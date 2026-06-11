// lib/core/models/content_detail.dart

class Episode {
  final String title;
  final String url;
  final String? episode;
  final String? quality;
  final String? size;

  const Episode({
    required this.title,
    required this.url,
    this.episode,
    this.quality,
    this.size,
  });

  factory Episode.fromJson(Map<String, dynamic> json) {
    return Episode(
      title: json['title'] ?? '',
      url: json['url'] ?? '',
      episode: json['episode']?.toString(),
      quality: json['quality'],
      size: json['size'],
    );
  }

  String get displayTitle {
    if (episode != null && episode!.isNotEmpty) return episode!;
    return title;
  }
}

class ContentDetail {
  final String title;
  final String? poster;
  final String description;
  final List<Episode> episodes;

  const ContentDetail({
    required this.title,
    this.poster,
    required this.description,
    required this.episodes,
  });

  factory ContentDetail.fromJson(Map<String, dynamic> json) {
    final rawEps = (json['episodes'] as List<dynamic>?) ?? [];
    return ContentDetail(
      title: json['title'] ?? '',
      poster: json['poster'],
      description: json['description'] ?? '',
      episodes:
          rawEps.map((e) => Episode.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }
}
