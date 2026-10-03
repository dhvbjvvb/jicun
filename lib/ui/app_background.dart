import 'dart:io';

import 'package:flutter/services.dart';

import '../failure.dart';

/// 自定义背景图的原生入口。
///
/// 选图借用下载器那条通道(见 MainActivity 的 pickBackgroundImage):原生侧拉起
/// 系统文件管理(ACTION_OPEN_DOCUMENT)选一张图,复制进应用目录后把绝对路径给回来。
/// **必须复制**,不能只存 content:// —— Flutter 的 Image.file 读不了 content uri,
/// 而且授权可能被回收。
class AppBackground {
  const AppBackground._();

  static const MethodChannel _channel = MethodChannel('jicun/downloader');

  /// 弹系统文件管理选一张图片,返回复制进应用目录后的绝对路径。用户取消返回 null。
  static Future<String?> pick() async {
    final path = await _channel.invokeMethod<String>('pickBackgroundImage');
    if (path == null || path.isEmpty) return null;
    return path;
  }

  /// 删掉一张自定义背景(换新图/还原默认时调)。删不掉就算了 —— 偏好清掉即可,
  /// 别让清理失败挡住「还原默认」这件事。
  static void removeFile(String? path) {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (error, stack) {
      swallow('bg.remove-file', error, stack);
    }
  }
}
