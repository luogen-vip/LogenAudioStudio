import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import '../services/engine.dart';
import '../services/importer.dart';
import '../services/repo.dart';
import '../services/storage.dart';
import '../widgets/waveform_view.dart';

class EditorPage extends StatefulWidget {
  final AudioTask task;
  const EditorPage({super.key, required this.task});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  late AudioTask task = widget.task;
  int trackIndex = 0;
  double selStart = 0;
  double selEnd = 0;
  double playhead = 0;
  bool rendering = false;
  bool exporting = false;
  double exportProgress = 0;
  String? statusText;

  final AudioPlayer _player = AudioPlayer();
  String? _loadedPreview;
  String? _previewSig;
  bool _selMode = false;
  Timer? _fxTimer;
  double? _resumeAt;

  Track get track => task.tracks[trackIndex];
  TrackSettings get settings => track.settings;
  double get duration => track.duration;

  @override
  void initState() {
    super.initState();
    _player.positionStream.listen((p) {
      if (!mounted) return;
      setState(() => playhead = p.inMilliseconds / 1000.0);
    });
    _player.playerStateStream.listen((s) {
      if (!mounted) return;
      if (s.processingState == ProcessingState.completed) {
        setState(() => playhead = 0);
      }
      setState(() {});
    });
    selEnd = duration;
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<String> _cacheDir() async {
    final dir = await getTemporaryDirectory();
    final sub = Directory('${dir.path}/preview');
    if (!await sub.exists()) await sub.create(recursive: true);
    return sub.path;
  }

  String _sig() => '${track.id}_${settings.signature}_${task.trimStart}_${task.trimEnd}'.hashCode.toString();

  Future<void> _preview({bool selectionOnly = false}) async {
    if (rendering) return;
    _selMode = selectionOnly;
    final wasPlaying = _player.playing;
    _resumeAt = wasPlaying ? _player.position.inMilliseconds / 1000.0 : null;
    final sig = selectionOnly ? '${_sig()}_sel_${selStart}_${selEnd}' : _sig();
    setState(() {
      rendering = true;
      statusText = selectionOnly ? '正在渲染选区…' : '正在渲染试听…';
    });
    try {
      // 没改过任何参数：直接播原文件，秒开
      if (!selectionOnly && track.settings.isPristine && task.trimStart <= 0) {
        await _player.stop();
        await _player.setFilePath(track.path);
        _loadedPreview = track.path;
        _previewSig = sig;
        _player.play();
        if (mounted) setState(() => statusText = null);
        return;
      }
      final dir = await _cacheDir();
      // 试听也吃裁剪：设了裁剪范围就只渲染那一段
      final start = selectionOnly
          ? selStart
          : (task.trimStart > 0 ? task.trimStart : null);
      final end = selectionOnly
          ? selEnd
          : (task.effectiveEnd > 0 ? task.effectiveEnd : null);
      final path = '$dir/$sig.wav';
      final err = await Engine.instance.renderPreview(
        track: track,
        outPath: path,
        start: start,
        end: end,
      );
      if (err != null) {
        _toast('渲染失败：$err');
        return;
      }
      _loadedPreview = path;
      _previewSig = sig;
      await _player.stop();
      await _player.setFilePath(path);
      final resume = _resumeAt;
      if (resume != null && resume > 0.1) {
        final maxPos = _player.duration?.inMilliseconds != null
            ? _player.duration!.inMilliseconds / 1000.0 - 0.2
            : resume;
        final target = resume > maxPos ? maxPos : resume;
        if (target > 0) await _player.seek(Duration(milliseconds: (target * 1000).round()));
      }
      _player.play();
      if (mounted) setState(() => statusText = null);
    } catch (e) {
      _toast('试听失败：$e');
    } finally {
      if (mounted) setState(() => rendering = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  bool get _isPlaying =>
      _player.playing && _player.processingState != ProcessingState.completed;

  Future<void> _pause() async {
    if (_isPlaying) {
      await _player.pause();
      if (mounted) setState(() {});
      return;
    }
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
      _player.play();
      if (mounted) setState(() {});
      return;
    }
    final fresh = _loadedPreview != null &&
        File(_loadedPreview!).existsSync() &&
        _previewSig == _sig();
    if (fresh) {
      _player.play();
      setState(() {});
    } else {
      await _preview();
    }
  }

  void _onSelDragStart() {
    if (_player.playing) {
      _player.pause();
    }
  }

  /// 松手后再重渲染（新选区）并自动从选区起点播，不打断手感
  void _onSelDragEnd() {
    if (!_selMode) return;
    _fxTimer?.cancel();
    _fxTimer = Timer(const Duration(milliseconds: 180), () {
      if (mounted) _preview(selectionOnly: true);
    });
  }

  /// 参数改了：正在放的话，停一下再按新参数重渲染，然后从原位置接着放
  void _scheduleFx() {
    _fxTimer?.cancel();
    if (!_player.playing) return;
    _fxTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted && _player.playing) _preview(selectionOnly: _selMode);
    });
  }

  Future<void> _seek(double seconds) async {
    try {
      if (_loadedPreview != null) {
        await _player.seek(Duration(milliseconds: (seconds * 1000).round()));
        setState(() => playhead = seconds);
      } else {
        setState(() => playhead = seconds);
      }
    } catch (_) {}
  }

  void _setSelection(double a, double b) {
    setState(() {
      selStart = math.max(0, a);
      selEnd = math.min(duration, b);
    });
  }

  void _applyRegionGain(double gain) {
    if (selEnd - selStart < 0.05) {
      _toast('先在波形上拖出一段区间');
      return;
    }
    setState(() {
      final existing = settings.regions.where((r) => (r.start - selStart).abs() < 0.01 && (r.end - selEnd).abs() < 0.01);
      if (existing.isNotEmpty) {
        existing.first.gainDb = gain;
      } else {
        settings.regions.add(RegionEdit(start: selStart, end: selEnd, gainDb: gain));
      }
    });
    _persist();
  }

  void _removeRegion(RegionEdit r) {
    setState(() => settings.regions.remove(r));
    _persist();
  }

  void _resetAll() {
    setState(() => settings.reset());
    _loadedPreview = null;
    _persist();
    _toast('已恢复默认（原始音频参数）');
  }

  void _persist() {
    Repo.instance.touch();
  }

  Future<void> _separate() async {
    if (rendering) return;
    setState(() {
      rendering = true;
      statusText = '正在分析频谱、分离人声和伴奏…（长歌要十几秒）';
    });
    try {
      final dir = '${Repo.instance.audioDir.path}/${task.id}';
      final res = await Engine.instance.separateDeep(track, dir);
      if (res['error'] != null) {
        _toast('分离失败：${res['error']}');
        return;
      }
      final vocalPath = res['vocal']!;
      final instPath = res['inst']!;
      final vInfo = await Engine.instance.probe(vocalPath);
      final iInfo = await Engine.instance.probe(instPath);
      final vPeaks = await Engine.instance.peaks(vocalPath);
      final iPeaks = await Engine.instance.peaks(instPath);
      setState(() {
        task.tracks.add(Track(
          id: '${DateTime.now().microsecondsSinceEpoch}_v',
          name: vocalPath.split('/').last,
          path: vocalPath,
          duration: vInfo.duration,
          sampleRate: vInfo.sampleRate,
          channels: vInfo.channels,
          peaks: vPeaks,
          role: 'vocal',
        ));
        task.tracks.add(Track(
          id: '${DateTime.now().microsecondsSinceEpoch}_i',
          name: instPath.split('/').last,
          path: instPath,
          duration: iInfo.duration,
          sampleRate: iInfo.sampleRate,
          channels: iInfo.channels,
          peaks: iPeaks,
          role: 'inst',
        ));
        track.muted = true;
        trackIndex = task.tracks.length - 2;
        selStart = 0;
        selEnd = task.tracks[trackIndex].duration;
      });
      await Repo.instance.touch();

      _toast('分离完成：人声 + 伴奏已加入，原轨已静音。'
          '这是频谱法（重复伴奏当背景减掉），伴奏很干净的歌会分得不错，'
          '混响重、伴奏不重复的歌还会留残响');
    } catch (e) {
      _toast('分离异常：$e');
    } finally {
      if (mounted) setState(() {
        rendering = false;
        statusText = null;
      });
    }
  }

  Future<void> _addTrack() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.audio, allowMultiple: false, withData: false);
      final path = result?.files.firstOrNull?.path;
      if (path == null) return;
      setState(() => statusText = '正在导入音轨…');
      final t = await Importer.instance.buildTrack(
        srcPath: path,
        taskId: task.id,
        role: task.tracks.length == 1 && task.tracks.first.role == 'song' ? 'inst' : 'vocal',
      );
      task.tracks.add(t);
      await Repo.instance.touch();
      if (!mounted) return;
      setState(() {
        trackIndex = task.tracks.length - 1;
        statusText = null;
        selStart = 0;
        selEnd = task.tracks.last.duration;
      });
    } catch (e) {
      _toast('加轨失败：$e');
    } finally {
      if (mounted) setState(() => statusText = null);
    }
  }

  Future<void> _export({required bool mixAll, required ExportConfig config}) async {
    setState(() {
      exporting = true;
      exportProgress = 0;
    });
    try {
      final dir = await Storage.instance.outputDir();
      final stamp = DateTime.now();
      final suffix = mixAll ? 'mix' : track.role;
      final name = '${_safe(task.title)}_${suffix}_${stamp.month}${stamp.day}_${stamp.hour}${stamp.minute}${stamp.second}.${config.format}';
      final out = '${dir.path}/$name';
      String? err;
      if (mixAll) {
        err = await Engine.instance.renderMix(
          tracks: task.tracks,
          outPath: out,
          config: config,
          start: task.trimStart,
          end: task.effectiveEnd,
        );
      } else {
        err = await Engine.instance.renderTrack(
          track: track,
          outPath: out,
          config: config,
          start: task.trimStart,
          end: task.effectiveEnd,
        );
      }
      if (err != null) {
        _toast('导出失败：$err');
        return;
      }
      final size = File(out).lengthSync();
      task.lastExportPath = out;
      task.lastExportLabel = '$name（${(size / 1024 / 1024).toStringAsFixed(1)}MB）';
      await Repo.instance.touch();
      _toast('导出成功：${dir.path}/$name');
    } catch (e) {
      _toast('导出异常：$e');
    } finally {
      if (mounted) {
        setState(() {
          exporting = false;
          exportProgress = 0;
        });
      }
    }
  }

  String _safe(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(task.title, style: const TextStyle(fontSize: 17)),
        actions: [
          IconButton(
            tooltip: '恢复默认',
            icon: const Icon(Icons.restart_alt),
            onPressed: _resetAll,
          ),
          IconButton(
            tooltip: '导出',
            icon: const Icon(Icons.ios_share),
            onPressed: exporting ? null : _showExportSheet,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _trackChips(),
            const SizedBox(height: 12),
            WaveformView(
              peaks: track.peaks,
              duration: duration,
              selStart: selStart,
              selEnd: selEnd,
              playhead: playhead,
              onSelection: _setSelection,
              onSeek: _seek,
              onDragStart: _onSelDragStart,
              onDragEnd: _onSelDragEnd,
            ),
            const SizedBox(height: 8),
            _timeRow(),
            const SizedBox(height: 8),
            _transport(),
            if (statusText != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Text(statusText!, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ],
              ),
            ],
            const SizedBox(height: 16),
            _sectionTitle('区间编辑（拖波形选段，只改这一段）'),
            _regionCard(),
            const SizedBox(height: 16),
            _sectionTitle('整轨调音'),
            _sliderRow('音量增益', settings.gainDb, -24, 24, 'dB', (v) => setState(() => settings.gainDb = v)),
            _sliderRow('低切（去低频浑浊）', settings.lowCut, 0, 400, 'Hz', (v) => setState(() => settings.lowCut = v)),
            _sliderRow('低频厚度', settings.bassDb, -12, 12, 'dB', (v) => setState(() => settings.bassDb = v)),
            _sliderRow('高频亮度', settings.trebleDb, -12, 12, 'dB', (v) => setState(() => settings.trebleDb = v)),
            _sliderRow('混响', settings.reverb, 0, 100, '%', (v) => setState(() => settings.reverb = v)),
            _sliderRow('变调（旋律升降，速度不变）', settings.pitch.toDouble(), -12, 12, '半音',
                (v) => setState(() => settings.pitch = v.round())),
            _sliderRow('速度', settings.speed, 0.5, 2.0, 'x', (v) => setState(() => settings.speed = v)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('压缩 / 限幅（防爆音，出“发行质感”）', style: TextStyle(fontSize: 14)),
              value: settings.compress,
              onChanged: (v) => setState(() => settings.compress = v),
            ),
            const SizedBox(height: 4),
            Text(
              settings.isPristine ? '当前就是原始音频参数' : '已改动，点「试听」听真实效果',
              style: const TextStyle(fontSize: 12, color: Colors.white38),
            ),
            const SizedBox(height: 16),
            _sectionTitle('裁剪'),
            _trimCard(),
            const SizedBox(height: 16),
            _sectionTitle('音轨与合成'),
            _mixCard(),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(t, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white70)),
      );

  Widget _trackChips() {
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (int i = 0; i < task.tracks.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(
                  '${_roleName(task.tracks[i].role)} ${i + 1}',
                  style: TextStyle(fontSize: 12, color: trackIndex == i ? Colors.black : Colors.white70),
                ),
                selected: trackIndex == i,
                selectedColor: const Color(0xFF22D3EE),
                backgroundColor: const Color(0xFF16202A),
                onSelected: (_) {
                  setState(() {
                    trackIndex = i;
                    selStart = 0;
                    selEnd = task.tracks[i].duration;
                    playhead = 0;
                  });
                },
              ),
            ),
          ActionChip(
            avatar: const Icon(Icons.add, size: 16, color: Color(0xFF22D3EE)),
            label: const Text('加一轨', style: TextStyle(fontSize: 12, color: Color(0xFF22D3EE))),
            backgroundColor: const Color(0xFF0E2A33),
            onPressed: _addTrack,
          ),
        ],
      ),
    );
  }

  String _roleName(String role) {
    switch (role) {
      case 'vocal':
        return '人声';
      case 'inst':
        return '伴奏';
      default:
        return '整曲';
    }
  }

  Widget _timeRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(_fmt(selStart), style: const TextStyle(fontSize: 12, color: Color(0xFF22D3EE))),
        Text('选区 ${_fmt(selStart)} - ${_fmt(selEnd)}（${(selEnd - selStart).toStringAsFixed(2)}s）',
            style: const TextStyle(fontSize: 11, color: Colors.white38)),
        Text(_fmt(duration), style: const TextStyle(fontSize: 12, color: Colors.white54)),
      ],
    );
  }

  Widget _transport() {
    return Row(
      children: [
        FilledButton.icon(
          onPressed: rendering ? null : _pause,
          icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, size: 20),
          label: Text(_isPlaying ? '暂停' : '试听'),
        ),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          onPressed: rendering ? null : () => _preview(selectionOnly: true),
          icon: const Icon(Icons.highlight_alt, size: 18),
          label: const Text('试听选区'),
        ),
        const Spacer(),
        if (rendering) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      ],
    );
  }

  Widget _regionCard() {
    final active = settings.regions.where((r) => !r.isEmpty).toList();
    final current = active.where((r) => (r.start - selStart).abs() < 0.01 && (r.end - selEnd).abs() < 0.01).toList();
    final gain = current.isNotEmpty ? current.first.gainDb : 0.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '已标记 ${active.length} 段',
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Text('选区增益', style: TextStyle(fontSize: 13)),
                Expanded(
                  child: Slider(
                    value: gain,
                    min: -24,
                    max: 24,
                    divisions: 48,
                    label: '${gain.toStringAsFixed(1)}dB',
                    onChanged: (v) => setState(() {
                      final cur = settings.regions.where((r) => (r.start - selStart).abs() < 0.01 && (r.end - selEnd).abs() < 0.01);
                      if (cur.isNotEmpty) {
                        cur.first.gainDb = v;
                      } else if (selEnd - selStart > 0.05) {
                        settings.regions.add(RegionEdit(start: selStart, end: selEnd, gainDb: v));
                      }
                    }),
                    onChangeEnd: (_) => _persist(),
                  ),
                ),
                Text('${gain.toStringAsFixed(0)}dB', style: const TextStyle(fontSize: 12, color: Color(0xFF22D3EE))),
              ],
            ),
            Row(
              children: [
                OutlinedButton(
                  onPressed: () => _applyRegionGain(0),
                  child: const Text('归零', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 8),
                if (active.isNotEmpty)
                  OutlinedButton(
                    onPressed: () => _removeRegion(active.last),
                    child: const Text('删除最后一段', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            if (active.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in active)
                    Chip(
                      label: Text('${_fmt(r.start)}-${_fmt(r.end)} ${r.gainDb.toStringAsFixed(0)}dB',
                          style: const TextStyle(fontSize: 11)),
                      deleteIcon: const Icon(Icons.close, size: 14),
                      onDeleted: () => _removeRegion(r),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sliderRow(String label, double value, double min, double max, String unit, ValueChanged<double> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
            Text(
              '${value.toStringAsFixed(unit == '半音' || unit == 'x' ? 1 : 0)}$unit',
              style: const TextStyle(fontSize: 12, color: Color(0xFF22D3EE)),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: (v) {
            setState(() => onChanged(v));
            _scheduleFx();
          },
          onChangeEnd: (_) => _persist(),
        ),
      ],
    );
  }

  Widget _trimCard() {
    final start = task.trimStart;
    final end = task.effectiveEnd;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('裁剪区间：${_fmt(start)} - ${_fmt(end)}（导出与「试听裁剪段」按这个范围）',
                style: const TextStyle(fontSize: 12, color: Colors.white54)),
            const SizedBox(height: 10),
            Row(
              children: [
                OutlinedButton(
                  onPressed: () {
                    setState(() {
                      task.trimStart = selStart;
                      task.trimEnd = selEnd;
                    });
                    _persist();
                    _toast('已把选区设为裁剪范围');
                  },
                  child: const Text('用选区当裁剪', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () async {
                    await _preview(selectionOnly: true);
                  },
                  child: const Text('试听裁剪段', style: TextStyle(fontSize: 12)),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    setState(() {
                      task.trimStart = 0;
                      task.trimEnd = 0;
                    });
                    _persist();
                  },
                  child: const Text('整段', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _mixCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: rendering ? null : _separate,
                      icon: const Icon(Icons.call_split, size: 18),
                      label: const Text('分离成人声 + 伴奏', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
              child: Text(
                '频谱分离：把重复的伴奏当背景减掉，剩下人声；单声道 / AI 合成歌也能分，比声道法靠谱',
                style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.35), height: 1.5),
              ),
            ),
            for (int i = 0; i < task.tracks.length; i++)
              ListTile(
                dense: true,
                title: Text('${_roleName(task.tracks[i].role)} · ${task.tracks[i].name}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                subtitle: Text('${_fmt(task.tracks[i].duration)}', style: const TextStyle(fontSize: 11)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: task.tracks[i].muted ? '取消静音' : '静音（不参与混音）',
                      icon: Icon(task.tracks[i].muted ? Icons.volume_off : Icons.volume_up, size: 18),
                      onPressed: () {
                        setState(() => task.tracks[i].muted = !task.tracks[i].muted);
                        _persist();
                      },
                    ),
                  ],
                ),
              ),
            if (task.tracks.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: FilledButton.icon(
                  onPressed: exporting ? null : () => _export(mixAll: true, config: const ExportConfig(format: 'wav')),
                  icon: const Icon(Icons.merge_type, size: 18),
                  label: const Text('直接合成一首（默认 WAV）'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _fmt(double s) {
    if (s <= 0) return '0:00';
    final m = s ~/ 60;
    final sec = (s % 60).floor();
    final ms = ((s % 1) * 10).floor();
    return '$m:${sec.toString().padLeft(2, '0')}.$ms';
  }

  void _showExportSheet() {
    String format = 'wav';
    int sr = 44100;
    int channels = 2;
    int bitrate = 192;
    bool mixAll = task.tracks.length > 1;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF121A22),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSheet) {
          return Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('导出音频', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 14),
                const Text('格式', style: TextStyle(fontSize: 12, color: Colors.white54)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final f in ['wav', 'mp3'])
                      ChoiceChip(
                        label: Text(f.toUpperCase(), style: TextStyle(fontSize: 12, color: format == f ? Colors.black : Colors.white70)),
                        selected: format == f,
                        selectedColor: const Color(0xFF22D3EE),
                        backgroundColor: const Color(0xFF16202A),
                        onSelected: (_) => setSheet(() => format = f),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('采样率', style: TextStyle(fontSize: 12, color: Colors.white54)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final s in [44100, 48000])
                      ChoiceChip(
                        label: Text('${s}Hz${s == 44100 ? '（发行常用）' : ''}', style: TextStyle(fontSize: 12, color: sr == s ? Colors.black : Colors.white70)),
                        selected: sr == s,
                        selectedColor: const Color(0xFF22D3EE),
                        backgroundColor: const Color(0xFF16202A),
                        onSelected: (_) => setSheet(() => sr = s),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('声道', style: TextStyle(fontSize: 12, color: Colors.white54)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final c in [2, 1])
                      ChoiceChip(
                        label: Text(c == 2 ? '立体声（双声道）' : '单声道', style: TextStyle(fontSize: 12, color: channels == c ? Colors.black : Colors.white70)),
                        selected: channels == c,
                        selectedColor: const Color(0xFF22D3EE),
                        backgroundColor: const Color(0xFF16202A),
                        onSelected: (_) => setSheet(() => channels = c),
                      ),
                  ],
                ),
                if (format == 'mp3') ...[
                  const SizedBox(height: 12),
                  const Text('MP3 比特率', style: TextStyle(fontSize: 12, color: Colors.white54)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final b in [128, 192, 256, 320])
                        ChoiceChip(
                          label: Text('${b}k', style: TextStyle(fontSize: 12, color: bitrate == b ? Colors.black : Colors.white70)),
                          selected: bitrate == b,
                          selectedColor: const Color(0xFF22D3EE),
                          backgroundColor: const Color(0xFF16202A),
                          onSelected: (_) => setSheet(() => bitrate = b),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('多轨合成（人声 + 伴奏）', style: TextStyle(fontSize: 13)),
                  value: mixAll && task.tracks.length > 1,
                  onChanged: task.tracks.length > 1 ? (v) => setSheet(() => mixAll = v) : null,
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: exporting
                        ? null
                        : () {
                            Navigator.pop(ctx);
                            _export(
                              mixAll: mixAll && task.tracks.length > 1,
                              config: ExportConfig(
                                format: format,
                                sampleRate: sr,
                                channels: channels,
                                bitrate: bitrate,
                              ),
                            );
                          },
                    icon: const Icon(Icons.save_alt),
                    label: const Text('导出到 Download/LogenAudioStudio'),
                  ),
                ),
              ],
            ),
          );
        });
      },
    );
  }
}
