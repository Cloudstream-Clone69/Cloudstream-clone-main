import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_db.dart';
import 'app_settings.dart';

class DownloadTask {
  final int tmdbId;
  final String title;
  final String posterUrl;
  final String mediaType;
  final String? seasonNumber;
  final String? episodeNumber;
  final String streamUrl;
  final String referer;
  final String cookie;

  double progress = 0.0;
  bool isComplete = false;
  bool hasError = false;
  String? errorMessage;
  String? filePath;

  // Advanced Downloader fields
  bool isPaused = false;
  double speedBytesPerSec = 0.0;
  int etaSeconds = -1;
  int downloadedBytes = 0;
  int totalBytes = 0;
  int lastSecondBytes = 0;

  bool isHls = false;
  int hlsCurrentSegment = 0;
  int hlsTotalSegments = 0;
  bool _cancelRequested = false;
  CancelToken? cancelToken;

  DownloadTask({
    required this.tmdbId,
    required this.title,
    required this.posterUrl,
    required this.mediaType,
    this.seasonNumber,
    this.episodeNumber,
    required this.streamUrl,
    this.referer = '',
    this.cookie = '',
  });

  Map<String, dynamic> toJson() => {
        'tmdbId': tmdbId,
        'title': title,
        'posterUrl': posterUrl,
        'mediaType': mediaType,
        'seasonNumber': seasonNumber,
        'episodeNumber': episodeNumber,
        'streamUrl': streamUrl,
        'filePath': filePath,
        'isHls': isHls,
        'referer': referer,
        'cookie': cookie,
      };
}

class DownloadService {
  DownloadService._();
  static final instance = DownloadService._();

  final _tasks = <String, DownloadTask>{};
  final _controller = StreamController<Map<String, DownloadTask>>.broadcast();
  List<String> _queueOrder = [];
  Timer? _speedTimer;

  Stream<Map<String, DownloadTask>> get tasksStream => _controller.stream;
  Map<String, DownloadTask> get tasks => Map.unmodifiable(_tasks);

  List<DownloadTask> get sortedTasks {
    final list = <DownloadTask>[];
    for (final key in _queueOrder) {
      if (_tasks.containsKey(key)) {
        list.add(_tasks[key]!);
      }
    }
    for (final entry in _tasks.entries) {
      if (!_queueOrder.contains(entry.key)) {
        list.add(entry.value);
      }
    }
    return list;
  }

  String _taskKey(int tmdbId, String? season, String? episode) =>
      '${tmdbId}_${season ?? 'm'}_${episode ?? '0'}';

  static const _activeTasksKey = 'active_download_tasks_v3';
  static const _queueOrderKey = 'download_queue_order_v3';

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _queueOrder = prefs.getStringList(_queueOrderKey) ?? [];

    final tasksJson = prefs.getString(_activeTasksKey);
    if (tasksJson != null) {
      try {
        final List<dynamic> list = jsonDecode(tasksJson);
        for (final item in list) {
          final task = DownloadTask(
            tmdbId: item['tmdbId'],
            title: item['title'],
            posterUrl: item['posterUrl'],
            mediaType: item['mediaType'],
            seasonNumber: item['seasonNumber'],
            episodeNumber: item['episodeNumber'],
            streamUrl: item['streamUrl'],
            referer: item['referer'] ?? '',
            cookie: item['cookie'] ?? '',
          );
          task.isPaused = true; // start as paused
          task.filePath = item['filePath'];
          task.isHls = item['isHls'] ?? false;

          final key = _taskKey(task.tmdbId, task.seasonNumber, task.episodeNumber);
          _tasks[key] = task;

          // Estimate initial progress
          if (task.filePath != null) {
            final file = File(task.filePath!);
            if (await file.exists()) {
              final len = await file.length();
              task.downloadedBytes = len;
              if (task.isHls) {
                final stateFile = File('${task.filePath!}.state');
                if (await stateFile.exists()) {
                  try {
                    final stateJson = jsonDecode(await stateFile.readAsString());
                    final curr = stateJson['hlsCurrentSegment'] ?? 0;
                    final tot = stateJson['hlsTotalSegments'] ?? 1;
                    task.progress = curr / tot;
                    task.hlsCurrentSegment = curr;
                    task.hlsTotalSegments = tot;
                    task.totalBytes = (len / (curr + 1) * tot).round();
                  } catch (_) {}
                }
              } else {
                task.progress = 0.0; // progress gets updated on resume
              }
            }
          }
        }
      } catch (e) {
        print('[DownloadService] Error restoring tasks: $e');
      }
    }
    _notify(force: true);
    _startSpeedTimer();
  }

  void _startSpeedTimer() {
    _speedTimer?.cancel();
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      bool changed = false;
      for (final task in _tasks.values) {
        if (task.isComplete || task.isPaused || task.hasError) {
          if (task.speedBytesPerSec > 0) {
            task.speedBytesPerSec = 0;
            task.etaSeconds = -1;
            changed = true;
          }
          continue;
        }

        final deltaBytes = task.downloadedBytes - task.lastSecondBytes;
        task.lastSecondBytes = task.downloadedBytes;

        // Smooth speed indicator using EMA
        task.speedBytesPerSec = (task.speedBytesPerSec * 0.6) + (deltaBytes * 0.4);

        if (task.speedBytesPerSec > 1024) {
          final remainingBytes = task.totalBytes - task.downloadedBytes;
          if (remainingBytes > 0) {
            task.etaSeconds = (remainingBytes / task.speedBytesPerSec).round();
          } else {
            task.etaSeconds = 0;
          }
        } else {
          task.etaSeconds = -1;
        }
        changed = true;
      }
      if (changed) {
        _notify();
      }
    });
  }

  Future<void> startDownload({
    required int tmdbId,
    required String title,
    required String posterUrl,
    required String mediaType,
    String? seasonNumber,
    String? episodeNumber,
    required String streamUrl,
    String referer = '',
    String cookie = '',
  }) async {
    final key = _taskKey(tmdbId, seasonNumber, episodeNumber);
    if (_tasks.containsKey(key)) {
      final existing = _tasks[key]!;
      if (existing.isPaused) {
        resumeTask(tmdbId, seasonNumber, episodeNumber);
      }
      return;
    }

    final task = DownloadTask(
      tmdbId: tmdbId,
      title: title,
      posterUrl: posterUrl,
      mediaType: mediaType,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      streamUrl: streamUrl,
      referer: referer,
      cookie: cookie,
    );

    _tasks[key] = task;
    if (!_queueOrder.contains(key)) {
      _queueOrder.add(key);
      _persistQueueOrder();
    }
    _notify(force: true);

    _runDownloadTask(task);
  }

  void _runDownloadTask(DownloadTask task) async {
    task.isPaused = false;
    task.hasError = false;
    task.errorMessage = null;
    _notify(force: true);

    try {
      final customPath = AppSettings.instance.downloadPath;
      final Directory dlDir;
      if (customPath.isNotEmpty) {
        dlDir = Directory(customPath);
      } else {
        final dir = await getApplicationDocumentsDirectory();
        dlDir = Directory('${dir.path}/CloudStream/Downloads');
      }

      String seriesName = '';
      if (task.seasonNumber != null && task.episodeNumber != null) {
        final match = RegExp(r'^(.*?)\s+S\d+E\d+').firstMatch(task.title);
        if (match != null) {
          seriesName = match.group(1) ?? '';
        }
      }

      final Directory saveDir;
      if (task.seasonNumber != null && task.episodeNumber != null && seriesName.isNotEmpty) {
        final folderName = seriesName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
        saveDir = Directory('${dlDir.path}/$folderName');
      } else {
        saveDir = dlDir;
      }
      await saveDir.create(recursive: true);

      String filename = task.title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
      final isHlsStream = task.streamUrl.contains('.m3u8') || task.streamUrl.contains('m3u8');
      task.isHls = isHlsStream;
      
      final ext = isHlsStream ? '.ts' : '.mp4';
      final savePath = '${saveDir.path}/$filename$ext';
      task.filePath = savePath;

      await _saveActiveTasks();

      if (isHlsStream) {
        await _downloadHls(task, savePath);
      } else {
        await _downloadDirect(task, savePath);
      }
    } catch (e) {
      if (task._cancelRequested || task.isPaused) {
        // Handled or user paused
      } else {
        task.hasError = true;
        task.errorMessage = e.toString();
        task.speedBytesPerSec = 0;
        task.etaSeconds = -1;
        _notify();
      }
    }
  }

  Future<void> _downloadDirect(DownloadTask task, String savePath) async {
    final file = File(savePath);
    final cancelToken = CancelToken();
    task.cancelToken = cancelToken;

    final numParts = 4;
    final partFiles = List.generate(numParts, (i) => File('$savePath.part$i'));

    try {
      final Map<String, dynamic> requestHeaders = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      };
      if (task.referer.isNotEmpty) {
        requestHeaders['Referer'] = task.referer;
      }
      if (task.cookie.isNotEmpty) {
        requestHeaders['Cookie'] = task.cookie;
      }
      final dio = Dio(BaseOptions(
        headers: requestHeaders,
      ));

      bool rangeSupported = false;
      int totalBytes = 0;

      try {
        final checkRes = await dio.get<ResponseBody>(
          task.streamUrl,
          cancelToken: cancelToken,
          options: Options(
            headers: {'Range': 'bytes=0-0'},
            responseType: ResponseType.stream,
          ),
        );
        if (checkRes.statusCode == 206) {
          rangeSupported = true;
          final contentRange = checkRes.headers.value('content-range');
          if (contentRange != null) {
            final match = RegExp(r'/(\d+)$').firstMatch(contentRange);
            if (match != null) {
              totalBytes = int.tryParse(match.group(1)!) ?? 0;
            }
          }
        } else if (checkRes.statusCode == 200) {
          final lenHeader = checkRes.headers.value('content-length');
          totalBytes = lenHeader != null ? int.tryParse(lenHeader) ?? 0 : 0;
        }
        await checkRes.data?.stream.drain();
      } catch (e) {
        print('[DownloadService] Range support check failed: $e');
      }

      if (rangeSupported && totalBytes > 5 * 1024 * 1024) {
        task.totalBytes = totalBytes;
        
        final partSize = (totalBytes / numParts).ceil();
        final partDownloadedBytes = List.filled(numParts, 0);

        for (int i = 0; i < numParts; i++) {
          if (await partFiles[i].exists()) {
            partDownloadedBytes[i] = await partFiles[i].length();
          }
        }

        int initialDownloaded = 0;
        for (int j = 0; j < numParts; j++) {
          initialDownloaded += partDownloadedBytes[j];
        }
        task.downloadedBytes = initialDownloaded;
        task.lastSecondBytes = initialDownloaded;

        bool partFailed = false;
        dynamic partError;

        Future<void> downloadPart(int i) async {
          final partFile = partFiles[i];
          final start = i * partSize;
          final end = (i == numParts - 1) ? totalBytes - 1 : (i + 1) * partSize - 1;
          
          final currentStart = start + partDownloadedBytes[i];
          if (currentStart >= end) {
            return;
          }

          final response = await dio.get<ResponseBody>(
            task.streamUrl,
            cancelToken: cancelToken,
            options: Options(
              responseType: ResponseType.stream,
              headers: {'Range': 'bytes=$currentStart-$end'},
            ),
          );

          IOSink? partSink;
          try {
            partSink = partFile.openWrite(mode: partDownloadedBytes[i] > 0 ? FileMode.append : FileMode.write);
            final stream = response.data!.stream;
            await for (final chunk in stream) {
              if (task.isPaused || task._cancelRequested || partFailed) {
                break;
              }
              partSink.add(chunk);
              partDownloadedBytes[i] += chunk.length;

              int totalDownloaded = 0;
              for (int j = 0; j < numParts; j++) {
                totalDownloaded += partDownloadedBytes[j];
              }
              task.downloadedBytes = totalDownloaded;
              task.progress = totalDownloaded / totalBytes;
              _notify();
            }
            await partSink.flush();
          } finally {
            if (partSink != null) {
              try { await partSink.close(); } catch (_) {}
            }
          }
        }

        final partFutures = <Future<void>>[];
        for (int i = 0; i < numParts; i++) {
          partFutures.add(() async {
            try {
              await downloadPart(i);
            } catch (e) {
              if (!task.isPaused && !task._cancelRequested && !partFailed) {
                partFailed = true;
                partError = e;
                try { cancelToken.cancel('Part $i failed'); } catch (_) {}
              }
            }
          }());
        }

        await Future.wait(partFutures);

        if (partFailed) {
          throw partError ?? Exception('Failed downloading one or more parts');
        }

        if (!task.isPaused && !task._cancelRequested) {
          final finalFile = File(savePath);
          final finalSink = finalFile.openWrite(mode: FileMode.write);
          try {
            for (int i = 0; i < numParts; i++) {
              final partFile = partFiles[i];
              if (await partFile.exists()) {
                final partStream = partFile.openRead();
                await for (final chunk in partStream) {
                  finalSink.add(chunk);
                }
              }
            }
            await finalSink.flush();
          } finally {
            try { await finalSink.close(); } catch (_) {}
          }

          for (int i = 0; i < numParts; i++) {
            try {
              if (await partFiles[i].exists()) {
                await partFiles[i].delete();
              }
            } catch (_) {}
          }
        }
      } else {
        int startBytes = 0;
        if (await file.exists()) {
          startBytes = await file.length();
        }

        Response<ResponseBody> response;
        try {
          response = await dio.get<ResponseBody>(
            task.streamUrl,
            cancelToken: cancelToken,
            options: Options(
              responseType: ResponseType.stream,
              headers: startBytes > 0 ? {'Range': 'bytes=$startBytes-'} : null,
            ),
          );
        } catch (e) {
          if (startBytes > 0 && !task.isPaused && !task._cancelRequested) {
            startBytes = 0;
            try { if (await file.exists()) await file.delete(); } catch (_) {}
            response = await dio.get<ResponseBody>(
              task.streamUrl,
              cancelToken: cancelToken,
              options: Options(responseType: ResponseType.stream),
            );
          } else {
            rethrow;
          }
        }

        final isPartial = response.statusCode == 206;
        final totalHeader = response.headers.value('content-length');
        final totalLength = totalHeader != null ? int.tryParse(totalHeader) ?? 0 : 0;

        if (isPartial) {
          task.totalBytes = startBytes + totalLength;
          task.downloadedBytes = startBytes;
        } else {
          if (startBytes > 0) {
            startBytes = 0;
            try { if (await file.exists()) await file.delete(); } catch (_) {}
          }
          task.totalBytes = totalLength;
          task.downloadedBytes = 0;
        }
        task.lastSecondBytes = task.downloadedBytes;

        IOSink? sink;
        try {
          sink = file.openWrite(mode: startBytes > 0 ? FileMode.append : FileMode.write);
          final stream = response.data!.stream;
          await for (final chunk in stream) {
            if (task.isPaused || task._cancelRequested) {
              break;
            }
            sink.add(chunk);
            task.downloadedBytes += chunk.length;
            if (task.totalBytes > 0) {
              task.progress = task.downloadedBytes / task.totalBytes;
            }
            _notify();
          }
          await sink.flush();
        } finally {
          if (sink != null) {
            try { await sink.close(); } catch (_) {}
          }
        }
      }

      if (!task.isPaused && !task._cancelRequested) {
        task.isComplete = true;
        _notify(force: true);

        final size = await file.length();
        await LocalDb.instance.saveDownload(DownloadItem(
          tmdbId: task.tmdbId,
          title: task.title,
          posterUrl: task.posterUrl,
          mediaType: task.mediaType,
          seasonNumber: task.seasonNumber,
          episodeNumber: task.episodeNumber,
          filePath: savePath,
          sizeBytes: size,
          downloadedAt: DateTime.now(),
        ));

        final key = _taskKey(task.tmdbId, task.seasonNumber, task.episodeNumber);
        _tasks.remove(key);
        _queueOrder.remove(key);
        await _saveActiveTasks();
        await _persistQueueOrder();
        _notify(force: true);
      }
    } finally {
      task.cancelToken = null;
      try { cancelToken.cancel(); } catch (_) {}

      if (task._cancelRequested) {
        try {
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
        for (int i = 0; i < numParts; i++) {
          try {
            if (await partFiles[i].exists()) {
              await partFiles[i].delete();
            }
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _downloadHls(DownloadTask task, String savePath) async {
    final Map<String, dynamic> requestHeaders = {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    };
    if (task.referer.isNotEmpty) {
      requestHeaders['Referer'] = task.referer;
    }
    if (task.cookie.isNotEmpty) {
      requestHeaders['Cookie'] = task.cookie;
    }
    final dio = Dio(BaseOptions(
      headers: requestHeaders,
    ));
    final res = await dio.get<String>(task.streamUrl);
    if (res.statusCode != 200 || res.data == null) {
      throw Exception('Failed to fetch HLS manifest');
    }

    String manifest = res.data!;
    String playlistUrl = task.streamUrl;

    if (manifest.contains('#EXT-X-STREAM-INF')) {
      final bestVariant = _getBestVariantUrl(manifest, playlistUrl);
      if (bestVariant == null) {
        throw Exception('Could not find variant sub-playlist in master manifest');
      }
      playlistUrl = bestVariant;
      final subRes = await dio.get<String>(playlistUrl);
      if (subRes.statusCode != 200 || subRes.data == null) {
        throw Exception('Failed to fetch HLS sub-playlist');
      }
      manifest = subRes.data!;
    }

    final segments = _getSegments(manifest, playlistUrl);
    if (segments.isEmpty) {
      throw Exception('No segments found in HLS playlist');
    }

    task.hlsTotalSegments = segments.length;

    final stateFile = File('$savePath.state');
    int startSegment = 0;
    if (await stateFile.exists()) {
      try {
        final stateJson = jsonDecode(await stateFile.readAsString());
        if (stateJson['streamUrl'] == task.streamUrl) {
          startSegment = stateJson['hlsCurrentSegment'] ?? 0;
        }
      } catch (_) {}
    }

    task.hlsCurrentSegment = startSegment;
    final file = File(savePath);

    // Assume average segment size is 1.5MB for initial totalBytes estimate
    const avgSegEstimate = 1500000;
    task.totalBytes = segments.length * avgSegEstimate;
    
    if (startSegment > 0 && await file.exists()) {
      task.downloadedBytes = await file.length();
    } else {
      task.downloadedBytes = startSegment * avgSegEstimate;
    }
    task.lastSecondBytes = task.downloadedBytes;

    final cancelToken = CancelToken();
    task.cancelToken = cancelToken;

    final maxConcurrent = 4;
    final segmentBuffer = <int, List<int>>{};
    final activeFutures = <int, Future<void>>{};
    int nextSegmentToDownload = startSegment;
    int nextSegmentToWrite = startSegment;
    bool hasDownloadError = false;
    dynamic downloadError;

    IOSink? sink;

    try {
      sink = file.openWrite(mode: startSegment == 0 ? FileMode.write : FileMode.append);

      while (nextSegmentToWrite < segments.length && !task.isPaused && !task._cancelRequested && !hasDownloadError) {
        // 1. Fill activeFutures up to maxConcurrent
        while (activeFutures.length < maxConcurrent &&
               nextSegmentToDownload < segments.length &&
               !task.isPaused &&
               !task._cancelRequested &&
               !hasDownloadError) {
          
          final downloadIdx = nextSegmentToDownload++;
          final url = segments[downloadIdx];

          final future = () async {
            try {
              final response = await dio.get<List<int>>(
                url,
                cancelToken: cancelToken,
                options: Options(responseType: ResponseType.bytes),
              );
              if (response.statusCode == 200 && response.data != null) {
                segmentBuffer[downloadIdx] = response.data!;
              } else {
                throw Exception('Status code ${response.statusCode}');
              }
            } catch (e) {
              if (!task.isPaused && !task._cancelRequested) {
                hasDownloadError = true;
                downloadError = e;
                try { cancelToken.cancel('Segment download failed'); } catch (_) {}
              }
            }
          }();
          
          activeFutures[downloadIdx] = future;
        }

        // 2. Write as many sequential segments as possible
        while (segmentBuffer.containsKey(nextSegmentToWrite)) {
          final data = segmentBuffer.remove(nextSegmentToWrite)!;
          activeFutures.remove(nextSegmentToWrite);

          sink.add(data);
          task.downloadedBytes += data.length;
          task.hlsCurrentSegment = nextSegmentToWrite;
          task.progress = (nextSegmentToWrite + 1) / segments.length;
          
          final segmentsDownloadedSoFar = nextSegmentToWrite - startSegment + 1;
          final avgSegmentSize = task.downloadedBytes / (segmentsDownloadedSoFar > 0 ? segmentsDownloadedSoFar : 1);
          task.totalBytes = (avgSegmentSize * segments.length).round();

          _notify();

          try {
            await stateFile.writeAsString(jsonEncode({
              'hlsCurrentSegment': nextSegmentToWrite,
              'hlsTotalSegments': segments.length,
              'streamUrl': task.streamUrl,
            }));
          } catch (_) {}

          nextSegmentToWrite++;
        }

        // 3. Wait for any active download to complete
        if (activeFutures.isNotEmpty) {
          await Future.any(activeFutures.values);
        } else {
          if (nextSegmentToDownload >= segments.length && !segmentBuffer.containsKey(nextSegmentToWrite)) {
            break;
          }
        }
      }

      if (hasDownloadError) {
        throw downloadError ?? Exception('HLS segment download failed');
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (!task.isPaused && !task._cancelRequested) {
        if (await stateFile.exists()) await stateFile.delete();
        task.isComplete = true;
        _notify(force: true);

        final size = await file.length();
        await LocalDb.instance.saveDownload(DownloadItem(
          tmdbId: task.tmdbId,
          title: task.title,
          posterUrl: task.posterUrl,
          mediaType: task.mediaType,
          seasonNumber: task.seasonNumber,
          episodeNumber: task.episodeNumber,
          filePath: savePath,
          sizeBytes: size,
          downloadedAt: DateTime.now(),
        ));

        final key = _taskKey(task.tmdbId, task.seasonNumber, task.episodeNumber);
        _tasks.remove(key);
        _queueOrder.remove(key);
        await _saveActiveTasks();
        await _persistQueueOrder();
        _notify(force: true);
      }
    } finally {
      task.cancelToken = null;
      try { cancelToken.cancel(); } catch (_) {}
      
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }

      if (task._cancelRequested) {
        try {
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
        try {
          if (await stateFile.exists()) {
            await stateFile.delete();
          }
        } catch (_) {}
      }
    }
  }

  String? _getBestVariantUrl(String manifest, String masterUrl) {
    final lines = manifest.split('\n');
    final baseUri = Uri.parse(masterUrl);
    String? bestUrl;
    int maxBandwidth = 0;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        final bwMatch = RegExp(r'BANDWIDTH=(\d+)', caseSensitive: false).firstMatch(line);
        final bw = bwMatch != null ? int.tryParse(bwMatch.group(1)!) ?? 0 : 0;

        if (i + 1 < lines.length) {
          final nextLine = lines[i + 1].trim();
          if (nextLine.isNotEmpty && !nextLine.startsWith('#')) {
            if (bw > maxBandwidth || bestUrl == null) {
              maxBandwidth = bw;
              bestUrl = nextLine.startsWith('http') ? nextLine : baseUri.resolve(nextLine).toString();
            }
          }
        }
      }
    }
    return bestUrl;
  }

  List<String> _getSegments(String manifest, String playlistUrl) {
    final lines = manifest.split('\n');
    final List<String> segments = [];
    final baseUri = Uri.parse(playlistUrl);

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      if (line.startsWith('http://') || line.startsWith('https://')) {
        segments.add(line);
      } else {
        segments.add(baseUri.resolve(line).toString());
      }
    }
    return segments;
  }

  void pauseTask(int tmdbId, String? seasonNumber, String? episodeNumber) {
    final key = _taskKey(tmdbId, seasonNumber, episodeNumber);
    final task = _tasks[key];
    if (task != null && !task.isComplete) {
      task.isPaused = true;
      task.speedBytesPerSec = 0;
      task.etaSeconds = -1;
      try {
        task.cancelToken?.cancel('Paused by user');
      } catch (_) {}
      _notify(force: true);
      _saveActiveTasks();
    }
  }

  void resumeTask(int tmdbId, String? seasonNumber, String? episodeNumber) {
    final key = _taskKey(tmdbId, seasonNumber, episodeNumber);
    final task = _tasks[key];
    if (task != null && task.isPaused) {
      task.isPaused = false;
      _notify(force: true);
      _runDownloadTask(task);
    }
  }

  void cancel(int tmdbId, String? seasonNumber, String? episodeNumber) {
    final key = _taskKey(tmdbId, seasonNumber, episodeNumber);
    final task = _tasks[key];
    if (task != null) {
      task._cancelRequested = true;
      task.isPaused = true;
      
      try {
        task.cancelToken?.cancel('Cancelled by user');
      } catch (_) {}

      _tasks.remove(key);
      _queueOrder.remove(key);
      
      // Try immediate deletion (will succeed if task is not actively running)
      if (task.filePath != null) {
        try {
          final file = File(task.filePath!);
          if (file.existsSync()) file.deleteSync();
        } catch (_) {}
        try {
          final stateFile = File('${task.filePath!}.state');
          if (stateFile.existsSync()) stateFile.deleteSync();
        } catch (_) {}
        for (int i = 0; i < 8; i++) {
          try {
            final partFile = File('${task.filePath!}.part$i');
            if (partFile.existsSync()) partFile.deleteSync();
          } catch (_) {}
        }
      }

      _notify(force: true);
      _saveActiveTasks();
      _persistQueueOrder();
    }
  }

  void moveUp(String key) {
    final idx = _queueOrder.indexOf(key);
    if (idx > 0) {
      _queueOrder.removeAt(idx);
      _queueOrder.insert(idx - 1, key);
      _persistQueueOrder();
      _notify(force: true);
    }
  }

  void moveDown(String key) {
    final idx = _queueOrder.indexOf(key);
    if (idx >= 0 && idx < _queueOrder.length - 1) {
      _queueOrder.removeAt(idx);
      _queueOrder.insert(idx + 1, key);
      _persistQueueOrder();
      _notify(force: true);
    }
  }

  Future<void> _saveActiveTasks() async {
    final prefs = await SharedPreferences.getInstance();
    final active = _tasks.values.where((t) => !t.isComplete).map((t) => t.toJson()).toList();
    await prefs.setString(_activeTasksKey, jsonEncode(active));
  }

  Future<void> _persistQueueOrder() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_queueOrderKey, _queueOrder);
  }

  int _lastNotifyMs = 0;

  void _notify({bool force = false}) {
    if (!force) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastNotifyMs < 400) {
        return; // limit updates to 2.5 times per second
      }
      _lastNotifyMs = now;
    }
    if (!_controller.isClosed) {
      _controller.add(Map<String, DownloadTask>.from(_tasks));
    }
  }

  void dispose() {
    _speedTimer?.cancel();
    _controller.close();
  }
}
