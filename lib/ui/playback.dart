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
/// 平台的 CDN 有的**按 Referer / UA 放行**,判据是实测的(2026-10-05,拿服务端真下发的
/// 那条 B 站 DASH 音轨地址,逐个头组合试出来的):
///
/// | 主机 | Referer | UA | 结果 |
/// |---|---|---|---|
/// | `upos-*.bilivideo.com` | 不带 | 移动版 Chrome | 403 |
/// | 同上 | 带 | 移动版 Chrome | 403 |
/// | 同上 | 带 | 播放器自己那份(ExoPlayerLib) | 403 |
/// | 同上 | 带 | **桌面 Chrome** | 206 |
/// | `upos-*.akamaized.net` | 不带 | 桌面 Chrome | 206 |
/// | 同上 | 带 | **一个字节的 UA 都不发** | 403 |
///
/// B 站那两件事因此是**硬要求**:Referer 要在,UA 也要在、而且必须是**桌面那份**。
/// 移动版 Chrome 的 UA 被判 403(原生下载器的 `BILIBILI_UA` 记的就是这条),播放器
/// 自己那份(ExoPlayerLib)在这条音轨上同样 403 —— 以前这里刻意不塞 UA、把希望押在
/// 「ExoPlayer 那份也许放行」,实测放行不了:预览的表现就是一块灰面板加一句
/// `(0) SOURCE ERROR`(ExoPlaybackException.TYPE_SOURCE,见 lib/ui/audio_stage.dart)。
///
/// 抖音系的 CDN(音乐在 `*.douyinstatic.com`)**下载器一直发浏览器 UA、能下**,而
/// 播放器默认那份 UA 不一定被放行 —— 这里把预览对齐成下载器那份浏览器 UA。
///
/// 认不出的主机返回空表:别人的 CDN 不吃这一套,乱塞一个 Referer 反而可能被拒。
Map<String, String> playbackHeaders(String url) {
  final host = _hostOf(url);
  if (_isBilibiliHost(host)) return _bilibiliHeaders;
  if (_byteDanceHosts.any(host.endsWith)) {
    return const <String, String>{'User-Agent': kBrowserUserAgent};
  }
  return const <String, String>{};
}

/// 走「流式加载失败就整段抓到本地再放」那条路时要带的头(抓取那一段在
/// lib/ui/audio_stage.dart 的 `fetchAudioPreviewFile` 里)。
///
/// 和 [playbackHeaders] 同源,差别只在认不出的主机:**这里也发一份浏览器 UA** ——
/// 这条路存在的全部理由就是「播放器加载不动、而下载器下得动」,所以要尽量贴住下载器
/// 发的那份请求(点击就下、下载器能下的地址,兜底也得能下)。原生下载器认不出平台时
/// 不补头、走 Java 默认那份 `Dalvik/2.x`,而 Dart 这边没有平台默认 UA 可用,统一发
/// 浏览器 UA 更接近普通客户端。
Map<String, String> fetchHeaders(String url) {
  final host = _hostOf(url);
  if (_isBilibiliHost(host)) return _bilibiliHeaders;
  return const <String, String>{'User-Agent': kBrowserUserAgent};
}

/// B 站 CDN 要的那两个头。见 [playbackHeaders] 里那张实测表。
const Map<String, String> _bilibiliHeaders = <String, String>{
  'Referer': 'https://www.bilibili.com/',
  'User-Agent': kBilibiliUserAgent,
};

String _hostOf(String url) => Uri.tryParse(url)?.host.toLowerCase() ?? '';

/// 这条地址是不是 B 站 CDN 上的。
///
/// **镜像是挂在别家 CDN 上的,只认自家域名会漏掉一半**:实测(2026-10-05)同一条视频,
/// 服务端一次给 `upos-sz-mirrorcosov.bilivideo.com`、下一次给
/// `upos-hz-mirrorakam.akamaized.net` —— 后者的后缀里没有任何「B 站」字样,漏判的
/// 后果是一个头都不发,预览整块灰、下载也 403。判据两条:
///   1. 自家域名(`*.bilivideo.com` / `*.bilivideo.cn` / `*.bilibili.com`);
///   2. `upos-*.akamaized.net`:B 站在 Akamai 上的镜像主机名就长这样。Akamai 是公共
///      CDN,不带 `upos-` 前缀的一律不碰 —— 别人家的东西不能替人加 Referer。
bool _isBilibiliHost(String host) {
  if (_bilibiliHostSuffixes.any(host.endsWith)) return true;
  return host.startsWith('upos-') && host.endsWith('akamaized.net');
}

/// B 站 CDN 的自家域名后缀。
const List<String> _bilibiliHostSuffixes = <String>[
  'bilivideo.com',
  'bilivideo.cn',
  'bilibili.com',
];

/// B 站 CDN 认的那份 UA,和原生下载器的 `BILIBILI_UA` 一字不差:预览、兜底抓取、
/// 下载三条路对齐同一份,不再出现「同一个地址有人能过、有人 403」。
const String kBilibiliUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

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
