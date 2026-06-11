// lib/features/detail/detail_screen.dart
// Full CloudStream-style detail page

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/api/simkl_api.dart';
import '../../core/api/stream_resolver.dart';
import '../../core/models/tmdb_models.dart';
import '../../core/services/local_db.dart';
import '../../core/services/download_service.dart';
import '../../shared/theme/app_theme.dart';

class DetailScreen extends StatefulWidget {
  final int id;       // TMDB ID — for stream resolution
  final int simklId;  // SIMKL ID — for metadata API calls
  final String mediaType;
  final String title;
  final String posterUrl;
  final String backdropUrl;
  final String overview;
  final String releaseDate;

  const DetailScreen({
    super.key,
    required this.id,
    this.simklId = 0,
    required this.mediaType,
    required this.title,
    required this.posterUrl,
    required this.backdropUrl,
    required this.overview,
    required this.releaseDate,
  });

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  bool _loading = true;
  TmdbDetail? _detail;
  String? _error;
  bool _descExpanded = false;
  int _selectedSeasonNumber = 1;
  List<TmdbEpisode> _seasonEpisodes = [];
  bool _loadingEpisodes = false;
  bool _isBookmarked = false;
  bool _isDownloading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      // Use SIMKL ID if available, otherwise look it up from TMDB ID
      final sid = widget.simklId > 0
          ? widget.simklId
          : await SimklApi.instance.simklIdFromTmdb(widget.id, widget.mediaType);
      final d = sid > 0
          ? await SimklApi.instance.getDetails(sid, widget.mediaType)
          : throw Exception('Could not find SIMKL ID for this title');
      final bookmarked = await LocalDb.instance.isBookmarked(widget.id);
      setState(() { _detail = d; _loading = false; _isBookmarked = bookmarked; });
      if (widget.mediaType == 'tv' && d.seasons.isNotEmpty) {
        _selectedSeasonNumber = d.seasons.first.seasonNumber;
        _loadEpisodes(_selectedSeasonNumber);
      }
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _loadEpisodes(int seasonNumber) async {
    setState(() { _loadingEpisodes = true; _selectedSeasonNumber = seasonNumber; });
    try {
      final sid = _detail?.simklId ?? widget.simklId;
      if (sid <= 0) { setState(() => _loadingEpisodes = false); return; }
      final eps = await SimklApi.instance.getSeasonEpisodes(sid, seasonNumber);
      setState(() { _seasonEpisodes = eps; _loadingEpisodes = false; });
    } catch (e) {
      setState(() { _loadingEpisodes = false; });
    }
  }

  bool get _isMovie => widget.mediaType == 'movie';

  void _onPlayMovie() {
    _navigateToPlayer(null);
  }

  void _navigateToPlayer(TmdbEpisode? episode) {
    final isAnime = _detail?.isAnime ?? false;
    context.push('/player', extra: <String, dynamic>{
      'tmdbId': widget.id.toString(),
      'simklId': (_detail?.simklId ?? widget.simklId),
      'mediaType': widget.mediaType,
      'title': widget.title,
      'year': widget.releaseDate.length >= 4 ? widget.releaseDate.substring(0, 4) : '',
      'seasonNumber': episode?.seasonNumber.toString() ?? '',
      'episodeNumber': episode?.episodeNumber.toString() ?? '',
      'episodeTitle': episode?.name ?? '',
      'isAnime': isAnime,
      'backdrop': widget.backdropUrl.isNotEmpty ? widget.backdropUrl : (_detail?.backdropUrl ?? ''),
      'logo': _detail?.logoUrl ?? '',
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return _buildLoading();
    if (_error != null) return _buildError();
    return _buildContent();
  }

  Widget _buildLoading() {
    return Shimmer.fromColors(
      baseColor: AppColors.shimmerBase,
      highlightColor: AppColors.shimmerHighlight,
      child: SingleChildScrollView(
        child: Column(children: [
          Container(height: 300, color: AppColors.shimmerBase),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(width: 200, height: 24, color: AppColors.shimmerBase),
              const SizedBox(height: 12),
              Container(height: 14, color: AppColors.shimmerBase),
              const SizedBox(height: 8),
              Container(width: 260, height: 14, color: AppColors.shimmerBase),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline_rounded, color: AppColors.accent, size: 48),
        const SizedBox(height: 12),
        Text('Failed to load', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(_error ?? '', style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
        const SizedBox(height: 20),
        _RedButton(label: 'Retry', icon: Icons.refresh_rounded, onTap: _load),
      ]),
    );
  }

  Widget _buildContent() {
    final detail = _detail!;
    return CustomScrollView(
      slivers: [
        // Back button overlay at top left
        SliverToBoxAdapter(
          child: Stack(
            children: [
              _buildHero(detail),
              Positioned(
                top: 12, left: 12,
                child: _TapIcon(
                  icon: Icons.arrow_back_rounded,
                  onTap: () => GoRouter.of(context).pop(),
                ),
              ),
            ],
          ),
        ),
        if (!_isMovie && detail.seasons.isNotEmpty) ...[
          SliverToBoxAdapter(child: _buildEpisodeHeader(detail)),
          if (_loadingEpisodes)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator(color: AppColors.accent)),
              ),
            )
          else
            SliverList.separated(
              itemCount: _seasonEpisodes.length,
              separatorBuilder: (_, __) => const Divider(
                height: 1, color: AppColors.cardBorder, indent: 20, endIndent: 20),
              itemBuilder: (ctx, i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: _EpisodeTile(
                  ep: _seasonEpisodes[i],
                  onTap: () => _navigateToPlayer(_seasonEpisodes[i]),
                ),
              ),
            ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }

  Widget _buildHero(TmdbDetail detail) {
    final posterUrl = detail.backdropUrl.isNotEmpty ? detail.backdropUrl : widget.backdropUrl;
    return Stack(
      children: [
        // Backdrop
        SizedBox(
          height: 550, // Much taller, like the Pinterest reference
          width: double.infinity,
          child: Stack(fit: StackFit.expand, children: [
            if (posterUrl.isNotEmpty)
              CachedNetworkImage(
                imageUrl: posterUrl,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                placeholder: (_, __) => Container(color: AppColors.surface),
                errorWidget: (_, __, ___) => Container(color: AppColors.surface),
              )
            else
              Container(color: AppColors.surface),
            
            // Strong bottom gradient to make text readable
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    AppColors.background.withValues(alpha: 0.6),
                    AppColors.background.withValues(alpha: 0.95),
                    AppColors.background,
                  ],
                  stops: const [0.3, 0.6, 0.85, 1.0],
                ),
              ),
            ),
            // Left gradient for text
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerRight,
                  end: Alignment.centerLeft,
                  colors: [
                    Colors.transparent, 
                    AppColors.background.withValues(alpha: 0.8)
                  ],
                ),
              ),
            ),
          ]),
        ),

        // Info overlay (Left aligned, giant text)
        Positioned(
          left: 32, right: 32, bottom: 20,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                detail.title.toUpperCase(),
                style: GoogleFonts.oswald( // Use a strong condensed font or just inter very bold
                  color: AppColors.primary,
                  fontSize: 52,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                  letterSpacing: -1,
                  shadows: [const Shadow(color: Colors.black, blurRadius: 16)],
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 16),
              if (detail.overview.isNotEmpty) ...[
                GestureDetector(
                  onTap: () => setState(() => _descExpanded = !_descExpanded),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 700),
                    child: Text(
                      detail.overview,
                      maxLines: _descExpanded ? 20 : 3,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        color: Colors.white70,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        height: 1.5,
                        shadows: [const Shadow(color: Colors.black, blurRadius: 8)],
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              // Buttons row
              Row(
                children: [
                  _RedButton(
                    label: 'Play',
                    icon: Icons.play_arrow_rounded,
                    onTap: _isMovie 
                        ? _onPlayMovie 
                        : (_seasonEpisodes.isNotEmpty ? () => _navigateToPlayer(_seasonEpisodes.first) : null),
                  ),
                  const SizedBox(width: 10),
                  // Bookmark toggle
                  _GhostButton(
                    label: _isBookmarked ? '✓ Bookmarked' : '+ Bookmark',
                    onTap: () async {
                      await LocalDb.instance.toggleBookmark(BookmarkItem(
                        tmdbId: widget.id,
                        title: widget.title,
                        posterUrl: widget.posterUrl,
                        mediaType: widget.mediaType,
                        overview: widget.overview,
                        addedAt: DateTime.now(),
                      ));
                      setState(() => _isBookmarked = !_isBookmarked);
                    },
                  ),
                  if (_isMovie) ...[
                    const SizedBox(width: 10),
                    _GhostButton(
                      label: _isDownloading ? 'Queued ↓' : '↓ Download',
                      onTap: _isDownloading ? null : () async {
                        setState(() => _isDownloading = true);
                        try {
                          // Get episode refs then resolve stream for best one
                          final refs = await StreamResolver.instance.getEpisodeRefs(
                            title: widget.title,
                            mediaType: widget.mediaType,
                            year: widget.releaseDate.length >= 4
                                ? widget.releaseDate.substring(0, 4)
                                : '',
                          );
                          if (refs.isEmpty) throw Exception('No sources found');
                          final bestRef = refs.first;
                          final bestSource = await StreamResolver.instance.resolveStreamForEpisode(
                            provider: bestRef.provider,
                            episodeUrl: bestRef.episodeUrl,
                            quality: bestRef.quality,
                            size: bestRef.size,
                            label: bestRef.label,
                          );
                          if (bestSource == null) throw Exception('Could not resolve stream');
                          await DownloadService.instance.startDownload(
                            tmdbId: widget.id,
                            title: widget.title,
                            posterUrl: widget.posterUrl,
                            mediaType: widget.mediaType,
                            streamUrl: bestSource.url,
                          );
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Download failed: $e',
                                    style: GoogleFonts.inter(fontSize: 12)),
                                backgroundColor: AppColors.accent,
                              ),
                            );
                            setState(() => _isDownloading = false);
                          }

                        }
                      },
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEpisodeHeader(TmdbDetail detail) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Row(
        children: [
          DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: _selectedSeasonNumber,
              dropdownColor: AppColors.surface,
              icon: const Icon(Icons.keyboard_arrow_down_rounded, color: AppColors.primary),
              style: GoogleFonts.inter(
                color: AppColors.primary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
              items: detail.seasons.map((s) {
                return DropdownMenuItem<int>(
                  value: s.seasonNumber,
                  child: Text(s.name.isNotEmpty ? s.name : 'Season ${s.seasonNumber}'),
                );
              }).toList(),
              onChanged: (val) {
                if (val != null && val != _selectedSeasonNumber) {
                  _loadEpisodes(val);
                }
              },
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.surfaceHigh,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${_seasonEpisodes.length} Episodes',
              style: GoogleFonts.inter(
                color: AppColors.tertiary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Episode Tile ─────────────────────────────────────────────────────────────

class _EpisodeTile extends StatefulWidget {
  final TmdbEpisode ep;
  final VoidCallback onTap;
  const _EpisodeTile({required this.ep, required this.onTap});

  @override
  State<_EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<_EpisodeTile> {
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
          duration: const Duration(milliseconds: 130),
          decoration: BoxDecoration(
            color: _h ? AppColors.surfaceHigher : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(children: [
            // Episode number badge
            SizedBox(
              width: 36,
              child: Text(
                '${widget.ep.episodeNumber}',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  color: AppColors.tertiary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Thumbnail
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 120, height: 68,
                child: widget.ep.stillUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: widget.ep.stillUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => Container(
                          color: AppColors.surface,
                          child: const Icon(Icons.movie_rounded, color: AppColors.tertiary, size: 24),
                        ),
                        errorWidget: (_, __, ___) => Container(
                          color: AppColors.surface,
                          child: const Icon(Icons.broken_image_rounded, color: AppColors.tertiary, size: 24),
                        ),
                      )
                    : Container(
                        color: AppColors.surface,
                        child: Center(
                          child: Text('${widget.ep.episodeNumber}',
                            style: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 20, fontWeight: FontWeight.w700)),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 14),
            // Info
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(
                  widget.ep.name.isNotEmpty ? widget.ep.name : 'Episode ${widget.ep.episodeNumber}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    color: AppColors.primary, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                if (widget.ep.overview.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    widget.ep.overview,
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 11, height: 1.4),
                  ),
                ],
              ]),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.play_circle_fill_rounded,
              color: _h ? AppColors.accent : AppColors.tertiary.withValues(alpha: 0.5),
              size: 26,
            ),
          ]),
        ),
      ),
    );
  }
}
// ─── Shared Widgets ───────────────────────────────────────────────────────────

class _RedButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  const _RedButton({required this.label, required this.icon, this.onTap});

  @override
  State<_RedButton> createState() => _RedButtonState();
}

class _RedButtonState extends State<_RedButton> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          decoration: BoxDecoration(
            color: enabled
                ? (_h ? AppColors.accentDim : AppColors.accent)
                : AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, color: Colors.white, size: 17),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GhostButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  const _GhostButton({required this.label, required this.onTap});

  @override
  State<_GhostButton> createState() => _GhostButtonState();
}

class _GhostButtonState extends State<_GhostButton> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: _h ? AppColors.surfaceHigher : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.cardBorder),
          ),
          child: Text(
            widget.label,
            style: GoogleFonts.inter(
              color: AppColors.secondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _TapIcon extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _TapIcon({required this.icon, required this.onTap});

  @override
  State<_TapIcon> createState() => _TapIconState();
}

class _TapIconState extends State<_TapIcon> {
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
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: _h ? AppColors.surfaceHigh : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(widget.icon, color: AppColors.secondary, size: 18),
        ),
      ),
    );
  }
}
