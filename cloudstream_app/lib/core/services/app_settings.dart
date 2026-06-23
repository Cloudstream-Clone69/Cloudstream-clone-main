// lib/core/services/app_settings.dart
// Centralised settings store (ChangeNotifier) — reads/writes SharedPreferences
// and syncs DNS configuration to the Node backend.

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import '../constants.dart';

// ── DNS Preset Model ─────────────────────────────────────────────────────────

class DnsPreset {
  final String id;
  final String name;
  final String description;
  final List<String> servers; // empty = system default
  final IconData icon;

  const DnsPreset({
    required this.id,
    required this.name,
    required this.description,
    required this.servers,
    required this.icon,
  });
}

// ── Built-in DNS Presets (like Cloudstream) ──────────────────────────────────

const kDnsPresets = [
  DnsPreset(
    id: 'system',
    name: 'System Default',
    description: 'Use your ISP\'s DNS (may block some sites)',
    servers: [],
    icon: Icons.router_rounded,
  ),
  DnsPreset(
    id: 'cloudflare',
    name: 'Cloudflare (1.1.1.1)',
    description: 'Fast, privacy-focused — bypasses most ISP blocks',
    servers: ['1.1.1.1', '1.0.0.1'],
    icon: Icons.bolt_rounded,
  ),
  DnsPreset(
    id: 'google',
    name: 'Google (8.8.8.8)',
    description: 'Reliable and widely used',
    servers: ['8.8.8.8', '8.8.4.4'],
    icon: Icons.public_rounded,
  ),
  DnsPreset(
    id: 'quad9',
    name: 'Quad9 (9.9.9.9)',
    description: 'Security-focused, blocks malicious domains',
    servers: ['9.9.9.9', '149.112.112.112'],
    icon: Icons.security_rounded,
  ),
  DnsPreset(
    id: 'adguard',
    name: 'AdGuard DNS',
    description: 'Blocks ads and trackers at DNS level',
    servers: ['94.140.14.14', '94.140.15.15'],
    icon: Icons.block_rounded,
  ),
  DnsPreset(
    id: 'opendns',
    name: 'OpenDNS',
    description: 'Cisco\'s reliable public DNS',
    servers: ['208.67.222.222', '208.67.220.220'],
    icon: Icons.shield_rounded,
  ),
  DnsPreset(
    id: 'custom',
    name: 'Custom DNS',
    description: 'Enter your own DNS server addresses',
    servers: [],
    icon: Icons.edit_rounded,
  ),
];

// ── AppSettings ───────────────────────────────────────────────────────────────

class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final instance = AppSettings._();

  final _dio = Dio(BaseOptions(
    baseUrl: kBaseUrl,
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
    validateStatus: (_) => true,
  ));

  // ── DNS ──────────────────────────────────────────────────────────────────
  String _dnsPresetId = 'cloudflare';
  String _customDns1 = '';
  String _customDns2 = '';
  bool _dnsApplied = false;

  String get dnsPresetId => _dnsPresetId;
  String get customDns1 => _customDns1;
  String get customDns2 => _customDns2;
  bool get dnsApplied => _dnsApplied;

  // ── WARP ─────────────────────────────────────────────────────────────────
  bool _warpEnabled = false;
  String _warpStatus = 'Unknown'; // 'Connected'|'Disconnected'|'Connecting'|'Not installed'
  bool _warpLoading = false;

  bool get warpEnabled => _warpEnabled;
  String get warpStatus => _warpStatus;
  bool get warpLoading => _warpLoading;

  DnsPreset get activeDnsPreset =>
      kDnsPresets.firstWhere((p) => p.id == _dnsPresetId,
          orElse: () => kDnsPresets[1]); // default cloudflare

  List<String> get activeDnsServers {
    if (_dnsPresetId == 'custom') {
      return [
        if (_customDns1.isNotEmpty) _customDns1,
        if (_customDns2.isNotEmpty) _customDns2,
      ];
    }
    return activeDnsPreset.servers;
  }

  // ── Playback ─────────────────────────────────────────────────────────────
  String _preferredQuality = '1080p'; // '1080p' | '720p' | 'auto'
  String _preferredLang = 'Sub';      // 'Sub' | 'Dub'
  bool _autoPlayNext = true;
  bool _pauseOnFocusLoss = true;
  int _bufferSeconds = 30;            // 5 | 15 | 30 | 60
  bool _autoDownloadNext = true;
  bool _autoDeleteWatched = false;
  int _simultaneousDownloads = 1;
  int _downloadThreads = 4;
  String _downloadPath = '';

  String get preferredQuality => _preferredQuality;
  String get preferredLang => _preferredLang;
  bool get autoPlayNext => _autoPlayNext;
  bool get pauseOnFocusLoss => _pauseOnFocusLoss;
  int get bufferSeconds => _bufferSeconds;
  bool get autoDownloadNext => _autoDownloadNext;
  bool get autoDeleteWatched => _autoDeleteWatched;
  int get simultaneousDownloads => _simultaneousDownloads;
  int get downloadThreads => _downloadThreads;
  String get downloadPath => _downloadPath;

  // ── Providers ────────────────────────────────────────────────────────────
  bool _enable4kHdHub = true;
  bool _enableHdHub = false;
  bool _enableAniDb = true;
  bool _enableAniDao = false;
  bool _enableMovieBox = false;

  bool get enable4kHdHub  => _enable4kHdHub;
  bool get enableHdHub    => _enableHdHub;
  bool get enableAniDb    => _enableAniDb;
  bool get enableAniDao   => _enableAniDao;
  bool get enableMovieBox => _enableMovieBox;

  // Source priority orders — first element = highest priority (tried first)
  // These are stored as JSON strings in SharedPreferences.
  List<String> _movieProviderOrder  = const ['4khdhub', 'anidb'];
  List<String> _seriesProviderOrder = const ['4khdhub', 'anidb'];
  List<String> _animeProviderOrder  = const ['anidb', '4khdhub'];

  List<String> get movieProviderOrder  => List.unmodifiable(_movieProviderOrder);
  List<String> get seriesProviderOrder => List.unmodifiable(_seriesProviderOrder);
  List<String> get animeProviderOrder  => List.unmodifiable(_animeProviderOrder);

  // ── Appearance ───────────────────────────────────────────────────────────
  String _accentColorHex = 'E50914'; // Netflix red

  String get accentColorHex => _accentColorHex;
  Color get accentColor => Color(int.parse('FF$_accentColorHex', radix: 16));

  // ── Backend ───────────────────────────────────────────────────────────────
  String _backendUrl = kBaseUrl;
  String get backendUrl => _backendUrl;

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> init() async {
    await _load();
    // Apply DNS to backend silently on startup
    await applyDns(notify: false);
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _dnsPresetId        = prefs.getString('dns_preset') ?? 'cloudflare';
    _customDns1         = prefs.getString('dns_custom1') ?? '';
    _customDns2         = prefs.getString('dns_custom2') ?? '';
    _preferredQuality   = prefs.getString('pref_quality') ?? '1080p';
    _preferredLang      = prefs.getString('preferred_anidb_lang') ?? 'Sub';
    _autoPlayNext       = prefs.getBool('auto_play_next') ?? true;
    _pauseOnFocusLoss   = prefs.getBool('pauseOnFocusLoss') ?? true;
    _bufferSeconds      = prefs.getInt('buffer_seconds') ?? 30;
    _autoDownloadNext   = prefs.getBool('auto_download_next') ?? true;
    _autoDeleteWatched  = prefs.getBool('auto_delete_watched') ?? false;
    _simultaneousDownloads = prefs.getInt('simultaneous_downloads') ?? 1;
    _downloadThreads    = prefs.getInt('download_threads') ?? 4;
    _downloadPath       = prefs.getString('download_path') ?? '';
    _enable4kHdHub      = prefs.getBool('enable_4khdhub') ?? true;
    _enableHdHub        = prefs.getBool('enable_hdhub') ?? false;
    _enableAniDb        = prefs.getBool('enable_anidb') ?? true;
    _enableAniDao       = prefs.getBool('enable_anidao') ?? false;
    _enableMovieBox     = prefs.getBool('enable_moviebox') ?? false;
    // Priority orders
    _movieProviderOrder  = _decodeOrder(prefs.getString('movie_provider_order'),  ['4khdhub', 'anidb']);
    _seriesProviderOrder = _decodeOrder(prefs.getString('series_provider_order'), ['4khdhub', 'anidb']);
    _animeProviderOrder  = _decodeOrder(prefs.getString('anime_provider_order'),  ['anidb', '4khdhub']);
    _accentColorHex     = prefs.getString('accent_color') ?? 'E50914';
    _backendUrl         = prefs.getString('backend_url') ?? kBaseUrl;
    if (_backendUrl == 'http://localhost:3000') {
      _backendUrl = kBaseUrl;
      await prefs.setString('backend_url', _backendUrl);
    }
    _dio.options.baseUrl = _backendUrl;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('dns_preset', _dnsPresetId);
    await prefs.setString('dns_custom1', _customDns1);
    await prefs.setString('dns_custom2', _customDns2);
    await prefs.setString('pref_quality', _preferredQuality);
    await prefs.setString('preferred_anidb_lang', _preferredLang);
    await prefs.setBool('auto_play_next', _autoPlayNext);
    await prefs.setBool('pauseOnFocusLoss', _pauseOnFocusLoss);
    await prefs.setInt('buffer_seconds', _bufferSeconds);
    await prefs.setBool('auto_download_next', _autoDownloadNext);
    await prefs.setBool('auto_delete_watched', _autoDeleteWatched);
    await prefs.setInt('simultaneous_downloads', _simultaneousDownloads);
    await prefs.setInt('download_threads', _downloadThreads);
    await prefs.setString('download_path', _downloadPath);
    await prefs.setBool('enable_4khdhub', _enable4kHdHub);
    await prefs.setBool('enable_hdhub', _enableHdHub);
    await prefs.setBool('enable_anidb', _enableAniDb);
    await prefs.setBool('enable_anidao', _enableAniDao);
    await prefs.setBool('enable_moviebox', _enableMovieBox);
    await prefs.setString('movie_provider_order',  jsonEncode(_movieProviderOrder));
    await prefs.setString('series_provider_order', jsonEncode(_seriesProviderOrder));
    await prefs.setString('anime_provider_order',  jsonEncode(_animeProviderOrder));
    await prefs.setString('accent_color', _accentColorHex);
    await prefs.setString('backend_url', _backendUrl);
  }

  // ── DNS Actions ───────────────────────────────────────────────────────────

  Future<bool> applyDns({bool notify = true}) async {
    final servers = activeDnsServers;
    try {
      final resp = await _dio.post('/api/settings/dns',
          data: jsonEncode({'servers': servers}),
          options: Options(
            contentType: 'application/json',
            sendTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 5),
          ));
      _dnsApplied = resp.statusCode == 200 && (resp.data?['success'] == true);
    } catch (_) {
      _dnsApplied = false;
    }
    if (notify) notifyListeners();
    return _dnsApplied;
  }

  // ── WARP Actions ──────────────────────────────────────────────────────────

  Future<void> refreshWarpStatus() async {
    try {
      final resp = await _dio.get('/api/settings/warp/status');
      if (resp.statusCode == 200) {
        _warpStatus = resp.data?['status'] ?? 'Unknown';
        _warpEnabled = resp.data?['enabled'] == true;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<bool> enableWarp() async {
    _warpLoading = true;
    notifyListeners();
    try {
      final resp = await _dio.post('/api/settings/warp/enable',
          options: Options(receiveTimeout: const Duration(seconds: 40)));
      final ok = resp.statusCode == 200 && resp.data?['success'] == true;
      if (ok) {
        _warpEnabled = true;
        _warpStatus = 'Connected';
      } else {
        _warpStatus = resp.data?['error'] ?? 'Failed';
      }
      return ok;
    } catch (e) {
      _warpStatus = 'Error: $e';
      return false;
    } finally {
      _warpLoading = false;
      notifyListeners();
    }
  }

  Future<bool> disableWarp() async {
    _warpLoading = true;
    notifyListeners();
    try {
      final resp = await _dio.post('/api/settings/warp/disable',
          options: Options(receiveTimeout: const Duration(seconds: 15)));
      final ok = resp.statusCode == 200 && resp.data?['success'] == true;
      if (ok) {
        _warpEnabled = false;
        _warpStatus = 'Disconnected';
      }
      return ok;
    } catch (e) {
      return false;
    } finally {
      _warpLoading = false;
      notifyListeners();
    }
  }

  Future<void> setDnsPreset(String id) async {
    _dnsPresetId = id;
    _dnsApplied = false;
    await _save();
    notifyListeners();
  }

  Future<void> setCustomDns(String dns1, String dns2) async {
    _customDns1 = dns1.trim();
    _customDns2 = dns2.trim();
    await _save();
    notifyListeners();
  }

  // ── Playback setters ──────────────────────────────────────────────────────

  Future<void> setPreferredQuality(String q) async {
    _preferredQuality = q;
    await _save();
    notifyListeners();
  }

  Future<void> setPreferredLang(String l) async {
    _preferredLang = l;
    await _save();
    notifyListeners();
  }

  Future<void> setAutoPlayNext(bool v) async {
    _autoPlayNext = v;
    await _save();
    notifyListeners();
  }

  Future<void> setPauseOnFocusLoss(bool v) async {
    _pauseOnFocusLoss = v;
    await _save();
    notifyListeners();
  }

  Future<void> setBufferSeconds(int v) async {
    _bufferSeconds = v;
    await _save();
    notifyListeners();
  }

  // ── Provider setters ──────────────────────────────────────────────────────

  Future<void> setEnable4kHdHub(bool v) async {
    _enable4kHdHub = v;
    await _save();
    await _syncProviders();
    notifyListeners();
  }

  Future<void> setEnableHdHub(bool v) async {
    _enableHdHub = v;
    await _save();
    await _syncProviders();
    notifyListeners();
  }

  Future<void> setEnableAniDb(bool v) async {
    _enableAniDb = v;
    await _save();
    await _syncProviders();
    notifyListeners();
  }

  Future<void> setEnableAniDao(bool v) async {
    _enableAniDao = v;
    await _save();
    await _syncProviders();
    notifyListeners();
  }

  Future<void> setEnableMovieBox(bool v) async {
    _enableMovieBox = v;
    await _save();
    await _syncProviders();
    notifyListeners();
  }

  Future<void> setMovieProviderOrder(List<String> order) async {
    _movieProviderOrder = List<String>.from(order);
    await _save();
    notifyListeners();
  }

  Future<void> setSeriesProviderOrder(List<String> order) async {
    _seriesProviderOrder = List<String>.from(order);
    await _save();
    notifyListeners();
  }

  Future<void> setAnimeProviderOrder(List<String> order) async {
    _animeProviderOrder = List<String>.from(order);
    await _save();
    notifyListeners();
  }

  Future<void> setAutoDownloadNext(bool v) async {
    _autoDownloadNext = v;
    await _save();
    notifyListeners();
  }

  Future<void> setAutoDeleteWatched(bool v) async {
    _autoDeleteWatched = v;
    await _save();
    notifyListeners();
  }

  Future<void> setSimultaneousDownloads(int v) async {
    _simultaneousDownloads = v;
    await _save();
    notifyListeners();
  }

  Future<void> setDownloadThreads(int v) async {
    _downloadThreads = v;
    await _save();
    notifyListeners();
  }

  Future<void> setDownloadPath(String v) async {
    _downloadPath = v;
    await _save();
    notifyListeners();
  }

  Future<void> _syncProviders() async {
    try {
      await _dio.post('/api/settings/providers',
          data: jsonEncode({
            'providers': {
              '4khdhub': _enable4kHdHub,
              'anidb': _enableAniDb,
            }
          }),
          options: Options(contentType: 'application/json'));
    } catch (_) {}
  }

  // ── Helper ────────────────────────────────────────────────────────────────
  static List<String> _decodeOrder(String? raw, List<String> defaultOrder) {
    if (raw == null || raw.isEmpty) return List<String>.from(defaultOrder);
    try {
      final list = (jsonDecode(raw) as List).cast<String>();
      // Only keep items that are in defaultOrder
      final filtered = list.where((p) => defaultOrder.contains(p)).toList();
      // Add any missing defaultOrder providers at the end
      for (final p in defaultOrder) {
        if (!filtered.contains(p)) filtered.add(p);
      }
      return filtered.isNotEmpty ? filtered : List<String>.from(defaultOrder);
    } catch (_) {
      return List<String>.from(defaultOrder);
    }
  }

  // ── Appearance ────────────────────────────────────────────────────────────

  Future<void> setAccentColor(String hex) async {
    _accentColorHex = hex;
    await _save();
    notifyListeners();
  }

  // ── Backend URL ───────────────────────────────────────────────────────────

  Future<void> setBackendUrl(String url) async {
    _backendUrl = url.trim();
    _dio.options.baseUrl = _backendUrl;
    await _save();
    notifyListeners();
  }

  // ── Reset all ─────────────────────────────────────────────────────────────

  Future<void> resetAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await _load();
    try {
      await _dio.post('/api/settings/reset');
    } catch (_) {}
    notifyListeners();
  }
}
