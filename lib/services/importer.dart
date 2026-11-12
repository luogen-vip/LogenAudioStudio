import '../models/track.dart';
import 'engine.dart';
import 'repo.dart';

class Importer {
  Importer._();
  static final Importer instance = Importer._();

  Future<Track> buildTrack({
    required String srcPath,
    required String taskId,
    required String role,
    String? displayName,
  }) async {
    final name = displayName ?? srcPath.split('/').last;
    final stored = await Repo.instance.importFile(srcPath, taskId, name);
    final info = await Engine.instance.probe(stored);
    final peaks = await Engine.instance.peaks(stored);
    return Track(
      id: '${DateTime.now().microsecondsSinceEpoch}_${role}_${name.hashCode.abs()}',
      name: name,
      path: stored,
      duration: info.duration,
      sampleRate: info.sampleRate,
      channels: info.channels,
      peaks: peaks,
      role: role,
    );
  }

  Future<AudioTask> createTask({
    required List<String> files,
    String? title,
    List<String>? roles,
  }) async {
    final taskId = Repo.instance.newId();
    final task = AudioTask(
      id: taskId,
      title: title ?? _defaultTitle(files),
      createdAt: DateTime.now(),
    );
    for (int i = 0; i < files.length; i++) {
      final role = roles != null && i < roles.length ? roles[i] : (files.length > 1 ? (i == 0 ? 'vocal' : 'inst') : 'song');
      task.tracks.add(await buildTrack(srcPath: files[i], taskId: taskId, role: role));
    }
    return task;
  }

  String _defaultTitle(List<String> files) {
    if (files.isEmpty) return '未命名工程';
    final base = files.first.split('/').last;
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }
}
