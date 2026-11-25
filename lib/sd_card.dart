import 'dart:io';

import 'package:flutter/material.dart';
import 'lfield.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import 'onvif.dart';
import 'session.dart';
import 'storage.dart';
import 'widgets.dart';

String _two(int n) => n.toString().padLeft(2, '0');

/// Play what the camera has stored on its own memory card.
/// Works with cameras that expose it: ONVIF Profile G, Hikvision, Dahua/Amcrest.
class SdCardTab extends StatefulWidget {
  const SdCardTab({super.key, required this.session, required this.onvif, this.log = const []});
  final Session session;
  final Onvif? onvif;
  final List<String> log;

  @override
  State<SdCardTab> createState() => _SdCardTabState();
}

class _SdCardTabState extends State<SdCardTab> {
  String _mode = 'hik'; // hik | dahua
  DateTime _date = DateTime.now();
  TimeOfDay _time = TimeOfDay.fromDateTime(DateTime.now().subtract(const Duration(hours: 1)));
  int _mins = 15;
  List<RecInfo> _recs = [];
  final _custom = TextEditingController();
  String? _msg;
  bool _busy = false;

  Session get s => widget.session;

  String _creds() {
    final u = Uri.parse(s.cam.streamUrl);
    return u.userInfo.isEmpty ? '' : '${u.userInfo}@';
  }

  int get _port {
    final u = Uri.tryParse(s.cam.rtsp);
    return (u != null && u.hasPort) ? u.port : 554;
  }

  String _timeUrl() {
    final start = DateTime(_date.year, _date.month, _date.day, _time.hour, _time.minute);
    final end = start.add(Duration(minutes: _mins));
    final base = 'rtsp://${_creds()}${s.cam.host}:$_port';
    if (_mode == 'hik') {
      String f(DateTime d) {
        final u = d.toUtc();
        return '${u.year}${_two(u.month)}${_two(u.day)}T${_two(u.hour)}${_two(u.minute)}${_two(u.second)}Z';
      }

      return '$base/Streaming/tracks/101?starttime=${f(start)}&endtime=${f(end)}';
    }
    String f(DateTime d) =>
        '${d.year}_${_two(d.month)}_${_two(d.day)}_${_two(d.hour)}_${_two(d.minute)}_${_two(d.second)}';
    return '$base/cam/playback?channel=1&subtype=0&starttime=${f(start)}&endtime=${f(end)}';
  }

  void _play(String url, String title) => Navigator.push(
      context, MaterialPageRoute(builder: (_) => ClipPlayerPage(url: url, title: title)));

  Future<void> _search() async {
    final o = widget.onvif;
    if (o == null) {
      setState(() => _msg = 'ONVIF is not connected yet. Open the PTZ tab and wait for "Connected".');
      return;
    }
    setState(() { _busy = true; _msg = null; _recs = []; });
    try {
      final r = await o.recordings();
      setState(() { _recs = r; _msg = r.isEmpty ? 'The camera reports no recordings (is a card inserted and recording?).' : null; });
    } catch (e) {
      setState(() => _msg = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _playRec(RecInfo r) async {
    setState(() => _busy = true);
    try {
      final raw = await widget.onvif!.replayUri(r.token);
      final u = Uri.parse(raw);
      final withCreds = u.userInfo.isNotEmpty || s.cam.user.isEmpty
          ? raw
          : u
              .replace(userInfo: '${Uri.encodeComponent(s.cam.user)}:${Uri.encodeComponent(s.cam.pass)}')
              .toString();
      if (mounted) _play(withCreds, r.name.isEmpty ? 'SD recording' : r.name);
    } catch (e) {
      setState(() => _msg = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fmt(DateTime? d) => d == null
      ? '?'
      : '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text(
          'Play recordings stored on the camera\'s memory card. This only works if the camera '
          'exposes its card to apps (ONVIF Profile G, Hikvision, Dahua/Amcrest). '
          'Some brands (e.g. Tapo, EZVIZ) keep it private to their own app.',
          style: TextStyle(fontSize: 12, color: kMuted)),
      const SizedBox(height: 14),
      const Text('PLAY BY TIME', style: TextStyle(fontSize: 11, color: kMuted, letterSpacing: 1)),
      const SizedBox(height: 6),
      Row(children: [
        const Text('Camera type'),
        const SizedBox(width: 12),
        DropdownButton<String>(
          value: _mode,
          items: const [
            DropdownMenuItem(value: 'hik', child: Text('Hikvision / compatible')),
            DropdownMenuItem(value: 'dahua', child: Text('Dahua / Amcrest')),
          ],
          onChanged: (v) => setState(() => _mode = v!),
        ),
      ]),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        OutlinedButton.icon(
            icon: const Icon(Icons.event, size: 18),
            label: Text('${_date.year}-${_two(_date.month)}-${_two(_date.day)}'),
            onPressed: () async {
              final d = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime.now().subtract(const Duration(days: 365)),
                  lastDate: DateTime.now());
              if (d != null) setState(() => _date = d);
            }),
        OutlinedButton.icon(
            icon: const Icon(Icons.schedule, size: 18),
            label: Text('${_two(_time.hour)}:${_two(_time.minute)}'),
            onPressed: () async {
              final t = await showTimePicker(context: context, initialTime: _time);
              if (t != null) setState(() => _time = t);
            }),
        DropdownButton<int>(
          value: _mins,
          items: const [5, 15, 30, 60]
              .map((m) => DropdownMenuItem(value: m, child: Text('$m min')))
              .toList(),
          onChanged: (v) => setState(() => _mins = v!),
        ),
      ]),
      const SizedBox(height: 10),
      FilledButton.icon(
          onPressed: () => _play(_timeUrl(), 'SD card ${_fmt(DateTime(_date.year, _date.month, _date.day, _time.hour, _time.minute))}'),
          icon: const Icon(Icons.play_arrow),
          label: const Text('Play from camera card')),
      const SizedBox(height: 22),
      Row(children: [
        const Text('ONVIF RECORDINGS', style: TextStyle(fontSize: 11, color: kMuted, letterSpacing: 1)),
        const Spacer(),
        TextButton.icon(
            onPressed: _busy ? null : _search,
            icon: const Icon(Icons.search, size: 16),
            label: const Text('Search')),
      ]),
      if (_busy) const LinearProgressIndicator(),
      if (_msg != null)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_msg!, style: const TextStyle(fontSize: 12, color: Colors.orangeAccent))),
      ..._recs.map((r) => ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.sd_card_outlined),
            title: Text(r.name.isEmpty ? 'Recording ${r.token}' : r.name),
            subtitle: Text('${_fmt(r.start)}  →  ${_fmt(r.end)}', style: const TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.play_arrow),
            onTap: () => _playRec(r),
          )),
      const SizedBox(height: 22),
      const Text('CUSTOM PLAYBACK URL', style: TextStyle(fontSize: 11, color: kMuted, letterSpacing: 1)),
      const SizedBox(height: 4),
      const Text('If your camera\'s manual lists an RTSP playback address, paste it here.',
          style: TextStyle(fontSize: 12, color: kMuted)),
      Row(children: [
        Expanded(
            child: LField(
                controller: _custom,
                decoration: const InputDecoration(hintText: 'rtsp://user:pass@192.168.1.10/…'))),
        IconButton(
            icon: const Icon(Icons.play_arrow),
            onPressed: () {
              final u = _custom.text.trim();
              if (u.startsWith('rtsp://')) _play(u, 'Custom playback');
            }),
      ]),
      const SizedBox(height: 14),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('Diagnostics (send this if SD access fails)', style: TextStyle(fontSize: 13)),
        children: [
          Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(widget.log.isEmpty ? 'No ONVIF activity yet' : widget.log.join('\n'),
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: kMuted))),
          Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                  onPressed: () => Clipboard.setData(ClipboardData(text: widget.log.join('\n'))),
                  icon: const Icon(Icons.copy, size: 14),
                  label: const Text('Copy'))),
        ],
      ),
    ]);
  }
}

/// Plays a camera-side recording and can save a copy to this device.
class ClipPlayerPage extends StatefulWidget {
  const ClipPlayerPage({super.key, required this.url, required this.title});
  final String url, title;
  @override
  State<ClipPlayerPage> createState() => _ClipPlayerPageState();
}

class _ClipPlayerPageState extends State<ClipPlayerPage> {
  late final player = Player();
  late final controller = makeVideoController(player);
  String _status = 'Connecting…';
  String? _savingTo;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final np = player.platform as NativePlayer;
    await applyDecoding(player);
    await np.setProperty('demuxer-lavf-o', 'rtsp_transport=tcp');
    player.stream.error.listen((e) {
      if (mounted) setState(() => _status = 'Error: $e');
    });
    player.stream.width.listen((w) {
      if ((w ?? 0) > 0 && mounted) setState(() => _status = 'Playing');
    });
    await player.open(Media(widget.url));
  }

  Future<void> _toggleSave() async {
    final np = player.platform as NativePlayer;
    if (_savingTo == null) {
      final dir = await Storage.recordingsDir();
      final path = p.join(dir.path, 'SDclip_${DateTime.now().millisecondsSinceEpoch}.mkv');
      await np.setProperty('stream-record', path);
      setState(() => _savingTo = path);
    } else {
      await np.setProperty('stream-record', '');
      final saved = _savingTo!;
      setState(() => _savingTo = null);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(File(saved).existsSync() ? 'Clip saved to Library' : 'Could not save clip')));
      }
    }
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title), actions: [
          IconButton(
              tooltip: _savingTo == null ? 'Save this clip to the device' : 'Stop saving',
              icon: Icon(_savingTo == null ? Icons.download : Icons.stop_circle, color: _savingTo == null ? null : Colors.redAccent),
              onPressed: _toggleSave),
        ]),
        body: Column(children: [
          Expanded(child: Video(controller: controller)),
          Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(widget.url.replaceFirst(RegExp(r'//[^@/]*@'), '//***@'),
                      style: const TextStyle(fontSize: 11, color: kMuted)))),
          Padding(
              padding: const EdgeInsets.all(10),
              child: Row(children: [
                IconButton(onPressed: () => player.playOrPause(), icon: const Icon(Icons.play_arrow)),
                Expanded(child: Text(_savingTo == null ? _status : 'Saving clip…  $_status', style: const TextStyle(fontSize: 12, color: kMuted))),
              ])),
        ]),
      );
}
