import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:jicun/downloader.dart';

final FlutterLocalNotificationsPlugin notifications =
    FlutterLocalNotificationsPlugin();
Future<bool?>? notificationsReady;

/// 初始化通知插件。**必须在第一帧之前调**:下载完成的通知就靠它,
/// 而且 Windows 那边少一份 settings 会直接抛(见下面那段注释)。
///
/// 从这个函数搬过来之前,这一坨挤在 main() 里 —— 那段注释比代码还长,
/// 每次读启动流程都要跳过它才能看清「启动到底做了哪几件事」。
void initNotifications() {
  notificationsReady = notifications.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('ic_notification'),
      // Windows 也必须给一份:flutter_local_notifications 在
      // defaultTargetPlatform == windows 而 settings.windows == null 时**直接抛**
      // ArgumentError。原来只填了 android,于是 Windows 上每次冷启动都甩一条
      // unhandled exception(这个 Future 没人 await,异常只进日志),而且通知一次
      // 都发不出来 —— 下载完成了用户什么都看不到。
      //
      // guid 是通知点击回调的 COM 激活标识,**必须固定**:每次变都会在系统里留下
      // 一堆失效的注册项,而且点通知回不到 App。
      // appUserModelId 用包名倒着写那一套(com.videofix.jicun)。
      windows: WindowsInitializationSettings(
        appName: '即存',
        appUserModelId: 'Videofix.Jicun',
        guid: '719bc11a-ac9c-4ae5-9d41-670b4d7f74e5',
      ),
    ),
  );
}

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
  // 我们自己的音频抽轨端点(/audio)失败时会回一句中文理由(「这段视频没有可提取的
  // 音轨」)。那句话本来就能直接给用户看,比下面按状态码套的通用文案准得多 ——
  // HttpException 把响应体带在 message 里,所以这里把冒号后面的那句摘出来。
  final serverReason = _serverReason(raw);
  if (serverReason != null) return serverReason;
  if (raw.contains('HTTP 4')) return '下载地址已失效，请重新解析';
  if (raw.contains('HTTP 5')) return '服务器暂时不可用，请稍后再试';
  if (raw.contains('SocketException') ||
      raw.contains('SocketTimeoutException') ||
      raw.contains('Connection reset') ||
      raw.contains('timeout') ||
      raw.contains('IOException')) {
    return '网络中断，请重试';
  }
  return raw;
}

/// 从 `HttpException` 的文本里摘出服务端那句中文理由。
///
/// 解析服务的 JSON 应答形如 `{"retcode":502,"retdesc":"这段视频没有可提取的音轨",…}`,
/// 而 `HttpException` 会把整个响应体拼进 message,所以直接找 `retdesc` 的值即可。
/// 拿不到(不是 JSON、或者没有这个字段)返回 null,交给按状态码的那几条兜底。
String? _serverReason(String raw) {
  final match = RegExp(r'"retdesc"\s*:\s*"([^"\\]{2,60})"').firstMatch(raw);
  final reason = match?.group(1)?.trim();
  if (reason == null || reason.isEmpty) return null;
  return reason;
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


/// 系统通知现在允不允许。问不出来返回 null。
Future<bool?> notificationsEnabled() async {
  try {
    final ready = notificationsReady;
    if (ready != null) await ready;
    final android = notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return await android?.areNotificationsEnabled();
  } catch (_) {
    return null;
  }
}

/// 要一次系统通知权限。老系统(13 以下)本来就是默认允许,拿不到答复按"给了"算。
Future<bool> requestNotificationPermission() async {
  try {
    final ready = notificationsReady;
    if (ready != null) await ready;
    final android = notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final granted = await android?.requestNotificationsPermission();
    return granted ?? true;
  } catch (_) {
    return true;
  }
}

