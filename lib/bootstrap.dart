import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_host.dart';
import 'bench.dart';
import 'cover_cache.dart';
import 'device_identity.dart';
import 'downloader.dart';
import 'preferred_ip.dart';
import 'sponsor_store.dart';
import 'ui/notifications.dart';
import 'ui/prefs.dart';

/// 启动编排。第一帧之前要办的事都在这里,main() 只留一句 runApp。
///
/// 分成两档**是为了能被说清楚**:
/// - [bootstrap] 里是「不办完就别出第一帧」的(主题偏好、域名/IP 落盘值、
///   通知插件的初始化);
/// - [warmUp] 是首帧之后才跑、办不完也无所谓的,由 main() 自己 unawaited。
///
/// 以前这两档混在 main() 里,读完十几行才能判断「哪一步会挡住启动」。
///
/// 返回读好的偏好存储,交给根 widget —— 它在第一帧就要用(主题、缩放、开关)。
/// 读不到(插件异常等)返回 null,让 App 带着默认值起来,别整个起不来。
Future<SharedPreferences?> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 轻量 shader 先准备好,高级多通道 shader 首次真正用到时再加载,不阻塞冷启动。
  await LiquidGlassWidgets.initialize(warmUpMode: GlassWarmUpMode.never);
  initNotifications();
  // 掉帧日志:只有 debug 构建 + `--dart-define=JICUN_FRAME_LOG=1` 才真的装
  // (见 FrameJankLog)。报「返回一级页卡顿」这类问题时,靠它把「构建慢」和「光栅慢」分开。
  FrameJankLog.install();

  SharedPreferences? prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } catch (_) {
    prefs = null;
  }
  // 优选 IP 与域名:先把上次服务端下发的读回来 —— 域名尤其重要,主域名被运营商
  // 阻断时它就是唯一能用的入口;再按需刷新一次(缓存没过期就不发请求)。
  // 拉不到就用内置兜底,不影响启动。
  final cachedHost = prefs?.getString(kPrefsApiHost);
  if (cachedHost != null) setApiHost(cachedHost);
  restoreCachedConfig(prefs?.getString(kPrefsPreferredIps));
  // 赞助名单:把上次拉到的那份读回来。它和主题一样属于「第一帧之后马上就可能
  // 被看到」(设置 → 赞助名单),所以缓存放在这一档里同步读完;网络刷新在
  // warmUp 里跑,不挡启动。
  sponsorStore.loadCached(prefs?.getString(kPrefsSponsors));
  if (preferredIpsStale(prefs?.getInt(kPrefsPreferredIpsAt))) {
    unawaited(refreshPreferredIps(prefs));
  }
  return prefs;
}

/// 把落盘的服务端配置读回全局状态:服务端下发的域名候选、优选 IP 池、平台白名单。
///
/// 抽成独立函数是为了能单测:bootstrap() 里紧接着要初始化通知插件,那个插件在测试
/// 环境里没有平台实现,一调就抛 —— 整条启动流程没法在用例里跑,而「冷启动把上次的
/// 域名表读回来」这件事必须有个能跑的检查(以前这里漏了 hosts,冷启动后
/// [PreferredIpConnector.remoteHosts] 是空的)。
///
/// [cached] 为 null(从没拉过)就什么都不做,继续用内置兜底。
void restoreCachedConfig(String? cached) {
  if (cached == null) return;
  final config = parseServerConfig(cached);
  if (config.ips.isNotEmpty) PreferredIpConnector.remote = config.ips;
  // 服务端下发的域名表也要读回来:它是 [PreferredIpConnector] 换域名重连时的候选。
  // 以前这里漏了它,于是冷启动后 remoteHosts 是空的 —— 当前域名被运营商阻断时,
  // 连接器手上只剩内置域名/优选 IP,「服务端换域名、老客户端跟着走」这条路等于断了。
  if (config.hosts.isNotEmpty) PreferredIpConnector.remoteHosts = config.hosts;
  // cf_host 也要在第一帧之前就位:优选 IP 赛跑要靠它做 SNI。
  //
  // 和上面两条一样是**有值才覆盖**(不是无条件):这份缓存可能来自升级前的旧版本,
  // 里面根本没有这个字段 —— 无条件写下去就成了空串,连接器会以为「没有 CF 域名」
  // 而干脆不赛跑 IP,等于把功能关到下一次刷新为止(最长 12 小时,见 kPreferredIpsTtl)。
  //
  // 反过来,服务端**真的想关掉**它时会下发一个空字符串(见 jicun-cfip.sh),
  // 那条路走的是 _apply 的无条件覆盖,不会被这里挡住。
  if (config.cfHost.isNotEmpty) PreferredIpConnector.cfHost = config.cfHost;
  // 支持域名表也要在第一帧之前就位：用户完全可能一进 APP 就粘一条不支持的
  // 链接，那一发就该在本地被拦掉，而不是等后台刷新回来才知道。
  supportedHosts = config.supported;
}

/// 首帧之后的后台活。都不 await:它们办不完也不该影响用户看到界面。
void warmUp() {
  // 首页先出,历史与封面缓存由页面在首帧后异步补齐。
  unawaited(CoverCache.warmUp());
  // 上一次下载被系统杀掉时留下的分片(原生预分配到全尺寸,很占地方)。
  // 启动时清一遍,不阻塞首帧。
  unawaited(Downloader.sweepLeftovers());
  // 赞助名单顺手刷一次:这个二级页多半在启动后几十秒内就被点开,启动时刷过
  // 那一趟之后打开它就不用再等。30 秒内不会重复打网络(见 SponsorStore)。
  unawaited(sponsorStore.ensureLoaded());
  // 设备身份 + 硬件密钥证明:首次启动注册一次 —— 拿挑战值、在安全芯片里生成密钥、
  // 把证书链交给服务端换一个 device_id 落盘(见 lib/device_identity.dart)。
  //
  // 绝不 await:它要过网络和安全芯片,而登记这条路整个是**静默**的,没办成也不该让
  // 用户看见任何差别。失败后 6 小时内不再试第二次。
  //
  // 「这里不 await」≠「请求不用等它」:**解析请求发出去之前会等一次正在跑的登记**
  // (见 awaitDeviceIdentity)。少了那一步,用户一进来就粘贴解析时那一次会不带签名头,
  // 服务端在 enforce 下必然 403 —— 线上实测就是「第一次粘贴必失败,重敲一遍就好」。
  unawaited(ensureDeviceIdentity());
}

/// 拉服务端下发的域名表与优选 IP 并落盘。
///
/// 拉不到就什么都不做 —— 内置域名和内置 IP 池都还在,这不是错误路径。
Future<void> refreshPreferredIps(SharedPreferences? prefs) async {
  final config = await PreferredIpUpdater.instance.fetch();
  if (config.isEmpty) return;
  await prefs?.setString(
    kPrefsPreferredIps,
    // hosts 也要落盘:它是连接器换域名重连的候选,冷启动读回来之前只有它在手上。
    jsonEncode({
      'ips': config.ips,
      'hosts': config.hosts,
      // cf_host 也要落盘:优选 IP 的赛跑要靠它做 SNI,冷启动读回来之前没有它就去
      // 连 CF 的边缘 IP,握手必然失败。
      'cf_host': config.cfHost,
      'supported': config.supported,
    }),
  );
  await prefs?.setInt(
    kPrefsPreferredIpsAt,
    DateTime.now().millisecondsSinceEpoch,
  );
  // 域名可能被服务端换掉了(上一个被运营商阻断时),这个必须落盘 ——
  // 下次冷启动要先用它,而不是先用内置域名去撞一次墙。
  await prefs?.setString(kPrefsApiHost, apiHost);
}
