// lib/core/models/tmdb_models.dart

class TmdbItem {
  final int id;
  final String title;
  final String posterPath;
  final String backdropPath;
  final String overview;
  final String mediaType; // 'movie' or 'tv'
  final String releaseDate;
  final double voteAverage;
  final List<int> genreIds;
  final List<String> originCountry;

  TmdbItem({
    required this.id,
    required this.title,
    required this.posterPath,
    required this.backdropPath,
    required this.overview,
    required this.mediaType,
    required this.releaseDate,
    required this.voteAverage,
    this.genreIds = const [],
    this.originCountry = const [],
  });

  factory TmdbItem.fromJson(Map<String, dynamic> json, {String defaultMediaType = 'movie'}) {
    return TmdbItem(
      id: json['id'] ?? 0,
      title: json['title'] ?? json['name'] ?? '',
      posterPath: json['poster_path'] ?? '',
      backdropPath: json['backdrop_path'] ?? '',
      overview: json['overview'] ?? '',
      mediaType: json['media_type'] ?? defaultMediaType,
      releaseDate: json['release_date'] ?? json['first_air_date'] ?? '',
      voteAverage: (json['vote_average'] ?? 0.0).toDouble(),
      genreIds: List<int>.from(json['genre_ids'] ?? []),
      originCountry: List<String>.from(json['origin_country'] ?? []),
    );
  }

  /// Handles both TMDB paths (/abc.jpg) and full SIMKL URLs (https://...)
  String get posterUrl {
    if (posterPath.isEmpty) return '';
    if (posterPath.startsWith('http')) return posterPath;
    return 'https://image.tmdb.org/t/p/w500$posterPath';
  }

  String get backdropUrl {
    if (backdropPath.isEmpty) return '';
    if (backdropPath.startsWith('http')) return backdropPath;
    return 'https://image.tmdb.org/t/p/w1280$backdropPath';
  }

  String get year => releaseDate.isNotEmpty ? releaseDate.substring(0, 4) : '';

  /// True if this is a Japanese animated show (anime).
  bool get isAnime => genreIds.contains(16) && originCountry.contains('JP');
}

class TmdbDetail {
  final int id;
  final String title;
  final String overview;
  final String backdropPath;
  final String posterPath;
  final String logoPath;
  final String mediaType;
  final String releaseDate;
  final List<TmdbSeason> seasons;
  final List<int> genreIds;
  final List<String> originCountry;

  TmdbDetail({
    required this.id,
    required this.title,
    required this.overview,
    required this.backdropPath,
    required this.posterPath,
    required this.logoPath,
    required this.mediaType,
    required this.releaseDate,
    required this.seasons,
    this.genreIds = const [],
    this.originCountry = const [],
  });

  factory TmdbDetail.fromJson(Map<String, dynamic> json, String type) {
    var seasonsList = <TmdbSeason>[];
    if (json['seasons'] != null) {
      for (var s in json['seasons']) {
        if (s['season_number'] != null && s['season_number'] > 0) {
          seasonsList.add(TmdbSeason.fromJson(s));
        }
      }
    }
    final genres = (json['genres'] as List?) ?? [];
    final genreIds = genres.map<int>((g) => (g['id'] as num).toInt()).toList();
    final originCountry = List<String>.from(json['origin_country'] ?? []);

    String logoPath = '';
    if (json['images'] != null && json['images']['logos'] != null) {
      final logosList = json['images']['logos'] as List;
      if (logosList.isNotEmpty) {
        final enLogo = logosList.firstWhere(
          (l) => l['iso_639_1'] == 'en',
          orElse: () => logosList.first,
        );
        logoPath = enLogo['file_path'] ?? '';
      }
    }

    return TmdbDetail(
      id: json['id'] ?? 0,
      title: json['title'] ?? json['name'] ?? '',
      overview: json['overview'] ?? '',
      backdropPath: json['backdrop_path'] ?? '',
      posterPath: json['poster_path'] ?? '',
      logoPath: logoPath,
      mediaType: type,
      releaseDate: json['release_date'] ?? json['first_air_date'] ?? '',
      seasons: seasonsList,
      genreIds: genreIds,
      originCountry: originCountry,
    );
  }

  /// Handles both TMDB paths and full SIMKL URLs
  String get backdropUrl {
    if (backdropPath.isEmpty) return '';
    if (backdropPath.startsWith('http')) return backdropPath;
    return 'https://image.tmdb.org/t/p/w1280$backdropPath';
  }

  String get posterUrl {
    if (posterPath.isEmpty) return '';
    if (posterPath.startsWith('http')) return posterPath;
    return 'https://image.tmdb.org/t/p/w500$posterPath';
  }

  String get logoUrl {
    if (logoPath.isEmpty) return '';
    if (logoPath.startsWith('http')) return logoPath;
    return 'https://image.tmdb.org/t/p/w500$logoPath';
  }

  String get year => releaseDate.isNotEmpty ? releaseDate.substring(0, 4) : '';

  bool get isAnime => genreIds.contains(16) && originCountry.contains('JP');
}

class TmdbSeason {
  final int id;
  final String name;
  final int seasonNumber;
  final int episodeCount;

  TmdbSeason({
    required this.id,
    required this.name,
    required this.seasonNumber,
    required this.episodeCount,
  });

  factory TmdbSeason.fromJson(Map<String, dynamic> json) {
    return TmdbSeason(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      seasonNumber: json['season_number'] ?? 0,
      episodeCount: json['episode_count'] ?? 0,
    );
  }
}

class TmdbEpisode {
  final int id;
  final String name;
  final String overview;
  final int seasonNumber;
  final int episodeNumber;
  final String stillPath;

  TmdbEpisode({
    required this.id,
    required this.name,
    required this.overview,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.stillPath,
  });

  factory TmdbEpisode.fromJson(Map<String, dynamic> json) {
    return TmdbEpisode(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      overview: json['overview'] ?? '',
      seasonNumber: json['season_number'] ?? 0,
      episodeNumber: json['episode_number'] ?? 0,
      stillPath: json['still_path'] ?? '',
    );
  }

  /// Handles both TMDB paths and full SIMKL URLs
  String get stillUrl {
    if (stillPath.isEmpty) return '';
    if (stillPath.startsWith('http')) return stillPath;
    return 'https://image.tmdb.org/t/p/w500$stillPath';
  }
}
