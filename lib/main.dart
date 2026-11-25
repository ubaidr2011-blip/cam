import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'app_state.dart';
import 'camera.dart';
import 'camera_page.dart';
import 'cameras_page.dart';
import 'dialogs.dart';
import 'live_page.dart';
import 'platform.dart';
import 'recordings.dart';
import 'session.dart';
import 'settings.dart';
import 'settings_page.dart';
import 'widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await settings.load();
  runApp(const LanCamApp());
}

class LanCamApp extends StatelessWidget {
  const LanCamApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: kBg,
      focusColor: kAccent.withAlpha(70),
      dividerColor: kLine,
      colorScheme: const ColorScheme.dark(
        primary: kAccent,
        secondary: kAccent,
        surface: kPanel,
        onSurface: Color(0xFFE6E9EE),
      ),
      appBarTheme: const AppBarTheme(
          backgroundColor: kBg, elevation: 0, scrolledUnderElevation: 0, centerTitle: false),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
    return MaterialApp(
      title: 'LanCam',
      debugShowCheckedModeBanner: false,
      theme: base,
      builder: (context, child) {
        final c = child ?? const SizedBox.shrink();
        if (!kTv) return c;
        // Bigger text for viewing from the sofa
        return MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.2)), child: c);
      },
      home: const Shell(),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  final app = AppState();
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    app.load();
  }

  @override
  void dispose() {
    app.closeAll();
    super.dispose();
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));
  }

  Future<void> _add({String? address}) async {
    final cam = await showDialog<Camera>(
        context: context,
        builder: (_) => CameraDialog(initialAddress: address, others: app.cams));
    if (cam != null) await app.upsert(cam);
  }

  Future<void> _edit(Camera c) async {
    final cam = await showDialog<Camera>(
        context: context, builder: (_) => CameraDialog(existing: c, others: app.cams));
    if (cam != null) await app.upsert(cam);
  }

  Future<void> _remove(Camera c) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
              title: Text('Remove ${c.name}?'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
              ],
            ));
    if (ok == true) await app.remove(c);
  }

  Future<void> _discover() async {
    final known = app.cams.map((c) => c.host).toSet();
    final addr = await showModalBottomSheet<String>(
        context: context, builder: (_) => DiscoverSheet(known: known));
    if (addr != null) _add(address: addr);
  }

  void _open(Session s) => Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => CameraPage(session: s, onChanged: () => app.save())));

  Future<void> _quit() async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Exit LanCam?'),
              content: const Text('Streams disconnect and any recording in progress is saved.'),
              actions: [
                TextButton(
                    autofocus: true,
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Exit')),
              ],
            ));
    if (ok != true) return;
    await app.closeAll();
    if (Platform.isAndroid || Platform.isIOS) {
      SystemNavigator.pop();
    } else {
      exit(0);
    }
  }

  Widget _alarmBanner() => ListenableBuilder(
        listenable: app,
        builder: (_, __) => ListenableBuilder(
          listenable: Listenable.merge(app.all),
          builder: (_, __) {
            final al = app.all.where((s) => s.alarmActive).toList();
            if (al.isEmpty) return const SizedBox.shrink();
            final s = al.first;
            return Material(
              color: Colors.red.shade800,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(children: [
                  const Icon(Icons.warning_amber_rounded),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text('Movement in alarm zone · ${s.cam.name}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold))),
                  if (!s.silenced) TextButton(onPressed: s.silence, child: const Text('SILENCE')),
                  TextButton(onPressed: () => _open(s), child: const Text('VIEW')),
                ]),
              ),
            );
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      LivePage(app: app, onOpen: _open, onAdd: _add, onDiscover: _discover, toast: _toast, onQuit: _quit),
      CamerasPage(
          app: app, onOpen: _open, onAdd: _add, onEdit: _edit, onRemove: _remove, onDiscover: _discover),
      const RecordingsPage(),
      SettingsPage(onQuit: _quit, onDecodeChanged: app.rebuildSessions),
    ];
    final wide = MediaQuery.of(context).size.width >= 760;
    Widget framed(Widget page) => Column(children: [_alarmBanner(), Expanded(child: page)]);
    const items = [
      (Icons.videocam_outlined, Icons.videocam, 'Live'),
      (Icons.dns_outlined, Icons.dns, 'Cameras'),
      (Icons.video_library_outlined, Icons.video_library, 'Library'),
      (Icons.tune_outlined, Icons.tune, 'Settings'),
    ];
    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            backgroundColor: kPanel,
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            labelType: NavigationRailLabelType.all,
            leading: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Icon(Icons.shield_outlined, color: kAccent)),
            trailing: Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: IconButton(
                      tooltip: 'Exit LanCam',
                      icon: const Icon(Icons.power_settings_new),
                      onPressed: _quit),
                ),
              ),
            ),
            destinations: [
              for (final it in items)
                NavigationRailDestination(icon: Icon(it.$1), selectedIcon: Icon(it.$2), label: Text(it.$3)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: SafeArea(child: framed(pages[_tab]))),
        ]),
      );
    }
    return Scaffold(
      body: SafeArea(child: framed(pages[_tab])),
      bottomNavigationBar: NavigationBar(
        backgroundColor: kPanel,
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          for (final it in items)
            NavigationDestination(icon: Icon(it.$1), selectedIcon: Icon(it.$2), label: it.$3),
        ],
      ),
    );
  }
}
