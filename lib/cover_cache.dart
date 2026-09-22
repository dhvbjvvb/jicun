import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 封面图的本地缓存。
///
/// **为什么必须落盘**:只放内存的话,App 一重启缓存就没了,进历史页要重新联网
/// 拉一遍 —— 那一两秒的空窗用户看得很清楚。写到磁盘上,重启后直接从文件解码。
///
/// **键为什么不用整串地址**:上游给的封面是带签名的临时地址,`?x-signature=...`
/// 那一段**每次解析都不一样**。整串做键的话,同一条视频重新解析就命中不了,
/// 缓存等于白做。这里削掉 query 只留稳定部分,同一个封面永远命中同一个文件。
///
/// 缓存放在 App 的 cache 目录下,系统在空间紧张时本来就会清它;这里再额外按
/// 文件数封顶,免得长期使用后无限增长。
class CoverCache {
  CoverCache._();

  /// 保留的最大文件数,超了删最旧的。
  static const int _maxFiles = 200;

  static Directory? _dir;

  /// 地址 → 缓存文件名。同一条记录每次解析都是同一个键。
  static String keyOf(String url) {
    final cut = url.indexOf('?');
    final stable = cut < 0 ? url : url.substring(0, cut);
    // hashCode 不是加密哈希,这里只是要一个短而稳定的文件名,够用。
    return stable.hashCode.toRadixString(16);
  }

  /// 建好目录并记住它。
  ///
  /// 必须在 [runApp] 之前调:卡片要在**第一帧**就决定"用文件还是走网络",
  /// 这是个同步判断 —— 目录没准备好就只能退化成联网,又白闪一下。
  static Future<void> warmUp() async {
    try {
      await _ensureDir();
    } catch (_) {
      // 拿不到目录(平台不支持、测试环境)就当没有缓存,全走网络。
    }
  }

  /// 同步取缓存文件。没有就返回 null,调用方退回网络图。
  static File? fileFor(String url) {
    final dir = _dir;
    if (dir == null) return null;
    final file = File('${dir.path}/${keyOf(url)}');
    return file.existsSync() ? file : null;
  }

  /// 把一张封面抓下来存好。已经有的、抓失败的都直接返回。
  static Future<void> store(String url) async {
    if (url.isEmpty || fileFor(url) != null) return;
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return;
      final dir = await _ensureDir();
      await File('${dir.path}/${keyOf(url)}').writeAsBytes(response.bodyBytes);
      await _trim(dir);
    } catch (_) {
      // 地址过期、没网、写盘失败 —— 都不该影响任何事,下次再试。
    }
  }

  /// 一批封面挨个存。[limit] 限制一轮抓多少张,免得刚进历史页就并发几十个请求。
  static Future<void> storeAll(Iterable<String> urls, {int limit = 20}) async {
    var done = 0;
    for (final url in urls) {
      if (done >= limit) return;
      if (fileFor(url) != null) continue;
      await store(url);
      done++;
    }
  }

  static Future<Directory> _ensureDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/covers');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _dir = dir;
  }

  /// 超过上限就按修改时间删最旧的。
  static Future<void> _trim(Directory dir) async {
    try {
      final files = dir.listSync().whereType<File>().toList()
        ..sort(
          (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
        );
      for (var i = 0; i < files.length - _maxFiles; i++) {
        files[i].deleteSync();
      }
    } catch (_) {
      // 清理失败无所谓,下次写盘再试。
    }
  }
}
