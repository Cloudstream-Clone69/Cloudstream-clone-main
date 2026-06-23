// lib/features/home/home_screen.dart
// CloudStream-exact home layout

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/models/tmdb_models.dart';
import '../../core/services/local_db.dart';
import '../../shared/theme/app_theme.dart';
import 'home_provider.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final p = context.read<HomeProvider>();
      if (p.status == HomeStatus.idle) p.load();
    });
  }

  void _openDetail(BuildContext ctx, TmdbItem item) {
    ctx.push('/detail', extra: {
      'id': item.id,
      'mediaType': item.mediaType,
      'title': item.title,
      'poster': item.posterUrl,
      'backdrop': item.backdropUrl,
      'overview': item.overview,
      'releaseDate': item.releaseDate,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<HomeProvider>(builder: (ctx, p, _) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: switch (p.status) {
          HomeStatus.loading || HomeStatus.idle => _buildShimmer(),
          HomeStatus.error   => _buildError(ctx, p),
          HomeStatus.loaded  => _buildContent(ctx, p),
        },
      );
    });
  }

  // ── Loading ────────────────────────────────────────────────────────────────

  Widget _buildShimmer() {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(children: [
        Shimmer.fromColors(
          baseColor: AppColors.shimmerBase,
          highlightColor: AppColors.shimmerHighlight,
          child: Container(height: 300, color: AppColors.shimmerBase),
        ),
        const SizedBox(height: 24),
        _shimmerRow(),
        const SizedBox(height: 20),
        _shimmerRow(),
        const SizedBox(height: 20),
      ]),
    );
  }

  Widget _shimmerRow() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
        child: Shimmer.fromColors(
          baseColor: AppColors.shimmerBase,
          highlightColor: AppColors.shimmerHighlight,
          child: Container(
            width: 120, height: 15,
            decoration: BoxDecoration(color: AppColors.shimmerBase, borderRadius: BorderRadius.circular(4)),
          ),
        ),
      ),
      SizedBox(
        height: 180,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 7,
          itemBuilder: (_, __) => Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Shimmer.fromColors(
              baseColor: AppColors.shimmerBase,
              highlightColor: AppColors.shimmerHighlight,
              child: Container(
                width: 110, height: 162,
                decoration: BoxDecoration(
                  color: AppColors.shimmerBase, borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ),
      ),
    ]);
  }

  // ── Error ──────────────────────────────────────────────────────────────────

  Widget _buildError(BuildContext ctx, HomeProvider p) {
    final isBackendDown = p.error == 'backend_unreachable';
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(
          isBackendDown ? Icons.power_off_rounded : Icons.cloud_off_rounded,
          color: AppColors.tertiary,
          size: 52,
        ),
        const SizedBox(height: 16),
        Text(
          isBackendDown ? 'Backend server not running' : 'Content failed to load',
          style: GoogleFonts.inter(color: AppColors.primary, fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          isBackendDown
              ? 'Make sure start.bat is running.\nGo to Settings → DNS & Network if streams are blocked.'
              : 'Check your internet connection and try again.',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 13),
        ),
        const SizedBox(height: 24),
        GestureDetector(
          onTap: p.refresh,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 11),
            decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(7)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.refresh_rounded, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text('Try Again', style: GoogleFonts.inter(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ]),
    );
  }

  // ── Content ────────────────────────────────────────────────────────────────

  Widget _buildContent(BuildContext ctx, HomeProvider p) {
    return CustomScrollView(
      slivers: [
        // Hero
        if (p.featuredItem != null)
          SliverToBoxAdapter(
            child: _HeroBanner(
              item: p.featuredItem!,
              onPlay: () => _openDetail(ctx, p.featuredItem!),
              onMoreInfo: () => _openDetail(ctx, p.featuredItem!),
            ),
          ),

        // ── Continue Watching ──────────────────────────────────────────────
        if (p.continueWatching.isNotEmpty) ...[
          const SliverToBoxAdapter(child: _SectionHeader(title: '▶ Continue Watching')),
          SliverToBoxAdapter(
            child: _ContinueWatchingRow(
              items: p.continueWatching,
              onTap: (h) => ctx.push('/player', extra: {
                'tmdbId': h.tmdbId.toString(),
                'mediaType': h.mediaType,
                'title': h.title,
                'year': '',
                'seasonNumber': h.seasonNumber ?? '',
                'episodeNumber': h.episodeNumber ?? '',
                'episodeTitle': h.episodeTitle ?? '',
              }),
              onClearAll: () async {
                await LocalDb.instance.clearHistory();
                await p.refreshContinueWatching();
              },
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],

        // Sections
        for (final section in p.sections)
          if (section.items.isNotEmpty) ...[
            SliverToBoxAdapter(child: _SectionHeader(title: section.title)),
            SliverToBoxAdapter(
              child: _CardRow(
                items: section.items,
                onTap: (item) => _openDetail(ctx, item),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],

        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }
}

// ─── Hero Banner ───────────────────────────────────────────────────────────────

class _HeroBanner extends StatelessWidget {
  final TmdbItem item;
  final VoidCallback onPlay;
  final VoidCallback onMoreInfo;

  const _HeroBanner({required this.item, required this.onPlay, required this.onMoreInfo});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 340,
      child: Stack(fit: StackFit.expand, children: [
        // Backdrop
        if (item.posterUrl.isNotEmpty)
          CachedNetworkImage(
            imageUrl: item.posterUrl,
            fit: BoxFit.cover,
            placeholder: (_, __) => Container(color: AppColors.surface),
            errorWidget: (_, __, ___) => Container(color: AppColors.surface),
          )
        else
          Container(color: AppColors.surface),

        // Gradients
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerRight, end: Alignment.centerLeft,
              colors: [Colors.transparent, AppColors.background.withValues(alpha: 0.7), AppColors.background],
              stops: const [0.0, 0.55, 1.0],
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [Colors.transparent, AppColors.background.withValues(alpha: 0.6), AppColors.background],
              stops: const [0.35, 0.75, 1.0],
            ),
          ),
        ),

        // Top-right controls
        Positioned(
          top: 14, right: 16,
          child: Row(children: [
            Text('CloudStream',
              style: GoogleFonts.inter(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                shadows: [const Shadow(color: Colors.black54, blurRadius: 8)],
              ),
            ),
            const SizedBox(width: 12),
            _HoverIcon(icon: Icons.search_rounded, onTap: () => GoRouter.of(context).go('/search')),
          ]),
        ),

        // Bottom content
        Positioned(
          left: 24, bottom: 28, right: 200,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(
              item.title,
              style: GoogleFonts.inter(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w800,
                height: 1.15,
                shadows: [const Shadow(color: Colors.black54, blurRadius: 12)],
              ),
              maxLines: 2, overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            Row(children: [
              _HeroPrimaryBtn(label: 'Play', icon: Icons.play_arrow_rounded, onTap: onPlay),
              const SizedBox(width: 10),
              _HeroSecondaryBtn(label: 'More Info', icon: Icons.info_outline_rounded, onTap: onMoreInfo),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _HoverIcon extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _HoverIcon({required this.icon, required this.onTap});

  @override
  State<_HoverIcon> createState() => _HoverIconState();
}

class _HoverIconState extends State<_HoverIcon> {
  bool _h = false;
  @override
  Widget build(BuildContext ctx) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit:  (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: _h ? AppColors.surfaceHigh.withValues(alpha: 0.8) : AppColors.surfaceHigh.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(widget.icon, color: Colors.white, size: 18),
        ),
      ),
    );
  }
}

class _HeroPrimaryBtn extends StatefulWidget {
  final String label; final IconData icon; final VoidCallback onTap;
  const _HeroPrimaryBtn({required this.label, required this.icon, required this.onTap});
  @override State<_HeroPrimaryBtn> createState() => _HeroPrimaryBtnState();
}

class _HeroPrimaryBtnState extends State<_HeroPrimaryBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext ctx) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit:  (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          decoration: BoxDecoration(
            color: _h ? AppColors.accentDim : AppColors.accent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(widget.icon, color: Colors.white, size: 17),
            const SizedBox(width: 5),
            Text(widget.label, style: GoogleFonts.inter(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }
}

class _HeroSecondaryBtn extends StatefulWidget {
  final String label; final IconData icon; final VoidCallback onTap;
  const _HeroSecondaryBtn({required this.label, required this.icon, required this.onTap});
  @override State<_HeroSecondaryBtn> createState() => _HeroSecondaryBtnState();
}

class _HeroSecondaryBtnState extends State<_HeroSecondaryBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext ctx) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit:  (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: _h ? AppColors.surfaceHigher : AppColors.surfaceHigh.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.cardBorder),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(widget.icon, color: Colors.white, size: 16),
            const SizedBox(width: 5),
            Text(widget.label, style: GoogleFonts.inter(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

// ─── Section Header ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
      child: Row(children: [
        Text(title,
          style: GoogleFonts.inter(
            color: AppColors.primary, fontSize: 16, fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 6),
        const Icon(Icons.arrow_forward_rounded, color: AppColors.accent, size: 16),
      ]),
    );
  }
}

// ─── Card Row ──────────────────────────────────────────────────────────────────

class _CardRow extends StatelessWidget {
  final List<TmdbItem> items;
  final void Function(TmdbItem) onTap;

  const _CardRow({required this.items, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 198,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: items.length,
        itemBuilder: (ctx, i) => Padding(
          padding: const EdgeInsets.only(right: 10),
          child: _ContentCard(item: items[i], onTap: () => onTap(items[i])),
        ),
      ),
    );
  }
}

class _ContentCard extends StatefulWidget {
  final TmdbItem item;
  final VoidCallback onTap;
  const _ContentCard({required this.item, required this.onTap});

  @override
  State<_ContentCard> createState() => _ContentCardState();
}

class _ContentCardState extends State<_ContentCard> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit:  (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          transform: _h
              ? (Matrix4.identity()..scale(1.04, 1.04, 1.0))
              : Matrix4.identity(),
          transformAlignment: Alignment.center,
          width: 110,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            // Poster
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 110, height: 162,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _h ? AppColors.accent.withValues(alpha: 0.7) : AppColors.cardBorder,
                  width: _h ? 1.5 : 0.5,
                ),
                boxShadow: _h
                    ? [BoxShadow(color: AppColors.accent.withValues(alpha: 0.25), blurRadius: 12, offset: const Offset(0, 4))]
                    : [],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: widget.item.posterUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: widget.item.posterUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => Shimmer.fromColors(
                          baseColor: AppColors.shimmerBase,
                          highlightColor: AppColors.shimmerHighlight,
                          child: Container(color: AppColors.shimmerBase),
                        ),
                        errorWidget: (_, __, ___) => _placeholder(),
                      )
                    : _placeholder(),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              widget.item.title,
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                color: _h ? AppColors.primary : AppColors.secondary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
                height: 1.3,
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _placeholder() => Container(
    color: AppColors.surfaceHigh,
    child: const Center(child: Icon(Icons.movie_outlined, color: AppColors.tertiary, size: 28)),
  );
}

// ─── Continue Watching Row ──────────────────────────────────────────────────────

class _ContinueWatchingRow extends StatelessWidget {
  final List<WatchHistory> items;
  final void Function(WatchHistory) onTap;
  final VoidCallback onClearAll;
  const _ContinueWatchingRow({
    required this.items,
    required this.onTap,
    required this.onClearAll,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 130,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: items.length + 1,
        itemBuilder: (ctx, i) {
          if (i == items.length) {
            return Padding(
              padding: const EdgeInsets.only(right: 12),
              child: _ClearContinueCard(onTap: onClearAll),
            );
          }
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _ContinueCard(item: items[i], onTap: () => onTap(items[i])),
          );
        },
      ),
    );
  }
}

class _ClearContinueCard extends StatefulWidget {
  final VoidCallback onTap;
  const _ClearContinueCard({required this.onTap});

  @override
  State<_ClearContinueCard> createState() => _ClearContinueCardState();
}

class _ClearContinueCardState extends State<_ClearContinueCard> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit:  (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: AppColors.surface,
              title: Text('Clear Continue Watching',
                  style: GoogleFonts.inter(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
              content: Text('Are you sure you want to clear your continue watching history?',
                  style: GoogleFonts.inter(color: Colors.white70, fontSize: 13)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('Cancel', style: GoogleFonts.inter(color: Colors.white60, fontSize: 12)),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    widget.onTap();
                  },
                  child: Text('Clear All', style: GoogleFonts.inter(color: AppColors.accent, fontWeight: FontWeight.bold, fontSize: 12)),
                ),
              ],
            ),
          );
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 140,
          decoration: BoxDecoration(
            color: _h ? AppColors.accent.withValues(alpha: 0.15) : AppColors.surfaceHigh.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _h ? AppColors.accent.withValues(alpha: 0.5) : AppColors.tertiary.withValues(alpha: 0.15),
              width: 1.5,
            ),
          ),
          transform: _h ? (Matrix4.identity()..scale(1.03)) : Matrix4.identity(),
          transformAlignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _h ? AppColors.accent : AppColors.surfaceHigh,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.delete_sweep_rounded,
                  color: _h ? Colors.white : AppColors.tertiary,
                  size: 24,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Clear List',
                style: GoogleFonts.inter(
                  color: _h ? Colors.white : AppColors.secondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContinueCard extends StatefulWidget {
  final WatchHistory item;
  final VoidCallback onTap;
  const _ContinueCard({required this.item, required this.onTap});
  @override
  State<_ContinueCard> createState() => _ContinueCardState();
}

class _ContinueCardState extends State<_ContinueCard> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final progress = widget.item.progress;
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit:  (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 220,
          transform: _h ? (Matrix4.identity()..scale(1.03)) : Matrix4.identity(),
          transformAlignment: Alignment.center,
          child: Stack(children: [
            // Backdrop / poster
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: widget.item.posterUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: widget.item.posterUrl,
                      width: 220, height: 124, fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: AppColors.surfaceHigh),
                      errorWidget: (_, __, ___) => Container(color: AppColors.surfaceHigh),
                    )
                  : Container(width: 220, height: 124, color: AppColors.surfaceHigh),
            ),
            // Gradient overlay
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter, end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black.withValues(alpha: 0.75)],
                    ),
                  ),
                ),
              ),
            ),
            // Progress bar
            Positioned(
              bottom: 6, left: 6, right: 6,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  widget.item.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                ),
                if (widget.item.subtitle.isNotEmpty)
                  Text(
                    widget.item.subtitle,
                    style: GoogleFonts.inter(color: Colors.white60, fontSize: 10),
                  ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    minHeight: 3,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent),
                  ),
                ),
              ]),
            ),
            // Play icon overlay
            if (_h)
              Positioned.fill(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.9),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 22),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

