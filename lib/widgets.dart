import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'platform.dart';
import 'session.dart';

// Design tokens
const kBg = Color(0xFF0B0D10);
const kPanel = Color(0xFF14181D);
const kLine = Color(0xFF242B34);
const kAccent = Color(0xFF4C8DF6);
const kMuted = Color(0xFF8B95A3);

Color stateColor(SState s) => switch (s) {
      SState.live => Colors.greenAccent,
      SState.connecting => Colors.amber,
      SState.error => Colors.redAccent,
      SState.stopped => Colors.grey,
    };

String stateLabel(SState s) => switch (s) {
      SState.live => 'LIVE',
      SState.connecting => 'CONNECTING',
      SState.error => 'ERROR',
      SState.stopped => 'STOPPED',
    };

/// Small pill: coloured dot + state (+ resolution when live).
class StateChip extends StatelessWidget {
  const StateChip(this.s, {super.key});
  final Session s;

  @override
  Widget build(BuildContext context) {
    final res = s.isLive && s.w > 0 ? '  ${s.w}×${s.h}' : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration:
          BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.circle, size: 9, color: stateColor(s.state)),
        const SizedBox(width: 5),
        Text('${stateLabel(s.state)}$res',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// Covers the video while it is not live: spinner / start button / error + retry.
class StatusOverlay extends StatelessWidget {
  const StatusOverlay(this.s, {super.key});
  final Session s;

  @override
  Widget build(BuildContext context) {
    if (s.isLive) return const SizedBox.shrink();
    final Widget child;
    switch (s.state) {
      case SState.connecting:
        child = Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(height: 8),
          Text(s.msg, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ]);
      case SState.stopped:
        child = Column(mainAxisSize: MainAxisSize.min, children: [
          IconButton.filled(
              iconSize: 34, icon: const Icon(Icons.play_arrow), onPressed: () => s.start()),
          const SizedBox(height: 4),
          const Text('Stream closed', style: TextStyle(color: Colors.white70, fontSize: 12)),
        ]);
      default:
        child = Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, color: Colors.orangeAccent),
          const SizedBox(height: 4),
          Text(s.msg,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
          TextButton.icon(
              onPressed: () => s.start(),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry')),
        ]);
    }
    return Container(
        color: const Color(0xFF0F1216),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(10),
        child: child);
  }
}

/// "● REC 00:12" badge that ticks every second.
class RecTimer extends StatefulWidget {
  const RecTimer(this.start, {super.key});
  final DateTime start;
  @override
  State<RecTimer> createState() => _RecTimerState();
}

class _RecTimerState extends State<RecTimer> {
  Timer? _t;
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = DateTime.now().difference(widget.start);
    String two(int n) => n.toString().padLeft(2, '0');
    final txt = '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: Colors.red.shade700, borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.fiber_manual_record, size: 10, color: Colors.white),
        const SizedBox(width: 4),
        Text('REC $txt', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
      ]),
    );
  }
}


/// Round button that fires [onDown] while pressed and [onUp] on release (for PTZ).
class HoldButton extends StatefulWidget {
  const HoldButton(
      {super.key, required this.icon, required this.onDown, required this.onUp, this.size = 54});
  final IconData icon;
  final VoidCallback onDown, onUp;
  final double size;
  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton> {
  bool _down = false, _focused = false;

  void _press(bool d) {
    if (d == _down) return;
    setState(() => _down = d);
    d ? widget.onDown() : widget.onUp();
  }

  @override
  Widget build(BuildContext context) => Focus(
        onFocusChange: (f) => setState(() => _focused = f),
        onKeyEvent: (node, e) {
          if (!isOkKey(e.logicalKey)) return KeyEventResult.ignored;
          if (e is KeyDownEvent) _press(true);
          if (e is KeyUpEvent) _press(false);
          return KeyEventResult.handled;
        },
        child: Listener(
          onPointerDown: (_) => _press(true),
          onPointerUp: (_) => _press(false),
          onPointerCancel: (_) => _press(false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _down ? kAccent : const Color(0xFF1C222A),
                border: Border.all(color: _focused ? Colors.white : (_down ? kAccent : kLine), width: _focused ? 3 : 1)),
            child: Icon(widget.icon, size: widget.size * 0.5),
          ),
        ),
      );
}

/// Circular PTZ joystick: 4 directions + home in the middle, zoom +/- on the side.
class PtzPad extends StatelessWidget {
  const PtzPad({super.key, required this.move, required this.stop, required this.home});
  final void Function(double pan, double tilt, double zoom) move;
  final VoidCallback stop, home;

  @override
  Widget build(BuildContext context) {
    Widget dir(IconData i, double pan, double tilt) =>
        HoldButton(icon: i, onDown: () => move(pan, tilt, 0), onUp: stop, size: 52);
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      SizedBox(
        width: 190,
        height: 190,
        child: Stack(alignment: Alignment.center, children: [
          Container(
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: kPanel,
                  border: Border.all(color: kLine, width: 1.5))),
          Align(alignment: Alignment.topCenter, child: Padding(padding: const EdgeInsets.only(top: 8), child: dir(Icons.keyboard_arrow_up, 0, 1))),
          Align(alignment: Alignment.bottomCenter, child: Padding(padding: const EdgeInsets.only(bottom: 8), child: dir(Icons.keyboard_arrow_down, 0, -1))),
          Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.only(left: 8), child: dir(Icons.keyboard_arrow_left, -1, 0))),
          Align(alignment: Alignment.centerRight, child: Padding(padding: const EdgeInsets.only(right: 8), child: dir(Icons.keyboard_arrow_right, 1, 0))),
          IconButton(
              tooltip: 'Home position',
              style: IconButton.styleFrom(backgroundColor: const Color(0xFF1C222A)),
              onPressed: home,
              icon: const Icon(Icons.home_outlined)),
        ]),
      ),
      const SizedBox(width: 24),
      Column(mainAxisSize: MainAxisSize.min, children: [
        HoldButton(icon: Icons.add, onDown: () => move(0, 0, 1), onUp: stop, size: 48),
        const SizedBox(height: 6),
        const Text('ZOOM', style: TextStyle(fontSize: 10, color: kMuted, letterSpacing: 1)),
        const SizedBox(height: 6),
        HoldButton(icon: Icons.remove, onDown: () => move(0, 0, -1), onUp: stop, size: 48),
      ]),
    ]);
  }
}
