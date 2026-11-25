import 'package:flutter/material.dart';
import 'lfield.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'camera.dart';
import 'onvif.dart';
import 'platform.dart';
import 'sd_card.dart';
import 'session.dart';
import 'widgets.dart';
import 'zoom_view.dart';

class CameraPage extends StatefulWidget {
  const CameraPage({super.key, required this.session, required this.onChanged});
  final Session session;
  final VoidCallback onChanged; // called when the camera's ONVIF address was learned

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
  Onvif? _onvif;
  String _ptzMsg = 'Connecting…';
  bool _ptzBusy = false, _ptzOk = false;
  List<PtzPreset> _presets = [];
  double _speed = 0.5;
  bool _editZones = false;
  bool _ptzKeys = !kTv; // TV: press OK on the video to switch arrow keys to PTZ
  bool _vf = false;
  final _videoFocus = FocusNode();
  final List<String> _ptzLog = [];

  Session get s => widget.session;

  @override
  void dispose() {
    _videoFocus.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _connectPtz();
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));
  }

  void _log(String m) {
    _ptzLog.add(m);
    if (_ptzLog.length > 60) _ptzLog.removeAt(0);
  }

  Future<void> _connectPtz() async {
    setState(() {
      _ptzBusy = true;
      _ptzOk = false;
      _ptzMsg = 'Connecting…';
      _onvif = null;
      _ptzLog.clear();
    });
    final cam = s.cam;
    Onvif? o;
    String? err;
    if (cam.onvifUrl != null) {
      try {
        o = Onvif(cam.onvifUrl!, cam.user, cam.pass, onLog: _log);
        await o.init().timeout(const Duration(seconds: 25));
      } catch (e) {
        err = '$e'.replaceFirst('Exception: ', '');
        _log('ONVIF at saved address failed: $err');
        o = null;
      }
    }
    if (o == null) {
      final r = await Onvif.find(cam.host, cam.user, cam.pass, onLog: _log);
      o = r.onvif;
      err = r.error ?? err;
      if (o != null) {
        cam.onvifUrl = o.deviceUrl;
        widget.onChanged();
      }
    }
    if (!mounted) return;
    if (o == null) {
      setState(() { _ptzBusy = false; _ptzMsg = err ?? 'PTZ not available'; });
      return;
    }
    if (!o.hasPtz) {
      setState(() { _ptzBusy = false; _ptzMsg = 'This camera has no PTZ motor (fixed camera).'; });
      return;
    }
    var pr = <PtzPreset>[];
    try {
      pr = await o.presets();
    } catch (e) {
      _log('GetPresets: $e');
    }
    if (!mounted) return;
    setState(() { _onvif = o; _presets = pr; _ptzBusy = false; _ptzOk = true; _ptzMsg = 'Connected'; });
  }

  Future<void> _do(Future<void> Function(Onvif o) f) async {
    final o = _onvif;
    if (o == null) return;
    try {
      await f(o);
      if (mounted && _ptzMsg != 'Connected') setState(() => _ptzMsg = 'Connected');
    } catch (e) {
      _log('Command failed: $e');
      if (mounted) setState(() => _ptzMsg = 'Command failed: ${'$e'.replaceFirst('Exception: ', '')}');
    }
  }

  void _move(double pan, double tilt, double zoom) {
    if (_onvif == null) {
      _toast('PTZ not connected: $_ptzMsg');
      return;
    }
    _do((o) => o.move(pan * _speed, tilt * _speed, zoom * _speed));
  }

  Future<void> _run(Future<void> Function() f, [String? ok]) async {
    try {
      await f();
      if (ok != null) _toast(ok);
    } catch (e) {
      _toast('$e'.replaceFirst('Exception: ', ''));
    }
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    final k = e.logicalKey;
    if (kTv && isOkKey(k)) {
      if (e is KeyDownEvent) setState(() => _ptzKeys = !_ptzKeys);
      return KeyEventResult.handled;
    }
    if (!_ptzKeys) return KeyEventResult.ignored; // let the arrows move focus
    double pan = 0, tilt = 0, zoom = 0;
    if (k == LogicalKeyboardKey.arrowLeft) {
      pan = -1;
    } else if (k == LogicalKeyboardKey.arrowRight) {
      pan = 1;
    } else if (k == LogicalKeyboardKey.arrowUp) {
      tilt = 1;
    } else if (k == LogicalKeyboardKey.arrowDown) {
      tilt = -1;
    } else if (k == LogicalKeyboardKey.equal || k == LogicalKeyboardKey.numpadAdd ||
        k == LogicalKeyboardKey.mediaFastForward || k == LogicalKeyboardKey.channelUp) {
      zoom = 1;
    } else if (k == LogicalKeyboardKey.minus || k == LogicalKeyboardKey.numpadSubtract ||
        k == LogicalKeyboardKey.mediaRewind || k == LogicalKeyboardKey.channelDown) {
      zoom = -1;
    } else {
      return KeyEventResult.ignored;
    }
    if (e is KeyDownEvent) {
      _move(pan, tilt, zoom);
    } else if (e is KeyUpEvent) {
      _do((o) => o.stop());
    }
    return KeyEventResult.handled;
  }

  // ------------------------------------------------------------------- tabs

  Widget _row(IconData icon, String title, VoidCallback onTap,
          {String? sub, Widget? trailing, Color? color}) =>
      Column(children: [
        ListTile(
          dense: true,
          leading: Icon(icon, size: 20, color: color),
          title: Text(title),
          subtitle: sub == null ? null : Text(sub, style: const TextStyle(fontSize: 12)),
          trailing: trailing,
          onTap: onTap,
        ),
        const Divider(height: 1),
      ]);

  /// Choose which stream (main/sub…) is used for live view or for recording.
  Future<void> _pickStream({required bool recording}) async {
    final o = _onvif;
    if (o == null || o.profiles.isEmpty) {
      _toast('ONVIF is not connected yet. Open the PTZ tab and wait for "Connected", '
          'or edit the camera and type the stream address.');
      return;
    }
    final choice = await showDialog<Object>(
        context: context,
        builder: (_) => SimpleDialog(
              title: Text(recording ? 'Recording stream' : 'Live stream'),
              children: [
                if (recording)
                  SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, 'same'),
                      child: const Text('Same as live view')),
                for (final pr in o.profiles)
                  SimpleDialogOption(onPressed: () => Navigator.pop(context, pr), child: Text(pr.label)),
              ],
            ));
    if (choice == null) return;
    try {
      if (choice is OnvifProfile) {
        final uri = await o.streamUriFor(choice.token);
        if (recording) {
          s.cam.recRtsp = uri;
          s.cam.recInfo = choice.label;
        } else {
          s.cam.rtsp = uri;
          s.cam.liveInfo = choice.label;
        }
      } else {
        s.cam.recRtsp = null;
        s.cam.recInfo = null;
      }
      widget.onChanged();
      if (!recording) s.start();
      if (mounted) setState(() {});
      _toast(recording ? 'Recording stream saved' : 'Live stream changed');
    } catch (e) {
      _toast('$e'.replaceFirst('Exception: ', ''));
    }
  }

  Widget _controlsTab() {
    final stopped = s.state == SState.stopped || s.state == SState.error;
    return ListView(children: [
      _row(Icons.hd_outlined, 'Live stream', () => _pickStream(recording: false),
          sub: s.cam.liveInfo ?? 'Tap to choose HD or SD',
          trailing: const Icon(Icons.chevron_right, size: 18)),
      _row(Icons.video_settings_outlined, 'Recording stream', () => _pickStream(recording: true),
          sub: s.cam.recInfo ?? (s.cam.recRtsp != null ? 'Custom address' : 'Same as live view'),
          trailing: const Icon(Icons.chevron_right, size: 18)),
      _row(stopped ? Icons.play_arrow : Icons.stop, stopped ? 'Start stream' : 'Close stream',
          () => stopped ? s.start() : _run(s.stop, 'Stream closed'),
          sub: stopped ? 'Connect to the camera' : 'Disconnect and stop network traffic'),
      _row(Icons.refresh, 'Reconnect', () => s.start(), sub: 'Restart the connection'),
      _row(s.recording ? Icons.stop_circle_outlined : Icons.fiber_manual_record,
          s.recording ? 'Stop recording' : 'Record',
          () => _run(s.toggleRecord, s.recording ? 'Saved to Library' : 'Recording started'),
          sub: s.recError ??
              (s.recording
                  ? '${s.recStatus} · ${(s.recBytes / 1048576).toStringAsFixed(1)} MB · ${s.recEngine}'
                  : 'Save the stream to a file (works even if the view is closed)'),
          color: s.recError != null ? Colors.orangeAccent : Colors.redAccent,
          trailing: s.recording && s.recStart != null ? RecTimer(s.recStart!) : null),
      _row(Icons.photo_camera_outlined, 'Snapshot', () => _run(() async {
            final p = await s.snapshot();
            _toast(p == null ? 'Snapshot failed' : 'Snapshot saved to Library');
          }), sub: 'Save the current frame as a photo'),
      _row(s.muted ? Icons.volume_off_outlined : Icons.volume_up_outlined, 'Audio',
          () => s.setMuted(!s.muted),
          sub: s.muted ? 'Muted' : 'On',
          trailing: Switch(value: !s.muted, onChanged: (v) => s.setMuted(!v))),
    ]);
  }

  Widget _ptzTab() {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        if (_ptzBusy)
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
        else
          Icon(_ptzOk ? Icons.check_circle : Icons.error_outline,
              size: 16, color: _ptzOk ? Colors.greenAccent : Colors.orangeAccent),
        const SizedBox(width: 8),
        Expanded(
            child: Text(_ptzMsg,
                style: TextStyle(fontSize: 12, color: _ptzOk ? Colors.greenAccent : Colors.orangeAccent))),
        TextButton(onPressed: _ptzBusy ? null : _connectPtz, child: const Text('Reconnect')),
      ]),
      if (_ptzOk) ...[
        const SizedBox(height: 16),
        PtzPad(move: _move, stop: () => _do((o) => o.stop()), home: () => _do((o) => o.gotoHome())),
        const SizedBox(height: 16),
        Row(children: [
          const Icon(Icons.speed, size: 18, color: kMuted),
          Expanded(
              child: Slider(
                  value: _speed,
                  min: 0.1,
                  max: 1.0,
                  divisions: 9,
                  onChanged: (v) => setState(() => _speed = v))),
          SizedBox(width: 40, child: Text('${(_speed * 100).round()}%', style: const TextStyle(color: kMuted))),
        ]),
        const Text('Keyboard: arrow keys move · + / − zoom',
            style: TextStyle(fontSize: 11, color: kMuted)),
        const SizedBox(height: 20),
        Row(children: [
          const Text('PRESETS', style: TextStyle(fontSize: 11, color: kMuted, letterSpacing: 1)),
          const Spacer(),
          TextButton.icon(
              onPressed: _savePreset,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Save position')),
        ]),
        if (_presets.isEmpty)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No presets. Aim the camera, then tap "Save position".',
                  style: TextStyle(fontSize: 12, color: kMuted))),
        ..._presets.map((pr) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.bookmark_border, size: 18),
              title: Text(pr.name),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => _do((o) => o.gotoPreset(pr.token)),
            )),
      ] else if (!_ptzBusy) ...[
        const SizedBox(height: 12),
        const Text(
            'PTZ needs an ONVIF camera with a motor. Check the Info tab for the connection log, '
            'and make sure ONVIF is enabled and you use the camera account.',
            style: TextStyle(fontSize: 12, color: kMuted)),
      ],
    ]);
  }


  Widget _alarmTab() {
    final cam = s.cam;
    void changed() {
      widget.onChanged();
      if (mounted) setState(() {});
    }

    String two(int n) => n.toString().padLeft(2, '0');
    return ListView(padding: const EdgeInsets.all(16), children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Intrusion alarm'),
        subtitle: const Text('Rings when something moves inside an alarm zone'),
        value: cam.alarmOn,
        onChanged: (v) {
          if (v && cam.zones.isEmpty) _toast('Draw at least one zone first');
          cam.alarmOn = v;
          s.configureDetection();
          changed();
        },
      ),
      const Divider(),
      Row(children: [
        Text('ALARM ZONES (${cam.zones.length})',
            style: const TextStyle(fontSize: 11, color: kMuted, letterSpacing: 1)),
        const Spacer(),
        TextButton(
            onPressed: () {
              cam.zones.add(Zone(0, 0, 1, 1));
              s.configureDetection();
              changed();
            },
            child: const Text('Whole picture')),
        FilledButton.icon(
            onPressed: () => setState(() => _editZones = !_editZones),
            icon: Icon(_editZones ? Icons.check : Icons.crop_square, size: 18),
            label: Text(_editZones ? 'Done' : 'Draw zone')),
      ]),
      if (_editZones)
        const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Drag on the video to draw a zone. Draw as many as you need.',
                style: TextStyle(fontSize: 12, color: Colors.amber))),
      for (var i = 0; i < cam.zones.length; i++)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.crop_din, color: Colors.amber),
          title: Text('Zone ${i + 1}'),
          trailing: IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () {
                cam.zones.removeAt(i);
                s.configureDetection();
                changed();
              }),
        ),
      const SizedBox(height: 8),
      Row(children: [
        const Text('Sensitivity'),
        Expanded(
            child: Slider(
                value: cam.sens,
                onChanged: (v) => setState(() => cam.sens = v),
                onChangeEnd: (_) => changed())),
        Text(cam.sens < 0.34 ? 'Low' : (cam.sens < 0.67 ? 'Medium' : 'High'),
            style: const TextStyle(color: kMuted)),
      ]),
      SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Ring siren'),
          value: cam.alarmSound,
          onChanged: (v) {
            cam.alarmSound = v;
            changed();
          }),
      SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Record when alarm triggers'),
          subtitle: const Text('Stops ~12 s after the movement ends'),
          value: cam.recOnAlarm,
          onChanged: (v) {
            cam.recOnAlarm = v;
            changed();
          }),
      const SizedBox(height: 6),
      Wrap(spacing: 8, children: [
        OutlinedButton.icon(
            onPressed: () => s.testAlarm(), icon: const Icon(Icons.notifications_active_outlined, size: 18), label: const Text('Test alarm')),
        if (s.alarmActive)
          FilledButton.tonalIcon(
              onPressed: () => s.silence(), icon: const Icon(Icons.volume_off, size: 18), label: const Text('Silence')),
      ]),
      const SizedBox(height: 16),
      const Text('RECENT ALARMS', style: TextStyle(fontSize: 11, color: kMuted, letterSpacing: 1)),
      if (s.events.isEmpty)
        const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('None yet', style: TextStyle(color: kMuted, fontSize: 12))),
      ...s.events.take(10).map((d) => ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.warning_amber, size: 18, color: Colors.redAccent),
            title: Text('${d.year}-${two(d.month)}-${two(d.day)}  ${two(d.hour)}:${two(d.minute)}:${two(d.second)}'),
          )),
      const SizedBox(height: 12),
      const Text(
          'Detection looks for movement inside the zones (people, animals, vehicles, also strong light changes). '
          'It works while the app is open and the stream is live.',
          style: TextStyle(fontSize: 11, color: kMuted)),
    ]);
  }

  Widget _sdTab() => SdCardTab(session: s, onvif: _onvif, log: _ptzLog);

  Future<void> _savePreset() async {
    final c = TextEditingController(text: 'Position ${_presets.length + 1}');
    final name = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Save current position'),
              content: LField(
                  controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'Preset name')),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('Save')),
              ],
            ));
    if (name == null || name.isEmpty) return;
    await _do((o) async {
      await o.savePreset(name);
      final pr = await o.presets();
      if (mounted) setState(() => _presets = pr);
    });
    _toast('Preset saved');
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 90, child: Text(k, style: const TextStyle(color: kMuted, fontSize: 12))),
          Expanded(child: SelectableText(v, style: const TextStyle(fontSize: 12))),
        ]),
      );

  Widget _infoTab() {
    final cam = s.cam;
    final report = 'Camera: ${cam.name}\nStream: ${cam.maskedUrl}\nState: ${s.state.name} ${s.msg}\n'
        'ONVIF: ${cam.onvifUrl ?? '-'}\nPTZ: $_ptzMsg\n\nPlayer log:\n${s.lastLog}\n\nRecorder log:\n${s.recLog.join('\n')}\n\nONVIF log:\n${_ptzLog.join('\n')}';
    return ListView(padding: const EdgeInsets.all(16), children: [
      _kv('Name', cam.name),
      _kv('Host', cam.host),
      _kv('Stream', cam.maskedUrl),
      _kv('Rec stream', cam.recRtsp == null ? 'same as live' : (cam.recInfo ?? cam.recRtsp!)),
      _kv('State', '${s.state.name}${s.isLive ? '  ${s.w}×${s.h}' : ''}'),
      _kv('ONVIF', cam.onvifUrl ?? 'not linked'),
      _kv('PTZ', _ptzMsg),
      const SizedBox(height: 12),
      Row(children: [
        const Text('DIAGNOSTICS', style: TextStyle(fontSize: 11, color: kMuted, letterSpacing: 1)),
        const Spacer(),
        TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: report));
              _toast('Copied');
            },
            icon: const Icon(Icons.copy, size: 14),
            label: const Text('Copy')),
      ]),
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: kPanel, border: Border.all(color: kLine), borderRadius: BorderRadius.circular(6)),
        child: SelectableText(
            'Player: ${s.lastLog.isEmpty ? '-' : s.lastLog}\n\nRecorder:\n${s.recLog.isEmpty ? '-' : s.recLog.join('\n')}\n\nONVIF:\n${_ptzLog.isEmpty ? '-' : _ptzLog.join('\n')}',
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: kMuted)),
      ),
    ]);
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => PopScope(
        canPop: !(kTv && _ptzKeys),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) setState(() => _ptzKeys = false);
        },
        child: Scaffold(
        appBar: AppBar(
          title: Row(children: [
            Icon(Icons.circle, size: 9, color: stateColor(s.state)),
            const SizedBox(width: 8),
            Text(s.cam.name),
            const SizedBox(width: 10),
            if (s.isLive)
              Text('${s.w}×${s.h}', style: const TextStyle(fontSize: 12, color: kMuted)),
          ]),
        ),
        body: Focus(
          canRequestFocus: false,
          child: LayoutBuilder(builder: (context, bc) {
            final video = Focus(
              focusNode: _videoFocus,
              autofocus: true,
              onFocusChange: (f) => setState(() => _vf = f),
              onKeyEvent: _onKey,
              child: Container(
              decoration: BoxDecoration(
                  color: Colors.black,
                  border: (_vf && kTv) ? Border.all(color: kAccent, width: 3) : null),
              child: Stack(fit: StackFit.expand, children: [
                ZoomableVideo(
                    session: s,
                    editZones: _editZones,
                    onZonesChanged: () {
                      widget.onChanged();
                      setState(() {});
                    }),
                StatusOverlay(s),
                if (kTv)
                  Positioned(
                      left: 10,
                      bottom: 10,
                      right: 170,
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                          child: Text(
                              '${_ptzKeys ? 'PTZ mode · arrows move · OK or Back to exit' : 'Press OK for PTZ mode'}  ·  PTZ: $_ptzMsg',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12)),
                        ),
                      )),
                if (s.recording && s.recStart != null)
                  Positioned(right: 10, top: 10, child: RecTimer(s.recStart!)),
              ]),
            ));
            final panel = DefaultTabController(
              length: 5,
              child: Column(children: [
                const TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
                  Tab(text: 'Controls'),
                  Tab(text: 'PTZ'),
                  Tab(text: 'Alarm'),
                  Tab(text: 'SD card'),
                  Tab(text: 'Info'),
                ]),
                Expanded(child: TabBarView(children: [_controlsTab(), _ptzTab(), _alarmTab(), _sdTab(), _infoTab()])),
              ]),
            );
            if (bc.maxWidth >= 900) {
              return Row(children: [
                Expanded(child: Center(child: AspectRatio(aspectRatio: 16 / 9, child: video))),
                const VerticalDivider(width: 1),
                SizedBox(width: 360, child: panel),
              ]);
            }
            return Column(children: [
              AspectRatio(aspectRatio: 16 / 9, child: video),
              Expanded(child: panel),
            ]);
          }),
        ),
      )),
    );
  }
}
