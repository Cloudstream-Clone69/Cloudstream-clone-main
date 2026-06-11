// lib/core/models/search_result.dart

class SearchResult {
  final String title;
  final String? poster;
  final String url;
  final String provider;

  const SearchResult({
    required this.title,
    this.poster,
    required this.url,
    required this.provider,
  });

  factory SearchResult.fromJson(Map<String, dynamic> json, String provider) {
    return SearchResult(
      title: json['title'] ?? '',
      poster: json['poster'],
      url: json['url'] ?? '',
      provider: json['provider'] ?? provider,
    );
  }
}

class ProviderSection {
  final String section;
  final String provider;
  final List<SearchResult> results;

  const ProviderSection({
    required this.section,
    required this.provider,
    required this.results,
  });

  factory ProviderSection.fromJson(Map<String, dynamic> json) {
    final provider = json['provider'] ?? '';
    final rawResults = (json['results'] as List<dynamic>?) ?? [];
    return ProviderSection(
      section: json['section'] ?? json['provider'] ?? '',
      provider: provider,
      results: rawResults
          .map((r) => SearchResult.fromJson(r as Map<String, dynamic>, provider))
          .toList(),
    );
  }
}
