// lib/features/home/home_provider.dart
// Uses SIMKL API instead of TMDB — accessible on Jio without DNS workarounds.

import 'package:flutter/foundation.dart';
import '../../core/api/simkl_api.dart';
import '../../core/models/tmdb_models.dart';
import '../../core/services/local_db.dart';

enum HomeStatus { idle, loading, loaded, error }

class HomeSection {
  final String title;
  final String icon;
  final List<TmdbItem> items;
  HomeSection(this.title, this.icon, this.items);
}

class HomeProvider extends ChangeNotifier {
  HomeStatus _status = HomeStatus.idle;
  List<HomeSection> _sections = [];
  List<WatchHistory> _continueWatching = [];
  String? _error;

  HomeStatus get status => _status;
  List<HomeSection> get sections => _sections;
  List<WatchHistory> get continueWatching => _continueWatching;
  String? get error => _error;

  TmdbItem? get featuredItem {
    for (final s in _sections) {
      if (s.items.isNotEmpty) return s.items.first;
    }
    return null;
  }

  Future<void> load() async {
    if (_status == HomeStatus.loading) return;
    _status = HomeStatus.loading;
    _error = null;
    notifyListeners();

    const maxAttempts = 3;
    const retryDelay = Duration(seconds: 2);

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        // Load continue watching first (local, always fast)
        _continueWatching = await LocalDb.instance.getHistory();
        _continueWatching = _continueWatching
            .where((h) => h.progressSeconds > 30 && h.progress < 0.95)
            .take(20)
            .toList();

        // Load all SIMKL sections in parallel
        final results = await Future.wait([
          SimklApi.instance.getTrendingMovies(),   // [0]
          SimklApi.instance.getTrendingTv(),        // [1]
          SimklApi.instance.getTrendingAnime(),     // [2]
          SimklApi.instance.getPopularAnime(),      // [3] alias → trending anime
          SimklApi.instance.getTopRatedMovies(),    // [4] alias → trending movies
          SimklApi.instance.getTopRatedTv(),        // [5] alias → trending tv
        ]);

        _sections = [
          if (results[0].isNotEmpty) HomeSection('🔥 Trending Movies',    '🔥', results[0]),
          if (results[1].isNotEmpty) HomeSection('📺 Trending TV Shows',  '📺', results[1]),
          if (results[2].isNotEmpty) HomeSection('🎌 Popular Anime',      '🎌', results[2]),
          if (results[3].isNotEmpty) HomeSection('⭐ Top Anime',          '⭐', results[3]),
          if (results[4].isNotEmpty) HomeSection('🏆 Top Rated Movies',   '🏆', results[4]),
          if (results[5].isNotEmpty) HomeSection('🌟 Top Rated TV Shows', '🌟', results[5]),
        ];

        _status = HomeStatus.loaded;
        notifyListeners();
        return;
      } catch (e) {
        debugPrint('[HomeProvider] attempt $attempt failed: $e');
        if (attempt < maxAttempts) {
          await Future.delayed(retryDelay);
        } else {
          _error = e.toString();
          _status = HomeStatus.error;
          notifyListeners();
        }
      }
    }
  }

  Future<void> refreshContinueWatching() async {
    final hist = await LocalDb.instance.getHistory();
    _continueWatching = hist
        .where((h) => h.progressSeconds > 30 && h.progress < 0.95)
        .take(20)
        .toList();
    notifyListeners();
  }

  void refresh() {
    _status = HomeStatus.idle;
    _sections = [];
    _error = null;
    load();
  }
}
