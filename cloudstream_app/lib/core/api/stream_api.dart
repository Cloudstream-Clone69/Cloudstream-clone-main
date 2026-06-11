// lib/core/api/stream_api.dart

import 'package:dio/dio.dart';
import '../api/api_client.dart';
import '../models/stream_info.dart';

class StreamApi {
  StreamApi._();
  static final StreamApi instance = StreamApi._();

  Future<StreamInfo> getStream(String provider, String url) async {
    final resp = await ApiClient.instance.dio.get(
      '/stream',
      queryParameters: {'provider': provider, 'url': url},
      options: Options(receiveTimeout: const Duration(seconds: 120)),
    );
    final data = resp.data as Map<String, dynamic>;
    if (data['success'] != true) throw Exception('Stream API error');
    return StreamInfo.fromJson(data['streams'] as Map<String, dynamic>);
  }
}
