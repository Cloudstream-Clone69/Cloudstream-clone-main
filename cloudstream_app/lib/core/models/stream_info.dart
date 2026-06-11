// lib/core/models/stream_info.dart

class StreamInfo {
  final String streamUrl;
  final String? proxyUrl;
  final String? referer;

  const StreamInfo({
    required this.streamUrl,
    this.proxyUrl,
    this.referer,
  });

  factory StreamInfo.fromJson(Map<String, dynamic> json) {
    return StreamInfo(
      streamUrl: json['streamUrl'] ?? '',
      proxyUrl: json['proxyUrl'],
      referer: json['referer'],
    );
  }

  /// The URL to actually feed to the player.
  /// Prefer proxyUrl (for HLS streams via backend proxy), else streamUrl.
  String get playUrl => proxyUrl ?? streamUrl;
}
