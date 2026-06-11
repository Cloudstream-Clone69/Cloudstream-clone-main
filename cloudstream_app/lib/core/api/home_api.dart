// lib/core/api/home_api.dart

import '../api/api_client.dart';
import '../models/search_result.dart';

class HomeApi {
  HomeApi._();
  static final HomeApi instance = HomeApi._();

  Future<List<ProviderSection>> getHomeSections() async {
    final resp = await ApiClient.instance.dio.get('/home');
    final data = resp.data as Map<String, dynamic>;
    if (data['success'] != true) throw Exception('Home API error');
    final sections = (data['sections'] as List<dynamic>)
        .map((s) => ProviderSection.fromJson(s as Map<String, dynamic>))
        .toList();
    return sections;
  }
}
