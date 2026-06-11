// lib/main.dart

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'shared/theme/app_theme.dart';
import 'shared/widgets/sidebar.dart';

import 'features/home/home_screen.dart';
import 'features/home/home_provider.dart';
import 'features/search/search_screen.dart';
import 'features/search/search_provider.dart';
import 'features/detail/detail_screen.dart';
import 'features/player/player_screen.dart';
import 'features/library/library_screen.dart';
import 'features/settings/settings_screen.dart';
import 'core/services/app_settings.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  // Fix SSL HandshakeException on Windows (TLS negotiation issues with some servers)
  HttpOverrides.global = _TrustAllCerts();
  MediaKit.ensureInitialized();
  // Init app settings (loads prefs + applies DNS to backend)
  await AppSettings.instance.init();
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
  initialLocation: '/',
  routes: [
    // Shell route — wraps sidebar around Home / Search / Library / Settings / Detail
    ShellRoute(
      builder: (ctx, state, child) => AppSidebar(child: child),
      routes: [
        GoRoute(
          path: '/',
          pageBuilder: (ctx, state) => _noTransitionPage(state, const HomeScreen()),
        ),
        GoRoute(
          path: '/search',
          pageBuilder: (ctx, state) => _noTransitionPage(state, const SearchScreen()),
        ),
        GoRoute(
          path: '/library',
          pageBuilder: (ctx, state) => _noTransitionPage(state, const LibraryScreen()),
        ),
        GoRoute(
          path: '/downloads',
          pageBuilder: (ctx, state) => _noTransitionPage(state, const LibraryScreen()),
        ),
        GoRoute(
          path: '/settings',
          pageBuilder: (ctx, state) => _noTransitionPage(state, const SettingsScreen()),
        ),
        GoRoute(
          path: '/detail',
          pageBuilder: (ctx, state) {
            final extra = state.extra as Map<String, dynamic>;
            return _slideUpPage(
              state,
              DetailScreen(
                id:          extra['id']          as int,
                simklId:     extra['simklId']     as int? ?? 0,
                mediaType:   extra['mediaType']   as String,
                title:       extra['title']       as String? ?? '',
                posterUrl:   extra['poster']      as String? ?? '',
                backdropUrl: extra['backdrop']    as String? ?? '',
                overview:    extra['overview']    as String? ?? '',
                releaseDate: extra['releaseDate'] as String? ?? '',
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
        return _slideUpPage(
          state,
          PlayerScreen(
            tmdbId:        extra['tmdbId']        as String? ?? '',
            simklId:       extra['simklId']       as int?    ?? 0,
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

class CloudStreamApp extends StatelessWidget {
  const CloudStreamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'CloudStream',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      routerConfig: _router,
    );
  }
}
