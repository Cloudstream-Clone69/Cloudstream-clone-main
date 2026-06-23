// lib/core/services/local_backend.dart

import 'dart:io';
import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:dio/dio.dart';

class LocalBackend {
  static Process? _process;
  static Timer? _heartbeatTimer;

  static Future<void> start() async {
    if (_process != null) return; // already started

    final appDir = p.dirname(Platform.resolvedExecutable);
    final releaseNodeExe = File(p.join(appDir, 'node.exe'));
    final releaseServerJs = File(p.join(appDir, 'backend', 'src', 'server.js'));

    String nodeCmd;
    List<String> args;
    String workingDir;

    if (releaseNodeExe.existsSync() && releaseServerJs.existsSync()) {
      nodeCmd = releaseNodeExe.path;
      args = [releaseServerJs.path, '--autoclose'];
      workingDir = p.join(appDir, 'backend');
    } else {
      // Debug / Dev mode fallback (run from workspace root using system node)
      print('[LocalBackend] Release binary not found. Falling back to dev mode...');
      Directory dir = Directory.current;
      File? serverJs;
      for (int i = 0; i < 5; i++) {
        final checkFile = File(p.join(dir.path, 'src', 'server.js'));
        if (checkFile.existsSync()) {
          serverJs = checkFile;
          break;
        }
        dir = dir.parent;
      }

      if (serverJs != null) {
        nodeCmd = 'node';
        args = [serverJs.path, '--autoclose'];
        workingDir = p.dirname(p.dirname(serverJs.path)); // workspace root
      } else {
        print('[LocalBackend] Could not locate backend server.js. Skipping autostart.');
        return;
      }
    }

    print('[LocalBackend] Launching backend: $nodeCmd ${args.join(' ')}');
    try {
      _process = await Process.start(
        nodeCmd,
        args,
        workingDirectory: workingDir,
        runInShell: true,
      );

      // Handle process exit / stdout
      _process!.stdout.listen((event) {
        final msg = String.fromCharCodes(event).trim();
        print('[Backend stdout] $msg');
      });
      _process!.stderr.listen((event) {
        final msg = String.fromCharCodes(event).trim();
        print('[Backend stderr] $msg');
      });

      // Wait a brief moment to let server bind to port 3000
      await Future.delayed(const Duration(milliseconds: 1500));
      
      // Start heartbeat timer
      _startHeartbeat();
    } catch (e) {
      print('[LocalBackend] Error starting local backend: $e');
    }
  }

  static void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      try {
        final dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 2),
          receiveTimeout: const Duration(seconds: 2),
        ));
        await dio.post('http://localhost:3000/api/heartbeat');
      } catch (_) {
        // If request fails, server might have shut down or is starting
      }
    });
  }

  static Future<void> stop() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (_process != null) {
      print('[LocalBackend] Terminating local backend process...');
      _process!.kill();
      _process = null;
    }
  }
}
