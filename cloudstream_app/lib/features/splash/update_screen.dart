import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/constants.dart';
import '../../core/services/update_service.dart';
import '../../shared/theme/app_theme.dart';

class UpdateScreen extends StatefulWidget {
  final UpdateInfo info;
  final bool isMandatory;

  const UpdateScreen({
    super.key,
    required this.info,
    required this.isMandatory,
  });

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  final UpdateService _updateService = UpdateService.instance;

  @override
  void initState() {
    super.initState();
    _updateService.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _updateService.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _startUpdate() async {
    await _updateService.startUpdateDownload(widget.info.downloadUrl);
  }

  @override
  Widget build(BuildContext context) {
    final progress = _updateService.downloadProgress;
    final isDownloading = _updateService.isDownloading;
    final error = _updateService.error;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Container(
          width: 550,
          padding: const EdgeInsets.all(40),
          decoration: BoxDecoration(
            color: const Color(0xFF0F1013).withOpacity(0.85),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withOpacity(0.05),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.6),
                blurRadius: 40,
                offset: const Offset(0, 20),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.accent.withOpacity(0.1),
                    ),
                    child: const Icon(
                      Icons.system_update_rounded,
                      color: AppColors.accent,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isDownloading ? 'Downloading Update' : 'New Update Available',
                          style: GoogleFonts.inter(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Version ${kAppVersion} → ${widget.info.latestVersion}',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: AppColors.secondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 30),

              if (!isDownloading) ...[
                // Release notes block
                Text(
                  'Release Notes',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 180),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.03),
                      width: 1,
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      widget.info.releaseNotes.isEmpty
                          ? 'No release notes provided.'
                          : widget.info.releaseNotes,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: AppColors.tertiary,
                        height: 1.6,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 30),

                // Error message if any
                if (error != null) ...[
                  Text(
                    error,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: Colors.redAccent,
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                // Action buttons
                Row(
                  children: [
                    if (!widget.isMandatory) ...[
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: Colors.white.withOpacity(0.1)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              foregroundColor: AppColors.secondary,
                            ),
                            onPressed: () => Navigator.pop(context),
                            child: Text(
                              'Later',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                    ],
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accent,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: _startUpdate,
                          child: Text(
                            'Update Now',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                // Progress block
                const SizedBox(height: 20),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 12,
                    backgroundColor: Colors.white.withOpacity(0.05),
                    color: AppColors.accent,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Installing update once downloaded...',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: AppColors.secondary,
                      ),
                    ),
                    Text(
                      '${(progress * 100).toStringAsFixed(0)}%',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
