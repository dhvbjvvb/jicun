import 'package:flutter/cupertino.dart';

import 'dart:async';
import 'dart:convert';
// 进度环的渐变要 ui.Gradient.linear:widgets 里的 Gradient 是另一套东西
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bench.dart';
import 'cover_cache.dart';
import 'downloader.dart';
import 'history_store.dart';
import 'parse_service.dart';
import 'preferred_ip.dart';
import 'update_service.dart';
import 'widgets/animated_tab_icon.dart';

import 'api_host.dart';
import 'ui/notifications.dart';
import 'ui/prefs.dart';
import 'ui/motion.dart';
import 'ui/clipboard.dart';
import 'ui/palette.dart';
import 'pages/parse.dart';
import 'pages/history.dart';
import 'ui/popup.dart';
import 'pages/settings.dart';
import 'ui/glass.dart';

/// 拉服务端下发的域名表与优选 IP 并落盘。
///
/// 拉不到就什么都不做 —— 内置域名和内置 IP 池都还在,这不是错误路径。
/// 故意不 await:它只是个后台刷新,不能让启动等它。
Future<void> _refreshPreferredIps(SharedPreferences? prefs) async {
  final config = await PreferredIpUpdater.instance.fetch();
  if (config.isEmpty) return;
  await prefs?.setString(kPrefsPreferredIps, jsonEncode({'ips': config.ips}));
  await prefs?.setInt(kPrefsPreferredIpsAt, DateTime.now().millisecondsSinceEpoch);
  // 域名可能被服务端换掉了(上一个被运营商阻断时),这个必须落盘 ——
  // 下次冷启动要先用它,而不是先用内置域名去撞一次墙。
  await prefs?.setString(kPrefsApiHost, apiHost);
}

// 启动画面**只在原生侧**(浅深各一个启动入口,见 AndroidManifest 里的
// LaunchLightActivity/LaunchDarkActivity 与 res/drawable/launch_{light,dark}.xml、
// values*/styles.xml),Flutter 这边刻意**不再叠一层**。
//
// 曾经叠过一层:系统启动图撤掉那一刻,在界面上再画同一只鸟、420ms 淡出,想让交接连
// 起来。真机上不行,两个理由:
//   1. 那一层压在**已经可用的界面**上:鸟悬在首页中间,看着就是"一只鸟的残影"
//      (浅色深色都一样,真机截图确认);
//   2. Android 12+ 的系统启动图**自己就在淡出** —— 能抓到"半透明的鸟浮在纯底色上"
//      那一帧,所以根本不缺这一层;补上去只多出那点延迟。
// 于是整层删掉:12+ 的交接交给系统,本来就是淡的;11 及以下回到"直接切"(和加这一层
// 之前一样)。以后想让老机器也有淡出,按系统版本开关这条路(别默认打开)。

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 轻量 shader 先准备好,高级多通道 shader 首次真正用到时再加载,不阻塞冷启动。
  await LiquidGlassWidgets.initialize(warmUpMode: GlassWarmUpMode.never);
  notificationsReady = notifications.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('ic_notification'),
    ),
  );
  // 偏好先读出来再上第一帧,免得启动时先闪一下默认值。
  // 读不到(插件异常等)就退回默认值继续跑,别让整个 App 起不来。
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
  final cachedIps = prefs?.getString(kPrefsPreferredIps);
  if (cachedIps != null) {
    final ips = parseServerConfig(cachedIps).ips;
    if (ips.isNotEmpty) PreferredIpConnector.remote = ips;
  }
  if (preferredIpsStale(prefs?.getInt(kPrefsPreferredIpsAt))) {
    _refreshPreferredIps(prefs);
  }

  runApp(LiquidGlassWidgets.wrap(child: LiquidGlassDemo(prefs: prefs)));
  // 首页先出,历史与封面缓存由页面在首帧后异步补齐。
  unawaited(CoverCache.warmUp());
  // 上一次下载被系统杀掉时留下的分片(原生预分配到全尺寸,很占地方)。
  // 启动时清一遍,不阻塞首帧。
  unawaited(Downloader.sweepLeftovers());
}

class LiquidGlassDemo extends StatefulWidget {
  const LiquidGlassDemo({
    super.key,
    this.prefs,
    this.entries,
    this.updates,
    this.autoCheckUpdate = true,
  });

  /// 偏好存储。传 null(测试里常见)就退化成只用默认值、不落盘。
  final SharedPreferences? prefs;

  /// 启动时预读出来的历史。
  ///
  /// 传了就直接用 —— 切到历史页的第一帧就能拿到数据,不用再等一次异步读盘。
  /// 没传(测试里常见)就自己异步读一份,行为退化成之前那样。
  final List<HistoryEntry>? entries;

  /// 检查更新用的服务。传 null 就用真的。
  ///
  /// 留这个口子**只为了测试**:widget 测试里不能真去打 GitHub,得换成假后端
  /// 才能验「有新版本就弹卡片」这条路。
  final UpdateService? updates;

  /// 启动时自动检查一次。
  ///
  /// 默认开(需求要的就是这个)。留成参数是为了测试能单独把这条路关掉 ——
  /// widget 测试里真去打 GitHub 会一直等不到结果。
  final bool autoCheckUpdate;

  @override
  State<LiquidGlassDemo> createState() => HomeShellState();
}

/// 横滑切板块:横向拖够这么多逻辑像素就算一次。
const double _kTabSwipeDistance = 80;

/// 横滑切板块:够快的一挥也算,不看拖了多远(px/s)。
const double _kTabSwipeVelocity = 400;

class HomeShellState extends State<LiquidGlassDemo>
    with WidgetsBindingObserver {
  /// 当前板块。**不是**普通字段 + setState:底栏那一下如果走根 setState,整个
  /// CupertinoApp(连同 Navigator 和三个页面)都要重建,实测 build 尖峰 40~47ms,
  /// 120Hz 上就是掉五六帧的卡顿。改成 ValueNotifier,只重建 IndexedStack 的 index
  /// 和底栏本身。
  final ValueNotifier<int> _tabIndex = ValueNotifier<int>(0);

  /// 这次横滑累计了多少 dx。手势结束时靠它判「拖得够远」。
  double _swipeDx = 0;
  Brightness _brightness =
      WidgetsBinding.instance.platformDispatcher.platformBrightness;

  // 二级设置页(主题与外观)可改的项。初值在 initState 里从偏好存储读回。
  late AppThemeMode themeMode;
  late bool hideTabLabels;
  late bool glassBottomBar;

  /// 界面缩放:已生效的值。(拖动中的草稿留在缩放卡片自己身上,见 UiScaleCard)
  late double uiScale;

  /// 下载结束后要不要发系统通知。两个开关在「通知管理与下载」页里。
  late bool notifyDownloadDone;
  late bool notifyDownloadFailed;

  /// 进入 APP 自动粘贴剪贴板首条链接并解析。开关在「自动粘贴并解析」页里，默认开。
  late bool autoPasteParse;

  /// 上一次自动粘贴解析过的链接。剪贴板没换内容时不再重复解析，
  /// 免得每次从后台回来都重新打一次解析。
  String? _lastAutoPasted;

  /// 「读剪贴板」那一趟的兜底超时。计时器由页面自己拿着,dispose 时取消。
  ///
  /// 不能就地用 `Future.timeout`:那个计时器没人能取消,页面切走/销毁之后它还挂着
  /// 700ms —— 测试里直接判失败(`A Timer is still pending even after the widget
  /// tree was disposed`),真机上也只是白等一趟。
  Timer? _clipboardDeadline;

  /// 和 [_clipboardDeadline] 配对的那次等待。销毁时要把它也结束掉,否则 await 挂着。
  Completer<String?>? _clipboardWait;

  // ── 检查更新 ──
  late final UpdateService _updates = widget.updates ?? UpdateService();

  /// 本机版本号,启动时问一次 package_info。空串 = 还没问到。
  ///
  /// 不阻塞启动:它只在 [PackageInfo] 回来的那一刻才可能影响"要不要弹更新卡",
  /// 而那时候更新接口多半也还没回。
  String _localVersion = '';

  /// 用户上次忽略的版本。
  String? _ignoredVersion;

  /// 这一趟会话里更新卡已经弹过/正在弹。避免"切个 tab 回来又弹一次"。
  bool _updatePromptShown = false;

  /// 弹层用的导航锚点。
  ///
  /// **不能直接用根 State 的 `context`**:它在 `CupertinoApp` 之上,而 Navigator
  /// 是 CupertinoApp 自己造的 —— 拿它去 `showCupertinoDialog` 会报"context does not
  /// include a Navigator"。页面里那些调用没事,是因为它们用的是页面自己的 context。
  /// 检查更新是在根 State 上发起的,所以这里单独留一个 Navigator 自己的 context。
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// 弹层用的 context。拿不到(还没挂上)就返回 null,调用方直接跳过这次提示 ——
  /// 更新提示不值得为它崩一次。
  BuildContext? get _popupContext {
    final context = _navigatorKey.currentContext;
    return context != null && context.mounted ? context : null;
  }

  /// 正在检查更新(设置页那颗按钮要跟着转)。
  bool checkingUpdate = false;

  /// 「已忽略的版本」那次异步读。见 initState。null = 不需要读(widget.prefs 里有)。
  Future<void>? _ignoredLoaded;

  /// 首次启动的授权卡弹过没有。和忽略状态同一个路数:偏好里能读到就不用再读一次。
  bool _permissionsAsked = false;

  /// 那次异步读。见 initState。
  Future<void> _permissionsAskedLoaded = Future<void>.value();

  // ── 解析页的状态 ──
  //
  // 刻意放在根 State 上,而不是 ParsePage 自己的 State 里:切 tab 会把整棵子树
  // 连同它的 State 一起重建,状态放在页面里的话,解析结果和输入框内容一换 tab
  // 就没了。输入框控制器同理 —— 它的内容也得活着。
  final ParseService parseService = ParseService();
  final HistoryStore _history = HistoryStore();
  final TextEditingController linkController = TextEditingController();

  /// 历史记录。同样放在根 State 上:历史页切走就会被重建,数据留在这儿才不会
  /// 每次进来都重新读一遍存储。
  ///
  /// null = 还没读到(测试里没预传、异步读还没回来)。
  List<HistoryEntry>? historyEntries;

  ParseResult? parseResult;

  /// 正在请求。按钮跟着置灰,避免连点打出多次解析。
  bool parsing = false;

  /// 上一次失败的提示文案。成功一次就清掉。
  String? parseError;

  /// 解析成功后把按钮锁成「完成解析」。点一下输入框、或清空内容才解锁。
  bool parseLocked = false;

  /// 输入框上次是不是空的。用来判断「变空/变非空」这一下要不要重画
  /// (见 [_onLinkChanged]:不能每个字符都 setState)。
  bool _linkWasEmpty = true;

  /// 输入框内容变了:只留有效的链接,并处理清空后的解锁。
  void _onLinkChanged() {
    final raw = linkController.text;
    final url = extractShareUrl(raw);

    // 粘进来的是整段分享文本(「7.62 复制打开抖音…https://… 复制此链接」),
    // 这里只留链接本身。改写后 listener 会再跑一次,那次 raw 已经是干净的 URL,
    // 不再匹配 —— 不会死循环。
    if (url != null && url != raw.trim()) {
      linkController.value = TextEditingValue(
        text: url,
        selection: TextSelection.collapsed(offset: url.length),
      );
      return;
    }

    // 这里**不能**每个字符都 setState。整棵页面树(玻璃面板的 BackdropFilter、
    // 几张预览卡、SVG 图标)会跟着重建,手动输入时每个字符都卡一下。
    // 只有按钮的可用状态真的会变时才需要重画:空 ↔ 非空、以及清空后的解锁。
    final bool empty = raw.trim().isEmpty;
    if (empty == _linkWasEmpty && !(empty && parseLocked)) return;
    setState(() {
      // 点了输入框右侧的叉清空内容 → 按钮从「完成解析」变回「开始解析」
      if (empty) parseLocked = false;
    });
    _linkWasEmpty = empty;
  }

  /// 用户点了输入框。按需求,这时「完成解析」要放回「开始解析」。
  void unlockParse() {
    if (!parseLocked) return;
    setState(() => parseLocked = false);
  }

  Future<void> startParse(String link) async {
    final url = extractShareUrl(link) ?? link.trim();
    if (url.isEmpty) return;

    setState(() {
      parsing = true;
      parseError = null;
      parseLocked = false;
    });

    try {
      final result = await parseService.parse(url);
      if (!mounted) return;
      linkController.text = url;
      setState(() {
        parseResult = result;
        parsing = false;
        parseLocked = true;
      });
      // 只有解析成功才记历史 —— 失败不记,否则历史里全是没用的失败条目。
      // 存储出问题(写满、插件异常)不该影响这次展示,所以吞掉。
      try {
        final entries = await _history.add(result, url);
        if (mounted) setState(() => historyEntries = entries);
      } catch (_) {}

      // 顺手把封面拉进图片缓存。解析完这张图只出现在解析页,历史页要等用户切过去
      // 才第一次发起请求 —— 那时候必然先灰一下。这里提前预热,切过去就是现成的。
      final cover = result.coverUrl;
      if (cover != null && mounted) {
        // 内存缓存:本次运行内立刻可用
        // 传 onError 是必须的:不传的话图片加载失败会变成未处理的 FlutterError。
        precacheImage(NetworkImage(cover), context, onError: (_, _) {});
        // 磁盘缓存:下次冷启动进历史页就不用再等网络了
        CoverCache.store(cover);
      }
    } on ParseException catch (e) {
      if (!mounted) return;
      // 失败时**不**清空 parseResult:换一条链接没解析出来,把上一份结果擦掉
      // 会让人以为越用越少。旧结果留着,只在上面加一条错误提示。
      setState(() {
        parseError = e.message;
        parsing = false;
      });
    }
  }

  /// 历史卡被单击:带着那条记录的链接回解析页重新解析。
  Future<void> reparseFromHistory(HistoryEntry entry) async {
    if (entry.sourceUrl.isEmpty) return;
    linkController.text = entry.sourceUrl;
    _selectTab(0);
    await startParse(entry.sourceUrl);
  }

  /// 读剪贴板里的文字,读不到返回 null。
  ///
  /// **先问平台侧**:它走系统的 `coerceToText`,`text/html`(浏览器复制的链接)、
  /// `text/uri-list`(相册/文件管理器复制的)这些都能读出来,而且会挨条找第一个
  /// 有文字的项。Flutter 自带的 `Clipboard.getData` 只认 `text/plain`,那几类剪贴板
  /// 明明有内容它却回 null —— APP 就会错报「剪贴板里没有内容」。
  ///
  /// 读空时停一下再问一次:刚切回前台那一下,系统偶尔还没把剪贴板交给应用。
  /// 平台侧没有这个方法(测试、非 Android)才退回自带那条路。
  ///
  /// 平台侧卡住(系统剪贴板服务抽风)时不能把「粘贴」晾在那儿:700ms 到点就按
  /// "读不到"收场,给用户一句明确的话,而不是点下去毫无反应。
  ///
  /// 计时器和等待都由页面自己拿着(见 [_clipboardDeadline] / [_clipboardWait]):
  /// 页面销毁时两个一起收掉,不然会留下一个孤儿计时器。
  Future<String?> readClipboard() async {
    final wait = Completer<String?>();
    _clipboardDeadline?.cancel();
    final timer = Timer(const Duration(milliseconds: 700), _finishClipboardRead);
    _clipboardDeadline = timer;
    _clipboardWait = wait;
    try {
      return await Future.any([readClipboardInner(), wait.future]);
    } finally {
      // 只收自己那一次:两个入口(启动自动粘贴、用户点「粘贴」)撞在一起时,
      // 别把对方刚起的计时器收掉。
      if (_clipboardDeadline == timer) {
        timer.cancel();
        _clipboardDeadline = null;
        _clipboardWait = null;
      }
    }
  }

  /// 把等待中的那次读剪贴板就地收场(超时到点、或页面销毁)。
  ///
  /// 必须把等待也结束掉:只取消计时器的话,`Future.any` 永远不返回,那个 await
  /// 就挂在那儿不放了。
  void _finishClipboardRead() {
    final wait = _clipboardWait;
    _clipboardWait = null;
    if (wait != null && !wait.isCompleted) wait.complete(null);
  }

  /// 进入 APP 自动粘贴并解析剪贴板首条链接。
  ///
  /// 只读剪贴板里的第一条文本,挑出其中的分享链接:没有链接、开关关了、
  /// 正在解析、或这条链接上次已经自动解析过,都直接跳过 —— 尤其是最后一条,
  /// 否则每次从后台回来(比如去系统设置开个权限)都会重复打一次解析。
  /// 读不到(系统拦截、剪贴板是空的)也什么都不做,不打扰用户。
  Future<void> _maybeAutoPasteParse() async {
    if (!autoPasteParse || parsing) return;
    final text = await readClipboard();
    if (!mounted) return;
    final url = text == null ? null : extractShareUrl(text);
    if (url == null || url.isEmpty) return;
    if (url == _lastAutoPasted) return;
    _lastAutoPasted = url;
    // 已经是这条且解析完了:不用再打一次。
    if (linkController.text.trim() == url && parseLocked) return;
    unlockParse();
    _selectTab(0);
    linkController.text = url;
    await startParse(url);
  }

  /// 下载结束后的系统通知。发不出去(没权限、系统静音)就算了 ——
  /// 通知只是锦上添花,不能反过来影响下载本身。
  Future<void> notifyDownloadFinished({
    required bool ok,
    required String title,
    String? error,
  }) async {
    if (!downloadNoticeEnabled(
      ok: ok,
      done: notifyDownloadDone,
      failed: notifyDownloadFailed,
    )) {
      return;
    }
    try {
      final ready = notificationsReady;
      if (ready != null) await ready;
      await notifications.show(
        id: DateTime.now().millisecondsSinceEpoch.remainder(1000000),
        title: ok ? '下载完成' : '下载失败',
        body: ok ? '《$title》已保存到本地。' : '《$title》:${error ?? '下载没能完成'}',
        notificationDetails: kNotificationDetails,
      );
    } catch (_) {}
  }

  /// 历史页删记录。数据在根 State 上,所以得由这里落盘并刷新。
  Future<void> deleteHistory(Set<String> ids) async {
    final entries = await _history.remove(ids);
    if (!mounted) return;
    setState(() => historyEntries = entries);
  }

  /// 供二级设置页调用。setState 是 protected,不能从外部 State 直接调,
  /// 所以在这里开一个公开入口统一刷新,顺带把改动落盘。
  void applySetting(VoidCallback change) {
    setState(change);
    _saveSettings();
  }

  void _saveSettings() {
    final prefs = widget.prefs;
    if (prefs == null) return;
    prefs.setString(kPrefsThemeMode, themeMode.name);
    prefs.setBool(kPrefsHideTabLabels, hideTabLabels);
    prefs.setBool(kPrefsGlassBottomBar, glassBottomBar);
    prefs.setDouble(kPrefsUiScale, uiScale);
    prefs.setBool(kPrefsNotifyDownloadDone, notifyDownloadDone);
    prefs.setBool(kPrefsNotifyDownloadFailed, notifyDownloadFailed);
    prefs.setBool(kPrefsAutoPasteParse, autoPasteParse);
  }

  /// 把选好的主题模式同步给原生侧(Android 的**按应用夜间模式**)。
  ///
  /// 系统启动图是按原生那一档取资源的:光落盘不够 —— 改完主题**紧接着**的一次
  /// 冷启动,启动图还会用旧的那一档(启动图是在 Activity 起来之前画好的),再开一次
  /// 才对。所以在这里当场告诉原生侧,下一次冷启动就是对的。
  ///
  /// 原生侧见 MainActivity.applyAppNightMode;老系统/别的平台没有这条路,失败就算了
  /// —— 那只影响启动图的深浅,不该让换主题这件事报错。
  void syncNightModeToNative(AppThemeMode mode) {
    Downloader.channel.invokeMethod<void>('setThemeMode', <String, String>{
      'mode': mode.name,
    }).ignore();
  }

  @override
  void initState() {
    super.initState();
    // 排障:如果这次启动带着 bench_url(见 lib/bench.dart),跑一轮下载基准。
    // 只在 debug 构建里问;release 上这段不会被编译进去。
    if (kDebugMode) DownloadBench.checkIntent();
    final prefs = widget.prefs;
    themeMode =
        AppThemeMode.values.asNameMap()[prefs?.getString(kPrefsThemeMode)] ??
        AppThemeMode.system;
    hideTabLabels = prefs?.getBool(kPrefsHideTabLabels) ?? false;
    glassBottomBar = prefs?.getBool(kPrefsGlassBottomBar) ?? true;
    uiScale = (prefs?.getDouble(kPrefsUiScale) ?? 1).clamp(
      UiScaleCard.min,
      UiScaleCard.max,
    );
    // 通知开关默认都开:下载完不给个动静才是异常。
    notifyDownloadDone = prefs?.getBool(kPrefsNotifyDownloadDone) ?? true;
    notifyDownloadFailed = prefs?.getBool(kPrefsNotifyDownloadFailed) ?? true;
    // 自动粘贴解析默认开:用户从别处复制链接回来就是想解析的。
    autoPasteParse = prefs?.getBool(kPrefsAutoPasteParse) ?? true;
    _ignoredVersion = prefs?.getString(kPrefsIgnoredVersion);
    // widget.prefs 为 null 时(widget 测试、或调用方没传)自己也去读一次。忽略状态
    // 读不到就等于"没忽略过",每次启动都会再弹一次 —— 这条不能只靠调用方传进来的
    // 那一份。读是一次异步,所以存成 Future:检查更新那边会先等它落地,不然自动
    // 检查可能跑在读回来之前,把已忽略的版本又弹一遍。
    if (_ignoredVersion == null) {
      _ignoredLoaded = _loadIgnoredVersion();
    }
    // 首次授权卡同理:widget.prefs 里没有就自己异步补读一次,不然每次启动都要弹。
    _permissionsAsked = prefs?.getBool(kPrefsPermissionsAsked) ?? false;
    if (!_permissionsAsked) {
      _permissionsAskedLoaded = _loadPermissionsAsked();
    }
    WidgetsBinding.instance.addObserver(this);
    linkController.addListener(_onLinkChanged);
    // 冷启动就先把到反代的连接建起来:用户很可能几秒内就粘链接解析。
    parseService.warmUp();

    // 版本号是异步问出来的,不等它:第一帧该出什么还出什么。
    PackageInfo.fromPlatform()
        .then((info) {
          if (!mounted) return;
          _localVersion = info.version;
        })
        .catchError((Object _) {});

    // 每次进 APP 自动检查一次。放在第一帧之后,别和启动动画抢帧。
    if (widget.autoCheckUpdate) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        checkForUpdate();
      });
    }

    // 首次装好的权限引导。也等第一帧:它要弹卡,得先有个能挂弹层的 Navigator。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_askPermissionsOnFirstLaunch());
    });

    // 冷启动自动粘贴解析:用户在别处复制了链接再打开 APP,直接填进输入栏并解析。
    // 等第一帧之后跑,别和启动抢帧;读剪贴板失败(系统拦截)就当没这回事。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_maybeAutoPasteParse());
    });

    // main() 里已经预读过就直接用;没预读(测试)才异步补一次。
    final preloaded = widget.entries;
    if (preloaded != null) {
      historyEntries = preloaded;
      _warmHistoryCovers(preloaded);
    } else {
      _history.load().then((entries) {
        if (!mounted) return;
        setState(() => historyEntries = entries);
        _warmHistoryCovers(entries);
      });
    }
  }

  /// 把历史封面提前送到位。
  ///
  /// 两件事:
  /// 1. 还没落盘的封面补存一份到磁盘(下次冷启动就不用联网了);
  /// 2. 已经能拿到本地文件的,提前解进内存图片缓存 —— 这样切到历史页的**第一帧**
  ///    就能同步命中,不会再有那一下空白。这是「重启后进历史页也立刻出图」的关键。
  void _warmHistoryCovers(List<HistoryEntry> entries) {
    final urls = entries
        .map((entry) => entry.result.coverUrl)
        .whereType<String>()
        .toList();
    // 只处理屏幕上放得下的那几条,别为几十条历史一次并发一堆请求
    CoverCache.storeAll(urls);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final url in urls.take(8)) {
        final file = CoverCache.fileFor(url);
        precacheImage(
          file != null ? FileImage(file) : NetworkImage(url),
          context,
          onError: (_, _) {},
        );
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 剪贴板那一趟还在等平台侧回话:计时器和等待一起收掉,别留孤儿 timer。
    _clipboardDeadline?.cancel();
    _clipboardDeadline = null;
    _finishClipboardRead();
    linkController.dispose();
    parseService.dispose();
    _updates.dispose();
    super.dispose();
  }

  // ── 检查更新 ──

  /// 检查一次有没有新版本。
  ///
  /// [manual] 是用户在设置里点的。手动检查有两处不一样:
  /// 1. "没有新版"时要给个回音(自动检查那时候什么都不弹,没人喜欢每次启动都被
  ///    通知一句"已是最新");
  /// 2. 用户忽略过的版本**照样弹更新卡** —— 是他自己点的检查,不该被上次的「忽略」
  ///    堵住;自动检查才按忽略状态闭嘴。
  Future<void> checkForUpdate({bool manual = false}) async {
    if (checkingUpdate) return;
    setState(() => checkingUpdate = true);
    try {
      if (_localVersion.isEmpty) {
        // 第一次启动时 package_info 可能还没回来。等它一下,不然会把自己当成
        // "版本未知",任何 release 都判不出新旧。
        try {
          final info = await PackageInfo.fromPlatform();
          _localVersion = info.version;
        } catch (_) {
          // 平台侧没有这个插件(测试环境):版本号留空,后面按"认不出就不提示"走
        }
      }
      final release = await _updates.fetchLatest();
      if (!mounted) return;
      // 忽略状态可能还在从存储里读(见 initState):先等它落地,不然自动检查会
      // 把用户已经忽略过的版本又弹一遍。
      await _ignoredLoaded;
      if (!mounted) return;
      final popup = _popupContext;

      if (release == null) {
        if (manual && popup != null && popup.mounted) {
          showInfo(popup, '检查更新', '仓库里还没有发布任何版本。');
        }
        return;
      }
      if (!isNewerVersion(release.version, _localVersion)) {
        if (manual && popup != null && popup.mounted) {
          showInfo(popup, '检查更新', '当前已是最新版本($_localVersion)。');
        }
        return;
      }
      // 忽略过这个版本(或更高的版本)就不再**自动**打扰。
      //
      // 手动检查不在此列:那是用户自己点的「检查更新」,拿上次的「忽略」把他的
      // 路堵掉说不过去 —— 有新版本就照弹更新卡。
      final ignored = !_updates.shouldPrompt(
        localVersion: _localVersion,
        ignored: _ignoredVersion,
        release: release,
      );
      if (ignored && !manual) return;
      if (popup == null || !popup.mounted) return;
      // 自动检查这一趟会话里只弹一次(切个 tab 回来不该又弹一遍);手动检查每次都弹。
      if (_updatePromptShown && !manual) return;
      _updatePromptShown = true;
      await _showUpdateCard(popup, release);
    } on UpdateException catch (error) {
      final popup = _popupContext;
      if (manual && popup != null && popup.mounted) {
        showInfo(popup, '检查更新失败', error.message);
      }
    } catch (error) {
      final popup = _popupContext;
      if (manual && popup != null && popup.mounted) {
        showInfo(popup, '检查更新失败', '$error');
      }
    } finally {
      if (mounted) setState(() => checkingUpdate = false);
    }
  }

  /// 弹「版本更新」卡片。用户选完(更新/忽略)才返回。
  Future<void> _showUpdateCard(BuildContext context, ReleaseInfo release) =>
      showUpdateCard(
        context,
        release: release,
        currentVersion: _localVersion,
        onIgnore: () {
          // 记住这个版本:下次启动不再提示,直到仓库发了更高的版本。
          // 用 getInstance 而不是 widget.prefs:后者在测试里可能是 null(那个口子
          // 是给"不落盘"用的),忽略状态落不下去就等于每次启动都再弹一次。
          _ignoredVersion = release.version;
          unawaited(_rememberIgnored(release.version));
        },
        onUpdate: () => _startUpdate(release),
      );

  /// 补读「已忽略的版本」。见 initState 里的说明。
  Future<void> _loadIgnoredVersion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final ignored = prefs.getString(kPrefsIgnoredVersion);
      if (ignored != null && ignored.isNotEmpty) {
        _ignoredVersion = ignored;
      }
    } catch (_) {
      // 读不到就当没忽略过
    }
  }

  /// 把「已忽略的版本」写进偏好存储。  ///
  /// 拿不到存储就算了:那说明这台设备上偏好读写整个用不了,别的设置也早就不生效了
  /// —— 这里再抛一次只会把点「忽略」这件事变成崩溃。
  Future<void> _rememberIgnored(String version) async {
    try {
      final prefs = widget.prefs ?? await SharedPreferences.getInstance();
      await prefs.setString(kPrefsIgnoredVersion, version);
    } catch (_) {}
  }

  /// 点「更新」:开窗口 → 下载 → 交给系统安装器。
  ///
  /// 「安装未知应用」那道授权**不在这里问** —— 它要等包下完了才问(见
  /// [_downloadAndInstall]):那时用户刚看着进度条走完,跳过去授权是一目了然的;
  /// 一上来就跳系统设置页,用户只会觉得莫名其妙。
  Future<void> _startUpdate(ReleaseInfo release) =>
      _downloadAndInstall(release);

  Future<bool> _canInstallApk() async {
    try {
      final ok = await Downloader.channel.invokeMethod<bool>('canInstallApk');
      return ok ?? true;
    } catch (_) {
      // 平台侧没有这个方法(比如测试环境):按"可以"处理,别把路堵死
      return true;
    }
  }

  Future<bool> _openInstallPermission() async {
    try {
      final ok = await Downloader.channel.invokeMethod<bool>(
        'openInstallPermission',
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  // ── 首次进入的权限 ──

  /// 首次进入 APP 时问一次通知权限。
  ///
  /// **这个弹窗是系统给的**(Android 13 起的系统授权框),APP 自己不多画一张卡。
  /// 摆在这儿是因为没通知权限的话,下载完用户什么都收不到,还以为是我们没做。
  ///
  /// 「安装未知应用」**刻意不在这里问**:系统没有"直接问"的接口,只能跳到它那一页,
  /// 而刚装好 APP 就被甩到系统设置里,用户只会觉得莫名其妙。那道授权挪到更新流程
  /// 里、包下完之后再跳 —— 见 [_downloadAndInstall]。
  ///
  /// 只问一次(记在偏好里):系统拒过一次之后再问也不会弹框。平台侧问不出来
  /// (测试 / 非 Android)就整段跳过。
  Future<void> _askPermissionsOnFirstLaunch() async {
    await _permissionsAskedLoaded;
    if (!mounted || _permissionsAsked) return;

    final enabled = await notificationsEnabled();
    if (!mounted) return;
    if (enabled == false) await requestNotificationPermission();
    if (!mounted) return;

    _permissionsAsked = true;
    unawaited(_rememberPermissionsAsked());
  }

  /// 补读「首次权限问过了吗」。见 initState。
  Future<void> _loadPermissionsAsked() async {
    try {
      final prefs = widget.prefs ?? await SharedPreferences.getInstance();
      if (!mounted) return;
      _permissionsAsked = prefs.getBool(kPrefsPermissionsAsked) ?? false;
    } catch (_) {
      // 读不到就当没问过:这次会再问一遍,最多重复一次
    }
  }

  Future<void> _rememberPermissionsAsked() async {
    try {
      final prefs = widget.prefs ?? await SharedPreferences.getInstance();
      await prefs.setBool(kPrefsPermissionsAsked, true);
    } catch (_) {}
  }

  /// 下载进度窗口 + 下完拉起安装器。
  ///
  /// 三件事按顺序来:开窗口 → 流式下载(进度实时报给窗口)→ 交给系统安装器。
  /// 安装完系统会覆盖安装并重启进程,所以这里的收尾基本都是给"没装成"那条路用的。
  Future<void> _downloadAndInstall(ReleaseInfo release) async {
    final popup = _popupContext;
    if (popup == null) return;
    final controller = ApkDownloadController();
    // 不 await 这个弹层:它要等用户关掉才返回,而下面还要往里推状态
    unawaited(
      showApkDownloadCard(
        popup,
        title: '版本更新',
        subtitle: '正在下载 ${release.version}',
        controller: controller,
      ),
    );
    try {
      final dir = await getTemporaryDirectory();
      final cached = ApkCache.existing(release, dir);
      if (cached == null) {
        await _updates.downloadApk(
          release,
          dir: dir,
          onProgress: controller.report,
          cancelled: () => controller.cancelled,
        );
      } else {
        // 上一趟下完但没装成(权限没开、用户没点安装):直接用,别重下 20MB
        final size = cached.lengthSync();
        controller.report(ApkProgress(received: size, total: size));
      }
      if (!mounted) return;
      final path = '${dir.path}/${release.apkName}';
      if (!await _canInstallApk()) {
        // 包已经在缓存里了,现在只差系统那道「安装未知应用」授权。
        // **直接跳过去,不弹 APP 自己的说明卡**:用户刚看着进度条走完,为什么跳
        // 是一目了然的;等到从设置页回来(见 didChangeAppLifecycleState)再自动装,
        // 他不用回来重新点一次「更新」,包也不会重下。
        _pendingInstall = path;
        controller.close();
        if (!await _openInstallPermission()) _finishPendingInstall();
        return;
      }
      await _installApk(path);
      controller.close();
    } on UpdateCancelled {
      controller.close();
    } catch (error) {
      controller.fail('$error');
    }
  }

  Future<void> _installApk(String path) async {
    try {
      await Downloader.channel.invokeMethod<String>('installApk', {
        'path': path,
      });
    } catch (error) {
      final popup = _popupContext;
      if (popup != null && popup.mounted) {
        showInfo(popup, '安装没能开始', '$error');
      }
    }
  }

  /// 下好却卡在「安装未知应用」授权上的那个包。见 [_downloadAndInstall]。
  ///
  /// 用户去系统设置页开权限时 APP 会退到后台,所以留着它,等回到前台再接着装。
  String? _pendingInstall;

  /// 从设置页回来:权限开了就把包交给安装器,没开就明说一句。
  ///
  /// 这一步不能省:用户点了「更新」、看着包下完、又被带去设置页,回来时如果什么
  /// 都不发生,他会以为更新坏了。
  Future<void> _finishPendingInstall() async {
    final path = _pendingInstall;
    if (path == null) return;
    _pendingInstall = null;
    if (await _canInstallApk()) {
      if (!mounted) return;
      await _installApk(path);
      return;
    }
    final popup = _popupContext;
    if (popup != null && popup.mounted) {
      showInfo(popup, '还差一步', '请在系统设置里允许「即存」安装应用,回来就会自动安装。');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 只认"回到前台":跳系统设置页会先后台、再前台,权限就是在那儿开的。
    if (state == AppLifecycleState.resumed) {
      unawaited(_finishPendingInstall());
      // 从别处复制链接后回到 APP:自动粘贴首条链接并解析(开关控制)。
      unawaited(_maybeAutoPasteParse());
    }
  }

  @override
  void didChangePlatformBrightness() {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    if (brightness != _brightness && mounted) {
      setState(() => _brightness = brightness);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 主题模式:跟随系统时用平台亮度,_brightness 由 didChangePlatformBrightness 保持最新
    final brightness = switch (themeMode) {
      AppThemeMode.system => _brightness,
      AppThemeMode.light => Brightness.light,
      AppThemeMode.dark => Brightness.dark,
    };
    final isDark = brightness == Brightness.dark;
    return CupertinoApp(
      title: '即存',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: CupertinoThemeData(
        brightness: brightness,
        primaryColor: const Color(0xFF1677FF),
      ),
      // 这里只把缩放值传下去,不再把整棵树包进 Transform。
      //
      // 原因:底部玻璃栏内部是 BackdropFilter。缩放是靠绘制期 Transform 做的,
      // 缩小时虚拟画布比屏幕大(OverflowBox 放行溢出),BackdropFilter 采样背景的
      // 区域会被裁到父级边界上,于是「玻璃面板」整体画偏 —— 图标是普通绘制、
      // 位置正确,面板却往左错开一截,看着就是底栏错位。所以缩放只作用于页面内容
      // (见 body 与 SubPage),底栏分成单独的绘制层,不参与缩放。
      builder: (context, child) =>
          UiScale(scale: uiScale, child: child ?? const SizedBox.shrink()),
      home: Stack(
        children: [
          // 弹层外面那层全屏模糊(见 [PopupShell])第一次用要现编译着色器,实测
          // 第一次弹窗会卡一下 —— 启动时先拿 1 个像素把它热起来。1×1 的模糊开销
          // 可以忽略,而且它压在整棵界面下面,看不见。
          Positioned(
            left: 0,
            top: 0,
            child: SizedBox(
              width: 1,
              height: 1,
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: const ColoredBox(color: Color(0x00000000)),
              ),
            ),
          ),
          GlassScaffold(
            // 键盘弹出时**不收**底栏,让输入法直接盖在它上面。
            //
            // 库把这个参数直接透给 CupertinoPageScaffold(默认 true):为真时整个
            // Stack 会被键盘顶掉一段高度,而底栏是 Positioned(bottom: 0),于是跟着
            // 键盘一起升到半空 —— 就是「底栏被顶起来」那一幕。置 false 后 Stack 保持
            // 全高,底栏留在屏幕底、由输入法盖住,和 iOS 原生 App 一样。
            //
            // 代价:内容不再为键盘让位。首页只有顶部一个输入框,编辑时不会被键盘挡住;
            // 二级设置页没有输入控件。所以这一条在这里是安全的 —— 以后若在页面底部
            // 加输入框,得自己给列表补 bottom padding(viewInsets.bottom)。
            resizeToAvoidBottomInset: false,
            // 背景放回库的取景位(玻璃底栏要采样它),去掉 CupertinoPageScaffold 的
            // 顶部内缩,保证画满整屏 800 而不是 760。
            //
            // 这里刻意**不用** MediaQuery.removePadding(context: ...):那个 API 内部
            // 走的是全 aspect 的 MediaQuery.of,依赖会挂在 _AppState 上 —— 键盘弹出时
            // viewInsets 一变,整个 App 连同三个页面一起重建,点输入框那一下的卡顿就是
            // 它。MediaQueryData.fromView 是静态读、不注册依赖,数据来源和根部那个
            // MediaQuery 是同一个 view,所以背景的观感与尺寸都不变,只是不再跟着
            // 键盘 insets 重建。
            background: RepaintBoundary(
              child: MediaQuery(
                data: MediaQueryData.fromView(View.of(context))
                    .removePadding(removeTop: true),
                child: ThemeBackground(
                  isDark: isDark,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            backgroundColor: isDark
                ? const Color(0xFF434343)
                : const Color(0xFFCDDCDC),
            statusBarStyle: isDark
                ? GlassStatusBarStyle.light
                : GlassStatusBarStyle.dark,
            // 底栏单独订一个 _tabIndex:切板块时只有它和下面的 IndexedStack 重建,
            // 页面树与 Navigator 原地不动。
            bottomBar: ValueListenableBuilder<int>(
              valueListenable: _tabIndex,
              builder: (context, index, _) => glassBottomBar
                  ? GlassTabBar.bottom(
                      iconSize: 24,
                      // 刻意**不传** interactionGlowRadius:null 才是库照 iOS 26 标定的
                      // 原生触摸柔光(半径 1.6 / 模糊 16 / 白 7%(深)10%(浅))。实测真机
                      // 按住底栏:原生档亮度增量 4.15、点亮 6168 px,显式 1.5 是 7.58 /
                      // 14070 px(主题档 sigma 只有 4,会画出一圈看得见的硬边)。任何显式
                      // 数值都会退回主题档,别"顺手补一个"。
                      // 选中态不带任何强调色:每个 tab 不传 glowColor,选中图标后面
                      // 那团彩色光已经去掉了,底栏上除了玻璃胶囊本身不留颜色。
                      // 曾经显式设过 indicatorColor:它能让胶囊按槽位宽度渲染、消掉两侧约 13px
                      // 的未覆盖缺口,但那条渲染路径是平涂、不走玻璃,观感会变成一块实心色。
                      // 结论:保留玻璃质感的胶囊,接受它比槽位略窄。
                      // 这里刻意**不设** selectedIconColor,原因(模拟器实测):
                      // 1. 标签文字默认直接复用 iconColor(tab_bar_bottom_internal.dart:208-213),
                      //    设了它会连"解析"两个字一起染蓝;
                      // 2. 蓝图标叠在蓝色胶囊上,选中项反而比未选中的黑白图标更难读
                      //    (#1677FF 在浅色玻璃上仅 2.77:1,低于 3:1)。
                      tabs: [
                        for (final t in _tabDefs)
                          GlassTab(
                            icon: _tabIcon(t.icon),
                            // 选中槽位只在被选中时构建 → 构建即播放一次,播完停在终态
                            activeIcon: AnimatedTabIcon(t.active),
                            // 开启"底栏文字标识隐藏"时传 null:GlassTab 只要求 icon/label
                            // 至少有一个,label 为 null 合法;无障碍名仍由 semanticLabel 提供
                            label: hideTabLabels ? null : t.label,
                            semanticLabel: t.label,
                          ),
                      ],
                      selectedIndex: index,
                      onTabSelected: _selectTab,
                    )
                  // 关闭液态玻璃:换成 CupertinoTabBar。自带底部安全区;底色必须不透明,
                  // 否则它会自动叠一层模糊,又变回玻璃。无光晕、无高光、无指示器胶囊。
                  : _plainTabBar(isDark, index),
            ),
            body: UiZoom(
              scale: uiScale,
              // 背景改由 GlassScaffold.background 整屏绘制(见上方),这里只留内容。
              // SafeArea 照旧:它只管内容,不再影响背景的绘制矩形。
              // 外面再包一层「键盘内缩不进子树」:键盘弹出时 viewInsets 会一路传到
              // 页面里,整页跟着重建一次 —— 输入框在顶部、页面本来就不为键盘让位
              // (见 resizeToAvoidBottomInset),这一下重建纯属白费,点输入框那一下
              // 的卡顿就是它。底栏不在这棵子树里,不受影响。
              child: NoKeyboardInset(
                child: SafeArea(
                  bottom: false,
                  child: _buildTabPage(isDark: isDark),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 切板块。只推 _tabIndex,不碰根 State —— 见 [_tabIndex] 的注释。
  void _selectTab(int index) => _tabIndex.value = index;

  /// 页面中间区域左右滑动 = 切板块,省得每次去点底栏。
  ///
  /// 两种手势都算:一挥(按速度)、或者横向拖够 [_kTabSwipeDistance](按距离)。
  /// 往左划是下一个板块,往右划是上一个,顺序和底栏从左到右一致。
  ///
  /// **页面里自己的横向手势照旧归它们**:视频画面拖进度、缩略图条、进度条、设置页
  /// 的滑块都在更里层,手势竞技场里赢的是更里层那个。所以那些地方划过是它们干活,
  /// 不会翻页 —— 这正是想要的,不然视频就没法拖进度了。
  void _onTabSwipeStart(DragStartDetails details) => _swipeDx = 0;

  void _onTabSwipeUpdate(DragUpdateDetails details) =>
      _swipeDx += details.delta.dx;

  void _onTabSwipeEnd(DragEndDetails details, int index) {
    final velocity = details.primaryVelocity ?? 0;
    final far = _swipeDx.abs() >= _kTabSwipeDistance;
    if (!far && velocity.abs() < _kTabSwipeVelocity) return;
    final forward = far ? _swipeDx < 0 : velocity < 0;
    final next = index + (forward ? 1 : -1);
    // 到头了(解析再往右、设置再往左)不动,不做循环。
    if (next < 0 || next >= _tabDefs.length) return;
    _selectTab(next);
  }

  Widget _buildTabPage({required bool isDark}) {
    // IndexedStack 而不是 switch:切走的页面**不销毁**,只隐藏。
    // switch 每次 setState 都会把上一页整棵子树拆掉,预览播放器跟着一起没了 ——
    // 切去历史再切回来,进度就打回 00:00(哪怕刚刚才播到一半)。
    // 代价:三个页面都常驻,首帧会多建两棵子树。
    //
    // 三个页面 widget 在这里现造:它们吃根 State(解析结果、主题、各个开关),
    // 根 setState 时必须跟着重建 —— 所以不能缓存成字段(同一个 widget 实例会被
    // 框架判定为「没变」而整棵跳过)。而切板块只推 _tabIndex,这个函数不会重跑,
    // builder 闭包里抓到的还是同一批实例,框架照样跳过三页的重建 —— 两件事都要。
    final pages = <Widget>[
      ParsePage(app: this),
      HistoryPage(app: this),
      SettingsPage(app: this),
    ];
    return ValueListenableBuilder<int>(
      valueListenable: _tabIndex,
      builder: (context, index, _) => GestureDetector(
        // 页面里到处是卡片,空白处也得能划,所以是 opaque 而不是默认的 deferToChild。
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _onTabSwipeStart,
        onHorizontalDragUpdate: _onTabSwipeUpdate,
        onHorizontalDragEnd: (details) => _onTabSwipeEnd(details, index),
        child: IndexedStack(index: index, children: pages),
      ),
    );
  }

  // 三个 tab 的资源与文案,玻璃栏和纯栏共用一份
  static const _tabDefs = <({String icon, String active, String label})>[
    (icon: '未选中24x24-SVG/解析.svg', active: '选中24x24-SVG/解析.svg', label: '解析'),
    (icon: '未选中24x24-SVG/历史.svg', active: '选中24x24-SVG/历史.svg', label: '历史'),
    (icon: '未选中24x24-SVG/设置.svg', active: '选中24x24-SVG/设置.svg', label: '设置'),
  ];

  Widget _tabIcon(String assetPath) {
    // 用 TintedSvgIcon 而不是裸 SvgPicture:这 6 个 SVG 都是
    // fill="#000000" 硬编码,不吃 IconTheme,深色玻璃上会变成黑上加黑。
    return TintedSvgIcon(assetPath, size: 24);
  }

  /// 无玻璃的悬浮底栏。外形与位置对齐玻璃栏(实测 386×63 逻辑px,左右各留
  /// 20,距屏幕底约 45),内部换成磨砂不透明的底。选中项是一块中性磨砂胶囊,
  /// 底栏上一点彩色都不留。
  /// 刻意没有:缩放/捏合、高光、拖拽位移 —— 只有一次平移动画。
  Widget _plainTabBar(bool isDark, int selected) {
    const double barHeight = 63;
    const double barRadius = barHeight / 2;
    final int count = _tabDefs.length;
    final Color fill = isDark
        ? const Color(0xE61C1C1E)
        : const Color(0xE6F2F2F7);

    return Padding(
      // 实测对齐玻璃栏:上=2532 左=60 右=1219(设备px,3x)
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
      child: SizedBox(
        height: barHeight,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(barRadius),
          child: DecoratedBox(
            decoration: BoxDecoration(color: fill),
            child: Stack(
              children: [
                // 选中项:一块中性磨砂胶囊,底栏上一点彩色都不留 —— 和液态玻璃栏
                // 的中性指示器一个观感。
                AnimatedAlign(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  alignment: Alignment(
                    count == 1 ? 0 : -1 + 2 * selected / (count - 1),
                    0,
                  ),
                  child: FractionallySizedBox(
                    widthFactor: 1 / count,
                    heightFactor: 1,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0x24FFFFFF)
                              : const Color(0x17000000),
                          borderRadius: BorderRadius.circular(26),
                        ),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (int i = 0; i < count; i++)
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _selectTab(i),
                          child: _plainTabItem(i, isDark, selected),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _plainTabItem(int index, bool isDark, int selected) {
    final t = _tabDefs[index];
    final bool isSelected = index == selected;
    // 选中项压在中性磨砂上,得用前景色;白图标压白磨砂等于没画。未选中沿用底栏那套中性色。
    final Color color = isSelected
        ? settingsPalette(isDark).foreground
        : (isDark ? const Color(0xFF9A9AA0) : const Color(0xFF8A8A8E));
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconTheme(
            data: IconThemeData(color: color, size: 24),
            child: SizedBox(
              width: 24,
              height: 24,
              // 选中用填充版图形,与玻璃栏一致
              child: _tabIcon(isSelected ? t.active : t.icon),
            ),
          ),
          if (!hideTabLabels) ...[
            const SizedBox(height: 2),
            Text(
              t.label,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

