import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class CastDevice {
  final String name;
  final String locationUrl;
  final String controlUrl;

  CastDevice({
    required this.name,
    required this.locationUrl,
    required this.controlUrl,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CastDevice &&
          runtimeType == other.runtimeType &&
          locationUrl == other.locationUrl;

  @override
  int get hashCode => locationUrl.hashCode;
}

class CastService {
  static final CastService _instance = CastService._internal();
  factory CastService() => _instance;
  CastService._internal();

  final StreamController<List<CastDevice>> _devicesController = StreamController<List<CastDevice>>.broadcast();
  Stream<List<CastDevice>> get devices => _devicesController.stream;

  final List<CastDevice> _discoveredDevices = [];
  bool _isScanning = false;
  bool get isScanning => _isScanning;
  RawDatagramSocket? _socket;
  Timer? _scanTimeoutTimer;

  List<CastDevice> get currentDevices => List.unmodifiable(_discoveredDevices);

  /// Resolves the machine's local IP address in the local subnet.
  Future<String?> getLocalIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          final ip = addr.address;
          if (!addr.isLoopback) {
            // Prefer standard private subnets (192.168.x.x, 10.x.x.x, 172.16.x.x-172.31.x.x)
            if (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.')) {
              return ip;
            }
          }
        }
      }
      if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
        return interfaces.first.addresses.first.address;
      }
    } catch (e) {
      print('[CastService] Error getting local IP: $e');
    }
    return null;
  }

  /// Translates 127.0.0.1 or localhost URL to the machine's local subnet IP.
  Future<String> translateUrl(String url) async {
    if (!url.contains('127.0.0.1') && !url.contains('localhost')) {
      return url;
    }
    final localIp = await getLocalIpAddress();
    if (localIp == null) return url;
    return url
        .replaceAll('127.0.0.1', localIp)
        .replaceAll('localhost', localIp);
  }

  /// Start discovery of DLNA/UPnP MediaRenderers using SSDP.
  Future<void> startDiscovery({Duration timeout = const Duration(seconds: 7)}) async {
    if (_isScanning) return;
    _isScanning = true;
    _discoveredDevices.clear();
    _devicesController.add([]);

    try {
      // Bind to any IPv4 address on an ephemeral port
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _socket!.broadcastEnabled = true;
      _socket!.multicastLoopback = false;

      // SSDP multicast IP and port
      final multicastAddress = InternetAddress('239.255.255.250');
      const multicastPort = 1900;

      // Listen for replies
      _socket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _socket!.receive();
          if (datagram != null) {
            final response = utf8.decode(datagram.data, allowMalformed: true);
            _handleSsdpResponse(response);
          }
        }
      });

      // Send M-SEARCH for MediaRenderer and AVTransport targets
      final targets = [
        'urn:schemas-upnp-org:device:MediaRenderer:1',
        'urn:schemas-upnp-org:service:AVTransport:1',
        'ssdp:all',
      ];

      for (final target in targets) {
        final request = 'M-SEARCH * HTTP/1.1\r\n'
            'HOST: 239.255.255.250:1900\r\n'
            'MAN: "ssdp:discover"\r\n'
            'MX: 3\r\n'
            'ST: $target\r\n\r\n';
        _socket!.send(utf8.encode(request), multicastAddress, multicastPort);
      }

      // Automatically stop scanning after timeout
      _scanTimeoutTimer = Timer(timeout, () {
        stopDiscovery();
      });
    } catch (e) {
      print('[CastService] Discovery startup error: $e');
      stopDiscovery();
    }
  }

  /// Stop discovery.
  void stopDiscovery() {
    _scanTimeoutTimer?.cancel();
    _scanTimeoutTimer = null;
    _socket?.close();
    _socket = null;
    _isScanning = false;
    print('[CastService] Discovery stopped. Found ${_discoveredDevices.length} devices.');
  }

  void _handleSsdpResponse(String response) async {
    // Parse headers
    final lines = response.split('\r\n');
    String? location;
    for (final line in lines) {
      final parts = line.split(':');
      if (parts.length >= 2 && parts[0].trim().toLowerCase() == 'location') {
        location = line.substring(line.indexOf(':') + 1).trim();
        break;
      }
    }

    if (location == null || location.isEmpty) return;

    // Check if we already processed this location URL
    if (_discoveredDevices.any((d) => d.locationUrl == location)) return;

    try {
      // Fetch device description XML
      final uri = Uri.parse(location);
      final res = await http.get(uri).timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final xmlBody = res.body;

        // Parse friendlyName
        final nameMatch = RegExp(r'<friendlyName>(.*?)</friendlyName>', caseSensitive: false).firstMatch(xmlBody);
        final friendlyName = nameMatch?.group(1) ?? 'Unknown DLNA Device';

        // Parse AVTransport service control URL
        // Locate the service description block containing AVTransport:1
        final avtBlockRegex = RegExp(
          r'<service>(?:[ \t\r\n]*?<[^>]+>)*?[ \t\r\n]*?<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>(?:[ \t\r\n]*?<[^>]+>)*?[ \t\r\n]*?</service>',
          caseSensitive: false,
        );
        final avtBlockMatch = avtBlockRegex.firstMatch(xmlBody);
        String? controlPath;

        if (avtBlockMatch != null) {
          final block = avtBlockMatch.group(0)!;
          final ctrlMatch = RegExp(r'<controlURL>(.*?)</controlURL>', caseSensitive: false).firstMatch(block);
          controlPath = ctrlMatch?.group(1);
        } else {
          // Fallback simple search if service block is differently formatted
          final fallbackMatch = RegExp(r'<controlURL>(.*?)</controlURL>', caseSensitive: false).firstMatch(xmlBody);
          controlPath = fallbackMatch?.group(1);
        }

        if (controlPath == null || controlPath.isEmpty) return;

        // Resolve absolute control URL
        String controlUrl;
        if (controlPath.startsWith('http://') || controlPath.startsWith('https://')) {
          controlUrl = controlPath;
        } else {
          final baseUri = Uri.parse('${uri.scheme}://${uri.host}:${uri.port}');
          if (controlPath.startsWith('/')) {
            controlUrl = baseUri.resolve(controlPath).toString();
          } else {
            // Find base path from location url
            final locPath = uri.path;
            final basePath = locPath.substring(0, locPath.lastIndexOf('/') + 1);
            controlUrl = baseUri.resolve(basePath + controlPath).toString();
          }
        }

        final device = CastDevice(
          name: friendlyName,
          locationUrl: location,
          controlUrl: controlUrl,
        );

        if (!_discoveredDevices.contains(device)) {
          _discoveredDevices.add(device);
          _devicesController.add(List.from(_discoveredDevices));
          print('[CastService] Discovered device: "${device.name}" controlUrl: ${device.controlUrl}');
        }
      }
    } catch (e) {
      // Ignore failures fetching metadata for individual devices
    }
  }

  /// Sends SetAVTransportURI SOAP action to TV.
  Future<bool> castVideo(CastDevice device, String videoUrl, {String? title}) async {
    try {
      final translatedUrl = await translateUrl(videoUrl);
      print('[CastService] Casting URL: $translatedUrl to "${device.name}"');

      // Stop any existing playback first to reset state
      await stopVideo(device);

      final envelope = '<?xml version="1.0" encoding="utf-8"?>\r\n'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\r\n'
          '  <s:Body>\r\n'
          '    <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">\r\n'
          '      <InstanceID>0</InstanceID>\r\n'
          '      <CurrentURI>${_escapeXml(translatedUrl)}</CurrentURI>\r\n'
          '      <CurrentURIMetaData>${_buildMetadata(translatedUrl, title ?? "Streaming Video")}</CurrentURIMetaData>\r\n'
          '    </u:SetAVTransportURI>\r\n'
          '  </s:Body>\r\n'
          '</s:Envelope>';

      final headers = {
        'SOAPACTION': '"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"',
        'Content-Type': 'text/xml; charset="utf-8"',
        'Connection': 'close',
      };

      final response = await http
          .post(
            Uri.parse(device.controlUrl),
            headers: headers,
            body: utf8.encode(envelope),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        // Send play command
        return await playVideo(device);
      } else {
        print('[CastService] SetAVTransportURI failed with code ${response.statusCode}: ${response.body}');
        return false;
      }
    } catch (e) {
      print('[CastService] Error casting video: $e');
      return false;
    }
  }

  /// Sends Play SOAP action to TV.
  Future<bool> playVideo(CastDevice device) async {
    try {
      final envelope = '<?xml version="1.0" encoding="utf-8"?>\r\n'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\r\n'
          '  <s:Body>\r\n'
          '    <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">\r\n'
          '      <InstanceID>0</InstanceID>\r\n'
          '      <Speed>1</Speed>\r\n'
          '    </u:Play>\r\n'
          '  </s:Body>\r\n'
          '</s:Envelope>';

      final headers = {
        'SOAPACTION': '"urn:schemas-upnp-org:service:AVTransport:1#Play"',
        'Content-Type': 'text/xml; charset="utf-8"',
        'Connection': 'close',
      };

      final response = await http
          .post(
            Uri.parse(device.controlUrl),
            headers: headers,
            body: utf8.encode(envelope),
          )
          .timeout(const Duration(seconds: 5));

      return response.statusCode == 200;
    } catch (e) {
      print('[CastService] Play action failed: $e');
      return false;
    }
  }

  /// Sends Stop SOAP action to TV.
  Future<bool> stopVideo(CastDevice device) async {
    try {
      final envelope = '<?xml version="1.0" encoding="utf-8"?>\r\n'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\r\n'
          '  <s:Body>\r\n'
          '    <u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">\r\n'
          '      <InstanceID>0</InstanceID>\r\n'
          '    </u:Stop>\r\n'
          '  </s:Body>\r\n'
          '</s:Envelope>';

      final headers = {
        'SOAPACTION': '"urn:schemas-upnp-org:service:AVTransport:1#Stop"',
        'Content-Type': 'text/xml; charset="utf-8"',
        'Connection': 'close',
      };

      final response = await http
          .post(
            Uri.parse(device.controlUrl),
            headers: headers,
            body: utf8.encode(envelope),
          )
          .timeout(const Duration(seconds: 4));

      return response.statusCode == 200;
    } catch (e) {
      print('[CastService] Stop action failed: $e');
      return false;
    }
  }

  String _escapeXml(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  String _buildMetadata(String url, String title) {
    final escapedUrl = _escapeXml(url);
    final escapedTitle = _escapeXml(title);
    final didl = '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">'
        '<item id="0" parentID="-1" restricted="1">'
        '<dc:title>$escapedTitle</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '<res protocolInfo="http-get:*:video/mp4:DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000">$escapedUrl</res>'
        '</item>'
        '</DIDL-Lite>';
    return _escapeXml(didl);
  }
}
