import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'dart:math' as math;

import 'spectral.dart';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';

class AudioInfo {
  final double duration;
  final int sampleRate;
  final int channels;
  AudioInfo(this.duration, this.sampleRate, this.channels);
}

class ExportConfig {
  final String format; // wav / mp3
  final int sampleRate; // 44100 / 48000
  final int channels; // 1 / 2
  final int bitrate; // mp3 kbps
  const ExportConfig({
    this.format = 'wav',
    this.sampleRate = 44100,
    this.channels = 2,
    this.bitrate = 192,
  });
}

class Engine {
  Engine._();
  static final Engine instance = Engine._();
  static double _srFallback = 44100;

  Future<AudioInfo> probe(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      final dur = double.tryParse(info?.getDuration() ?? '') ?? 0;
      final streams = info?.getStreams() ?? [];
      int sr = 44100;
      int ch = 2;
      if (streams.isNotEmpty) {
        sr = int.tryParse(streams.first.getSampleRate() ?? '') ?? 44100;
        final layout = streams.first.getChannelLayout() ?? '';
        ch = layout.contains('stereo') ? 2 : (layout.contains('mono') ? 1 : 2);
      }
      _srFallback = sr.toDouble();
      return AudioInfo(dur, sr, ch);
    } catch (_) {
      return AudioInfo(0, 44100, 2);
    }
  }

  /// 解码成 8kHz 单声道原始 PCM，再压成 buckets 个峰值点
  Future<List<double>> peaks(String path, {int buckets = 2400}) async {
    final cacheDir = await getTemporaryDirectory();
    final tmp = '${cacheDir.path}/peaks_${DateTime.now().microsecondsSinceEpoch}.raw';
    final err = await _run([
      '-hide_banner', '-loglevel', 'error', '-y',
      '-i', path, '-vn', '-ac', '1', '-ar', '8000', '-f', 's16le', tmp,
    ]);
    if (err != null) return [];
    try {
      final bytes = await File(tmp).readAsBytes();
      final data = ByteData.sublistView(bytes);
      final samples = bytes.length ~/ 2;
      if (samples == 0) return [];
      final out = List<double>.filled(buckets, 0);
      final per = math.max(1, samples ~/ buckets);
      for (int b = 0; b < buckets; b++) {
        final s0 = b * per;
        final s1 = math.min(samples, s0 + per);
        double peak = 0;
        for (int i = s0; i < s1; i++) {
          final v = data.getInt16(i * 2, Endian.little).abs();
          if (v > peak) peak = v.toDouble();
        }
        out[b] = peak / 32768.0;
      }
      final maxV = out.reduce(math.max);
      if (maxV > 0.02) {
        for (int i = 0; i < out.length; i++) {
          out[i] = (out[i] / maxV).clamp(0.0, 1.0).toDouble();
        }
      }
      return out;
    } catch (_) {
      return [];
    } finally {
      try {
        File(tmp).deleteSync();
      } catch (_) {}
    }
  }

  Future<String?> _run(List<String> args) async {
    try {
      final session = await FFmpegKit.executeWithArguments(args);
      final rc = await session.getReturnCode();
      if (ReturnCode.isSuccess(rc)) return null;
      final logs = await session.getAllLogsAsString() ?? '';
      final lines = logs
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .where((l) => !l.startsWith('ffmpeg version') && !l.startsWith('configuration:') && !l.startsWith('built with'))
          .toList();
      final errLines = lines
          .where((l) => RegExp(r'error|invalid|unknown|unsupported|no such|failed|not found', caseSensitive: false).hasMatch(l))
          .toList();
      if (errLines.isNotEmpty) return errLines.take(3).join('\n');
      if (lines.isNotEmpty) return lines.take(3).join('\n');
      return '处理失败（返回码 ${rc?.getValue()}）';
    } catch (e) {
      return '执行异常：$e';
    }
  }

  /// 返回滤镜链；没有任何改动时返回 null（直接转码，最快最稳）
  String? _buildFilter(Track track, {required String inLabel, required String outLabel, double? trimStart, double? trimEnd}) {
    final s = track.settings;
    final hasRegions = s.regions.any((r) => !r.isEmpty);
    if (!hasRegions && !s.hasGlobalFx) return null;

    final dur = track.duration > 0 ? track.duration : 1e9;
    final cuts = <double>[0];
    if (hasRegions) {
      for (final r in s.regions) {
        if (r.isEmpty) continue;
        if (r.start > 0 && r.start < dur) cuts.add(r.start);
        if (r.end > 0 && r.end < dur) cuts.add(r.end);
      }
    }
    cuts.add(dur);
    cuts.sort();

    final parts = <String>[];
    int idx = 0;
    for (int i = 0; i < cuts.length - 1; i++) {
      final start = cuts[i];
      final end = cuts[i + 1];
      if (end - start < 0.02) continue;
      final active = s.regions
          .where((r) => !r.isEmpty && r.start <= start + 0.0001 && r.end >= end - 0.0001)
          .toList();
      String chain = '';
      if (active.isNotEmpty) {
        final g = active.map((r) => r.gainDb).reduce((a, b) => a + b);
        final lc = active.map((r) => r.lowCut).reduce((a, b) => math.max(a, b));
        if (lc > 0) chain += ',highpass=f=${lc.toStringAsFixed(0)}';
        if (g != 0) chain += ',volume=${g.toStringAsFixed(2)}dB';
      }
      parts.add('[$inLabel]atrim=start=${start.toStringAsFixed(3)}:end=${end.toStringAsFixed(3)}'
          ',asetpts=PTS-STARTPTS$chain[seg$idx]');
      idx++;
    }

    final buffer = StringBuffer();
    for (final p in parts) {
      buffer.write(p);
      buffer.write(';');
    }
    if (idx == 0) {
      buffer.write('[$inLabel]anull[joined];');
    } else if (idx == 1) {
      buffer.write('[seg0]anull[joined];');
    } else {
      final labels = List.generate(idx, (i) => '[seg$i]').join();
      buffer.write('$labels concat=n=$idx:v=0:a=1[joined];');
    }

    final chain = StringBuffer();
    final sr = track.sampleRate > 0 ? track.sampleRate : _srFallback.toInt();
    if (s.pitch != 0) {
      final f = math.pow(2, s.pitch / 12).toDouble();
      chain.write(',asetrate=${(sr * f).round()},aresample=$sr');
      double tempo = 1.0 / f;
      while (tempo > 2.0) {
        chain.write(',atempo=2.0');
        tempo /= 2.0;
      }
      while (tempo < 0.5) {
        chain.write(',atempo=0.5');
        tempo /= 0.5;
      }
      chain.write(',atempo=${tempo.toStringAsFixed(4)}');
    }
    if (s.speed != 1 && s.speed > 0) {
      double tempo = s.speed;
      while (tempo > 2.0) {
        chain.write(',atempo=2.0');
        tempo /= 2.0;
      }
      while (tempo < 0.5) {
        chain.write(',atempo=0.5');
        tempo /= 0.5;
      }
      chain.write(',atempo=${tempo.toStringAsFixed(4)}');
    }
    if (s.lowCut > 0) chain.write(',highpass=f=${s.lowCut.toStringAsFixed(0)}');
    if (s.bassDb != 0) chain.write(',bass=g=${s.bassDb.toStringAsFixed(1)}:f=110');
    if (s.trebleDb != 0) chain.write(',treble=g=${s.trebleDb.toStringAsFixed(1)}:f=3000');
    if (s.compress) {
      chain.write(',compand=attacks=0:decays=0.3:points=-80/-80|-25/-22|0/-6:soft-knee=6:gain=0:volume=0');
    }
    if (s.reverb > 0) {
      final wet = (s.reverb / 100).clamp(0.0, 1.0);
      chain.write(',aecho=0.8:${(0.6 + 0.4 * wet).toStringAsFixed(2)}:60|120:'
          '${(0.3 * wet).toStringAsFixed(3)}|${(0.2 * wet).toStringAsFixed(3)}');
    }
    if (s.gainDb != 0) chain.write(',volume=${s.gainDb.toStringAsFixed(2)}dB');
    // 注意：空链不能补 ",anull"，否则整体变成 "[joined],anull" 会解析出一个空滤镜名
    final body = chain.toString();
    var clean = body.startsWith(',') ? body.substring(1) : body;
    // 裁剪放在最后：处理完再切，区域增益的时间轴才不会错位
    if (trimStart != null && trimStart > 0) {
      final end = (trimEnd != null && trimEnd > trimStart) ? 'end=${trimEnd.toStringAsFixed(3)}:' : '';
      final cut = 'atrim=start=${trimStart.toStringAsFixed(3)}:${end},asetpts=PTS-STARTPTS';
      clean = clean.isEmpty ? cut : '$clean,$cut';
    }
    buffer.write('[joined]${clean.isEmpty ? 'anull' : clean}[$outLabel]');
    return buffer.toString();
  }

  List<String> _codecArgs(ExportConfig c) {
    if (c.format == 'mp3') return ['-c:a', 'libmp3lame', '-b:a', '${c.bitrate}k'];
    return ['-c:a', 'pcm_s16le'];
  }

  Future<String?> renderTrack({
    required Track track,
    required String outPath,
    ExportConfig config = const ExportConfig(),
    double? start,
    double? end,
  }) async {
    final trimStart = (start != null && start > 0) ? start : 0.0;
    final trimEnd = (end != null && end > trimStart) ? end : 0.0;

    final args = <String>['-hide_banner', '-loglevel', 'error', '-y'];
    final f = _buildFilter(track,
        inLabel: '0:a', outLabel: 'out',
        trimStart: trimStart, trimEnd: trimEnd > 0 ? trimEnd : null);
    if (f != null) {
      args.addAll(['-i', track.path, '-filter_complex', f, '-map', '[out]']);
    } else {
      if (trimStart > 0) args.addAll(['-ss', trimStart.toStringAsFixed(3)]);
      if (trimEnd > 0) args.addAll(['-t', (trimEnd - trimStart).toStringAsFixed(3)]);
      args.addAll(['-i', track.path, '-map', '0:a']);
    }
    args.addAll(['-vn']);
    args.addAll(_codecArgs(config));
    args.addAll(['-ar', '${config.sampleRate}', '-ac', '${config.channels}', outPath]);
    return _run(args);
  }

  /// 多轨混音（人声 + 伴奏），每轨各自应用自己的参数
  Future<String?> renderMix({
    required List<Track> tracks,
    required String outPath,
    ExportConfig config = const ExportConfig(),
    double start = 0,
    double end = 0,
  }) async {
    final active = tracks.where((t) => !t.muted).toList();
    if (active.isEmpty) return '没有可导出的音轨';

    final args = <String>['-hide_banner', '-loglevel', 'error', '-y'];
    for (final t in active) {
      args.addAll(['-i', t.path]);
    }

    final filters = StringBuffer();
    for (int i = 0; i < active.length; i++) {
      final f = _buildFilter(active[i], inLabel: '$i:a', outLabel: 'src$i');
      if (f != null) {
        filters.write(f);
        filters.write(';');
      } else {
        filters.write('[$i:a]anull[src$i];');
      }
      if (active[i].volume != 1.0) {
        filters.write('[src$i]volume=${active[i].volume.toStringAsFixed(3)}[t$i];');
      } else {
        filters.write('[src$i]anull[t$i];');
      }
    }
    final inputs = List.generate(active.length, (i) => '[t$i]').join();
    filters.write('$inputs amix=inputs=${active.length}:duration=longest:normalize=0[mixed]');
    if (start > 0) {
      final e = (end > start) ? 'end=${end.toStringAsFixed(3)}:' : '';
      filters.write('[mixed]atrim=start=${start.toStringAsFixed(3)}:$e,'
          'asetpts=PTS-STARTPTS[out]');
    } else {
      filters.write(';[mixed]anull[out]');
    }

    args.addAll(['-filter_complex', filters.toString(), '-map', '[out]', '-vn']);
    args.addAll(_codecArgs(config));
    args.addAll(['-ar', '${config.sampleRate}', '-ac', '${config.channels}', outPath]);

    return _run(args);
  }

  /// 读取一条音频的平均音量（dB），用 volumedetect
  Future<double?> meanVolumeDb(String path) async {
    try {
      final session = await FFmpegKit.executeWithArguments([
        '-hide_banner', '-i', path, '-af', 'volumedetect', '-f', 'null', '/dev/null',
      ]);
      final logs = await session.getAllLogsAsString() ?? '';
      final m = RegExp(r'mean_volume:\s*(-?[0-9.]+)').firstMatch(logs);
      if (m == null) return null;
      return double.tryParse(m.group(1)!);
    } catch (_) {
      return null;
    }
  }

  /// 频谱分离（真算法）：把重复的伴奏当背景减掉，剩下人声
  Future<Map<String, String>> separateDeep(Track track, String outDir) async {
    final base = track.name.contains('.')
        ? track.name.substring(0, track.name.lastIndexOf('.'))
        : track.name;
    final mixRaw = '$outDir/.${base}_mix.f32';
    final vocalWav16 = '$outDir/.${base}_vocal16.wav';
    final vocalPath = '$outDir/${base}_人声.wav';
    final instPath = '$outDir/${base}_伴奏.wav';

    // 1. 解码成 16k 单声道浮点
    final err1 = await _run([
      '-hide_banner', '-loglevel', 'error', '-y', '-i', track.path,
      '-vn', '-ac', '1', '-ar', '16000', '-f', 'f32le', '-acodec', 'pcm_f32le', mixRaw,
    ]);
    if (err1 != null) return {'error': err1};

    final bytes = await File(mixRaw).readAsBytes();
    final count = bytes.length ~/ 4;
    final view = bytes.buffer.asFloat32List(bytes.offsetInBytes, count);
    final samples = Float32List.fromList(view);

    // 2. 频谱分离（独立 isolate，别卡住界面）
    final vocals = await Isolate.run(() => Spectral.vocals(samples, half: 10));

    // 3. 写 16k 单声道 wav
    _writeWav16(vocalWav16, vocals, 16000);

    // 4. 升回原采样率/立体声
    final err2 = await _run([
      '-hide_banner', '-loglevel', 'error', '-y', '-i', vocalWav16,
      '-ar', '${track.sampleRate}', '-ac', '2', '-c:a', 'pcm_s16le', vocalPath,
    ]);
    if (err2 != null) return {'error': err2};

    // 5. 伴奏 = 原曲 - 人声（真减法）
    final err3 = await _run([
      '-hide_banner', '-loglevel', 'error', '-y', '-i', track.path, '-i', vocalPath,
      '-filter_complex',
      '[1:a]volume=-1[v];[0:a][v]amix=inputs=2:duration=first:normalize=0[out]',
      '-map', '[out]', '-vn', '-c:a', 'pcm_s16le', '-ar', '${track.sampleRate}', '-ac', '2', instPath,
    ]);
    if (err3 != null) return {'error': err3};

    for (final f in [mixRaw, vocalWav16]) {
      try {
        await File(f).delete();
      } catch (_) {}
    }
    return {'vocal': vocalPath, 'inst': instPath};
  }

  void _writeWav16(String path, Float32List data, int sampleRate) {
    final int16 = Int16List(data.length);
    for (int i = 0; i < data.length; i++) {
      var v = data[i];
      if (v > 1) v = 1;
      if (v < -1) v = -1;
      int16[i] = (v * 32767).round();
    }
    final byteLen = int16.length * 2;
    final b = BytesBuilder();
    void tag(String s) => b.add(ascii.encode(s));
    void u32(int v) {
      final d = ByteData(4)..setUint32(0, v, Endian.little);
      b.add(d.buffer.asUint8List());
    }

    void u16(int v) {
      final d = ByteData(2)..setUint16(0, v, Endian.little);
      b.add(d.buffer.asUint8List());
    }

    tag('RIFF');
    u32(36 + byteLen);
    tag('WAVE');
    tag('fmt ');
    u32(16);
    u16(1);
    u16(1);
    u32(sampleRate);
    u32(sampleRate * 2);
    u16(2);
    u16(16);
    tag('data');
    u32(byteLen);
    b.add(int16.buffer.asUint8List());
    File(path).writeAsBytesSync(b.toBytes());
  }

  /// 快速人声/伴奏分离：中置声道提取 + 反相抵消（立体声歌曲用，秒出结果）
  Future<Map<String, String>> separateQuick(Track track, String outDir) async {
    if (track.channels < 2) {
      return {'error': '这轨是单声道，没法做声道分离（中置提取需要立体声）'};
    }
    final base = track.name.contains('.') ? track.name.substring(0, track.name.lastIndexOf('.')) : track.name;
    final vocalPath = '$outDir/${base}_人声.wav';
    final instPath = '$outDir/${base}_伴奏.wav';

    final vocalErr = await _run([
      '-hide_banner', '-loglevel', 'error', '-y', '-i', track.path,
      '-filter_complex',
      '[0:a]pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c0+0.5*c1,highpass=f=70[v];[v]anull[out]',
      '-map', '[out]', '-vn', '-c:a', 'pcm_s16le', '-ar', '${track.sampleRate}', '-ac', '2', vocalPath,
    ]);
    if (vocalErr != null) return {'error': vocalErr};

    // 伴奏 = 左右声道相减（中置的人声被抵消），这是真减法，不是叠两层
    final instErr = await _run([
      '-hide_banner', '-loglevel', 'error', '-y', '-i', track.path,
      '-filter_complex',
      '[0:a]pan=stereo|c0=0.5*c0-0.5*c1|c1=0.5*c1-0.5*c0[out]',
      '-map', '[out]', '-vn', '-c:a', 'pcm_s16le', '-ar', '${track.sampleRate}', '-ac', '2', instPath,
    ]);
    if (instErr != null) return {'error': instErr};

    return {'vocal': vocalPath, 'inst': instPath};
  }

  Future<String?> renderPreview({required Track track, required String outPath, double? start, double? end}) {
    return renderTrack(track: track, outPath: outPath, start: start, end: end);
  }

  Future<void> cancelAll() async => FFmpegKit.cancel();
}
