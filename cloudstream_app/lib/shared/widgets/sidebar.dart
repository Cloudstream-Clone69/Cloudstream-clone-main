// lib/shared/widgets/sidebar.dart
// Clean CloudStream sidebar - no overflow, centered items, pop-out hover

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../theme/app_theme.dart';

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final String route;
  const _NavItem({required this.icon, required this.activeIcon, required this.label, required this.route});
}

const _items = [
  _NavItem(icon: Icons.home_outlined,     activeIcon: Icons.home_rounded,     label: 'Home',      route: '/'),
  _NavItem(icon: Icons.search_rounded,    activeIcon: Icons.search_rounded,   label: 'Search',    route: '/search'),
  _NavItem(icon: Icons.folder_outlined,   activeIcon: Icons.folder_rounded,   label: 'Library',   route: '/library'),
  _NavItem(icon: Icons.download_outlined, activeIcon: Icons.download_rounded, label: 'Downloads', route: '/downloads'),
  _NavItem(icon: Icons.settings_outlined, activeIcon: Icons.settings_rounded, label: 'Settings',  route: '/settings'),
];

// Collapsed: 56px exactly, Expanded: 196px
const double _kCollapsed = 56;
const double _kExpanded  = 196;

class AppSidebar extends StatefulWidget {
  final Widget child;
  const AppSidebar({super.key, required this.child});

  @override
  State<AppSidebar> createState() => _AppSidebarState();
}

class _AppSidebarState extends State<AppSidebar> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _t; // 0..1 collapsed..expanded

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
    _t = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      // Main content with padding so it isn't under the collapsed sidebar
      Positioned.fill(
        left: _kCollapsed,
        child: widget.child,
      ),
      // Overlay Sidebar
      Positioned(
        left: 0, top: 0, bottom: 0,
        child: MouseRegion(
          onEnter: (_) => _ctrl.forward(),
          onExit:  (_) => _ctrl.reverse(),
          child: AnimatedBuilder(
            animation: _t,
            builder: (ctx, _) {
              final w = _kCollapsed + (_kExpanded - _kCollapsed) * _t.value;
              final loc = GoRouterState.of(ctx).uri.path;
              return Material(
                color: Colors.transparent,
                child: Container(
                  width: w,
                  // Clip so nothing leaks outside while animating
                  clipBehavior: Clip.hardEdge,
                  decoration: BoxDecoration(
                    color: AppColors.sidebarBg.withValues(alpha: 0.95), // Slight transparency
                    boxShadow: _t.value > 0 
                        ? [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 20)] 
                        : [],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 14),
                      // ── Avatar ──
                      Center(child: const _Avatar()),
                      const Spacer(),
                      // ── Nav items ──
                      ..._items.map((item) {
                        final active = item.route == '/'
                            ? loc == '/'
                            : loc.startsWith(item.route);
                        return _NavTile(
                          item: item,
                          active: active,
                          showLabel: _t.value > 0.45,
                          labelOpacity: ((_t.value - 0.45) / 0.55).clamp(0.0, 1.0),
                          onTap: () => ctx.go(item.route),
                        );
                      }),
                      const Spacer(),
                      // ── Logo ──
                      Center(child: _Logo()),
                      const SizedBox(height: 14),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ]);
  }
}

// ─── Avatar ───────────────────────────────────────────────────────────────────

class _Avatar extends StatefulWidget {
  const _Avatar();
  @override
  State<_Avatar> createState() => _AvatarState();
}

class _AvatarState extends State<_Avatar> {
  String? _avatarUrl;

  @override
  void initState() {
    super.initState();
    _loadAvatar();
  }

  Future<void> _loadAvatar() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _avatarUrl = prefs.getString('avatar_url');
    });
  }

  Future<void> _promptAvatarUrl() async {
    final ctrl = TextEditingController(text: _avatarUrl);
    final newUrl = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Profile Image URL', style: GoogleFonts.inter(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          style: GoogleFonts.inter(color: Colors.white),
          decoration: const InputDecoration(hintText: 'https://...'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Save')),
        ],
      ),
    );

    if (newUrl != null && newUrl.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('avatar_url', newUrl);
      setState(() => _avatarUrl = newUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _promptAvatarUrl,
      child: Container(
        width: 32, height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.surfaceHigh,
          border: Border.all(color: AppColors.cardBorder, width: 0.5),
          image: _avatarUrl != null
              ? DecorationImage(
                  image: CachedNetworkImageProvider(_avatarUrl!),
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child: _avatarUrl == null
            ? const Icon(Icons.person_outline, color: AppColors.secondary, size: 17)
            : null,
      ),
    );
  }
}

// ─── Logo ─────────────────────────────────────────────────────────────────────

class _Logo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32, height: 32,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [Color(0xFF1565C0), Color(0xFF0D47A1)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 20),
    );
  }
}

// ─── Nav Tile ─────────────────────────────────────────────────────────────────

class _NavTile extends StatefulWidget {
  final _NavItem item;
  final bool active;
  final bool showLabel;
  final double labelOpacity;
  final VoidCallback onTap;

  const _NavTile({
    required this.item,
    required this.active,
    required this.showLabel,
    required this.labelOpacity,
    required this.onTap,
  });

  @override
  State<_NavTile> createState() => _NavTileState();
}

class _NavTileState extends State<_NavTile>
    with SingleTickerProviderStateMixin {
  bool _h = false;
  late AnimationController _pop;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _pop = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 160));
    _scale = Tween<double>(begin: 1.0, end: 1.08).animate(
        CurvedAnimation(parent: _pop, curve: Curves.easeOutBack));
  }

  @override
  void dispose() { _pop.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final iconColor = widget.active
        ? Colors.white
        : (_h ? AppColors.secondary : AppColors.tertiary);

    return MouseRegion(
      onEnter: (_) { setState(() => _h = true);  _pop.forward(); },
      onExit:  (_) { setState(() => _h = false); _pop.reverse(); },
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: ScaleTransition(
          scale: _scale,
          child: Container(
            // Fixed height, full-width of sidebar
            height: 44,
            margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 10),
            color: Colors.transparent, // Remove the rectangular background
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Icon in fixed 36×36 pill ─────────────────────
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.active
                        ? AppColors.accent.withValues(alpha: 0.2)
                        : (_h ? Colors.white.withValues(alpha: 0.1) : Colors.transparent),
                  ),
                  child: Icon(
                    widget.active
                        ? widget.item.activeIcon
                        : widget.item.icon,
                    color: widget.active ? AppColors.accent : iconColor,
                    size: 20,
                  ),
                ),
                // ── Label (only when expanded) ────────────────────
                if (widget.showLabel) ...[
                  const SizedBox(width: 14), // More spacing to look cleaner
                  Expanded(
                    child: Opacity(
                      opacity: widget.labelOpacity,
                      child: Text(
                        widget.item.label,
                        style: GoogleFonts.inter(
                          color: widget.active ? AppColors.accent : iconColor,
                          fontSize: 14,
                          fontWeight: widget.active
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
