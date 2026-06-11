// lib/features/player/player_screen.dart
// Full player: lazy episode refs, on-demand fresh URL resolution, quality+subtitle panel

import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:window_manager/window_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/stream_resolver.dart';
import '../../core/api/simkl_api.dart';
import '../../core/models/tmdb_models.dart';
import '../../core/services/local_db.dart';
import '../../shared/theme/app_theme.dart';

enum _LoadState { fetching, playing, error }
enum _PanelTab { none, sources, episodes, quality, audio, subtitles }

class PlayerScreen extends StatefulWidget {
  final String tmdbId;
  final int simklId;  // SIMKL ID for episode metadata (0 if not known)
  final String mediaType;
  final String title;
  final String year;
  final String seasonNumber;
  final String episodeNumber;
  final String episodeTitle;
  final bool isAnime;
  final String? preloadedUrl;
  final String? preloadedProvider;
  final String? backdropUrl;
  final String? logoUrl;

  const PlayerScreen({
    super.key,
    required this.tmdbId,
    this.simklId = 0,
    required this.mediaType,
    required this.title,
    required this.year,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.episodeTitle,
    this.isAnime = false,
    this.preloadedUrl,
    this.preloadedProvider,
    this.backdropUrl,
    this.logoUrl,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _videoCtrl;

  _LoadState _loadState = _LoadState.fetching;
  String? _error;
  String _loadStep = 'Getting things ready…'; // user-friendly loading step message
  String? _backdropUrl;
  String? _logoUrl;

  // Sources (lazy refs — just metadata, no stream URL pre-fetched)
  List<EpisodeRef> _episodeRefs = [];
  List<TmdbEpisode> _tmdbEpisodes = []; // TMDB episodes for the Episodes panel
  bool _tmdbEpisodesLoading = false;
  int _selectedSeasonNumber = 1; // Which season is shown in Episodes panel
  List<TmdbSeason> _allSeasons = []; // All seasons for the dropdown
  int _activeRefIdx = 0;
  bool _isResolvingSource = false;
  StreamSource? _currentSource;

  // HLS quality tracks from player
  Tracks _tracks = const Tracks();
  VideoTrack _activeVideo = VideoTrack.auto();
  AudioTrack _activeAudio = AudioTrack.auto();
  SubtitleTrack _activeSubtitle = SubtitleTrack.no();

  // HLS quality variants parsed from master.m3u8 (for Quality panel)
  List<_HlsVariant> _hlsVariants = [];
  int _activeVariantBandwidth = -1; // -1 = Auto (hls-bitrate=max)

  // Panel
  _PanelTab _panel = _PanelTab.none;
  bool _showControls = false;
  Timer? _hideTimer;

  // Next episode overlay (shown in last 90s, auto-plays with countdown)
  bool _showNextEp = false;
  int _nextEpCountdown = 5;   // seconds until auto-play
  Timer? _nextEpTimer;        // countdown tick timer

  // Playback
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  bool _isPlaying = false;
  bool _isBuffering = false;
  double _volume = 1.0;
  double _speed = 1.0;
  bool _isDragging = false;
  double _dragValue = 0.0;

  // Aspect ratio: 'fit' | 'crop' | 'stretch'
  String _aspectRatio = 'fit';

  // Fullscreen
  bool _isFullscreen = false;

  // Seek flash animation: -1 = backward, 0 = none, +1 = forward
  int _seekFlash = 0;
  Timer? _seekFlashTimer;

  // Next-episode background preload
  StreamSource? _preloadedNextSrc;
  bool _preloadingNext = false;

  // Setting: pause when app loses focus
  bool _pauseOnFocusLoss = true;

  Timer? _bufferPollTimer;

  final List<StreamSubscription> _subs = [];
  Timer? _progressTimer;

  @override
  void initState() {
    super.initState();
    _player = Player(configuration: const PlayerConfiguration(logLevel: MPVLogLevel.error));
    _videoCtrl = VideoController(_player);

    // Configure MPV for YouTube-like pre-buffering to avoid interruptions
    // Especially important on Cloudflare/slow DNS setups
    _configureBuffer();

    _subs.addAll([
      _player.stream.position.listen((p) {
        if (_isDragging || !mounted) return;
        setState(() => _position = p);
        _checkSkipOverlays(p);
      }),
      _player.stream.duration.listen((d) { if (mounted) setState(() => _duration = d); }),
      _player.stream.playing.listen((p) { if (mounted) setState(() => _isPlaying = p); }),
      _player.stream.buffering.listen((b) {
        if (mounted) {
          setState(() {
            _isBuffering = b;
            if (b) {
              _showControls = false;
              _hideTimer?.cancel();
            }
          });
        }
      }),
      _player.stream.volume.listen((v) { if (mounted) setState(() => _volume = v / 100.0); }),
      _player.stream.tracks.listen((t) { if (mounted) setState(() => _tracks = t); }),
      _player.stream.track.listen((t) {
        if (mounted) setState(() {
          _activeVideo = t.video;
          _activeAudio = t.audio;
          _activeSubtitle = t.subtitle;
        });
      }),
      _player.stream.error.listen((e) {
        if (e.isNotEmpty && mounted) _onPlaybackError(e);
      }),
      // Auto-play next episode when current finishes
      _player.stream.completed.listen((done) {
        if (done && mounted && widget.mediaType == 'tv') {
          Future.delayed(const Duration(milliseconds: 500), _goNextEpisode);
        }
      }),
    ]);

    _selectedSeasonNumber = int.tryParse(widget.seasonNumber) ?? 1;
    _backdropUrl = widget.backdropUrl;
    _logoUrl = widget.logoUrl;
    if ((_backdropUrl == null || _backdropUrl!.isEmpty) || (_logoUrl == null || _logoUrl!.isEmpty)) {
      _fetchMediaDetailsIfNeeded();
    }
    _resolveAndPlay();
    _scheduleHide();
    _loadSettings();
    _loadAllSeasons(); // Load seasons list for Episodes panel dropdown
    // Proactively load episodes so the panel is ready when opened
    if (widget.mediaType == 'tv') {
      Future.microtask(() => _loadTmdbEpisodes());
    }
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_pauseOnFocusLoss) return; // user disabled pause-on-focus-loss
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.inactive) {
      try { _player.pause(); } catch (_) {}
    }
  }

  @override
  void dispose() {
    _nextEpTimer?.cancel();
    _bufferPollTimer?.cancel();
    _seekFlashTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_isFullscreen) {
      try {
        windowManager.setFullScreen(false);
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      } catch (_) {}
    }
    // Pause first to let MPV flush any pending HLS segment reads
    try { _player.pause(); } catch (_) {}
    _hideTimer?.cancel();
    _progressTimer?.cancel();
    // Cancel all Dart stream subscriptions before disposing native player
    for (final s in _subs) s.cancel();
    // dispose() internally calls stop+cleanup — don't call stop() separately
    _player.dispose();
    super.dispose();
  }

  // ── Resolution ──────────────────────────────────────────────────────────────

  Future<void> _resolveAndPlay() async {
    if (mounted) setState(() {
      _loadState = _LoadState.fetching;
      _error = null;
      _episodeRefs = [];
      _currentSource = null;
      _loadStep = 'Looking up "${widget.title}"…';
    });

    try {
      // Step 0: Check if we have a preloaded source
      if (widget.preloadedUrl != null && widget.preloadedUrl!.isNotEmpty) {
        final isDub = widget.preloadedUrl!.contains('lang=eng') || 
                      widget.preloadedUrl!.contains('quality=Dub');
        final preloadedSrc = StreamSource(
          provider: widget.preloadedProvider ?? 'anidb',
          label: widget.preloadedProvider == 'anidb'
              ? (isDub ? 'AniDB [Dub]' : 'AniDB [Sub]')
              : 'Preloaded Source',
          quality: isDub ? 'Dub' : 'Sub',
          size: '',
          url: widget.preloadedUrl!,
          fallbackUrl: '',
          referer: 'https://anidb.app/',
          subtitleUrl: '',
          episodeUrl: '', // Will populate from getEpisodeRefs below
        );

        if (mounted) setState(() {
          _currentSource = preloadedSrc;
          _loadState = _LoadState.playing;
        });

        await _openSource(preloadedSrc);
        _saveHistory();

        // Load sources panel in background (non-blocking)
        StreamResolver.instance.getEpisodeRefs(
          title: widget.title, mediaType: widget.mediaType, year: widget.year,
          seasonNumber: widget.seasonNumber.isEmpty ? null : widget.seasonNumber,
          episodeNumber: widget.episodeNumber.isEmpty ? null : widget.episodeNumber,
          isAnime: widget.isAnime,
        ).then((refs) {
          if (!mounted) return;
          setState(() {
            _episodeRefs = refs;
            final idx = refs.indexWhere((r) =>
                r.provider == preloadedSrc.provider &&
                (r.episodeUrl == preloadedSrc.url || 
                 preloadedSrc.url.contains(r.episodeUrl.split('?').first)));
            if (idx >= 0) _activeRefIdx = idx;
          });
        }).catchError((_) {});

        return;
      }

      // Step 1: Load preferred language and resolve first playable source
      final prefs = await SharedPreferences.getInstance();
      final prefLang = prefs.getString('preferred_anidb_lang') ?? 'Sub';

      // resolveFirstSource races providers in the correct order based on isAnime
      final first = await StreamResolver.instance.resolveFirstSource(
        title: widget.title, mediaType: widget.mediaType, year: widget.year,
        seasonNumber: widget.seasonNumber.isEmpty ? null : widget.seasonNumber,
        episodeNumber: widget.episodeNumber.isEmpty ? null : widget.episodeNumber,
        preferredQuality: prefLang,
        isAnime: widget.isAnime,
      );

      // Step 2: Check we got something
      if (first == null) {
        final backendUp = await StreamResolver.instance.ping();
        if (!backendUp) {
          throw Exception('The streaming service is not running.\nPlease start the backend server and try again.');
        } else {
          throw Exception('"${widget.title}" could not be found.\n\nTry searching with a different title, or this content may not be available yet.');
        }
      }

      // Step 3: Go to playing state IMMEDIATELY — don't wait for Sources panel
      if (mounted) setState(() {
        _currentSource = first;
        _loadState = _LoadState.playing;
      });

      // Step 4: Open video NOW
      await _openSource(first);
      _saveHistory();

      // Step 5: Load sources panel in background (non-blocking)
      // User is already watching — this just populates the Sources/Quality panels
      StreamResolver.instance.getEpisodeRefs(
        title: widget.title, mediaType: widget.mediaType, year: widget.year,
        seasonNumber: widget.seasonNumber.isEmpty ? null : widget.seasonNumber,
        episodeNumber: widget.episodeNumber.isEmpty ? null : widget.episodeNumber,
        isAnime: widget.isAnime,
      ).then((refs) {
        if (!mounted) return;
        setState(() {
          _episodeRefs = refs;
          final idx = refs.indexWhere((r) =>
              r.provider == first.provider && r.episodeUrl == first.episodeUrl);
          if (idx >= 0) _activeRefIdx = idx;
        });
      }).catchError((_) {});

    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loadState = _LoadState.error; });
    }
  }

  // ── Buffering ──────────────────────────────────────────────────────────────────────

  /// Configure MPV buffer — fast start, large forward+backward cache for smooth seeking.
  void _configureBuffer() async {
    try {
      final native = _player.platform as dynamic;
      await native.setProperty('cache', 'yes');
      // Buffer 60s ahead while watching — seeking within this range is instant
      await native.setProperty('cache-secs', '60');
      await native.setProperty('demuxer-readahead-secs', '5'); // start after 5s buffer
      // Large forward + backward cache so ±10s seeks never need a download
      await native.setProperty('demuxer-max-bytes', '150MiB');
      await native.setProperty('demuxer-max-back-bytes', '100MiB'); // backward seek cache
      // Keyframe seeking — MUCH faster than hr-seek for HLS (no frame decode overhead)
      await native.setProperty('hr-seek', 'no');
      // Don't freeze playback during seek buffer fill
      await native.setProperty('cache-pause', 'no');
      // HLS: best quality + prefetch next playlist segment for smooth playback
      await native.setProperty('hls-bitrate', 'max');
      await native.setProperty('prefetch-playlist', 'yes');
      // Network: reconnect on drop
      await native.setProperty('network-timeout', '20');
      await native.setProperty(
        'stream-lavf-o',
        'reconnect=1,reconnect_at_eof=1,reconnect_streamed=1,reconnect_delay_max=5',
      );
      await native.setProperty('demuxer-thread', 'yes');
      print('[Player] Buffer configured: 5s start, 60s ahead, 150MB fwd + 100MB back');
    } catch (e) {
      print('[Player] Buffer config skipped: $e');
    }
  }

  /// Start polling MPV for buffer position (for the YouTube-style buffer bar).
  void _startBufferPolling() {
    _bufferPollTimer?.cancel();
    _bufferPollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      if (!mounted) return;
      try {
        final native = _player.platform as dynamic;
        final val = await native.getProperty('demuxer-cache-time');
        final secs = double.tryParse(val?.toString() ?? '') ?? 0.0;
        if (mounted) {
          setState(() {
            _buffered = _position + Duration(milliseconds: (secs * 1000).round());
            if (_buffered > _duration && _duration > Duration.zero) _buffered = _duration;
          });
        }
      } catch (_) {}
    });
  }

  // ── Open source ──────────────────────────────────────────────────────────────

  Future<void> _openSource(StreamSource source) async {
    print('[Player] Opening: ${source.url}');

    try {
      final native = _player.platform as dynamic;

      // AniDB streams come from hls.anidb.app which is behind Cloudflare.
      // Cloudflare on hls.anidb.app blocks browser UAs but allows Android Dalvik.
      // We set this BEFORE open() so it applies to every HLS request (master, sub-playlist, segments).
      if (source.provider == 'anidb') {
        await native.setProperty('user-agent',
            'Dalvik/2.1.0 (Linux; U; Android 13; Pixel 7 Build/TQ3A.230805.001)');
      } else {
        await native.setProperty('user-agent',
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
      }

      // Set the Referer header for ALL HLS sub-requests (critical for vibeplayer.site).
      // Without this, CDNs reject sub-playlist and segment requests with 403.
      if (source.referer.isNotEmpty) {
        await native.setProperty('referrer', source.referer);
      }
    } catch (_) {}

    // Open direct stream URL — MPV handles HLS natively using the headers set above.
    await _player.open(Media(source.url), play: true);
    await _player.play();

    // Reset quality variants + buffered position for this new source
    if (mounted) setState(() { _hlsVariants = []; _activeVariantBandwidth = -1; _buffered = Duration.zero; });
    _fetchHlsVariants(source);
    _startBufferPolling(); // YouTube-style: poll MPV for demuxer-cache-time

    // Load subtitle if available
    if (source.subtitleUrl.isNotEmpty) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      try {
        await _player.setSubtitleTrack(SubtitleTrack.uri(source.subtitleUrl, title: 'English', language: 'en'));
        print('[Player] Subtitle loaded: ${source.subtitleUrl}');
      } catch (e) { print('[Player] Subtitle failed: $e'); }
    }
  }

  // ── HLS quality variants ─────────────────────────────────────────────────────

  /// Fetches the HLS master.m3u8 via the local proxy (which handles UA + Referer
  /// correctly for both AniDB/Dalvik and AniDAO/vibeplayer) then parses quality variants.
  void _fetchHlsVariants(StreamSource source) async {
    if (!source.url.contains('.m3u8')) return;

    // Build a proxy URL to fetch the master playlist — proxy handles per-provider headers
    final encodedUrl = Uri.encodeComponent(source.url);
    final encodedRef = Uri.encodeComponent(source.referer);
    final proxyUrl = 'http://localhost:3000/proxy/hls?url=$encodedUrl&ref=$encodedRef';

    try {
      // We use the existing node proxy to fetch with correct UA/Referer
      final resp = await StreamResolver.dio.get<String>(proxyUrl,
          options: Options(responseType: ResponseType.plain, receiveTimeout: const Duration(seconds: 10)));
      if (resp.data == null || !mounted) return;

      final variants = _parseHlsMaster(resp.data!);
      if (variants.isEmpty || !mounted) return;
      setState(() => _hlsVariants = variants);
    } catch (_) {}
  }

  /// Parses an HLS master playlist (possibly with proxy-rewritten variant URLs)
  /// and extracts [{label, bandwidth, resolution}] for the Quality panel.
  List<_HlsVariant> _parseHlsMaster(String m3u8) {
    final lines = m3u8.split('\n');
    final variants = <_HlsVariant>[];
    int bandwidth = 0;
    String resolution = '';

    for (final raw in lines) {
      final line = raw.trim();
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        final bwM = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
        final resM = RegExp(r'RESOLUTION=(\d+x\d+)').firstMatch(line);
        bandwidth = int.tryParse(bwM?.group(1) ?? '') ?? 0;
        resolution = resM?.group(1) ?? '';
      } else if (line.isNotEmpty && !line.startsWith('#') && bandwidth > 0) {
        final label = _resLabel(resolution, bandwidth);
        variants.add(_HlsVariant(label: label, bandwidth: bandwidth, resolution: resolution));
        bandwidth = 0; resolution = '';
      }
    }
    // Sort highest quality first
    variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    return variants;
  }

  /// Convert HLS resolution/bandwidth to a human-readable label.
  String _resLabel(String res, int bw) {
    if (res.isNotEmpty) {
      final h = int.tryParse(res.split('x').last) ?? 0;
      if (h >= 1080) return '1080p';
      if (h >= 720) return '720p';
      if (h >= 480) return '480p';
      return '360p';
    }
    if (bw > 2000000) return '1080p';
    if (bw > 1000000) return '720p';
    if (bw > 500000) return '480p';
    return '360p';
  }

  /// Switches HLS quality by telling MPV to prefer a specific bitrate variant.
  /// Seeks to current position after switching to flush already-cached segments
  /// so the new quality starts playing immediately (not after the buffer drains).
  void _setHlsBitrate(int bandwidth) async {
    try {
      final native = _player.platform as dynamic;
      if (bandwidth < 0) {
        await native.setProperty('hls-bitrate', 'max');
      } else {
        await native.setProperty('hls-bitrate', bandwidth.toString());
      }
      if (mounted) setState(() => _activeVariantBandwidth = bandwidth);
      // Flush buffer: seek to current position forces MPV to reload at new quality
      final pos = _position;
      if (pos > Duration.zero) {
        await Future.delayed(const Duration(milliseconds: 200));
        if (mounted) {
          try { await _player.seek(pos); } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Select a source from the panel — resolves a FRESH stream URL on demand.
  /// Stops old playback immediately, carries over current position to new source.
  Future<void> _selectEpisodeRef(int idx) async {
    if (idx < 0 || idx >= _episodeRefs.length) return;
    final ref = _episodeRefs[idx];

    // 1. Save current playback position BEFORE stopping
    final savedPosition = _position;

    // 2. Immediately pause the old source so it doesn't play in background
    try { await _player.pause(); } catch (_) {}

    setState(() { _activeRefIdx = idx; _isResolvingSource = true; _panel = _PanelTab.none; });

    final src = await StreamResolver.instance.resolveStreamForEpisode(
      provider: ref.provider,
      episodeUrl: ref.episodeUrl,
      quality: ref.quality,
      size: ref.size,
      label: ref.label,
    );

    if (!mounted) return;
    setState(() => _isResolvingSource = false);

    if (src != null) {
      setState(() => _currentSource = src);
      // Save language preference for AniDB
      if (ref.provider == 'anidb') {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('preferred_anidb_lang', ref.quality);
        } catch (_) {}
      }
      await _openSource(src);
      // 3. Resume from saved position if meaningful (> 5 seconds)
      if (savedPosition.inSeconds > 5) {
        await Future.delayed(const Duration(milliseconds: 800));
        if (mounted) {
          try { await _player.seek(savedPosition); } catch (_) {}
        }
      }
    } else {
      // Failed — resume old source
      try { await _player.play(); } catch (_) {}
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load source. Try another.', style: GoogleFonts.inter(fontSize: 12)),
            backgroundColor: Colors.red.shade900, duration: const Duration(seconds: 3)),
      );
    }
  }

  void _onPlaybackError(String err) {
    print('[Player] Playback error: $err');
    if (_currentSource == null) {
      setState(() { _error = err; _loadState = _LoadState.error; });
      return;
    }

    final cur = _currentSource!;

    // For TCP errors on local proxy (connection dropped, etc.) — skip to next source
    // The proxy URL already IS the fallback; if it failed, go to next
    final isProxyError = cur.url.contains('127.0.0.1') || cur.url.contains('localhost');

    // If direct CDN URL failed, try the proxyUrl as fallback
    if (!isProxyError && cur.fallbackUrl.isNotEmpty) {
      print('[Player] Direct CDN failed, trying proxy fallback...');
      final fallback = StreamSource(
        provider: cur.provider, label: '${cur.label} [Proxy]',
        quality: cur.quality, size: cur.size,
        url: cur.fallbackUrl, fallbackUrl: '',
        referer: cur.referer, subtitleUrl: cur.subtitleUrl, episodeUrl: cur.episodeUrl,
      );
      setState(() => _currentSource = fallback);
      _openSource(fallback);
      return;
    }

    // Proxy failed or no fallback — re-resolve next source fresh
    final nextIdx = _activeRefIdx + 1;
    if (nextIdx < _episodeRefs.length) {
      print('[Player] Trying next source ($nextIdx/${_episodeRefs.length})...');
      // Go back to animated loading screen while we try the next source
      setState(() {
        _loadState = _LoadState.fetching;
        _loadStep = 'Trying another source ($nextIdx/${_episodeRefs.length})…';
      });
      _selectEpisodeRef(nextIdx);
    } else if (_episodeRefs.isEmpty && cur.episodeUrl.isNotEmpty) {
      // No refs loaded yet — show error
      setState(() { _error = err; _loadState = _LoadState.error; });
    } else {
      setState(() { _error = err; _loadState = _LoadState.error; });
    }
  }

  void _saveHistory() async {
    final tmdbIdInt = int.tryParse(widget.tmdbId) ?? 0;
    if (tmdbIdInt <= 0) return;
    await LocalDb.instance.saveHistory(WatchHistory(
      tmdbId: tmdbIdInt, title: widget.title, posterUrl: '',
      mediaType: widget.mediaType,
      seasonNumber: widget.seasonNumber.isEmpty ? null : widget.seasonNumber,
      episodeNumber: widget.episodeNumber.isEmpty ? null : widget.episodeNumber,
      episodeTitle: widget.episodeTitle.isEmpty ? null : widget.episodeTitle,
      progressSeconds: 0, durationSeconds: 0, lastWatchedAt: DateTime.now(),
    ));
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (_duration.inSeconds > 0) {
        await LocalDb.instance.updateProgress(tmdbIdInt,
          seasonNumber: widget.seasonNumber.isEmpty ? null : widget.seasonNumber,
          episodeNumber: widget.episodeNumber.isEmpty ? null : widget.episodeNumber,
          progressSeconds: _position.inSeconds, durationSeconds: _duration.inSeconds,
        );
      }
    });
  }

  // ── Next Episode ─────────────────────────────────────────────────────────────

  /// Called on every position tick. Shows the Next Episode card in last 90s.
  /// Starts a 5s auto-play countdown when < 20s remain.
  void _checkSkipOverlays(Duration pos) {
    if (_duration == Duration.zero || widget.mediaType != 'tv') return;
    final secs = pos.inSeconds;
    final total = _duration.inSeconds;
    final wantNext = total > 90 && secs >= total - 90;

    if (wantNext && !_showNextEp) {
      // Start showing the card + preload next ep in background
      setState(() { _showNextEp = true; _nextEpCountdown = 5; });
      _preloadNextEpisode(); // start fetching next ep stream silently
    }

    // Start countdown in last 20s
    if (_showNextEp && secs >= total - 20 && _nextEpTimer == null) {
      _nextEpTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) { t.cancel(); return; }
        setState(() {
          if (_nextEpCountdown > 0) {
            _nextEpCountdown--;
          } else {
            t.cancel();
            _nextEpTimer = null;
            _goNextEpisode();
          }
        });
      });
    }

    if (!wantNext && _showNextEp) {
      _nextEpTimer?.cancel();
      _nextEpTimer = null;
      setState(() { _showNextEp = false; _nextEpCountdown = 5; });
    }
  }

  void _cancelNextEp() {
    _nextEpTimer?.cancel();
    _nextEpTimer = null;
    setState(() { _showNextEp = false; _nextEpCountdown = 5; });
  }

  void _goNextEpisode() {
    final nextEp = (int.tryParse(widget.episodeNumber) ?? 0) + 1;
    if (nextEp <= 0) return;
    // If we have a preloaded source, play it directly (no loading wait)
    final preloaded = _preloadedNextSrc;
    // Use the widget's season number (next episode is always in the same season)
    final season = widget.seasonNumber;
    GoRouter.of(context).pushReplacement('/player', extra: <String, dynamic>{
      'tmdbId': widget.tmdbId,
      'mediaType': widget.mediaType,
      'title': widget.title,
      'year': widget.year,
      'seasonNumber': season,
      'episodeNumber': '$nextEp',
      'episodeTitle': 'Episode $nextEp',
      'isAnime': widget.isAnime,
      'backdrop': _backdropUrl,
      'logo': _logoUrl,
      if (preloaded != null) 'preloadedUrl': preloaded.url,
      if (preloaded != null) 'preloadedProvider': preloaded.provider,
    });
  }

  // ── Controls ─────────────────────────────────────────────────────────────────

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _panel == _PanelTab.none) setState(() => _showControls = false);
    });
  }

  void _onTap() {
    setState(() => _showControls = !_showControls);
    if (_showControls && _panel == _PanelTab.none) _scheduleHide();
  }

  void _seek(int secs) {
    _player.seek(_position + Duration(seconds: secs));
    // Flash animation
    _seekFlashTimer?.cancel();
    setState(() => _seekFlash = secs > 0 ? 1 : -1);
    _seekFlashTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekFlash = 0);
    });
  }

  /// Set video aspect ratio via MPV panscan/keepaspect.
  void _setAspectRatio(String mode) async {
    setState(() => _aspectRatio = mode);
    try {
      final native = _player.platform as dynamic;
      switch (mode) {
        case 'fit':     // Letterbox/pillarbox — fit within screen
          await native.setProperty('keepaspect', 'yes');
          await native.setProperty('panscan', '0.0');
          await native.setProperty('video-zoom', '0');
          break;
        case 'crop':    // Fill screen, crop edges
          await native.setProperty('keepaspect', 'yes');
          await native.setProperty('panscan', '1.0');
          await native.setProperty('video-zoom', '0');
          break;
        case 'stretch': // Stretch to fill (ignore aspect ratio)
          await native.setProperty('keepaspect', 'no');
          await native.setProperty('panscan', '0.0');
          await native.setProperty('video-zoom', '0');
          break;
      }
    } catch (_) {}
  }

  /// Toggle fullscreen.
  Future<void> _toggleFullscreen() async {
    final next = !_isFullscreen;
    setState(() => _isFullscreen = next);
    try {
      await windowManager.setFullScreen(next);
    } catch (_) {
      // Fallback: hide/show system UI
      if (next) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    }
  }

  /// Preload next episode stream in background (called when NextEpCard appears).
  Future<void> _preloadNextEpisode() async {
    if (_preloadingNext || _preloadedNextSrc != null) return;
    final nextEpNum = (int.tryParse(widget.episodeNumber) ?? 0) + 1;
    if (nextEpNum <= 0) return;
    setState(() => _preloadingNext = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final prefLang = prefs.getString('preferred_anidb_lang') ?? 'Sub';

      final src = await StreamResolver.instance.resolveFirstSource(
        title: widget.title, mediaType: widget.mediaType,
        year: widget.year, seasonNumber: widget.seasonNumber,
        episodeNumber: '$nextEpNum',
        preferredQuality: prefLang,
        isAnime: widget.isAnime,
      );
      if (mounted && src != null) setState(() => _preloadedNextSrc = src);
    } catch (_) {} finally {
      if (mounted) setState(() => _preloadingNext = false);
    }
  }

  /// Load pause-on-focus-loss setting from prefs.
  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) setState(() {
        _pauseOnFocusLoss = prefs.getBool('pauseOnFocusLoss') ?? true;
      });
    } catch (_) {}
  }

  Future<void> _savePauseOnFocusLoss(bool value) async {
    setState(() => _pauseOnFocusLoss = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('pauseOnFocusLoss', value);
    } catch (_) {}
  }


  void _togglePlay() { _isPlaying ? _player.pause() : _player.play(); _scheduleHide(); }
  void _toggleMute() { _player.setVolume(_volume > 0 ? 0 : 100); }

  void _cycleSpeed() {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    final idx = speeds.indexWhere((s) => (s - _speed).abs() < 0.01);
    final next = speeds[(idx + 1) % speeds.length];
    setState(() => _speed = next);
    _player.setRate(next);
    _scheduleHide();
  }

  void _showSpeedPicker(BuildContext context) {
    const speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => Dialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Playback Speed', style: GoogleFonts.inter(color: Colors.white,
                fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: speeds.map((s) {
              final active = (s - _speed).abs() < 0.01;
              return GestureDetector(
                onTap: () {
                  setState(() => _speed = s);
                  _player.setRate(s);
                  Navigator.pop(context);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: active ? AppColors.accent : Colors.white12,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('${s}x', style: GoogleFonts.inter(
                      color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              );
            }).toList()),
          ]),
        ),
      ),
    );
  }

  void _togglePanel(_PanelTab tab) {
    setState(() => _panel = _panel == tab ? _PanelTab.none : tab);
    if (_panel == _PanelTab.none) _scheduleHide();
    else _hideTimer?.cancel();
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: KeyboardListener(
        focusNode: FocusNode()..requestFocus(),
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(children: [
          // Video
          Positioned.fill(
            child: MouseRegion(
              onHover: (_) {
                if (_isBuffering || _loadState != _LoadState.playing) return;
                if (!_showControls) setState(() => _showControls = true);
                if (_panel == _PanelTab.none) _scheduleHide();
              },
              child: GestureDetector(onTap: _onTap, behavior: HitTestBehavior.opaque, child: _buildVideoArea()),
            ),
          ),

          // Controls
          if (_loadState == _LoadState.playing)
            AnimatedOpacity(
              opacity: _showControls ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 250),
              child: IgnorePointer(ignoring: !_showControls, child: _buildControls()),
            ),

          // Centered logo overlay when buffering mid-play
          if (_loadState == _LoadState.playing && _isBuffering)
            _BufferingOverlay(
              title: widget.title,
              logoUrl: _logoUrl,
            ),



          // Seek flash animation (+10 / -10 ripple)
          if (_seekFlash != 0)
            Positioned.fill(
              child: IgnorePointer(
                child: Align(
                  alignment: _seekFlash > 0 ? Alignment.centerRight : Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 48),
                    child: AnimatedOpacity(
                      opacity: _seekFlash != 0 ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 150),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(40),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (_seekFlash < 0) Icon(Icons.replay_10_rounded, color: Colors.white, size: 28),
                          if (_seekFlash < 0) const SizedBox(width: 6),
                          Text(_seekFlash > 0 ? '+10s' : '-10s',
                            style: GoogleFonts.inter(color: Colors.white,
                                fontSize: 15, fontWeight: FontWeight.w700)),
                          if (_seekFlash > 0) const SizedBox(width: 6),
                          if (_seekFlash > 0) Icon(Icons.forward_10_rounded, color: Colors.white, size: 28),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Source-resolving overlay — use the same animated buffering logo, no extra spinner
          if (_isResolvingSource && _loadState == _LoadState.playing)
            Positioned.fill(
              child: _BufferingOverlay(
                title: widget.title,
                logoUrl: _logoUrl,
              ),
            ),

          // ── Netflix-style Next Episode card ────────────────────────────────
          if (_loadState == _LoadState.playing && _showNextEp && widget.mediaType == 'tv')
            Positioned(
              bottom: 100, right: 24,
              child: _NextEpCard(
                episodeNumber: (int.tryParse(widget.episodeNumber) ?? 0) + 1,
                countdown: _nextEpCountdown,
                showCountdown: _nextEpTimer != null,
                onPlay: _goNextEpisode,
                onCancel: _cancelNextEp,
              ),
            ),

          // Panel backdrop
          if (_panel != _PanelTab.none)
            Positioned.fill(
              child: GestureDetector(
                onTap: () => setState(() => _panel = _PanelTab.none),
                child: Container(color: Colors.black54),
              ),
            ),

          // Sliding panel
          AnimatedPositioned(
            duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic,
            top: 0, bottom: 0, right: _panel != _PanelTab.none ? 0 : -340,
            child: _buildPanel(),
          ),
        ]),
      ),
    );
  }

  Widget _buildVideoArea() {
    return switch (_loadState) {
      _LoadState.fetching => _FetchingOverlay(
          title: widget.title,
          backdropUrl: _backdropUrl,
          logoUrl: _logoUrl,
          subtitle: widget.episodeTitle.isNotEmpty ? widget.episodeTitle
              : widget.seasonNumber.isNotEmpty ? 'S${widget.seasonNumber} · E${widget.episodeNumber}' : '',
          step: _loadStep,
          onBack: () => GoRouter.of(context).pop(),
        ),
      _LoadState.error => _ErrorOverlay(error: _error ?? 'Unknown error',
          onRetry: _resolveAndPlay, onBack: () => GoRouter.of(context).pop()),
      _LoadState.playing => Video(
          controller: _videoCtrl,
          controls: NoVideoControls,
          fill: Colors.black,
          fit: switch (_aspectRatio) {
            'fit' => BoxFit.contain,
            'crop' => BoxFit.cover,
            'stretch' => BoxFit.fill,
            _ => BoxFit.contain,
          },
        ),
    };
  }

  Widget _buildControls() {
    return Stack(children: [
      Positioned(top: 0, left: 0, right: 0, height: 90,
        child: Container(decoration: const BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent])))),
      Positioned(bottom: 0, left: 0, right: 0, height: 160,
        child: Container(decoration: BoxDecoration(gradient: LinearGradient(
          begin: Alignment.bottomCenter, end: Alignment.topCenter,
          colors: [Colors.black.withValues(alpha: 0.9), Colors.transparent])))),

      // Top bar
      Positioned(top: 0, left: 0, right: 0,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            _CtrlBtn(icon: Icons.arrow_back_rounded, onTap: () => GoRouter.of(context).pop()),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
              if (widget.episodeTitle.isNotEmpty || widget.seasonNumber.isNotEmpty)
                Text(widget.episodeTitle.isNotEmpty ? widget.episodeTitle
                    : 'S${widget.seasonNumber} E${widget.episodeNumber}',
                    style: GoogleFonts.inter(color: Colors.white70, fontSize: 12)),
            ])),
            // Current source badge
            if (_currentSource != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(4)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _QualityDot(quality: _currentSource!.quality),
                  const SizedBox(width: 5),
                  Text(_currentSource!.quality,
                      style: GoogleFonts.inter(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                ]),
              ),
            const SizedBox(width: 6),
            // Episodes button (TV only)
            if (widget.mediaType == 'tv') ...[
              _PanelBtn(icon: Icons.video_library_rounded,
                label: 'Episodes',
                active: _panel == _PanelTab.episodes,
                onTap: () {
                  _togglePanel(_PanelTab.episodes);
                  // Always reload if empty (covers failed loads)
                  if (_tmdbEpisodes.isEmpty && !_tmdbEpisodesLoading) _loadTmdbEpisodes();
                }),
              const SizedBox(width: 6),
            ],
            // Sources button
            _PanelBtn(icon: Icons.layers_rounded,
              label: _episodeRefs.isEmpty ? 'Sources' : 'Sources (${_episodeRefs.length})',
              active: _panel == _PanelTab.sources,
              onTap: () => _togglePanel(_PanelTab.sources)),
            const SizedBox(width: 6),
            // Settings button (quality, aspect ratio, subtitles, etc.)
            _PanelBtn(icon: Icons.settings_rounded, label: 'Settings',
              active: _panel == _PanelTab.quality || _panel == _PanelTab.subtitles,
              onTap: () => _togglePanel(_PanelTab.quality)),
          ]),
        ),
      ),

      // Bottom controls
      Positioned(bottom: 0, left: 0, right: 0,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Time markers above seekbar
            Row(children: [
              Text(_fmt(_position),
                  style: GoogleFonts.inter(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(_fmt(_duration),
                  style: GoogleFonts.inter(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 6),
            // Seek bar
            _VideoSeekBar(
              position: _duration.inMilliseconds > 0
                  ? (_isDragging ? _dragValue : (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0))
                  : 0.0,
              buffered: _duration.inMilliseconds > 0
                  ? (_buffered.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
                  : 0.0,
              isDragging: _isDragging,
              onSeekStart: (v) => setState(() { _isDragging = true; _dragValue = v; }),
              onSeekUpdate: (v) => setState(() => _dragValue = v),
              onSeekEnd: (v) {
                final ms = (v * _duration.inMilliseconds).round();
                setState(() { _isDragging = false; _position = Duration(milliseconds: ms); });
                _player.seek(Duration(milliseconds: ms));
                _scheduleHide();
              },
            ),
            const SizedBox(height: 10),
            Row(children: [
              // Bottom-left controls: Play/Pause, Next Episode (if TV), Volume + Slider
              _CtrlBtn(
                icon: _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                onTap: _togglePlay,
              ),
              const SizedBox(width: 8),
              if (widget.mediaType == 'tv') ...[
                _CtrlBtn(
                  icon: Icons.skip_next_rounded,
                  onTap: _goNextEpisode,
                ),
                const SizedBox(width: 8),
              ],
              _CtrlBtn(
                icon: _volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                onTap: _toggleMute,
              ),
              const SizedBox(width: 4),
              // Volume Slider
              SizedBox(
                width: 80,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: _volume,
                    onChanged: (val) {
                      _player.setVolume(val * 100.0);
                    },
                  ),
                ),
              ),
              
              const Spacer(),
              
              // Bottom-right controls: Speed, Settings/CC panel, Aspect Ratio cycling, Fullscreen
              GestureDetector(
                onTap: () => _showSpeedPicker(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(4)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.speed_rounded, color: Colors.white, size: 14),
                    const SizedBox(width: 4),
                    Text('${_speed}x', style: GoogleFonts.inter(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),

              const SizedBox(width: 8),
              // Aspect ratio cycles button
              GestureDetector(
                onTap: () {
                  final nextMode = switch (_aspectRatio) {
                    'fit' => 'crop',
                    'crop' => 'stretch',
                    'stretch' => 'fit',
                    _ => 'fit',
                  };
                  _setAspectRatio(nextMode);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(4)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(
                      switch (_aspectRatio) {
                        'fit' => Icons.fit_screen_rounded,
                        'crop' => Icons.crop_rounded,
                        'stretch' => Icons.aspect_ratio_rounded,
                        _ => Icons.fit_screen_rounded,
                      },
                      color: Colors.white,
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      switch (_aspectRatio) {
                        'fit' => 'Fit',
                        'crop' => 'Crop',
                        'stretch' => 'Stretch',
                        _ => 'Fit',
                      },
                      style: GoogleFonts.inter(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
                    ),
                  ]),
                ),
              ),
              const SizedBox(width: 8),
              // Fullscreen button
              _CtrlBtn(
                icon: _isFullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                onTap: _toggleFullscreen,
              ),
            ]),
          ]),
        ),
      ),

      // ── Center: spinner while buffering, Netflix controls when ready ──────────────
      Center(
        child: _isBuffering
          ? const SizedBox.shrink()
          : Row(mainAxisSize: MainAxisSize.min, children: [
              Visibility(
                visible: _seekFlash == 0,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: _CenterSkipBtn(secs: -10, onTap: () => _seek(-10)),
              ),
              const SizedBox(width: 36),
              // Play / Pause
              GestureDetector(
                onTap: _togglePlay,
                child: Container(
                  width: 72, height: 72,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 42,
                  ),
                ),
              ),
              const SizedBox(width: 36),
              Visibility(
                visible: _seekFlash == 0,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: _CenterSkipBtn(secs: 10, onTap: () => _seek(10)),
              ),
            ]),
      ),

    ]);
  }

  Widget _buildPanel() {
    return Container(
      width: 320,
      decoration: const BoxDecoration(
        color: Color(0xFF111111),
        border: Border(left: BorderSide(color: Color(0xFF2A2A2A), width: 1)),
      ),
      child: switch (_panel) {
        _PanelTab.sources => _SourcesPanel(
            refs: _episodeRefs, activeIdx: _activeRefIdx,
            currentProvider: _currentSource?.provider,
            onSelect: _selectEpisodeRef,
            onClose: () => setState(() => _panel = _PanelTab.none),
          ),
        _PanelTab.episodes => _EpisodesPanel(
            episodes: _tmdbEpisodes,
            isLoading: _tmdbEpisodesLoading,
            currentEpisodeNumber: widget.episodeNumber,
            currentSeasonNumber: widget.seasonNumber,
            selectedSeasonNumber: _selectedSeasonNumber,
            allSeasons: _allSeasons,
            onSeasonChange: (s) {
              setState(() { _selectedSeasonNumber = s; });
              _loadTmdbEpisodes(seasonOverride: s);
            },
            onSelect: (ep) {
              setState(() => _panel = _PanelTab.none);
              _playTmdbEpisode(ep);
            },
            onClose: () => setState(() => _panel = _PanelTab.none),
          ),
        _PanelTab.quality || _PanelTab.audio || _PanelTab.subtitles => _SettingsPanel(
            tracks: _tracks,
            activeVideo: _activeVideo, activeAudio: _activeAudio, activeSubtitle: _activeSubtitle,
            currentSource: _currentSource, activeTab: _panel,
            hlsVariants: _hlsVariants,
            activeVariantBandwidth: _activeVariantBandwidth,
            aspectRatio: _aspectRatio,
            pauseOnFocusLoss: _pauseOnFocusLoss,
            onVideoTrack: (t) { _player.setVideoTrack(t); setState(() => _activeVideo = t); },
            onAudioTrack: (t) { _player.setAudioTrack(t); setState(() => _activeAudio = t); },
            onSubtitleTrack: (t) { _player.setSubtitleTrack(t); setState(() => _activeSubtitle = t); },
            onTabChange: (t) => setState(() => _panel = t),
            onSetHlsBitrate: _setHlsBitrate,
            onSetAspectRatio: _setAspectRatio,
            onSetPauseOnFocusLoss: _savePauseOnFocusLoss,
            onClose: () => setState(() => _panel = _PanelTab.none),
          ),
        _PanelTab.none => const SizedBox.shrink(),
      },
    );
  }

  /// Load all seasons for the Episodes panel dropdown — uses SIMKL
  Future<void> _loadAllSeasons() async {
    if (widget.mediaType != 'tv') return;
    final sid = await _resolveSimklId();
    if (sid <= 0) return;
    try {
      final detail = await SimklApi.instance.getDetails(sid, widget.mediaType);
      if (mounted && detail.seasons.isNotEmpty) {
        setState(() => _allSeasons = detail.seasons);
      }
    } catch (_) {}
  }

  /// Asynchronously fetch backdrop image and logo URL if missing — uses SIMKL
  Future<void> _fetchMediaDetailsIfNeeded() async {
    final needBack = _backdropUrl == null || _backdropUrl!.isEmpty;
    final needLogo = _logoUrl == null || _logoUrl!.isEmpty;
    if (!needBack && !needLogo) return;
    final sid = await _resolveSimklId();
    if (sid <= 0) return;
    try {
      final detail = await SimklApi.instance.getDetails(sid, widget.mediaType);
      if (mounted) {
        setState(() {
          if (needBack && detail.backdropUrl.isNotEmpty) _backdropUrl = detail.backdropUrl;
          if (needLogo && detail.logoUrl.isNotEmpty) _logoUrl = detail.logoUrl;
        });
      }
    } catch (_) {}
  }

  /// Resolve the SIMKL ID: prefer widget.simklId, else look up from TMDB ID
  Future<int> _resolveSimklId() async {
    if (widget.simklId > 0) return widget.simklId;
    final tmdbId = int.tryParse(widget.tmdbId) ?? 0;
    if (tmdbId <= 0) return 0;
    return SimklApi.instance.simklIdFromTmdb(tmdbId, widget.mediaType);
  }

  /// Load SIMKL season episodes for the Episodes panel
  Future<void> _loadTmdbEpisodes({int? seasonOverride}) async {
    if (_tmdbEpisodesLoading) return;
    final season = seasonOverride ?? _selectedSeasonNumber;
    setState(() { _tmdbEpisodesLoading = true; _tmdbEpisodes = []; });
    try {
      final sid = await _resolveSimklId();
      if (sid <= 0) { if (mounted) setState(() => _tmdbEpisodesLoading = false); return; }
      final eps = await SimklApi.instance.getSeasonEpisodes(sid, season);
      if (mounted) setState(() { _tmdbEpisodes = eps; _tmdbEpisodesLoading = false; });
    } catch (e) {
      debugPrint('[Player] _loadTmdbEpisodes failed: $e');
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      try {
        final sid = await _resolveSimklId();
        if (sid > 0) {
          final eps = await SimklApi.instance.getSeasonEpisodes(sid, season);
          if (mounted) setState(() { _tmdbEpisodes = eps; _tmdbEpisodesLoading = false; });
        } else {
          if (mounted) setState(() => _tmdbEpisodesLoading = false);
        }
      } catch (_) {
        if (mounted) setState(() => _tmdbEpisodesLoading = false);
      }
    }
  }

  void _playTmdbEpisode(TmdbEpisode ep) {
    GoRouter.of(context).pushReplacement('/player', extra: <String, dynamic>{
      'tmdbId': widget.tmdbId,
      'simklId': widget.simklId,
      'mediaType': widget.mediaType,
      'title': widget.title,
      'year': widget.year,
      'seasonNumber': '${ep.seasonNumber}',
      'episodeNumber': '${ep.episodeNumber}',
      'episodeTitle': ep.name,
      'isAnime': widget.isAnime,
      'backdrop': _backdropUrl,
      'logo': _logoUrl,
    });
  }


  void _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.space: case LogicalKeyboardKey.mediaPlayPause: _togglePlay();
      case LogicalKeyboardKey.arrowLeft: _seek(-10);
      case LogicalKeyboardKey.arrowRight: _seek(10);
      case LogicalKeyboardKey.arrowUp: _player.setVolume((_volume * 100 + 10).clamp(0, 100));
      case LogicalKeyboardKey.arrowDown: _player.setVolume((_volume * 100 - 10).clamp(0, 100));
      case LogicalKeyboardKey.escape:
        if (_panel != _PanelTab.none) {
          setState(() => _panel = _PanelTab.none);
        } else if (_isFullscreen) {
          _toggleFullscreen();
        } else {
          GoRouter.of(context).pop();
        }
      case LogicalKeyboardKey.keyS: _togglePanel(_PanelTab.sources);
      default: break;
    }
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

// ─── Skip Button (Netflix-style) ───────────────────────────────────────────────

// ─── Netflix-style Next Episode Card ──────────────────────────────────────────

class _NextEpCard extends StatelessWidget {
  final int episodeNumber;
  final int countdown;
  final bool showCountdown;
  final VoidCallback onPlay;
  final VoidCallback onCancel;

  const _NextEpCard({
    required this.episodeNumber,
    required this.countdown,
    required this.showCountdown,
    required this.onPlay,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          width: 300,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12), width: 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            // Header row
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFE50914),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('UP NEXT', style: GoogleFonts.inter(
                    color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.2)),
              ),
              const Spacer(),
              // Dismiss X button
              GestureDetector(
                onTap: onCancel,
                child: Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close_rounded, color: Colors.white70, size: 16),
                ),
              ),
            ]),

            const SizedBox(height: 12),

            // Episode info
            Text('Episode $episodeNumber',
                style: GoogleFonts.inter(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(showCountdown
                    ? 'Playing automatically in ${countdown}s…'
                    : 'Coming up next',
                style: GoogleFonts.inter(color: Colors.white60, fontSize: 12)),

            const SizedBox(height: 14),

            // Progress bar (countdown visual)
            if (showCountdown) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: countdown / 5.0,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFE50914)),
                  minHeight: 3,
                ),
              ),
              const SizedBox(height: 14),
            ],

            // Action buttons
            Row(children: [
              // Play Now
              Expanded(
                child: GestureDetector(
                  onTap: onPlay,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE50914),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 20),
                      const SizedBox(width: 6),
                      Text('Play Now', style: GoogleFonts.inter(
                          color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

// ─── Episodes Panel (TMDB) ─────────────────────────────────────────────────────

class _EpisodesPanel extends StatelessWidget {
  final List<TmdbEpisode> episodes;
  final bool isLoading;
  final String currentEpisodeNumber;
  final String currentSeasonNumber;
  final int selectedSeasonNumber;
  final List<TmdbSeason> allSeasons;
  final void Function(int) onSeasonChange;
  final void Function(TmdbEpisode) onSelect;
  final VoidCallback onClose;

  const _EpisodesPanel({
    required this.episodes,
    required this.isLoading,
    required this.currentEpisodeNumber,
    required this.currentSeasonNumber,
    required this.selectedSeasonNumber,
    required this.allSeasons,
    required this.onSeasonChange,
    required this.onSelect,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    // An episode is "currently playing" only if it's in the current season too
    final inCurrentSeason = '$selectedSeasonNumber' == currentSeasonNumber;

    return Column(children: [
      _PanelHeader(
        icon: Icons.video_library_rounded,
        title: 'Episodes',
        subtitle: isLoading ? 'Loading…' : '${episodes.length} episodes',
        onClose: onClose,
      ),
      // Season dropdown (only show if there are multiple seasons)
      if (allSeasons.length > 1)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFF2A2A2A), width: 1)),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: selectedSeasonNumber,
              dropdownColor: const Color(0xFF1A1A1A),
              isExpanded: true,
              icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white54, size: 18),
              style: GoogleFonts.inter(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
              items: allSeasons.map((s) {
                return DropdownMenuItem<int>(
                  value: s.seasonNumber,
                  child: Text(s.name.isNotEmpty ? s.name : 'Season ${s.seasonNumber}'),
                );
              }).toList(),
              onChanged: (val) {
                if (val != null && val != selectedSeasonNumber) onSeasonChange(val);
              },
            ),
          ),
        ),
      Expanded(
        child: isLoading
            ? const Center(child: CircularProgressIndicator(color: AppColors.accent, strokeWidth: 2))
            : episodes.isEmpty
                ? Center(child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text('No episodes available', style: GoogleFonts.inter(color: Colors.white38, fontSize: 13)),
                  ))
                : ListView.builder(
                    itemCount: episodes.length,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemBuilder: (ctx, i) {
                      final ep = episodes[i];
                      // Highlight only the episode that is actually playing (right season + right episode)
                      final isActive = inCurrentSeason && '${ep.episodeNumber}' == currentEpisodeNumber;
                      return _TmdbEpisodeTile(
                        episode: ep,
                        isActive: isActive,
                        onTap: () => onSelect(ep),
                      );
                    },
                  ),
      ),
    ]);
  }
}

class _TmdbEpisodeTile extends StatefulWidget {
  final TmdbEpisode episode;
  final bool isActive;
  final VoidCallback onTap;
  const _TmdbEpisodeTile({required this.episode, required this.isActive, required this.onTap});
  @override State<_TmdbEpisodeTile> createState() => _TmdbEpisodeTileState();
}

class _TmdbEpisodeTileState extends State<_TmdbEpisodeTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ep = widget.episode;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.isActive
                ? AppColors.accent.withValues(alpha: 0.12)
                : _hover ? Colors.white.withValues(alpha: 0.05) : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: widget.isActive ? AppColors.accent : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Episode still image
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: ep.stillUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: ep.stillUrl,
                      width: 96, height: 54, fit: BoxFit.cover,
                      placeholder: (_, __) => Container(
                        width: 96, height: 54,
                        color: Colors.white.withValues(alpha: 0.08),
                        child: const Icon(Icons.play_circle_outline_rounded, color: Colors.white24, size: 24),
                      ),
                      errorWidget: (_, __, ___) => Container(
                        width: 96, height: 54, color: Colors.white.withValues(alpha: 0.08),
                        child: const Icon(Icons.broken_image_rounded, color: Colors.white24, size: 20),
                      ),
                    )
                  : Container(
                      width: 96, height: 54,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: widget.isActive
                          ? const Icon(Icons.play_arrow_rounded, color: AppColors.accent, size: 28)
                          : Center(child: Text('${ep.episodeNumber}',
                              style: GoogleFonts.inter(color: Colors.white38, fontSize: 18, fontWeight: FontWeight.w700))),
                    ),
            ),
            const SizedBox(width: 10),
            // Episode info
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(
                    'E${ep.episodeNumber}',
                    style: GoogleFonts.inter(
                      color: widget.isActive ? AppColors.accent : Colors.white38,
                      fontSize: 11, fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (widget.isActive) ...[ 
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(3)),
                      child: Text('NOW PLAYING', style: GoogleFonts.inter(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                    ),
                  ],
                ]),
                const SizedBox(height: 2),
                Text(
                  ep.name.isNotEmpty ? ep.name : 'Episode ${ep.episodeNumber}',
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    color: widget.isActive ? Colors.white : Colors.white.withValues(alpha: 0.85),
                    fontSize: 12, fontWeight: widget.isActive ? FontWeight.w700 : FontWeight.w500,
                    height: 1.3,
                  ),
                ),
                if (ep.overview.isNotEmpty) ...[ 
                  const SizedBox(height: 3),
                  Text(
                    ep.overview,
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(color: Colors.white30, fontSize: 10, height: 1.4),
                  ),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}



// ─── Sources Panel ─────────────────────────────────────────────────────────────


class _SourcesPanel extends StatelessWidget {
  final List<EpisodeRef> refs;
  final int activeIdx;
  final String? currentProvider;
  final void Function(int) onSelect;
  final VoidCallback onClose;

  const _SourcesPanel({required this.refs, required this.activeIdx, required this.currentProvider, required this.onSelect, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _PanelHeader(icon: Icons.layers_rounded, title: 'Sources',
          subtitle: refs.isEmpty ? 'Loading…' : '${refs.length} found', onClose: onClose),
      if (refs.isEmpty)
        const Expanded(child: Center(child: CircularProgressIndicator(color: AppColors.accent, strokeWidth: 2)))
      else
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: refs.length,
            itemBuilder: (_, i) => _EpisodeRefTile(
              ref: refs[i], isActive: i == activeIdx,
              onTap: () => onSelect(i),
            ),
          ),
        ),
    ]);
  }
}

class _EpisodeRefTile extends StatefulWidget {
  final EpisodeRef ref;
  final bool isActive;
  final VoidCallback onTap;
  const _EpisodeRefTile({required this.ref, required this.isActive, required this.onTap});
  @override State<_EpisodeRefTile> createState() => _EpisodeRefTileState();
}

class _EpisodeRefTileState extends State<_EpisodeRefTile> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true), onExit: (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          color: _h ? Colors.white.withValues(alpha: 0.06)
              : widget.isActive ? Colors.white.withValues(alpha: 0.04) : Colors.transparent,
          child: Row(children: [
            SizedBox(width: 20, child: widget.isActive
                ? const Icon(Icons.play_arrow_rounded, color: AppColors.accent, size: 16) : null),
            const SizedBox(width: 6),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Show quality + size on first line
              Text(
                '${widget.ref.qualityBadge}${widget.ref.size.isNotEmpty ? "  ·  ${widget.ref.size}" : ""}',
                style: GoogleFonts.inter(
                  color: widget.isActive ? Colors.white : Colors.white.withValues(alpha: 0.85),
                  fontSize: 13, fontWeight: widget.isActive ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              // Show title (first line only, trimmed)
              if (widget.ref.title.isNotEmpty)
                Text(
                  widget.ref.title.split('\n').first.trim(),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(color: Colors.white38, fontSize: 11),
                ),
              Text(
                switch (widget.ref.provider) {
                  '4khdhub' => '4KHD Hub',
                  'hdhub4u' => 'HDHub4U',
                  'anidao'  => 'AniDAO',
                  'anidb'   => 'AniDB',
                  _         => widget.ref.provider,
                },
                style: GoogleFonts.inter(color: Colors.white24, fontSize: 10),
              ),
            ])),
            const SizedBox(width: 6),
            _QualityBadge(quality: widget.ref.qualityBadge),
          ]),
        ),
      ),
    );
  }
}

// ─── Settings Panel ────────────────────────────────────────────────────────────

class _SettingsPanel extends StatelessWidget {
  final Tracks tracks;
  final VideoTrack activeVideo;
  final AudioTrack activeAudio;
  final SubtitleTrack activeSubtitle;
  final StreamSource? currentSource;
  final _PanelTab activeTab;
  final List<_HlsVariant> hlsVariants;
  final int activeVariantBandwidth;
  final String aspectRatio;
  final bool pauseOnFocusLoss;
  final void Function(VideoTrack) onVideoTrack;
  final void Function(AudioTrack) onAudioTrack;
  final void Function(SubtitleTrack) onSubtitleTrack;
  final void Function(_PanelTab) onTabChange;
  final void Function(int) onSetHlsBitrate;
  final void Function(String) onSetAspectRatio;
  final void Function(bool) onSetPauseOnFocusLoss;
  final VoidCallback onClose;

  const _SettingsPanel({
    required this.tracks, required this.activeVideo, required this.activeAudio,
    required this.activeSubtitle, required this.currentSource, required this.activeTab,
    required this.hlsVariants, required this.activeVariantBandwidth,
    required this.aspectRatio, required this.pauseOnFocusLoss,
    required this.onVideoTrack, required this.onAudioTrack,
    required this.onSubtitleTrack, required this.onTabChange,
    required this.onSetHlsBitrate, required this.onSetAspectRatio,
    required this.onSetPauseOnFocusLoss, required this.onClose,
  });

  // Only show Audio tab when there are 2+ audio tracks (multi-audio content)
  bool get _hasMultiAudio {
    final audioTracks = tracks.audio
        .where((t) => t != AudioTrack.no() && t != AudioTrack.auto())
        .toList();
    return audioTracks.length > 1;
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _PanelHeader(icon: Icons.settings_rounded, title: 'Settings', onClose: onClose),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          _TabChip(label: 'Quality', active: activeTab == _PanelTab.quality,
              onTap: () => onTabChange(_PanelTab.quality)),
          const SizedBox(width: 8),
          if (_hasMultiAudio) ...[
            _TabChip(label: 'Audio', active: activeTab == _PanelTab.audio,
                onTap: () => onTabChange(_PanelTab.audio)),
            const SizedBox(width: 8),
          ],
          _TabChip(label: 'Subtitles', active: activeTab == _PanelTab.subtitles,
              onTap: () => onTabChange(_PanelTab.subtitles)),
          const SizedBox(width: 8),
          _TabChip(label: 'Display', active: activeTab == _PanelTab.none,
              onTap: () => onTabChange(_PanelTab.none)),
        ]),
      ),
      Expanded(child: switch(activeTab) {
        _PanelTab.quality   => _buildQuality(),
        _PanelTab.audio     => _buildAudio(),
        _PanelTab.subtitles => _buildSubtitles(),
        _                   => _buildDisplay(),
      }),
    ]);
  }

  Widget _buildDisplay() {
    return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
      _SectionLabel('ASPECT RATIO'),
      ...[
        ('fit',     'Fit to Screen',   'Letterbox / pillarbox', Icons.fit_screen_rounded),
        ('crop',    'Crop / Fill',      'Zoom to fill, may crop edges', Icons.crop_rounded),
        ('stretch', 'Stretch',          'Stretch to fill screen', Icons.aspect_ratio_rounded),
      ].map(((String, String, String, IconData) item) => _TrackTile(
        label: item.$2, sublabel: item.$3,
        isActive: aspectRatio == item.$1,
        onTap: () => onSetAspectRatio(item.$1),
      )),
      const SizedBox(height: 8),
      _SectionLabel('PLAYBACK BEHAVIOUR'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Pause when app loses focus',
                style: GoogleFonts.inter(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
            Text('Pause video when you switch to another window',
                style: GoogleFonts.inter(color: Colors.white54, fontSize: 11)),
          ])),
          Switch(
            value: pauseOnFocusLoss,
            onChanged: onSetPauseOnFocusLoss,
            activeColor: AppColors.accent,
            thumbColor: WidgetStateProperty.all(Colors.white),
          ),
        ]),
      ),
    ]);
  }

  Widget _buildAudio() {
    final audioTracks = tracks.audio
        .where((t) => t != AudioTrack.no() && t != AudioTrack.auto())
        .toList();

    if (audioTracks.isEmpty) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text('No audio tracks detected.',
            style: GoogleFonts.inter(color: Colors.white38, fontSize: 12)),
      ));
    }

    return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
      _SectionLabel('AUDIO LANGUAGE'),
      _TrackTile(
        label: 'Auto',
        sublabel: 'System default audio track',
        isActive: activeAudio == AudioTrack.auto(),
        onTap: () => onAudioTrack(AudioTrack.auto()),
      ),
      ...audioTracks.map((t) {
        final lang = t.language?.isNotEmpty == true ? t.language! : '';
        final title = t.title?.isNotEmpty == true ? t.title! : '';
        final label = [title, lang].where((s) => s.isNotEmpty).join(' — ');
        return _TrackTile(
          label: label.isNotEmpty ? label : 'Track ${t.id}',
          sublabel: lang.isNotEmpty ? lang.toUpperCase() : '',
          badge: lang.length >= 2 ? lang.substring(0, 2).toUpperCase() : null,
          isActive: activeAudio == t,
          onTap: () => onAudioTrack(t),
        );
      }),
    ]);
  }

  Widget _buildQuality() {
    // HLS streams: show parsed quality variants from master.m3u8
    if (hlsVariants.isNotEmpty) {
      return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
        _SectionLabel('VIDEO QUALITY'),
        _TrackTile(
          label: 'Auto',
          sublabel: 'Best quality for your connection',
          badge: 'HLS',
          isActive: activeVariantBandwidth < 0,
          onTap: () => onSetHlsBitrate(-1),
        ),
        ...hlsVariants.map((v) {
          final bwMbps = '${(v.bandwidth / 1000000).toStringAsFixed(1)} Mbps';
          return _TrackTile(
            label: v.label,
            sublabel: v.resolution.isNotEmpty ? '${v.resolution}  ·  $bwMbps' : bwMbps,
            isActive: activeVariantBandwidth == v.bandwidth,
            onTap: () => onSetHlsBitrate(v.bandwidth),
          );
        }),
      ]);
    }

    // MPV internal video tracks (for non-HLS / direct sources)
    final videoTracks = tracks.video.where((t) => t != VideoTrack.no()).toList();
    if (videoTracks.isNotEmpty) {
      return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
        _SectionLabel('VIDEO QUALITY'),
        _TrackTile(
          label: 'Auto (Adaptive)',
          sublabel: 'Best quality for your speed',
          isActive: activeVideo == VideoTrack.auto(),
          onTap: () => onVideoTrack(VideoTrack.auto()),
        ),
        ...videoTracks.where((t) => t != VideoTrack.auto()).map((t) {
          final label = _formatVideoTrack(t);
          final sub = _formatTrackSublabel(t);
          return _TrackTile(
            label: label, sublabel: sub,
            isActive: activeVideo == t,
            onTap: () => onVideoTrack(t),
          );
        }),
      ]);
    }

    return Center(child: Padding(
      padding: const EdgeInsets.all(20),
      child: Text('Quality options will appear once the stream loads.',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(color: Colors.white38, fontSize: 12, height: 1.5)),
    ));
  }

  Widget _buildSubtitles() {
    final subTracks = tracks.subtitle.where((t) => t != SubtitleTrack.no() && t != SubtitleTrack.auto()).toList();

    return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
      _SectionLabel('SUBTITLES'),
      _TrackTile(label: 'Off', sublabel: 'No subtitles',
          isActive: activeSubtitle == SubtitleTrack.no(),
          onTap: () => onSubtitleTrack(SubtitleTrack.no())),
      if (currentSource?.subtitleUrl.isNotEmpty == true)
        _TrackTile(
          label: 'English (External)', sublabel: 'VTT from provider', badge: 'CC',
          isActive: activeSubtitle != SubtitleTrack.no() && activeSubtitle != SubtitleTrack.auto(),
          onTap: () => onSubtitleTrack(SubtitleTrack.uri(
            currentSource!.subtitleUrl, title: 'English', language: 'en')),
        ),
      ...subTracks.map((t) {
        final lang = t.language?.isNotEmpty == true ? t.language! : '';
        final title = t.title?.isNotEmpty == true ? t.title! : '';
        final label = [title, lang].where((s) => s.isNotEmpty).join(' — ');
        return _TrackTile(
          label: label.isNotEmpty ? label : 'Track ${t.id}',
          isActive: activeSubtitle == t,
          onTap: () => onSubtitleTrack(t),
        );
      }),
      if (subTracks.isEmpty && currentSource?.subtitleUrl.isEmpty != false)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('No subtitles found for this source.',
              style: GoogleFonts.inter(color: Colors.white38, fontSize: 12)),
        ),
    ]);
  }

  /// Format a VideoTrack using resolution (height) when available
  String _formatVideoTrack(VideoTrack t) {
    // Try height-based label (most reliable)
    if (t.h != null && t.h! > 0) {
      return switch (t.h!) {
        >= 2160 => '4K UHD (${t.h}p)',
        >= 1440 => '1440p HD',
        >= 1080 => '1080p Full HD',
        >= 720  => '720p HD',
        >= 480  => '480p SD',
        >= 360  => '360p',
        _       => '${t.h}p',
      };
    }
    // Try title if it looks like a quality label
    if (t.title?.isNotEmpty == true) {
      final title = t.title!;
      if (RegExp(r'\d+[pP]').hasMatch(title)) return title;
      if (title.toLowerCase().contains('k')) return title;
      if (title.toLowerCase().contains('hd')) return title;
    }
    // Fallback — use track ID with better label
    return 'Quality ${t.id}';
  }

  String _formatTrackSublabel(VideoTrack t) {
    if (t.w != null && t.h != null && t.w! > 0) return '${t.w}×${t.h}';
    if (t.title?.isNotEmpty == true && t.h == null) return t.title!;
    return '';
  }
}

// ─── Shared Panel Widgets ──────────────────────────────────────────────────────

class _PanelHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onClose;
  const _PanelHeader({required this.icon, required this.title, this.subtitle, required this.onClose});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF2A2A2A)))),
    child: Row(children: [
      Icon(icon, color: Colors.white, size: 18),
      const SizedBox(width: 8),
      Text(title, style: GoogleFonts.inter(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
      const Spacer(),
      if (subtitle != null) Text(subtitle!, style: GoogleFonts.inter(color: Colors.white38, fontSize: 12)),
      const SizedBox(width: 8),
      GestureDetector(onTap: onClose, child: const Icon(Icons.close_rounded, color: Colors.white54, size: 20)),
    ]),
  );
}

class _TabChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _TabChip({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: active ? AppColors.accent : Colors.white12,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label, style: GoogleFonts.inter(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
    child: Text(text, style: GoogleFonts.inter(color: Colors.white38, fontSize: 10,
        fontWeight: FontWeight.w700, letterSpacing: 1.0)),
  );
}

class _TrackTile extends StatefulWidget {
  final String label;
  final String? sublabel;
  final String? badge;
  final bool isActive;
  final VoidCallback onTap;
  const _TrackTile({required this.label, required this.isActive, required this.onTap, this.sublabel, this.badge});
  @override State<_TrackTile> createState() => _TrackTileState();
}

class _TrackTileState extends State<_TrackTile> {
  bool _h = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _h = true), onExit: (_) => setState(() => _h = false),
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: widget.onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: _h ? Colors.white.withValues(alpha: 0.06) : Colors.transparent,
        child: Row(children: [
          SizedBox(width: 20, child: widget.isActive
              ? const Icon(Icons.check_rounded, color: AppColors.accent, size: 16) : null),
          const SizedBox(width: 6),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.label, style: GoogleFonts.inter(
              color: widget.isActive ? Colors.white : Colors.white70, fontSize: 13,
              fontWeight: widget.isActive ? FontWeight.w600 : FontWeight.w400)),
            if (widget.sublabel?.isNotEmpty == true)
              Text(widget.sublabel!, style: GoogleFonts.inter(color: Colors.white38, fontSize: 11)),
          ])),
          if (widget.badge != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(3)),
              child: Text(widget.badge!, style: GoogleFonts.inter(color: Colors.lightBlue, fontSize: 10, fontWeight: FontWeight.w700))),
        ]),
      ),
    ),
  );
}

class _QualityBadge extends StatelessWidget {
  final String quality;
  const _QualityBadge({required this.quality});
  @override
  Widget build(BuildContext context) {
    final q = quality.toLowerCase();
    final color = q.contains('2160') || q.contains('4k') ? const Color(0xFFFF6D00)
        : q.contains('1080') ? const Color(0xFF69F0AE)
        : q.contains('720') ? Colors.lightBlue
        : q.contains('480') ? Colors.amber
        : q == 'multi' ? const Color(0xFF40C4FF)  // Cyan for adaptive HLS
        : Colors.white54;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)),
      child: Text(quality, style: GoogleFonts.inter(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }
}

class _QualityDot extends StatelessWidget {
  final String quality;
  const _QualityDot({required this.quality});
  @override
  Widget build(BuildContext context) {
    final q = quality.toLowerCase();
    final color = q.contains('2160') || q.contains('4k') ? const Color(0xFFFF6D00)
        : q.contains('1080') ? const Color(0xFF69F0AE)
        : q.contains('720') ? Colors.lightBlue
        : Colors.white54;
    return Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }
}

class _PanelBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _PanelBtn({required this.icon, required this.label, required this.active, required this.onTap});
  @override State<_PanelBtn> createState() => _PanelBtnState();
}

class _PanelBtnState extends State<_PanelBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _h = true), onExit: (_) => setState(() => _h = false),
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: widget.active ? AppColors.accent : _h ? Colors.white12 : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(widget.icon, color: Colors.white, size: 15),
          const SizedBox(width: 5),
          Text(widget.label, style: GoogleFonts.inter(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      ),
    ),
  );
}

class _CtrlBtn extends StatefulWidget {
  final IconData icon; final VoidCallback onTap; final double size;
  const _CtrlBtn({required this.icon, required this.onTap, this.size = 22});
  @override State<_CtrlBtn> createState() => _CtrlBtnState();
}

class _CtrlBtnState extends State<_CtrlBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _h = true), onExit: (_) => setState(() => _h = false),
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100), padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(color: _h ? Colors.white12 : Colors.transparent, shape: BoxShape.circle),
        child: Icon(widget.icon, color: Colors.white, size: widget.size),
      ),
    ),
  );
}

// ─── Overlays ─────────────────────────────────────────────────────────────────

class _FetchingOverlay extends StatefulWidget {
  final String title, subtitle, step;
  final String? backdropUrl;
  final String? logoUrl;
  final VoidCallback onBack;
  const _FetchingOverlay({
    required this.title, required this.subtitle,
    required this.step, required this.onBack,
    this.backdropUrl, this.logoUrl,
  });
  @override State<_FetchingOverlay> createState() => _FetchingOverlayState();
}

class _FetchingOverlayState extends State<_FetchingOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  late final AnimationController _dotCtrl;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2000))
      ..repeat(reverse: true);
    _pulse = CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut);
    _dotCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _dotCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasBackdrop =
        widget.backdropUrl != null && widget.backdropUrl!.isNotEmpty;
    final hasLogo = widget.logoUrl != null && widget.logoUrl!.isNotEmpty;

    return Stack(children: [
      // ── 1. Backdrop ───────────────────────────────────────────────────────
      Positioned.fill(
        child: hasBackdrop
            ? CachedNetworkImage(
                imageUrl: widget.backdropUrl!,
                fit: BoxFit.cover,
                fadeInDuration: const Duration(milliseconds: 600),
                placeholder: (_, __) => Container(color: const Color(0xFF0D0D0D)),
                errorWidget: (_, __, ___) =>
                    Container(color: const Color(0xFF0D0D0D)),
              )
            : Container(color: const Color(0xFF0D0D0D)),
      ),

      // ── 2. Layered gradient overlays ──────────────────────────────────────
      Positioned.fill(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.75),
                Colors.black.withValues(alpha: 0.45),
                Colors.black.withValues(alpha: 0.8),
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
        ),
      ),

      // ── 3. Animated radial accent glow ────────────────────────────────────
      Positioned.fill(
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (_, __) => Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 0.9,
                colors: [
                  AppColors.accent.withValues(alpha: 0.14 * _pulse.value),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ),

      // ── 4. Back button ────────────────────────────────────────────────────
      Positioned(
        top: 16, left: 16,
        child: GestureDetector(
          onTap: widget.onBack,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              shape: BoxShape.circle,
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.15), width: 0.5),
            ),
            child: const Icon(Icons.arrow_back_rounded,
                color: Colors.white, size: 20),
          ),
        ),
      ),

      // ── 5. Center content ─────────────────────────────────────────────────
      Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Logo image or styled title text
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, child) =>
                  Opacity(opacity: 0.7 + 0.3 * _pulse.value, child: child),
              child: hasLogo
                  ? CachedNetworkImage(
                      imageUrl: widget.logoUrl!,
                      height: 110,
                      fit: BoxFit.contain,
                      errorWidget: (_, __, ___) => _buildStyledTitle(),
                    )
                  : _buildStyledTitle(),
            ),

            // Episode subtitle
            if (widget.subtitle.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                widget.subtitle,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.3,
                ),
              ),
            ],

            const SizedBox(height: 36),

            // Animated three-dot loader
            _AnimatedDots(controller: _dotCtrl),

            const SizedBox(height: 14),

            // Loading step message
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, __) => Text(
                widget.step,
                style: GoogleFonts.inter(
                  color: Colors.white.withValues(alpha: 0.45 + 0.3 * _pulse.value),
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ],
        ),
      ),
    ]);
  }

  Widget _buildStyledTitle() {
    return ShaderMask(
      shaderCallback: (bounds) => LinearGradient(
        colors: [
          Colors.white,
          Colors.white.withValues(alpha: 0.85),
          AppColors.accent.withValues(alpha: 0.9),
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(bounds),
      child: Text(
        widget.title.toUpperCase(),
        textAlign: TextAlign.center,
        style: GoogleFonts.oswald(
          color: Colors.white, // masked by shader
          fontSize: 38,
          fontWeight: FontWeight.w700,
          letterSpacing: 3.0,
          height: 1.1,
        ),
      ),
    );
  }
}

// ── Animated dots loader ──────────────────────────────────────────────────────

class _AnimatedDots extends StatelessWidget {
  final AnimationController controller;
  const _AnimatedDots({required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            // Each dot lags by 0.2 of the cycle
            final delay = i * 0.28;
            final t = ((controller.value - delay) % 1.0).clamp(0.0, 1.0);
            final scale = 0.5 + 0.5 * (1 - (2 * t - 1).abs());
            final opacity = 0.3 + 0.7 * scale;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 5),
              child: Transform.scale(
                scale: scale,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: opacity),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.accent.withValues(alpha: opacity * 0.6),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class _BufferingOverlay extends StatefulWidget {
  final String title;
  final String? logoUrl;
  const _BufferingOverlay({required this.title, this.logoUrl});

  @override
  State<_BufferingOverlay> createState() => _BufferingOverlayState();
}

class _BufferingOverlayState extends State<_BufferingOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat(reverse: true);
    _pulse = Tween(begin: 0.2, end: 1.0).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget logoOrTitle = widget.logoUrl != null && widget.logoUrl!.isNotEmpty
        ? CachedNetworkImage(
            imageUrl: widget.logoUrl!,
            height: 90,
            fit: BoxFit.contain,
            placeholder: (_, __) => Text(
              widget.title,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
              ),
            ),
            errorWidget: (_, __, ___) => Text(
              widget.title,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
              ),
            ),
          )
        : Text(
            widget.title,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          );

    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          color: Colors.black.withValues(alpha: 0.4),
          child: Center(
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (_, child) => Opacity(opacity: _pulse.value, child: child),
              child: logoOrTitle,
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorOverlay extends StatelessWidget {
  final String error; final VoidCallback onRetry, onBack;
  const _ErrorOverlay({required this.error, required this.onRetry, required this.onBack});

  @override
  Widget build(BuildContext context) => Stack(children: [
    Positioned(top: 12, left: 12,
      child: GestureDetector(onTap: onBack,
        child: Container(padding: const EdgeInsets.all(8),
          decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
          child: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 20)))),
    Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(border: Border.all(color: AppColors.accent, width: 2), shape: BoxShape.circle),
        child: const Icon(Icons.error_outline_rounded, color: AppColors.accent, size: 36)),
      const SizedBox(height: 20),
      Text('Playback failed', style: GoogleFonts.inter(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 12),
      Container(
        constraints: const BoxConstraints(maxWidth: 480), padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
        child: Text(error, textAlign: TextAlign.center,
            style: GoogleFonts.inter(color: Colors.white60, fontSize: 12, height: 1.5))),
      const SizedBox(height: 24),
      GestureDetector(onTap: onRetry,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(8)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.refresh_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text('Retry', style: GoogleFonts.inter(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
          ]))),
    ])),
  ]);
}

/// HLS quality variant from master.m3u8 � used by Quality panel.
class _HlsVariant {
  final String label;
  final int bandwidth;
  final String resolution;
  const _HlsVariant({required this.label, required this.bandwidth, required this.resolution});
}




// ── YouTube-style Seek Bar ─────────────────────────────────────────────────────

/// A custom seek bar with:
/// - White semi-transparent buffer indicator (YouTube-style)
/// - Red played progress
/// - Tap-anywhere-to-seek
/// - Smooth drag with growing thumb
class _VideoSeekBar extends StatefulWidget {
  final double position;   // 0.0 – 1.0
  final double buffered;   // 0.0 – 1.0
  final bool isDragging;
  final void Function(double) onSeekStart;
  final void Function(double) onSeekUpdate;
  final void Function(double) onSeekEnd;

  const _VideoSeekBar({
    required this.position,
    required this.buffered,
    required this.isDragging,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekEnd,
  });

  @override
  State<_VideoSeekBar> createState() => _VideoSeekBarState();
}

class _VideoSeekBarState extends State<_VideoSeekBar> {
  double _frac(Offset local, BoxConstraints c) =>
      (local.dx / c.maxWidth).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, constraints) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Tap anywhere to seek
        onTapDown: (d) {
          final v = _frac(d.localPosition, constraints);
          widget.onSeekStart(v);
          widget.onSeekEnd(v);
        },
        // Drag to scrub
        onHorizontalDragStart: (d) =>
            widget.onSeekStart(_frac(d.localPosition, constraints)),
        onHorizontalDragUpdate: (d) =>
            widget.onSeekUpdate(_frac(d.localPosition, constraints)),
        onHorizontalDragEnd: (_) =>
            widget.onSeekEnd(widget.position),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: CustomPaint(
            size: Size(constraints.maxWidth, 20),
            painter: _SeekBarPainter(
              position: widget.position,
              buffered: widget.buffered,
              isDragging: widget.isDragging,
            ),
          ),
        ),
      );
    });
  }
}

class _SeekBarPainter extends CustomPainter {
  final double position;
  final double buffered;
  final bool isDragging;

  const _SeekBarPainter({
    required this.position,
    required this.buffered,
    required this.isDragging,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final trackH = isDragging ? 5.0 : 3.0;
    final thumbR = isDragging ? 8.0 : 5.0;
    final r = Radius.circular(trackH);

    final paint = Paint()..isAntiAlias = true;

    // Background track
    paint.color = Colors.white.withValues(alpha: 0.20);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, cy - trackH / 2, size.width, trackH), r),
      paint);

    // Buffer track (white — YouTube-style)
    final bufW = (buffered * size.width).clamp(0.0, size.width);
    if (bufW > 0) {
      paint.color = Colors.white.withValues(alpha: 0.42);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, cy - trackH / 2, bufW, trackH), r),
        paint);
    }

    // Played track (Netflix / accent red)
    final playW = (position * size.width).clamp(0.0, size.width);
    if (playW > 0) {
      paint.color = const Color(0xFFE50914);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, cy - trackH / 2, playW, trackH), r),
        paint);
    }

    // Thumb (white circle, grows while dragging)
    paint.color = Colors.white;
    canvas.drawCircle(Offset(playW, cy), thumbR, paint);

    // Thumb inner glow while dragging
    if (isDragging) {
      paint.color = Colors.white.withValues(alpha: 0.25);
      canvas.drawCircle(Offset(playW, cy), thumbR + 5, paint);
    }
  }

  @override
  bool shouldRepaint(_SeekBarPainter old) =>
      old.position != position ||
      old.buffered != buffered ||
      old.isDragging != isDragging;
}

/// Netflix-style center skip button — just a large arrow icon, no circle border.
class _CenterSkipBtn extends StatelessWidget {
  final int secs;   // negative = rewind, positive = forward
  final VoidCallback onTap;
  const _CenterSkipBtn({required this.secs, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 60, height: 60,
        child: Icon(
          secs > 0 ? Icons.forward_10_rounded : Icons.replay_10_rounded,
          color: Colors.white,
          size: 48,
          shadows: const [Shadow(color: Colors.black54, blurRadius: 8)],
        ),
      ),
    );
  }
}
