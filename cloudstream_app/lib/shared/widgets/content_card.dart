// lib/shared/widgets/content_card.dart

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import '../theme/app_theme.dart';

class ContentCard extends StatefulWidget {
  final String title;
  final String? posterUrl;
  final VoidCallback onTap;
  final double width;
  final double height;

  const ContentCard({
    super.key,
    required this.title,
    this.posterUrl,
    required this.onTap,
    this.width = 130,
    this.height = 190,
  });

  @override
  State<ContentCard> createState() => _ContentCardState();
}

class _ContentCardState extends State<ContentCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          transform: _hovered
              ? (Matrix4.identity()..scale(1.04, 1.04, 1.0))
              : Matrix4.identity(),
          transformAlignment: Alignment.center,
          width: widget.width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Poster
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: widget.width,
                height: widget.height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _hovered
                        ? AppColors.accent.withValues(alpha: 0.6)
                        : AppColors.cardBorder,
                    width: _hovered ? 1.5 : 0.5,
                  ),
                  boxShadow: _hovered
                      ? [
                          BoxShadow(
                            color: AppColors.accent.withValues(alpha: 0.2),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          )
                        ]
                      : [],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: widget.posterUrl != null
                      ? CachedNetworkImage(
                          imageUrl: widget.posterUrl!,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => _buildShimmer(),
                          errorWidget: (_, __, ___) => _buildPlaceholder(),
                        )
                      : _buildPlaceholder(),
                ),
              ),
              const SizedBox(height: 7),
              // Title
              Text(
                widget.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: _hovered ? AppColors.primary : AppColors.secondary,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildShimmer() {
    return Shimmer.fromColors(
      baseColor: AppColors.shimmerBase,
      highlightColor: AppColors.shimmerHighlight,
      child: Container(color: AppColors.shimmerBase),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: AppColors.surfaceHigh,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.movie_outlined, color: AppColors.tertiary, size: 32),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              widget.title,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.tertiary,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
