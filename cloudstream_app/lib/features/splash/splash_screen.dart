// lib/features/splash/splash_screen.dart
//
// Premium animated splash screen shown at startup while:
//   1. Backend server warms up (ping with retries)
//   2. DNS-over-HTTPS pre-resolves TMDB IPs
//   3. Home content loads completely in the background (prevents startup TMDB load errors)
//
// Navigates to home automatically once ready.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../core/api/stream_resolver.dart';
import '../../features/home/home_provider.dart';
import '../../core/api/dns_over_https.dart';
import '../../shared/theme/app_theme.dart';
import '../../core/constants.dart';
import '../../core/services/update_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // ── Animations ───────────────────────────────────────────────────────────
  late final AnimationController _logoController;
  late final AnimationController _glowController;
  late final AnimationController _shimmerController;
  late final AnimationController _fadeOutController;

  late final Animation<double> _logoScale;
  late final Animation<double> _logoOpacity;
  late final Animation<double> _glowOpacity;
  late final Animation<double> _shimmerProgress;

  String _statusText = 'Initializing secure channels…';
  bool _navigating = false;
  bool _showSpinner = false;

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _startInitSequence();
  }

  void _setupAnimations() {
    // Logo entrance scale + fade-in (sleek, slow curve like cinema intro)
    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _logoScale = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeOutCubic),
    );
    _logoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _logoController,
        curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
      ),
    );

    // Deep breathing pulse for the ambient background glow and logo breathing scale
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..repeat(reverse: true);
    _glowOpacity = Tween<double>(begin: 0.4, end: 0.85).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );

    // Shimmer/sweep metallic light effect across the logo text
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
    _shimmerProgress = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _shimmerController, curve: Curves.easeInOut),
    );

    // Smooth fade-out before entering Main Screen
    _fadeOutController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _logoController.forward();
  }

  Future<void> _startInitSequence() async {
    final stopwatch = Stopwatch()..start();

    // 0. Check updates and maintenance status
    _setStatus('Checking system status…');
    try {
      final info = await UpdateService.instance.checkUpdate();
      if (info != null) {
        if (info.maintenance) {
          if (mounted) {
            context.go('/maintenance', extra: info.maintenanceMessage);
          }
          return;
        }

        final updateAvailable = UpdateService.instance.isUpdateAvailable(kAppVersion, info.latestVersion);
        if (updateAvailable) {
          if (mounted) {
            context.go('/update', extra: {
              'info': info,
              'mandatory': info.mandatory,
            });
          }
          return;
        }
      }
    } catch (e) {
      print('[SplashScreen] System status check error: $e');
    }

    // 1. Warm up DoH immediately
    _setStatus('Syncing DNS routes…');
    await DnsOverHttps.prefetch();

    // 2. Ping backend with retry loop (supports Render cold starts up to 60s)
    _setStatus('Securing server connection…');
    bool backendReady = false;
    for (int i = 0; i < 120; i++) {
      backendReady = await StreamResolver.instance.ping();
      if (backendReady) break;
      await Future.delayed(const Duration(milliseconds: 500));
    }

    if (!backendReady) {
      _setStatus('System offline. Retrying…');
      await Future.delayed(const Duration(seconds: 2));
    }

    // Show loading spinner only if the sequence is taking long (like Prime Video)
    if (stopwatch.elapsedMilliseconds > 1200) {
      if (mounted) setState(() => _showSpinner = true);
    }

    // 3. Load the Home feed in the background so it is completely ready when we land
    if (backendReady && mounted) {
      _setStatus('Downloading libraries…');
      final homeProvider = context.read<HomeProvider>();
      
      // Request home feed load and wait for it
      await homeProvider.load();
      
      // Wait until the provider is marked as loaded
      while (homeProvider.status == HomeStatus.loading) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    // Guarantee the splash screen shows for at least 2.5 seconds for cinematic feel
    final elapsed = stopwatch.elapsedMilliseconds;
    if (elapsed < 2500) {
      await Future.delayed(Duration(milliseconds: 2500 - elapsed));
    }

    _navigate();
  }

  void _setStatus(String text) {
    if (mounted) {
      setState(() => _statusText = text);
    }
  }

  Future<void> _navigate() async {
    if (_navigating) return;
    _navigating = true;
    
    // Slow fade to black
    await _fadeOutController.forward();
    if (mounted) {
      context.go('/');
    }
  }

  @override
  void dispose() {
    _logoController.dispose();
    _glowController.dispose();
    _shimmerController.dispose();
    _fadeOutController.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 1.0, end: 0.0).animate(
        CurvedAnimation(parent: _fadeOutController, curve: Curves.easeInOutCubic),
      ),
      child: Scaffold(
        backgroundColor: Colors.black, // Dark cinematic base
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Deep red ambient backdrop (similar to Netflix intro vignette)
            _buildBackdropGlow(),

            // Floating cinematic embers
            AnimatedBuilder(
              animation: _shimmerController,
              builder: (_, __) => CustomPaint(
                painter: _EmbersPainter(_shimmerController.value),
              ),
            ),

            // Vignette overlay to darken borders
            Positioned.fill(
              child: CustomPaint(
                painter: _AmbientVignettePainter(),
              ),
            ),

            // Logo & branding container
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(flex: 12),
                _buildCinematicLogo(),
                const SizedBox(height: 32),
                _buildShimmerTitle(),
                const SizedBox(height: 12),
                _buildTagline(),
                const Spacer(flex: 10),
                _buildLoadingFooter(),
                const SizedBox(height: 64),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBackdropGlow() {
    return AnimatedBuilder(
      animation: _glowOpacity,
      builder: (_, __) => Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0.0, -0.1),
            radius: 1.3,
            colors: [
              AppColors.accent.withOpacity(0.10 * _glowOpacity.value),
              Colors.black,
            ],
            stops: const [0.0, 0.85],
          ),
        ),
      ),
    );
  }

  Widget _buildCinematicLogo() {
    return AnimatedBuilder(
      animation: Listenable.merge([_logoController, _glowController]),
      builder: (_, __) {
        // Entrance scale (0.85 -> 1.0) multiplied by continuous slow breathing scale (0.98 -> 1.02)
        final pulseScale = 0.98 + (0.04 * _glowOpacity.value);
        final scale = _logoScale.value * pulseScale;
        final opacity = _logoOpacity.value;

        return Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: scale,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Massive outer radial blur glow
                Container(
                  width: 180,
                  height: 180,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.accent.withOpacity(0.24 * _glowOpacity.value),
                        blurRadius: 75,
                        spreadRadius: 25,
                      ),
                    ],
                  ),
                ),
                
                // Inner premium ring border
                Container(
                  width: 110,
                  height: 110,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppColors.accent.withOpacity(0.35 * _glowOpacity.value),
                      width: 1.5,
                    ),
                  ),
                ),

                // Solid logo disc with gradient
                Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFFFF1E27), // Bright cinema red
                        Color(0xFFB30006), // Deep ruby red
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.accent.withOpacity(0.55),
                        blurRadius: 35,
                        spreadRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 58,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildShimmerTitle() {
    return AnimatedBuilder(
      animation: Listenable.merge([_logoController, _shimmerController]),
      builder: (_, __) {
        final double value = _shimmerProgress.value;
        // Shift begin/end alignment from left to right based on the animation value
        final begin = Alignment(-2.0 + (value * 4.0), -1.0);
        final end = Alignment(-1.0 + (value * 4.0), 1.0);

        return Opacity(
          opacity: _logoOpacity.value,
          child: ShaderMask(
            shaderCallback: (bounds) {
              return LinearGradient(
                begin: begin,
                end: end,
                colors: const [
                  Colors.white38,
                  Colors.white,
                  Colors.white38,
                ],
                stops: const [0.35, 0.5, 0.65],
              ).createShader(bounds);
            },
            child: Text(
              'CLOUDSTREAM',
              style: GoogleFonts.outfit(
                fontSize: 34,
                fontWeight: FontWeight.w900,
                color: Colors.white,
                letterSpacing: 8.0,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTagline() {
    return AnimatedBuilder(
      animation: _logoOpacity,
      builder: (_, __) => Opacity(
        opacity: _logoOpacity.value * 0.45,
        child: Text(
          'YOUR PORTAL TO ENDLESS ENTERTAINMENT',
          style: GoogleFonts.inter(
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            letterSpacing: 2.0,
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingFooter() {
    return SizedBox(
      height: 48,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Elegant animated status switcher
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            child: Text(
              _statusText,
              key: ValueKey(_statusText),
              style: GoogleFonts.inter(
                fontSize: 11,
                color: Colors.white.withOpacity(0.55),
                fontWeight: FontWeight.w500,
                letterSpacing: 0.8,
              ),
            ),
          ),
          
          const SizedBox(height: 14),

          // Pulsing horizontal bar instead of progress indicator
          if (_showSpinner)
            const SizedBox(
              width: 130,
              height: 2,
              child: ClipRRect(
                borderRadius: BorderRadius.all(Radius.circular(1)),
                child: LinearProgressIndicator(
                  backgroundColor: Colors.white10,
                  valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
                ),
              ),
            )
          else
            const SizedBox(height: 2),
        ],
      ),
    );
  }
}

// ── Floating Embers Painter ─────────────────────────────────────────────────

class _EmbersPainter extends CustomPainter {
  final double progress;

  static final List<_Ember> _embers = List.generate(28, (i) {
    final rng = math.Random(i * 743);
    return _Ember(
      x: rng.nextDouble(),
      y: rng.nextDouble(),
      size: rng.nextDouble() * 3.0 + 1.0,
      speed: rng.nextDouble() * 0.12 + 0.04,
      phase: rng.nextDouble(),
    );
  });

  _EmbersPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;

    for (final e in _embers) {
      final t = (progress * e.speed + e.phase) % 1.0;
      final opacity = (math.sin(t * math.pi) * 0.35).clamp(0.0, 1.0);
      final yOffset = t * 0.35; // Slow upward drift

      final dx = e.x * size.width;
      final dy = (e.y - yOffset) * size.height;

      // Soft crimson glowing embers
      paint.color = const Color(0xFFFF2E3B).withOpacity(opacity * 0.22);
      canvas.drawCircle(Offset(dx, dy % size.height), e.size, paint);
    }
  }

  @override
  bool shouldRepaint(_EmbersPainter old) => old.progress != progress;
}

class _Ember {
  final double x;
  final double y;
  final double size;
  final double speed;
  final double phase;

  const _Ember({
    required this.x,
    required this.y,
    required this.size,
    required this.speed,
    required this.phase,
  });
}

// ── Background gradient vignette painter ────────────────────────────────────

class _AmbientVignettePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bgPaint = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 1.4,
        colors: [
          Colors.transparent,
          Colors.black.withOpacity(0.70),
          Colors.black,
        ],
        stops: const [0.0, 0.65, 1.0],
      ).createShader(rect);

    canvas.drawRect(rect, bgPaint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
