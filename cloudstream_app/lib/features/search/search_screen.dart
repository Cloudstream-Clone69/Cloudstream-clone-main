// lib/features/search/search_screen.dart
// Exact CloudStream search — search bar on top, provider sections with horizontal cards

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/models/search_result.dart';
import '../../shared/theme/app_theme.dart';
import 'search_provider.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController();
    _focus = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _openDetail(BuildContext ctx, SearchResult item) {
    ctx.push('/detail', extra: {
      'title': item.title,
      'poster': item.poster ?? '',
      'provider': item.provider,
      'providerUrl': item.url,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SearchProvider>(builder: (ctx, sp, _) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: Column(children: [
          _SearchBar(
            controller: _ctrl, focusNode: _focus,
            onChanged: sp.onQueryChanged,
            onClear: () { _ctrl.clear(); sp.clear(); },
          ),
          Expanded(
            child: sp.query.isNotEmpty && sp.suggestions.isNotEmpty && sp.status == SearchStatus.idle
                ? _buildSuggestions(ctx, sp)
                : switch (sp.status) {
                    SearchStatus.idle    => _buildIdle(ctx, sp),
                    SearchStatus.loading => _buildLoading(),
                    SearchStatus.error   => _buildError(ctx, sp),
                    SearchStatus.loaded  => _buildResults(ctx, sp),
                  },
          ),
        ]),
      );
    });
  }

  Widget _buildIdle(BuildContext ctx, SearchProvider sp) {
    if (sp.history.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.search_rounded, color: AppColors.tertiary, size: 56),
          const SizedBox(height: 14),
          Text('Search movies, series and anime',
            style: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 14)),
        ]),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history_rounded, color: AppColors.secondary, size: 18),
              const SizedBox(width: 8),
              Text(
                'RECENT SEARCHES',
                style: GoogleFonts.inter(
                  color: AppColors.secondary,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => sp.clearHistory(),
                child: Text(
                  'Clear All',
                  style: GoogleFonts.inter(
                    color: AppColors.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: sp.history.map((q) => _SearchHistoryChip(
              query: q,
              onTap: () {
                _ctrl.text = q;
                sp.executeSearch(q);
              },
              onDelete: () => sp.deleteHistoryItem(q),
            )).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestions(BuildContext ctx, SearchProvider sp) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sp.suggestions.length,
      itemBuilder: (context, idx) {
        final sug = sp.suggestions[idx];
        return _SearchSuggestionTile(
          suggestion: sug,
          onTap: () {
            _ctrl.text = sug;
            sp.executeSearch(sug);
          },
        );
      },
    );
  }

  Widget _buildLoading() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 16),
      itemCount: 2,
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.only(bottom: 28),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Shimmer.fromColors(
              baseColor: AppColors.shimmerBase,
              highlightColor: AppColors.shimmerHighlight,
              child: Container(
                width: 100, height: 18,
                decoration: BoxDecoration(
                  color: AppColors.shimmerBase, borderRadius: BorderRadius.circular(4)),
              ),
            ),
          ),
          SizedBox(
            height: 180,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
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
        ]),
      ),
    );
  }

  Widget _buildError(BuildContext ctx, SearchProvider sp) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline_rounded, color: AppColors.accent, size: 44),
        const SizedBox(height: 12),
        Text('Search failed', style: GoogleFonts.inter(color: AppColors.primary, fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(sp.error ?? '', style: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 12), textAlign: TextAlign.center),
      ]),
    );
  }

  Widget _buildResults(BuildContext ctx, SearchProvider sp) {
    final sections = sp.results.where((s) => s.results.isNotEmpty).toList();
    if (sections.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.search_off_rounded, color: AppColors.tertiary, size: 48),
          const SizedBox(height: 12),
          Text('No results for "${sp.query}"',
            style: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 14)),
        ]),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 16),
      itemCount: sections.length,
      itemBuilder: (context, idx) {
        final section = sections[idx];
        final providerLabel = switch (section.provider.toLowerCase()) {
          'anidb'    => 'AniDB',
          '4khdhub'  => '4KHD Hub',
          final other => other.isNotEmpty ? '${other[0].toUpperCase()}${other.substring(1)}' : '',
        };

        return Padding(
          padding: const EdgeInsets.only(bottom: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Row(children: [
                  Text(
                    providerLabel,
                    style: GoogleFonts.inter(
                      color: AppColors.primary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.arrow_forward_rounded, color: AppColors.accent, size: 16),
                ]),
              ),
              SizedBox(
                height: 198,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: section.results.length,
                  itemBuilder: (ctx, i) {
                    final item = section.results[i];
                    return Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: _ProviderSearchCard(
                        item: item,
                        onTap: () => _openDetail(ctx, item),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Search Bar ────────────────────────────────────────────────────────────────

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      height: 40,
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(50),
        border: Border.all(color: AppColors.cardBorder, width: 0.5),
      ),
      child: Row(children: [
        const SizedBox(width: 12),
        const Icon(Icons.search_rounded, color: AppColors.tertiary, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            onChanged: onChanged,
            style: GoogleFonts.inter(color: AppColors.primary, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Search...',
              hintStyle: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 14),
              border: InputBorder.none,
              focusedBorder: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.zero,
              filled: false,
            ),
          ),
        ),
        if (controller.text.isNotEmpty)
          GestureDetector(
            onTap: onClear,
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.close_rounded, color: AppColors.tertiary, size: 17),
            ),
          )
        else
          const SizedBox(width: 8),
      ]),
    );
  }
}

// ─── Provider Search Card ──────────────────────────────────────────────────────

class _ProviderSearchCard extends StatefulWidget {
  final SearchResult item;
  final VoidCallback onTap;
  const _ProviderSearchCard({required this.item, required this.onTap});

  @override
  State<_ProviderSearchCard> createState() => _ProviderSearchCardState();
}

class _ProviderSearchCardState extends State<_ProviderSearchCard> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit:  (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: SizedBox(
          width: 110,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 110, height: 162,
              transform: _h
                  ? (Matrix4.identity()..scale(1.04, 1.04, 1.0))
                  : Matrix4.identity(),
              transformAlignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _h ? AppColors.accent.withValues(alpha: 0.8) : AppColors.cardBorder,
                  width: _h ? 1.5 : 0.5,
                ),
                boxShadow: _h
                    ? [BoxShadow(color: AppColors.accent.withValues(alpha: 0.3), blurRadius: 14)]
                    : [],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(15),
                child: (widget.item.poster ?? '').isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: widget.item.poster!,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => _shimmer(),
                        errorWidget: (_, __, ___) => _placeholder(),
                      )
                    : _placeholder(),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              widget.item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
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

  Widget _shimmer() => Shimmer.fromColors(
    baseColor: AppColors.shimmerBase,
    highlightColor: AppColors.shimmerHighlight,
    child: Container(color: AppColors.shimmerBase),
  );

  Widget _placeholder() => Container(
    color: AppColors.surfaceHigh,
    child: const Center(child: Icon(Icons.movie_outlined, color: AppColors.tertiary, size: 28)),
  );
}

// ─── Search History & Suggestions UI Helpers ─────────────────────────────────

class _SearchHistoryChip extends StatefulWidget {
  final String query;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _SearchHistoryChip({required this.query, required this.onTap, required this.onDelete});

  @override
  State<_SearchHistoryChip> createState() => _SearchHistoryChipState();
}

class _SearchHistoryChipState extends State<_SearchHistoryChip> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _h ? AppColors.surfaceHigh : AppColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.cardBorder, width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.query,
                style: GoogleFonts.inter(
                  color: AppColors.primary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  widget.onDelete();
                },
                child: const Icon(
                  Icons.close_rounded,
                  color: AppColors.tertiary,
                  size: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchSuggestionTile extends StatefulWidget {
  final String suggestion;
  final VoidCallback onTap;
  const _SearchSuggestionTile({required this.suggestion, required this.onTap});

  @override
  State<_SearchSuggestionTile> createState() => _SearchSuggestionTileState();
}

class _SearchSuggestionTileState extends State<_SearchSuggestionTile> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          color: _h ? AppColors.surfaceHigh : Colors.transparent,
          child: Row(
            children: [
              const Icon(Icons.search_rounded, color: AppColors.tertiary, size: 18),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  widget.suggestion,
                  style: GoogleFonts.inter(
                    color: AppColors.primary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const Icon(Icons.arrow_outward_rounded, color: AppColors.tertiary, size: 14),
            ],
          ),
        ),
      ),
    );
  }
}

