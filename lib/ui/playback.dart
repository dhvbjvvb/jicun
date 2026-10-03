import 'package:flutter/material.dart';

/// 预览播放器的**跨页面记忆**、**暂停信号**与**恢复信号**。
///
/// 三件事都源于同一个坑:预览播放器活在页面树里,页面一重建/一销毁,播放器就跟着
/// 没了。所以位置不能只存在播放器里。
///
/// 1. [positions]:按地址记住「上次播到哪」。切到历史/设置再切回来、或者解析出
///    新地址导致播放器重建,都靠它把进度接回去 —— 而不是打回 00:00。
/// 2. [pauseRequests]:点「下载媒体」时发一次信号,让正在播的视频和音频都停下来。
///    只是暂停,播放器留着 —— 下载和预览抢带宽、抢音频焦点,让位是对的,但下载
///    一结束用户要能接着看。
/// 3. [resumeRequests]:下载那一趟结束(下完/取消/失败)时发一次,把上一条信号
///    暂停掉的播放器放回去接着播。只恢复**点下载前本来就在播**的那些:用户自己
///    按停的,不该被这个信号弄响。
class Playback {
  const Playback._();

  /// 地址 → 上次播到的位置。地址带签名,同一条媒体在一次运行里地址是稳定的。
  static final Map<String, Duration> positions = <String, Duration>{};

  /// 递增即请求暂停;两个播放区各自记住消费到哪一次,互不干扰。
  static final ValueNotifier<int> pauseRequests = ValueNotifier<int>(0);

  /// 递增即请求恢复播放。同上,两边各自记住消费到哪一次。
  static final ValueNotifier<int> resumeRequests = ValueNotifier<int>(0);

  static void requestPause() => pauseRequests.value++;

  static void requestResume() => resumeRequests.value++;

  static void remember(String url, Duration position) {
    positions[url] = position;
  }

  static Duration? recall(String url) {
    final position = positions[url];
    if (position == null || position <= Duration.zero) return null;
    return position;
  }
}

/// 播放器要带的请求头。
///
/// 平台的 CDN 有的**按 Referer / UA 放行**:
/// - B 站 DASH 那条纯音频流(解析服务的 `_fetch_audio_stream`)不带 Referer 一律 403、
///   带了才 206;而且它认桌面 UA(见 NativeDownloader 的 BILIBILI_UA);
/// - 抖音系的 CDN(音乐在 `*.douyinstatic.com`)**下载器一直发浏览器 UA、能下**,而
///   播放器默认那份 UA 不一定被放行 —— 预览加载不出来、下载却正常,差异就在这儿。
///   这里把预览对齐成下载器那份浏览器 UA。
///
/// **B 站那条刻意不塞 User-Agent**:just_audio 会把 headers 里的 `User-Agent` 摘出来
/// 当播放器自己的 UA 用,而 B 站 CDN 是按「IP + UA」一起判的 —— 同一份 UA 在这台手机上
/// 被拒、在另一条链路上被放行(实测)。猜哪一份都可能猜错。
///
/// 认不出的主机返回空表:别人的 CDN 不吃这一套,乱塞一个 Referer 反而可能被拒。
Map<String, String> playbackHeaders(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.endsWith('bilivideo.com') || host.endsWith('bilibili.com')) {
    return const <String, String>{'Referer': 'https://www.bilibili.com/'};
  }
  if (_byteDanceHosts.any(host.endsWith)) {
    return const <String, String>{'User-Agent': kBrowserUserAgent};
  }
  return const <String, String>{};
}

/// 和原生下载器的 `BROWSER_UA` 一字不差:预览和下载对齐同一份 UA。
const String kBrowserUserAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

/// 抖音系的 CDN 域名后缀 —— 下载器对这几家发的就是上面那份浏览器 UA。
const List<String> _byteDanceHosts = <String>[
  'douyinstatic.com',
  'douyinpic.com',
  'douyinvod.com',
  'douyincdn.com',
  'ixigua.com',
  'ixiguavideo.com',
  'amemv.com',
  'bdxiguavod.com',
  'byteimg.com',
  'bytedance.com',
  'zjcdn.com',
  'pstatp.com',
  'snssdk.com',
];
