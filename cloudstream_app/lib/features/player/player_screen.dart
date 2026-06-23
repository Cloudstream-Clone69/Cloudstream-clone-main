// lib/features/player/player_screen.dart
// Full player: lazy episode refs, on-demand fresh URL resolution, quality+subtitle panel

import 'dart:async';
import 'dart:convert';
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
import '../../core/api/tmdb_api.dart';
import '../../core/models/tmdb_models.dart';
import '../../core/services/local_db.dart';
import '../../core/services/app_settings.dart';
import '../../shared/theme/app_theme.dart';
import '../../core/services/cast_service.dart';


enum _LoadState { fetching, playing, error }
enum _PanelTab { none, sources, episodes, quality, audio, subtitles, chapters }

class PlayerScreen extends StatefulWidget {
  final String tmdbId;
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
  final String? episodeUrl;
  final String? showUrl;

  const PlayerScreen({
    super.key,
    required this.tmdbId,
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
    this.episodeUrl,
    this.showUrl,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WidgetsBindingObserver {
  // Player fields are NOT final — we recreate them on every source switch
  // to get a fully clean libmpv instance (stop()+open() on the same player
  // crashes on Windows because the DASH demuxer thread keeps running).
  late Player _player;
  late VideoController _videoCtrl;
  int _playerGeneration = 0; // incremented each rebuild so Video widget remounts

  _LoadState _loadState = _LoadState.fetching;
  String? _error;
  String _loadStep = 'Getting things ready…'; // user-friendly loading step message
  Timer? _watchdogTimer; // fires if playback never starts (e.g. DASH cookie failure)
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

  // AniSkip & Chapters
  List<SkipInterval> _skipIntervals = [];
  List<MediaChapter> _chapters = [];
  int? _malId;
  int? _anilistId;
  bool _skipTimesLoaded = false;

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

  // Casting state
  CastDevice? _activeCastDevice;

  // Fullscreen
  bool _isFullscreen = false;

  // Seek flash animation: -1 = backward, 0 = none, +1 = forward
  int _seekFlash = 0;
  Timer? _seekFlashTimer;
  Duration? _targetSeekPosition;
  Timer? _seekDebounceTimer;

  // Flag to prevent concurrent episode switches
  bool _isSwitching = false;

  // Guard flag: true while _openSource is running (between stop() and open() completing).
  // Any setProperty call or seek during this window will crash libmpv on Windows.
  bool _isPlayerBusy = false;

  // Next-episode background preload
  StreamSource? _preloadedNextSrc;
  bool _preloadingNext = false;

  // Setting: pause when app loses focus
  bool _pauseOnFocusLoss = true;
  String _subSize = '55';
  String _subColor = '#FFFFFFFF';
  String _subBgColor = '#80000000';

  Timer? _bufferPollTimer;

  final List<StreamSubscription> _subs = [];
  Timer? _progressTimer;

  @override
  void initState() {
    super.initState();
    _player = Player(configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn));
    _videoCtrl = VideoController(_player);
    _attachPlayerListeners();

    // Configure MPV for YouTube-like pre-buffering to avoid interruptions
    // Especially important on Cloudflare/slow DNS setups
    _configureBuffer();

    _selectedSeasonNumber = int.tryParse(widget.seasonNumber) ?? 1;
    _backdropUrl = widget.backdropUrl;
    _logoUrl = widget.logoUrl;
    if ((_backdropUrl == null || _backdropUrl!.isEmpty) || (_logoUrl == null || _logoUrl!.isEmpty)) {
      _fetchMediaDetailsIfNeeded();
    }
    _resolveAndPlay();
    _scheduleHide();
    _loadSettings();
    _loadAllSeasons();
    if (widget.mediaType == 'tv') {
      Future.microtask(() => _loadTmdbEpisodes());
    }
    WidgetsBinding.instance.addObserver(this);
  }

  /// Attach all stream listeners to the current _player instance.
  /// Called once at init and again after every player rebuild.
  void _attachPlayerListeners() {
    _subs.addAll([
      _player.stream.position.listen((p) {
        if (_isDragging || _targetSeekPosition != null || !mounted) return;
        setState(() => _position = p);
        _checkSkipOverlays(p);
      }),
      _player.stream.duration.listen((d) {
        if (mounted) {
          setState(() => _duration = d);
          if (d.inSeconds > 0) {
            if (!_skipTimesLoaded) {
              _fetchSkipTimes();
            }
            if (_chapters.isEmpty) {
              _fetchChapters();
            }
          }
        }
      }),
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
        // Ignore errors fired during teardown (generation mismatch)
        if (e.isNotEmpty && mounted && !_isSwitching) _onPlaybackError(e);
      }),
      // Auto-play next episode when current finishes
      _player.stream.completed.listen((done) {
        if (done && mounted && widget.mediaType == 'tv' && !_isSwitching) {
          Future.delayed(const Duration(milliseconds: 500), _goNextEpisode);
        }
      }),
    ]);
  }

  /// Fully rebuilds the Player and VideoController to get a completely clean
  /// libmpv instance before opening a new source.
  ///
  /// WHY WE RECREATE instead of reusing the same player:
  ///   Calling open() on an existing Player that was playing a DASH stream
  ///   causes libmpv's internal demuxer thread to run teardown while the
  ///   C++ network read loop is still active on Windows → ntdll.dll 0xC0000005.
  ///
  Future<void> _safeSwitchPlayer() async {
    // Cancel all timers that interact with the player
    _watchdogTimer?.cancel();
    _bufferPollTimer?.cancel();
    _nextEpTimer?.cancel();
    _seekDebounceTimer?.cancel();
    _progressTimer?.cancel();

    // Detach Dart listeners before touching native player
    for (final s in _subs) { try { s.cancel(); } catch (_) {} }
    _subs.clear();

    // ── Step 1: Kill all proxy segment downloads ──────────────────────────────
    // This stops data arriving at libmpv's ring-buffer before we do anything else.
    try {
      await Dio().get('${AppSettings.instance.backendUrl}/proxy/abort-all')
          .timeout(const Duration(milliseconds: 600));
    } catch (_) {}

    // ── Step 2: Tell MPV to stop its demuxer read-ahead ───────────────────────
    // These are synchronous native calls — just fire them.
    try {
      final native = _player.platform as dynamic;
      native.setProperty('demuxer-max-bytes', '1');
      native.setProperty('cache', 'no');
    } catch (_) {}

    // ── Step 3: Pause the player ──────────────────────────────────────────────
    try { await _player.pause(); } catch (_) {}

    // ── Step 4: Wait for everything to settle ─────────────────────────────────
    // 500ms gives the demuxer write queue and any in-flight native callbacks
    // time to drain before we call open() on the same player.
    await Future.delayed(const Duration(milliseconds: 500));

    // ── Step 5: Reset playback UI state ──────────────────────────────────────
    if (mounted) setState(() {
      _isPlayerBusy = false;
      _isBuffering  = false;
      _position     = Duration.zero;
      _duration     = Duration.zero;
      _buffered     = Duration.zero;
      _hlsVariants  = [];
      _activeVariantBandwidth = -1;
      _tracks       = const Tracks();
      _activeVideo  = VideoTrack.auto();
      _activeAudio  = AudioTrack.auto();
      _activeSubtitle = SubtitleTrack.no();
    });

    // ── Step 6: Reattach listeners to the same player ────────────────────────
    // We deliberately do NOT recreate the Player instance. MPV's own
    // player.open(newMedia) sends 'loadfile … replace' to the internal
    // playloop thread, which tears down the old demuxer from the SAME thread
    // that owns it — making the transition atomic and crash-free on Windows.
    _attachPlayerListeners();
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
    _seekDebounceTimer?.cancel();
    _watchdogTimer?.cancel();
    _hideTimer?.cancel();
    _progressTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_isFullscreen) {
      try {
        windowManager.setFullScreen(false);
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      } catch (_) {}
    }
    // Cancel all Dart stream subscriptions before touching native player
    for (final s in _subs) { try { s.cancel(); } catch (_) {} }
    // ── DASH demuxer drain (synchronous best-effort) ─────────────────────
    // Note: _goNextEpisode already aborts + drains + pauses before navigation,
    // so in most cases the player is already quiet here.
    // For unexpected dispose (e.g. back button), do a best-effort drain.
    try {
      final native = _player.platform as dynamic;
      native.setProperty('cache', 'no');
      native.setProperty('demuxer-max-bytes', '1');
    } catch (_) {}
    try { _player.pause(); } catch (_) {}
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
      _loadStep = 'Loading available sources…';
    });

    try {
      // Step 1: Fetch all episode references first (so the sources list is loaded FIRST!)
      final providerFilter = (widget.preloadedProvider != null && widget.preloadedProvider!.isNotEmpty)
          ? widget.preloadedProvider
          : null;

      final refs = await StreamResolver.instance.getEpisodeRefs(
        title: widget.title,
        mediaType: widget.mediaType,
        year: widget.year,
        seasonNumber: widget.seasonNumber.isEmpty ? null : widget.seasonNumber,
        episodeNumber: widget.episodeNumber.isEmpty ? null : widget.episodeNumber,
        isAnime: widget.isAnime,
        provider: providerFilter,
        showUrl: widget.showUrl,
      );

      if (refs.isNotEmpty) {
        if (mounted) setState(() {
          _episodeRefs = refs;
        });

        // Resolve preferred language/quality
        final prefs = await SharedPreferences.getInstance();
        final prefLang = prefs.getString('preferred_anidb_lang') ?? 'Sub';

        // Select the best match from refs
        EpisodeRef bestRef = refs.first;
        for (final r in refs) {
          if (r.quality.toLowerCase() == prefLang.toLowerCase()) {
            bestRef = r;
            break;
          }
        }

        final idx = refs.indexOf(bestRef);
        if (mounted && idx >= 0) {
          setState(() {
            _activeRefIdx = idx;
          });
        }

        // If we have a preloaded URL, use it directly instead of resolving again
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
            episodeUrl: '',
          );

          if (mounted) setState(() {
            _currentSource = preloadedSrc;
            _loadState = _LoadState.playing;
            _showControls = false;
            _watchdogTimer?.cancel();
          });

          await _openSource(preloadedSrc);
          _saveHistory();
          return;
        }

        if (mounted) setState(() {
          _loadStep = 'Resolving stream: ${bestRef.label}…';
        });

        final src = await StreamResolver.instance.resolveStreamForEpisode(
          provider: bestRef.provider,
          episodeUrl: bestRef.episodeUrl,
          quality: bestRef.quality,
          size: bestRef.size,
          label: bestRef.label,
        );

        if (src == null) {
          throw Exception('Could not resolve stream for "${widget.title}".');
        }

        if (mounted) setState(() {
          _currentSource = src;
          _loadState = _LoadState.playing;
          _showControls = false;
          _watchdogTimer?.cancel();
        });

        await _openSource(src);
        _saveHistory();
        return;
      }

      // Step 2: Fallback to direct resolution of episodeUrl if refs is empty (e.g. scraper detail mapped watch URL)
      if (widget.episodeUrl != null && widget.episodeUrl!.isNotEmpty) {
        if (mounted) setState(() {
          _loadStep = 'Resolving stream from ${widget.preloadedProvider ?? "provider"}…';
        });
        final src = await StreamResolver.instance.resolveStreamForEpisode(
          provider: widget.preloadedProvider ?? '',
          episodeUrl: widget.episodeUrl!,
          quality: '1080p',
          size: '',
          label: '${widget.title} - ${widget.episodeTitle}',
        );
        if (src == null) {
          throw Exception('Could not resolve stream for "${widget.title}".');
        }
        _setCurrentSource(src);
        _fetchEpisodeRefsInBackground();
        await _openSource(src);
        _saveHistory();
        return;
      }

      // Step 3: Fallback to preloadedUrl
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
          episodeUrl: '',
        );

        _setCurrentSource(preloadedSrc);
        _fetchEpisodeRefsInBackground();
        await _openSource(preloadedSrc);
        _saveHistory();
        return;
      }

      // Step 4: Fallback to resolveFirstSource
      if (mounted) setState(() {
        _loadStep = 'Searching for first working source…';
      });
      final first = await StreamResolver.instance.resolveFirstSource(
        title: widget.title, mediaType: widget.mediaType, year: widget.year,
        seasonNumber: widget.seasonNumber.isEmpty ? null : widget.seasonNumber,
        episodeNumber: widget.episodeNumber.isEmpty ? null : widget.episodeNumber,
        isAnime: widget.isAnime,
        provider: providerFilter,
      );

      if (first == null) {
        final backendUp = await StreamResolver.instance.ping();
        if (!backendUp) {
          throw Exception('The streaming service is not running.\nPlease start the backend server and try again.');
        } else {
          throw Exception('"${widget.title}" could not be found.\n\nTry searching with a different title, or this content may not be available yet.');
        }
      }

      _setCurrentSource(first);
      _fetchEpisodeRefsInBackground();
      await _openSource(first);
      _saveHistory();

    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loadState = _LoadState.error; });
    }
  }

  void _setCurrentSource(StreamSource src) {
    if (mounted) {
      setState(() {
        _currentSource = src;
        _loadState = _LoadState.playing;
        _showControls = false;
        _watchdogTimer?.cancel();
        if (_episodeRefs.isEmpty) {
          _episodeRefs = [
            EpisodeRef(
              provider: src.provider,
              quality: src.quality,
              size: src.size,
              title: src.label,
              episodeUrl: src.episodeUrl.isNotEmpty ? src.episodeUrl : widget.episodeUrl ?? '',
            )
          ];
          _activeRefIdx = 0;
        }
      });
    }
  }

  void _fetchEpisodeRefsInBackground() async {
    try {
      final settings = AppSettings.instance;
      final List<String> rawOrder = widget.isAnime
          ? settings.animeProviderOrder
          : (widget.mediaType == 'movie'
              ? settings.movieProviderOrder
              : settings.seriesProviderOrder);

      final List<String> providers;
      if (widget.preloadedProvider != null && widget.preloadedProvider!.isNotEmpty) {
        providers = [widget.preloadedProvider!];
      } else {
        providers = rawOrder.where((p) => StreamResolver.instance.isProviderEnabled(p)).toList();
      }
      if (providers.isEmpty) return;

      print('[Player] Progressive fetch started for: $providers');

      for (final p in providers) {
        StreamResolver.instance.getEpisodeRefs(
          title: widget.title,
          mediaType: widget.mediaType,
          year: widget.year,
          seasonNumber: widget.seasonNumber.isEmpty ? null : widget.seasonNumber,
          episodeNumber: widget.episodeNumber.isEmpty ? null : widget.episodeNumber,
          isAnime: widget.isAnime,
          provider: p,
          showUrl: widget.showUrl,
        ).then((newRefs) {
          if (!mounted) return;
          if (newRefs.isNotEmpty) {
            setState(() {
              final existingUrls = _episodeRefs.map((r) => r.episodeUrl).toSet();
              final uniqueNew = newRefs.where((r) => !existingUrls.contains(r.episodeUrl)).toList();
              
              if (uniqueNew.isNotEmpty) {
                if (_episodeRefs.length == 1 && (_episodeRefs[0].episodeUrl == widget.episodeUrl || _episodeRefs[0].episodeUrl == _currentSource?.episodeUrl)) {
                  final hasMatch = uniqueNew.any((r) => r.episodeUrl == _episodeRefs[0].episodeUrl);
                  if (hasMatch) {
                    _episodeRefs = uniqueNew;
                  } else {
                    _episodeRefs = [..._episodeRefs, ...uniqueNew];
                  }
                } else {
                  _episodeRefs = [..._episodeRefs, ...uniqueNew];
                }
                
                if (_currentSource != null) {
                  final activeUrl = _currentSource!.episodeUrl;
                  final idx = _episodeRefs.indexWhere((r) => r.episodeUrl == activeUrl || r.episodeUrl == widget.episodeUrl);
                  if (idx >= 0) {
                    _activeRefIdx = idx;
                  }
                }
                print('[Player] Added ${uniqueNew.length} refs from $p. Total: ${_episodeRefs.length}');
              }
            });
          }
        }).catchError((err) {
          print('[Player] Progressive fetch error for $p: $err');
        });
      }
    } catch (e) {
      print('[Player] Progressive fetch master error: $e');
    }
  }


  // ── Buffering ──────────────────────────────────────────────────────────────────────

  /// Configure MPV buffer — fast start, large forward+backward cache for smooth seeking.
  void _configureBuffer() async {
    try {
      final native = _player.platform as dynamic;
      await native.setProperty('cache', 'yes');
      // Buffer 120s ahead for smooth network playback
      await native.setProperty('cache-secs', '120');
      await native.setProperty('demuxer-readahead-secs', '120');
      
      // 150MB max buffer to store high-bitrate video segments in memory
      await native.setProperty('demuxer-max-bytes', '150MiB');
      await native.setProperty('demuxer-max-back-bytes', '50MiB'); // back buffer for smooth rewinding
      
      // Stop buffering once the limit is reached and resume when 10s remain
      await native.setProperty('demuxer-hysteresis-secs', '10');
      
      // Keyframe seeking — MUCH faster than hr-seek for HLS (no frame decode overhead)
      await native.setProperty('hr-seek', 'no');
      // Pause playback during seek buffer fill to prevent desync
      await native.setProperty('cache-pause', 'yes');
      
      await native.setProperty('hls-bitrate', 'max');
      await native.setProperty('prefetch-playlist', 'no');
      await native.setProperty('hwdec', 'auto-safe');
      await _applySubtitleStyle();
      print('[Player] Buffer configured: 120s readahead, 150MB max-bytes, hwdec=auto-safe');
    } catch (e) {
      print('[Player] Buffer config skipped: $e');
    }
  }

  /// Awaitable version of _configureBuffer — used after _rebuildPlayer()
  /// so buffer settings are applied before _openSource is called.
  Future<void> _configureBufferAsync() async {
    try {
      final native = _player.platform as dynamic;
      await native.setProperty('cache', 'yes');
      await native.setProperty('cache-secs', '120');
      await native.setProperty('demuxer-readahead-secs', '120');
      await native.setProperty('demuxer-max-bytes', '150MiB');
      await native.setProperty('demuxer-max-back-bytes', '50MiB');
      await native.setProperty('demuxer-hysteresis-secs', '10');
      await native.setProperty('hr-seek', 'no');
      await native.setProperty('cache-pause', 'yes');
      await native.setProperty('hls-bitrate', 'max');
      await native.setProperty('prefetch-playlist', 'no');
      await native.setProperty('hwdec', 'auto-safe');
      await _applySubtitleStyle();
    } catch (_) {}
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

  Future<void> _openSource(StreamSource source, {Duration? startPosition}) async {
    print('[Player] Opening: ${source.url}');
    setState(() {
      _skipIntervals = [];
      _chapters = [];
      _skipTimesLoaded = false;
    });

    // For proxied DASH streams (/proxy/stream.mpd) the Node.js proxy injects
    // CloudFront cookies server-side into every segment request via /proxy/cdn/:session.
    // Passing the 650-char CloudFront cookie string into libmpv's native property
    // system causes a memory access violation (0xc0000005 in ntdll.dll) on Windows.
    // We therefore skip ALL http-header-fields and Media httpHeaders for proxied DASH.
    final bool isProxiedDash = source.url.contains('/proxy/stream.mpd') || source.url.contains('/proxy/mpd');

    // Mark player as busy — no seek calls should happen until open() finishes.
    _isPlayerBusy = true;

    try {
      final native = _player.platform as dynamic;

      // Apply all buffer + network settings FIRST, sequentially, before open().
      // This MUST be awaited — calling open() while setProperty calls are still
      // in progress on the same player instance causes a crash on Windows.
      await _configureBufferAsync();

      // AniDB streams require Android Dalvik UA to bypass Cloudflare CDN.
      // All other providers use a standard browser UA.
      if (source.provider == 'anidb') {
        await native.setProperty('user-agent',
            'Dalvik/2.1.0 (Linux; U; Android 13; Pixel 7 Build/TQ3A.230805.001)');
      } else {
        await native.setProperty('user-agent',
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
      }

      // Referer via MPV property (applies to all sub-requests)
      if (source.referer.isNotEmpty) {
        await native.setProperty('referrer', source.referer);
      }

      if (!isProxiedDash) {
        final headerParts = <String>[];
        if (source.cookie.isNotEmpty) {
          headerParts.add('Cookie: ${source.cookie}');
        }
        if (source.referer.isNotEmpty) {
          headerParts.add('Referer: ${source.referer}');
        }
        if (headerParts.isNotEmpty) {
          await native.setProperty('http-header-fields', headerParts.join(','));
          print('[Player] Set http-header-fields: ${headerParts.map((h) => h.split(':').first).join(", ")}');
        } else {
          // Clear any previous headers from a different stream
          await native.setProperty('http-header-fields', '');
        }
      } else {
        // Explicitly clear headers so a previous stream's large cookie isn't reused
        try { await native.setProperty('http-header-fields', ''); } catch (_) {}
        print('[Player] Proxied DASH — skipping http-header-fields (proxy handles auth)');
      }
    } catch (e) {
      print('[Player] MPV property error: $e');
    }

    // Guard: if the widget was unmounted or a new switch started during the
    // async setProperty calls above, abort before calling open().
    if (!mounted) { _isPlayerBusy = false; return; }

    // Build per-media HTTP headers map (for HLS/MP4 direct streams).
    // Skip for proxied DASH — the Node.js proxy handles all auth server-side
    // and passing the large CloudFront cookie here crashes libmpv on Windows.
    final Map<String, String> httpHeaders = {};
    if (!isProxiedDash) {
      if (source.referer.isNotEmpty) {
        httpHeaders['Referer'] = source.referer;
      }
      if (source.cookie.isNotEmpty) {
        httpHeaders['Cookie'] = source.cookie;
      }
    }

    // Open the stream.
    // NOTE: open() is fully async internally — it fetches the MPD/M3U8, initialises
    // the demuxer, and THEN starts playback. DO NOT call play() immediately after
    // open(play:true) — that races the demuxer init and causes a crash in libmpv.
    final media = httpHeaders.isNotEmpty
        ? Media(source.url, httpHeaders: httpHeaders)
        : Media(source.url);

    try {
      await _player.open(media, play: true);
      // open(play:true) already starts playback — no additional .play() call needed.
    } catch (e) {
      print('[Player] _player.open error: $e');
      _isPlayerBusy = false;
      rethrow;
    }

    // Player is now live — release the busy guard
    _isPlayerBusy = false;

    // Reset quality panel + buffer tracker, and transition to playing state
    if (mounted) {
      setState(() {
        _hlsVariants = [];
        _activeVariantBandwidth = -1;
        _buffered = Duration.zero;
        _loadState = _LoadState.playing;
      });
    }
    _fetchHlsVariants(source);
    _startBufferPolling();

    // ── Playback-start watchdog ───────────────────────────────────────────────
    // If MPV opens the URL but never starts buffering, switch to fallback after 25s.
    _schedulePlaybackWatchdog(source, timeout: const Duration(seconds: 25));

    // Load subtitle if available
    // If no external subtitle URL is provided, disable auto-selected embedded subs.
    // MPV would otherwise auto-activate the first embedded track (e.g. Italian signs+songs).
    if (source.subtitleUrl.isEmpty) {
      try {
        final native = _player.platform as dynamic;
        await native.setProperty('sid', 'no');
      } catch (_) {}
    }
    if (source.subtitleUrl.isNotEmpty) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      try {
        if (source.subtitleUrl.trim().startsWith('[')) {
          final List<dynamic> list = jsonDecode(source.subtitleUrl);
          if (list.isNotEmpty) {
            final first = list[0];
            final url = first['url']?.toString() ?? '';
            final lang = first['lang']?.toString() ?? 'English';
            final code = first['code']?.toString() ?? 'en';
            if (url.isNotEmpty) {
              await _player.setSubtitleTrack(SubtitleTrack.uri(url, title: lang, language: code));
              await _applySubtitleStyle();
              print('[Player] JSON Subtitle loaded: $lang -> $url');
            }
          }
        } else {
          await _player.setSubtitleTrack(SubtitleTrack.uri(source.subtitleUrl, title: 'English', language: 'en'));
          await _applySubtitleStyle();
          print('[Player] Subtitle loaded: ${source.subtitleUrl}');
        }
      } catch (e) { print('[Player] Subtitle failed: $e'); }
    }

    // ── Resume Position ────────────────────────────────────────────────────────
    Duration? seekTo = startPosition;
    if (seekTo == null) {
      final tmdbIdInt = int.tryParse(widget.tmdbId) ?? 0;
      if (tmdbIdInt > 0) {
        try {
          final entry = await LocalDb.instance.getHistoryEntry(
            tmdbIdInt,
            seasonNumber: widget.seasonNumber.isEmpty ? null : widget.seasonNumber,
            episodeNumber: widget.episodeNumber.isEmpty ? null : widget.episodeNumber,
          );
          if (entry != null && entry.progressSeconds > 5 && entry.durationSeconds > 0) {
            final pct = entry.progressSeconds / entry.durationSeconds;
            if (pct < 0.95) {
              seekTo = Duration(seconds: entry.progressSeconds);
              print('[Player] Watch history found for tmdbId=$tmdbIdInt: resuming at ${seekTo.inSeconds}s (progress: ${(pct * 100).toStringAsFixed(1)}%)');
            } else {
              print('[Player] Watch history found, but user watched ${(pct * 100).toStringAsFixed(1)}% (>95%) — starting from beginning');
            }
          }
        } catch (e) {
          print('[Player] Failed to load resume progress: $e');
        }
      }
    }

    if (seekTo != null && seekTo.inSeconds > 5) {
      // Delay slightly for demuxer to start pushing frames before we seek
      await Future.delayed(const Duration(milliseconds: 1000));
      if (mounted) {
        try {
          print('[Player] Seeking to starting position: ${seekTo.inSeconds}s');
          await _player.seek(seekTo);
        } catch (err) {
          print('[Player] Initial seek failed: $err');
        }
      }
    }
  }

  // ── HLS quality variants ─────────────────────────────────────────────────────

  /// Fetches the HLS master.m3u8 via the local proxy (which handles UA + Referer
  /// correctly for both AniDB/Dalvik and AniDAO/vibeplayer) then parses quality variants.
  void _fetchHlsVariants(StreamSource source) async {
    if (!source.url.contains('.m3u8') && !source.url.contains('/proxy/dash')) return;

    final String fetchUrl;
    if (source.url.contains('/proxy/dash')) {
      fetchUrl = source.url;
    } else {
      final encodedUrl = Uri.encodeComponent(source.url);
      final encodedRef = Uri.encodeComponent(source.referer);
      fetchUrl = '${AppSettings.instance.backendUrl}/proxy/hls?url=$encodedUrl&ref=$encodedRef';
    }

    try {
      // We use the existing node proxy to fetch with correct UA/Referer
      final resp = await StreamResolver.dio.get<String>(fetchUrl,
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

  /// Select a source from the panel — resolves a fresh stream URL on demand.
  /// Stops old playback, clears buffers, and safely loads the new source.
  /// Uses try/finally to ALWAYS reset _isSwitching even on error/unmount.
  Future<void> _selectEpisodeRef(int idx) async {
    if (idx < 0 || idx >= _episodeRefs.length) return;
    if (_isSwitching) return;
    _isSwitching = true;

    try {
      final ref = _episodeRefs[idx];
      final savedPosition = _position;

      // ── CRITICAL: hide the Video widget BEFORE touching the player ────────
      // The Video widget renders from a native libmpv texture. If Flutter's
      // render thread is reading that texture while we pause/abort/switch the
      // player, we get an ntdll.dll 0xC0000005 access violation on Windows.
      // Setting _loadState = fetching unmounts the Video widget so the render
      // thread stops touching the native texture completely.
      if (mounted) setState(() {
        _loadState = _LoadState.fetching;
        _loadStep = 'Switching source…';
        _activeRefIdx = idx;
        _isResolvingSource = true;
        _panel = _PanelTab.none;
        _showNextEp = false;
        _nextEpCountdown = 5;
      });

      // Give Flutter one frame to rebuild without the Video widget
      await Future.delayed(const Duration(milliseconds: 32));
      if (!mounted) return;

      // Safely drain the DASH demuxer buffer, then stop.
      // See _safeSwitchPlayer() for full explanation.
      await _safeSwitchPlayer();
      if (!mounted) return;

      // Resolve the new stream URL

      // Resolve the new stream URL
      final src = await StreamResolver.instance.resolveStreamForEpisode(
        provider: ref.provider,
        episodeUrl: ref.episodeUrl,
        quality: ref.quality,
        size: ref.size,
        label: ref.label,
      );

      if (!mounted) return;
      if (mounted) setState(() => _isResolvingSource = false);

      if (src != null) {
        if (mounted) setState(() => _currentSource = src);
        if (ref.provider == 'anidb') {
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('preferred_anidb_lang', ref.quality);
          } catch (_) {}
        }
        await _openSource(src, startPosition: savedPosition);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to load source. Try another.',
                  style: GoogleFonts.inter(fontSize: 12, color: Colors.white)),
              backgroundColor: Colors.red.shade900,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      print('[Player] _selectEpisodeRef error: $e');
      if (mounted) {
        setState(() {
          _isResolvingSource = false;
          _error = 'Source switch failed: $e';
          _loadState = _LoadState.error;
        });
      }
    } finally {
      _isSwitching = false;
    }
  }

  /// Fires [timeout] after _openSource if playback truly gets stuck.
  /// Switches to next EpisodeRef when a stream fails to start.
  /// Does NOT fire if MPV is actively buffering (_isBuffering=true).
  void _schedulePlaybackWatchdog(StreamSource source, {required Duration timeout}) {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(timeout, () {
      if (!mounted) return;
      // Stream is fine if position advanced OR MPV is actively buffering
      if (_position > Duration.zero || _isBuffering) {
        print('[Player] [Watchdog] OK (pos=${_position.inSeconds}s buf=$_isBuffering) — no switch');
        return;
      }
      print('[Player] [Watchdog] Stuck after ${timeout.inSeconds}s → next source');
      _onPlaybackError('Stream did not start after ${timeout.inSeconds}s');
    });
  }

  Future<void> _onPlaybackError(String err) async {
    print('[Player] Playback error: $err');
    if (!mounted) return;

    // If the player is still in the middle of open() / demuxer init,
    // don't try to stop or re-open — we'd interrupt the init and crash.
    if (_isPlayerBusy) {
      print('[Player] _onPlaybackError: player busy (init), ignoring error');
      return;
    }

    if (_currentSource == null) {
      if (mounted) setState(() { _error = err; _loadState = _LoadState.error; });
      return;
    }

    // If we're already switching, don't layer another switch on top
    if (_isSwitching) {
      print('[Player] _onPlaybackError: switch already in progress, ignoring');
      return;
    }

    final cur = _currentSource!;
    final isProxyError = cur.url.contains('127.0.0.1') || cur.url.contains('localhost');

    // If direct CDN URL failed, try the proxyUrl as fallback
    if (!isProxyError && cur.fallbackUrl.isNotEmpty) {
      print('[Player] Direct CDN failed, trying proxy fallback...');
      final fallback = StreamSource(
        provider: cur.provider, label: '${cur.label} [Proxy]',
        quality: cur.quality, size: cur.size,
        url: cur.fallbackUrl, fallbackUrl: '',
        referer: cur.referer, subtitleUrl: cur.subtitleUrl,
        episodeUrl: cur.episodeUrl, cookie: cur.cookie,
      );
      if (mounted) setState(() {
        _loadState = _LoadState.fetching;
        _loadStep = 'Trying fallback source…';
        _currentSource = fallback;
      });
      // Wait one frame for the Video widget to unmount before switching
      await Future.delayed(const Duration(milliseconds: 32));
      if (!mounted) return;
      await _safeSwitchPlayer();
      if (mounted) _openSource(fallback, startPosition: _position);
      return;
    }

    // Proxy failed or no fallback — re-resolve next source fresh
    final nextIdx = _activeRefIdx + 1;
    if (nextIdx < _episodeRefs.length) {
      print('[Player] Trying next source ($nextIdx/${_episodeRefs.length})...');
      if (mounted) setState(() {
        _loadState = _LoadState.fetching;
        _loadStep = 'Trying another source ($nextIdx/${_episodeRefs.length})…';
      });
      _isSwitching = false;
      _selectEpisodeRef(nextIdx);
    } else if (_episodeRefs.isEmpty && cur.episodeUrl.isNotEmpty) {
      if (mounted) setState(() { _error = err; _loadState = _LoadState.error; });
    } else {
      if (mounted) setState(() { _error = err; _loadState = _LoadState.error; });
    }
  }

  void _saveHistory() async {
    final tmdbIdInt = int.tryParse(widget.tmdbId) ?? 0;
    if (tmdbIdInt <= 0) return;
    try {
      await LocalDb.instance.saveHistory(WatchHistory(
        tmdbId: tmdbIdInt, title: widget.title, posterUrl: '',
        mediaType: widget.mediaType,
        seasonNumber: widget.seasonNumber.isEmpty ? null : widget.seasonNumber,
        episodeNumber: widget.episodeNumber.isEmpty ? null : widget.episodeNumber,
        episodeTitle: widget.episodeTitle.isEmpty ? null : widget.episodeTitle,
        progressSeconds: 0, durationSeconds: 0, lastWatchedAt: DateTime.now(),
      ));
    } catch (_) {}
    // Cancel any existing progress timer before creating a new one
    // (prevents timer accumulation when switching sources)
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!mounted) return;
      if (_duration.inSeconds > 0) {
        try {
          await LocalDb.instance.updateProgress(tmdbIdInt,
            seasonNumber: widget.seasonNumber.isEmpty ? null : widget.seasonNumber,
            episodeNumber: widget.episodeNumber.isEmpty ? null : widget.episodeNumber,
            progressSeconds: _position.inSeconds, durationSeconds: _duration.inSeconds,
          );
        } catch (_) {}
      }
    });
  }

  Future<void> _resolveAnimeIds(String title) async {
    if (_malId != null && _anilistId != null) return;
    try {
      final query = """
      query (\$search: String) {
        Media(search: \$search, type: ANIME) {
          id
          idMal
        }
      }
      """;
      final dio = Dio();
      final res = await dio.post(
        'https://graphql.anilist.co',
        data: {
          'query': query,
          'variables': {'search': title},
        },
      );
      if (res.statusCode == 200 && res.data != null) {
        final media = res.data['data']?['Media'];
        if (media != null) {
          _anilistId = media['id'] as int?;
          _malId = media['idMal'] as int?;
          print('[AniList] Resolved AniList ID: $_anilistId, MAL ID: $_malId');
        }
      }
    } catch (e) {
      print('[AniList] Error resolving Anime IDs for "$title": $e');
    }
  }

  Future<List<SkipInterval>> _fetchAnimeSkipTimes(int anilistId) async {
    try {
      final query = """
      query (\$anilistId: String!) {
        findShowsByExternalId(service: ANILIST, serviceId: \$anilistId) {
          episodes {
            number
            absoluteNumber
            timestamps {
              at
              type {
                name
              }
            }
          }
        }
      }
      """;

      print('[Anime-Skip] Fetching timestamps for AniList ID: $anilistId');
      final dio = Dio();
      final res = await dio.post(
        'https://api.anime-skip.com/graphql',
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'X-Client-ID': 'ZGfO0sMF3eCwLYf8yMSCJjlynwNGRXWE',
          },
        ),
        data: {
          'query': query,
          'variables': {'anilistId': anilistId.toString()},
        },
      );

      if (res.statusCode == 200 && res.data != null) {
        final shows = res.data['data']?['findShowsByExternalId'];
        if (shows is List && shows.isNotEmpty) {
          final show = shows[0];
          final episodes = show['episodes'];
          if (episodes is List) {
            final targetEpStr = widget.episodeNumber;
            // Try to find the episode matching targetEpStr
            var ep = episodes.firstWhere(
              (e) => e['number'] == targetEpStr || e['absoluteNumber'] == targetEpStr,
              orElse: () => null,
            );

            // If not found directly, try parsing numbers
            if (ep == null) {
              final targetEpNum = double.tryParse(targetEpStr);
              if (targetEpNum != null) {
                ep = episodes.firstWhere(
                  (e) {
                    final epNum = double.tryParse(e['number'] ?? '');
                    final absNum = double.tryParse(e['absoluteNumber'] ?? '');
                    return epNum == targetEpNum || absNum == targetEpNum;
                  },
                  orElse: () => null,
                );
              }
            }

            if (ep != null) {
              final timestamps = ep['timestamps'];
              if (timestamps is List && timestamps.isNotEmpty) {
                // Sort timestamps by 'at' ascending
                final List<Map<String, dynamic>> sortedTs = timestamps
                    .map((t) => Map<String, dynamic>.from(t as Map))
                    .toList();
                sortedTs.sort((a, b) {
                  final aAt = (a['at'] as num).toDouble();
                  final bAt = (b['at'] as num).toDouble();
                  return aAt.compareTo(bAt);
                });

                final List<SkipInterval> intervals = [];
                for (int i = 0; i < sortedTs.length; i++) {
                  final ts = sortedTs[i];
                  final typeName = ts['type']?['name'] as String?;
                  if (typeName == 'Intro' || typeName == 'Credits' || typeName == 'Recap') {
                    final startTime = (ts['at'] as num).toDouble();
                    // End time is either the next timestamp's 'at' or the episode length (duration)
                    double endTime = _duration.inSeconds.toDouble();
                    if (i + 1 < sortedTs.length) {
                      endTime = (sortedTs[i + 1]['at'] as num).toDouble();
                    }

                    // Map Anime-Skip names to app-expected types
                    String skipType = 'op';
                    if (typeName == 'Credits') {
                      skipType = 'ed';
                    } else if (typeName == 'Recap') {
                      skipType = 'recap';
                    }

                    // Ensure start and end times make sense
                    if (endTime > startTime && startTime >= 0) {
                      intervals.add(SkipInterval(
                        startTime: startTime,
                        endTime: endTime,
                        type: skipType,
                      ));
                    }
                  }
                }
                print('[Anime-Skip] Successfully parsed ${intervals.length} intervals');
                return intervals;
              }
            }
          }
        }
      }
    } catch (e) {
      print('[Anime-Skip] Error fetching timestamps: $e');
    }
    return [];
  }

  Future<void> _fetchSkipTimes() async {
    final currentProv = widget.preloadedProvider ?? _currentSource?.provider;
    final isAnime = widget.isAnime ||
        currentProv?.toLowerCase() == 'anidb' ||
        currentProv?.toLowerCase() == 'anidao';
    if (!isAnime) return;

    if (_duration.inSeconds <= 0) return;
    if (_skipTimesLoaded) return;
    _skipTimesLoaded = true;

    try {
      await _resolveAnimeIds(widget.title);
      final malId = _malId;
      final anilistId = _anilistId;

      List<SkipInterval> intervals = [];

      // Try AniSkip first if malId is resolved
      if (malId != null) {
        final epNum = double.tryParse(widget.episodeNumber) ?? 1.0;
        final epLength = _duration.inSeconds.toDouble();
        final url = 'https://api.aniskip.com/v2/skip-times/$malId/$epNum?types[]=op&types[]=ed&types[]=recap&episodeLength=$epLength';
        print('[AniSkip] Fetching skip times: $url');

        final dio = Dio();
        try {
          final res = await dio.get(url, options: Options(
            headers: {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            },
            validateStatus: (status) => status != null && status < 600,
          ));
          print('[AniSkip] Response status: ${res.statusCode}');
          if (res.statusCode == 200 && res.data != null) {
            final data = res.data;
            final dataStatus = data['statusCode'];
            if (dataStatus == 200 && data['results'] != null) {
              final List<dynamic> results = data['results'];
              for (final r in results) {
                final interval = r['interval'];
                if (interval != null) {
                  intervals.add(SkipInterval(
                    startTime: (interval['startTime'] as num).toDouble(),
                    endTime: (interval['endTime'] as num).toDouble(),
                    type: r['skipType'] ?? 'op',
                  ));
                }
              }
            }
          }
        } catch (e) {
          print('[AniSkip] Error querying AniSkip API: $e');
        }
      }

      // If AniSkip returned nothing (or is down), try Anime-Skip fallback using anilistId
      if (intervals.isEmpty && anilistId != null) {
        print('[Anime-Skip] Trying Anime-Skip GraphQL fallback...');
        intervals = await _fetchAnimeSkipTimes(anilistId);
      }

      if (intervals.isNotEmpty) {
        if (mounted) {
          setState(() {
            _skipIntervals = intervals;
          });
          print('[AniSkip/Anime-Skip] Loaded ${intervals.length} skip intervals');
        }
      } else {
        print('[AniSkip/Anime-Skip] No skip times resolved.');
      }
    } catch (e) {
      print('[AniSkip] Error resolving skip times: $e');
    }
  }

  Future<void> _fetchChapters() async {
    try {
      final native = _player.platform as dynamic;
      final String? listStr = await native.getProperty('chapter-list');
      if (listStr != null && listStr.isNotEmpty) {
        final List<dynamic> list = jsonDecode(listStr);
        final List<MediaChapter> chaptersList = [];

        for (var i = 0; i < list.length; i++) {
          final item = list[i];
          final String title = item['title'] ?? 'Chapter ${i + 1}';
          final double timeSecs = (item['time'] as num).toDouble();
          chaptersList.add(MediaChapter(
            title: title,
            time: Duration(seconds: timeSecs.round()),
          ));
        }

        if (mounted) {
          setState(() {
            _chapters = chaptersList;
          });
          print('[Player] Loaded ${chaptersList.length} chapters from MPV');

          // ── Build skip intervals from chapter names when AniSkip has no data ──
          // Only do this if AniSkip didn't already load intervals.
          if (_skipIntervals.isEmpty && chaptersList.length >= 2) {
            final List<SkipInterval> intervals = [];
            for (var i = 0; i < chaptersList.length; i++) {
              final ch = chaptersList[i];
              final title = (ch.title ?? '').toLowerCase();
              String? type;
              if (title.contains('opening') || title == 'op') {
                type = 'op';
              } else if (title.contains('ending') || title == 'ed') {
                type = 'ed';
              } else if (title.contains('recap') || title.contains('preview')) {
                type = 'recap';
              }
              if (type != null) {
                // The interval runs from this chapter's start to the next chapter's start.
                final start = ch.time.inSeconds.toDouble();
                final end = i + 1 < chaptersList.length
                    ? chaptersList[i + 1].time.inSeconds.toDouble()
                    : start + 90; // fallback: 90s if it's the last chapter
                intervals.add(SkipInterval(startTime: start, endTime: end, type: type));
                print('[Chapters] Skip interval from chapter "${ch.title}": ${start}s → ${end}s ($type)');
              }
            }
            if (intervals.isNotEmpty && mounted) {
              setState(() => _skipIntervals = intervals);
            }
          }
        }
      }
    } catch (e) {
      print('[Player] Error loading chapters from MPV: $e');
    }
  }

  bool _shouldShowSkipButton() {
    final secs = _position.inSeconds.toDouble();
    for (final interval in _skipIntervals) {
      if (secs >= interval.startTime && secs <= interval.endTime) {
        return true;
      }
    }
    return false;
  }

  String _skipButtonLabel() {
    final secs = _position.inSeconds.toDouble();
    for (final interval in _skipIntervals) {
      if (secs >= interval.startTime && secs <= interval.endTime) {
        if (interval.type == 'op') return 'Skip Opening';
        if (interval.type == 'ed') return 'Skip Ending';
        if (interval.type == 'recap') return 'Skip Recap';
        return 'Skip Segment';
      }
    }
    return 'Skip';
  }

  void _skipToNextSegment() {
    final secs = _position.inSeconds.toDouble();
    for (final interval in _skipIntervals) {
      if (secs >= interval.startTime && secs <= interval.endTime) {
        _player.seek(Duration(seconds: interval.endTime.round()));
        break;
      }
    }
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

  void _goNextEpisode() async {
    // ── CRITICAL: abort + drain + pause BEFORE navigating ───────────────────────
    // GoRouter.pushReplacement calls dispose() on this screen synchronously.
    // dispose() cannot await, so if there are active segment downloads
    // when _player.dispose() runs, ntdll.dll crashes (write to freed ring buffer).
    // We must stop all downloads and pause the player BEFORE navigating.
    _watchdogTimer?.cancel();
    _bufferPollTimer?.cancel();
    _nextEpTimer?.cancel();
    _progressTimer?.cancel();
    for (final s in _subs) { try { s.cancel(); } catch (_) {} }
    _subs.clear();
    // Abort proxy downloads
    try {
      await Dio().get('${AppSettings.instance.backendUrl}/proxy/abort-all')
          .timeout(const Duration(milliseconds: 600));
    } catch (_) {}
    // Drain demuxer
    try {
      final native = _player.platform as dynamic;
      native.setProperty('demuxer-max-bytes', '1');
      native.setProperty('cache', 'no');
    } catch (_) {}
    // Pause player
    try { await _player.pause(); } catch (_) {}
    // Wait for ring-buffer writes to settle
    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;

    final nextEp = (int.tryParse(widget.episodeNumber) ?? 0) + 1;
    if (nextEp <= 0) return;
    final preloaded = _preloadedNextSrc;
    final season = widget.seasonNumber;
    final currentProv = preloaded?.provider ?? widget.preloadedProvider ?? _currentSource?.provider;
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
      'preloadedProvider': currentProv,
      'showUrl': widget.showUrl,
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

  void _debouncedSeek(Duration target) {
    _targetSeekPosition = target;
    setState(() => _position = target);

    _seekDebounceTimer?.cancel();
    _seekDebounceTimer = Timer(const Duration(milliseconds: 200), () async {
      // Don't seek if the player is in the middle of a source switch or open().
      // Calling seek() while libmpv is initialising a new demuxer crashes on Windows.
      if (_isSwitching || _isPlayerBusy) {
        if (mounted) setState(() { _targetSeekPosition = null; });
        return;
      }
      final pos = _targetSeekPosition;
      if (pos != null) {
        try {
          await _player.seek(pos);
        } catch (e) {
          print('[Player] Debounced seek error: $e');
        }
        if (mounted) {
          setState(() {
            _targetSeekPosition = null;
          });
        }
      }
    });
  }

  void _seek(int secs) {
    final current = _targetSeekPosition ?? _position;
    var target = current + Duration(seconds: secs);
    if (target < Duration.zero) target = Duration.zero;
    if (target > _duration) target = _duration;

    _debouncedSeek(target);

    // Flash animation
    _seekFlashTimer?.cancel();
    setState(() => _seekFlash = secs > 0 ? 1 : -1);
    _seekFlashTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekFlash = 0);
    });
  }

  void _showCastDialog() {
    final castService = CastService();
    castService.startDiscovery();

    showDialog(
      context: context,
      builder: (ctx) {
        return StreamBuilder<List<CastDevice>>(
          stream: castService.devices,
          initialData: castService.currentDevices,
          builder: (context, snapshot) {
            final devices = snapshot.data ?? [];
            return AlertDialog(
              backgroundColor: AppColors.surface,
              title: Row(
                children: [
                  const Icon(Icons.cast_rounded, color: AppColors.accent),
                  const SizedBox(width: 10),
                  Text('Cast to Device', style: GoogleFonts.inter(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              content: SizedBox(
                width: 300,
                child: devices.isEmpty
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: 16),
                          const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
                          ),
                          const SizedBox(height: 16),
                          Text('Searching for local devices...', style: GoogleFonts.inter(color: Colors.white70, fontSize: 13)),
                          const SizedBox(height: 8),
                        ],
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: devices.length,
                        itemBuilder: (context, index) {
                          final dev = devices[index];
                          return ListTile(
                            leading: const Icon(Icons.tv_rounded, color: Colors.white54),
                            title: Text(dev.name, style: GoogleFonts.inter(color: Colors.white, fontSize: 14)),
                            onTap: () {
                              Navigator.pop(context);
                              _startCasting(dev);
                            },
                          );
                        },
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    castService.stopDiscovery();
                    Navigator.pop(ctx);
                  },
                  child: Text('Cancel', style: GoogleFonts.inter(color: AppColors.accent)),
                ),
              ],
            );
          },
        );
      },
    ).then((_) {
      castService.stopDiscovery();
    });
  }

  void _startCasting(CastDevice dev) async {
    if (_currentSource == null) return;
    _player.pause();
    setState(() {
      _activeCastDevice = dev;
    });

    final success = await CastService().castVideo(
      dev,
      _currentSource!.url,
      title: widget.title,
    );

    if (!success) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to cast to device.')),
        );
        setState(() {
          _activeCastDevice = null;
        });
        _player.play();
      }
    }
  }

  void _stopCasting() async {
    if (_activeCastDevice != null) {
      await CastService().stopVideo(_activeCastDevice!);
      if (mounted) {
        setState(() {
          _activeCastDevice = null;
        });
        _player.play();
      }
    }
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
      final currentProv = widget.preloadedProvider ?? _currentSource?.provider;

      final src = await StreamResolver.instance.resolveFirstSource(
        title: widget.title, mediaType: widget.mediaType,
        year: widget.year, seasonNumber: widget.seasonNumber,
        episodeNumber: '$nextEpNum',
        preferredQuality: prefLang,
        isAnime: widget.isAnime,
        provider: currentProv,
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
        _subSize = prefs.getString('subSize') ?? '55';
        _subColor = prefs.getString('subColor') ?? '#FFFFFFFF';
        _subBgColor = prefs.getString('subBgColor') ?? '#80000000';
      });
      Future.delayed(const Duration(milliseconds: 200), _applySubtitleStyle);
    } catch (_) {}
  }

  Future<void> _applySubtitleStyle() async {
    try {
      final native = _player.platform as dynamic;
      await native.setProperty('sub-font', 'sans-serif');
      await native.setProperty('sub-font-size', _subSize);
      await native.setProperty('sub-color', _subColor);
      await native.setProperty('sub-back-color', _subBgColor);
      // 'yes' respects embedded ASS styling but applies our overrides on top.
      // 'force' caused a second plain-text render pass → doubled subtitles.
      await native.setProperty('sub-ass-override', 'yes');
      await native.setProperty('sub-border-size', '2');
      await native.setProperty('sub-border-color', '#FF000000'); // black outline
      await native.setProperty('sub-shadow-offset', '0'); // no shadow offset
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

          // Source switching happens silently — no overlay shown

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

          // ── Skip Intro Button ──────────────────────────────────────────────
          // Movies: never show skip button (no intros/outros).
          // Series (anime + non-anime): only show when AniSkip data is loaded.
          // No hardcoded fallbacks — skip button only appears with real timestamps.
          if (_loadState == _LoadState.playing &&
              widget.mediaType == 'tv' &&
              _shouldShowSkipButton())
            Positioned(
              bottom: 100, right: 24,
              child: GestureDetector(
                onTap: _skipToNextSegment,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.80),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.white38, width: 0.8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.skip_next_rounded, color: Colors.white, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          _skipButtonLabel(),
                          style: GoogleFonts.inter(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // ── DLNA Casting Overlay ───────────────────────────────────────────
          if (_activeCastDevice != null)
            Positioned.fill(
              child: Container(
                color: Colors.black,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.cast_connected_rounded, size: 80, color: AppColors.accent),
                      const SizedBox(height: 24),
                      Text(
                        'Casting to ${_activeCastDevice!.name}',
                        style: GoogleFonts.inter(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        widget.title,
                        style: GoogleFonts.inter(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 40),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                        ),
                        onPressed: _stopCasting,
                        icon: const Icon(Icons.cast_connected_rounded),
                        label: Text('Stop Casting', style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
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
          onBack: () => _safeNavigateBack(),
        ),
      _LoadState.error => _ErrorOverlay(error: _error ?? 'Unknown error',
          onRetry: _resolveAndPlay, onBack: () => _safeNavigateBack()),
      _LoadState.playing => Video(
          key: ValueKey(_playerGeneration), // remounts when player is rebuilt
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
            _CtrlBtn(icon: Icons.arrow_back_rounded, onTap: () => _safeNavigateBack()),
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
            const SizedBox(width: 6),
            if (_chapters.isNotEmpty) ...[
              _PanelBtn(
                icon: Icons.bookmarks_rounded,
                label: 'Chapters (${_chapters.length})',
                active: _panel == _PanelTab.chapters,
                onTap: () => _togglePanel(_PanelTab.chapters),
              ),
              const SizedBox(width: 6),
            ],
            // Cast button
            _PanelBtn(
              icon: _activeCastDevice != null ? Icons.cast_connected_rounded : Icons.cast_rounded,
              label: _activeCastDevice != null ? 'Casting' : 'Cast',
              active: false,
              onTap: _showCastDialog,
            ),
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
                setState(() => _isDragging = false);
                _debouncedSeek(Duration(milliseconds: ms));
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
            subSize: _subSize,
            subColor: _subColor,
            subBgColor: _subBgColor,
            onVideoTrack: (t) { _player.setVideoTrack(t); setState(() => _activeVideo = t); },
            onAudioTrack: (t) { _player.setAudioTrack(t); setState(() => _activeAudio = t); },
            onSubtitleTrack: (t) async {
              await _player.setSubtitleTrack(t);
              await _applySubtitleStyle();
              setState(() => _activeSubtitle = t);
            },
            onTabChange: (t) => setState(() => _panel = t),
            onSetHlsBitrate: _setHlsBitrate,
            onSetAspectRatio: _setAspectRatio,
            onSetPauseOnFocusLoss: _savePauseOnFocusLoss,
            onSetSubSize: (val) async {
              setState(() => _subSize = val);
              await _applySubtitleStyle();
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('subSize', val);
            },
            onSetSubColor: (val) async {
              setState(() => _subColor = val);
              await _applySubtitleStyle();
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('subColor', val);
            },
            onSetSubBgColor: (val) async {
              setState(() => _subBgColor = val);
              await _applySubtitleStyle();
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('subBgColor', val);
            },
            onClose: () => setState(() => _panel = _PanelTab.none),
          ),
        _PanelTab.chapters => _ChaptersPanel(
            chapters: _chapters,
            position: _position,
            onSelect: (time) {
              _player.seek(time);
              setState(() => _panel = _PanelTab.none);
            },
            onClose: () => setState(() => _panel = _PanelTab.none),
          ),
        _PanelTab.none => const SizedBox.shrink(),
      },
    );
  }

  /// Load all seasons for the Episodes panel dropdown — uses TMDB
  Future<void> _loadAllSeasons() async {
    if (widget.mediaType != 'tv') return;
    final tmdbId = int.tryParse(widget.tmdbId) ?? 0;
    if (tmdbId <= 0) return;
    try {
      final detail = await TmdbApi.instance.getDetails(tmdbId, widget.mediaType);
      if (mounted && detail.seasons.isNotEmpty) {
        setState(() => _allSeasons = detail.seasons);
      }
    } catch (_) {}
  }

  /// Asynchronously fetch backdrop image and logo URL if missing — uses TMDB
  Future<void> _fetchMediaDetailsIfNeeded() async {
    final needBack = _backdropUrl == null || _backdropUrl!.isEmpty;
    final needLogo = _logoUrl == null || _logoUrl!.isEmpty;
    if (!needBack && !needLogo) return;
    final tmdbId = int.tryParse(widget.tmdbId) ?? 0;
    if (tmdbId <= 0) return;
    try {
      final detail = await TmdbApi.instance.getDetails(tmdbId, widget.mediaType);
      if (mounted) {
        setState(() {
          if (needBack && detail.backdropUrl.isNotEmpty) _backdropUrl = detail.backdropUrl;
          if (needLogo && detail.logoUrl.isNotEmpty) _logoUrl = detail.logoUrl;
        });
      }
    } catch (_) {}
  }

  // (unused — kept for compatibility)

  /// Load TMDB season episodes for the Episodes panel
  Future<void> _loadTmdbEpisodes({int? seasonOverride}) async {
    if (_tmdbEpisodesLoading) return;
    final tmdbId = int.tryParse(widget.tmdbId) ?? 0;
    final season = seasonOverride ?? _selectedSeasonNumber;
    if (tmdbId <= 0) { if (mounted) setState(() => _tmdbEpisodesLoading = false); return; }
    setState(() { _tmdbEpisodesLoading = true; _tmdbEpisodes = []; });
    try {
      final eps = await TmdbApi.instance.getSeasonEpisodes(tmdbId, season);
      if (mounted) setState(() { _tmdbEpisodes = eps; _tmdbEpisodesLoading = false; });
    } catch (e) {
      debugPrint('[Player] _loadTmdbEpisodes failed: $e');
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      try {
        final eps = await TmdbApi.instance.getSeasonEpisodes(tmdbId, season);
        if (mounted) setState(() { _tmdbEpisodes = eps; _tmdbEpisodesLoading = false; });
      } catch (_) {
        if (mounted) setState(() => _tmdbEpisodesLoading = false);
      }
    }
  }

  /// Navigate to a different TMDB episode.
  /// Drains the DASH demuxer before pushReplacement so dispose() is safe.
  Future<void> _playTmdbEpisode(TmdbEpisode ep) async {
    if (!mounted) return;
    await _safeSwitchPlayer();
    if (!mounted) return;
    final currentProv = widget.preloadedProvider ?? _currentSource?.provider;
    GoRouter.of(context).pushReplacement('/player', extra: <String, dynamic>{
      'tmdbId': widget.tmdbId,
      'mediaType': widget.mediaType,
      'title': widget.title,
      'year': widget.year,
      'seasonNumber': '${ep.seasonNumber}',
      'episodeNumber': '${ep.episodeNumber}',
      'episodeTitle': ep.name,
      'isAnime': widget.isAnime,
      'backdrop': _backdropUrl,
      'logo': _logoUrl,
      'preloadedProvider': currentProv,
      'showUrl': widget.showUrl,
    });
  }

  /// Safe back navigation — drains DASH demuxer before popping route.
  /// Without this, dispose() fires mid-write → ntdll.dll crash.
  Future<void> _safeNavigateBack() async {
    if (!mounted) return;
    // Abort proxy downloads + drain demuxer BEFORE pop() triggers dispose().
    // dispose() is synchronous and cannot await, so we must stop downloads here.
    _watchdogTimer?.cancel();
    _bufferPollTimer?.cancel();
    _progressTimer?.cancel();
    try {
      await Dio().get('${AppSettings.instance.backendUrl}/proxy/abort-all')
          .timeout(const Duration(milliseconds: 600));
    } catch (_) {}
    try {
      final native = _player.platform as dynamic;
      native.setProperty('demuxer-max-bytes', '1');
      native.setProperty('cache', 'no');
    } catch (_) {}
    try { await _player.pause(); } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    GoRouter.of(context).pop();
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
          _safeNavigateBack(); // abort + drain before pop
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
  final String subSize;
  final String subColor;
  final String subBgColor;
  final void Function(VideoTrack) onVideoTrack;
  final void Function(AudioTrack) onAudioTrack;
  final void Function(SubtitleTrack) onSubtitleTrack;
  final void Function(_PanelTab) onTabChange;
  final void Function(int) onSetHlsBitrate;
  final void Function(String) onSetAspectRatio;
  final void Function(bool) onSetPauseOnFocusLoss;
  final void Function(String) onSetSubSize;
  final void Function(String) onSetSubColor;
  final void Function(String) onSetSubBgColor;
  final VoidCallback onClose;

  const _SettingsPanel({
    required this.tracks, required this.activeVideo, required this.activeAudio,
    required this.activeSubtitle, required this.currentSource, required this.activeTab,
    required this.hlsVariants, required this.activeVariantBandwidth,
    required this.aspectRatio, required this.pauseOnFocusLoss,
    required this.subSize, required this.subColor, required this.subBgColor,
    required this.onVideoTrack, required this.onAudioTrack,
    required this.onSubtitleTrack, required this.onTabChange,
    required this.onSetHlsBitrate, required this.onSetAspectRatio,
    required this.onSetPauseOnFocusLoss,
    required this.onSetSubSize, required this.onSetSubColor, required this.onSetSubBgColor,
    required this.onClose,
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
        ]),
      ),
      Expanded(child: switch(activeTab) {
        _PanelTab.quality   => _buildQuality(),
        _PanelTab.audio     => _buildAudio(),
        _PanelTab.subtitles => _buildSubtitles(),
        _                   => const SizedBox.shrink(),
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

    List<Widget> extTiles = [];
    if (currentSource?.subtitleUrl.isNotEmpty == true) {
      final subUrl = currentSource!.subtitleUrl.trim();
      if (subUrl.startsWith('[')) {
        try {
          final List<dynamic> list = jsonDecode(subUrl);
          for (final item in list) {
            final url = item['url']?.toString() ?? '';
            final lang = item['lang']?.toString() ?? 'Unknown';
            final code = item['code']?.toString() ?? 'en';
            if (url.isNotEmpty) {
              final track = SubtitleTrack.uri(url, title: lang, language: code);
              extTiles.add(_TrackTile(
                label: '$lang (External)',
                sublabel: 'VTT from provider',
                badge: 'CC',
                isActive: activeSubtitle.id == url || activeSubtitle.title == lang,
                onTap: () => onSubtitleTrack(track),
              ));
            }
          }
        } catch (_) {}
      } else {
        extTiles.add(_TrackTile(
          label: 'English (External)', sublabel: 'VTT from provider', badge: 'CC',
          isActive: activeSubtitle != SubtitleTrack.no() && activeSubtitle != SubtitleTrack.auto(),
          onTap: () => onSubtitleTrack(SubtitleTrack.uri(
            currentSource!.subtitleUrl, title: 'English', language: 'en')),
        ));
      }
    }

    return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
      _SectionLabel('SUBTITLES'),
      _TrackTile(label: 'Off', sublabel: 'No subtitles',
          isActive: activeSubtitle == SubtitleTrack.no(),
          onTap: () => onSubtitleTrack(SubtitleTrack.no())),
      ...extTiles,
      ...subTracks.map((t) {
        final lang = t.language?.isNotEmpty == true ? t.language! : '';
        final title = t.title?.isNotEmpty == true ? t.title! : '';
        final label = [title, lang].where((s) => s.isNotEmpty).join(' — ');
        // Compare by id (string) not object equality — track objects are rebuilt on each setState
        final isActive = activeSubtitle.id != null && t.id != null
            ? activeSubtitle.id == t.id
            : activeSubtitle == t;
        return _TrackTile(
          label: label.isNotEmpty ? label : 'Track ${t.id}',
          isActive: isActive,
          onTap: () => onSubtitleTrack(t),
        );
      }),
      if (subTracks.isEmpty && extTiles.isEmpty)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('No subtitles found for this source.',
              style: GoogleFonts.inter(color: Colors.white38, fontSize: 12)),
        ),
      const Divider(color: Colors.white10, height: 24),
      _SectionLabel('SUBTITLE SIZE'),
      _buildStyleRow(
        options: {'Small': '35', 'Medium': '55', 'Large': '70', 'Extra Large': '90'},
        currentValue: subSize,
        onSelect: onSetSubSize,
      ),
      const SizedBox(height: 12),
      _SectionLabel('SUBTITLE COLOR'),
      _buildStyleRow(
        options: {'White': '#FFFFFFFF', 'Yellow': '#FFFFFF00', 'Cyan': '#FF00FFFF', 'Green': '#FF00FF00'},
        currentValue: subColor,
        onSelect: onSetSubColor,
      ),
      const SizedBox(height: 12),
      _SectionLabel('BACKGROUND BOX OPACITY'),
      _buildStyleRow(
        options: {'None': '#00000000', 'Low': '#40000000', 'Medium': '#80000000', 'High': '#C0000000'},
        currentValue: subBgColor,
        onSelect: onSetSubBgColor,
      ),
      const SizedBox(height: 24),
    ]);
  }

  Widget _buildStyleRow({
    required Map<String, String> options,
    required String currentValue,
    required void Function(String) onSelect,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: options.entries.map((entry) {
          final isSelected = currentValue == entry.value;
          return _StyleChip(
            label: entry.key,
            isSelected: isSelected,
            onTap: () => onSelect(entry.value),
          );
        }).toList(),
      ),
    );
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

            const SizedBox(height: 40),

            // Animated three-dot loader — no text, clean
            _AnimatedDots(controller: _dotCtrl),
          ]),  // closes Column children + Column
        ),     // closes Center
    ]);        // closes Stack
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

// ─── Subtitle Style Chip ──────────────────────────────────────────────────────

class _StyleChip extends StatefulWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  const _StyleChip({required this.label, required this.isSelected, required this.onTap});

  @override
  State<_StyleChip> createState() => _StyleChipState();
}

class _StyleChipState extends State<_StyleChip> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppColors.accent
                : (_h ? AppColors.surfaceHigh : AppColors.surface),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: widget.isSelected ? AppColors.accent : AppColors.cardBorder,
              width: 0.5,
            ),
          ),
          child: Text(
            widget.label,
            style: GoogleFonts.inter(
              color: widget.isSelected ? Colors.white : AppColors.secondary,
              fontSize: 11,
              fontWeight: widget.isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Chapters Panel ─────────────────────────────────────────────────────────

class _ChaptersPanel extends StatelessWidget {
  final List<MediaChapter> chapters;
  final Duration position;
  final void Function(Duration) onSelect;
  final VoidCallback onClose;

  const _ChaptersPanel({
    required this.chapters,
    required this.position,
    required this.onSelect,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _PanelHeader(icon: Icons.bookmarks_rounded, title: 'Chapters', onClose: onClose),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: chapters.length,
            itemBuilder: (context, index) {
              final c = chapters[index];
              final timeStr = _fmt(c.time);
              final isCurrent = index == chapters.length - 1
                  ? position >= c.time
                  : (position >= c.time && position < chapters[index + 1].time);

              return ListTile(
                title: Text(
                  c.title ?? 'Chapter ${index + 1}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    color: isCurrent ? AppColors.accent : Colors.white70,
                    fontSize: 13,
                    fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                subtitle: Text(
                  timeStr,
                  style: GoogleFonts.inter(
                    color: isCurrent ? AppColors.accent.withOpacity(0.7) : Colors.white38,
                    fontSize: 11,
                  ),
                ),
                trailing: isCurrent ? const Icon(Icons.play_arrow_rounded, color: AppColors.accent, size: 18) : null,
                onTap: () => onSelect(c.time),
              );
            },
          ),
        ),
      ],
    );
  }

  String _fmt(Duration d) {
    if (d.inHours > 0) {
      final h = d.inHours;
      final m = d.inMinutes % 60;
      final s = d.inSeconds % 60;
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    } else {
      final m = d.inMinutes;
      final s = d.inSeconds % 60;
      return '$m:${s.toString().padLeft(2, '0')}';
    }
  }
}

// ─── Skip Interval Model ──────────────────────────────────────────────────────

class SkipInterval {
  final double startTime;
  final double endTime;
  final String type; // "op" | "ed" | "recap"

  SkipInterval({
    required this.startTime,
    required this.endTime,
    required this.type,
  });
}

class MediaChapter {
  final String? title;
  final Duration time;

  MediaChapter({
    required this.title,
    required this.time,
  });
}


