import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'app_state.dart';
import 'session.dart';
import 'platform.dart';
import 'widgets.dart';
import 'zoom_view.dart';

class LivePage extends StatelessWidget {
  const LivePage({
    super.key,
    required this.app,
    required this.onOpen,
    required this.onAdd,
    required this.onDiscover,
    required this.toast,
    this.onQuit,
  });

  final AppState app;
  final void Function(Session) onOpen;
  final VoidCallback onAdd, onDiscover;
  final void Function(String) toast;
  final VoidCallback? onQuit;

  Future<void> _bulk(Future<void> Function(Session s) f, String done) async {
    for (final s in app.all) {
      try {
        await f(s);
      } catch (_) {}
    }
    toast(done);
  }

  Widget _header(BuildContext context) {
    final all = app.all;
    return ListenableBuilder(
      listenable: Listenable.merge(all),
      builder: (_, __) {
        final live = all.where((s) => s.isLive).length;
        final rec = all.where((s) => s.recording).length;
        final err = all.where((s) => s.state == SState.error).length;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
          child: Row(children: [
            const Text('Live', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(width: 14),
            Flexible(
              child: Text(
                '${all.length} cameras · $live live'
                '${rec > 0 ? ' · $rec recording' : ''}${err > 0 ? ' · $err with errors' : ''}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: err > 0 ? Colors.orangeAccent : kMuted, fontSize: 13),
              ),
            ),
            const Spacer(),
            PopupMenuButton<int>(
              tooltip: 'Layout',
              icon: const Icon(Icons.grid_view_outlined, size: 20),
              initialValue: app.cols,
              onSelected: app.setCols,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 0, child: Text('Auto')),
                PopupMenuItem(value: 1, child: Text('1 column')),
                PopupMenuItem(value: 2, child: Text('2 columns')),
                PopupMenuItem(value: 3, child: Text('3 columns')),
                PopupMenuItem(value: 4, child: Text('4 columns')),
              ],
            ),
            IconButton(
                tooltip: 'Start all streams',
                icon: const Icon(Icons.play_arrow_outlined),
                onPressed: () => _bulk((s) => s.start(), 'Starting all streams')),
            IconButton(
                tooltip: 'Close all streams',
                icon: const Icon(Icons.stop_outlined),
                onPressed: () => _bulk((s) => s.stop(), 'All streams closed')),
            IconButton(
                tooltip: rec > 0 ? 'Stop all recordings' : 'Record all',
                icon: Icon(rec > 0 ? Icons.stop_circle_outlined : Icons.fiber_manual_record,
                    color: Colors.redAccent, size: 20),
                onPressed: () => rec > 0
                    ? _bulk((s) async {
                        if (s.recording) await s.toggleRecord();
                      }, 'Recordings saved')
                    : _bulk((s) async {
                        if (s.isLive && !s.recording) await s.toggleRecord();
                      }, 'Recording all live cameras')),
            IconButton(
                tooltip: 'Snapshot all',
                icon: const Icon(Icons.photo_camera_outlined),
                onPressed: () => _bulk((s) async {
                      if (s.isLive) await s.snapshot();
                    }, 'Snapshots saved')),
            if (onQuit != null)
              IconButton(
                  tooltip: 'Exit LanCam',
                  icon: const Icon(Icons.power_settings_new),
                  onPressed: onQuit),
          ]),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        if (!app.loaded) return const Center(child: CircularProgressIndicator());
        if (app.cams.isEmpty) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.videocam_off_outlined, size: 44, color: kMuted),
              const SizedBox(height: 12),
              const Text('No cameras yet', style: TextStyle(fontSize: 16)),
              const SizedBox(height: 4),
              const Text('Find cameras on your network or add one manually.',
                  style: TextStyle(color: kMuted, fontSize: 13)),
              const SizedBox(height: 18),
              Row(mainAxisSize: MainAxisSize.min, children: [
                FilledButton.icon(
                    onPressed: onDiscover, icon: const Icon(Icons.radar, size: 18), label: const Text('Find cameras')),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                    onPressed: onAdd, icon: const Icon(Icons.add, size: 18), label: const Text('Add manually')),
              ]),
            ]),
          );
        }
        return Column(children: [
          _header(context),
          Expanded(
            child: LayoutBuilder(builder: (context, bc) {
              final n = app.cams.length;
              var cols = app.cols == 0 ? (bc.maxWidth / 460).floor().clamp(1, 4) : app.cols;
              if (cols > n) cols = n;
              return GridView.builder(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols, childAspectRatio: 16 / 9, crossAxisSpacing: 10, mainAxisSpacing: 10),
                itemCount: n,
                itemBuilder: (_, i) {
                  final s = app.sessionOf(app.cams[i]);
                  return CameraTile(key: ObjectKey(s), session: s, autofocus: i == 0, onOpen: () => onOpen(s), toast: toast);
                },
              );
            }),
          ),
        ]);
      },
    );
  }
}

/// One camera on the dashboard. Controls appear on hover (Mac) or always (phone).
class CameraTile extends StatefulWidget {
  const CameraTile({super.key, required this.session, required this.onOpen, required this.toast, this.autofocus = false});
  final bool autofocus;
  final Session session;
  final VoidCallback onOpen;
  final void Function(String) toast;
  @override
  State<CameraTile> createState() => _CameraTileState();
}

class _CameraTileState extends State<CameraTile> {
  bool _hover = false, _focused = false;
  final _fn = FocusNode();
  Session get s => widget.session;

  @override
  void dispose() {
    _fn.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() f, [String? ok]) async {
    try {
      await f();
      if (ok != null) widget.toast(ok);
    } catch (e) {
      widget.toast('$e'.replaceFirst('Exception: ', ''));
    }
  }

  Widget _btn(IconData i, String tip, VoidCallback f, {Color? color}) => IconButton(
      visualDensity: VisualDensity.compact,
      iconSize: 19,
      tooltip: tip,
      color: color ?? Colors.white,
      onPressed: f,
      icon: Icon(i));

  @override
  Widget build(BuildContext context) {
    final touch = Platform.isAndroid || Platform.isIOS;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final closed = s.state == SState.stopped || s.state == SState.error;
        final showBar = !kTv && (touch || _hover);
        return Focus(
            focusNode: _fn,
            autofocus: widget.autofocus,
            onFocusChange: (f) => setState(() => _focused = f),
            onKeyEvent: (n, e) {
              if (e is KeyDownEvent && isOkKey(e.logicalKey)) {
                widget.onOpen();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onOpen,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: _focused ? kAccent : ((s.recording || s.alarmActive) ? Colors.redAccent : kLine),
                      width: _focused ? 4 : ((s.recording || s.alarmActive) ? 2 : 1))),
              child: Stack(fit: StackFit.expand, children: [
                Video(controller: s.video, controls: NoVideoControls),
                StatusOverlay(s),
                if (s.cam.zones.isNotEmpty)
                  IgnorePointer(child: CustomPaint(painter: ZonePainter(s), size: Size.infinite)),
                // name + state
                Positioned(
                  left: 8,
                  top: 8,
                  right: 90,
                  child: Row(children: [
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration:
                            BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.circle, size: 8, color: stateColor(s.state)),
                          const SizedBox(width: 6),
                          Flexible(
                              child: Text(s.cam.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                        ]),
                      ),
                    ),
                  ]),
                ),
                if (s.recording && s.recStart != null)
                  Positioned(right: 8, top: 8, child: RecTimer(s.recStart!)),
                if (s.recError != null && !s.recording)
                  Positioned(
                      right: 8,
                      top: 8,
                      child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(color: Colors.orange.shade800, borderRadius: BorderRadius.circular(6)),
                          child: const Text('REC FAILED', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)))),
                if (s.alarmActive)
                  Positioned(
                      left: 8,
                      bottom: 40,
                      child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(color: Colors.red.shade700, borderRadius: BorderRadius.circular(6)),
                          child: const Text('ALARM', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)))),
                // controls
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity: showBar ? 1 : 0,
                    child: ExcludeFocus(
                      excluding: !showBar,
                      child: IgnorePointer(
                      ignoring: !showBar,
                      child: Container(
                        decoration: const BoxDecoration(
                            gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [Colors.black87, Colors.transparent])),
                        padding: const EdgeInsets.fromLTRB(8, 18, 4, 2),
                        child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                          _btn(closed ? Icons.play_arrow : Icons.stop, closed ? 'Start stream' : 'Close stream',
                              () => closed ? s.start() : s.stop()),
                          _btn(s.recording ? Icons.stop_circle_outlined : Icons.fiber_manual_record,
                              s.recording ? 'Stop recording' : 'Record',
                              () => _guard(s.toggleRecord, s.recording ? 'Recording saved' : 'Recording started'),
                              color: Colors.redAccent),
                          _btn(Icons.photo_camera_outlined, 'Snapshot', () => _guard(() async {
                                final p = await s.snapshot();
                                widget.toast(p == null ? 'Snapshot failed' : 'Snapshot saved');
                              })),
                          _btn(Icons.open_in_full, 'Open · PTZ', widget.onOpen),
                        ]),
                      ),
                    )),
                  ),
                ),
              ]),
            ),
          ),
        ));
      },
    );
  }
}
