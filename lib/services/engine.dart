import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

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
    final tmp = '${Directory.systemTemp.path}/peaks_${DateTime.now().microsecondsSinceEpoch}.raw';
    final cmd = '-y -i "${_q(path)}" -vn -ac 1 -ar 8000 -f s16le "$tmp"';
    final session = await FFmpegKit.execute(cmd);
    final rc = await session.getReturnCode();
    if (!ReturnCode.isSuccess(rc)) return [];
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
      // 归一化，让小音量音频也能看清波形
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

  String _q(String p) => p.replaceAll('"', '\\"').replaceAll("'", "");

  /// 单轨完整滤镜链（含区间分段）
  String _trackFilter(Track track, {String inLabel = '0:a', required String outLabel}) {
    final s = track.settings;
    final dur = track.duration > 0 ? track.duration : 1e9;

    // 分区段：区间的边界把时间轴切开
    final cuts = <double>[0];
    for (final r in s.regions) {
      if (r.isEmpty) continue;
      if (r.start > 0 && r.start < dur) cuts.add(r.start);
      if (r.end > 0 && r.end < dur) cuts.add(r.end);
    }
    cuts.add(dur);
    cuts.sort();

    final parts = <String>[];
    int idx = 0;
    for (int i = 0; i < cuts.length - 1; i++) {
      final start = cuts[i];
      final end = cuts[i + 1];
      if (end - start < 0.02) continue;
      final active = s.regions.where((r) => !r.isEmpty && r.start <= start + 0.0001 && r.end >= end - 0.0001).toList();
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

    // 全局链
    final chain = StringBuffer();
    final sr = track.sampleRate > 0 ? track.sampleRate : _srFallback.toInt();
    if (s.pitch != 0) {
      final f = math.pow(2, s.pitch / 12).toDouble();
      final rate = (sr * f).round();
      chain.write(',asetrate=$rate,aresample=$sr');
      double tempo = 1.0 / f;
      // atempo 单级只支持 0.5~2
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
      chain.write(',aecho=0.8:${(0.6 + 0.4 * wet).toStringAsFixed(2)}:60|120:${(0.3 * wet).toStringAsFixed(3)}|${(0.2 * wet).toStringAsFixed(3)}');
    }
    if (s.gainDb != 0) chain.write(',volume=${s.gainDb.toStringAsFixed(2)}dB');
    if (chain.isEmpty) chain.write(',anull');

    buffer.write('[joined]$chain[$outLabel]');
    return buffer.toString();
  }

  Future<String?> _run(String cmd) async {
    final session = await FFmpegKit.execute(cmd);
    final rc = await session.getReturnCode();
    if (ReturnCode.isSuccess(rc)) return null;
    final logs = await session.getAllLogsAsString();
    return (logs == null || logs.isEmpty) ? '处理失败（返回码 ${rc?.getValue()}）' : logs;
  }

  Future<String?> renderTrack({
    required Track track,
    required String outPath,
    ExportConfig config = const ExportConfig(),
    double? start,
    double? end,
    String? tempDir,
  }) async {
    final filter = _trackFilter(track, outLabel: 'out');
    final ss = (start != null && start > 0) ? '-ss ${start.toStringAsFixed(3)} ' : '';
    final t = (start != null && end != null && end > start) ? '-t ${(end - start).toStringAsFixed(3)} ' : '';
    final codec = _codec(config);
    final cmd = '-y $ss$t-i "${_q(track.path)}" -filter_complex "${filter.replaceAll('"', '')}" '
        '-map "[out]" -vn $codec -ar ${config.sampleRate} -ac ${config.channels} "${_q(outPath)}"';
    return _run(cmd);
  }

  String _codec(ExportConfig c) {
    if (c.format == 'mp3') return '-c:a libmp3lame -b:a ${c.bitrate}k';
    return '-c:a pcm_s16le';
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

    final inputs = StringBuffer();
    final filters = StringBuffer();
    for (int i = 0; i < active.length; i++) {
      inputs.write(' -i "${_q(active[i].path)}"');
      filters.write(_trackFilter(active[i], inLabel: '$i:a', outLabel: 't$i'));
      filters.write(';');
    }
    final labels = List.generate(active.length, (i) => '[t$i]').join();
    final volChain = StringBuffer();
    for (int i = 0; i < active.length; i++) {
      volChain.write('$labels');
    }
    final ss = start > 0 ? '-ss ${start.toStringAsFixed(3)} ' : '';
    final t = (end > start && end > 0) ? '-t ${(end - start).toStringAsFixed(3)} ' : '';

    // 每一轨先套自己的音量，再用 amix 合并（normalize=0 保证音量不被自动压低）
    final perVol = StringBuffer();
    for (int i = 0; i < active.length; i++) {
      final v = active[i].volume;
      if (v != 1.0) {
        filters.write('[t$i]volume=${v.toStringAsFixed(3)}[v$i];');
      }
    }
    final mixInputs = List.generate(active.length, (i) => active[i].volume == 1.0 ? '[t$i]' : '[v$i]').join();
    perVol.write('$mixInputs amix=inputs=${active.length}:duration=longest:normalize=0[out]');

    final codec = _codec(config);
    final cmd = '-y $ss$t$inputs -filter_complex "${filters.toString().replaceAll('"', '')}$perVol" '
        '-map "[out]" -vn $codec -ar ${config.sampleRate} -ac ${config.channels} "${_q(outPath)}"';
    return _run(cmd);
  }

  Future<String?> renderPreview({required Track track, required String outPath, double? start, double? end}) {
    return renderTrack(track: track, outPath: outPath, start: start, end: end);
  }

  Future<void> cancelAll() async => FFmpegKit.cancel();
}
