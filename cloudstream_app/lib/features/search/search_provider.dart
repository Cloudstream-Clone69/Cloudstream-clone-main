// lib/features/search/search_provider.dart

import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../core/api/search_api.dart';
import '../../core/models/search_result.dart';
import '../../core/services/app_settings.dart';
import '../../core/services/local_db.dart';

enum SearchStatus { idle, loading, loaded, error }

class SearchProvider extends ChangeNotifier {
  SearchStatus _status = SearchStatus.idle;
  List<ProviderSection> _results = [];
  String? _error;
  String _query = '';
  Timer? _debounce;
  
  List<String> _history = [];
  List<String> _suggestions = [];

  SearchStatus get status => _status;
  List<ProviderSection> get results => _results;
  String? get error => _error;
  String get query => _query;
  List<String> get history => _history;
  List<String> get suggestions => _suggestions;

  SearchProvider() {
    loadHistory();
  }

  Future<void> loadHistory() async {
    _history = await LocalDb.instance.getSearchHistory();
    notifyListeners();
  }

  void onQueryChanged(String q) {
    _query = q;
    _debounce?.cancel();
    _updateSuggestions(q);
    if (q.trim().isEmpty) {
      _status = SearchStatus.idle;
      _results = [];
      notifyListeners();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(q.trim()));
  }

  Future<void> executeSearch(String q) async {
    _query = q;
    _debounce?.cancel();
    _updateSuggestions(q);
    await _search(q.trim());
  }

  Future<void> _updateSuggestions(String q) async {
    if (q.trim().isEmpty) {
      _suggestions = [];
      notifyListeners();
      return;
    }
    final qLower = q.toLowerCase();
    
    // 1. Matches in history
    final historyMatches = _history.where((s) => s.toLowerCase().contains(qLower)).toList();
    
    // 2. Matches in bookmarks
    final bookmarks = await LocalDb.instance.getBookmarks();
    final bookmarkMatches = bookmarks
        .map((b) => b.title)
        .where((title) => title.toLowerCase().contains(qLower))
        .toList();
        
    // 3. Matches in watch history
    final watchHistory = await LocalDb.instance.getHistory();
    final watchMatches = watchHistory
        .map((h) => h.title)
        .where((title) => title.toLowerCase().contains(qLower))
        .toList();

    final combined = <String>{
      ...historyMatches,
      ...bookmarkMatches,
      ...watchMatches,
    }.toList();
    
    if (combined.length > 5) {
      _suggestions = combined.sublist(0, 5);
    } else {
      _suggestions = combined;
    }
    notifyListeners();
  }

  Future<void> _search(String q) async {
    if (q.isEmpty) return;
    _status = SearchStatus.loading;
    notifyListeners();
    try {
      final allSections = await SearchApi.instance.searchAll(q);
      final settings = AppSettings.instance;
      _results = allSections.where((section) {
        final name = section.provider.toLowerCase();
        switch (name) {
          case '4khdhub':  return settings.enable4kHdHub;
          case 'anidb':    return settings.enableAniDb;
          default:         return false;
        }
      }).toList();
      
      await LocalDb.instance.saveSearchQuery(q);
      await loadHistory();
      
      _status = SearchStatus.loaded;
    } catch (e) {
      _error = e.toString();
      _status = SearchStatus.error;
    }
    notifyListeners();
  }

  Future<void> deleteHistoryItem(String query) async {
    await LocalDb.instance.removeSearchQuery(query);
    await loadHistory();
  }

  Future<void> clearHistory() async {
    await LocalDb.instance.clearSearchHistory();
    await loadHistory();
  }

  void clear() {
    _query = '';
    _results = [];
    _suggestions = [];
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

