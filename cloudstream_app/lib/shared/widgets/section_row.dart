// lib/shared/widgets/section_row.dart
// A labelled horizontal scrolling row of content cards (used on home + search)

import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';
import '../../core/models/search_result.dart';
import '../theme/app_theme.dart';
import 'content_card.dart';

class SectionRow extends StatefulWidget {
  final String title;
  final List<SearchResult> items;
  final bool isLoading;
  final void Function(SearchResult item) onItemTap;

  const SectionRow({
    super.key,
    required this.title,
    required this.items,
    required this.onItemTap,
    this.isLoading = false,
  });

  @override
  State<SectionRow> createState() => _SectionRowState();
}

class _SectionRowState extends State<SectionRow> {
  bool _headerHovered = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Text(
                widget.title,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(width: 8),
              MouseRegion(
                onEnter: (_) => setState(() => _headerHovered = true),
                onExit: (_) => setState(() => _headerHovered = false),
                cursor: SystemMouseCursors.click,
                child: AnimatedOpacity(
                  opacity: _headerHovered ? 1.0 : 0.5,
                  duration: const Duration(milliseconds: 150),
                  child: const Icon(
                    Icons.arrow_forward_rounded,
                    color: AppColors.accent,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        // Cards row
        SizedBox(
          height: 220,
          child: widget.isLoading
              ? _buildShimmerRow()
              : widget.items.isEmpty
                  ? Center(
                      child: Text(
                        'No results',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    )
                  : ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      itemCount: widget.items.length,
                      itemBuilder: (ctx, i) {
                        final item = widget.items[i];
                        return Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: ContentCard(
                            title: item.title,
                            posterUrl: item.poster,
                            onTap: () => widget.onItemTap(item),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _buildShimmerRow() {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      itemCount: 8,
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Shimmer.fromColors(
          baseColor: AppColors.shimmerBase,
          highlightColor: AppColors.shimmerHighlight,
          child: Container(
            width: 130,
            height: 190,
            decoration: BoxDecoration(
              color: AppColors.shimmerBase,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      ),
    );
  }
}
