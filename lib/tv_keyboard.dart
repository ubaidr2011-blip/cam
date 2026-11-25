import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'widgets.dart';

/// Opens LanCam's own on-screen keyboard for [c].
Future<void> openTvKeyboard(BuildContext context, TextEditingController c,
    {bool obscure = false, ValueChanged<String>? onChanged}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kPanel,
    builder: (_) => TvKeyboard(controller: c, obscure: obscure, onChanged: onChanged),
  );
}

class TvKeyboard extends StatefulWidget {
  const TvKeyboard({super.key, required this.controller, this.obscure = false, this.onChanged});
  final TextEditingController controller;
  final bool obscure;
  final ValueChanged<String>? onChanged;

  @override
  State<TvKeyboard> createState() => _TvKeyboardState();
}

class _TvKeyboardState extends State<TvKeyboard> {
  bool _shift = false, _sym = false, _show = false;

  TextEditingController get c => widget.controller;

  int get _pos {
    final s = c.selection;
    return s.isValid ? math.min(s.extentOffset, c.text.length) : c.text.length;
  }

  void _changed() {
    widget.onChanged?.call(c.text);
    setState(() {});
  }

  void _insert(String s) {
    final v = c.value;
    final sel = v.selection;
    final start = sel.isValid ? math.min(sel.start, v.text.length) : v.text.length;
    final end = sel.isValid ? math.min(sel.end, v.text.length) : v.text.length;
    c.value = TextEditingValue(
        text: v.text.replaceRange(start, end, s), selection: TextSelection.collapsed(offset: start + s.length));
    _changed();
  }

  void _backspace() {
    final v = c.value;
    final sel = v.selection;
    var start = sel.isValid ? math.min(sel.start, v.text.length) : v.text.length;
    final end = sel.isValid ? math.min(sel.end, v.text.length) : v.text.length;
    if (start == end) {
      if (start == 0) return;
      start -= 1;
    }
    c.value = TextEditingValue(
        text: v.text.replaceRange(start, end, ''), selection: TextSelection.collapsed(offset: start));
    _changed();
  }

  void _move(int d) {
    c.selection = TextSelection.collapsed(offset: math.max(0, math.min(c.text.length, _pos + d)));
    setState(() {});
  }

  String _label(String ch) => (!_sym && _shift) ? ch.toUpperCase() : ch;

  Widget _k(String label, VoidCallback f,
      {int flex = 2, IconData? icon, bool primary = false, bool autofocus = false}) {
    final style = ButtonStyle(
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      side: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.focused) ? const BorderSide(color: Colors.white, width: 3) : null),
    );
    final child = icon != null ? Icon(icon, size: 22) : Text(label, style: const TextStyle(fontSize: 18));
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: SizedBox(
          height: 46,
          child: primary
              ? FilledButton(autofocus: autofocus, style: style, onPressed: f, child: child)
              : FilledButton.tonal(autofocus: autofocus, style: style, onPressed: f, child: child),
        ),
      ),
    );
  }

  Widget _chars(String chars, {bool first = false}) => Row(children: [
        for (var i = 0; i < chars.length; i++)
          _k(_label(chars[i]), () => _insert(_label(chars[i])), autofocus: first && i == 0),
      ]);

  @override
  Widget build(BuildContext context) {
    final text = c.text;
    final shown = widget.obscure && !_show ? '•' * text.length : text;
    final pos = math.min(_pos, shown.length);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                    color: kBg, border: Border.all(color: kLine), borderRadius: BorderRadius.circular(8)),
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: shown.substring(0, pos)),
                    const TextSpan(text: '│', style: TextStyle(color: kAccent)),
                    TextSpan(text: shown.substring(pos)),
                  ]),
                  style: const TextStyle(fontSize: 20),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            IconButton(tooltip: 'Cursor left', icon: const Icon(Icons.chevron_left), onPressed: () => _move(-1)),
            IconButton(tooltip: 'Cursor right', icon: const Icon(Icons.chevron_right), onPressed: () => _move(1)),
            if (widget.obscure)
              IconButton(
                  tooltip: 'Show / hide',
                  icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _show = !_show)),
            IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () {
                  c.value = const TextEditingValue();
                  _changed();
                }),
          ]),
          const SizedBox(height: 8),
          if (!_sym) ...[
            _chars('1234567890'),
            _chars('qwertyuiop', first: true),
            _chars('asdfghjkl'),
            Row(children: [
              _k('', () => setState(() => _shift = !_shift), flex: 3, icon: _shift ? Icons.keyboard_capslock : Icons.arrow_upward),
              for (final ch in 'zxcvbnm'.split('')) _k(_label(ch), () => _insert(_label(ch))),
              _k('', _backspace, flex: 3, icon: Icons.backspace_outlined),
            ]),
          ] else ...[
            _chars('!@#\$%^&*()'),
            _chars('-_=+[]{}|\\'),
            _chars(';:\'",<>/?`'),
            Row(children: [
              for (final ch in '~?!=+#'.split('')) _k(ch, () => _insert(ch)),
              _k('', _backspace, flex: 3, icon: Icons.backspace_outlined),
            ]),
          ],
          Row(children: [
            _k(_sym ? 'ABC' : '?123', () => setState(() => _sym = !_sym), flex: 3),
            _k('@', () => _insert('@')),
            _k('/', () => _insert('/')),
            _k(':', () => _insert(':')),
            _k('', () => _insert(' '), flex: 6, icon: Icons.space_bar),
            _k('.', () => _insert('.')),
            _k('-', () => _insert('-')),
            _k('_', () => _insert('_')),
            _k('Done', () => Navigator.of(context).pop(), flex: 3, primary: true),
          ]),
        ]),
      ),
    );
  }
}
