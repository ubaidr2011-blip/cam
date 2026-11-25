import 'dart:io';

import 'package:flutter/material.dart';
import 'lfield.dart';

import 'recorder.dart';
import 'settings.dart';
import 'storage.dart';
import 'widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.onQuit, this.onDecodeChanged});
  final VoidCallback? onQuit, onDecodeChanged;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List<StorageOption> _opts = [];
  String? _ff;
  int _used = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final o = await Storage.options();
    final f = await FfmpegRecorder.find();
    final u = await Storage.usedBytes();
    if (mounted) setState(() { _opts = o; _ff = f; _used = u; });
  }

  Future<void> _setPath() async {
    final c = TextEditingController(text: settings.ffmpegPath);
    final v = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Path to ffmpeg'),
              content: LField(
                  controller: c,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: '/opt/local/bin/ffmpeg')),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Save')),
              ],
            ));
    if (v == null) return;
    settings.ffmpegPath = v.trim();
    await settings.save();
    FfmpegRecorder.recheck();
    _load();
  }

  Future<void> _save() async {
    await settings.save();
    if (mounted) setState(() {});
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
        child: Text(t.toUpperCase(), style: const TextStyle(fontSize: 11, color: kMuted, letterSpacing: 1)),
      );

  Widget _dd<T>(String title, String? sub, T value, Map<T, String> items, void Function(T) on, {bool enabled = true}) =>
      ListTile(
        title: Text(title),
        subtitle: sub == null ? null : Text(sub, style: const TextStyle(fontSize: 12)),
        trailing: DropdownButton<T>(
          value: value,
          onChanged: enabled ? (v) => on(v as T) : null,
          items: items.entries.map((e) => DropdownMenuItem<T>(value: e.key, child: Text(e.value))).toList(),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final canEncode = _ff != null;
    final mb = _used / 1048576;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        _section('Video'),
        _dd<String>(
            'Video decoding',
            'If the picture looks garbled or scrambled, try the other modes. '
                'Safe mode is the most compatible. Changes apply immediately.',
            settings.decode,
            {'auto': 'Auto (hardware)', 'soft': 'Software decoding', 'safe': 'Safe mode'},
            (v) async {
              settings.decode = v;
              await _save();
              widget.onDecodeChanged?.call();
            }),

        _section('Recording folder'),
        for (final o in _opts)
          ListTile(
            dense: true,
            title: Text(o.label),
            subtitle: Text(o.path, style: const TextStyle(fontSize: 11, color: kMuted)),
            trailing: settings.folder == o.id ? const Icon(Icons.check_circle, color: kAccent) : null,
            onTap: () {
              settings.folder = o.id;
              _save();
            },
          ),
        if (Platform.isMacOS)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              OutlinedButton.icon(
                  onPressed: () async {
                    final d = await Storage.chooseFolder();
                    if (d != null) {
                      settings.customPath = d;
                      settings.folder = 'custom';
                      await _save();
                      _load();
                    }
                  },
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Choose folder…')),
              const SizedBox(width: 8),
              TextButton(
                  onPressed: () async {
                    final d = await Storage.recordingsDir();
                    Process.run('open', [d.path]);
                  },
                  child: const Text('Open in Finder')),
            ]),
          ),
        if (!Platform.isMacOS)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text('An SD-card option appears here automatically when a card is inserted in the phone. '
                'Files in "App storage" are only reachable through the Library (Share / Export).',
                style: TextStyle(fontSize: 12, color: kMuted)),
          ),
        if (Storage.warning != null)
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(Storage.warning!, style: const TextStyle(color: Colors.orangeAccent, fontSize: 12))),

        _section('Files'),
        _dd<int>('Split recordings', 'New file every N minutes – easier to manage, safer if the app is closed',
            settings.segmentMin, {0: 'One file', 5: '5 min', 15: '15 min', 30: '30 min', 60: '60 min'}, (v) {
          settings.segmentMin = v;
          _save();
        }),

        _section('Quality & size'),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Text(
              'Recording uses LanCam\'s built-in recorder: it saves the camera\'s stream unchanged (original '
              'quality, video only, .ts files that play in most players). With ffmpeg installed on a Mac you '
              'can also re-encode to H.265 / H.264.',
              style: TextStyle(fontSize: 12, color: kMuted)),
        ),
        _dd<String>(
            'Codec',
            canEncode
                ? 'H.265 keeps the same look at roughly half the size'
                : (FfmpegRecorder.supported
                    ? 'Needs ffmpeg (see below)'
                    : 'Android saves the camera\'s own stream, unchanged (see tip below)'),
            canEncode ? settings.codec : 'copy',
            {'copy': 'Original (no loss)', 'hevc': 'H.265 (smaller)', 'h264': 'H.264'},
            (v) {
              settings.codec = v;
              _save();
            },
            enabled: canEncode),
        _dd<String>('Quality', 'Lower = smaller files', settings.quality,
            {'high': 'High', 'medium': 'Medium', 'low': 'Low'}, (v) {
          settings.quality = v;
          _save();
        }, enabled: canEncode && settings.codec != 'copy'),
        if (FfmpegRecorder.supported)
          ListTile(
            dense: true,
            leading: Icon(canEncode ? Icons.check_circle : Icons.error_outline,
                color: canEncode ? Colors.greenAccent : Colors.orangeAccent),
            title: Text(canEncode ? 'ffmpeg found' : 'ffmpeg not found'),
            subtitle: Text(
                canEncode
                    ? '${FfmpegRecorder.version ?? ''}\n$_ff'
                    : 'Looked in MacPorts, Homebrew and your shell PATH. Use "Set path" to point to it '
                        '(find it with:  which ffmpeg).',
                style: const TextStyle(fontSize: 11, color: kMuted)),
            isThreeLine: true,
          ),
        if (FfmpegRecorder.supported)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              OutlinedButton(
                  onPressed: () {
                    FfmpegRecorder.recheck();
                    _load();
                  },
                  child: const Text('Check again')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: _setPath, child: const Text('Set path…')),
            ]),
          ),
        if (!FfmpegRecorder.supported)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
                'Tip to save space on Android without losing quality: in your camera\'s own settings choose '
                'H.265 (and "Smart codec" if available) and a moderate bitrate. LanCam records exactly what '
                'the camera sends, so the files get smaller automatically.',
                style: TextStyle(fontSize: 12, color: kMuted)),
          ),

        _section('Storage limits'),
        _dd<double>('Maximum size', 'Oldest recordings are deleted first', settings.maxGb,
            {0: 'Unlimited', 1: '1 GB', 2: '2 GB', 5: '5 GB', 10: '10 GB', 20: '20 GB', 50: '50 GB'}, (v) {
          settings.maxGb = v;
          _save();
        }),
        _dd<int>('Keep for', 'Older recordings are deleted automatically', settings.keepDays,
            {0: 'Forever', 1: '1 day', 3: '3 days', 7: '7 days', 14: '14 days', 30: '30 days'}, (v) {
          settings.keepDays = v;
          _save();
        }),
        ListTile(
          dense: true,
          title: Text('Used: ${mb >= 1024 ? '${(mb / 1024).toStringAsFixed(2)} GB' : '${mb.toStringAsFixed(0)} MB'}'),
          trailing: TextButton(
              onPressed: () async {
                await Storage.purge();
                _load();
              },
              child: const Text('Clean up now')),
        ),
        _section('App'),
        ListTile(
          leading: const Icon(Icons.power_settings_new, color: Colors.redAccent),
          title: const Text('Exit LanCam'),
          subtitle: const Text('Disconnect all cameras and close the app', style: TextStyle(fontSize: 12)),
          onTap: widget.onQuit,
        ),
        const SizedBox(height: 30),
      ]),
    );
  }
}
