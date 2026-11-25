import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// Common RTSP paths used by many brands. {u}/{p} = username/password.
/// Lighter sub-streams first, main streams after.
const kProbePaths = <String>[
  'Streaming/Channels/102', // Hikvision sub
  'Streaming/Channels/101', // Hikvision main
  'cam/realmonitor?channel=1&subtype=1', // Dahua / Amcrest sub
  'cam/realmonitor?channel=1&subtype=0', // Dahua / Amcrest main
  'stream2', // Tapo / TP-Link sub
  'stream1', // Tapo / TP-Link main
  'h264Preview_01_sub', // Reolink
  'h264Preview_01_main',
  'live/ch1',
  'live/ch0',
  'videoSub', // Foscam
  'videoMain',
  'user={u}&password={p}&channel=1&stream=1.sdp?real_stream', // XMEye / generic Chinese DVR
  'user={u}&password={p}&channel=1&stream=0.sdp?real_stream',
  '11',
  '12',
  '1',
  'h264',
  'live',
  'live.sdp',
  'ch0_1.h264',
  'axis-media/media.amp',
  'onvif1',
  'media/video2',
  'media/video1',
  'video1',
  'cam1/h264',
  'MediaInput/h264',
  'profile2/media.smp',
  'profile1/media.smp',
  '0/video1',
  '',
];

/// Opens [url] in a throw-away player and returns true if a video track shows up.
Future<bool> probeUrl(String url,
    {Duration timeout = const Duration(seconds: 6)}) async {
  final player = Player();
  final subs = <StreamSubscription>[];
  try {
    final np = player.platform as NativePlayer;
    await np.setProperty('demuxer-lavf-o', 'rtsp_transport=tcp');
    await np.setProperty('network-timeout', '5');
    await player.setVolume(0);
    final done = Completer<bool>();
    void finish(bool v) {
      if (!done.isCompleted) done.complete(v);
    }

    subs.add(player.stream.error.listen((_) => finish(false)));
    subs.add(player.stream.tracks.listen((t) {
      if (t.video.any((v) => v.id != 'auto' && v.id != 'no')) finish(true);
    }));
    subs.add(player.stream.width.listen((w) {
      if ((w ?? 0) > 0) finish(true);
    }));
    await player.open(Media(url));
    return await done.future.timeout(timeout, onTimeout: () => false);
  } catch (_) {
    return false;
  } finally {
    for (final s in subs) {
      await s.cancel();
    }
    await player.dispose();
  }
}
