import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// 导出统一落到 /storage/emulated/0/Download/LogenAudioStudio
class Storage {
  Storage._();
  static final Storage instance = Storage._();

  static const String downloadRoot = '/storage/emulated/0/Download';
  static const String folderName = 'LogenAudioStudio';

  bool _checked = false;
  bool _granted = false;

  Future<bool> ensurePermission() async {
    if (_checked) return _granted;
    _checked = true;
    if (!Platform.isAndroid) {
      _granted = true;
      return true;
    }
    try {
      if (await Permission.manageExternalStorage.isGranted) {
        _granted = true;
        return true;
      }
      final status = await Permission.manageExternalStorage.request();
      if (status.isGranted) {
        _granted = true;
        return true;
      }
      if (await Permission.storage.request().isGranted) {
        _granted = true;
        return true;
      }
    } catch (_) {}
    _granted = false;
    return false;
  }

  /// 返回真正可写、确实存在的目录
  Future<Directory> outputDir() async {
    await ensurePermission();
    if (_granted) {
      try {
        final target = Directory('$downloadRoot/$folderName');
        if (!await target.exists()) await target.create(recursive: true);
        final probe = File('${target.path}/.probe');
        await probe.writeAsString('ok');
        await probe.delete();
        return target;
      } catch (_) {}
    }
    Directory? base;
    try {
      base = await getExternalStorageDirectory();
    } catch (_) {}
    base ??= await getTemporaryDirectory();
    final fallback = Directory('${base.path}/$folderName');
    if (!await fallback.exists()) await fallback.create(recursive: true);
    return fallback;
  }
}
