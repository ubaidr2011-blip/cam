import 'dart:io';

import 'package:flutter/material.dart';
import 'lfield.dart';

import 'camera.dart';
import 'onvif.dart';
import 'probe.dart';

String hostOf(String a) =>
    a.replaceFirst(RegExp(r'^\w+://'), '').split('/').first.split('@').last.split(':').first;

class CameraDialog extends StatefulWidget {
  const CameraDialog({super.key, this.existing, this.initialAddress, this.others = const []});
  final List<Camera> others;
  final Camera? existing;
  final String? initialAddress;
  @override
  State<CameraDialog> createState() => _CameraDialogState();
}

class _CameraDialogState extends State<CameraDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _addr =
      TextEditingController(text: widget.existing?.rtsp ?? widget.initialAddress ?? '');
  late final _user = TextEditingController(text: widget.existing?.user ?? '');
  late final _pass = TextEditingController(text: widget.existing?.pass ?? '');
  late final _port = TextEditingController(text: _portOf(widget.existing?.onvifUrl));
  late final _recUrl = TextEditingController(text: widget.existing?.recRtsp ?? '');

  String _brand = 'Auto (ONVIF)';
  bool _hd = true, _busy = false, _probing = false, _cancel = false;
  String? _err, _info;

  // name: [mainPath, subPath]
  static const _brands = <String, List<String>>{
    'Auto (ONVIF)': [],
    'Hikvision': ['Streaming/Channels/101', 'Streaming/Channels/102'],
    'Dahua / Amcrest': ['cam/realmonitor?channel=1&subtype=0', 'cam/realmonitor?channel=1&subtype=1'],
    'Tapo / TP-Link': ['stream1', 'stream2'],
    'Reolink': ['h264Preview_01_main', 'h264Preview_01_sub'],
    'Foscam': ['videoMain', 'videoSub'],
    'Generic /stream1': ['stream1', 'stream2'],
  };

  static String _portOf(String? u) {
    if (u == null) return '';
    final uri = Uri.tryParse(u);
    return (uri != null && uri.hasPort) ? '${uri.port}' : '';
  }

  bool get _isRtsp => _addr.text.trim().startsWith('rtsp://');

  Future<void> _save() async {
    setState(() { _busy = true; _err = null; });
    try {
      final a = _addr.text.trim();
      if (a.isEmpty) throw Exception('Enter an address');
      final host = hostOf(a);
      final port = _port.text.trim();
      String rtsp;
      String? onvifUrl = widget.existing?.onvifUrl;
      String? liveLabel;
      if (port.isNotEmpty) onvifUrl = 'http://$host:$port/onvif/device_service';

      if (_isRtsp) {
        rtsp = a;
      } else if (_brand != 'Auto (ONVIF)') {
        final b = _brands[_brand]!;
        rtsp = 'rtsp://$host:554/${_hd ? b[0] : b[1]}';
      } else {
        final url = a.startsWith('http')
            ? a
            : 'http://$host${port.isEmpty ? '' : ':$port'}/onvif/device_service';
        final o = Onvif(url, _user.text, _pass.text);
        await o.init();
        rtsp = await o.streamUri(sub: !_hd);
        liveLabel = o.lastLabel;
        onvifUrl = url;
      }
      if (!mounted) return;
      final cam = Camera(
        id: widget.existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        name: _name.text.trim().isEmpty ? hostOf(rtsp) : _name.text.trim(),
        rtsp: rtsp,
        onvifUrl: onvifUrl,
        user: _user.text,
        pass: _pass.text,
      );
      final ex = widget.existing;
      cam.recRtsp = _recUrl.text.trim().isEmpty ? null : _recUrl.text.trim();
      cam.liveInfo = liveLabel ?? ((ex != null && ex.rtsp == rtsp) ? ex.liveInfo : null);
      cam.recInfo = (ex != null && ex.recRtsp == cam.recRtsp) ? ex.recInfo : null;
      if (ex != null) {
        cam.zones = ex.zones;
        cam.alarmOn = ex.alarmOn;
        cam.sens = ex.sens;
        cam.recOnAlarm = ex.recOnAlarm;
        cam.alarmSound = ex.alarmSound;
      }
      final dup = widget.others.where((c) => c.id != cam.id && c.host == cam.host);
      if (dup.isNotEmpty) {
        final go = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
                  title: const Text('Camera already added'),
                  content: Text('${cam.host} is already in your list as "${dup.first.name}". '
                      'Adding it again will show the same stream twice.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add anyway')),
                  ],
                ));
        if (go != true) {
          if (mounted) setState(() => _busy = false);
          return;
        }
      }
      if (mounted) Navigator.pop(context, cam);
    } catch (e) {
      setState(() {
        _err = '$e'.replaceFirst('Exception: ', '') +
            (_isRtsp ? '' : '\n\nNo ONVIF on this camera? Tap "Auto-detect stream path".');
        _busy = false;
      });
    }
  }

  /// Tries many known RTSP paths on this IP until one returns video.
  Future<void> _autoDetect() async {
    final host = hostOf(_addr.text.trim());
    if (host.isEmpty) {
      setState(() => _err = 'Enter the camera IP first');
      return;
    }
    setState(() { _probing = true; _cancel = false; _err = null; _info = 'Checking RTSP ports…'; });
    final ports = <int>[];
    for (final p in const [554, 8554]) {
      try {
        (await Socket.connect(host, p, timeout: const Duration(milliseconds: 800))).destroy();
        ports.add(p);
      } catch (_) {}
    }
    if (ports.isEmpty) {
      setState(() {
        _probing = false;
        _info = null;
        _err = 'RTSP port (554/8554) is closed on $host. Enable RTSP in the camera '
            'settings or check the IP address.';
      });
      return;
    }
    final user = _user.text, pass = _pass.text;
    final cred = user.isEmpty ? '' : '${Uri.encodeComponent(user)}:${Uri.encodeComponent(pass)}@';
    final total = ports.length * kProbePaths.length;
    var n = 0;
    String? found;
    outer:
    for (final port in ports) {
      for (final path in kProbePaths) {
        if (_cancel || !mounted) break outer;
        n++;
        setState(() => _info = 'Trying $n/$total: /${path.split('?').first}');
        final clean = path.replaceAll('{u}', user).replaceAll('{p}', pass);
        if (await probeUrl('rtsp://$cred$host:$port/$clean')) {
          found = 'rtsp://$host:$port/$clean';
          break outer;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _probing = false;
      if (found != null) {
        _addr.text = found;
        _info = 'Found a working stream ✓  Press Add / Save.';
      } else {
        _info = null;
        _err = _cancel
            ? 'Cancelled.'
            : 'No working stream path found. Check username/password, and that the '
                'camera account is allowed to use RTSP.';
      }
    });
  }

  @override
  void dispose() {
    _cancel = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.existing == null ? 'Add camera' : 'Edit camera'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              LField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
              LField(
                  controller: _addr,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                      labelText: 'IP address, or rtsp:// URL',
                      helperText: 'Just the IP is fine – use Auto-detect below')),
              LField(controller: _user, decoration: const InputDecoration(labelText: 'Username')),
              LField(
                  controller: _pass,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password')),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: _probing
                    ? OutlinedButton.icon(
                        onPressed: () => setState(() => _cancel = true),
                        icon: const Icon(Icons.close),
                        label: const Text('Cancel search'))
                    : OutlinedButton.icon(
                        onPressed: _busy ? null : _autoDetect,
                        icon: const Icon(Icons.auto_fix_high),
                        label: const Text('Auto-detect stream path')),
              ),
              if (!_isRtsp) ...[
                DropdownButtonFormField<String>(
                    value: _brand,
                    decoration: const InputDecoration(labelText: 'Camera type'),
                    items: _brands.keys
                        .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                        .toList(),
                    onChanged: (v) => setState(() => _brand = v!)),
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Maximum quality (main stream)'),
                    subtitle: const Text('Off = lighter sub-stream'),
                    value: _hd,
                    onChanged: (v) => setState(() => _hd = v)),
              ],
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Advanced: ONVIF port, recording stream', style: TextStyle(fontSize: 14)),
                children: [
                  LField(
                      controller: _recUrl,
                      decoration: const InputDecoration(
                          labelText: 'Recording stream address (optional)',
                          helperText: 'e.g. the HD main stream rtsp://…  Empty = record what you watch')),
                  LField(
                      controller: _port,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'ONVIF port',
                          helperText: 'Leave empty to auto-detect (80, 2020, 8000, 8899…)')),
                ],
              ),
              if (_info != null)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_info!, style: const TextStyle(color: Colors.tealAccent))),
              if (_err != null)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_err!, style: const TextStyle(color: Colors.redAccent))),
              if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
              onPressed: (_busy || _probing) ? null : _save,
              child: Text(widget.existing == null ? 'Add' : 'Save')),
        ],
      );
}

class DiscoverSheet extends StatefulWidget {
  const DiscoverSheet({super.key, this.known = const {}});
  final Set<String> known; // hosts already in the list
  @override
  State<DiscoverSheet> createState() => _DiscoverSheetState();
}

class _DiscoverSheetState extends State<DiscoverSheet> {
  final Map<String, String> _found = {}; // host -> address to use
  bool _scanning = true;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final onvif = await Onvif.discover().catchError((_) => <String>[]);
    if (mounted) {
      setState(() {
        for (final u in onvif) {
          final h = Uri.tryParse(u)?.host ?? '';
          if (h.isNotEmpty) _found[h] = u; // one entry per camera
        }
      });
    }
    final hosts = await Onvif.scanRtsp().catchError((_) => <String>[]);
    if (mounted) {
      setState(() {
        for (final h in hosts) {
          _found.putIfAbsent(h, () => h);
        }
        _scanning = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hosts = _found.keys.toList()..sort();
    return SizedBox(
      height: 420,
      child: Column(children: [
        ListTile(
            title: const Text('Cameras on your network'),
            trailing: _scanning
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : null),
        const Divider(height: 1),
        Expanded(
          child: hosts.isEmpty
              ? Center(child: Text(_scanning ? 'Scanning…' : 'Nothing found. Use Add camera instead.'))
              : ListView(
                  children: hosts.map((h) {
                  final isOnvif = _found[h]!.startsWith('http');
                  final known = widget.known.contains(h);
                  return ListTile(
                    leading: const Icon(Icons.videocam_outlined),
                    title: Text(h),
                    subtitle: Text(known ? 'Already added' : (isOnvif ? 'ONVIF camera' : 'RTSP port open')),
                    trailing: known ? const Icon(Icons.check_circle, color: Colors.greenAccent) : null,
                    onTap: () => Navigator.pop(context, _found[h]),
                  );
                }).toList()),
        ),
      ]),
    );
  }
}
