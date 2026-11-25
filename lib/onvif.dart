import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// One ONVIF media profile = one stream the camera offers (main / sub …).
class OnvifProfile {
  OnvifProfile(this.token, this.name, this.enc, this.width, this.height, this.fps);
  final String token, name, enc, fps;
  final int width, height;

  int get pixels => width * height;
  String get label =>
      '${name.isEmpty ? token : name} · ${width > 0 ? '$width×$height' : 'unknown size'}'
      '${enc.isEmpty ? '' : ' · $enc'}${fps.isEmpty ? '' : ' · $fps fps'}';
}

/// Direct child elements by local name (XML prefixes like tt: are ignored).
Iterable<XmlElement> _kids(XmlElement e, String local) =>
    e.childElements.where((c) => c.name.local == local);

class RecInfo {
  RecInfo(this.token, this.name, this.start, this.end);
  final String token, name;
  final DateTime? start, end;
}

class PtzPreset {
  PtzPreset(this.token, this.name);
  final String token, name;
}

/// Minimal ONVIF client: capabilities, profiles, stream URI, PTZ, presets.
class Onvif {
  Onvif(this.deviceUrl, this.user, this.pass, {this.onLog});

  final String deviceUrl, user, pass;
  final void Function(String)? onLog;
  int _mode = 0; // 0 WSSE digest, 1 HTTP digest/basic, 2 WSSE plain text
  String? _mediaUrl, _ptzUrl, _token, _searchUrl, _replayUrl;
  List<OnvifProfile> _profiles = [];
  String? lastLabel; // description of the profile last returned by streamUri
  List<OnvifProfile> get profiles => List.unmodifiable(_profiles);
  Duration _skew = Duration.zero; // camera clock minus phone clock

  bool get hasPtz => _ptzUrl != null;
  bool get hasSearch => _searchUrl != null && _replayUrl != null;

  // ---------------------------------------------------------------- discovery

  /// WS-Discovery over UDP multicast. Returns ONVIF device_service URLs.
  static Future<List<String>> discover(
      {Duration wait = const Duration(seconds: 4)}) async {
    final found = <String>{};
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final sub = sock.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      final dg = sock.receive();
      if (dg == null) return;
      try {
        final doc = XmlDocument.parse(utf8.decode(dg.data));
        for (final x in doc.descendantElements
            .where((e) => e.name.local == 'XAddrs')) {
          final urls = x.innerText.trim().split(RegExp(r'\s+'));
          final u = urls.firstWhere(
              (u) => u.startsWith('http') && !u.contains('['),
              orElse: () => '');
          if (u.isNotEmpty) found.add(u);
        }
      } catch (_) {}
    });

    final rnd = Random();
    String hex(int n) =>
        List.generate(n, (_) => rnd.nextInt(16).toRadixString(16)).join();
    final probe = '<?xml version="1.0" encoding="UTF-8"?>'
        '<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
        'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" '
        'xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><e:Header>'
        '<w:MessageID>uuid:${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}</w:MessageID>'
        '<w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>'
        '<w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>'
        '</e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types>'
        '</d:Probe></e:Body></e:Envelope>';
    final data = utf8.encode(probe);
    final group = InternetAddress('239.255.255.250');
    sock.send(data, group, 3702);
    await Future.delayed(const Duration(milliseconds: 800));
    sock.send(data, group, 3702);

    await Future.delayed(wait);
    await sub.cancel();
    sock.close();
    return found.toList();
  }

  /// Fallback for cameras/routers that block multicast: scan /24 for RTSP.
  static Future<List<String>> scanRtsp() async {
    final out = <String>{};
    for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in ni.addresses) {
        if (a.isLoopback || a.address.startsWith('169.254')) continue;
        final pre = a.address.split('.').take(3).join('.');
        await Future.wait(List.generate(254, (i) async {
          final ip = '$pre.${i + 1}';
          for (final port in const [554, 8554]) {
            try {
              final s = await Socket.connect(ip, port,
                  timeout: const Duration(milliseconds: 600));
              s.destroy();
              out.add(ip);
              break;
            } catch (_) {}
          }
        }));
      }
    }
    return out.toList();
  }

  /// Looks for the ONVIF service of [host] on all the usual ports.
  static Future<({Onvif? onvif, String? error})> find(
      String host, String user, String pass,
      {void Function(String)? onLog}) async {
    final open = <int>[];
    String? lastErr;
    for (final port in const [80, 8080, 2020, 8000, 8899, 5000, 8999, 8081, 10080]) {
      try {
        final s = await Socket.connect(host, port,
            timeout: const Duration(milliseconds: 700));
        s.destroy();
      } catch (_) {
        continue;
      }
      open.add(port);
      onLog?.call('Trying ONVIF on $host:$port');
      final o = Onvif('http://$host:$port/onvif/device_service', user, pass, onLog: onLog);
      try {
        await o.init().timeout(const Duration(seconds: 7));
        return (onvif: o, error: null);
      } catch (e) {
        lastErr = 'port $port: $e';
      }
    }
    if (open.isEmpty) {
      return (
        onvif: null,
        error: 'No ONVIF port is open on $host (tried 80, 8080, 2020, 8000, 8899…). '
            'Enable ONVIF in the camera settings, or set the ONVIF port by editing the camera.'
      );
    }
    return (onvif: null, error: 'ONVIF did not accept the login → $lastErr');
  }

  // --------------------------------------------------------------------- SOAP

  void _log(String m) => onLog?.call(m);

  String _md5(String s) => md5.convert(utf8.encode(s)).toString();

  String _envelope(String body, {bool auth = true, bool text = false}) {
    var header = '';
    if (auth) {
      const w = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-';
      final rnd = Random.secure();
      final nonce = List<int>.generate(16, (_) => rnd.nextInt(256));
      final now = DateTime.now().toUtc().add(_skew);
      final created = '${now.toIso8601String().split('.').first}Z';
      final pw = text
          ? '<Password Type="${w}username-token-profile-1.0#PasswordText">${_esc(pass)}</Password>'
          : '<Password Type="${w}username-token-profile-1.0#PasswordDigest">'
              '${base64.encode(sha1.convert([...nonce, ...utf8.encode(created), ...utf8.encode(pass)]).bytes)}</Password>';
      header = '<s:Header><Security s:mustUnderstand="1" xmlns="${w}wssecurity-secext-1.0.xsd">'
          '<UsernameToken><Username>${_esc(user)}</Username>$pw'
          '<Nonce EncodingType="${w}soap-message-security-1.0#Base64Binary">${base64.encode(nonce)}</Nonce>'
          '<Created xmlns="${w}wssecurity-utility-1.0.xsd">$created</Created>'
          '</UsernameToken></Security></s:Header>';
    }
    return '<?xml version="1.0" encoding="UTF-8"?>'
        '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">$header'
        '<s:Body>$body</s:Body></s:Envelope>';
  }

  String _digest(String challenge, Uri uri) {
    String? g(String k) => RegExp('$k="?([^",]+)"?').firstMatch(challenge)?.group(1);
    final realm = g('realm') ?? '', nonce = g('nonce') ?? '';
    final qop = g('qop'), opaque = g('opaque');
    final path = uri.path + (uri.hasQuery ? '?${uri.query}' : '');
    final ha1 = _md5('$user:$realm:$pass'), ha2 = _md5('POST:$path');
    var extra = '';
    String resp;
    if (qop != null && qop.contains('auth')) {
      const nc = '00000001';
      final rnd = Random.secure();
      final cn = List.generate(8, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      resp = _md5('$ha1:$nonce:$nc:$cn:auth:$ha2');
      extra = ', qop=auth, nc=$nc, cnonce="$cn"';
    } else {
      resp = _md5('$ha1:$nonce:$ha2');
    }
    return 'Digest username="$user", realm="$realm", nonce="$nonce", uri="$path", '
        'response="$resp"${opaque != null ? ', opaque="$opaque"' : ''}$extra';
  }

  static const _hdr = {'Content-Type': 'application/soap+xml; charset=utf-8'};
  static const _t = Duration(seconds: 8);

  Future<http.Response> _send(String url, String body, int mode) async {
    final uri = Uri.parse(url);
    if (mode == 1) {
      final env = _envelope(body, auth: false);
      var r = await http.post(uri, headers: _hdr, body: env).timeout(_t);
      if (r.statusCode == 401) {
        final ch = r.headers['www-authenticate'] ?? '';
        final lc = ch.toLowerCase();
        if (lc.startsWith('digest')) {
          r = await http
              .post(uri, headers: {..._hdr, 'Authorization': _digest(ch, uri)}, body: env)
              .timeout(_t);
        } else if (lc.startsWith('basic')) {
          r = await http
              .post(uri,
                  headers: {..._hdr, 'Authorization': 'Basic ${base64.encode(utf8.encode('$user:$pass'))}'},
                  body: env)
              .timeout(_t);
        }
      }
      return r;
    }
    return http.post(uri, headers: _hdr, body: _envelope(body, text: mode == 2)).timeout(_t);
  }

  bool _authFail(http.Response r) {
    final b = r.body.toLowerCase();
    return r.statusCode == 401 || b.contains('authoriz') || b.contains('notauthorized');
  }

  String _why(http.Response r) {
    var why = '';
    try {
      final t = XmlDocument.parse(r.body).descendantElements.where((e) => e.name.local == 'Text');
      if (t.isNotEmpty) why = ' – ${t.first.innerText.trim()}';
    } catch (_) {}
    if (_authFail(r)) why = ' – login rejected (wrong username/password, or not an ONVIF-enabled account)$why';
    return 'HTTP ${r.statusCode}$why';
  }

  static const _modeName = ['wsse-digest', 'http-digest', 'wsse-text'];

  /// Sends a SOAP call. If the camera rejects the login, the other
  /// authentication styles cameras use are tried automatically.
  Future<XmlDocument> _call(String url, String body, {bool auth = true}) async {
    final path = Uri.parse(url).path;
    final modes = auth ? [_mode, ...[0, 1, 2].where((m) => m != _mode)] : [-1];
    var err = 'no response';
    for (final m in modes) {
      final r = m == -1
          ? await http
              .post(Uri.parse(url), headers: _hdr, body: _envelope(body, auth: false))
              .timeout(_t)
          : await _send(url, body, m);
      _log('POST $path [${m == -1 ? 'no-auth' : _modeName[m]}] → ${r.statusCode}');
      if (r.statusCode == 200) {
        if (auth) _mode = m;
        return XmlDocument.parse(r.body);
      }
      err = _why(r);
      final snip = r.body.replaceAll(RegExp(r'\s+'), ' ');
      _log('   ${snip.length > 220 ? snip.substring(0, 220) : snip}');
      if (!_authFail(r)) break;
    }
    throw Exception(err);
  }

  String? _xaddr(XmlDocument d, String service) {
    for (final e in d.descendantElements.where((e) => e.name.local == service)) {
      final x = _kids(e, 'XAddr');
      if (x.isNotEmpty) return x.first.innerText.trim();
    }
    return null;
  }

  /// Cameras sometimes report an internal IP in their service URLs.
  String? _fix(String? x) {
    if (x == null) return null;
    final base = Uri.parse(deviceUrl);
    return Uri.parse(x).replace(host: base.host).toString();
  }

  Future<void> _syncClock() async {
    try {
      final r = await _call(
          deviceUrl,
          '<tds:GetSystemDateAndTime xmlns:tds="http://www.onvif.org/ver10/device/wsdl"/>',
          auth: false);
      final u = r.descendantElements.firstWhere((e) => e.name.local == 'UTCDateTime');
      int g(String n) => int.parse(
          u.descendantElements.firstWhere((e) => e.name.local == n).innerText.trim());
      final cam = DateTime.utc(
          g('Year'), g('Month'), g('Day'), g('Hour'), g('Minute'), g('Second'));
      _skew = cam.difference(DateTime.now().toUtc());
    } catch (_) {}
  }

  // --------------------------------------------------------------- operations

  /// Connects: syncs clock, finds service URLs and a PTZ-capable profile.
  Future<void> init() async {
    await _syncClock();
    String? media, ptz, search, replay;
    try {
      final caps = await _call(
          deviceUrl,
          '<tds:GetCapabilities xmlns:tds="http://www.onvif.org/ver10/device/wsdl">'
          '<tds:Category>All</tds:Category></tds:GetCapabilities>');
      media = _fix(_xaddr(caps, 'Media'));
      ptz = _fix(_xaddr(caps, 'PTZ'));
      search = _fix(_xaddr(caps, 'Search'));
      replay = _fix(_xaddr(caps, 'Replay'));
    } catch (e) {
      _log('GetCapabilities failed ($e) – trying GetServices');
      final sv = await _call(
          deviceUrl,
          '<tds:GetServices xmlns:tds="http://www.onvif.org/ver10/device/wsdl">'
          '<tds:IncludeCapability>false</tds:IncludeCapability></tds:GetServices>');
      for (final e in sv.descendantElements.where((e) => e.name.local == 'Service')) {
        String tx(String n) {
          final l = _kids(e, n);
          return l.isEmpty ? '' : l.first.innerText.trim();
        }

        if (tx('Namespace').endsWith('/media/wsdl')) media = _fix(tx('XAddr'));
        if (tx('Namespace').endsWith('/ptz/wsdl')) ptz = _fix(tx('XAddr'));
        if (tx('Namespace').endsWith('/search/wsdl')) search = _fix(tx('XAddr'));
        if (tx('Namespace').endsWith('/replay/wsdl')) replay = _fix(tx('XAddr'));
      }
    }
    _mediaUrl = media ?? deviceUrl;
    _ptzUrl = ptz;
    _searchUrl = search;
    _replayUrl = replay;

    final prof = await _call(_mediaUrl!,
        '<trt:GetProfiles xmlns:trt="http://www.onvif.org/ver10/media/wsdl"/>');
    final profiles =
        prof.descendantElements.where((e) => e.name.local == 'Profiles').toList();
    if (profiles.isEmpty) throw Exception('Camera returned no media profiles');
    final withPtz = profiles.where(
        (p) => p.descendantElements.any((e) => e.name.local == 'PTZConfiguration'));
    final pick = withPtz.isNotEmpty ? withPtz.first : profiles.first;
    _token = pick.getAttribute('token');
    if (_ptzUrl == null && withPtz.isNotEmpty) {
      final b = Uri.parse(deviceUrl);
      _ptzUrl = '${b.scheme}://${b.authority}/onvif/ptz_service';
      _log('PTZ address not reported; guessing $_ptzUrl');
    }
    _log('Profile ${_token} · PTZ ${_ptzUrl ?? 'none'}');
    _profiles = profiles.map((pr) {
      final venc = _kids(pr, 'VideoEncoderConfiguration');
      final scope = venc.isNotEmpty ? venc.first : pr;
      String tx(String n) {
        final l = scope.descendantElements.where((e) => e.name.local == n);
        return l.isEmpty ? '' : l.first.innerText.trim();
      }

      final nm = _kids(pr, 'Name');
      return OnvifProfile(
          pr.getAttribute('token') ?? '',
          nm.isEmpty ? '' : nm.first.innerText.trim(),
          tx('Encoding').toUpperCase(),
          int.tryParse(tx('Width')) ?? 0,
          int.tryParse(tx('Height')) ?? 0,
          tx('FrameRateLimit'));
    }).toList();
    for (final pr in _profiles) {
      _log('Stream: ${pr.label}');
    }
  }

  /// sub=true: the smallest picture (H.264 preferred, best compatibility).
  /// sub=false: the biggest picture, whatever its codec (H.264 or H.265).
  Future<String> streamUri({bool sub = true}) async {
    final list = [..._profiles]..sort((a, b) => a.pixels.compareTo(b.pixels));
    if (list.isEmpty) throw Exception('Camera returned no streams');
    OnvifProfile pick;
    if (sub) {
      final h264 = list.where((p) => p.enc.contains('264')).toList();
      pick = h264.isNotEmpty ? h264.first : list.first;
    } else {
      pick = list.last;
    }
    return streamUriFor(pick.token);
  }

  /// RTSP address of one specific stream/profile.
  Future<String> streamUriFor(String token) async {
    final r = await _call(
        _mediaUrl!,
        '<trt:GetStreamUri xmlns:trt="http://www.onvif.org/ver10/media/wsdl" '
        'xmlns:tt="http://www.onvif.org/ver10/schema"><trt:StreamSetup>'
        '<tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol>'
        '</tt:Transport></trt:StreamSetup><trt:ProfileToken>$token</trt:ProfileToken>'
        '</trt:GetStreamUri>');
    var uri = r.descendantElements.firstWhere((e) => e.name.local == 'Uri').innerText.trim();
    // some cameras report an internal/wrong IP in the stream address
    final u = Uri.tryParse(uri);
    final dev = Uri.parse(deviceUrl).host;
    if (u != null && u.host.isNotEmpty && u.host != dev) uri = u.replace(host: dev).toString();
    final match = _profiles.where((p) => p.token == token);
    lastLabel = match.isEmpty ? null : match.first.label;
    _log('Stream ${lastLabel ?? token} → ${uri.replaceFirst(RegExp(r'//[^@/]*@'), '//')}');
    return uri;
  }

  static const _ptzNs = 'xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl" '
      'xmlns:tt="http://www.onvif.org/ver10/schema"';

  String _esc(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  /// Speeds are -1.0 .. 1.0. Pan: +right, Tilt: +up, Zoom: +in.
  Future<void> move(double pan, double tilt, double zoom) async {
    if (_ptzUrl == null) return;
    String f(double v) => v.toStringAsFixed(2);
    final pt = (pan != 0 || tilt != 0) ? '<tt:PanTilt x="${f(pan)}" y="${f(tilt)}"/>' : '';
    final zm = zoom != 0 ? '<tt:Zoom x="${f(zoom)}"/>' : '';
    await _call(
        _ptzUrl!,
        '<tptz:ContinuousMove $_ptzNs><tptz:ProfileToken>$_token</tptz:ProfileToken>'
        '<tptz:Velocity>$pt$zm</tptz:Velocity></tptz:ContinuousMove>');
  }

  Future<void> stop() async {
    if (_ptzUrl == null) return;
    await _call(
        _ptzUrl!,
        '<tptz:Stop $_ptzNs><tptz:ProfileToken>$_token</tptz:ProfileToken>'
        '<tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>true</tptz:Zoom></tptz:Stop>');
  }

  Future<void> gotoHome() async {
    if (_ptzUrl == null) return;
    await _call(_ptzUrl!,
        '<tptz:GotoHomePosition $_ptzNs><tptz:ProfileToken>$_token</tptz:ProfileToken></tptz:GotoHomePosition>');
  }

  Future<List<PtzPreset>> presets() async {
    if (_ptzUrl == null) return [];
    final r = await _call(_ptzUrl!,
        '<tptz:GetPresets $_ptzNs><tptz:ProfileToken>$_token</tptz:ProfileToken></tptz:GetPresets>');
    return r.descendantElements.where((e) => e.name.local == 'Preset').map((e) {
      final token = e.getAttribute('token') ?? '';
      final n = _kids(e, 'Name');
      return PtzPreset(token, n.isNotEmpty ? n.first.innerText : 'Preset $token');
    }).toList();
  }

  Future<void> gotoPreset(String token) async {
    if (_ptzUrl == null) return;
    await _call(
        _ptzUrl!,
        '<tptz:GotoPreset $_ptzNs><tptz:ProfileToken>$_token</tptz:ProfileToken>'
        '<tptz:PresetToken>$token</tptz:PresetToken></tptz:GotoPreset>');
  }

  Future<void> savePreset(String name) async {
    if (_ptzUrl == null) return;
    await _call(
        _ptzUrl!,
        '<tptz:SetPreset $_ptzNs><tptz:ProfileToken>$_token</tptz:ProfileToken>'
        '<tptz:PresetName>${_esc(name)}</tptz:PresetName></tptz:SetPreset>');
  }

  // ------------------------------------------------- camera SD card (Profile G)

  DateTime? _dt(String s) => DateTime.tryParse(s.trim())?.toLocal();

  /// Lists recordings stored on the camera (SD card) – only cameras that
  /// implement ONVIF Profile G answer this.
  Future<List<RecInfo>> recordings() async {
    if (_searchUrl == null) {
      throw Exception('This camera does not offer SD-card search over ONVIF (Profile G).');
    }
    const ns = 'xmlns:tse="http://www.onvif.org/ver10/search/wsdl"';
    final f = await _call(
        _searchUrl!,
        '<tse:FindRecordings $ns><tse:Scope/><tse:KeepAliveTime>PT30S</tse:KeepAliveTime>'
        '</tse:FindRecordings>');
    final tok = f.descendantElements.firstWhere((e) => e.name.local == 'SearchToken').innerText.trim();
    final r = await _call(
        _searchUrl!,
        '<tse:GetRecordingSearchResults $ns><tse:SearchToken>$tok</tse:SearchToken>'
        '<tse:MinResults>1</tse:MinResults><tse:MaxResults>100</tse:MaxResults>'
        '<tse:WaitTime>PT5S</tse:WaitTime></tse:GetRecordingSearchResults>');
    final out = <RecInfo>[];
    for (final e in r.descendantElements.where((e) => e.name.local == 'RecordingInformation')) {
      String tx(String n) {
        final l = e.descendantElements.where((x) => x.name.local == n);
        return l.isEmpty ? '' : l.first.innerText.trim();
      }

      out.add(RecInfo(tx('RecordingToken'), tx('Name'), _dt(tx('EarliestRecording')), _dt(tx('LatestRecording'))));
    }
    return out;
  }

  Future<String> replayUri(String token) async {
    if (_replayUrl == null) throw Exception('No replay service on this camera');
    final r = await _call(
        _replayUrl!,
        '<trp:GetReplayUri xmlns:trp="http://www.onvif.org/ver10/replay/wsdl" '
        'xmlns:tt="http://www.onvif.org/ver10/schema"><trp:StreamSetup>'
        '<tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol>'
        '</tt:Transport></trp:StreamSetup><trp:RecordingToken>$token</trp:RecordingToken>'
        '</trp:GetReplayUri>');
    return r.descendantElements.firstWhere((e) => e.name.local == 'Uri').innerText.trim();
  }
}
