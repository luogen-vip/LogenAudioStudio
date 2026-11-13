import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Demucs 神经网络模型分离（ONNX Runtime，Android 原生跑）。
///
/// 模型是官方 htdemucs 的 fp16 权重版（约 158MB），首次使用时下载，
/// 之后离线可用。分离流程全部在原生层完成：7.8 秒分块、25% 重叠、
/// 三角窗重叠相加，最后输出人声 / 伴奏两条 44.1k 立体声轨道。
class Demucs {
  Demucs._();
  static final Demucs instance = Demucs._();

  static const MethodChannel _ch = MethodChannel('logen/demucs');

  static const String modelFile = 'htdemucs_fp16.onnx';
  static const int modelBytes = 165612636;

  /// 用户提供的加速镜像前缀
  static const String mirror = 'gh.luogen.cc.cd';

  static const String _hf =
      'https://huggingface.co/StemSplitio/htdemucs-onnx/resolve/main/htdemucs_fp16weights.onnx';

  /// 模型同时挂在 GitHub 发布页上（走你的加速镜像会快很多）
  static const String _gh =
      'https://github.com/luogen-vip/LogenAudioStudio/releases/download/v1.0.0-luogen.9/htdemucs_fp16weights.onnx';

  List<String> get _urls => [
        'https://$mirror/$_gh',
        _gh,
        _hf,
      ];

  Future<Directory> _modelDir() async {
    final dir = await getApplicationSupportDirectory();
    final d = Directory('${dir.path}/models');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<String> modelPath() async => '${(await _modelDir()).path}/$modelFile';

  /// 模型是否已下载好（大小对得上才算）
  Future<bool> ready() async {
    try {
      final f = File(await modelPath());
      if (!await f.exists()) return false;
      final len = await f.length();
      return len > modelBytes - 2048 && len <= modelBytes + 2048;
    } catch (_) {
      return false;
    }
  }

  /// 下载模型，返回本地路径。onProgress 是 0~1。
  Future<String> download({void Function(double p)? onProgress}) async {
    final dir = await _modelDir();
    final target = File('${dir.path}/$modelFile');
    final tmp = File('${dir.path}/$modelFile.part');
    String? lastError;
    for (final url in _urls) {
      try {
        if (await tmp.exists()) await tmp.delete();
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 20);
        final req = await client.getUrl(Uri.parse(url));
        req.headers.set('User-Agent', 'LogenAudioStudio');
        final resp = await req.close();
        if (resp.statusCode != 200) {
          lastError = 'HTTP ${resp.statusCode}';
          client.close(force: true);
          continue;
        }
        final total = resp.contentLength > 0 ? resp.contentLength : modelBytes;
        final sink = tmp.openWrite();
        var got = 0;
        await for (final chunk in resp) {
          sink.add(chunk);
          got += chunk.length;
          onProgress?.call((got / total).clamp(0.0, 1.0));
        }
        await sink.flush();
        await sink.close();
        client.close();
        if (got < modelBytes - 2048) {
          lastError = '文件不完整（$got 字节）';
          continue;
        }
        if (await target.exists()) await target.delete();
        await tmp.rename(target.path);
        return target.path;
      } catch (e) {
        lastError = '$e';
      }
    }
    throw Exception('模型下载失败：${lastError ?? '未知原因'}');
  }

  /// 调原生分离。mixRaw/vocalRaw/instRaw 都是 f32le 立体声 44.1k 裸文件。
  Future<void> separate({
    required String modelPath,
    required String mixRawPath,
    required String vocalRawPath,
    required String instRawPath,
    required int samplesPerChannel,
    void Function(double p)? onProgress,
  }) async {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'progress') {
        final p = (call.arguments as num).toDouble();
        onProgress?.call(p);
      }
      return null;
    });
    await _ch.invokeMethod('separate', {
      'model': modelPath,
      'mix': mixRawPath,
      'vocal': vocalRawPath,
      'inst': instRawPath,
      'samples': samplesPerChannel,
    });
  }
}
