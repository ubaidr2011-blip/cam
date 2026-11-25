import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'session.dart';
import 'storage.dart';
import 'widgets.dart';

Future<void> exportFile(String path) async {
  if (Storage.isDesktop) {
    await Process.run('open', ['-R', path]); // reveal in Finder
  } else {
    await Share.shareXFiles([XFile(path)]);
  }
}

class RecordingsPage extends StatefulWidget {
  const RecordingsPage({super.key});
  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  List<File> _videos = [], _photos = [];
  String _folder = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await Storage.listRecordings();
    final sd = await Storage.snapshotsDir();
    final ph = sd.listSync().whereType<File>().toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    final cur = await Storage.recordingsDir();
    if (mounted) setState(() { _videos = v; _photos = ph; _folder = cur.path; });
  }

  String _size(File f) {
    final b = f.lengthSync();
    return b > 1048576 ? '${(b / 1048576).toStringAsFixed(1)} MB' : '${(b / 1024).round()} KB';
  }

  Widget _menu(File f) => PopupMenuButton<String>(
        onSelected: (v) async {
          if (v == 'share') await exportFile(f.path);
          if (v == 'delete') {
            await f.delete();
            _load();
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'share', child: Text(Storage.isDesktop ? 'Show in Finder' : 'Share / Export')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      );

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Library'),
            actions: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _load)],
            bottom: TabBar(tabs: [
              Tab(text: 'Videos (${_videos.length})'),
              Tab(text: 'Snapshots (${_photos.length})'),
            ]),
          ),
          body: TabBarView(children: [
            Column(children: [
              if (_folder.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Align(
                        alignment: Alignment.centerLeft,
                        child: SelectableText('Saving to: $_folder', style: const TextStyle(fontSize: 11, color: kMuted)))),
              Expanded(
                child: _videos.isEmpty
                    ? const Center(child: Text('No recordings yet', style: TextStyle(color: kMuted)))
                    : ListView(
                        children: _videos
                            .map((f) => ListTile(
                                  leading: const Icon(Icons.movie_outlined),
                                  title: Text(p.basename(f.path), style: const TextStyle(fontSize: 14)),
                                  subtitle: Text('${_size(f)} · ${f.lastModifiedSync().toString().split('.').first}',
                                      style: const TextStyle(fontSize: 12)),
                                  trailing: _menu(f),
                                  onTap: () => Navigator.push(
                                      context, MaterialPageRoute(builder: (_) => PlaybackPage(path: f.path))),
                                ))
                            .toList()),
              ),
            ]),
            _photos.isEmpty
                ? const Center(child: Text('No snapshots yet', style: TextStyle(color: kMuted)))
                : GridView.count(
                    crossAxisCount: 3,
                    padding: const EdgeInsets.all(6),
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                    children: _photos
                        .map((f) => GestureDetector(
                              onTap: () => showDialog(
                                  context: context,
                                  builder: (_) => AlertDialog(
                                        contentPadding: const EdgeInsets.all(8),
                                        content: Image.file(f),
                                        actions: [
                                          TextButton(onPressed: () => exportFile(f.path), child: Text(Storage.isDesktop ? 'Show in Finder' : 'Share')),
                                          TextButton(
                                              onPressed: () async {
                                                await f.delete();
                                                if (context.mounted) Navigator.pop(context);
                                                _load();
                                              },
                                              child: const Text('Delete')),
                                          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
                                        ],
                                      )),
                              child: Image.file(f, fit: BoxFit.cover, cacheWidth: 400),
                            ))
                        .toList()),
          ]),
        ),
      );
}

class PlaybackPage extends StatefulWidget {
  const PlaybackPage({super.key, required this.path});
  final String path;
  @override
  State<PlaybackPage> createState() => _PlaybackPageState();
}

class _PlaybackPageState extends State<PlaybackPage> {
  late final player = Player();
  late final controller = makeVideoController(player);

  @override
  void initState() {
    super.initState();
    applyDecoding(player).then((_) => player.open(Media(widget.path)));
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(appBar: AppBar(title: Text(p.basename(widget.path))), body: Video(controller: controller));
}
