import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:jicun/downloader.dart';

final FlutterLocalNotificationsPlugin notifications =
    FlutterLocalNotificationsPlugin();
Future<bool?>? notificationsReady;

/// 这次下载结果该不该发系统通知。
///
/// 两个开关各管一头:下完了看「下载完成通知」,没下成看「下载失败通知」。
bool downloadNoticeEnabled({
  required bool ok,
  required bool done,
  required bool failed,
}) => ok ? done : failed;

/// 下载异常 → 给用户看的一句话。
///
/// 弹窗和通知原来直接贴 `'$error'`,于是用户看到的是
/// `HttpException: SocketException: Connection reset` —— 原生那层的类型名加 Dart
/// 这层的包装一起甩到脸上,除了吓人没有任何用处。这里按"该怎么办"归类:
///
/// - 连接被重置/读超时/IO 中断 → 网络问题,重试即可(下载器内部已经对每一段自动
///   重试 3 次,能走到这里说明重试也没救回来);
/// - 4xx → 这条直链本身失效了(CDN 的签名过期最常见),重试无用,得重新解析;
/// - 其余原样透出,免得把还没见过的错因藏掉。
///
/// 原始异常仍然打 logcat:排障看日志,不看用户看到的这句话。
String downloadErrorMessage(Object error) {
  if (error is DownloadCancelled) return '已取消';
  final raw = '$error';
  if (kDebugMode) debugPrint('[dl] 下载失败原始异常: $raw');
  if (raw.contains('文件不完整') || raw.contains('下载不完整')) {
    return '文件不完整，请重试';
  }
  if (raw.contains('HTTP 4')) return '下载地址已失效，请重新解析';
  if (raw.contains('SocketException') ||
      raw.contains('SocketTimeoutException') ||
      raw.contains('Connection reset') ||
      raw.contains('timeout') ||
      raw.contains('IOException')) {
    return '网络中断，请重试';
  }
  return raw;
}

/// 所有系统通知共用的渠道。
///
/// Android 上渠道的通知名和重要性一旦创建就改不动了,所以改这个常量只对新安装的
/// 设备生效。测试通知和下载通知走同一条渠道:「完成 / 失败」分成两个开关是应用里
/// 的判断,不是系统里的渠道。
const NotificationDetails kNotificationDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    '即存_notifications',
    '通知管理与下载',
    channelDescription: '下载完成、下载失败等提醒',
    importance: Importance.high,
    priority: Priority.high,
    icon: 'ic_notification',
    // 面板里那颗大图标由系统取应用图标,这里不再额外指定 largeIcon,
    // 否则面板右侧会多出一个重复的图标。
    color: Color(0xFF1F2A37),
  ),
);

