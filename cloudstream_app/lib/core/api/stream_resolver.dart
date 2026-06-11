// lib/core/api/stream_resolver.dart
// Bridges TMDB metadata → local scraper backend → playable stream sources
//
// Architecture:
//  1. Search provider → get episode list (metadata only, fast)
//  2. Show episode list in Sources panel immediately
//  3. Resolve stream URL ON DEMAND when user selects a source (always fresh)
//  4. For 4KHDHub: all refs resolved in parallel — fastest validated URL wins
//  5. HEAD pre-validation confirms URL is reachable before MPV ever opens it

import 'dart:async';
import 'package:dio/dio.dart';

// AniDB for anime; 4KHDHub for everything else
const List<String> _kProviders = ['anidb', '4khdhub'];

// ── Models ────────────────────────────────────────────────────────────────────

/// A fully-resolved, ready-to-play stream source
class StreamSource {
  final String provider;
  final String label;
  final String quality;
  final String size;
  final String url;          // Direct stream URL (pixel.hubcloud.cx etc.)
  final String fallbackUrl;  // Proxy URL fallback
  final String referer;
  final String subtitleUrl;  // VTT subtitle if available
  final String episodeUrl;   // hubcloud.foo URL — used to re-resolve fresh URL

  const StreamSource({
    required this.provider,
    required this.label,
    required this.quality,
    this.size = '',
    required this.url,
    this.fallbackUrl = '',
    required this.referer,
    this.subtitleUrl = '',
    this.episodeUrl = '',
  });

  /// Re-resolve a fresh stream URL (call when URL expires)
  Future<StreamSource?> refresh() =>
      StreamResolver.instance.resolveStreamForEpisode(
        provider: provider,
        episodeUrl: episodeUrl,
        quality: quality,
        size: size,
        label: label,
      );
}

/// Episode metadata from /details — NOT yet resolved to a stream URL.
/// Used to show source list instantly without waiting for stream resolution.
class EpisodeRef {
  final String provider;
  final String quality;
  final String size;
  final String title;
  final String episodeUrl; // hubcloud.foo or anidao watch URL
  final String episodeNumber; // e.g. '1', '2', '3' from provider

  const EpisodeRef({
    required this.provider,
    required this.quality,
    required this.size,
    required this.title,
    required this.episodeUrl,
    this.episodeNumber = '',
  });

  String get label {
    final providerLabel = switch (provider) {
      '4khdhub' => '4KHD Hub',
      'hdhub4u' => 'HDHub4U',
      'anidao'  => 'AniDAO',
      'anidb'   => 'AniDB',
      _         => provider,
    };
    final sizePart = size.isNotEmpty ? ' · $size' : '';
    final titlePart = title.isNotEmpty ? ' · ${title.split('\n').first.trim()}' : '';
    return '$providerLabel [$quality]$sizePart$titlePart';
  }

  /// Display label for the quality badge — 'Unknown' becomes 'Multi' for HLS adaptive
  String get qualityBadge {
    if (quality.isEmpty || quality == 'Unknown') return 'Multi';
    return quality;
  }
}

// ── Resolver ──────────────────────────────────────────────────────────────────

class StreamResolver {
  static const String _baseUrl = 'http://localhost:3000';

  /// Main Dio: used for /search, /details, /stream backend calls.
  final Dio _dio = Dio(BaseOptions(
    baseUrl: _baseUrl,
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 20),
    validateStatus: (s) => true,
  ));

  /// Validator Dio: fire-and-forget HEAD checks on CDN URLs.
  /// Short timeouts — we only need to know the file exists.
  final Dio _headDio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 6),
    validateStatus: (_) => true,
  ));

  StreamResolver._();
  static final instance = StreamResolver._();

  /// Shared Dio instance for proxy requests (e.g. fetching HLS playlists).
  static Dio get dio => instance._dio;

  /// Returns true if the backend is reachable.
  Future<bool> ping() async {
    try {
      final r = await _dio.get('/health',
          options: Options(
            sendTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 3),
          ));
      return r.statusCode == 200;
    } catch (_) { return false; }
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Fast: returns the first working, pre-validated stream source for immediate playback.
  ///
  /// For anime  (isAnime=true): resolves AniDB refs sequentially (Sub preferred).
  /// For non-anime (isAnime=false): resolves ALL 4KHDHub refs IN PARALLEL and
  ///   returns the first one that passes a HEAD validation — meaning MPV will
  ///   definitely be able to open it without a buffering failure.
  Future<StreamSource?> resolveFirstSource({
    required String title,
    required String mediaType,
    required String year,
    String? seasonNumber,
    String? episodeNumber,
    String? preferredQuality,
    bool isAnime = false,
  }) async {
    final provider = isAnime ? 'anidb' : '4khdhub';
    print('[StreamResolver] resolveFirstSource: isAnime=$isAnime → $provider');

    try {
      final refs = await _getEpisodeRefs(
        provider: provider, title: title, mediaType: mediaType,
        year: year, seasonNumber: seasonNumber, episodeNumber: episodeNumber,
        maxRefs: isAnime ? 3 : 8, // grab more 4KHDHub refs for parallel racing
      );
      if (refs.isEmpty) return null;

      // ── AniDB: sequential with Sub preference ────────────────────────────
      if (isAnime) {
        final sortedRefs = <EpisodeRef>[];
        if (preferredQuality != null) {
          sortedRefs.addAll(refs.where((r) => r.quality.toLowerCase() == preferredQuality.toLowerCase()));
          sortedRefs.addAll(refs.where((r) => r.quality.toLowerCase() != preferredQuality.toLowerCase()));
        } else {
          sortedRefs.addAll(refs);
        }
        for (final ref in sortedRefs) {
          final src = await resolveStreamForEpisode(
            provider: provider, episodeUrl: ref.episodeUrl,
            quality: ref.quality, size: ref.size, label: ref.label,
          );
          if (src != null) return src;
        }
        return null;
      }

      // ── 4KHDHub: resolve ALL refs in parallel, first validated URL wins ──
      print('[StreamResolver] Racing ${refs.length} 4KHDHub refs in parallel…');
      final completer = Completer<StreamSource?>();
      int pending = refs.length;

      for (final ref in refs) {
        resolveStreamForEpisode(
          provider: provider, episodeUrl: ref.episodeUrl,
          quality: ref.quality, size: ref.size, label: ref.label,
        ).then((src) async {
          if (completer.isCompleted) return;
          if (src == null) {
            if (--pending == 0) completer.complete(null);
            return;
          }
          // HEAD-validate: confirm the CDN URL is reachable & is a video file
          final valid = await _validateUrl(src.url);
          if (completer.isCompleted) return;
          if (valid) {
            print('[StreamResolver] ✓ Validated: ${src.label}');
            completer.complete(src);
          } else {
            print('[StreamResolver] ✗ HEAD failed, skipping: ${src.url.substring(0, 60)}…');
            if (--pending == 0) completer.complete(null);
          }
        }).catchError((_) {
          if (!completer.isCompleted && --pending == 0) completer.complete(null);
        });
      }

      // Overall timeout: if nothing validated in 45s, give up
      return completer.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          if (!completer.isCompleted) completer.complete(null);
          return null;
        },
      );
    } catch (_) {
      return null;
    }
  }

  /// Quick HEAD validation: returns true if the URL is reachable with a
  /// 200/206 response and has a non-zero Content-Length (or is HLS .m3u8).
  /// This is the key guard — if this passes, MPV will definitely play the file.
  Future<bool> _validateUrl(String url) async {
    if (url.isEmpty) return false;
    try {
      // HLS playlists don't work well with HEAD — trust them directly
      if (url.contains('.m3u8')) {
        print('[StreamResolver] [validate] HLS — trusting without HEAD: $url');
        return true;
      }
      // For direct video files: send a Range: bytes=0-1023 request
      // This is lighter than a full HEAD and works on more CDNs
      final resp = await _headDio.get(
        url,
        options: Options(
          headers: {
            'Range': 'bytes=0-1023',
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          },
          responseType: ResponseType.bytes,
          receiveDataWhenStatusError: false,
        ),
      );
      final status = resp.statusCode ?? 0;
      final ok = status == 200 || status == 206;
      final contentLength = int.tryParse(
        resp.headers.value('content-length') ?? '0') ?? 0;
      final valid = ok && contentLength > 1000; // at least 1KB = real content
      print('[StreamResolver] [validate] status=$status len=$contentLength → ${valid ? "OK" : "FAIL"}');
      return valid;
    } catch (e) {
      print('[StreamResolver] [validate] Exception: $e');
      return false;
    }
  }

  /// Returns episode refs for the Sources panel.
  /// For anime (isAnime=true): AniDB only.
  /// For non-anime (isAnime=false): 4KHDHub only — AniDB is never tried.
  Future<List<EpisodeRef>> getEpisodeRefs({
    required String title,
    required String mediaType,
    required String year,
    String? seasonNumber,
    String? episodeNumber,
    bool isAnime = false,
  }) async {
    final provider = isAnime ? 'anidb' : '4khdhub';
    print('[StreamResolver] getEpisodeRefs isAnime=$isAnime → provider: $provider');
    return _getEpisodeRefs(
      provider: provider, title: title, mediaType: mediaType,
      year: year, seasonNumber: seasonNumber, episodeNumber: episodeNumber,
    ).catchError((_) => <EpisodeRef>[]);
  }

  /// Resolves a stream URL for a specific episode ref (always fresh).
  Future<StreamSource?> resolveStreamForEpisode({
    required String provider,
    required String episodeUrl,
    required String quality,
    required String size,
    required String label,
  }) async {
    try {
      if (episodeUrl.isEmpty) return null;
      print('[StreamResolver] [$provider] Resolving stream: $episodeUrl');

      final epUrlEnc = Uri.encodeComponent(episodeUrl);
      final resp = await _dio.get('/stream?provider=$provider&url=$epUrlEnc');

      if (resp.statusCode != 200) return null;
      final data = resp.data;
      if (data == null || data['success'] != true) return null;

      final streams = data['streams'];
      if (streams == null) return null;

      final streamUrl = streams['streamUrl']?.toString() ?? '';
      final proxyUrl = streams['proxyUrl']?.toString() ?? '';
      final referer = streams['referer']?.toString() ?? '';

      // Strategy: always use the DIRECT stream URL and let MPV handle HLS natively.
      // MPV receives correct User-Agent + Referer via properties set in _openSource,
      // so it can fetch playlists AND segments from the CDN without a proxy middleman.
      // The proxyUrl is kept as fallback for cases where direct access truly fails.
      final String playUrl;
      if (streamUrl.isNotEmpty) {
        playUrl = streamUrl; // Direct CDN URL — MPV handles headers natively
      } else if (proxyUrl.isNotEmpty) {
        playUrl = proxyUrl; // Fallback to proxy if no direct URL
      } else {
        return null;
      }

      // Extract subtitle from AniDAO referer ?sub= param
      String subtitleUrl = '';
      if (referer.contains('?sub=') || referer.contains('&sub=')) {
        try {
          final uri = Uri.parse(referer);
          subtitleUrl = uri.queryParameters['sub'] ?? '';
        } catch (_) {}
      }

      print('[StreamResolver] [$provider] ✓ Resolved: $label${subtitleUrl.isNotEmpty ? ' [CC]' : ''}');
      return StreamSource(
        provider: provider,
        label: label,
        quality: quality,
        size: size,
        url: playUrl,
        fallbackUrl: proxyUrl != playUrl ? proxyUrl : '',
        referer: referer,
        subtitleUrl: subtitleUrl,
        episodeUrl: episodeUrl,
      );
    } catch (e) {
      print('[StreamResolver] [$provider] Error resolving stream: $e');
      return null;
    }
  }

  // ── Internal ────────────────────────────────────────────────────────────────

  /// Gets episode metadata (from /search + /details) WITHOUT resolving stream URLs.
  /// Very fast — just two HTTP calls regardless of number of episodes.
  Future<List<EpisodeRef>> _getEpisodeRefs({
    required String provider,
    required String title,
    required String mediaType,
    required String year,
    String? seasonNumber,
    String? episodeNumber,
    int maxRefs = 999,
  }) async {
    try {
      // Step 1: Search
      final encoded = Uri.encodeComponent(title);
      print('[StreamResolver] [$provider] Searching: $title');
      final searchResp = await _dio.get('/search?q=$encoded&provider=$provider');
      if (searchResp.statusCode != 200) return [];
      final searchData = searchResp.data;
      if (searchData?['success'] != true) return [];

      final results = (searchData['results'] as List?) ?? [];
      print('[StreamResolver] [$provider] ${results.length} results');
      if (results.isEmpty) return [];

      // Step 2: Best match
      final cleanTitle = _clean(title);
      Map<String, dynamic>? best;
      int bestScore = -1;
      for (final r in results) {
        if (r is! Map<String, dynamic>) continue;
        final score = _matchScore(cleanTitle, _clean(r['title']?.toString() ?? ''), year);
        if (score > bestScore) { bestScore = score; best = r; }
      }
      if (best == null || bestScore < 1) {
        print('[StreamResolver] [$provider] No match (score=$bestScore)');
        return [];
      }
      final detailUrl = best['url']?.toString() ?? '';
      print('[StreamResolver] [$provider] Match: "${best['title']}" score=$bestScore');
      if (detailUrl.isEmpty) return [];

      // Step 3: Details
      final detailEnc = Uri.encodeComponent(detailUrl);
      final detailResp = await _dio.get('/details?provider=$provider&url=$detailEnc');
      if (detailResp.statusCode != 200) return [];
      final detailData = detailResp.data;
      if (detailData?['success'] != true) return [];

      final episodes = (detailData['details']?['episodes'] as List?) ?? [];
      print('[StreamResolver] [$provider] ${episodes.length} episodes');
      if (episodes.isEmpty) return [];

      // Step 4: Filter/sort episodes
      List<Map<String, dynamic>> targets = [];
      if (mediaType == 'movie') {
        final sorted = List<Map<String, dynamic>>.from(
          episodes.whereType<Map<String, dynamic>>(),
        );
        sorted.sort((a, b) {
          final aS = _parseGB(a['size']?.toString() ?? '');
          final bS = _parseGB(b['size']?.toString() ?? '');
          return aS.compareTo(bS);
        });
        targets = sorted;
      } else {
        // TV: find ALL quality variants for the matching episode
        targets = _findAllEpisodesForNumber(episodes, seasonNumber, episodeNumber);
        // Sort smallest first for faster initial load
        targets.sort((a, b) {
          final aS = _parseGB(a['size']?.toString() ?? '');
          final bS = _parseGB(b['size']?.toString() ?? '');
          return aS.compareTo(bS);
        });
        // Fallback: if no match, return empty
      }

      // Step 5: Build EpisodeRef list (NO stream URL resolution here — instant!)
      final refs = <EpisodeRef>[];
      for (final t in targets) {
        final epUrl = t['url']?.toString() ?? '';
        if (epUrl.isEmpty) continue;
        refs.add(EpisodeRef(
          provider: provider,
          quality: t['quality']?.toString() ?? 'Unknown',
          size: t['size']?.toString() ?? '',
          title: t['title']?.toString() ?? '',
          episodeUrl: epUrl,
          episodeNumber: t['episode']?.toString() ?? '',
        ));
        if (refs.length >= maxRefs) break;
      }
      print('[StreamResolver] [$provider] Returning ${refs.length} episode refs');
      return refs;
    } catch (e) {
      print('[StreamResolver] [$provider] Exception in _getEpisodeRefs: $e');
      return [];
    }
  }

  /// Returns ALL episodes for the Episodes panel — AniDB-first (same logic as getEpisodeRefs).
  Future<List<EpisodeRef>> getAllEpisodes({
    required String title,
    required String mediaType,
    required String year,
    String? seasonNumber,
  }) async {
    // Try AniDB first
    final anidbEps = await _getProviderAllEpisodes(
      provider: 'anidb', title: title, mediaType: mediaType,
      year: year, seasonNumber: seasonNumber,
    ).catchError((_) => <EpisodeRef>[]);
    if (anidbEps.isNotEmpty) return anidbEps; // It's anime

    // Fallback to 4KHDHub for non-anime content
    return _getProviderAllEpisodes(
      provider: '4khdhub', title: title, mediaType: mediaType,
      year: year, seasonNumber: seasonNumber,
    ).catchError((_) => <EpisodeRef>[]);
  }

  /// Fetches every episode from one provider (search → best match → all episodes).
  Future<List<EpisodeRef>> _getProviderAllEpisodes({
    required String provider,
    required String title,
    required String mediaType,
    required String year,
    String? seasonNumber,
  }) async {
    try {
      final encoded = Uri.encodeComponent(title);
      final searchResp = await _dio.get('/search?q=$encoded&provider=$provider');
      if (searchResp.statusCode != 200) return [];
      final searchData = searchResp.data;
      if (searchData?['success'] != true) return [];
      final results = (searchData['results'] as List?) ?? [];
      if (results.isEmpty) return [];

      final cleanTitle = _clean(title);
      Map<String, dynamic>? best;
      int bestScore = -1;
      for (final r in results) {
        if (r is! Map<String, dynamic>) continue;
        final score = _matchScore(cleanTitle, _clean(r['title']?.toString() ?? ''), year);
        if (score > bestScore) { bestScore = score; best = r; }
      }
      if (best == null || bestScore < 1) return [];
      final detailUrl = best['url']?.toString() ?? '';
      if (detailUrl.isEmpty) return [];

      final detailEnc = Uri.encodeComponent(detailUrl);
      final detailResp = await _dio.get('/details?provider=$provider&url=$detailEnc');
      if (detailResp.statusCode != 200) return [];
      final detailData = detailResp.data;
      if (detailData?['success'] != true) return [];

      final episodes = (detailData['details']?['episodes'] as List?)
          ?.whereType<Map<String, dynamic>>().toList() ?? [];

      return episodes.take(500).expand<EpisodeRef>((ep) {
        final epUrl = ep['url']?.toString() ?? '';
        if (epUrl.isEmpty) return [];
        return [EpisodeRef(
          provider: provider,
          quality: ep['quality']?.toString() ?? 'Unknown',
          size: ep['size']?.toString() ?? '',
          title: ep['title']?.toString() ?? '',
          episodeUrl: epUrl,
          episodeNumber: ep['episode']?.toString() ?? '',
        )];
      }).toList();
    } catch (_) { return []; }
  }


  // ── Helpers ───────────────────────────────────────────────────

  double _parseGB(String s) {
    final m = RegExp(r'([\d.]+)\s*(GB|MB|TB)', caseSensitive: false).firstMatch(s);
    if (m == null) return 999.0;
    final v = double.tryParse(m.group(1) ?? '0') ?? 0;
    return switch (m.group(2)?.toUpperCase()) {
      'MB' => v / 1024, 'TB' => v * 1024, _ => v,
    };
  }

  String _clean(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  int _matchScore(String search, String candidate, String year) {
    if (candidate.isEmpty) return 0;
    if (candidate == search) return 200;
    final sWords = search.split(' ').where((w) => w.length > 1).toSet();
    final cWords = candidate.split(' ').toSet();
    final overlap = sWords.intersection(cWords).length;
    int score = 0;
    if (overlap == sWords.length && sWords.isNotEmpty) score += 80;
    if (candidate.contains(search)) score += 60;
    if (search.contains(candidate)) score += 40;
    if (year.isNotEmpty && candidate.contains(year)) score += 20;
    score += overlap * 10;
    return score;
  }

  /// Returns ALL episode entries matching the requested season+episode number.
  /// Priority:
  ///   1. Title has s##e## pattern → only match the exact requested season+ep
  ///   2. Title has NO season info → match by episode field (e.g. "Episode-01")
  ///   3. Fallback by index grouped by episode field value
  List<Map<String, dynamic>> _findAllEpisodesForNumber(
      List eps, String? seasonNumber, String? episodeNumber) {
    final s    = int.tryParse(seasonNumber ?? '1') ?? 1;
    final e    = int.tryParse(episodeNumber ?? '1') ?? 1;
    final sPad = s.toString().padLeft(2, '0'); // "05"
    final ePad = e.toString().padLeft(2, '0'); // "01"

    final matchedWithSeason = <Map<String, dynamic>>[];
    final matchedEpOnly     = <Map<String, dynamic>>[];
    final seasonRx = RegExp(r's\d{1,2}e\d{1,2}', caseSensitive: false);

    // Detect if any episodes use season-patterned filenames (e.g. S22E39)
    // If they do, we MUST match exactly — no index fallback allowed
    bool anyHasSeasonPattern = false;

    for (final ep in eps) {
      if (ep is! Map<String, dynamic>) continue;
      final t     = (ep['title']?.toString() ?? '').toLowerCase();
      final epStr = (ep['episode']?.toString() ?? '').toLowerCase();

      if (seasonRx.hasMatch(t)) {
        anyHasSeasonPattern = true;
        // Title contains season info → require exact season+episode match
        if (t.contains('s${sPad}e$ePad') ||
            t.contains('s${sPad}e$e')    ||
            t.contains('s${s}e$ePad')    ||
            t.contains('s${s}e$e')) {
          matchedWithSeason.add(ep);
        }
      } else {
        // No season in title → match by episode field only
        if (epStr == 'episode-$ePad' ||
            epStr == 'episode-$e'    ||
            epStr == 'episode $e'    ||
            epStr == 'ep$ePad'       ||
            epStr == 'ep$e'          ||
            epStr == '$e'            ||
            epStr == ePad) {
          matchedEpOnly.add(ep);
        }
      }
    }

    if (matchedWithSeason.isNotEmpty) return matchedWithSeason;
    if (matchedEpOnly.isNotEmpty)     return matchedEpOnly;

    // Season-patterned content (e.g. One Piece S22Exx) with no exact match.
    // Try cross-season: find eXX matching the episode number.
    if (anyHasSeasonPattern) {
      final crossSeason = <Map<String, dynamic>>[];
      for (final ep in eps) {
        if (ep is! Map<String, dynamic>) continue;
        final t = (ep['title']?.toString() ?? '').toLowerCase();
        if (RegExp('e${ePad}[^\\d]').hasMatch(t) ||
            RegExp('e${e}[^\\d]').hasMatch(t) ||
            t.endsWith('e${ePad}') ||
            t.endsWith('e${e}')) {
          crossSeason.add(ep);
        }
      }
      if (crossSeason.isNotEmpty) {
        print('[StreamResolver] Cross-season match for E$ePad: ${crossSeason.length} variants');
        return crossSeason;
      }
      // No cross-season match → return empty. The episode truly doesn't exist in this provider.
      print('[StreamResolver] Season-patterned: no match for E$ePad in any season — returning empty');
      return [];
    }

    // No season patterns → safe to use index fallback
    if (eps.length >= e) {
      final first = eps[e - 1];
      if (first is Map<String, dynamic>) {
        final key = (first['episode']?.toString() ?? '').toLowerCase();
        if (key.isNotEmpty) {
          final group = eps
              .whereType<Map<String, dynamic>>() 
              .where((x) => (x['episode']?.toString() ?? '').toLowerCase() == key)
              .toList();
          if (group.isNotEmpty) return group;
        }
        return [first];
      }
    }
    if (eps.isNotEmpty) {
      final ep = eps.first;
      if (ep is Map<String, dynamic>) return [ep];
    }
    return [];
  }

  Map<String, dynamic>? _findEpisode(List eps, String? sNum, String? eNum) {
    final s = int.tryParse(sNum ?? '1') ?? 1;
    final e = int.tryParse(eNum ?? '1') ?? 1;
    for (final ep in eps) {
      if (ep is! Map<String, dynamic>) continue;
      final t = (ep['title']?.toString() ?? '').toLowerCase();
      final epStr = ep['episode']?.toString() ?? '';
      if (t.contains('s${s}e$e') || t.contains('episode $e') ||
          t.contains('ep $e') || t.contains('ep$e') || epStr == '$e') return ep;
    }
    if (eps.length >= e) { final ep = eps[e - 1]; if (ep is Map<String, dynamic>) return ep; }
    if (eps.isNotEmpty) { final ep = eps.first; if (ep is Map<String, dynamic>) return ep; }
    return null;
  }
}
