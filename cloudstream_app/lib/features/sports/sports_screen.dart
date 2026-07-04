// lib/features/sports/sports_screen.dart
// Premium Sports UI — Sofascore-style interactive match cards

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';
import 'package:dio/dio.dart';

import '../../core/services/app_settings.dart';
import '../../shared/theme/app_theme.dart';

// ─── Models ────────────────────────────────────────────────────────────────

class SportsMatchLink {
  final String name;
  final String type;
  final String url;
  final String hdnea;
  SportsMatchLink({required this.name, required this.type, required this.url, this.hdnea = ''});
  factory SportsMatchLink.fromJson(Map<String, dynamic> j) => SportsMatchLink(
        name: j['name'] ?? 'Stream Server',
        type: j['type'] ?? 'm3u8',
        url: j['url'] ?? '',
        hdnea: j['hdnea'] ?? '',
      );
}

class SportsMatch {
  final String id;
  final String title;
  final String category;
  final String tournament;
  final String teamA;
  final String teamAFlag;
  final String teamALogo; // resolved by backend via flagcdn.com / ESPN CDN
  final String teamB;
  final String teamBFlag;
  final String teamBLogo;
  final String bannerImg;
  final String status;
  final String liveTime;
  final String startTime;
  final String countdown;
  final String endedText;
  final bool pinned;
  final bool hot;
  final List<SportsMatchLink> links;
  SportsMatch({
    required this.id, required this.title, required this.category,
    required this.tournament, required this.teamA, required this.teamAFlag,
    required this.teamALogo, required this.teamB, required this.teamBFlag,
    required this.teamBLogo, required this.bannerImg, required this.status,
    required this.liveTime, required this.startTime, required this.countdown,
    required this.endedText, required this.pinned, required this.hot,
    required this.links,
  });
  factory SportsMatch.fromJson(Map<String, dynamic> j) {
    final rawLinks = j['links'] as List? ?? [];
    return SportsMatch(
      id: j['id'] ?? '',
      title: j['title'] ?? 'Live Match',
      category: j['category'] ?? 'Football',
      tournament: j['tournament'] ?? 'LIVE SPORTS EVENT',
      teamA: j['teamA'] ?? '',
      teamAFlag: j['teamAFlag'] ?? '',
      teamALogo: j['teamALogo'] ?? '',
      teamB: j['teamB'] ?? '',
      teamBFlag: j['teamBFlag'] ?? '',
      teamBLogo: j['teamBLogo'] ?? '',
      bannerImg: j['bannerImg'] ?? j['img'] ?? '',
      status: j['status'] ?? 'live',
      liveTime: j['liveTime'] ?? 'LIVE',
      startTime: j['startTime'] ?? '',
      countdown: j['countdown'] ?? '',
      endedText: j['endedText'] ?? 'Event Ended',
      pinned: j['pinned'] == true,
      hot: j['hot'] == true,
      links: rawLinks.map((l) => SportsMatchLink.fromJson(l)).toList(),
    );
  }
  bool get isLive => status == 'live';
  bool get isUpcoming => status == 'upcoming';
  bool get isFinished => status == 'finished';
}

// ─── Logo source priority: backend logo URL → fallback to initials ────────

Color _sportColor(String category) {
  switch (category.toLowerCase()) {
    case 'football': return const Color(0xFF00D084);
    case 'baseball': return const Color(0xFF4FC3F7);
    case 'basketball': return const Color(0xFFFF8A00);
    case 'cricket': return const Color(0xFF69F0AE);
    case 'boxing': return const Color(0xFFFF4D4D);
    case 'motorsport': return const Color(0xFFFF6D00);
    case 'tennis': return const Color(0xFFD4E157);
    default: return const Color(0xFF8B8BF5);
  }
}

// ─── Screen ──────────────────────────────────────────────────────────────

class SportsScreen extends StatefulWidget {
  const SportsScreen({super.key});
  @override
  State<SportsScreen> createState() => _SportsScreenState();
}

class _SportsScreenState extends State<SportsScreen> with TickerProviderStateMixin {
  bool _loading = true;
  bool _resolvingLinks = false;
  String? _error;
  List<SportsMatch> _allMatches = [];
  String _selectedCategory = 'ALL';
  String _selectedFilter = 'All';
  late AnimationController _pulseController;

  final List<Map<String, dynamic>> _categories = [
    {'name': 'ALL', 'icon': Icons.grid_view_rounded},
    {'name': 'Football', 'icon': Icons.sports_soccer_rounded},
    {'name': 'Baseball', 'icon': Icons.sports_baseball_rounded},
    {'name': 'Basketball', 'icon': Icons.sports_basketball_rounded},
    {'name': 'Cricket', 'icon': Icons.sports_cricket_rounded},
    {'name': 'Boxing', 'icon': Icons.sports_mma_rounded},
    {'name': 'Motorsport', 'icon': Icons.two_wheeler_rounded},
    {'name': 'Tennis', 'icon': Icons.sports_tennis_rounded},
  ];

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
    _fetchSports();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _fetchSports() async {
    setState(() { _loading = true; _error = null; });
    try {
      final dio = Dio();
      final backendUrl = AppSettings.instance.backendUrl;
      final resp = await dio.get('$backendUrl/sports',
          options: Options(receiveTimeout: const Duration(seconds: 8)));
      List<dynamic> listData = [];
      if (resp.statusCode == 200 && resp.data?['success'] == true) {
        listData = resp.data['matches'] as List? ?? [];
      }
      final parsed = listData
          .where((m) => m is Map<String, dynamic> && (m['title']?.toString().isNotEmpty ?? false))
          .map((m) => SportsMatch.fromJson(m as Map<String, dynamic>))
          .toList();
      setState(() { _allMatches = parsed; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  List<SportsMatch> get _filteredMatches {
    return _allMatches.where((m) {
      if (_selectedCategory != 'ALL' && m.category.toLowerCase() != _selectedCategory.toLowerCase()) return false;
      if (_selectedFilter == 'Live' && !m.isLive) return false;
      if (_selectedFilter == 'Upcoming' && !m.isUpcoming) return false;
      if (_selectedFilter == 'Finished' && !m.isFinished) return false;
      return true;
    }).toList();
  }

  void _playMatch(SportsMatch match) async {
    setState(() => _resolvingLinks = true);
    try {
      final dio = Dio();
      final backendUrl = AppSettings.instance.backendUrl;
      final resp = await dio.get('$backendUrl/sports/links',
        queryParameters: {'slug': match.id, 'category': match.category},
        options: Options(receiveTimeout: const Duration(seconds: 15)));
      if (mounted) setState(() => _resolvingLinks = false);
      List<dynamic> linksData = [];
      if (resp.statusCode == 200 && resp.data?['success'] == true) {
        linksData = resp.data['links'] as List? ?? [];
      }
      if (linksData.isEmpty) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No active stream servers found for this match yet.')));
        return;
      }
      final List<Map<String, String>> preloadedRefs = [];
      for (final l in linksData) {
        final url = l['url']?.toString() ?? '';
        if (url.isNotEmpty) {
          preloadedRefs.add({
            'provider': 'cmv_sports', 'title': l['name']?.toString() ?? 'Server',
            'quality': l['type']?.toString().toUpperCase() ?? 'M3U8',
            'url': url, 'key': l['key']?.toString() ?? '',
          });
        }
      }
      if (preloadedRefs.isEmpty) return;
      if (mounted) {
        context.push('/player', extra: {
          'tmdbId': '0', 'mediaType': 'live', 'title': match.title, 'year': '',
          'seasonNumber': '', 'episodeNumber': '', 'episodeTitle': preloadedRefs.first['title'],
          'isAnime': false, 'preloadedUrl': preloadedRefs.first['url'],
          'preloadedProvider': 'cmv_sports', 'preloadedRefs': preloadedRefs, 'backdrop': match.bannerImg,
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _resolvingLinks = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to resolve stream servers: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final categoryMatches = _allMatches.where((m) =>
        _selectedCategory == 'ALL' || m.category.toLowerCase() == _selectedCategory.toLowerCase()).toList();
    final totalCount = categoryMatches.length;
    final liveCount = categoryMatches.where((m) => m.isLive).length;
    final upcomingCount = categoryMatches.where((m) => m.isUpcoming).length;
    final finishedCount = categoryMatches.where((m) => m.isFinished).length;
    return Scaffold(
      backgroundColor: const Color(0xFF0E1320),
      appBar: _buildAppBar(),
      body: Stack(children: [
        _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _error != null ? _buildErrorView()
          : CustomScrollView(slivers: [
              SliverToBoxAdapter(child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Column(children: [
                  _buildNoticeBanner(),
                  const SizedBox(height: 16),
                  _buildCategoryRow(),
                  const SizedBox(height: 12),
                  _buildFilterPills(totalCount, liveCount, upcomingCount, finishedCount),
                  const SizedBox(height: 16),
                ]),
              )),
              if (_filteredMatches.isEmpty)
                SliverToBoxAdapter(child: _buildEmptyView())
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                  sliver: SliverList(delegate: SliverChildBuilderDelegate(
                    (ctx, idx) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _buildMatchCard(_filteredMatches[idx]),
                    ),
                    childCount: _filteredMatches.length,
                  )),
                ),
            ]),
        if (_resolvingLinks)
          Container(
            color: Colors.black.withOpacity(0.7),
            child: Center(child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              decoration: BoxDecoration(
                color: const Color(0xFF1A2030), borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white10),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 30)],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(color: AppColors.primary, strokeWidth: 3),
                const SizedBox(height: 16),
                Text('Loading stream...', style: GoogleFonts.inter(color: Colors.white, fontSize: 14)),
              ]),
            )),
          ),
      ]),
    );
  }

  AppBar _buildAppBar() => AppBar(
    backgroundColor: const Color(0xFF0E1320),
    elevation: 0, titleSpacing: 16,
    title: Row(children: [
      Container(
        width: 34, height: 34,
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF00D084), Color(0xFF00A86B)]),
          borderRadius: BorderRadius.circular(10)),
        child: const Icon(Icons.sports_soccer_rounded, color: Colors.white, size: 20)),
      const SizedBox(width: 10),
      Text('LIVE SPORTS', style: GoogleFonts.outfit(
          color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20, letterSpacing: 1.4)),
    ]),
    actions: [
      AnimatedBuilder(animation: _pulseController, builder: (_, __) {
        final liveCount = _allMatches.where((m) => m.isLive).length;
        if (liveCount == 0) return const SizedBox();
        return Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.redAccent.withOpacity(0.15 + _pulseController.value * 0.1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.redAccent.withOpacity(0.5))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 6, height: 6, decoration: BoxDecoration(
              color: Colors.redAccent.withOpacity(0.6 + _pulseController.value * 0.4),
              shape: BoxShape.circle)),
            const SizedBox(width: 5),
            Text('$liveCount LIVE', style: GoogleFonts.inter(
                color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold)),
          ]));
      }),
      IconButton(icon: const Icon(Icons.refresh_rounded, color: Colors.white54), onPressed: _fetchSports),
    ],
  );

  Widget _buildNoticeBanner() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      gradient: const LinearGradient(colors: [Color(0xFF1A2535), Color(0xFF141B28)]),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.white.withOpacity(0.07))),
    child: Row(children: [
      const Icon(Icons.stars_rounded, color: Colors.amber, size: 18),
      const SizedBox(width: 10),
      Expanded(child: Text(
        '📌 Live Sports ⭐ | 🚀 Live FIFA World Cup & Global Matches Active',
        style: GoogleFonts.inter(color: Colors.white60, fontSize: 11.5, fontWeight: FontWeight.w500),
        maxLines: 1, overflow: TextOverflow.ellipsis)),
    ]));

  Widget _buildCategoryRow() => SizedBox(
    height: 76,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: _categories.length,
      separatorBuilder: (_, __) => const SizedBox(width: 12),
      itemBuilder: (ctx, idx) {
        final cat = _categories[idx];
        final isSelected = _selectedCategory == cat['name'];
        final accent = _sportColor(cat['name'] as String);
        return GestureDetector(
          onTap: () => setState(() => _selectedCategory = cat['name']),
          child: Column(children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 50, height: 50,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected ? accent.withOpacity(0.2) : const Color(0xFF1A2035),
                border: Border.all(color: isSelected ? accent : Colors.white.withOpacity(0.08), width: isSelected ? 2 : 1),
                boxShadow: isSelected ? [BoxShadow(color: accent.withOpacity(0.3), blurRadius: 12, spreadRadius: 1)] : []),
              child: Icon(cat['icon'] as IconData, color: isSelected ? accent : Colors.white38, size: 22)),
            const SizedBox(height: 4),
            Text(cat['name'] as String, style: GoogleFonts.inter(
              color: isSelected ? accent : Colors.white38, fontSize: 10,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
          ]));
      }));

  Widget _buildFilterPills(int totalCount, int liveCount, int upcomingCount, int finishedCount) {
    final filters = [
      {'name': 'All', 'count': totalCount, 'color': Colors.white70},
      {'name': 'Live', 'count': liveCount, 'color': Colors.redAccent},
      {'name': 'Upcoming', 'count': upcomingCount, 'color': Colors.amberAccent},
      {'name': 'Finished', 'count': finishedCount, 'color': Colors.white38},
    ];
    return Row(children: filters.map((f) {
      final name = f['name'] as String;
      final count = f['count'] as int;
      final color = f['color'] as Color;
      final isSelected = _selectedFilter == name;
      return Padding(padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          onTap: () => setState(() => _selectedFilter = name),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: isSelected ? color.withOpacity(0.15) : const Color(0xFF1A2035),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isSelected ? color.withOpacity(0.7) : Colors.white.withOpacity(0.08),
                width: isSelected ? 1.5 : 1)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (name == 'Live') AnimatedBuilder(animation: _pulseController, builder: (_, __) =>
                Container(width: 6, height: 6, margin: const EdgeInsets.only(right: 5),
                  decoration: BoxDecoration(shape: BoxShape.circle,
                    color: isSelected ? color.withOpacity(0.5 + _pulseController.value * 0.5) : color.withOpacity(0.4)))),
              Text('$name ($count)', style: GoogleFonts.inter(
                color: isSelected ? color : Colors.white38, fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500)),
            ]))));
    }).toList());
  }

  Widget _buildMatchCard(SportsMatch match) {
    final isTeamVsTeam = match.teamA.isNotEmpty && match.teamB.isNotEmpty;
    final accent = _sportColor(match.category);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _playMatch(match),
        borderRadius: BorderRadius.circular(16),
        splashColor: accent.withOpacity(0.1),
        highlightColor: accent.withOpacity(0.05),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: match.isLive
                ? [const Color(0xFF1C2236), const Color(0xFF161B2C)]
                : [const Color(0xFF18202F), const Color(0xFF131825)]),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: match.isLive ? accent.withOpacity(0.25) : Colors.white.withOpacity(0.07)),
            boxShadow: match.isLive
              ? [BoxShadow(color: accent.withOpacity(0.08), blurRadius: 20, offset: const Offset(0, 4))]
              : [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 2))]),
          child: Column(children: [
            _buildTournamentHeader(match, accent),
            Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: isTeamVsTeam ? _buildTeamVsTeamBody(match, accent) : _buildBannerBody(match, accent)),
            if (match.isLive) _buildWatchNowBar(match, accent),
          ]))));
  }

  Widget _buildTournamentHeader(SportsMatch match, Color accent) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.03),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16))),
    child: Row(children: [
      Container(width: 8, height: 8, decoration: BoxDecoration(color: accent, shape: BoxShape.circle)),
      const SizedBox(width: 8),
      Expanded(child: Text(match.tournament,
        style: GoogleFonts.inter(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5),
        maxLines: 1, overflow: TextOverflow.ellipsis)),
      if (match.isLive)
        AnimatedBuilder(animation: _pulseController, builder: (_, __) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.redAccent.withOpacity(0.12 + _pulseController.value * 0.08),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.redAccent.withOpacity(0.4))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 5, height: 5, decoration: BoxDecoration(
              color: Colors.redAccent.withOpacity(0.6 + _pulseController.value * 0.4), shape: BoxShape.circle)),
            const SizedBox(width: 4),
            Text('LIVE', style: GoogleFonts.inter(color: Colors.redAccent, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1)),
          ])))
      else if (match.isUpcoming)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: Colors.amberAccent.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.amberAccent.withOpacity(0.3))),
          child: Text('UPCOMING', style: GoogleFonts.inter(color: Colors.amberAccent, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1)))
      else
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(20)),
          child: Text('FT', style: GoogleFonts.inter(color: Colors.white38, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1))),
      if (match.hot) ...[const SizedBox(width: 6), const Text('🔥', style: TextStyle(fontSize: 13))],
    ]));

  Widget _buildTeamVsTeamBody(SportsMatch match, Color accent) => Row(children: [
    Expanded(child: _buildTeamCol(match.teamA, match.teamALogo, match.teamAFlag, accent)),
    Expanded(flex: 2, child: _buildCenterStatus(match, accent)),
    Expanded(child: _buildTeamCol(match.teamB, match.teamBLogo, match.teamBFlag, accent)),
  ]);

  Widget _buildTeamCol(String teamName, String logoUrl, String flag, Color accent) => Column(children: [
    _buildTeamLogo(logoUrl, flag, teamName, accent),
    const SizedBox(height: 8),
    Text(_shortTeamName(teamName),
      style: GoogleFonts.inter(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
      textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
  ]);

  String _shortTeamName(String name) {
    const Map<String, String> abbr = {
      'manchester city': 'Man City', 'manchester united': 'Man Utd',
      'paris saint-germain': 'PSG', 'borussia dortmund': 'Dortmund',
      'atletico madrid': 'Atletico', 'new york yankees': 'Yankees',
      'new york mets': 'NY Mets', 'boston red sox': 'Red Sox',
      'los angeles dodgers': 'Dodgers', 'los angeles angels': 'Angels',
      'san francisco giants': 'SF Giants', 'chicago white sox': 'White Sox',
      'chicago cubs': 'Cubs', 'cleveland guardians': 'Guardians',
      'st. louis cardinals': 'Cardinals', 'st louis cardinals': 'Cardinals',
      'miami marlins': 'Marlins', 'houston astros': 'Astros',
      'tampa bay rays': 'Rays', 'colorado rockies': 'Rockies',
      'golden state warriors': 'Warriors', 'los angeles lakers': 'Lakers',
    };
    return abbr[name.toLowerCase()] ?? name;
  }

  Widget _buildTeamLogo(String logoUrl, String flag, String teamName, Color accent) {
    // Sofascore-style: white circle with shadow, logo inside
    return Container(
      width: 68, height: 68,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: accent.withOpacity(0.25), blurRadius: 14, spreadRadius: 1),
          BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 8, offset: const Offset(0, 3)),
        ],
        border: Border.all(color: Colors.white.withOpacity(0.9), width: 2),
      ),
      child: ClipOval(
        child: logoUrl.isNotEmpty
          ? Image.network(
              logoUrl, width: 68, height: 68, fit: BoxFit.contain,
              loadingBuilder: (_, child, progress) => progress == null
                ? child
                : Center(child: SizedBox(width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2, color: accent))),
              errorBuilder: (_, __, ___) => _logoFallback(flag, teamName, accent))
          : _logoFallback(flag, teamName, accent),
      ),
    );
  }

  Widget _logoFallback(String flag, String teamName, Color accent) {
    if (flag.startsWith('http')) {
      return Image.network(flag, width: 68, height: 68, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _initialsLogo(teamName, accent));
    }
    return _initialsLogo(teamName, accent);
  }

  Widget _initialsLogo(String teamName, Color accent) {
    final words = teamName.trim().split(' ');
    final initials = words.length >= 2
      ? '${words.first[0]}${words.last[0]}'.toUpperCase()
      : teamName.substring(0, math.min(2, teamName.length)).toUpperCase();
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [accent.withOpacity(0.85), accent.withOpacity(0.5)],
          begin: Alignment.topLeft, end: Alignment.bottomRight),
        shape: BoxShape.circle),
      child: Center(child: Text(initials,
        style: GoogleFonts.outfit(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold,
          shadows: [Shadow(color: Colors.black.withOpacity(0.3), blurRadius: 4)]))));
  }

  Widget _buildCenterStatus(SportsMatch match, Color accent) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Text('VS', style: GoogleFonts.outfit(color: Colors.white24, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 2)),
      const SizedBox(height: 6),
      if (match.isLive)
        Text(match.liveTime, style: GoogleFonts.inter(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.w600))
      else if (match.isUpcoming) ...[
        Text(match.startTime, style: GoogleFonts.inter(color: Colors.amberAccent, fontSize: 11, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(match.countdown, style: GoogleFonts.inter(color: Colors.white38, fontSize: 9),
          textAlign: TextAlign.center, maxLines: 2),
      ] else
        Text(match.endedText, style: GoogleFonts.inter(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.w500),
          textAlign: TextAlign.center),
    ]);

  Widget _buildBannerBody(SportsMatch match, Color accent) {
    final Widget logoWidget = match.bannerImg.isNotEmpty
      ? Image.network(
          match.bannerImg, width: 68, height: 68, fit: BoxFit.contain,
          loadingBuilder: (_, child, progress) => progress == null
            ? child
            : Center(child: SizedBox(width: 22, height: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: accent))),
          errorBuilder: (_, __, ___) => Icon(Icons.play_arrow_rounded, color: accent, size: 30))
      : Icon(Icons.play_arrow_rounded, color: accent, size: 30);

    return Row(children: [
      Container(
        width: 68, height: 68,
        decoration: BoxDecoration(
          color: match.bannerImg.isNotEmpty ? Colors.white : accent.withOpacity(0.12),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(color: accent.withOpacity(0.15), blurRadius: 10, spreadRadius: 1),
            BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 6, offset: const Offset(0, 2)),
          ],
          border: Border.all(
            color: match.bannerImg.isNotEmpty ? Colors.white.withOpacity(0.9) : accent.withOpacity(0.25),
            width: match.bannerImg.isNotEmpty ? 2 : 1),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: logoWidget,
        ),
      ),
      const SizedBox(width: 16),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(match.title, style: GoogleFonts.inter(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
          maxLines: 2, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 5),
        Text(match.isLive ? '● Live Now' : match.isUpcoming ? match.startTime : match.endedText,
          style: GoogleFonts.inter(color: match.isLive ? Colors.redAccent : Colors.amberAccent,
            fontSize: 11, fontWeight: FontWeight.w600)),
      ])),
      if (match.isLive)
        Container(padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: accent.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
          child: Icon(Icons.chevron_right_rounded, color: accent, size: 22)),
    ]);
  }

  Widget _buildWatchNowBar(SportsMatch match, Color accent) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(
      gradient: LinearGradient(colors: [accent.withOpacity(0.12), accent.withOpacity(0.06)]),
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
      border: Border(top: BorderSide(color: accent.withOpacity(0.15)))),
    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.play_circle_outline_rounded, color: accent, size: 16),
      const SizedBox(width: 6),
      Text('Watch Now', style: GoogleFonts.inter(color: accent, fontSize: 12, fontWeight: FontWeight.bold)),
      const SizedBox(width: 8),
      Icon(Icons.chevron_right_rounded, color: accent.withOpacity(0.7), size: 16),
    ]));

  Widget _buildEmptyView() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 60),
    child: Center(child: Column(children: [
      const Icon(Icons.sports_rounded, color: Colors.white24, size: 48),
      const SizedBox(height: 12),
      Text('No matches found', style: GoogleFonts.inter(color: Colors.white38, fontSize: 15, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      Text('Try a different category or filter', style: GoogleFonts.inter(color: Colors.white24, fontSize: 12)),
    ])));

  Widget _buildErrorView() => Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
    const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 48),
    const SizedBox(height: 16),
    Text('Failed to load sports catalog', style: GoogleFonts.inter(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
    const SizedBox(height: 16),
    ElevatedButton.icon(onPressed: _fetchSports,
      icon: const Icon(Icons.refresh_rounded, color: Colors.black),
      label: const Text('Retry', style: TextStyle(color: Colors.black)),
      style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary)),
  ]));
}
