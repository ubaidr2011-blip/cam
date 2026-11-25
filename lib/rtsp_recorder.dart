import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// A failure that retrying will not fix (wrong password, unsupported codec…).
class _Fatal implements Exception {
  _Fatal(this.msg);
  final String msg;
  @override
  String toString() => msg;
}

class _Resp {
  _Resp(this.code, this.h, this.body);
  final int code;
  final Map<String, String> h;
  final String body;
}

class _ByteBuf {
  Uint8List _d = Uint8List(1 << 16);
  int _s = 0, _e = 0;

  int get length => _e - _s;
  int operator [](int i) => _d[_s + i];

  void add(List<int> b) {
    if (_e + b.length > _d.length) {
      final n = length;
      if (_s > 0 && n + b.length <= _d.length) {
        _d.setRange(0, n, _d, _s);
      } else {
        final nd = Uint8List(math.max(_d.length * 2, n + b.length));
        nd.setRange(0, n, _d, _s);
        _d = nd;
      }
      _s = 0;
      _e = n;
    }
    _d.setRange(_e, _e + b.length, b);
    _e += b.length;
  }

  Uint8List take(int n) {
    final r = _d.sublist(_s, _s + n);
    drop(n);
    return r;
  }

  Uint8List peek(int n) => Uint8List.sublistView(_d, _s, _s + n);

  void drop(int n) {
    _s += n;
    if (_s >= _e) {
      _s = 0;
      _e = 0;
    }
  }

  /// Index just after the first CRLFCRLF, or -1.
  int headerEnd() {
    for (var i = 0; i + 3 < length; i++) {
      if (_d[_s + i] == 13 && _d[_s + i + 1] == 10 && _d[_s + i + 2] == 13 && _d[_s + i + 3] == 10) {
        return i + 4;
      }
    }
    return -1;
  }
}

/// Records an RTSP camera (H.264 / H.265) straight to MPEG-TS files, with no
/// dependency on any media library. Video only, original quality, no re-encode.
class RtspRecorder {
  RtspRecorder({
    required this.url,
    required this.dir,
    required this.name,
    required this.segmentMin,
    this.onFile,
    this.onStatus,
    this.onFatal,
    this.onProgress,
    this.onLog,
    this.onBusy,
  });

  final String url, name;
  final Directory dir;
  final int segmentMin; // 0 = single file
  final void Function(String path)? onFile;
  final void Function(String status)? onStatus;
  final void Function(String message)? onFatal;
  final void Function(int bytes)? onProgress;
  final void Function(String line)? onLog;
  final void Function()? onBusy; // camera refused a second stream

  bool _stop = false;
  int totalBytes = 0;

  // connection
  Socket? _sock;
  _ByteBuf _buf = _ByteBuf();
  Completer<_Resp>? _pending;
  int _cseq = 0, _nc = 0, _rtpCh = 0;
  String _user = '', _pass = '', _base = '', _sid = '';
  Map<String, String>? _challenge;
  DateTime _lastData = DateTime.now();
  bool _gotMedia = false, _busyReported = false;
  String _lastErr = '';
  DateTime? _waitStart;

  void _log(String m) => onLog?.call(m);

  // stream description
  bool _h264 = true;
  int _pt = 96;
  final List<Uint8List> _params = [];

  // access-unit assembly
  List<Uint8List> _au = [];
  int? _auTs, _lastSeq;
  bool _auCorrupt = false, _needKey = true;
  BytesBuilder? _fu;

  // timestamps
  int? _lastTs;
  int _ext = 0;

  // output
  RandomAccessFile? _raf;
  DateTime? _fileStart;
  DateTime _lastFlush = DateTime.now();
  final Map<int, int> _cc = {};
  static const int _pmtPid = 0x1000, _vPid = 0x0100;
  static final Uint8List _sc = Uint8List.fromList([0, 0, 0, 1]);

  // ------------------------------------------------------------------- control

  Future<void> run() async {
    var failures = 0;
    while (!_stop) {
      try {
        onStatus?.call(failures == 0 ? 'Connecting…' : 'Reconnecting… ($_lastErr)');
        await _session();
      } on _Fatal catch (e) {
        _closeFile();
        if (!_stop) onFatal?.call(e.msg);
        return;
      } catch (e) {
        _lastErr = '$e'.replaceFirst('Exception: ', '');
        _log('Error: $_lastErr');
      }
      if (_stop) break;
      failures = _gotMedia ? 1 : failures + 1;
      if (failures > 30) {
        _closeFile();
        onFatal?.call('Camera not reachable: $_lastErr');
        return;
      }
      await Future.delayed(Duration(seconds: math.min(10, 2 + failures)));
    }
    _closeFile();
  }

  Future<void> stop() async {
    if (_stop) return;
    _stop = true;
    try {
      if (_sid.isNotEmpty) _sock?.add(utf8.encode(_build('TEARDOWN', _base, {'Session': _sid})));
    } catch (_) {}
    _closeFile();
    try {
      _sock?.destroy();
    } catch (_) {}
  }

  // ------------------------------------------------------------------- session

  Future<void> _session() async {
    _gotMedia = false;
    _buf = _ByteBuf();
    _challenge = null;
    _cseq = 0;
    _nc = 0;
    _sid = '';
    _au = [];
    _auTs = null;
    _lastSeq = null;
    _fu = null;
    _needKey = true;
    _auCorrupt = false;
    _params.clear();

    final u = Uri.parse(url);
    final port = u.hasPort ? u.port : 554;
    final ui = u.userInfo;
    if (ui.isNotEmpty) {
      final i = ui.indexOf(':');
      _user = Uri.decodeComponent(i < 0 ? ui : ui.substring(0, i));
      _pass = i < 0 ? '' : Uri.decodeComponent(ui.substring(i + 1));
    }
    _base = 'rtsp://${u.host}:$port${u.path.isEmpty ? '/' : u.path}${u.hasQuery ? '?${u.query}' : ''}';

    final sock = await Socket.connect(u.host, port, timeout: const Duration(seconds: 8));
    sock.setOption(SocketOption.tcpNoDelay, true);
    _sock = sock;
    final done = Completer<void>();
    final sub = sock.listen((d) {
      try {
        _buf.add(d);
        _lastData = DateTime.now();
        _parse();
      } catch (e) {
        if (!done.isCompleted) done.completeError(e);
      }
    }, onDone: () {
      if (!done.isCompleted) done.complete();
    }, onError: (e) {
      if (!done.isCompleted) done.completeError(e as Object);
    }, cancelOnError: true);

    Timer? keep, watch;
    try {
      await _handshake().timeout(const Duration(seconds: 30));
      onStatus?.call('Waiting for keyframe…');
      _lastData = DateTime.now();
      keep = Timer.periodic(const Duration(seconds: 20), (_) => _keepAlive());
      watch = Timer.periodic(const Duration(seconds: 5), (_) {
        if (DateTime.now().difference(_lastData).inSeconds > 12 && !done.isCompleted) {
          done.completeError(Exception('No data from the camera for 12 seconds'));
        }
      });
      await done.future;
    } finally {
      keep?.cancel();
      watch?.cancel();
      await sub.cancel();
      try {
        sock.destroy();
      } catch (_) {}
      _sock = null;
    }
  }

  Future<void> _handshake() async {
    var r = await _req('DESCRIBE', _base, {'Accept': 'application/sdp'});
    if (r.code == 401) throw _Fatal('Camera rejected the username/password (RTSP 401).');
    if (r.code == 404) throw _Fatal('Stream path not found (RTSP 404). Edit the camera and use Auto-detect.');
    _checkBusy(r, 'DESCRIBE');
    if (r.code != 200) throw Exception('DESCRIBE failed (RTSP ${r.code})');
    final base = r.h['content-base'] ?? r.h['content-location'] ?? _base;
    final control = _parseSdp(r.body);
    _log('Video: ${_h264 ? 'H.264' : 'H.265'}, payload $_pt, ${_params.length} parameter sets');
    final setupUrl = _resolve(base, control);
    r = await _req('SETUP', setupUrl, {'Transport': 'RTP/AVP/TCP;unicast;interleaved=0-1'});
    if (r.code == 401) throw _Fatal('Camera rejected the username/password (RTSP 401).');
    _checkBusy(r, 'SETUP');
    if (r.code != 200) throw Exception('SETUP failed (RTSP ${r.code})');
    _sid = (r.h['session'] ?? '').split(';').first.trim();
    final tr = r.h['transport'] ?? '';
    final m = RegExp(r'interleaved=(\d+)').firstMatch(tr);
    _rtpCh = m != null ? int.parse(m.group(1)!) : 0;
    final play = {if (_sid.isNotEmpty) 'Session': _sid, 'Range': 'npt=0.000-'};
    r = await _req('PLAY', base, play);
    _checkBusy(r, 'PLAY');
    if (r.code != 200) throw Exception('PLAY failed (RTSP ${r.code})');
    _waitStart = DateTime.now();
  }

  /// Many cheap cameras allow only one or two streams at once.
  void _checkBusy(_Resp r, String step) {
    if (r.code == 453 || r.code == 503 || r.code == 454) {
      if (!_busyReported) {
        _busyReported = true;
        onBusy?.call();
      }
      throw Exception('Camera has no free stream slot ($step → RTSP ${r.code})');
    }
  }

  void _keepAlive() {
    try {
      _sock?.add(utf8.encode(_build('OPTIONS', _base, {if (_sid.isNotEmpty) 'Session': _sid})));
    } catch (_) {}
  }

  // ---------------------------------------------------------------------- RTSP

  String _build(String method, String uri, Map<String, String> extra) {
    final b = StringBuffer('$method $uri RTSP/1.0\r\nCSeq: ${++_cseq}\r\nUser-Agent: LanCam/1.0\r\n');
    final a = _authHeader(method, uri);
    if (a != null) b.write('Authorization: $a\r\n');
    extra.forEach((k, v) => b.write('$k: $v\r\n'));
    b.write('\r\n');
    return b.toString();
  }

  String _md5(String s) => md5.convert(utf8.encode(s)).toString();

  String? _authHeader(String method, String uri) {
    final ch = _challenge;
    if (ch == null || _user.isEmpty) return null;
    if (ch['scheme'] == 'basic') return 'Basic ${base64.encode(utf8.encode('$_user:$_pass'))}';
    final realm = ch['realm'] ?? '', nonce = ch['nonce'] ?? '';
    final ha1 = _md5('$_user:$realm:$_pass'), ha2 = _md5('$method:$uri');
    final qop = ch['qop'];
    final opaque = ch['opaque'];
    if (qop != null && qop.contains('auth')) {
      final nc = (++_nc).toRadixString(16).padLeft(8, '0');
      final cn = _md5('${DateTime.now().microsecondsSinceEpoch}').substring(0, 16);
      final resp = _md5('$ha1:$nonce:$nc:$cn:auth:$ha2');
      return 'Digest username="$_user", realm="$realm", nonce="$nonce", uri="$uri", '
          'response="$resp", qop=auth, nc=$nc, cnonce="$cn"${opaque != null ? ', opaque="$opaque"' : ''}';
    }
    final resp = _md5('$ha1:$nonce:$ha2');
    return 'Digest username="$_user", realm="$realm", nonce="$nonce", uri="$uri", '
        'response="$resp"${opaque != null ? ', opaque="$opaque"' : ''}';
  }

  void _setChallenge(String header) {
    // header may hold several WWW-Authenticate values joined with \n; prefer Digest
    final lines = header.split('\n');
    final digest = lines.firstWhere((l) => l.toLowerCase().trimLeft().startsWith('digest'), orElse: () => '');
    final line = digest.isNotEmpty ? digest : lines.first;
    String? g(String k) => RegExp('$k="?([^",]+)"?').firstMatch(line)?.group(1);
    _challenge = {
      'scheme': line.toLowerCase().trimLeft().startsWith('basic') ? 'basic' : 'digest',
      if (g('realm') != null) 'realm': g('realm')!,
      if (g('nonce') != null) 'nonce': g('nonce')!,
      if (g('qop') != null) 'qop': g('qop')!,
      if (g('opaque') != null) 'opaque': g('opaque')!,
    };
  }

  Future<_Resp> _req(String method, String uri, Map<String, String> extra) async {
    _Resp? r;
    for (var attempt = 0; attempt < 2; attempt++) {
      final text = _build(method, uri, extra);
      _pending = Completer<_Resp>();
      _sock!.add(utf8.encode(text));
      r = await _pending!.future.timeout(const Duration(seconds: 8));
      _pending = null;
      _log('$method → ${r.code}${attempt == 1 ? ' (with login)' : ''}');
      final wa = r.h['www-authenticate'];
      if (r.code == 401 && attempt == 0 && _user.isNotEmpty && wa != null) {
        _setChallenge(wa);
        continue;
      }
      break;
    }
    return r!;
  }

  String _resolve(String base, String? control) {
    if (control == null || control.isEmpty || control == '*') return base;
    if (control.startsWith('rtsp://')) return control;
    if (control.startsWith('/')) {
      final u = Uri.parse(base);
      return 'rtsp://${u.host}:${u.hasPort ? u.port : 554}$control';
    }
    return base.endsWith('/') ? '$base$control' : '$base/$control';
  }

  /// Reads the first video section. Returns its control attribute.
  String? _parseSdp(String sdp) {
    var inVideo = false, found = false;
    String? control;
    for (final raw in sdp.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.startsWith('m=')) {
        inVideo = !found && line.startsWith('m=video');
        if (inVideo) {
          found = true;
          final parts = line.split(' ');
          if (parts.length > 3) _pt = int.tryParse(parts[3]) ?? 96;
        }
        continue;
      }
      if (!inVideo) continue;
      if (line.startsWith('a=rtpmap:')) {
        final up = line.toUpperCase();
        if (up.contains('H264')) {
          _h264 = true;
        } else if (up.contains('H265') || up.contains('HEVC')) {
          _h264 = false;
        } else {
          throw _Fatal('This camera stream is not H.264/H.265 ($line). Recording needs one of those.');
        }
      } else if (line.startsWith('a=control:')) {
        control = line.substring(10).trim();
      } else if (line.startsWith('a=fmtp:')) {
        final kv = line.substring(line.indexOf(' ') + 1);
        for (final part in kv.split(';')) {
          final eq = part.indexOf('=');
          if (eq < 0) continue;
          final k = part.substring(0, eq).trim().toLowerCase();
          final v = part.substring(eq + 1).trim();
          if (k == 'sprop-parameter-sets') {
            for (final s in v.split(',')) {
              _addParam(s);
            }
          } else if (k == 'sprop-vps' || k == 'sprop-sps' || k == 'sprop-pps') {
            _addParam(v);
          }
        }
      }
    }
    if (!found) throw _Fatal('The camera offers no video stream.');
    return control;
  }

  void _addParam(String b64) {
    try {
      final b = base64.decode(base64.normalize(b64.trim()));
      if (b.isNotEmpty) _params.add(Uint8List.fromList(b));
    } catch (_) {}
  }

  // ------------------------------------------------------------------- parsing

  void _parse() {
    while (_buf.length > 0) {
      final b0 = _buf[0];
      if (b0 == 0x24) {
        if (_buf.length < 4) return;
        final len = (_buf[2] << 8) | _buf[3];
        if (_buf.length < 4 + len) return;
        final ch = _buf[1];
        final frame = _buf.take(4 + len);
        if (ch == _rtpCh) {
          try {
            _onRtp(frame, 4, len);
          } on _Fatal {
            rethrow;
          } catch (_) {}
        }
        continue;
      }
      if (b0 == 0x52) {
        if (_buf.length < 5) return;
        final end = _buf.headerEnd();
        if (end < 0) return;
        final head = utf8.decode(_buf.peek(end), allowMalformed: true);
        final lines = head.split('\r\n');
        final code = int.tryParse(lines.first.split(' ').length > 1 ? lines.first.split(' ')[1] : '') ?? 0;
        final h = <String, String>{};
        for (final l in lines.skip(1)) {
          final i = l.indexOf(':');
          if (i < 0) continue;
          final k = l.substring(0, i).trim().toLowerCase();
          final v = l.substring(i + 1).trim();
          h[k] = h.containsKey(k) ? '${h[k]}\n$v' : v;
        }
        final clen = int.tryParse(h['content-length'] ?? '0') ?? 0;
        if (_buf.length < end + clen) return;
        _buf.drop(end);
        final body = clen > 0 ? utf8.decode(_buf.take(clen), allowMalformed: true) : '';
        final resp = _Resp(code, h, body);
        final pend = _pending;
        if (pend != null && !pend.isCompleted) pend.complete(resp);
        continue;
      }
      _buf.drop(1); // stray byte
    }
  }

  void _onRtp(Uint8List d, int off, int len) {
    if (len < 12) return;
    final b0 = d[off], b1 = d[off + 1];
    if ((b0 >> 6) != 2) return;
    if ((b1 & 0x7F) != _pt) return;
    final marker = (b1 & 0x80) != 0;
    final seq = (d[off + 2] << 8) | d[off + 3];
    final ts = (d[off + 4] << 24) | (d[off + 5] << 16) | (d[off + 6] << 8) | d[off + 7];
    var pos = off + 12 + (b0 & 0x0F) * 4;
    if ((b0 & 0x10) != 0) {
      if (pos + 4 > off + len) return;
      pos += 4 + ((d[pos + 2] << 8) | d[pos + 3]) * 4;
    }
    var end = off + len;
    if ((b0 & 0x20) != 0) end -= d[end - 1];
    if (pos >= end) return;

    final ls = _lastSeq;
    if (ls != null && seq != ((ls + 1) & 0xFFFF)) {
      _fu = null; // packet loss: drop the fragment and the picture it belongs to
      _auCorrupt = true;
    }
    _lastSeq = seq;
    _depay(d, pos, end, ts, marker);
  }

  void _depay(Uint8List d, int p0, int end, int ts, bool marker) {
    if (_auTs != null && ts != _auTs) _flushAu();
    _auTs = ts;
    if (_h264) {
      final t = d[p0] & 0x1F;
      if (t >= 1 && t <= 23) {
        _addNal(Uint8List.sublistView(d, p0, end));
      } else if (t == 24) {
        _aggregate(d, p0 + 1, end);
      } else if (t == 28 && end - p0 >= 2) {
        final ind = d[p0], hdr = d[p0 + 1];
        if ((hdr & 0x80) != 0) {
          _fu = BytesBuilder(copy: true)..addByte((ind & 0xE0) | (hdr & 0x1F));
        }
        final fu = _fu;
        if (fu != null) {
          fu.add(Uint8List.sublistView(d, p0 + 2, end));
          if ((hdr & 0x40) != 0) {
            _addNal(fu.takeBytes());
            _fu = null;
          }
        }
      }
    } else {
      final t = (d[p0] >> 1) & 0x3F;
      if (t < 48) {
        _addNal(Uint8List.sublistView(d, p0, end));
      } else if (t == 48) {
        _aggregate(d, p0 + 2, end);
      } else if (t == 49 && end - p0 >= 3) {
        final hdr = d[p0 + 2];
        if ((hdr & 0x80) != 0) {
          _fu = BytesBuilder(copy: true)
            ..addByte((d[p0] & 0x81) | ((hdr & 0x3F) << 1))
            ..addByte(d[p0 + 1]);
        }
        final fu = _fu;
        if (fu != null) {
          fu.add(Uint8List.sublistView(d, p0 + 3, end));
          if ((hdr & 0x40) != 0) {
            _addNal(fu.takeBytes());
            _fu = null;
          }
        }
      }
    }
    if (marker) _flushAu();
  }

  void _aggregate(Uint8List d, int start, int end) {
    var o = start;
    while (o + 2 <= end) {
      final sz = (d[o] << 8) | d[o + 1];
      o += 2;
      if (sz == 0 || o + sz > end) break;
      _addNal(Uint8List.sublistView(d, o, o + sz));
      o += sz;
    }
  }

  void _addNal(Uint8List nal) {
    if (nal.isNotEmpty) _au.add(nal);
  }

  void _flushAu() {
    final nals = _au;
    final ts = _auTs;
    _au = [];
    _auTs = null;
    if (nals.isEmpty || ts == null) return;
    if (_auCorrupt) {
      _auCorrupt = false;
      _needKey = true;
      return;
    }
    var key = false, hasParams = false;
    for (final n in nals) {
      if (_h264) {
        final t = n[0] & 0x1F;
        if (t == 5) key = true;
        if (t == 7) hasParams = true;
      } else {
        final t = (n[0] >> 1) & 0x3F;
        if (t >= 16 && t <= 21) key = true;
        if (t == 33) hasParams = true;
      }
    }
    if (_needKey && !key) {
      final w = _waitStart;
      if (w != null && DateTime.now().difference(w).inSeconds > 12) {
        key = true; // camera sends keyframes rarely: start on the first picture we get
        _log('No keyframe within 12 s – starting on the first frame');
      } else {
        return;
      }
    }
    if (key) _needKey = false;
    final bb = BytesBuilder(copy: false);
    if (key && !hasParams) {
      for (final ps in _params) {
        bb.add(_sc);
        bb.add(ps);
      }
    }
    for (final n in nals) {
      bb.add(_sc);
      bb.add(n);
    }
    _writeAu(bb.takeBytes(), ts, key);
  }

  // -------------------------------------------------------------------- output

  void _writeAu(Uint8List es, int rtpTs, bool key) {
    if (_stop) return;
    final last = _lastTs;
    if (last == null) {
      _ext = 0;
    } else {
      final diff = (rtpTs - last) & 0xFFFFFFFF;
      _ext += diff < 0x80000000 ? diff : diff - 0x100000000;
    }
    _lastTs = rtpTs;
    final pts = 90000 + _ext;

    final needNew = _raf == null ||
        (key && segmentMin > 0 && DateTime.now().difference(_fileStart!).inSeconds >= segmentMin * 60);
    if (needNew) {
      if (!key) return; // files always start on a keyframe
      _openFile();
    }
    final out = BytesBuilder(copy: false);
    if (key) {
      out.add(_section(0x0000, _pat()));
      out.add(_section(_pmtPid, _pmt()));
    }
    _pes(out, es, pts, key);
    final bytes = out.takeBytes();
    try {
      _raf!.writeFromSync(bytes);
    } catch (e) {
      throw _Fatal('Cannot write to the recording folder: $e');
    }
    totalBytes += bytes.length;
    _gotMedia = true;
    final now = DateTime.now();
    if (now.difference(_lastFlush).inMilliseconds > 1000) {
      _lastFlush = now;
      try {
        _raf!.flushSync();
      } catch (_) {}
      onProgress?.call(totalBytes);
    }
  }

  void _openFile() {
    _closeFile();
    final t = DateTime.now().toIso8601String().split('.').first.replaceAll(':', '-');
    final path = p.join(dir.path, '${name}_$t.ts');
    try {
      _raf = File(path).openSync(mode: FileMode.write);
    } catch (e) {
      throw _Fatal('Cannot create "$path": $e');
    }
    _fileStart = DateTime.now();
    onFile?.call(path);
    onStatus?.call('Recording');
  }

  void _closeFile() {
    try {
      _raf?.flushSync();
      _raf?.closeSync();
    } catch (_) {}
    _raf = null;
  }

  int _nextCc(int pid) {
    final v = _cc[pid] ?? 0;
    _cc[pid] = (v + 1) & 0xF;
    return v;
  }

  int _crc32(List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final b in data) {
      crc ^= b << 24;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 0x80000000) != 0 ? ((crc << 1) ^ 0x04C11DB7) : (crc << 1);
        crc &= 0xFFFFFFFF;
      }
    }
    return crc;
  }

  List<int> _withCrc(List<int> s) {
    final c = _crc32(s);
    return [...s, (c >> 24) & 0xFF, (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF];
  }

  List<int> _pat() {
    const len = 13;
    return _withCrc([
      0x00, 0xB0 | (len >> 8), len & 0xFF,
      0x00, 0x01, 0xC1, 0x00, 0x00, // ts id, version, section numbers
      0x00, 0x01, 0xE0 | (_pmtPid >> 8), _pmtPid & 0xFF, // program 1 → PMT pid
    ]);
  }

  List<int> _pmt() {
    const len = 18;
    return _withCrc([
      0x02, 0xB0 | (len >> 8), len & 0xFF,
      0x00, 0x01, 0xC1, 0x00, 0x00,
      0xE0 | (_vPid >> 8), _vPid & 0xFF, // PCR pid
      0xF0, 0x00, // program info length
      _h264 ? 0x1B : 0x24, 0xE0 | (_vPid >> 8), _vPid & 0xFF, 0xF0, 0x00,
    ]);
  }

  Uint8List _section(int pid, List<int> section) {
    final pkt = Uint8List(188)..fillRange(0, 188, 0xFF);
    pkt[0] = 0x47;
    pkt[1] = 0x40 | ((pid >> 8) & 0x1F);
    pkt[2] = pid & 0xFF;
    pkt[3] = 0x10 | _nextCc(pid);
    pkt[4] = 0x00; // pointer field
    pkt.setRange(5, 5 + section.length, section);
    return pkt;
  }

  void _pes(BytesBuilder out, Uint8List es, int pts33, bool key) {
    final pts = pts33 & 0x1FFFFFFFF;
    final hdr = <int>[
      0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x80, 0x05,
      0x21 | (((pts >> 30) & 0x07) << 1),
      (pts >> 22) & 0xFF,
      (((pts >> 15) & 0x7F) << 1) | 1,
      (pts >> 7) & 0xFF,
      ((pts & 0x7F) << 1) | 1,
    ];
    final all = Uint8List(hdr.length + es.length)
      ..setRange(0, hdr.length, hdr)
      ..setRange(hdr.length, hdr.length + es.length, es);
    final pcr = (pts - 9000) & 0x1FFFFFFFF;
    var pos = 0;
    var first = true;
    while (pos < all.length) {
      final cap = first ? 176 : 184;
      final n = math.min(cap, all.length - pos);
      out.add(_ts(_vPid, first, Uint8List.sublistView(all, pos, pos + n),
          pcr: first ? pcr : null, ra: first && key));
      pos += n;
      first = false;
    }
  }

  Uint8List _ts(int pid, bool pusi, Uint8List payload, {int? pcr, bool ra = false}) {
    final pkt = Uint8List(188);
    pkt[0] = 0x47;
    pkt[1] = (pusi ? 0x40 : 0) | ((pid >> 8) & 0x1F);
    pkt[2] = pid & 0xFF;
    final n = payload.length;
    final space = 184 - n;
    final cc = _nextCc(pid);
    var o = 4;
    if (space == 0 && pcr == null && !ra) {
      pkt[3] = 0x10 | cc;
    } else {
      pkt[3] = 0x30 | cc;
      final afLen = space - 1;
      pkt[o++] = afLen;
      if (afLen > 0) {
        var flags = 0;
        if (ra) flags |= 0x40;
        if (pcr != null) flags |= 0x10;
        pkt[o++] = flags;
        var used = 1;
        if (pcr != null) {
          pkt[o++] = (pcr >> 25) & 0xFF;
          pkt[o++] = (pcr >> 17) & 0xFF;
          pkt[o++] = (pcr >> 9) & 0xFF;
          pkt[o++] = (pcr >> 1) & 0xFF;
          pkt[o++] = ((pcr & 1) << 7) | 0x7E;
          pkt[o++] = 0;
          used += 6;
        }
        while (used < afLen) {
          pkt[o++] = 0xFF;
          used++;
        }
      }
    }
    pkt.setRange(o, o + n, payload);
    return pkt;
  }
}
