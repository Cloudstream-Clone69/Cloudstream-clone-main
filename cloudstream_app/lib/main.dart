// lib/main.dart

import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'dart:ui';
import 'shared/theme/app_theme.dart';
import 'shared/widgets/sidebar.dart';

import 'core/constants.dart';
import 'features/splash/splash_screen.dart';
import 'features/home/home_screen.dart';
import 'features/home/home_provider.dart';
import 'features/sports/sports_screen.dart';
import 'features/search/search_screen.dart';
import 'features/search/search_provider.dart';
import 'features/detail/detail_screen.dart';
import 'features/player/player_screen.dart';
import 'features/library/library_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/splash/maintenance_screen.dart';
import 'features/splash/update_screen.dart';
import 'core/services/update_service.dart';
import 'core/services/app_settings.dart';
import 'core/services/download_service.dart';
import 'core/api/dns_over_https.dart';

import 'core/services/local_backend.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  // Start local backend server automatically
  await LocalBackend.start();
  // Fix SSL HandshakeException on Windows (TLS negotiation issues with some servers)
  HttpOverrides.global = _TrustAllCerts();
  MediaKit.ensureInitialized();
  // Init app settings (loads prefs + applies DNS to backend)
  await AppSettings.instance.init();
  // Init download manager (loads active tasks and resumes speed calculations)
  await DownloadService.instance.init();
  // Pre-resolve TMDB hostnames via Cloudflare DoH (bypasses Jio DNS block)
  await DnsOverHttps.prefetch();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => HomeProvider()),
        ChangeNotifierProvider(create: (_) => SearchProvider()),
        ChangeNotifierProvider.value(value: AppSettings.instance),
      ],
      child: const CloudStreamApp(),
    ),
  );
}

class _TrustAllCerts extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (_, __, ___) => true;
  }
}

// ─── Router ───────────────────────────────────────────────────────────────────

final _router = GoRouter(
  initialLocation: '/splash',
  routes: [
    // Splash / welcome screen (entry point)
    GoRoute(
      path: '/splash',
      pageBuilder: (ctx, state) => NoTransitionPage<void>(
        key: state.pageKey,
        child: const SplashScreen(),
      ),
    ),
    GoRoute(
      path: '/maintenance',
      pageBuilder: (ctx, state) {
        final message = state.extra as String? ?? 'System maintenance in progress.';
        return NoTransitionPage<void>(
          key: state.pageKey,
          child: MaintenanceScreen(message: message),
        );
      },
    ),
    GoRoute(
      path: '/update',
      pageBuilder: (ctx, state) {
        final extra = state.extra as Map<String, dynamic>?;
        return _slideUpPage(
          state,
          UpdateScreen(
            info: extra?['info'] as UpdateInfo,
            isMandatory: extra?['mandatory'] as bool? ?? false,
          ),
        );
      },
    ),

    // Shell route — wraps sidebar around Home / Search / Library / Settings / Detail
    ShellRoute(
      builder: (ctx, state, child) => AppSidebar(child: child),
      routes: [
        GoRoute(
          path: '/',
          pageBuilder: (ctx, state) => _noTransitionPage(state, const HomeScreen()),
        ),
        GoRoute(
          path: '/sports',
          pageBuilder: (ctx, state) => _noTransitionPage(state, const SportsScreen()),
        ),
        GoRoute(
          path: '/search',
          pageBuilder: (ctx, state) => _noTransitionPage(state, const SearchScreen()),
        ),
        GoRoute(
          path: '/library',
          pageBuilder: (ctx, state) => _noTransitionPage(state, const LibraryScreen(initialTabIndex: 0)),
        ),
        GoRoute(
          path: '/downloads',
          pageBuilder: (ctx, state) => _noTransitionPage(state, const LibraryScreen(initialTabIndex: 2)),
        ),
        GoRoute(
          path: '/settings',
          pageBuilder: (ctx, state) {
            final tab = state.uri.queryParameters['tab'];
            return _noTransitionPage(state, SettingsScreen(initialTab: tab));
          },
        ),
        GoRoute(
          path: '/detail',
          pageBuilder: (ctx, state) {
            final extra = state.extra as Map<String, dynamic>;
            return _slideUpPage(
              state,
              DetailScreen(
                id:          extra['id']          as int?,
                mediaType:   extra['mediaType']   as String?,
                title:       extra['title']       as String? ?? '',
                posterUrl:   extra['poster']      as String? ?? '',
                backdropUrl: extra['backdrop']    as String? ?? '',
                overview:    extra['overview']    as String? ?? '',
                releaseDate: extra['releaseDate'] as String? ?? '',
                provider:    extra['provider']    as String?,
                providerUrl: extra['providerUrl'] as String?,
              ),
            );
          },
        ),
      ],
    ),

    // Full-screen routes (no sidebar)
    GoRoute(
      path: '/player',
      pageBuilder: (ctx, state) {
        final extra = state.extra as Map<String, dynamic>;
        // Build a stable key that changes whenever the target episode changes.
        // This forces GoRouter to dispose the old PlayerScreen and create a fresh
        // one when the user navigates from one episode to another while already
        // on the /player route (pushReplacement would otherwise reuse state).
        final navId    = extra['_navId']?.toString() ?? '';
        final season   = extra['seasonNumber']?.toString() ?? '';
        final episode  = extra['episodeNumber']?.toString() ?? '';
        final tmdb     = extra['tmdbId']?.toString() ?? '';
        final uniqueKey = ValueKey('player_${tmdb}_S${season}E${episode}_$navId');
        return _slideUpPage(
          state,
          PlayerScreen(
            key: uniqueKey,
            tmdbId:        extra['tmdbId']        as String? ?? '',
            mediaType:     extra['mediaType']     as String? ?? '',
            title:         extra['title']         as String? ?? '',
            year:          extra['year']          as String? ?? '',
            seasonNumber:  extra['seasonNumber']  as String? ?? '',
            episodeNumber: extra['episodeNumber'] as String? ?? '',
            episodeTitle:  extra['episodeTitle']  as String? ?? '',
            isAnime:       extra['isAnime']       as bool?   ?? false,
            preloadedUrl:  extra['preloadedUrl']  as String?,
            preloadedProvider: extra['preloadedProvider'] as String?,
            backdropUrl:   extra['backdrop']      as String?,
            logoUrl:       extra['logo']          as String?,
            episodeUrl:    extra['episodeUrl']    as String?,
            showUrl:       extra['showUrl']       as String?,
            preloadedRefs: extra['preloadedRefs'] as List<Map<String, dynamic>>?,
            preloadedEpisodes: extra['preloadedEpisodes'] as List<Map<String, dynamic>>?,
          ),
        );
      },
    ),

  ],
);

Page<void> _noTransitionPage(GoRouterState state, Widget child) {
  return NoTransitionPage<void>(key: state.pageKey, child: child);
}

Page<void> _slideUpPage(GoRouterState state, Widget child) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: const Duration(milliseconds: 280),
    transitionsBuilder: (ctx, animation, secondary, child) {
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.04),
          end: Offset.zero,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        )),
        child: FadeTransition(opacity: animation, child: child),
      );
    },
  );
}

// ─── App ──────────────────────────────────────────────────────────────────────

class AppScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}

class CloudStreamApp extends StatefulWidget {
  const CloudStreamApp({super.key});

  @override
  State<CloudStreamApp> createState() => _CloudStreamAppState();
}

class _CloudStreamAppState extends State<CloudStreamApp> {
  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    // Periodically check for updates/maintenance every 5 minutes in the background
    _updateTimer = Timer.periodic(const Duration(minutes: 5), (_) => _checkStatus());
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkStatus() async {
    try {
      final info = await UpdateService.instance.checkUpdate();
      if (info != null) {
        // 1. Instantly block if maintenance mode is enabled
        if (info.maintenance) {
          _router.go('/maintenance', extra: info.maintenanceMessage);
          return;
        }

        // 2. Instantly force update if a mandatory update is available
        final updateAvailable = UpdateService.instance.isUpdateAvailable(kAppVersion, info.latestVersion);
        if (updateAvailable && info.mandatory) {
          _router.go('/update', extra: {
            'info': info,
            'mandatory': true,
          });
        }
      }
    } catch (e) {
      print('[UpdateTimer] Periodic status check error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'CloudStream',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      routerConfig: _router,
      scrollBehavior: AppScrollBehavior(),
    );
  }
}
