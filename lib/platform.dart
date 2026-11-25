import 'package:flutter/services.dart';

/// True in the Google TV / Android TV build (flutter build --dart-define=TV_MODE=true).
const bool kTv = bool.fromEnvironment('TV_MODE', defaultValue: false);

/// The remote's centre / OK button (and Enter / gamepad A).
bool isOkKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.select ||
    k == LogicalKeyboardKey.enter ||
    k == LogicalKeyboardKey.numpadEnter ||
    k == LogicalKeyboardKey.gameButtonA;
