// lib/core/api/dns_over_https.dart
//
// Bypasses Jio's DNS blocking of api.themoviedb.org by resolving hostnames
// via Cloudflare's DNS-over-HTTPS endpoint at IP 1.1.1.1 (not blocked).
//
// How it works:
//   1. At app startup, call DnsOverHttps.prefetch() to resolve TMDB IPs.
//   2. Dio is configured with an IOHttpClientAdapter that connects directly
//      to the resolved IP, keeping the original hostname for TLS/SNI so that
//      certificate validation still passes.

import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

class DnsOverHttps {
  DnsOverHttps._();

  /// IP cache: hostname → resolved IP address
  static final Map<String, String> _cache = {};

  /// Hostnames to prefetch at startup
  static const _tmdbHosts = [
    'api.themoviedb.org',
    'image.tmdb.org',
  ];

  // ── Public API ──────────────────────────────────────────────────────────

  /// Call once at app start (in main() before runApp).
  /// Silently succeeds even if network is unavailable.
  static Future<void> prefetch() async {
    await Future.wait(
      _tmdbHosts.map(_resolve),
      eagerError: false,
    );
  }

  /// Returns a [Dio] instance whose HTTP client uses DoH-resolved IPs.
  static Dio createDio({
    required String baseUrl,
    required Map<String, String> headers,
    Duration connectTimeout = const Duration(seconds: 12),
    Duration receiveTimeout = const Duration(seconds: 20),
  }) {
    final dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      headers: headers,
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
    ));

    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: _buildClient,
    );

    return dio;
  }

  // ── Internal ────────────────────────────────────────────────────────────

  /// Resolves [hostname] via Cloudflare/Google/Quad9 DoH and stores the result in [_cache].
  static Future<void> _resolve(String hostname) async {
    if (_cache.containsKey(hostname)) return;

    // DoH provider IPs to try in order
    final dnsIps = ['1.1.1.1', '8.8.8.8', '9.9.9.9'];

    for (final ip in dnsIps) {
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 4)
          ..badCertificateCallback = (_, __, ___) => false; // strict for DoH itself

        final req = await client.getUrl(
          Uri.parse('https://$ip/dns-query?name=$hostname&type=A'),
        );
        req.headers.set('accept', 'application/dns-json');
        final resp = await req.close();

        final body = await resp.transform(utf8.decoder).join();
        client.close();

        final data = jsonDecode(body) as Map<String, dynamic>;
        final answers = data['Answer'] as List?;
        if (answers != null) {
          for (final a in answers) {
            if (a['type'] == 1) {
              // A record — IPv4 address
              final resolved = a['data'] as String;
              if (resolved.isNotEmpty) {
                _cache[hostname] = resolved;
                print('[DnsOverHttps] Resolved $hostname -> $resolved via $ip');
                return;
              }
            }
          }
        }
      } catch (e) {
        print('[DnsOverHttps] Resolve $hostname via $ip failed: $e');
        // Continue to next provider
      }
    }
  }

  /// Builds an [HttpClient] whose [connectionFactory] routes TMDB traffic
  /// to the DoH-resolved IP while keeping the original hostname for TLS SNI.
  static HttpClient _buildClient() {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);

    client.connectionFactory =
        (Uri uri, String? proxyHost, int? proxyPort) async {
      final host = uri.host;
      final resolvedIp = _cache[host] ?? host; // fall back to original hostname
      final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);

      if (uri.scheme == 'https') {
        // Connect TCP to resolved IP, then upgrade with SNI = original hostname
        final rawSocket = await Socket.connect(resolvedIp, port);
        final secureSocket = await SecureSocket.secure(
          rawSocket,
          host: host, // SNI — server picks the correct certificate for this hostname
          supportedProtocols: const ['http/1.1'],
        );
        return ConnectionTask.fromSocket(Future.value(secureSocket), () {});
      } else {
        final socket = await Socket.connect(resolvedIp, port);
        return ConnectionTask.fromSocket(Future.value(socket), () {});
      }
    };

    return client;
  }
}
