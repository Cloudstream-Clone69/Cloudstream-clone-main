// lib/core/services/local_db.dart
// Local persistent storage for watch history, bookmarks, and downloads
// Uses shared_preferences with JSON serialization

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Models ───────────────────────────────────────────────────────────────────

class WatchHistory {
  final int tmdbId;
  final String title;
  final String posterUrl;
  final String mediaType;
  final String? seasonNumber;
  final String? episodeNumber;
  final String? episodeTitle;
  int progressSeconds;
  int durationSeconds;
  final DateTime lastWatchedAt;

  WatchHistory({
    required this.tmdbId,
    required this.title,
    required this.posterUrl,
    required this.mediaType,
    this.seasonNumber,
    this.episodeNumber,
    this.episodeTitle,
    this.progressSeconds = 0,
    this.durationSeconds = 0,
    required this.lastWatchedAt,
  });

  double get progress =>
      durationSeconds > 0 ? progressSeconds / durationSeconds : 0.0;

  String get subtitle {
    if (mediaType == 'tv' && seasonNumber != null && episodeNumber != null) {
      return 'S$seasonNumber E$episodeNumber${episodeTitle != null ? ' · $episodeTitle' : ''}';
    }
    return '';
  }

  Map<String, dynamic> toJson() => {
        'tmdbId': tmdbId,
        'title': title,
        'posterUrl': posterUrl,
        'mediaType': mediaType,
        'seasonNumber': seasonNumber,
        'episodeNumber': episodeNumber,
        'episodeTitle': episodeTitle,
        'progressSeconds': progressSeconds,
        'durationSeconds': durationSeconds,
        'lastWatchedAt': lastWatchedAt.toIso8601String(),
      };

  factory WatchHistory.fromJson(Map<String, dynamic> j) => WatchHistory(
        tmdbId: j['tmdbId'] ?? 0,
        title: j['title'] ?? '',
        posterUrl: j['posterUrl'] ?? '',
        mediaType: j['mediaType'] ?? 'movie',
        seasonNumber: j['seasonNumber'],
        episodeNumber: j['episodeNumber'],
        episodeTitle: j['episodeTitle'],
        progressSeconds: j['progressSeconds'] ?? 0,
        durationSeconds: j['durationSeconds'] ?? 0,
        lastWatchedAt: DateTime.tryParse(j['lastWatchedAt'] ?? '') ?? DateTime.now(),
      );
}

class BookmarkItem {
  final int tmdbId;
  final String title;
  final String posterUrl;
  final String mediaType;
  final String overview;
  final DateTime addedAt;
  final String category;

  BookmarkItem({
    required this.tmdbId,
    required this.title,
    required this.posterUrl,
    required this.mediaType,
    required this.overview,
    required this.addedAt,
    this.category = 'Plan to Watch',
  });

  Map<String, dynamic> toJson() => {
        'tmdbId': tmdbId,
        'title': title,
        'posterUrl': posterUrl,
        'mediaType': mediaType,
        'overview': overview,
        'addedAt': addedAt.toIso8601String(),
        'category': category,
      };

  factory BookmarkItem.fromJson(Map<String, dynamic> j) => BookmarkItem(
        tmdbId: j['tmdbId'] ?? 0,
        title: j['title'] ?? '',
        posterUrl: j['posterUrl'] ?? '',
        mediaType: j['mediaType'] ?? 'movie',
        overview: j['overview'] ?? '',
        addedAt: DateTime.tryParse(j['addedAt'] ?? '') ?? DateTime.now(),
        category: j['category'] ?? 'Plan to Watch',
      );
}

class DownloadItem {
  final int tmdbId;
  final String title;
  final String posterUrl;
  final String mediaType;
  final String? seasonNumber;
  final String? episodeNumber;
  final String filePath;
  final int sizeBytes;
  final DateTime downloadedAt;

  DownloadItem({
    required this.tmdbId,
    required this.title,
    required this.posterUrl,
    required this.mediaType,
    this.seasonNumber,
    this.episodeNumber,
    required this.filePath,
    required this.sizeBytes,
    required this.downloadedAt,
  });

  String get subtitle {
    if (mediaType == 'tv' && seasonNumber != null && episodeNumber != null) {
      return 'S$seasonNumber E$episodeNumber';
    }
    return mediaType == 'movie' ? 'Movie' : 'TV Show';
  }

  String get sizeLabel {
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    if (sizeBytes < 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Map<String, dynamic> toJson() => {
        'tmdbId': tmdbId,
        'title': title,
        'posterUrl': posterUrl,
        'mediaType': mediaType,
        'seasonNumber': seasonNumber,
        'episodeNumber': episodeNumber,
        'filePath': filePath,
        'sizeBytes': sizeBytes,
        'downloadedAt': downloadedAt.toIso8601String(),
      };

  factory DownloadItem.fromJson(Map<String, dynamic> j) => DownloadItem(
        tmdbId: j['tmdbId'] ?? 0,
        title: j['title'] ?? '',
        posterUrl: j['posterUrl'] ?? '',
        mediaType: j['mediaType'] ?? 'movie',
        seasonNumber: j['seasonNumber'],
        episodeNumber: j['episodeNumber'],
        filePath: j['filePath'] ?? '',
        sizeBytes: j['sizeBytes'] ?? 0,
        downloadedAt: DateTime.tryParse(j['downloadedAt'] ?? '') ?? DateTime.now(),
      );
}

// ─── Database ──────────────────────────────────────────────────────────────────

class LocalDb {
  LocalDb._();
  static final instance = LocalDb._();

  static const _historyKey = 'watch_history_v2';
  static const _bookmarksKey = 'bookmarks_v2';
  static const _downloadsKey = 'downloads_v2';

  // ── History ────────────────────────────────────────────────────────────────

  Future<List<WatchHistory>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => WatchHistory.fromJson(e as Map<String, dynamic>)).toList()
      ..sort((a, b) => b.lastWatchedAt.compareTo(a.lastWatchedAt));
  }

  Future<WatchHistory?> getHistoryEntry(int tmdbId, {String? seasonNumber, String? episodeNumber}) async {
    final list = await getHistory();
    try {
      return list.firstWhere(
        (h) =>
            h.tmdbId == tmdbId &&
            (h.seasonNumber == seasonNumber) &&
            (h.episodeNumber == episodeNumber),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveHistory(WatchHistory entry) async {
    final list = await getHistory();
    // Remove existing entry for same tmdb/season/episode
    list.removeWhere((h) =>
        h.tmdbId == entry.tmdbId &&
        h.seasonNumber == entry.seasonNumber &&
        h.episodeNumber == entry.episodeNumber);
    // Prepend new entry
    list.insert(0, entry);
    // Keep only last 100 entries
    final trimmed = list.take(100).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_historyKey, jsonEncode(trimmed.map((e) => e.toJson()).toList()));
  }

  Future<void> updateProgress(int tmdbId, {
    String? seasonNumber,
    String? episodeNumber,
    required int progressSeconds,
    required int durationSeconds,
  }) async {
    final list = await getHistory();
    final idx = list.indexWhere((h) =>
        h.tmdbId == tmdbId &&
        h.seasonNumber == seasonNumber &&
        h.episodeNumber == episodeNumber);
    if (idx >= 0) {
      list[idx].progressSeconds = progressSeconds;
      list[idx].durationSeconds = durationSeconds;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_historyKey, jsonEncode(list.map((e) => e.toJson()).toList()));
    }
  }

  Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
  }

  /// Clear everything — history + bookmarks
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
    await prefs.remove(_bookmarksKey);
  }

  // ── Bookmarks ──────────────────────────────────────────────────────────────

  Future<List<BookmarkItem>> getBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_bookmarksKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => BookmarkItem.fromJson(e as Map<String, dynamic>)).toList()
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
  }

  Future<bool> isBookmarked(int tmdbId) async {
    final list = await getBookmarks();
    return list.any((b) => b.tmdbId == tmdbId);
  }

  Future<void> toggleBookmark(BookmarkItem item) async {
    final list = await getBookmarks();
    final exists = list.indexWhere((b) => b.tmdbId == item.tmdbId);
    if (exists >= 0) {
      list.removeAt(exists);
    } else {
      list.insert(0, item);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_bookmarksKey, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  Future<void> updateBookmarkCategory(int tmdbId, String category) async {
    final list = await getBookmarks();
    final idx = list.indexWhere((b) => b.tmdbId == tmdbId);
    if (idx >= 0) {
      final old = list[idx];
      list[idx] = BookmarkItem(
        tmdbId: old.tmdbId,
        title: old.title,
        posterUrl: old.posterUrl,
        mediaType: old.mediaType,
        overview: old.overview,
        addedAt: old.addedAt,
        category: category,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_bookmarksKey, jsonEncode(list.map((e) => e.toJson()).toList()));
    }
  }

  Future<void> clearBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_bookmarksKey);
  }

  // ── Downloads ──────────────────────────────────────────────────────────────

  Future<List<DownloadItem>> getDownloads() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_downloadsKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => DownloadItem.fromJson(e as Map<String, dynamic>)).toList()
      ..sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
  }

  Future<void> saveDownload(DownloadItem item) async {
    final list = await getDownloads();
    list.removeWhere((d) =>
        d.tmdbId == item.tmdbId &&
        d.seasonNumber == item.seasonNumber &&
        d.episodeNumber == item.episodeNumber);
    list.insert(0, item);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_downloadsKey, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  Future<void> removeDownload(DownloadItem item) async {
    final list = await getDownloads();
    list.removeWhere((d) =>
        d.tmdbId == item.tmdbId &&
        d.seasonNumber == item.seasonNumber &&
        d.episodeNumber == item.episodeNumber);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_downloadsKey, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  // ── Search History ─────────────────────────────────────────────────────────

  static const _searchHistoryKey = 'search_history_v2';

  Future<List<String>> getSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_searchHistoryKey) ?? [];
  }

  Future<void> saveSearchQuery(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final list = await getSearchHistory();
    list.removeWhere((q) => q.toLowerCase() == trimmed.toLowerCase());
    list.insert(0, trimmed);
    if (list.length > 10) {
      list.removeRange(10, list.length);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_searchHistoryKey, list);
  }

  Future<void> removeSearchQuery(String query) async {
    final list = await getSearchHistory();
    list.removeWhere((q) => q.toLowerCase() == query.toLowerCase());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_searchHistoryKey, list);
  }

  Future<void> clearSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_searchHistoryKey);
  }
}
