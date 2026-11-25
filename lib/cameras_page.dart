import 'package:flutter/material.dart';

import 'app_state.dart';
import 'camera.dart';
import 'session.dart';
import 'widgets.dart';

/// Manage cameras: list, edit, remove.
class CamerasPage extends StatelessWidget {
  const CamerasPage({
    super.key,
    required this.app,
    required this.onOpen,
    required this.onAdd,
    required this.onEdit,
    required this.onRemove,
    required this.onDiscover,
  });

  final AppState app;
  final void Function(Session) onOpen;
  final VoidCallback onAdd, onDiscover;
  final void Function(Camera) onEdit, onRemove;

  Future<void> _maximize(BuildContext context) async {
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(
            content: Row(children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Expanded(child: Text('Setting every camera to its best stream…')),
        ])));
    final report = await app.maximizeQuality();
    if (!context.mounted) return;
    Navigator.of(context).pop();
    await showDialog(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Maximum quality'),
              content: SingleChildScrollView(child: Text(report)),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
            ));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
          child: Row(children: [
            const Text('Cameras', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const Spacer(),
            OutlinedButton.icon(
                onPressed: onDiscover, icon: const Icon(Icons.radar, size: 18), label: const Text('Discover')),
            const SizedBox(width: 8),
            FilledButton.icon(
                onPressed: onAdd, icon: const Icon(Icons.add, size: 18), label: const Text('Add camera')),
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'max') {
                  await _maximize(context);
                  return;
                }
                if (v != 'clear') return;
                final ok = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                          title: const Text('Remove all cameras?'),
                          content: const Text('Recordings and snapshots are kept.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove all')),
                          ],
                        ));
                if (ok == true) app.removeAll();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'max', child: Text('Set all cameras to maximum quality')),
                PopupMenuItem(value: 'clear', child: Text('Remove all cameras')),
              ],
            ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: app.cams.isEmpty
              ? const Center(child: Text('No cameras', style: TextStyle(color: kMuted)))
              : ListView.separated(
                  itemCount: app.cams.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final cam = app.cams[i];
                    final s = app.sessionOf(cam);
                    return ListenableBuilder(
                      listenable: s,
                      builder: (_, __) => ListTile(
                        onTap: () => onOpen(s),
                        leading: Icon(Icons.circle, size: 12, color: stateColor(s.state)),
                        title: Text(cam.name),
                        subtitle: Text(
                            '${cam.host}  ·  ${stateLabel(s.state).toLowerCase()}'
                            '${s.isLive ? '  ${s.w}×${s.h}' : ''}'
                            '${cam.onvifUrl != null ? '  ·  PTZ linked' : ''}',
                            style: const TextStyle(fontSize: 12, color: kMuted)),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                              tooltip: 'Edit',
                              icon: const Icon(Icons.edit_outlined, size: 20),
                              onPressed: () => onEdit(cam)),
                          IconButton(
                              tooltip: 'Remove',
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () => onRemove(cam)),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}
