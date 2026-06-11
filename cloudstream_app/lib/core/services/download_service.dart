// lib/core/services/download_service.dart
// Handles file downloads with progress notifications

import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import 'local_db.dart';

class DownloadTask {
  final int tmdbId;
  final String title;
  final String posterUrl;
  final String mediaType;
  final String? seasonNumber;
  final String? episodeNumber;
  final String streamUrl;

  double progress = 0.0;
  bool isComplete = false;
  bool hasError = false;
  String? errorMessage;
  String? filePath;
  CancelToken? cancelToken;

  DownloadTask({
    required this.tmdbId,
    required this.title,
    required this.posterUrl,
    required this.mediaType,
    this.seasonNumber,
    this.episodeNumber,
    required this.streamUrl,
  });
}

class DownloadService {
  DownloadService._();
  static final instance = DownloadService._();

  final _tasks = <String, DownloadTask>{};
  final _controller = StreamController<Map<String, DownloadTask>>.broadcast();

  Stream<Map<String, DownloadTask>> get tasksStream => _controller.stream;
  Map<String, DownloadTask> get tasks => Map.unmodifiable(_tasks);

  String _taskKey(int tmdbId, String? season, String? episode) =>
      '${tmdbId}_${season ?? 'm'}_${episode ?? '0'}';

  Future<void> startDownload({
    required int tmdbId,
    required String title,
    required String posterUrl,
    required String mediaType,
    String? seasonNumber,
    String? episodeNumber,
    required String streamUrl,
  }) async {
    final key = _taskKey(tmdbId, seasonNumber, episodeNumber);
    if (_tasks.containsKey(key)) return; // Already downloading

    final task = DownloadTask(
      tmdbId: tmdbId,
      title: title,
      posterUrl: posterUrl,
      mediaType: mediaType,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      streamUrl: streamUrl,
    );
    task.cancelToken = CancelToken();
    _tasks[key] = task;
    _notify();

    try {
      // Get downloads folder
      final dir = await getApplicationDocumentsDirectory();
      final dlDir = Directory('${dir.path}/CloudStream/Downloads');
      await dlDir.create(recursive: true);

      // Build filename
      String filename = title.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
      if (seasonNumber != null && episodeNumber != null) {
        filename += '_S${seasonNumber}E$episodeNumber';
      }
      filename += '.mp4';
      final savePath = '${dlDir.path}/$filename';

      final dio = Dio(BaseOptions(
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        },
      ));

      await dio.download(
        streamUrl,
        savePath,
        cancelToken: task.cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            task.progress = received / total;
          } else {
            task.progress = 0;
          }
          _notify();
        },
      );

      final file = File(savePath);
      final size = await file.length();

      task.isComplete = true;
      task.filePath = savePath;
      _notify();

      // Save to local DB
      await LocalDb.instance.saveDownload(DownloadItem(
        tmdbId: tmdbId,
        title: title,
        posterUrl: posterUrl,
        mediaType: mediaType,
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
        filePath: savePath,
        sizeBytes: size,
        downloadedAt: DateTime.now(),
      ));
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        task.hasError = false;
        task.errorMessage = 'Cancelled';
      } else {
        task.hasError = true;
        task.errorMessage = e.toString();
      }
      _notify();
    }
  }

  void cancel(int tmdbId, String? seasonNumber, String? episodeNumber) {
    final key = _taskKey(tmdbId, seasonNumber, episodeNumber);
    _tasks[key]?.cancelToken?.cancel('User cancelled');
    _tasks.remove(key);
    _notify();
  }

  void _notify() {
    if (!_controller.isClosed) {
      _controller.add(Map<String, DownloadTask>.from(_tasks));
    }
  }

  void dispose() {
    _controller.close();
  }
}
