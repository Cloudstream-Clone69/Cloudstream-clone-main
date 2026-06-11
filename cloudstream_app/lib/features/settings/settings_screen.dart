// lib/features/settings/settings_screen.dart
// Full-featured Settings screen — DNS, Playback, Providers, Appearance, About

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services/app_settings.dart';
import '../../core/services/local_db.dart';
import '../../shared/theme/app_theme.dart';

// ─── Screen ───────────────────────────────────────────────────────────────────

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left sidebar tabs
          const _SideNav(),
          // Divider
          Container(width: 1, color: AppColors.cardBorder),
          // Main content area
          const Expanded(child: _SettingsContent()),
        ],
      ),
    );
  }
}

// ─── Side Nav ─────────────────────────────────────────────────────────────────

enum _Tab { dns, playback, providers, appearance, about }

class _SideNav extends StatefulWidget {
  const _SideNav();
  @override
  State<_SideNav> createState() => _SideNavState();
}

class _SideNavState extends State<_SideNav> {
  _Tab _active = _Tab.dns;

  static const _tabs = [
    (_Tab.dns,        Icons.dns_rounded,           'DNS & Network'),
    (_Tab.playback,   Icons.play_circle_outline,    'Playback'),
    (_Tab.providers,  Icons.video_library_outlined, 'Providers'),
    (_Tab.appearance, Icons.palette_outlined,       'Appearance'),
    (_Tab.about,      Icons.info_outline_rounded,   'About'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      decoration: const BoxDecoration(color: AppColors.surface),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
            child: Text('Settings',
                style: GoogleFonts.inter(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5)),
          ),
          const SizedBox(height: 8),
          // Tabs
          ..._tabs.map((t) => _NavTab(
                icon: t.$2,
                label: t.$3,
                active: _active == t.$1,
                onTap: () {
                  setState(() => _active = t.$1);
                  _SettingsContentState._tabNotifier.value = t.$1;
                },
              )),
          const Spacer(),
          // Footer version
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Text('CloudStream v1.0.0',
                style: GoogleFonts.inter(
                    color: AppColors.tertiary, fontSize: 11)),
          ),
        ],
      ),
    );
  }
}

class _NavTab extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _NavTab(
      {required this.icon,
      required this.label,
      required this.active,
      required this.onTap});
  @override
  State<_NavTab> createState() => _NavTabState();
}

class _NavTabState extends State<_NavTab> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.active
                ? AppColors.accent.withValues(alpha: 0.15)
                : _hover
                    ? Colors.white.withValues(alpha: 0.04)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.active
                  ? AppColors.accent.withValues(alpha: 0.3)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Icon(widget.icon,
                  size: 18,
                  color: widget.active ? AppColors.accent : AppColors.tertiary),
              const SizedBox(width: 10),
              Text(widget.label,
                  style: GoogleFonts.inter(
                      color: widget.active ? Colors.white : AppColors.secondary,
                      fontSize: 13,
                      fontWeight: widget.active
                          ? FontWeight.w600
                          : FontWeight.w400)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Main Content Area ────────────────────────────────────────────────────────

class _SettingsContent extends StatefulWidget {
  const _SettingsContent();
  @override
  State<_SettingsContent> createState() => _SettingsContentState();
}

class _SettingsContentState extends State<_SettingsContent> {
  static final _tabNotifier = ValueNotifier<_Tab>(_Tab.dns);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_Tab>(
      valueListenable: _tabNotifier,
      builder: (context, tab, _) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: KeyedSubtree(
            key: ValueKey(tab),
            child: switch (tab) {
              _Tab.dns        => const _DnsSection(),
              _Tab.playback   => const _PlaybackSection(),
              _Tab.providers  => const _ProvidersSection(),
              _Tab.appearance => const _AppearanceSection(),
              _Tab.about      => const _AboutSection(),
            },
          ),
        );
      },
    );
  }
}

// ─── Shared Widgets ───────────────────────────────────────────────────────────

class _SectionScroll extends StatelessWidget {
  final List<Widget> children;
  const _SectionScroll({required this.children});
  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(32, 32, 32, 32),
        children: children,
      );
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final String? subtitle;
  const _SectionTitle(this.text, {this.subtitle});
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text,
              style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5)),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!,
                style: GoogleFonts.inter(
                    color: AppColors.tertiary, fontSize: 13)),
          ],
          const SizedBox(height: 24),
        ],
      );
}

class _GroupLabel extends StatelessWidget {
  final String text;
  const _GroupLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(text.toUpperCase(),
            style: GoogleFonts.inter(
                color: AppColors.tertiary,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2)),
      );
}

class _Card extends StatelessWidget {
  final List<Widget> children;
  const _Card({required this.children});
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.cardBorder, width: 0.5),
        ),
        child: Column(
          children: List.generate(children.length, (i) {
            if (i < children.length - 1) {
              return Column(children: [
                children[i],
                Divider(
                    height: 1,
                    thickness: 0.5,
                    color: AppColors.cardBorder,
                    indent: 48),
              ]);
            }
            return children[i];
          }),
        ),
      );
}

class _ToggleTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Color? iconColor;

  const _ToggleTile({
    required this.icon,
    required this.label,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: (iconColor ?? AppColors.tertiary).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon,
                  size: 16, color: iconColor ?? AppColors.secondary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: GoogleFonts.inter(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500)),
                  if (subtitle != null)
                    Text(subtitle!,
                        style: GoogleFonts.inter(
                            color: AppColors.tertiary, fontSize: 11)),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeColor: AppColors.accent,
              thumbColor: WidgetStateProperty.all(Colors.white),
            ),
          ],
        ),
      );
}

class _InfoTile extends StatefulWidget {
  final IconData icon;
  final String label;
  final String value;
  final String? subtitle;
  final VoidCallback? onTap;
  final Color? iconColor;
  final Widget? trailing;

  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
    this.subtitle,
    this.onTap,
    this.iconColor,
    this.trailing,
  });

  @override
  State<_InfoTile> createState() => _InfoTileState();
}

class _InfoTileState extends State<_InfoTile> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor:
            widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            color: _hover && widget.onTap != null
                ? Colors.white.withValues(alpha: 0.03)
                : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: (widget.iconColor ?? AppColors.tertiary)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(widget.icon,
                      size: 16,
                      color: widget.iconColor ?? AppColors.secondary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.label,
                          style: GoogleFonts.inter(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500)),
                      if (widget.subtitle != null)
                        Text(widget.subtitle!,
                            style: GoogleFonts.inter(
                                color: AppColors.tertiary, fontSize: 11)),
                    ],
                  ),
                ),
                widget.trailing ??
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(widget.value,
                            style: GoogleFonts.inter(
                                color: AppColors.tertiary, fontSize: 12)),
                        if (widget.onTap != null) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.chevron_right_rounded,
                              color: AppColors.tertiary, size: 16),
                        ],
                      ],
                    ),
              ],
            ),
          ),
        ),
      );
}

// ─── DNS SECTION ──────────────────────────────────────────────────────────────

class _DnsSection extends StatefulWidget {
  const _DnsSection();
  @override
  State<_DnsSection> createState() => _DnsSectionState();
}

class _DnsSectionState extends State<_DnsSection> {
  bool _applying = false;
  bool? _lastResult;

  final _dns1Ctrl = TextEditingController();
  final _dns2Ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final s = AppSettings.instance;
    _dns1Ctrl.text = s.customDns1;
    _dns2Ctrl.text = s.customDns2;
    // Refresh WARP status from backend
    Future.microtask(() => s.refreshWarpStatus());
  }

  @override
  void dispose() {
    _dns1Ctrl.dispose();
    _dns2Ctrl.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final s = AppSettings.instance;
    if (s.dnsPresetId == 'custom') {
      await s.setCustomDns(_dns1Ctrl.text, _dns2Ctrl.text);
    }
    setState(() { _applying = true; _lastResult = null; });
    final ok = await s.applyDns();
    setState(() { _applying = false; _lastResult = ok; });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppSettings>(builder: (ctx, s, _) {
      final isCustom = s.dnsPresetId == 'custom';
      return _SectionScroll(children: [
        _SectionTitle('DNS & Network',
            subtitle: 'Change DNS to bypass ISP blocks and improve stream reliability'),

        // ── Status Banner ──
        if (_lastResult != null)
          _DnsStatusBanner(success: _lastResult!),

        // ── Preset Cards ──
        _GroupLabel('DNS Server'),
        ...kDnsPresets.map((preset) => _DnsPresetCard(
              preset: preset,
              selected: s.dnsPresetId == preset.id,
              onTap: () => s.setDnsPreset(preset.id),
            )),

        // ── Custom input (shown when Custom selected) ──
        if (isCustom) ...[
          const SizedBox(height: 16),
          _GroupLabel('Custom DNS Addresses'),
          _Card(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Column(children: [
                _DnsField(label: 'Primary DNS', ctrl: _dns1Ctrl, hint: 'e.g. 1.1.1.1'),
                const SizedBox(height: 10),
                _DnsField(label: 'Secondary DNS', ctrl: _dns2Ctrl, hint: 'e.g. 1.0.0.1'),
                const SizedBox(height: 8),
              ]),
            ),
          ]),
        ],

        const SizedBox(height: 20),

        // ── Apply button ──
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _applying ? null : _apply,
            icon: _applying
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.check_circle_rounded, size: 18),
            label: Text(_applying ? 'Applying…' : 'Apply DNS Settings',
                style: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 14)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
          ),
        ),

        const SizedBox(height: 32),

        // ── Backend URL ──
        _GroupLabel('Backend Server'),
        _Card(children: [
          _InfoTile(
            icon: Icons.computer_rounded,
            iconColor: Colors.blue,
            label: 'Backend URL',
            value: s.backendUrl,
            subtitle: 'Address of the local streaming backend',
            onTap: () => _editBackendUrl(context, s),
          ),
        ]),

        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            '💡 The DNS setting applies to the backend server (which makes external requests). Restart the backend after changing DNS if streams don\'t load.',
            style: GoogleFonts.inter(
                color: AppColors.tertiary, fontSize: 11, height: 1.5),
          ),
        ),

        const SizedBox(height: 28),

        // ── DoH Status Banner ──
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: Colors.green.shade900.withOpacity(0.4),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.green.shade800, width: 1),
          ),
          child: Row(children: [
            const Icon(Icons.check_circle_rounded, color: Colors.green, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(
              'Built-in DoH active — no external apps needed. '
              'DNS queries go through Cloudflare/Google via encrypted HTTPS.',
              style: GoogleFonts.inter(color: Colors.green.shade300, fontSize: 11, height: 1.4),
            )),
          ]),
        ),

        const SizedBox(height: 20),

        // ── WARP Section (optional advanced) ──
        _GroupLabel('WARP Tunnel (Advanced — Only If Streams Still Fail)'),
        _Card(children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.orange.shade400, Colors.deepOrange.shade600],
                      begin: Alignment.topLeft, end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.vpn_lock_rounded, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Cloudflare WARP Proxy',
                      style: GoogleFonts.inter(color: AppColors.primary, fontSize: 15, fontWeight: FontWeight.w700)),
                  Text('Full tunnel bypass — for IP-level ISP blocks',
                      style: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 12)),
                ])),
                Consumer<AppSettings>(builder: (ctx, s, _) {
                  if (s.warpLoading) {
                    return const SizedBox(width: 24, height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange));
                  }
                  return Switch(
                    value: s.warpEnabled,
                    onChanged: (v) async {
                      if (v) {
                        final ok = await s.enableWarp();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(ok ? '✓ WARP connected — streams will work now!' : '✗ WARP failed to connect. Is the 1.1.1.1 app installed?'),
                            backgroundColor: ok ? Colors.green.shade800 : Colors.red.shade900,
                            duration: const Duration(seconds: 4),
                          ));
                        }
                      } else {
                        await s.disableWarp();
                      }
                    },
                    activeColor: Colors.orange,
                  );
                }),
              ]),
              const SizedBox(height: 12),
              Consumer<AppSettings>(builder: (ctx, s, _) {
                final color = s.warpStatus == 'Connected' ? Colors.green
                    : s.warpStatus == 'Connecting' ? Colors.orange
                    : s.warpStatus == 'Not installed' ? Colors.grey
                    : Colors.red.shade400;
                return Row(children: [
                  Container(width: 8, height: 8,
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Text('WARP: ${s.warpStatus}',
                      style: GoogleFonts.inter(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => s.refreshWarpStatus(),
                    child: Text('Refresh', style: GoogleFonts.inter(color: AppColors.accent, fontSize: 12)),
                  ),
                ]);
              }),
              const SizedBox(height: 8),
              Text(
                'Most users do NOT need this — the built-in DoH handles DNS blocking automatically. '
                'Only enable WARP if streams still fail after trying different DNS presets. '
                'Requires the "Cloudflare One Client" (1.1.1.1) app to be installed.',
                style: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 11, height: 1.5),
              ),
            ]),
          ),
        ]),
      ]);
    });
  }


  void _editBackendUrl(BuildContext context, AppSettings s) {
    final ctrl = TextEditingController(text: s.backendUrl);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Backend URL',
            style: GoogleFonts.inter(color: Colors.white, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: ctrl,
          style: GoogleFonts.inter(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'http://localhost:3000',
            hintStyle: GoogleFonts.inter(color: AppColors.tertiary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: GoogleFonts.inter(color: AppColors.tertiary)),
          ),
          TextButton(
            onPressed: () {
              s.setBackendUrl(ctrl.text);
              Navigator.pop(ctx);
            },
            child: Text('Save', style: GoogleFonts.inter(color: AppColors.accent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _DnsStatusBanner extends StatelessWidget {
  final bool success;
  const _DnsStatusBanner({required this.success});
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: success
              ? const Color(0xFF1A3326)
              : const Color(0xFF331A1A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: success ? const Color(0xFF2A6648) : const Color(0xFF662222),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              success ? Icons.check_circle_rounded : Icons.error_rounded,
              color: success ? const Color(0xFF4CAF50) : Colors.redAccent,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                success
                    ? 'DNS applied successfully! New streams will use the selected DNS.'
                    : 'Could not apply DNS — is the backend running? Restart the backend and try again.',
                style: GoogleFonts.inter(
                    color: success ? const Color(0xFF81C784) : Colors.redAccent,
                    fontSize: 12,
                    height: 1.4),
              ),
            ),
          ],
        ),
      );
}

class _DnsPresetCard extends StatefulWidget {
  final DnsPreset preset;
  final bool selected;
  final VoidCallback onTap;
  const _DnsPresetCard(
      {required this.preset, required this.selected, required this.onTap});
  @override
  State<_DnsPresetCard> createState() => _DnsPresetCardState();
}

class _DnsPresetCardState extends State<_DnsPresetCard> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final p = widget.preset;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: widget.selected
                ? AppColors.accent.withValues(alpha: 0.1)
                : _hover
                    ? Colors.white.withValues(alpha: 0.03)
                    : AppColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.selected
                  ? AppColors.accent.withValues(alpha: 0.5)
                  : AppColors.cardBorder,
              width: widget.selected ? 1.5 : 0.5,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: widget.selected
                      ? AppColors.accent.withValues(alpha: 0.15)
                      : AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(p.icon,
                    size: 18,
                    color: widget.selected
                        ? AppColors.accent
                        : AppColors.secondary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name,
                        style: GoogleFonts.inter(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(p.description,
                        style: GoogleFonts.inter(
                            color: AppColors.tertiary, fontSize: 11)),
                    if (p.servers.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: p.servers
                            .map((ip) => Container(
                                  margin: const EdgeInsets.only(right: 6),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppColors.surfaceHigher,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(ip,
                                      style: GoogleFonts.inter(
                                          color: AppColors.secondary,
                                          fontSize: 10)),
                                ))
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.selected)
                Container(
                  width: 20,
                  height: 20,
                  decoration: const BoxDecoration(
                    color: AppColors.accent,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check_rounded,
                      color: Colors.white, size: 13),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DnsField extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  final String hint;
  const _DnsField(
      {required this.label, required this.ctrl, required this.hint});
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: GoogleFonts.inter(
                  color: AppColors.secondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          TextField(
            controller: ctrl,
            style: GoogleFonts.inter(color: Colors.white, fontSize: 13),
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[\d\.]'))
            ],
            decoration: InputDecoration(
              hintText: hint,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              filled: true,
              fillColor: AppColors.surfaceHigher,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      const BorderSide(color: AppColors.accent, width: 1.5)),
            ),
          ),
        ],
      );
}

// ─── PLAYBACK SECTION ─────────────────────────────────────────────────────────

class _PlaybackSection extends StatelessWidget {
  const _PlaybackSection();
  @override
  Widget build(BuildContext context) {
    return Consumer<AppSettings>(builder: (ctx, s, _) {
      return _SectionScroll(children: [
        _SectionTitle('Playback',
            subtitle: 'Customize how videos are loaded and played'),

        _GroupLabel('Default Quality'),
        _Card(children: [
          _ChoiceTile(
            icon: Icons.hd_rounded,
            iconColor: const Color(0xFF69F0AE),
            label: '1080p',
            subtitle: 'Full HD — best quality, higher bandwidth',
            selected: s.preferredQuality == '1080p',
            onTap: () => s.setPreferredQuality('1080p'),
          ),
          _ChoiceTile(
            icon: Icons.hd_rounded,
            iconColor: Colors.lightBlue,
            label: '720p',
            subtitle: 'HD — balanced quality and speed',
            selected: s.preferredQuality == '720p',
            onTap: () => s.setPreferredQuality('720p'),
          ),
          _ChoiceTile(
            icon: Icons.auto_awesome_rounded,
            iconColor: AppColors.accent,
            label: 'Auto (Best Available)',
            subtitle: 'Let the provider choose the highest quality',
            selected: s.preferredQuality == 'auto',
            onTap: () => s.setPreferredQuality('auto'),
          ),
        ]),

        const SizedBox(height: 20),
        _GroupLabel('Anime Language Preference'),
        _Card(children: [
          _ChoiceTile(
            icon: Icons.subtitles_rounded,
            iconColor: Colors.amber,
            label: 'Subtitled (Sub)',
            subtitle: 'Original Japanese audio with subtitles',
            selected: s.preferredLang == 'Sub',
            onTap: () => s.setPreferredLang('Sub'),
          ),
          _ChoiceTile(
            icon: Icons.record_voice_over_rounded,
            iconColor: Colors.purple,
            label: 'Dubbed (Dub)',
            subtitle: 'English dubbed audio',
            selected: s.preferredLang == 'Dub',
            onTap: () => s.setPreferredLang('Dub'),
          ),
        ]),

        const SizedBox(height: 20),
        _GroupLabel('Buffer Settings'),
        _Card(children: [
          ...[5, 15, 30, 60].map((sec) => _ChoiceTile(
                icon: Icons.timelapse_rounded,
                iconColor: AppColors.secondary,
                label: '${sec}s pre-buffer',
                subtitle: sec <= 5
                    ? 'Fastest start, may stutter on slow connections'
                    : sec >= 60
                        ? 'Most stable — best for slow or cellular'
                        : 'Good balance between start speed and stability',
                selected: s.bufferSeconds == sec,
                onTap: () => s.setBufferSeconds(sec),
              )),
        ]),

        const SizedBox(height: 20),
        _GroupLabel('Behavior'),
        _Card(children: [
          _ToggleTile(
            icon: Icons.skip_next_rounded,
            iconColor: AppColors.accent,
            label: 'Auto-play Next Episode',
            subtitle: 'Automatically start the next episode when one finishes',
            value: s.autoPlayNext,
            onChanged: s.setAutoPlayNext,
          ),
          _ToggleTile(
            icon: Icons.pause_rounded,
            iconColor: Colors.orange,
            label: 'Pause on Focus Loss',
            subtitle: 'Pause video when you switch to another window',
            value: s.pauseOnFocusLoss,
            onChanged: s.setPauseOnFocusLoss,
          ),
        ]),
      ]);
    });
  }
}

class _ChoiceTile extends StatefulWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  const _ChoiceTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });
  @override
  State<_ChoiceTile> createState() => _ChoiceTileState();
}

class _ChoiceTileState extends State<_ChoiceTile> {
  bool _h = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            color: _h ? Colors.white.withValues(alpha: 0.025) : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: widget.iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(widget.icon, size: 16, color: widget.iconColor),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.label, style: GoogleFonts.inter(
                      color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                  Text(widget.subtitle, style: GoogleFonts.inter(
                      color: AppColors.tertiary, fontSize: 11)),
                ],
              )),
              if (widget.selected)
                Container(
                  width: 20, height: 20,
                  decoration: const BoxDecoration(
                      color: AppColors.accent, shape: BoxShape.circle),
                  child: const Icon(Icons.check_rounded, color: Colors.white, size: 13),
                )
              else
                Container(
                  width: 20, height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.tertiary, width: 1.5),
                  ),
                ),
            ]),
          ),
        ),
      );
}

// ─── PROVIDERS SECTION ────────────────────────────────────────────────────────

class _ProvidersSection extends StatelessWidget {
  const _ProvidersSection();
  @override
  Widget build(BuildContext context) {
    return Consumer<AppSettings>(builder: (ctx, s, _) {
      return _SectionScroll(children: [
        _SectionTitle('Providers',
            subtitle: 'Enable or disable streaming sources'),

        _GroupLabel('Movies & TV Shows'),
        _Card(children: [
          _ProviderTile(
            name: '4KHD Hub',
            description: 'High-quality 1080p/4K movies and TV shows',
            badgeText: '1080p · 4K',
            badgeColor: const Color(0xFF69F0AE),
            enabled: s.enable4kHdHub,
            onChanged: s.setEnable4kHdHub,
            icon: Icons.movie_filter_rounded,
          ),
        ]),

        const SizedBox(height: 16),
        _GroupLabel('Anime'),
        _Card(children: [
          _ProviderTile(
            name: 'AniDB',
            description: 'Anime streaming with Sub/Dub options',
            badgeText: 'Sub · Dub',
            badgeColor: Colors.amber,
            enabled: s.enableAniDb,
            onChanged: s.setEnableAniDb,
            icon: Icons.play_circle_filled_rounded,
          ),
          _ProviderTile(
            name: 'AniDAO',
            description: 'Alternative anime source',
            badgeText: 'Sub',
            badgeColor: Colors.lightBlue,
            enabled: s.enableAniDao,
            onChanged: s.setEnableAniDao,
            icon: Icons.animation_rounded,
          ),
        ]),

        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.blue.withValues(alpha: 0.2)),
          ),
          child: Row(children: [
            const Icon(Icons.info_outline_rounded, color: Colors.lightBlue, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(
              'Provider changes take effect on the next search or stream. Anime content always uses AniDB/AniDAO; non-anime uses 4KHD Hub.',
              style: GoogleFonts.inter(color: Colors.lightBlue, fontSize: 11, height: 1.5),
            )),
          ]),
        ),
      ]);
    });
  }
}

class _ProviderTile extends StatelessWidget {
  final String name;
  final String description;
  final String badgeText;
  final Color badgeColor;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  final IconData icon;

  const _ProviderTile({
    required this.name,
    required this.description,
    required this.badgeText,
    required this.badgeColor,
    required this.enabled,
    required this.onChanged,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: enabled
                    ? badgeColor.withValues(alpha: 0.12)
                    : AppColors.surfaceHigh,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 20,
                  color: enabled ? badgeColor : AppColors.tertiary),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(name, style: GoogleFonts.inter(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(badgeText, style: GoogleFonts.inter(
                        color: badgeColor, fontSize: 10, fontWeight: FontWeight.w700)),
                  ),
                ]),
                const SizedBox(height: 2),
                Text(description, style: GoogleFonts.inter(
                    color: AppColors.tertiary, fontSize: 11)),
              ],
            )),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Switch(
                  value: enabled,
                  onChanged: onChanged,
                  activeColor: AppColors.accent,
                  thumbColor: WidgetStateProperty.all(Colors.white),
                ),
                Text(enabled ? 'Active' : 'Disabled',
                    style: GoogleFonts.inter(
                        color: enabled
                            ? const Color(0xFF4CAF50)
                            : AppColors.tertiary,
                        fontSize: 10,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ],
        ),
      );
}

// ─── APPEARANCE SECTION ───────────────────────────────────────────────────────

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection();

  static const _colors = [
    ('Netflix Red', 'E50914'),
    ('Cobalt Blue', '1565C0'),
    ('Purple', '7C3AED'),
    ('Teal', '0D9488'),
    ('Amber', 'F59E0B'),
    ('Pink', 'EC4899'),
    ('Lime', '65A30D'),
    ('Orange', 'EA580C'),
  ];

  @override
  Widget build(BuildContext context) {
    return Consumer<AppSettings>(builder: (ctx, s, _) {
      return _SectionScroll(children: [
        _SectionTitle('Appearance', subtitle: 'Personalize the look of the app'),

        _GroupLabel('Accent Color'),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.cardBorder, width: 0.5),
          ),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: _colors.map((c) {
              final color = Color(int.parse('FF${c.$2}', radix: 16));
              final active = s.accentColorHex == c.$2;
              return GestureDetector(
                onTap: () => s.setAccentColor(c.$2),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: active ? Colors.white : Colors.transparent,
                        width: 2.5,
                      ),
                      boxShadow: active
                          ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 12)]
                          : [],
                    ),
                    child: active
                        ? const Icon(Icons.check_rounded, color: Colors.white, size: 22)
                        : null,
                  ),
                  const SizedBox(height: 6),
                  Text(c.$1,
                      style: GoogleFonts.inter(
                          color: active ? Colors.white : AppColors.tertiary,
                          fontSize: 10)),
                ]),
              );
            }).toList(),
          ),
        ),

        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            '⚠️ Accent color changes take effect after restarting the app.',
            style: GoogleFonts.inter(color: AppColors.tertiary, fontSize: 11),
          ),
        ),
      ]);
    });
  }
}

// ─── ABOUT SECTION ────────────────────────────────────────────────────────────

class _AboutSection extends StatefulWidget {
  const _AboutSection();
  @override
  State<_AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<_AboutSection> {
  bool _clearing = false;
  bool _resetting = false;

  Future<void> _clearHistory() async {
    final ok = await _confirm(context, 'Clear Watch History',
        'This will permanently delete all watch history and progress. This cannot be undone.');
    if (!ok || !mounted) return;
    setState(() => _clearing = true);
    await LocalDb.instance.clearAll();
    setState(() => _clearing = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Watch history cleared',
            style: GoogleFonts.inter(color: Colors.white)),
        backgroundColor: const Color(0xFF1A3326),
      ));
    }
  }

  Future<void> _resetAll() async {
    final ok = await _confirm(context, 'Reset All Settings',
        'This will reset all settings, clear DNS preferences, and remove watch history. The app will return to defaults.');
    if (!ok || !mounted) return;
    setState(() => _resetting = true);
    await AppSettings.instance.resetAll();
    setState(() => _resetting = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Settings reset to defaults',
            style: GoogleFonts.inter(color: Colors.white)),
        backgroundColor: AppColors.surface,
      ));
    }
  }

  Future<bool> _confirm(BuildContext ctx, String title, String msg) async {
    return await showDialog<bool>(
          context: ctx,
          builder: (d) => AlertDialog(
            backgroundColor: AppColors.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            title: Text(title,
                style: GoogleFonts.inter(
                    color: Colors.white, fontWeight: FontWeight.w700)),
            content: Text(msg,
                style: GoogleFonts.inter(color: AppColors.secondary, height: 1.5)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: Text('Cancel',
                    style: GoogleFonts.inter(color: AppColors.tertiary)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(d, true),
                child: Text('Confirm',
                    style: GoogleFonts.inter(
                        color: Colors.redAccent, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) => _SectionScroll(children: [
        _SectionTitle('About'),

        // App info card
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.accent.withValues(alpha: 0.15),
                AppColors.accent.withValues(alpha: 0.05),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: AppColors.accent.withValues(alpha: 0.25), width: 1),
          ),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [Color(0xFF1565C0), Color(0xFF0D47A1)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const Icon(Icons.play_arrow_rounded,
                    color: Colors.white, size: 32),
              ),
              const SizedBox(width: 16),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('CloudStream',
                    style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800)),
                Text('Version 1.0.0 · Windows',
                    style: GoogleFonts.inter(
                        color: AppColors.secondary, fontSize: 12)),
                const SizedBox(height: 4),
                Text('Built with Flutter + Media Kit',
                    style: GoogleFonts.inter(
                        color: AppColors.tertiary, fontSize: 11)),
              ]),
            ],
          ),
        ),

        const SizedBox(height: 24),
        _GroupLabel('Data Management'),
        _Card(children: [
          _InfoTile(
            icon: Icons.history_rounded,
            iconColor: Colors.orange,
            label: 'Clear Watch History',
            value: '',
            subtitle: 'Remove all viewed content and progress data',
            onTap: _clearing ? null : _clearHistory,
            trailing: _clearing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.orange))
                : const Icon(Icons.delete_outline_rounded,
                    color: Colors.orange, size: 18),
          ),
          _InfoTile(
            icon: Icons.restart_alt_rounded,
            iconColor: Colors.redAccent,
            label: 'Reset All Settings',
            value: '',
            subtitle: 'Restore all settings to factory defaults',
            onTap: _resetting ? null : _resetAll,
            trailing: _resetting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.redAccent))
                : const Icon(Icons.restore_rounded,
                    color: Colors.redAccent, size: 18),
          ),
        ]),

        const SizedBox(height: 24),
        _GroupLabel('Technical Info'),
        _Card(children: [
          _InfoTile(
            icon: Icons.code_rounded,
            iconColor: Colors.lightBlue,
            label: 'Framework',
            value: 'Flutter 3.x + Media Kit',
          ),
          _InfoTile(
            icon: Icons.storage_rounded,
            iconColor: Colors.purple,
            label: 'Backend',
            value: 'Node.js + Express',
          ),
          _InfoTile(
            icon: Icons.movie_rounded,
            iconColor: const Color(0xFF69F0AE),
            label: 'Metadata',
            value: 'TMDB API',
          ),
          _InfoTile(
            icon: Icons.play_circle_rounded,
            iconColor: Colors.amber,
            label: 'Player',
            value: 'MPV / libmpv',
          ),
        ]),
      ]);
}
