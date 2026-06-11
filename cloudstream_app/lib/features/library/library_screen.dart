// lib/features/library/library_screen.dart
// Library: Bookmarks | History | Downloads

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/services/local_db.dart';
import '../../core/services/download_service.dart';
import '../../shared/theme/app_theme.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Row(children: [
            Text('Library',
                style: GoogleFonts.inter(
                    color: AppColors.primary,
                    fontSize: 22,
                    fontWeight: FontWeight.w800)),
            const Spacer(),
          ]),
        ),
        const SizedBox(height: 12),
        // Tabs
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(10),
          ),
          child: TabBar(
            controller: _tab,
            indicator: BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(9),
            ),
            indicatorSize: TabBarIndicatorSize.tab,
            dividerColor: Colors.transparent,
            labelColor: Colors.white,
            unselectedLabelColor: AppColors.tertiary,
            labelStyle: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700),
            unselectedLabelStyle: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
            tabs: const [
              Tab(text: 'Bookmarks'),
              Tab(text: 'History'),
              Tab(text: 'Downloads'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: const [
              _BookmarksTab(),
              _HistoryTab(),
              _DownloadsTab(),
            ],
          ),
        ),
      ]),
    );
  }
}

// ─── Bookmarks ─────────────────────────────────────────────────────────────────

class _BookmarksTab extends StatefulWidget {
  const _BookmarksTab();

  @override
  State<_BookmarksTab> createState() => _BookmarksTabState();
}

class _BookmarksTabState extends State<_BookmarksTab> {
  List<BookmarkItem>? _bookmarks;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = await LocalDb.instance.getBookmarks();
    if (mounted) setState(() => _bookmarks = b);
  }

  @override
  Widget build(BuildContext context) {
    if (_bookmarks == null) return const _Loading();
    if (_bookmarks!.isEmpty) return const _Empty(icon: Icons.bookmark_border_rounded, label: 'No bookmarks yet');

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        childAspectRatio: 110 / 190,
        crossAxisSpacing: 10,
        mainAxisSpacing: 16,
      ),
      itemCount: _bookmarks!.length,
      itemBuilder: (_, i) {
        final b = _bookmarks![i];
        return _MediaCard(
          title: b.title,
          posterUrl: b.posterUrl,
          badge: b.mediaType == 'tv' ? 'TV' : 'Movie',
          onTap: () => context.push('/detail', extra: {
            'id': b.tmdbId,
            'mediaType': b.mediaType,
            'title': b.title,
            'poster': b.posterUrl,
            'backdrop': '',
            'overview': b.overview,
            'releaseDate': '',
          }),
          onLongPress: () async {
            await LocalDb.instance.toggleBookmark(BookmarkItem(
              tmdbId: b.tmdbId, title: b.title, posterUrl: b.posterUrl,
              mediaType: b.mediaType, overview: b.overview, addedAt: b.addedAt,
            ));
            _load();
          },
        );
      },
    );
  }
}

// ─── History ───────────────────────────────────────────────────────────────────

class _HistoryTab extends StatefulWidget {
  const _HistoryTab();

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> {
  List<WatchHistory>? _history;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final h = await LocalDb.instance.getHistory();
    if (mounted) setState(() => _history = h);
  }

  @override
  Widget build(BuildContext context) {
    if (_history == null) return const _Loading();
    if (_history!.isEmpty) return const _Empty(icon: Icons.history_rounded, label: 'No watch history yet');

    return Column(children: [
      // Clear button
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Text('${_history!.length} items',
              style: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 12)),
          const Spacer(),
          TextButton.icon(
            onPressed: () async {
              await LocalDb.instance.clearHistory();
              _load();
            },
            icon: const Icon(Icons.delete_outline_rounded, size: 16, color: AppColors.accent),
            label: Text('Clear All', style: GoogleFonts.inter(color: AppColors.accent, fontSize: 12)),
          ),
        ]),
      ),
      const SizedBox(height: 4),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: _history!.length,
          itemBuilder: (_, i) {
            final h = _history![i];
            return _HistoryTile(
              item: h,
              onTap: () => context.push('/player', extra: {
                'tmdbId': h.tmdbId.toString(),
                'mediaType': h.mediaType,
                'title': h.title,
                'year': '',
                'seasonNumber': h.seasonNumber ?? '',
                'episodeNumber': h.episodeNumber ?? '',
                'episodeTitle': h.episodeTitle ?? '',
              }),
              onRemove: () async {
                final list = await LocalDb.instance.getHistory();
                list.removeWhere((x) =>
                    x.tmdbId == h.tmdbId &&
                    x.seasonNumber == h.seasonNumber &&
                    x.episodeNumber == h.episodeNumber);
                // Rebuild prefs
                await LocalDb.instance.clearHistory();
                for (final item in list) {
                  await LocalDb.instance.saveHistory(item);
                }
                _load();
              },
            );
          },
        ),
      ),
    ]);
  }
}

class _HistoryTile extends StatefulWidget {
  final WatchHistory item;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  const _HistoryTile({required this.item, required this.onTap, required this.onRemove});

  @override
  State<_HistoryTile> createState() => _HistoryTileState();
}

class _HistoryTileState extends State<_HistoryTile> {
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
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _h ? AppColors.surfaceHigh : AppColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.cardBorder, width: 0.5),
          ),
          child: Row(children: [
            // Poster
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: widget.item.posterUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: widget.item.posterUrl,
                      width: 48, height: 68, fit: BoxFit.cover,
                    )
                  : Container(
                      width: 48, height: 68,
                      color: AppColors.surfaceHigh,
                      child: const Icon(Icons.movie_outlined, color: AppColors.tertiary, size: 20),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.item.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                        color: AppColors.primary, fontSize: 14, fontWeight: FontWeight.w600)),
                if (widget.item.subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(widget.item.subtitle,
                      style: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 12)),
                ],
                const SizedBox(height: 6),
                // Progress bar
                if (widget.item.durationSeconds > 0) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: widget.item.progress.clamp(0.0, 1.0),
                      minHeight: 3,
                      backgroundColor: AppColors.surfaceHigh,
                      valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_fmt(Duration(seconds: widget.item.progressSeconds))} / ${_fmt(Duration(seconds: widget.item.durationSeconds))}',
                    style: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 10),
                  ),
                ],
              ]),
            ),
            const SizedBox(width: 8),
            // Resume button
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.play_arrow_rounded, color: AppColors.accent, size: 18),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: widget.onRemove,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(Icons.close_rounded, color: AppColors.tertiary, size: 15),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) return '${d.inHours}:$m:$s';
    return '$m:$s';
  }
}

// ─── Downloads ─────────────────────────────────────────────────────────────────

class _DownloadsTab extends StatefulWidget {
  const _DownloadsTab();

  @override
  State<_DownloadsTab> createState() => _DownloadsTabState();
}

class _DownloadsTabState extends State<_DownloadsTab> {
  List<DownloadItem>? _downloads;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await LocalDb.instance.getDownloads();
    if (mounted) setState(() => _downloads = d);
  }

  @override
  Widget build(BuildContext context) {
    final activeTasks = DownloadService.instance.tasks;

    return StreamBuilder<Map<String, DownloadTask>>(
      stream: DownloadService.instance.tasksStream,
      initialData: activeTasks,
      builder: (_, snap) {
        final tasks = snap.data ?? {};

        return Column(children: [
          // Active downloads
          if (tasks.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Downloading (${tasks.length})',
                  style: GoogleFonts.inter(
                      color: AppColors.tertiary, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
            ...tasks.values.map((t) => _ActiveDownloadTile(task: t)),
            const SizedBox(height: 12),
          ],

          // Completed downloads
          if (_downloads == null)
            const Expanded(child: _Loading())
          else if (_downloads!.isEmpty && tasks.isEmpty)
            const Expanded(child: _Empty(icon: Icons.download_outlined, label: 'No downloads yet'))
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _downloads?.length ?? 0,
                itemBuilder: (_, i) {
                  final d = _downloads![i];
                  return _DownloadTile(
                    item: d,
                    onDelete: () async {
                      // Delete file
                      try { await File(d.filePath).delete(); } catch (_) {}
                      await LocalDb.instance.removeDownload(d);
                      _load();
                    },
                  );
                },
              ),
            ),
        ]);
      },
    );
  }
}

class _ActiveDownloadTile extends StatelessWidget {
  final DownloadTask task;
  const _ActiveDownloadTile({required this.task});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.3), width: 0.5),
      ),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: task.posterUrl.isNotEmpty
              ? CachedNetworkImage(imageUrl: task.posterUrl, width: 42, height: 60, fit: BoxFit.cover)
              : Container(width: 42, height: 60, color: AppColors.surfaceHigh),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(task.title,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(color: AppColors.primary, fontSize: 13, fontWeight: FontWeight.w600)),
            if (task.hasError)
              Text('Error: ${task.errorMessage}',
                  style: GoogleFonts.inter(color: AppColors.accent, fontSize: 11))
            else if (task.isComplete)
              Text('Complete ✓',
                  style: GoogleFonts.inter(color: const Color(0xFF69F0AE), fontSize: 11))
            else ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: task.progress,
                backgroundColor: AppColors.surfaceHigh,
                valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent),
              ),
              const SizedBox(height: 4),
              Text('${(task.progress * 100).toStringAsFixed(1)}%',
                  style: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 10)),
            ],
          ]),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => DownloadService.instance.cancel(
              task.tmdbId, task.seasonNumber, task.episodeNumber),
          child: const Icon(Icons.close_rounded, color: AppColors.tertiary, size: 18),
        ),
      ]),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  final DownloadItem item;
  final VoidCallback onDelete;
  const _DownloadTile({required this.item, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.cardBorder, width: 0.5),
      ),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: item.posterUrl.isNotEmpty
              ? CachedNetworkImage(imageUrl: item.posterUrl, width: 42, height: 60, fit: BoxFit.cover)
              : Container(width: 42, height: 60, color: AppColors.surfaceHigh,
                  child: const Icon(Icons.movie_outlined, color: AppColors.tertiary, size: 18)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.title,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(color: AppColors.primary, fontSize: 13, fontWeight: FontWeight.w600)),
            Text(item.subtitle,
                style: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 11)),
            const SizedBox(height: 2),
            Text(item.sizeLabel,
                style: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 10)),
          ]),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: const Color(0xFF69F0AE).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Icon(Icons.download_done_rounded, color: Color(0xFF69F0AE), size: 16),
        ),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: onDelete,
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(Icons.delete_outline_rounded, color: AppColors.accent, size: 16),
          ),
        ),
      ]),
    );
  }
}

// ─── Shared small widgets ──────────────────────────────────────────────────────

class _MediaCard extends StatefulWidget {
  final String title;
  final String posterUrl;
  final String badge;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _MediaCard({required this.title, required this.posterUrl, required this.badge,
      required this.onTap, this.onLongPress});
  @override State<_MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<_MediaCard> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          transform: _h ? (Matrix4.identity()..scale(1.04)) : Matrix4.identity(),
          transformAlignment: Alignment.center,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(fit: StackFit.expand, children: [
                  widget.posterUrl.isNotEmpty
                      ? CachedNetworkImage(imageUrl: widget.posterUrl, fit: BoxFit.cover)
                      : Container(color: AppColors.surfaceHigh,
                          child: const Icon(Icons.movie_outlined, color: AppColors.tertiary, size: 28)),
                  Positioned(top: 6, right: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(widget.badge,
                          style: GoogleFonts.inter(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 5),
            Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                    color: _h ? AppColors.primary : AppColors.secondary,
                    fontSize: 11, fontWeight: FontWeight.w500, height: 1.3)),
          ]),
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) => const Center(
    child: CircularProgressIndicator(color: AppColors.accent, strokeWidth: 2),
  );
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Empty({required this.icon, required this.label});
  @override
  Widget build(BuildContext context) => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: AppColors.tertiary, size: 52),
      const SizedBox(height: 14),
      Text(label, style: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 14)),
    ]),
  );
}
