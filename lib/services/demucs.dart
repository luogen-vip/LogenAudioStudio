import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 人声/伴奏 AI 分离（UVR MDX-Net 人声模型，ONNX Runtime 原生跑）。
///
/// 模型约 64MB，首次用时下载，之后离线可用；下载支持断点续传，
/// 卡住超过 30 秒会自动断开重试，已经下到的部分不会丢。
class Demucs {
  Demucs._();
  static final Demucs instance = Demucs._();

  static const MethodChannel _ch = MethodChannel('logen/demucs');

  static const String modelFile = 'mdx_voc_ft.onnx';
  static const int modelBytes = 66762490;

  static const String mirror = 'gh.luogen.cc.cd';

  static const String _hf =
      'https://huggingface.co/aaatmy/uvr-mdx-net-onnx/resolve/main/UVR-MDX-NET-Voc_FT.onnx';

  static const String _gh =
      'https://github.com/luogen-vip/LogenAudioStudio/releases/download/v1.0.0-luogen.9/UVR-MDX-NET-Voc_FT.onnx';

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

  Future<bool> ready() async {
    try {
      final f = File(await modelPath());
      if (!await f.exists()) return false;
      final len = await f.length();
      return len >= modelBytes - 1024;
    } catch (_) {
      return false;
    }
  }

  /// 下载（带断点续传）。onProgress 是 0~1。
  Future<String> download({void Function(double p)? onProgress}) async {
    final dir = await _modelDir();
    final target = File('${dir.path}/$modelFile');
    final part = File('${dir.path}/$modelFile.part');

    String? lastError;
    for (final url in _urls) {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          var have = await part.exists() ? await part.length() : 0;
          if (have >= modelBytes) {
            if (await target.exists()) await target.delete();
            await part.rename(target.path);
            onProgress?.call(1);
            return target.path;
          }
          final client = HttpClient()
            ..connectionTimeout = const Duration(seconds: 20)
            ..idleTimeout = const Duration(seconds: 30);
          final req = await client.getUrl(Uri.parse(url));
          req.headers.set('User-Agent', 'LogenAudioStudio');
          if (have > 0) req.headers.set('Range', 'bytes=$have-');
          final resp = await req.close();
          if (resp.statusCode != 200 && resp.statusCode != 206) {
            lastError = 'HTTP ${resp.statusCode}';
            client.close(force: true);
            continue;
          }
          var start = have;
          if (resp.statusCode == 200) start = 0; // 服务器不支持续传，从头来
          final sink = part.openWrite(
            mode: start > 0 ? FileMode.append : FileMode.write,
          );
          var got = start;
          await for (final chunk in resp) {
            sink.add(chunk);
            got += chunk.length;
            onProgress?.call((got / modelBytes).clamp(0.0, 1.0));
          }
          await sink.flush();
          await sink.close();
          client.close();
          if (got >= modelBytes - 1024) {
            if (await target.exists()) await target.delete();
            await part.rename(target.path);
            onProgress?.call(1);
            return target.path;
          }
          lastError = '连接中断（已下 $got / $modelBytes 字节，接着重试）';
        } catch (e) {
          lastError = '$e';
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    throw Exception('模型下载失败：${lastError ?? '未知原因'}（已经下到一部分，下次会接着下）');
  }

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
        onProgress?.call((call.arguments as num).toDouble());
      }
      return null;
    });
    await _ch.invokeMethod('separateMdx', {
      'model': modelPath,
      'mix': mixRawPath,
      'vocal': vocalRawPath,
      'inst': instRawPath,
      'samples': samplesPerChannel,
    });
  }
}
