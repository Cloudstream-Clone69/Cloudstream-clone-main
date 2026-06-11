// lib/core/api/search_api.dart

import '../api/api_client.dart';
import '../models/search_result.dart';

class SearchApi {
  SearchApi._();
  static final SearchApi instance = SearchApi._();

  Future<List<ProviderSection>> searchAll(String query) async {
    final resp = await ApiClient.instance.dio.get(
      '/search-all',
      queryParameters: {'q': query},
    );
    final data = resp.data as Map<String, dynamic>;
    if (data['success'] != true) throw Exception('Search API error');
    final sections = (data['sections'] as List<dynamic>)
        .map((s) {
          final map = s as Map<String, dynamic>;
          return ProviderSection(
            section: map['provider'] ?? '',
            provider: map['provider'] ?? '',
            results: ((map['results'] as List<dynamic>?) ?? [])
                .map((r) => SearchResult.fromJson(
                    r as Map<String, dynamic>, map['provider'] ?? ''))
                .toList(),
          );
        })
        .toList();
    return sections;
  }
}
