import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/track.dart';

class Repo {
  Repo._();
  static final Repo instance = Repo._();

  Directory? _root;
  Directory? _audioDir;
  final List<AudioTask> tasks = [];
  bool loaded = false;

  Directory get root => _root!;
  Directory get audioDir => _audioDir!;

  File get _dbFile => File('${_root!.path}/tasks.json');

  Future<void> init() async {
    final support = await getApplicationSupportDirectory();
    _root = Directory('${support.path}/workspace');
    _audioDir = Directory('${_root!.path}/audio');
    if (!await _audioDir!.exists()) {
      await _audioDir!.create(recursive: true);
    }
    loaded = true;
    await load();
  }

  Future<void> load() async {
    tasks.clear();
    if (!await _dbFile.exists()) return;
    try {
      final text = await _dbFile.readAsString();
      final data = jsonDecode(text) as Map<String, dynamic>;
      final list = (data['tasks'] as List?) ?? [];
      for (final item in list) {
        try {
          final t = AudioTask.fromJson(item as Map<String, dynamic>);
          // 修正丢失的文件引用：文件真的不在了，任务保留但标记出来
          t.tracks.removeWhere((tr) => !File(tr.path).existsSync());
          if (t.tracks.isNotEmpty) tasks.add(t);
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> save() async {
    try {
      final payload = {
        'version': 1,
        'savedAt': DateTime.now().toIso8601String(),
        'tasks': tasks.map((e) => e.toJson()).toList(),
      };
      final tmp = File('${_dbFile.path}.tmp');
      await tmp.writeAsString(jsonEncode(payload), flush: true);
      await tmp.rename(_dbFile.path);
    } catch (_) {}
  }

  Future<void> addTask(AudioTask task) async {
    tasks.insert(0, task);
    await save();
  }

  Future<void> removeTask(String id) async {
    tasks.removeWhere((t) => t.id == id);
    final dir = Directory('${_audioDir!.path}/$id');
    if (await dir.exists()) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
    await save();
  }

  Future<void> touch() => save();

  /// 把用户选中的文件复制进应用私有目录，原文件删了也不影响任务
  Future<String> importFile(String srcPath, String taskId, String fileName) async {
    final dir = Directory('${_audioDir!.path}/$taskId');
    if (!await dir.exists()) await dir.create(recursive: true);
    final dst = File('${dir.path}/$fileName');
    await File(srcPath).copy(dst.path);
    return dst.path;
  }

  String newId() => '${DateTime.now().microsecondsSinceEpoch}';
}
