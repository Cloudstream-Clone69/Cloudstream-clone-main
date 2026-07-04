import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import '../constants.dart';

class UpdateInfo {
  final bool maintenance;
  final String maintenanceMessage;
  final String latestVersion;
  final String downloadUrl;
  final String releaseNotes;
  final bool mandatory;

  UpdateInfo({
    required this.maintenance,
    required this.maintenanceMessage,
    required this.latestVersion,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.mandatory,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      maintenance: json['maintenance'] as bool? ?? false,
      maintenanceMessage: json['maintenance_message'] as String? ?? 'System maintenance in progress.',
      latestVersion: json['latest_version'] as String? ?? '1.0.0',
      downloadUrl: json['download_url'] as String? ?? '',
      releaseNotes: json['release_notes'] as String? ?? '',
      mandatory: json['mandatory'] as bool? ?? false,
    );
  }
}

class UpdateService extends ChangeNotifier {
  static final UpdateService instance = UpdateService._();
  UpdateService._();

  UpdateInfo? _info;
  UpdateInfo? get info => _info;

  bool _isChecking = false;
  bool get isChecking => _isChecking;

  double _downloadProgress = 0.0;
  double get downloadProgress => _downloadProgress;

  bool _isDownloading = false;
  bool get isDownloading => _isDownloading;

  String? _error;
  String? get error => _error;

  Future<UpdateInfo?> checkUpdate() async {
    _isChecking = true;
    _error = null;
    _info = null;
    notifyListeners();

    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 4),
        receiveTimeout: const Duration(seconds: 4),
      ));
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final res = await dio.get(
        '$kUpdateConfigUrl?t=$timestamp',
        options: Options(
          headers: {
            'Cache-Control': 'no-cache',
            'Pragma': 'no-cache',
            'Expires': '0',
          },
        ),
      );
      if (res.statusCode == 200 && res.data != null) {
        dynamic data = res.data;
        if (data is String) {
          try {
            final Map<String, dynamic> parsed = Map<String, dynamic>.from(jsonDecode(data));
            _info = UpdateInfo.fromJson(parsed);
          } catch (_) {
            // Fallback to custom decode if it's not standard JSON
            importJsonString(data);
          }
        } else if (data is Map<String, dynamic>) {
          _info = UpdateInfo.fromJson(data);
        }
        print('[UpdateService] Update check success. Maintenance: ${_info?.maintenance}, Latest: ${_info?.latestVersion}');
      } else {
        _error = 'Failed to fetch update config (HTTP status ${res.statusCode})';
      }
    } catch (e) {
      _error = 'Failed to check for updates: $e';
      print('[UpdateService] Error: $e');
    }

    _isChecking = false;
    notifyListeners();
    return _info;
  }

  void importJsonString(String str) {
    try {
      final decoded = Uri.decodeComponent(str);
      final clean = decoded.substring(decoded.indexOf('{'), decoded.lastIndexOf('}') + 1);
      final Map<String, dynamic> parsed = Map<String, dynamic>.from(
        Uri.splitQueryString(clean).map((k, v) => MapEntry(k, v))
      );
      _info = UpdateInfo.fromJson(parsed);
    } catch (e) {
      _error = 'Error parsing JSON config: $e';
    }
  }

  bool isUpdateAvailable(String currentVersion, String latestVersion) {
    try {
      final currentParts = currentVersion.split('+')[0].split('.').map(int.parse).toList();
      final latestParts = latestVersion.split('+')[0].split('.').map(int.parse).toList();

      for (int i = 0; i < currentParts.length && i < latestParts.length; i++) {
        if (latestParts[i] > currentParts[i]) return true;
        if (currentParts[i] > latestParts[i]) return false;
      }
      return latestParts.length > currentParts.length;
    } catch (_) {
      return latestVersion != currentVersion;
    }
  }

  Future<void> startUpdateDownload(String url) async {
    if (_isDownloading) return;
    _isDownloading = true;
    _downloadProgress = 0.0;
    _error = null;
    notifyListeners();

    try {
      final tempDir = await getTemporaryDirectory();
      final savePath = '${tempDir.path}/cloudstream_setup.exe';

      final dio = Dio();
      await dio.download(
        url,
        savePath,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            _downloadProgress = received / total;
            notifyListeners();
          }
        },
      );

      _isDownloading = false;
      notifyListeners();

      // Launch the installer setup.exe and close the app
      print('[UpdateService] Launching installer at $savePath');
      await Process.start(savePath, [], runInShell: true);
      exit(0);
    } catch (e) {
      _isDownloading = false;
      _error = 'Failed to download update: $e';
      notifyListeners();
    }
  }
}
