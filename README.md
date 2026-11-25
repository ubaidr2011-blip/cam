# LanCam – IP camera viewer for Android + macOS

Features: ONVIF auto-discovery (+ subnet scan fallback), multi-camera live grid,
PTZ (pan/tilt/zoom/presets), local recording to `.mkv` (lossless, no re-encode),
recordings browser/playback.

## 1. Create the project shell

```bash
flutter create --platforms=android,macos lancam
cd lancam
# copy pubspec.yaml and lib/ from this folder over the generated ones
flutter pub get
```

## 2. Android setup

`android/app/src/main/AndroidManifest.xml` – inside `<manifest>` (before `<application>`):

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>
<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE"/>
```

and on the `<application>` tag add: `android:usesCleartextTraffic="true"`
(ONVIF/RTSP on a LAN is plain HTTP/RTSP).

In `android/app/build.gradle(.kts)` set `minSdk = 21` (media_kit requirement).

## 3. macOS setup

Add to **both** `macos/Runner/DebugProfile.entitlements` and `Release.entitlements`:

```xml
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.network.server</key><true/>
```

Add to `macos/Runner/Info.plist`:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Find and stream from IP cameras on your network.</string>
<key>NSAppTransportSecurity</key>
<dict><key>NSAllowsArbitraryLoads</key><true/></dict>
```

Set macOS deployment target to 11.0+ in `macos/Podfile` (`platform :osx, '11.0'`).

## 4. Run

```bash
flutter run -d macos
flutter run -d <android-device>
# release
flutter build apk --release
flutter build macos --release
```

## Usage

- **Radar icon**: finds ONVIF cameras (WS-Discovery) and any host with RTSP port 554 open.
  Tap one, enter username/password, done.
- **+**: add manually. Enter an IP (ONVIF → PTZ works), or a full `rtsp://…` URL (view-only).
  Typical RTSP URLs: Hikvision `rtsp://IP:554/Streaming/Channels/101`,
  Dahua `rtsp://IP:554/cam/realmonitor?channel=1&subtype=0`, Tapo `rtsp://IP:554/stream1`.
- **Tap a tile**: full view, hold arrow/zoom buttons to move PTZ, ● to record.
- **Long-press a tile**: remove camera.
- Recordings live in the app documents folder under `Recordings/`.

## Troubleshooting

- **401/ONVIF error**: wrong password, or camera clock differs from the phone by more than
  a few minutes (ONVIF digest auth is time-based). Enable NTP on the camera.
- **Tapo/some cameras**: create a separate "Camera Account" in the Tapo app and enable ONVIF/RTSP.
- **Nothing discovered on Android**: some phones drop multicast; the subnet scan fallback should
  still list RTSP hosts. Use sub-streams (low res) for the grid if you have many cameras.
- **Android recording location** is app-private; add the `share_plus` package if you want
  to export clips to the gallery.
