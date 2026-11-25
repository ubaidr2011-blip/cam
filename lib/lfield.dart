import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'platform.dart';
import 'tv_keyboard.dart';

/// Text field used everywhere in the app. On phones/Mac it is a normal TextField.
/// On Google TV it never uses the (unreliable) system keyboard: pressing OK on the
/// remote, or clicking with the mouse, opens LanCam's own on-screen keyboard.
class LField extends StatelessWidget {
  const LField({
    super.key,
    required this.controller,
    this.decoration = const InputDecoration(),
    this.obscureText = false,
    this.keyboardType,
    this.onChanged,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final InputDecoration decoration;
  final bool obscureText;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    if (!kTv) {
      return TextField(
        controller: controller,
        decoration: decoration,
        obscureText: obscureText,
        keyboardType: keyboardType,
        onChanged: onChanged,
        autofocus: autofocus,
      );
    }
    void open() => openTvKeyboard(context, controller, obscure: obscureText, onChanged: onChanged);
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (node, e) {
        if (e is KeyDownEvent && isOkKey(e.logicalKey)) {
          open();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: TextField(
        controller: controller,
        decoration: decoration,
        obscureText: obscureText,
        readOnly: true, // no system keyboard at all
        showCursor: true,
        enableInteractiveSelection: false,
        autofocus: autofocus,
        onTap: open,
      ),
    );
  }
}
