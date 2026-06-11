// HLS quality variant — represents one entry from a master.m3u8 playlist
class HlsVariant {
  final String label;       // '1080p', '720p', '360p'
  final int bandwidth;      // bits/sec — used with hls-bitrate MPV property
  final String resolution;  // '1920x1080', '1280x720', etc.

  const HlsVariant({
    required this.label,
    required this.bandwidth,
    required this.resolution,
  });
}
