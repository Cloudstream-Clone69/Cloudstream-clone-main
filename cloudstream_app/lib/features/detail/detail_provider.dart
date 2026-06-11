// lib/features/detail/detail_provider.dart

import 'package:flutter/foundation.dart';
import '../../core/api/details_api.dart';
import '../../core/models/content_detail.dart';

enum DetailStatus { idle, loading, loaded, error }

class DetailProvider extends ChangeNotifier {
  DetailStatus _status = DetailStatus.idle;
  ContentDetail? _detail;
  String? _error;

  DetailStatus get status => _status;
  ContentDetail? get detail => _detail;
  String? get error => _error;

  Future<void> load(String provider, String url) async {
    _status = DetailStatus.loading;
    _detail = null;
    _error = null;
    notifyListeners();

    try {
      _detail = await DetailsApi.instance.getDetails(provider, url);
      _status = DetailStatus.loaded;
    } catch (e) {
      _error = e.toString();
      _status = DetailStatus.error;
    }
    notifyListeners();
  }

  void reset() {
    _status = DetailStatus.idle;
    _detail = null;
    _error = null;
    notifyListeners();
  }
}
