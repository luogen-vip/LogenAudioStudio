import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../models/track.dart';
import '../services/importer.dart';
import '../services/repo.dart';
import '../services/storage.dart';
import 'editor_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _busy = false;
  String _busyText = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (!Repo.instance.loaded) {
      await Repo.instance.init();
    }
    setState(() {});
  }

  Future<void> _pickAndCreate({required bool twoTracks}) async {
    if (_busy) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: twoTracks,
        withData: false,
      );
      if (result == null || result.files.isEmpty) return;
      final paths = result.files.where((f) => f.path != null).map((f) => f.path!).toList();
      if (paths.isEmpty) return;
      if (twoTracks && paths.length < 2) {
        _toast('这个模式要选两条音频：先人声，再伴奏');
        return;
      }
      setState(() {
        _busy = true;
        _busyText = '正在导入并分析波形…';
      });
      final task = await Importer.instance.createTask(files: paths);
      await Repo.instance.addTask(task);
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('已导入：${task.title}');
      _openEditor(task);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('导入失败：$e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _openEditor(AudioTask task) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPage(task: task)));
    setState(() {});
  }

  Future<void> _deleteTask(AudioTask task) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除工程'),
        content: Text('「${task.title}」和它的音频副本会被删掉，确定吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await Repo.instance.removeTask(task.id);
    setState(() {});
  }

  void _showImportSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121A22),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('新建工程', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.audio_file),
              title: const Text('导入整首歌'),
              subtitle: const Text('一条音频，整轨调音 / 裁剪 / 导出'),
              onTap: () {
                Navigator.pop(ctx);
                _pickAndCreate(twoTracks: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.call_split),
              title: const Text('导入人声 + 伴奏两条'),
              subtitle: const Text('分别精修，最后混音合成一首'),
              onTap: () {
                Navigator.pop(ctx);
                _pickAndCreate(twoTracks: true);
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _openExport(String path) async {
    if (!File(path).existsSync()) {
      _toast('文件已经被移走了');
      return;
    }
    await OpenFilex.open(path);
  }

  @override
  Widget build(BuildContext context) {
    final tasks = Repo.instance.tasks;
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('罗根音频工作室', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
            Text('Logen Audio Studio · by 罗根', style: TextStyle(fontSize: 11, color: Colors.white38)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '关于',
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showAbout(),
          ),
        ],
      ),
      body: _busy
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(_busyText, style: const TextStyle(color: Colors.white54)),
                ],
              ),
            )
          : tasks.isEmpty
              ? _emptyState()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                  itemCount: tasks.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, i) => _taskCard(tasks[i]),
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _showImportSheet,
        icon: const Icon(Icons.add),
        label: const Text('导入音频'),
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.graphic_eq, size: 64, color: Color(0xFF22D3EE)),
            const SizedBox(height: 16),
            const Text('还没有工程', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text(
              '点右下角导入一段音频，\n波形、调音、裁剪、混音、导出都在里面。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, height: 1.6),
            ),
            const SizedBox(height: 28),
            Text(
              '导出的成品会存到\nDownload/LogenAudioStudio',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 12, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }

  Widget _taskCard(AudioTask task) {
    final roles = task.tracks.map((t) => t.role).toSet();
    final label = roles.contains('vocal') && roles.contains('inst')
        ? '人声 + 伴奏'
        : (task.tracks.length > 1 ? '${task.tracks.length} 条音轨' : '单轨');
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openEditor(task),
        onLongPress: () => _deleteTask(task),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.multitrack_audio, color: Color(0xFF22D3EE), size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: '删除',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.delete_outline, size: 20, color: Colors.white38),
                    onPressed: () => _deleteTask(task),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '$label · ${_fmt(task.duration)} · ${_ago(task.createdAt)}',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
              if (task.lastExportPath != null) ...[
                const SizedBox(height: 10),
                InkWell(
                  onTap: () => _openExport(task.lastExportPath!),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0E2A33),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.play_circle_outline, size: 16, color: Color(0xFF22D3EE)),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '打开成品：${task.lastExportLabel ?? ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, color: Color(0xFF22D3EE)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(double seconds) {
    if (seconds <= 0) return '--:--';
    final m = seconds ~/ 60;
    final s = (seconds % 60).floor();
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String _ago(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  void _showAbout() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('罗根音频工作室'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('作者：罗根\nLogen Audio Studio v1.0', style: TextStyle(height: 1.7)),
            const SizedBox(height: 12),
            FutureBuilder<Directory>(
              future: Storage.instance.outputDir(),
              builder: (context, snap) => Text(
                '导出目录：\n${snap.data?.path ?? 'Download/LogenAudioStudio'}',
                style: const TextStyle(fontSize: 12, color: Colors.white54, height: 1.6),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final ok = await Storage.instance.ensurePermission();
              if (ctx.mounted) {
                Navigator.pop(ctx);
                _toast(ok ? '存储权限已就绪' : '权限没给，「所有文件访问」需要手动打开');
              }
            },
            child: const Text('检查存储权限'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }
}
