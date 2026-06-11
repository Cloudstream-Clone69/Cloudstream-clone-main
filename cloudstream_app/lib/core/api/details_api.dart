// lib/core/api/details_api.dart

import '../api/api_client.dart';
import '../models/content_detail.dart';

class DetailsApi {
  DetailsApi._();
  static final DetailsApi instance = DetailsApi._();

  Future<ContentDetail> getDetails(String provider, String url) async {
    final resp = await ApiClient.instance.dio.get(
      '/details',
      queryParameters: {'provider': provider, 'url': url},
    );
    final data = resp.data as Map<String, dynamic>;
    if (data['success'] != true) throw Exception('Details API error');
    return ContentDetail.fromJson(data['details'] as Map<String, dynamic>);
  }
}
