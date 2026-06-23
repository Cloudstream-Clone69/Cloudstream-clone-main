// lib/features/detail/detail_screen.dart
// Full CloudStream-style detail page

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/api/tmdb_api.dart';
import '../../core/api/stream_resolver.dart';
import '../../core/api/details_api.dart';
import '../../core/models/tmdb_models.dart';
import '../../core/models/content_detail.dart';
import '../../core/services/local_db.dart';
import '../../core/services/download_service.dart';
import '../../shared/theme/app_theme.dart';

class DetailScreen extends StatefulWidget {
  final int? id;       // TMDB ID
  final String? mediaType;
  final String title;
  final String posterUrl;
  final String backdropUrl;
  final String overview;
  final String releaseDate;
  final String? provider;
  final String? providerUrl;

  const DetailScreen({
    super.key,
    this.id,
    this.mediaType,
    required this.title,
    required this.posterUrl,
    required this.backdropUrl,
    required this.overview,
    required this.releaseDate,
    this.provider,
    this.providerUrl,
  });

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  bool _loading = true;
  TmdbDetail? _detail;
  ContentDetail? _providerDetail;
  String? _error;
  bool _descExpanded = false;
  int _selectedSeasonNumber = 1;
  List<TmdbEpisode> _seasonEpisodes = [];
  bool _loadingEpisodes = false;
  bool _isBookmarked = false;
  String _bookmarkCategory = 'Plan to Watch';
  bool _isDownloading = false;
  Set<String> _completedDownloadKeys = {};
  StreamSubscription? _downloadsSubscription;

  bool get _isAnime => widget.provider?.toLowerCase() == 'anidb' ||
      widget.provider?.toLowerCase() == 'anidao' ||
      (_detail?.isAnime ?? false);

  @override
  void initState() {
    super.initState();
    _load();
    _loadCompletedDownloads();
    _downloadsSubscription = DownloadService.instance.tasksStream.listen((_) {
      _loadCompletedDownloads();
    });
  }

  @override
  void dispose() {
    _downloadsSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadCompletedDownloads() async {
    final list = await LocalDb.instance.getDownloads();
    final keys = list.map((d) => '${d.tmdbId}_${d.seasonNumber ?? 'm'}_${d.episodeNumber ?? '0'}').toSet();
    if (mounted) {
      setState(() {
        _completedDownloadKeys = keys;
      });
    }
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      if (widget.provider != null && widget.providerUrl != null) {
        // Step 1: Search TMDB for the cleaned title
        final cleanedQuery = _cleanSearchTitle(widget.title);
        final searchResults = await TmdbApi.instance.search(cleanedQuery);
        TmdbItem? bestMatch;
        if (searchResults.isNotEmpty) {
          final providerLower = widget.provider?.toLowerCase();
          final isAnimeProvider = providerLower == 'anidb' || providerLower == 'anidao';

          searchResults.sort((a, b) {
            int scoreA = 0;
            int scoreB = 0;

            // Exact title matches (case-sensitive)
            if (a.title == cleanedQuery) {
              scoreA += 50;
            } else if (a.title.toLowerCase() == cleanedQuery.toLowerCase()) {
              scoreA += 30;
            } else if (a.title.toLowerCase().contains(cleanedQuery.toLowerCase()) || cleanedQuery.toLowerCase().contains(a.title.toLowerCase())) {
              scoreA += 10;
            }

            if (b.title == cleanedQuery) {
              scoreB += 50;
            } else if (b.title.toLowerCase() == cleanedQuery.toLowerCase()) {
              scoreB += 30;
            } else if (b.title.toLowerCase().contains(cleanedQuery.toLowerCase()) || cleanedQuery.toLowerCase().contains(b.title.toLowerCase())) {
              scoreB += 10;
            }

            // Anime provider bias
            if (isAnimeProvider) {
              if (a.isAnime) scoreA += 100;
              else if (a.genreIds.contains(16)) scoreA += 50; // Animation

              if (b.isAnime) scoreB += 100;
              else if (b.genreIds.contains(16)) scoreB += 50; // Animation
            } else {
              // General anime detection (e.g. if title is "One Piece" vs "ONE PIECE" and one is anime)
              if (a.isAnime) scoreA += 15;
              if (b.isAnime) scoreB += 15;
            }

            return scoreB.compareTo(scoreA); // descending order
          });
          bestMatch = searchResults.first;
        }

        // Step 2: Load provider details (watch URLs list)
        final pDetail = await DetailsApi.instance.getDetails(widget.provider!, widget.providerUrl!);

        if (bestMatch != null) {
          // Step 3: Load TMDB details & bookmarks using the matched TMDB ID
          final d = await TmdbApi.instance.getDetails(bestMatch.id, bestMatch.mediaType);
          await _updateBookmarkState(bestMatch.id);
          setState(() {
            _detail = d;
            _providerDetail = pDetail;
            _loading = false;
          });
          if (bestMatch.mediaType == 'tv' && d.seasons.isNotEmpty) {
            _selectedSeasonNumber = d.seasons.first.seasonNumber;
            _loadEpisodes(_selectedSeasonNumber);
          }
        } else {
          // Fallback to scraper-only list if TMDB search yields no results
          setState(() {
            _providerDetail = pDetail;
            _loading = false;
          });
        }
      } else {
        if (widget.id != null && widget.mediaType != null) {
          final d = await TmdbApi.instance.getDetails(widget.id!, widget.mediaType!);
          await _updateBookmarkState(widget.id!);
          setState(() { _detail = d; _loading = false; });
          if (widget.mediaType == 'tv' && d.seasons.isNotEmpty) {
            _selectedSeasonNumber = d.seasons.first.seasonNumber;
            _loadEpisodes(_selectedSeasonNumber);
          }
        }
      }
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  String _cleanSearchTitle(String title) {
    return title
        .split(RegExp(r'\s+[-–—]\s+'))[0] // Split by hyphen (e.g. "FROM - MGMP" -> "FROM")
        .replaceAll(RegExp(r'\s*[\[\(].*?[\]\)]'), '') // Remove brackets/parentheses
        .replaceAll(RegExp(r'\s*S\d+(?:\s*-\s*S?\d+)?', caseSensitive: false), '') // Remove S1, S1-S2, etc.
        .replaceAll(RegExp(r'\s*Season\s*\d+.*$', caseSensitive: false), '') // Remove Season ...
        .replaceAll(RegExp(r'\b(series|movie|anime|dub|sub)\b', caseSensitive: false), '') // Remove common tags
        .replaceAll(RegExp(r'\s+'), ' ') // Collapse multiple spaces
        .trim();
  }

  Future<void> _loadEpisodes(int seasonNumber) async {
    setState(() { _loadingEpisodes = true; _selectedSeasonNumber = seasonNumber; });
    try {
      final eps = await TmdbApi.instance.getSeasonEpisodes(_detail!.id, seasonNumber);
      setState(() { _seasonEpisodes = eps; _loadingEpisodes = false; });
    } catch (e) {
      setState(() { _loadingEpisodes = false; });
    }
  }

  bool get _isMovie => (widget.mediaType ?? _detail?.mediaType) == 'movie';

  bool get _isProviderMovie {
    if (_providerDetail == null) return false;
    if (_providerDetail!.episodes.isEmpty) return false;
    return _providerDetail!.episodes.any((ep) => ep.episode?.toLowerCase() == 'movie');
  }

  void _onPlayMovie() {
    _navigateToPlayer(null);
  }

  Future<void> _onDownloadSingleEpisode(TmdbEpisode ep) async {
    try {
      String? mappedEpUrl;
      if (_providerDetail != null) {
        final targetSeason = ep.seasonNumber;
        final targetEp = ep.episodeNumber;

        for (final pEp in _providerDetail!.episodes) {
          int? epSeason;
          int? epNumber;

          if (widget.provider == 'anidb') {
            epSeason = 1;
            epNumber = int.tryParse(pEp.episode ?? '') ?? _parseEpNumFromText(pEp.title);
          } else {
            epSeason = _parseSeasonNumFromText(pEp.title) ?? 1;
            epNumber = int.tryParse(pEp.episode ?? '') ?? _parseEpNumFromText(pEp.title) ?? _parseEpNumFromText(pEp.episode ?? '');
          }

          if (epSeason == targetSeason && epNumber == targetEp) {
            mappedEpUrl = pEp.url;
            break;
          }
        }
      }

      final refs = await StreamResolver.instance.getEpisodeRefs(
        title: widget.title,
        mediaType: _detail!.mediaType,
        year: widget.releaseDate.length >= 4
            ? widget.releaseDate.substring(0, 4)
            : (_detail?.year ?? ''),
        seasonNumber: ep.seasonNumber.toString(),
        episodeNumber: ep.episodeNumber.toString(),
        isAnime: _isAnime,
        provider: widget.provider,
        showUrl: mappedEpUrl ?? widget.providerUrl,
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
        tmdbId: _detail!.id,
        title: '${widget.title} S${ep.seasonNumber}E${ep.episodeNumber}',
        posterUrl: widget.posterUrl,
        mediaType: _detail!.mediaType,
        seasonNumber: ep.seasonNumber.toString(),
        episodeNumber: ep.episodeNumber.toString(),
        streamUrl: bestSource.url,
        referer: bestSource.referer,
        cookie: bestSource.cookie,
      );

      _loadCompletedDownloads();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e', style: GoogleFonts.inter(fontSize: 12, color: Colors.white)),
            backgroundColor: AppColors.accent,
          ),
        );
      }
    }
  }

  Future<void> _onDownloadFullSeason() async {
    if (_seasonEpisodes.isEmpty) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Queueing ${_seasonEpisodes.length} episodes for download...', style: GoogleFonts.inter(fontSize: 12, color: Colors.white)),
        backgroundColor: AppColors.surfaceHigh,
      ),
    );

    for (final ep in _seasonEpisodes) {
      final key = '${_detail!.id}_${ep.seasonNumber}_${ep.episodeNumber}';
      if (_completedDownloadKeys.contains(key) || DownloadService.instance.tasks.containsKey(key)) {
        continue;
      }
      
      _onDownloadSingleEpisode(ep);
      await Future.delayed(const Duration(milliseconds: 600));
    }
  }

  void _navigateToPlayer(TmdbEpisode? episode) {
    final isAnime = _isAnime;

    String? mappedEpUrl;
    if (_providerDetail != null) {
      final targetSeason = episode?.seasonNumber ?? 1;
      final targetEp = episode?.episodeNumber ?? 1;

      for (final ep in _providerDetail!.episodes) {
        int? epSeason;
        int? epNumber;

        if (widget.provider == 'anidb') {
          epSeason = 1;
          epNumber = int.tryParse(ep.episode ?? '') ?? _parseEpNumFromText(ep.title);
        } else {
          epSeason = _parseSeasonNumFromText(ep.title) ?? 1;
          epNumber = int.tryParse(ep.episode ?? '') ?? _parseEpNumFromText(ep.title) ?? _parseEpNumFromText(ep.episode ?? '');
        }

        if (epSeason == targetSeason && epNumber == targetEp) {
          mappedEpUrl = ep.url;
          break;
        }
      }
    }

    context.push('/player', extra: <String, dynamic>{
      'tmdbId': _detail?.id.toString() ?? '',
      'mediaType': _detail?.mediaType ?? '',
      'title': widget.title,
      'year': _detail?.year ?? '',
      'seasonNumber': episode?.seasonNumber.toString() ?? '',
      'episodeNumber': episode?.episodeNumber.toString() ?? '',
      'episodeTitle': episode?.name ?? '',
      'isAnime': isAnime,
      'backdrop': _detail?.backdropUrl ?? widget.backdropUrl,
      'logo': _detail?.logoUrl ?? '',
      'preloadedUrl': '',
      'episodeUrl': mappedEpUrl,
      'preloadedProvider': widget.provider,
      'showUrl': widget.providerUrl,
    });
  }

  int? _parseSeasonNumFromText(String text) {
    final m = RegExp(r'(?:[Ss]eason|[Ss])\s*[-_]?\s*(\d+)').firstMatch(text);
    if (m != null) return int.tryParse(m.group(1)!);
    return null;
  }

  int? _parseEpNumFromText(String text) {
    final m = RegExp(r'(?:[Ee]pisode|[Ee]p|[Ee])\s*[-_]?\s*(\d+)').firstMatch(text);
    if (m != null) return int.tryParse(m.group(1)!);
    final m2 = RegExp(r'\b(\d+)\b').firstMatch(text);
    if (m2 != null) return int.tryParse(m2.group(1)!);
    return null;
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
    if (_detail != null) return _buildContent();
    if (_providerDetail != null) return _buildProviderContent();
    return const Center(child: Text('No details found'));
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
              itemBuilder: (ctx, i) {
                final ep = _seasonEpisodes[i];
                final key = '${_detail!.id}_${ep.seasonNumber}_${ep.episodeNumber}';
                final isDownloaded = _completedDownloadKeys.contains(key);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: _EpisodeTile(
                    tmdbId: _detail!.id,
                    ep: ep,
                    isDownloaded: isDownloaded,
                    onTap: () => _navigateToPlayer(ep),
                    onDownload: () => _onDownloadSingleEpisode(ep),
                  ),
                );
              },
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
                    label: _isBookmarked ? '✓ $_bookmarkCategory' : '+ Bookmark',
                    onTap: () async {
                      if (_isBookmarked) {
                        final bookmarks = await LocalDb.instance.getBookmarks();
                        try {
                          final old = bookmarks.firstWhere((x) => x.tmdbId == _detail!.id);
                          await LocalDb.instance.toggleBookmark(old);
                        } catch (_) {
                          await LocalDb.instance.toggleBookmark(BookmarkItem(
                            tmdbId: _detail!.id, title: widget.title, posterUrl: widget.posterUrl,
                            mediaType: _detail!.mediaType, overview: widget.overview, addedAt: DateTime.now(),
                          ));
                        }
                        await _updateBookmarkState(_detail!.id);
                      } else {
                        final item = BookmarkItem(
                          tmdbId: _detail!.id,
                          title: widget.title,
                          posterUrl: widget.posterUrl,
                          mediaType: _detail!.mediaType,
                          overview: widget.overview,
                          addedAt: DateTime.now(),
                          category: 'Plan to Watch',
                        );
                        await LocalDb.instance.toggleBookmark(item);
                        await _updateBookmarkState(_detail!.id);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Added to Plan to Watch', style: GoogleFonts.inter(fontSize: 12, color: Colors.white)),
                              backgroundColor: AppColors.surfaceHigh,
                              action: SnackBarAction(
                                label: 'Edit',
                                textColor: AppColors.accent,
                                onPressed: () => _showCategorySelector(context, _detail!.id, item),
                              ),
                            ),
                          );
                        }
                      }
                    },
                    onLongPress: _isBookmarked
                        ? () {
                            final item = BookmarkItem(
                              tmdbId: _detail!.id,
                              title: widget.title,
                              posterUrl: widget.posterUrl,
                              mediaType: _detail!.mediaType,
                              overview: widget.overview,
                              addedAt: DateTime.now(),
                            );
                            _showCategorySelector(context, _detail!.id, item);
                          }
                        : null,
                  ),
                  if (_isMovie) ...[
                    const SizedBox(width: 10),
                    StreamBuilder<Map<String, DownloadTask>>(
                      stream: DownloadService.instance.tasksStream,
                      initialData: DownloadService.instance.tasks,
                      builder: (context, snapshot) {
                        final tasks = snapshot.data ?? {};
                        final movieKey = '${_detail!.id}_m_0';
                        final activeTask = tasks[movieKey];
                        final isDownloaded = _completedDownloadKeys.contains(movieKey);

                        String label = '↓ Download';
                        VoidCallback? onTap = () async {
                          setState(() => _isDownloading = true);
                          try {
                            // Get episode refs then resolve stream for best one
                            final refs = await StreamResolver.instance.getEpisodeRefs(
                              title: widget.title,
                              mediaType: _detail!.mediaType,
                              year: widget.releaseDate.length >= 4
                                  ? widget.releaseDate.substring(0, 4)
                                  : (_detail?.year ?? ''),
                              isAnime: _isAnime,
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
                              tmdbId: _detail!.id,
                              title: widget.title,
                              posterUrl: widget.posterUrl,
                              mediaType: _detail!.mediaType,
                              streamUrl: bestSource.url,
                              referer: bestSource.referer,
                              cookie: bestSource.cookie,
                            );
                            if (mounted) {
                              setState(() => _isDownloading = false);
                            }
                          } catch (e) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Download failed: $e',
                                      style: GoogleFonts.inter(fontSize: 12, color: Colors.white)),
                                  backgroundColor: AppColors.accent,
                                ),
                              );
                              setState(() => _isDownloading = false);
                            }
                          }
                        };

                        if (isDownloaded || (activeTask?.isComplete ?? false)) {
                          label = 'Downloaded ✓';
                          onTap = null;
                        } else if (activeTask != null) {
                          if (activeTask.isPaused) {
                            label = 'Paused';
                            onTap = () => DownloadService.instance.resumeTask(activeTask.tmdbId, activeTask.seasonNumber, activeTask.episodeNumber);
                          } else if (activeTask.hasError) {
                            label = 'Retry Download';
                          } else {
                            final pct = (activeTask.progress * 100).toStringAsFixed(0);
                            label = 'Downloading ($pct%) ↓';
                            onTap = () => DownloadService.instance.pauseTask(activeTask.tmdbId, activeTask.seasonNumber, activeTask.episodeNumber);
                          }
                        } else if (_isDownloading) {
                          label = 'Queued ↓';
                          onTap = null;
                        }

                        return _GhostButton(
                          label: label,
                          onTap: onTap,
                        );
                      },
                    ),
                  ] else ...[
                    const SizedBox(width: 10),
                    _GhostButton(
                      label: '↓ Download Season',
                      onTap: _onDownloadFullSeason,
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
  final int tmdbId;
  final TmdbEpisode ep;
  final VoidCallback onTap;
  final VoidCallback? onDownload;
  final bool isDownloaded;
  const _EpisodeTile({
    required this.tmdbId,
    required this.ep,
    required this.onTap,
    this.onDownload,
    this.isDownloaded = false,
  });

  @override
  State<_EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<_EpisodeTile> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final taskKey = '${widget.tmdbId}_${widget.ep.seasonNumber}_${widget.ep.episodeNumber}';

    return StreamBuilder<Map<String, DownloadTask>>(
      stream: DownloadService.instance.tasksStream,
      initialData: DownloadService.instance.tasks,
      builder: (context, snapshot) {
        final tasks = snapshot.data ?? {};
        final activeTask = tasks[taskKey];

        Widget downloadButton;
        if (activeTask != null) {
          if (activeTask.isComplete) {
            downloadButton = const Icon(Icons.check_circle_rounded, color: Color(0xFF69F0AE), size: 24);
          } else if (activeTask.isPaused) {
            downloadButton = IconButton(
              icon: const Icon(Icons.play_arrow_rounded, color: AppColors.secondary, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () => DownloadService.instance.resumeTask(activeTask.tmdbId, activeTask.seasonNumber, activeTask.episodeNumber),
            );
          } else if (activeTask.hasError) {
            downloadButton = const Icon(Icons.error_outline_rounded, color: AppColors.accent, size: 22);
          } else {
            downloadButton = SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                value: activeTask.progress,
                strokeWidth: 2,
                backgroundColor: AppColors.surfaceHigh,
                valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent),
              ),
            );
          }
        } else {
          if (widget.isDownloaded) {
            downloadButton = const Icon(Icons.check_circle_rounded, color: Color(0xFF69F0AE), size: 22);
          } else {
            downloadButton = IconButton(
              icon: const Icon(Icons.arrow_circle_down_rounded, color: AppColors.secondary, size: 22),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: widget.onDownload,
            );
          }
        }

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
                const SizedBox(width: 12),
                Icon(
                  Icons.play_circle_fill_rounded,
                  color: _h ? AppColors.accent : AppColors.tertiary.withValues(alpha: 0.5),
                  size: 26,
                ),
                const SizedBox(width: 12),
                downloadButton,
                const SizedBox(width: 8),
              ]),
            ),
          ),
        );
      },
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
  final VoidCallback? onLongPress;
  const _GhostButton({required this.label, required this.onTap, this.onLongPress});

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
        onLongPress: widget.onLongPress,
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

// ─── Provider Detail Helpers ───────────────────────────────────────────────────

extension _ProviderDetailSupport on _DetailScreenState {
  Widget _buildProviderContent() {
    final detail = _providerDetail!;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Stack(
            children: [
              _buildProviderHero(detail),
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
        if (!_isMovie && !_isProviderMovie)
          SliverList.separated(
            itemCount: detail.episodes.length,
            separatorBuilder: (_, __) => const Divider(
              height: 1, color: AppColors.cardBorder, indent: 20, endIndent: 20),
            itemBuilder: (ctx, i) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: _ProviderEpisodeTile(
                ep: detail.episodes[i],
                onTap: () => _navigateToProviderPlayer(detail.episodes[i]),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }

  Widget _buildProviderHero(ContentDetail detail) {
    final posterUrl = detail.poster ?? widget.posterUrl;
    return Stack(
      children: [
        // Backdrop
        SizedBox(
          height: 550,
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
                style: GoogleFonts.oswald(
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
              if (detail.description.isNotEmpty) ...[
                GestureDetector(
                  onTap: () => setState(() => _descExpanded = !_descExpanded),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 700),
                    child: Text(
                      detail.description,
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
              Row(
                children: [
                  _RedButton(
                    label: 'Play',
                    icon: Icons.play_arrow_rounded,
                    onTap: detail.episodes.isNotEmpty
                        ? () {
                            if (_isMovie || _isProviderMovie) {
                              _showMovieSourcesSelector(context, detail.episodes);
                            } else {
                              _navigateToProviderPlayer(detail.episodes.first);
                            }
                          }
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _navigateToProviderPlayer(Episode ep) {
    final isAnime = widget.provider?.toLowerCase() == 'anidb' ||
        widget.provider?.toLowerCase() == 'anidao';
    final isMovie = _isMovie || _isProviderMovie;
    context.push('/player', extra: <String, dynamic>{
      'tmdbId': '',
      'mediaType': isMovie ? 'movie' : '',
      'title': _providerDetail!.title,
      'year': '',
      'seasonNumber': '',
      'episodeNumber': ep.episode ?? '',
      'episodeTitle': ep.title,
      'isAnime': isAnime,
      'preloadedUrl': '',
      'episodeUrl': ep.url,
      'preloadedProvider': widget.provider,
      'showUrl': widget.providerUrl,
    });
  }

  void _showMovieSourcesSelector(BuildContext context, List<Episode> episodes) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(20.0),
                child: Row(
                  children: [
                    const Icon(Icons.layers_rounded, color: AppColors.accent, size: 22),
                    const SizedBox(width: 10),
                    Text(
                      'SELECT SOURCE',
                      style: GoogleFonts.oswald(
                        color: AppColors.primary,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.cardBorder),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: episodes.length,
                  itemBuilder: (context, idx) {
                    final ep = episodes[idx];
                    return _MovieSourceTile(
                      episode: ep,
                      onTap: () {
                        Navigator.of(context).pop();
                        _navigateToProviderPlayer(ep);
                      },
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

  Future<void> _updateBookmarkState(int tmdbId) async {
    final bookmarked = await LocalDb.instance.isBookmarked(tmdbId);
    String cat = 'Plan to Watch';
    if (bookmarked) {
      final bookmarks = await LocalDb.instance.getBookmarks();
      try {
        final b = bookmarks.firstWhere((x) => x.tmdbId == tmdbId);
        cat = b.category;
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _isBookmarked = bookmarked;
        _bookmarkCategory = cat;
      });
    }
  }

  void _showCategorySelector(BuildContext context, int tmdbId, BookmarkItem item) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        final categories = ['Plan to Watch', 'Watching', 'Completed', 'Favorites'];
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(20.0),
                child: Row(
                  children: [
                    const Icon(Icons.bookmark_added_rounded, color: AppColors.accent, size: 22),
                    const SizedBox(width: 10),
                    Text(
                      'CHOOSE CATEGORY',
                      style: GoogleFonts.oswald(
                        color: AppColors.primary,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.cardBorder),
              ...categories.map((cat) {
                final isSelected = _bookmarkCategory == cat;
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                  leading: Icon(
                    isSelected ? Icons.check_circle_rounded : Icons.radio_button_off_rounded,
                    color: isSelected ? AppColors.accent : AppColors.tertiary,
                  ),
                  title: Text(
                    cat,
                    style: GoogleFonts.inter(
                      color: AppColors.primary,
                      fontSize: 14,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  onTap: () async {
                    Navigator.of(context).pop();
                    await LocalDb.instance.updateBookmarkCategory(tmdbId, cat);
                    await _updateBookmarkState(tmdbId);
                  },
                );
              }),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }
}

// ─── Provider Episode Tile ─────────────────────────────────────────────────────

class _ProviderEpisodeTile extends StatefulWidget {
  final Episode ep;
  final VoidCallback onTap;
  const _ProviderEpisodeTile({required this.ep, required this.onTap});

  @override
  State<_ProviderEpisodeTile> createState() => _ProviderEpisodeTileState();
}

class _ProviderEpisodeTileState extends State<_ProviderEpisodeTile> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _h ? AppColors.surfaceHigh : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            const Icon(Icons.play_circle_outline_rounded, color: AppColors.accent, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  widget.ep.title.isNotEmpty ? widget.ep.title : 'Episode ${widget.ep.episode ?? ""}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    color: AppColors.primary, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                if ((widget.ep.quality ?? '').isNotEmpty || (widget.ep.size ?? '').isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (widget.ep.quality != null && widget.ep.quality!.isNotEmpty) widget.ep.quality,
                      if (widget.ep.size != null && widget.ep.size!.isNotEmpty) widget.ep.size
                    ].join(' · '),
                    style: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 11),
                  ),
                ]
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

// ─── Movie Source Tile ─────────────────────────────────────────────────────────

class _MovieSourceTile extends StatefulWidget {
  final Episode episode;
  final VoidCallback onTap;
  const _MovieSourceTile({required this.episode, required this.onTap});

  @override
  State<_MovieSourceTile> createState() => _MovieSourceTileState();
}

class _MovieSourceTileState extends State<_MovieSourceTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final ep = widget.episode;
    final hasQuality = (ep.quality ?? '').isNotEmpty;
    final hasSize = (ep.size ?? '').isNotEmpty;
    
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: _isHovered ? AppColors.surfaceHigh : Colors.transparent,
            border: const Border(
              bottom: BorderSide(color: AppColors.cardBorder, width: 0.5),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.play_circle_fill_rounded,
                color: AppColors.accent,
                size: 28,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      ep.title.isNotEmpty ? ep.title : 'Play Movie',
                      style: GoogleFonts.inter(
                        color: AppColors.primary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (hasQuality || hasSize) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (hasQuality) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceHigher,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                ep.quality!.toUpperCase(),
                                style: GoogleFonts.inter(
                                  color: AppColors.secondary,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          if (hasSize)
                            Text(
                              ep.size!,
                              style: GoogleFonts.inter(
                                color: AppColors.tertiary,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                Icons.arrow_forward_ios_rounded,
                color: _isHovered ? AppColors.secondary : AppColors.tertiary,
                size: 14,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

