import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Alarm zone, normalized (0..1) to the video frame.
class Zone {
  Zone(this.l, this.t, this.r, this.b);
  double l, t, r, b;

  List<double> toJson() => [l, t, r, b];
  factory Zone.fromJson(List j) => Zone(
      (j[0] as num).toDouble(), (j[1] as num).toDouble(), (j[2] as num).toDouble(), (j[3] as num).toDouble());
}

class Camera {
  Camera({
    required this.id,
    required this.name,
    required this.rtsp,
    this.onvifUrl,
    this.user = '',
    this.pass = '',
    List<Zone>? zones,
    this.alarmOn = false,
    this.sens = 0.5,
    this.recOnAlarm = true,
    this.alarmSound = true,
    this.recRtsp,
    this.liveInfo,
    this.recInfo,
  }) : zones = zones ?? [];

  String id, name, rtsp, user, pass;

  /// ONVIF device_service URL (needed for PTZ). Auto-detected when null.
  String? onvifUrl;

  /// Optional separate (usually HD) stream used only for recording.
  String? recRtsp, liveInfo, recInfo;

  // Intrusion alarm
  List<Zone> zones;
  bool alarmOn, recOnAlarm, alarmSound;
  double sens; // 0..1, higher = more sensitive

  String get host => Uri.tryParse(rtsp)?.host ?? '';

  /// RTSP URL with credentials embedded (if not already present).
  String get streamUrl {
    final u = Uri.parse(rtsp);
    if (u.userInfo.isNotEmpty || user.isEmpty) return rtsp;
    return u
        .replace(
            userInfo:
                '${Uri.encodeComponent(user)}:${Uri.encodeComponent(pass)}')
        .toString();
  }

  /// Address used for recording: the recording stream if set, else the live one.
  String get recUrl {
    final r = recRtsp;
    if (r == null || r.isEmpty) return streamUrl;
    final u = Uri.parse(r);
    if (u.userInfo.isNotEmpty || user.isEmpty) return r;
    return u
        .replace(userInfo: '${Uri.encodeComponent(user)}:${Uri.encodeComponent(pass)}')
        .toString();
  }

  /// Same as [streamUrl] but with credentials hidden (safe to display).
  String get maskedUrl =>
      streamUrl.replaceFirst(RegExp(r'//[^@/]*@'), '//***@');

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'rtsp': rtsp,
        'onvifUrl': onvifUrl,
        'user': user,
        'pass': pass,
        'zones': zones.map((z) => z.toJson()).toList(),
        'alarmOn': alarmOn,
        'sens': sens,
        'recOnAlarm': recOnAlarm,
        'alarmSound': alarmSound,
        'recRtsp': recRtsp,
        'liveInfo': liveInfo,
        'recInfo': recInfo,
      };

  factory Camera.fromJson(Map<String, dynamic> j) => Camera(
        id: j['id'],
        name: j['name'],
        rtsp: j['rtsp'],
        onvifUrl: j['onvifUrl'],
        user: j['user'] ?? '',
        pass: j['pass'] ?? '',
        zones: ((j['zones'] as List?) ?? []).map((e) => Zone.fromJson(e as List)).toList(),
        alarmOn: j['alarmOn'] ?? false,
        sens: (j['sens'] as num?)?.toDouble() ?? 0.5,
        recOnAlarm: j['recOnAlarm'] ?? true,
        alarmSound: j['alarmSound'] ?? true,
        recRtsp: j['recRtsp'],
        liveInfo: j['liveInfo'],
        recInfo: j['recInfo'],
      );
}

class CameraStore {
  static const _key = 'cameras_v1';

  static Future<List<Camera>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map((e) => Camera.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> save(List<Camera> cams) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(cams.map((c) => c.toJson()).toList()));
  }
}
