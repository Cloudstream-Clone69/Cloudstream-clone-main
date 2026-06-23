// lib/core/api/simkl_api.dart
//
// Uses SIMKL for metadata/search (accessible on Jio)
// Uses TVMaze for episode lists (free, no auth, not blocked on Jio)
//
// SIMKL API: https://simkl.docs.apiary.io/
// TVMaze API: https://www.tvmaze.com/api

import 'package:dio/dio.dart';
import '../models/tmdb_models.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

int _toInt(dynamic v) =>
    v is num ? v.toInt() : (v is String ? (int.tryParse(v) ?? 0) : 0);
double _toDouble(dynamic v) =>
    v is num ? v.toDouble() : (v is String ? (double.tryParse(v) ?? 0.0) : 0.0);
String _toStr(dynamic v) =>
    v is String ? v : (v != null ? v.toString() : '');

// ── SimklApi ──────────────────────────────────────────────────────────────────

class SimklApi {
  static const String _clientId =
      '9ef3c8edec7bb476aa8d355dc163782280b14c32fd311c38b98ca6424000ff04';

  SimklApi._();
  static final instance = SimklApi._();

  /// SIMKL: metadata, search, trending
  final Dio _simkl = Dio(BaseOptions(
    baseUrl: 'https://api.simkl.com',
    headers: {'simkl-api-key': _clientId, 'Content-Type': 'application/json'},
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
  ));

  /// TVMaze: episode lists + season structure (free, no key, follows redirects)
  final Dio _tvmaze = Dio(BaseOptions(
    baseUrl: 'https://api.tvmaze.com',
    followRedirects: true,
    maxRedirects: 3,
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
  ));

  /// Cache: simklId → imdbId (avoids re-fetching detail for episode calls)
  final Map<int, String> _imdbCache = {};
  /// Cache: imdbId → tvmazeId
  final Map<String, int> _tvmazeIdCache = {};
  /// Cache: tvmazeId → all episodes (fetched once, filtered per season)
  final Map<int, List<TmdbEpisode>> _episodeCache = {};

  // ── Image URL builders ────────────────────────────────────────────────────

  static String posterUrl(String? hash) =>
      hash != null && hash.isNotEmpty
          ? 'https://simkl.in/posters/${hash}_ca.jpg'
          : '';

  static String fanartUrl(String? hash) =>
      hash != null && hash.isNotEmpty
          ? 'https://simkl.in/fanart/${hash}_medium.jpg'
          : '';

  static String episodeImgUrl(String? hash) =>
      hash != null && hash.isNotEmpty
          ? 'https://simkl.in/episodes/${hash}_w.jpg'
          : '';

  // ── ID extraction ─────────────────────────────────────────────────────────

  /// Handles both `simkl_id` (trending/search) and `simkl` (detail/search-id)
  static int _extractSimklId(dynamic ids) {
    if (ids is! Map) return 0;
    return _toInt(ids['simkl_id'] ?? ids['simkl']);
  }

  static int _extractTmdbId(dynamic ids) {
    if (ids is! Map) return 0;
    return _toInt(ids['tmdb']);
  }

  static String _extractImdbId(dynamic ids) {
    if (ids is! Map) return '';
    return _toStr(ids['imdb']); // e.g. "tt0903747"
  }

  // ── Item mapper ───────────────────────────────────────────────────────────

  TmdbItem _toItem(Map<String, dynamic> j, {String? forceType}) {
    final ids = j['ids'];
    final simklId = _extractSimklId(ids);
    final tmdbId = _extractTmdbId(ids);

    final endpointType = _toStr(j['endpoint_type']);
    final rawType = _toStr(j['type']);
    final resolvedType =
        endpointType.isNotEmpty ? endpointType : (forceType ?? rawType);
    final mediaType =
        (resolvedType == 'movies' || resolvedType == 'movie') ? 'movie' : 'tv';
    final isAnime = resolvedType == 'anime';

    final year = _toStr(j['year']);
    final releaseRaw = _toStr(j['release_date']);
    String releaseDate = '';
    if (year.length == 4) {
      releaseDate = '$year-01-01';
    } else if (releaseRaw.length == 10) {
      final p = releaseRaw.split('/');
      if (p.length == 3) releaseDate = '${p[2]}-${p[0]}-${p[1]}';
    }

    double rating = 0.0;
    final ratings = j['ratings'];
    if (ratings is Map) {
      final sr = ratings['simkl'];
      if (sr is Map) rating = _toDouble(sr['rating']);
    }

    return TmdbItem(
      id: tmdbId > 0 ? tmdbId : simklId,
      title: _toStr(j['title']),
      posterPath: posterUrl(_toStr(j['poster'])),
      backdropPath: fanartUrl(_toStr(j['fanart'])),
      overview: _toStr(j['overview']),
      mediaType: mediaType,
      releaseDate: releaseDate,
      voteAverage: rating,
      genreIds: isAnime ? [16] : [],
      originCountry: isAnime ? ['JP'] : [],
    );
  }

  // ── Trending ──────────────────────────────────────────────────────────────

  Future<List<TmdbItem>> getTrendingAnime() =>
      _fetchList('/anime/trending', forceType: 'anime');
  Future<List<TmdbItem>> getTrendingMovies() =>
      _fetchList('/movies/trending', forceType: 'movie');
  Future<List<TmdbItem>> getTrendingTv() =>
      _fetchList('/tv/trending', forceType: 'show');

  Future<List<TmdbItem>> getPopularAnime() => getTrendingAnime();
  Future<List<TmdbItem>> getPopularMovies() => getTrendingMovies();
  Future<List<TmdbItem>> getPopularTv() => getTrendingTv();
  Future<List<TmdbItem>> getTopRatedMovies() => getTrendingMovies();
  Future<List<TmdbItem>> getTopRatedTv() => getTrendingTv();

  Future<List<TmdbItem>> _fetchList(String path, {String? forceType}) async {
    final r = await _simkl.get(path, queryParameters: {'extended': 'full'});
    if (r.statusCode == 200 && r.data is List) {
      return (r.data as List)
          .whereType<Map<String, dynamic>>()
          .map((j) => _toItem(j, forceType: forceType))
          .where((i) => i.id > 0 && i.title.isNotEmpty)
          .toList();
    }
    throw Exception('SIMKL: bad response $path → ${r.statusCode}');
  }

  // ── Search ────────────────────────────────────────────────────────────────

  Future<List<TmdbItem>> search(String query, {int limit = 20}) async {
    final lists = await Future.wait([
      _searchType('anime', query, limit ~/ 2),
      _searchType('movie', query, limit ~/ 3),
      _searchType('tv',    query, limit ~/ 3),
    ], eagerError: false);

    final seen = <int>{};
    return lists
        .expand((l) => l)
        .where((i) => i.id > 0 && seen.add(i.id))
        .toList();
  }

  Future<List<TmdbItem>> _searchType(String type, String q, int lim) async {
    try {
      final r = await _simkl.get('/search/$type',
          queryParameters: {'q': q, 'extended': 'full', 'limit': lim});
      if (r.statusCode == 200 && r.data is List) {
        return (r.data as List)
            .whereType<Map<String, dynamic>>()
            .map((j) => _toItem(j, forceType: type))
            .where((i) => i.id > 0)
            .toList();
      }
    } catch (_) {}
    return [];
  }

  // ── Details ───────────────────────────────────────────────────────────────

  /// Returns SIMKL metadata + TVMaze season list for TV shows.
  Future<TmdbDetail> getDetails(int simklId, String mediaType) async {
    final endpoints = mediaType == 'movie'
        ? ['/movies/$simklId']
        : ['/anime/$simklId', '/tv/$simklId'];

    Map<String, dynamic>? raw;
    for (final ep in endpoints) {
      try {
        final r =
            await _simkl.get(ep, queryParameters: {'extended': 'full'});
        if (r.statusCode == 200 && r.data is Map) {
          raw = r.data as Map<String, dynamic>;
          break;
        }
      } catch (_) {}
    }
    if (raw == null) {
      throw Exception('SIMKL: could not load details for id=$simklId');
    }

    // Extract IMDB ID and cache it for episode calls
    final imdbId = _extractImdbId(raw['ids']);
    if (imdbId.isNotEmpty) _imdbCache[simklId] = imdbId;

    // For TV/anime: fetch TVMaze seasons so we get proper season structure
    List<TmdbSeason> seasons = [];
    if (mediaType != 'movie' && imdbId.isNotEmpty) {
      seasons = await _tvmazeSeasons(imdbId);
    }
    if (seasons.isEmpty && mediaType != 'movie') {
      // fallback: 1 season with total episode count
      final total = _toInt(raw['total_episodes']);
      seasons = [TmdbSeason(
        id: 1, name: 'Season 1', seasonNumber: 1, episodeCount: total)];
    }

    return _toDetail(raw, mediaType, simklId, imdbId, seasons);
  }

  TmdbDetail _toDetail(
    Map<String, dynamic> j,
    String mediaType,
    int simklId,
    String imdbId,
    List<TmdbSeason> seasons,
  ) {
    final ids = j['ids'];
    final tmdbId = _extractTmdbId(ids);
    final type = _toStr(j['type']);
    final isAnime = type == 'anime';

    final year = _toStr(j['year']);
    final releaseRaw = _toStr(j['release_date']);
    String releaseDate = '';
    if (year.length == 4) {
      releaseDate = '$year-01-01';
    } else if (releaseRaw.length == 10) {
      final p = releaseRaw.split('/');
      if (p.length == 3) releaseDate = '${p[2]}-${p[0]}-${p[1]}';
    } else if (j['first_aired'] is String) {
      final fa = _toStr(j['first_aired']);
      if (fa.length >= 10) releaseDate = fa.substring(0, 10);
    }

    // Title: prefer en_title for anime
    final title = _toStr(j['en_title']).isNotEmpty
        ? _toStr(j['en_title'])
        : _toStr(j['title']);

    return TmdbDetail(
      id: tmdbId > 0 ? tmdbId : simklId,
      title: title,
      overview: _toStr(j['overview']),
      backdropPath: fanartUrl(_toStr(j['fanart'])),
      posterPath: posterUrl(_toStr(j['poster'])),
      logoPath: '',
      mediaType: mediaType,
      releaseDate: releaseDate,
      seasons: seasons,
      genreIds: isAnime ? [16] : [],
      originCountry: isAnime ? ['JP'] : [],
    );
  }

  // ── TVMaze: seasons ───────────────────────────────────────────────────────

  /// Fetch season structure from TVMaze using IMDB ID.
  Future<List<TmdbSeason>> _tvmazeSeasons(String imdbId) async {
    try {
      // Lookup show by IMDB → Dio follows 301 redirect automatically
      final showR =
          await _tvmaze.get('/lookup/shows', queryParameters: {'imdb': imdbId});
      if (showR.statusCode == 200 && showR.data is Map) {
        final tvmazeId = _toInt(showR.data['id']);
        if (tvmazeId <= 0) return [];
        _tvmazeIdCache[imdbId] = tvmazeId;

        final seasR = await _tvmaze.get('/shows/$tvmazeId/seasons');
        if (seasR.statusCode == 200 && seasR.data is List) {
          final list = <TmdbSeason>[];
          for (final s in seasR.data as List) {
            if (s is! Map) continue;
            final num = _toInt(s['number']);
            if (num <= 0) continue;
            list.add(TmdbSeason(
              id: _toInt(s['id']),
              name: _toStr(s['name']).isNotEmpty
                  ? _toStr(s['name'])
                  : 'Season $num',
              seasonNumber: num,
              episodeCount: _toInt(s['episodeOrder']),
            ));
          }
          return list;
        }
      }
    } catch (_) {}
    return [];
  }

  // ── Episodes ──────────────────────────────────────────────────────────────

  /// Loads all episodes from TVMaze, filters by season number.
  Future<List<TmdbEpisode>> getSeasonEpisodes(
      int simklId, int seasonNumber) async {
    // Resolve TVMaze show ID (using cached IMDB ID if available)
    final tvmazeId = await _resolveTvmazeId(simklId);

    if (tvmazeId > 0) {
      final eps = await _tvmazeEpisodes(tvmazeId);
      final filtered =
          eps.where((e) => e.seasonNumber == seasonNumber).toList();
      if (filtered.isNotEmpty) return filtered;
    }

    // Fallback: return numbered placeholder episodes
    return List.generate(
      12,
      (i) => TmdbEpisode(
        id: 0,
        name: 'Episode ${i + 1}',
        overview: '',
        seasonNumber: seasonNumber,
        episodeNumber: i + 1,
        stillPath: '',
      ),
    );
  }

  /// Resolve TVMaze show ID from simklId (uses cached IMDB → tvmaze chain)
  Future<int> _resolveTvmazeId(int simklId) async {
    // Try cache first
    String imdbId = _imdbCache[simklId] ?? '';

    // If no cached IMDB, fetch SIMKL detail to get it
    if (imdbId.isEmpty) {
      try {
        for (final ep in ['/anime/$simklId', '/tv/$simklId']) {
          final r = await _simkl.get(ep, queryParameters: {'extended': 'full'});
          if (r.statusCode == 200 && r.data is Map) {
            imdbId = _extractImdbId((r.data as Map)['ids']);
            if (imdbId.isNotEmpty) {
              _imdbCache[simklId] = imdbId;
              break;
            }
          }
        }
      } catch (_) {}
    }

    if (imdbId.isEmpty) return 0;

    // Check TVMaze ID cache
    if (_tvmazeIdCache.containsKey(imdbId)) return _tvmazeIdCache[imdbId]!;

    // Fetch TVMaze show by IMDB
    try {
      final r = await _tvmaze.get('/lookup/shows',
          queryParameters: {'imdb': imdbId});
      if (r.statusCode == 200 && r.data is Map) {
        final id = _toInt(r.data['id']);
        if (id > 0) {
          _tvmazeIdCache[imdbId] = id;
          return id;
        }
      }
    } catch (_) {}
    return 0;
  }

  /// Fetch all episodes from TVMaze for a show (cached).
  Future<List<TmdbEpisode>> _tvmazeEpisodes(int tvmazeId) async {
    if (_episodeCache.containsKey(tvmazeId)) return _episodeCache[tvmazeId]!;

    try {
      final r = await _tvmaze.get('/shows/$tvmazeId/episodes',
          queryParameters: {'specials': 0});
      if (r.statusCode == 200 && r.data is List) {
        final list = (r.data as List)
            .whereType<Map<String, dynamic>>()
            .map((e) {
              final imgMed = e['image'] is Map
                  ? _toStr(e['image']['medium'])
                  : '';
              return TmdbEpisode(
                id: _toInt(e['id']),
                name: _toStr(e['name']).isNotEmpty
                    ? _toStr(e['name'])
                    : 'Episode ${_toInt(e["number"])}',
                overview: _toStr(e['summary'] != null
                    ? e['summary'].toString().replaceAll(RegExp(r'<[^>]*>'), '')
                    : ''),
                seasonNumber: _toInt(e['season']),
                episodeNumber: _toInt(e['number']),
                stillPath: imgMed,
              );
            })
            .toList();
        _episodeCache[tvmazeId] = list;
        return list;
      }
    } catch (_) {}
    return [];
  }

  // ── TMDB ID → SIMKL ID lookup ─────────────────────────────────────────────

  Future<int> simklIdFromTmdb(int tmdbId, String mediaType) async {
    try {
      final r = await _simkl.get('/search/id', queryParameters: {
        'tmdb': tmdbId,
        'type': mediaType == 'movie' ? 'movie' : 'show',
      });
      if (r.statusCode == 200 && r.data is List) {
        for (final item in r.data as List) {
          if (item is Map) {
            final sid = _extractSimklId(item['ids']);
            if (sid > 0) return sid;
          }
        }
      }
    } catch (_) {}
    return 0;
  }
}
