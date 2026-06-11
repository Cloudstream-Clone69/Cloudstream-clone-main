// lib/features/search/search_provider.dart

import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../core/api/simkl_api.dart';
import '../../core/models/tmdb_models.dart';

enum SearchStatus { idle, loading, loaded, error }

class SearchProvider extends ChangeNotifier {
  SearchStatus _status = SearchStatus.idle;
  List<TmdbItem> _results = [];
  String? _error;
  String _query = '';
  Timer? _debounce;

  SearchStatus get status => _status;
  List<TmdbItem> get results => _results;
  String? get error => _error;
  String get query => _query;

  void onQueryChanged(String q) {
    _query = q;
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      _status = SearchStatus.idle;
      _results = [];
      notifyListeners();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(q.trim()));
  }

  Future<void> _search(String q) async {
    _status = SearchStatus.loading;
    notifyListeners();
    try {
      _results = await SimklApi.instance.search(q);
      _status = SearchStatus.loaded;
    } catch (e) {
      _error = e.toString();
      _status = SearchStatus.error;
    }
    notifyListeners();
  }

  void clear() {
    _query = '';
    _results = [];
    _status = SearchStatus.idle;
    _debounce?.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
