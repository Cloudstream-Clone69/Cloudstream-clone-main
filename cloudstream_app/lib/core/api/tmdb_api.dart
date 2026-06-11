// lib/core/api/tmdb_api.dart

import 'package:dio/dio.dart';
import '../models/tmdb_models.dart';

class TmdbApi {
  static const String _baseUrl = 'https://api.themoviedb.org/3';
  static const String _accessToken =
      'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJjZTM2NmI5OWI3NGI2ZjU1YjA0Y2M1ODc1NmIxOTc3MSIsIm5iZiI6MTc4MDQxNzkwMi4yNDk5OTk4LCJzdWIiOiI2YTFmMDU2ZTg4ZDU2ZDA5ZDgyNTBmYTgiLCJzY29wZXMiOlsiYXBpX3JlYWQiXSwidmVyc2lvbiI6MX0.qYBt851P-6o-o75v_R51Ihfb4jV-64vLw1nD_9OtEqQ';

  TmdbApi._();
  static final instance = TmdbApi._();

  final Dio _dio = Dio(BaseOptions(
    baseUrl: _baseUrl,
    headers: {
      'Authorization': 'Bearer $_accessToken',
      'accept': 'application/json',
    },
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
  ));

  Future<List<TmdbItem>> getTrendingMovies() async {
    final r = await _dio.get('/trending/movie/day?language=en-US');
    return _parseItems(r, 'movie');
  }

  Future<List<TmdbItem>> getTrendingTv() async {
    final r = await _dio.get('/trending/tv/day?language=en-US');
    return _parseItems(r, 'tv');
  }

  Future<List<TmdbItem>> getTopRatedMovies() async {
    final r = await _dio.get('/movie/top_rated?language=en-US&page=1');
    return _parseItems(r, 'movie');
  }

  Future<List<TmdbItem>> getTopRatedTv() async {
    final r = await _dio.get('/tv/top_rated?language=en-US&page=1');
    return _parseItems(r, 'tv');
  }

  Future<List<TmdbItem>> getPopularMovies() async {
    final r = await _dio.get('/movie/popular?language=en-US&page=1');
    return _parseItems(r, 'movie');
  }

  Future<List<TmdbItem>> getPopularTv() async {
    final r = await _dio.get('/tv/popular?language=en-US&page=1');
    return _parseItems(r, 'tv');
  }

  Future<List<TmdbItem>> getNowPlayingMovies() async {
    final r = await _dio.get('/movie/now_playing?language=en-US&page=1');
    return _parseItems(r, 'movie');
  }

  /// Popular Anime — TV genre 16 (Animation) with Japanese origin
  Future<List<TmdbItem>> getPopularAnime() async {
    final r = await _dio.get(
        '/discover/tv?with_genres=16&with_origin_country=JP&sort_by=popularity.desc&language=en-US&page=1');
    return _parseItems(r, 'tv');
  }

  /// Top Rated Anime
  Future<List<TmdbItem>> getTopRatedAnime() async {
    final r = await _dio.get(
        '/discover/tv?with_genres=16&with_origin_country=JP&sort_by=vote_average.desc&vote_count.gte=500&language=en-US&page=1');
    return _parseItems(r, 'tv');
  }

  /// Action movies
  Future<List<TmdbItem>> getActionMovies() async {
    final r = await _dio.get(
        '/discover/movie?with_genres=28&sort_by=popularity.desc&language=en-US&page=1');
    return _parseItems(r, 'movie');
  }

  /// Upcoming movies
  Future<List<TmdbItem>> getUpcomingMovies() async {
    final r = await _dio.get('/movie/upcoming?language=en-US&page=1');
    return _parseItems(r, 'movie');
  }

  Future<List<TmdbItem>> search(String query) async {
    final encoded = Uri.encodeQueryComponent(query);
    final r = await _dio.get(
        '/search/multi?query=$encoded&include_adult=false&language=en-US&page=1');
    if (r.statusCode == 200) {
      final results = r.data['results'] as List;
      return results
          .where((e) => e['media_type'] == 'movie' || e['media_type'] == 'tv')
          .map((e) => TmdbItem.fromJson(e))
          .toList();
    }
    throw Exception('Failed to search TMDB');
  }

  Future<TmdbDetail> getDetails(int id, String mediaType) async {
    final r = await _dio.get('/$mediaType/$id?language=en-US&append_to_response=images&include_image_language=en,null');
    if (r.statusCode == 200) return TmdbDetail.fromJson(r.data, mediaType);
    throw Exception('Failed to load TMDB details');
  }

  Future<List<TmdbEpisode>> getSeasonEpisodes(int seriesId, int seasonNumber) async {
    final r = await _dio.get('/tv/$seriesId/season/$seasonNumber?language=en-US');
    if (r.statusCode == 200) {
      final episodes = r.data['episodes'] as List;
      return episodes.map((e) => TmdbEpisode.fromJson(e)).toList();
    }
    throw Exception('Failed to load season episodes');
  }

  List<TmdbItem> _parseItems(Response r, String defaultType) {
    if (r.statusCode == 200) {
      final results = r.data['results'] as List;
      return results
          .map((e) => TmdbItem.fromJson(e, defaultMediaType: defaultType))
          .toList();
    }
    throw Exception('Failed to load TMDB data');
  }
}
