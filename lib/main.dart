import 'package:flutter/cupertino.dart';
// 二级设置页走 Google(Material 3)风格,所以只从这里取需要的几个控件;
// 显式 show 是为了不和 cupertino.dart 的同名导出撞车。
import 'package:flutter/material.dart'
    show
        ColorScheme,
        FilledButton,
        InkWell,
        Material,
        MaterialType,
        NoSplash,
        Radio,
        RadioGroup,
        Slider,
        SliderComponentShape,
        SliderTheme,
        Switch,
        Theme,
        ThemeData,
        WidgetState,
        WidgetStateProperty,
        WidgetStatePropertyAll;

import 'dart:async';
import 'dart:convert';
// 进度环的渐变要 ui.Gradient.linear:widgets 里的 Gradient 是另一套东西
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
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
import 'widgets/tap_easter_egg.dart';

import 'api_host.dart';
import 'ui/notifications.dart';
import 'ui/prefs.dart';
import 'ui/motion.dart';
import 'ui/icons.dart';
import 'ui/clipboard.dart';
import 'ui/widgets.dart';
import 'ui/palette.dart';
import 'pages/parse.dart';
import 'pages/history.dart';
import 'ui/popup.dart';

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
  late AppThemeMode _themeMode;
  late bool _hideTabLabels;
  late bool _glassBottomBar;

  /// 界面缩放:已生效的值。(拖动中的草稿留在缩放卡片自己身上,见 _UiScaleCard)
  late double _uiScale;

  /// 下载结束后要不要发系统通知。两个开关在「通知管理与下载」页里。
  late bool _notifyDownloadDone;
  late bool _notifyDownloadFailed;

  /// 进入 APP 自动粘贴剪贴板首条链接并解析。开关在「自动粘贴并解析」页里，默认开。
  late bool _autoPasteParse;

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
  bool _checkingUpdate = false;

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
    if (!_autoPasteParse || parsing) return;
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
      done: _notifyDownloadDone,
      failed: _notifyDownloadFailed,
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
    prefs.setString(kPrefsThemeMode, _themeMode.name);
    prefs.setBool(kPrefsHideTabLabels, _hideTabLabels);
    prefs.setBool(kPrefsGlassBottomBar, _glassBottomBar);
    prefs.setDouble(kPrefsUiScale, _uiScale);
    prefs.setBool(kPrefsNotifyDownloadDone, _notifyDownloadDone);
    prefs.setBool(kPrefsNotifyDownloadFailed, _notifyDownloadFailed);
    prefs.setBool(kPrefsAutoPasteParse, _autoPasteParse);
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
    _themeMode =
        AppThemeMode.values.asNameMap()[prefs?.getString(kPrefsThemeMode)] ??
        AppThemeMode.system;
    _hideTabLabels = prefs?.getBool(kPrefsHideTabLabels) ?? false;
    _glassBottomBar = prefs?.getBool(kPrefsGlassBottomBar) ?? true;
    _uiScale = (prefs?.getDouble(kPrefsUiScale) ?? 1).clamp(
      _UiScaleCard.min,
      _UiScaleCard.max,
    );
    // 通知开关默认都开:下载完不给个动静才是异常。
    _notifyDownloadDone = prefs?.getBool(kPrefsNotifyDownloadDone) ?? true;
    _notifyDownloadFailed = prefs?.getBool(kPrefsNotifyDownloadFailed) ?? true;
    // 自动粘贴解析默认开:用户从别处复制链接回来就是想解析的。
    _autoPasteParse = prefs?.getBool(kPrefsAutoPasteParse) ?? true;
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
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
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
      if (mounted) setState(() => _checkingUpdate = false);
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
    final brightness = switch (_themeMode) {
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
      // (见 body 与 _SubPage),底栏分成单独的绘制层,不参与缩放。
      builder: (context, child) =>
          _UiScale(scale: _uiScale, child: child ?? const SizedBox.shrink()),
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
              builder: (context, index, _) => _glassBottomBar
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
                            label: _hideTabLabels ? null : t.label,
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
            body: _UiZoom(
              scale: _uiScale,
              // 背景改由 GlassScaffold.background 整屏绘制(见上方),这里只留内容。
              // SafeArea 照旧:它只管内容,不再影响背景的绘制矩形。
              // 外面再包一层「键盘内缩不进子树」:键盘弹出时 viewInsets 会一路传到
              // 页面里,整页跟着重建一次 —— 输入框在顶部、页面本来就不为键盘让位
              // (见 resizeToAvoidBottomInset),这一下重建纯属白费,点输入框那一下
              // 的卡顿就是它。底栏不在这棵子树里,不受影响。
              child: _NoKeyboardInset(
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
      _SettingsPage(app: this),
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
          if (!_hideTabLabels) ...[
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

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.app});

  /// 二级页要改的是应用级状态(主题、底栏),所以直接持有根 State。
  final HomeShellState app;

  static const _options = <_SettingsOption>[
    _SettingsOption('主题与外观', '修改主题、显示效果'),
    _SettingsOption('通知管理与下载', '通知管理与存储位置', icon: '通知管理'),
    _SettingsOption('自动粘贴并解析', '剪贴板首条链接自动解析', icon: '通知管理'),
    // 检查更新是当场就办事的,没有下一级页面,所以不给箭头。
    _SettingsOption('检查更新', '点击检查最新版本', showChevron: false),
    _SettingsOption('使用帮助及反馈', '查看使用帮助或提交反馈', icon: '帮助及联系反馈'),
    _SettingsOption('关于本APP', '开源地址、彩蛋出席'),
    _SettingsOption('彩蛋提示', '看看APP里藏了什么'),
  ];

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const ShortBounceScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, kBoardHeaderTop, 20, 120),
      children: [
        const BoardHeader(title: '设置'),
        const SizedBox(height: 18),
        ..._options.asMap().entries.map(
          (entry) => Padding(
            padding: EdgeInsets.only(
              bottom: entry.key == _options.length - 1 ? 0 : 12,
            ),
            child: _SettingsOptionCard(
              option: entry.value,
              // 检查更新要打网络,慢的时候好几秒;转个圈至少让人知道点到了
              busy: entry.value.title == '检查更新' && app._checkingUpdate,
              onPressed: () => _handleOption(context, entry.value.title),
            ),
          ),
        ),
      ],
    );
  }

  void _handleOption(BuildContext context, String title) {
    if (title == '检查更新') {
      // 手动检查:没新版、被忽略过、检查失败都要给个回音 —— 用户是主动点的,
      // 什么都不弹会让人以为按钮坏了(见 checkForUpdate 的 manual 参数)。
      app.checkForUpdate(manual: true);
      return;
    }

    if (title == '主题与外观') {
      Navigator.of(context).push(
        _SubPageRoute<void>(builder: (_) => _ThemeAppearancePage(app: app)),
      );
      return;
    }

    if (title == '通知管理与下载') {
      Navigator.of(context).push(
        _SubPageRoute<void>(
          builder: (_) => _NotificationManagementPage(app: app),
        ),
      );
      return;
    }

    if (title == '自动粘贴并解析') {
      Navigator.of(context).push(
        _SubPageRoute<void>(builder: (_) => _AutoPastePage(app: app)),
      );
      return;
    }

    if (title == '使用帮助及反馈') {
      Navigator.of(context)
          .push(_SubPageRoute<void>(builder: (_) => const _HelpFeedbackPage()));
      return;
    }

    if (title == '关于本APP') {
      Navigator.of(context)
          .push(_SubPageRoute<void>(builder: (_) => const _AboutAppPage()));
      return;
    }

    if (title == '彩蛋提示') {
      Navigator.of(context)
          .push(_SubPageRoute<void>(builder: (_) => const _EasterEggHintPage()));
      return;
    }

    // 这个分支目前只有「使用帮助及反馈」到得了,但别处加一项没做二级页的设置就是它
    showInfo(context, title, '该设置项将在后续版本开放。');
  }
}

class _SettingsOption {
  const _SettingsOption(
    this.title,
    this.subtitle, {
    this.icon,
    this.showChevron = true,
  });

  final String title;
  final String subtitle;

  /// 右侧箭头。false 用于没有二级页、点一下就地生效的条目(检查更新)。
  final bool showChevron;

  /// 图标文件名(不含扩展名)。不填就拿标题当文件名。
  ///
  /// 单独留一个字段,是为了「改文案不用跟着改资源名」——图标是按旧标题命名的,
  /// 文案一改,靠标题拼路径就找不到图了。
  final String? icon;
}

class _SettingsOptionCard extends StatelessWidget {
  const _SettingsOptionCard({
    required this.option,
    required this.onPressed,
    this.busy = false,
  });

  final _SettingsOption option;
  final VoidCallback onPressed;

  /// 这一项正在办事(目前只有「检查更新」)。为真时右侧显示转圈并挡住重复点击 ——
  /// 检查更新要打网络,慢的时候好几秒才有回音,不给任何动静就像按钮坏了。
  final bool busy;

  String _iconPath(BuildContext context) =>
      settingsIcon(context, '${option.icon ?? option.title}.svg');

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final secondary = settingsPalette(isDark).secondary;

    // 手写模糊面板。库的 GlassCard 无论走着色器路径、还是嵌套时的 vibrancy fill
    // 路径,都会在边界画一道高光:实测上沿 1 设备像素亮线(76 vs 内部 12),
    // 左沿 68 vs 内部 14,且 lightIntensity / fresnelStrength / useOwnLayer
    // 都关不掉。既然只要模糊,就自己拼,不再和库的着色器纠缠。
    final content = CupertinoButton(
      // 原来 18/18/16/18 + 50px 圆角块 = 86px 高,圆角块比右侧文字块还高,
      // 视觉上被图标块主导。收紧到 68px,让文字块重新成为主体。
      padding: const EdgeInsets.fromLTRB(16, 13, 14, 13),
      onPressed: busy ? null : onPressed,
      pressedOpacity: 0.72,
      child: Row(
        children: [
          // 尺寸 20 而非资源的 24:图形在 24x24 画布里没有留白,
          // 按 24 渲染会顶满圆角块,20 才是正常呼吸感。
          GlassIconChip(isDark: isDark, asset: _iconPath(context)),
          const SizedBox(width: 14),
          Expanded(
            child: CardHeadline(
              isDark: isDark,
              title: option.title,
              subtitle: option.subtitle,
            ),
          ),
          if (busy) ...[
            const SizedBox(width: 8),
            // 用文字而不是转圈:转圈是**无限动画**,页面就再也 pumpAndSettle 不了
            // (用例里实测直接超时)。文字同样是"点到了、正在办"的回音,还不花帧。
            Text(
              '检查中…',
              style: TextStyle(
                color: secondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ] else if (option.showChevron) ...[
            const SizedBox(width: 8),
            Icon(CupertinoIcons.chevron_forward, color: secondary, size: 17),
          ],
        ],
      ),
    );

    return GlassPanel(isDark: isDark, child: content);
  }
}

class _NotificationManagementPage extends StatefulWidget {
  const _NotificationManagementPage({required this.app});

  /// 这两个开关下载流程要用,所以和「主题与外观」一样直接持有根 State。
  final HomeShellState app;

  @override
  State<_NotificationManagementPage> createState() =>
      _NotificationManagementPageState();
}

class _NotificationManagementPageState
    extends State<_NotificationManagementPage> {
  bool _isSending = false;

  HomeShellState get app => widget.app;

  /// 要一次通知权限。和首次授权卡走同一个实现,免得两处判断分家。
  Future<bool> _requestPermission() => requestNotificationPermission();

  /// 拨一个下载通知开关。
  ///
  /// 打开前先要系统通知权限:没权限就别把开关点亮 —— 点亮了却弹不出通知,
  /// 用户只会以为是我们没做。关闭不需要权限,直接写。
  Future<void> _setNotify({required bool onDone, required bool value}) async {
    if (value) {
      final granted = await _requestPermission();
      if (!mounted) return;
      if (!granted) {
        showInfo(
          context,
          '通知权限未开启',
          '请在系统设置中允许即存发送通知。',
          icon: settingsIcon(context, '通知管理.svg'),
        );
        return;
      }
    }
    app.applySetting(() {
      if (onDone) {
        app._notifyDownloadDone = value;
      } else {
        app._notifyDownloadFailed = value;
      }
    });
  }

  Future<void> _sendTestNotification() async {
    setState(() => _isSending = true);
    try {
      final granted = await _requestPermission();
      if (!mounted) return;
      if (!granted) {
        showInfo(
          context,
          '通知权限未开启',
          '请在系统设置中允许即存发送通知。',
          icon: settingsIcon(context, '通知管理.svg'),
        );
        return;
      }
      final ready = notificationsReady;
      if (ready != null) await ready;
      await notifications.show(
        id: DateTime.now().millisecondsSinceEpoch.remainder(1000000),
        title: '即存通知测试',
        body: '通知功能运行正常。',
        notificationDetails: kNotificationDetails,
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    // 给顶栏图让出的高度。图按屏宽等比缩,所以这里也按屏宽算,
    // 两边同一个 _kHeaderArtAspect,界面缩放下不会错位。
    final headerHeight = MediaQuery.sizeOf(context).width / _kHeaderArtAspect;
    // 画面底边在画布 564/605 处(实测 bbox;画布下方那段是透明的),
    // 第一张卡从图底边往下 5dp 起。
    final headerBottom = headerHeight * 564 / 605;

    return _SubPage(
      title: '通知管理与下载',
      // 抠好的插画带一圈白描边:深色模式下靠它把角色从背景里拎出来,
      // 浅色模式下描边和背景同色等于隐形,所以深浅两模式共用这一张。
      headerImage: 'assets/theme-header/theme_top_2.png',
      child: _GoogleSurface(
        brightness: isDark ? Brightness.dark : Brightness.light,
        child: SafeArea(
          child: ListView(
            physics: const ShortBounceScrollPhysics(),
            padding: EdgeInsets.fromLTRB(20, headerBottom + 5, 20, 32),
            children: [
              GlassPanel(
                isDark: isDark,
                child: _GoogleSwitchRow(
                  isDark: isDark,
                  title: '下载完成通知',
                  subtitle: '下载成功后,在系统状态栏提醒一声',
                  value: app._notifyDownloadDone,
                  onChanged: (value) => _setNotify(onDone: true, value: value),
                ),
              ),
              const SizedBox(height: 12),
              GlassPanel(
                isDark: isDark,
                child: _GoogleSwitchRow(
                  isDark: isDark,
                  title: '下载失败通知',
                  subtitle: '下载中断或出错时提醒,免得白等',
                  value: app._notifyDownloadFailed,
                  onChanged: (value) => _setNotify(onDone: false, value: value),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _isSending ? null : _sendTestNotification,
                child: Text(_isSending ? '发送中…' : '测试通知'),
              ),
              const SizedBox(height: 24),
              _StorageLocationCard(isDark: isDark),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「设置 → 自动粘贴并解析」的二级页。
///
/// 只有一张开关卡,样式与「通知管理与下载」页同一套
/// (GlassPanel + _GoogleSwitchRow,同一张顶栏图):打开后,每次进入 APP
/// 都会把剪贴板首条链接自动填进输入栏并解析(见 `_maybeAutoPasteParse`)。
class _AutoPastePage extends StatelessWidget {
  const _AutoPastePage({required this.app});

  final HomeShellState app;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final headerHeight = MediaQuery.sizeOf(context).width / _kHeaderArtAspect;
    final headerBottom = headerHeight * 564 / 605;

    return _SubPage(
      title: '自动粘贴并解析',
      headerImage: 'assets/theme-header/theme_top_2.png',
      child: _GoogleSurface(
        brightness: isDark ? Brightness.dark : Brightness.light,
        child: SafeArea(
          child: ListView(
            physics: const ShortBounceScrollPhysics(),
            padding: EdgeInsets.fromLTRB(20, headerBottom + 5, 20, 32),
            children: [
              GlassPanel(
                isDark: isDark,
                child: _GoogleSwitchRow(
                  isDark: isDark,
                  title: '进入APP自动粘贴并解析首条链接',
                  subtitle: '从其他平台复制链接后,打开即自动解析',
                  value: app._autoPasteParse,
                  onChanged: (value) => app.applySetting(
                    () => app._autoPasteParse = value,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「存储保存位置」卡。
///
/// 直接摊开,不做伸缩:只有三行,而且用户来这儿就是想知道文件去哪了,不该再点一下。
/// 路径由 Android 侧的媒体库归档决定(见 MainActivity 的 `ROOT` 与 `kindOf`),
/// 这里只做告知,不提供修改 —— 换目录得同时改 Kotlin 那套 MediaStore 映射、
/// [MediaKind] 里的展示路径和这张卡,不是切个开关的事。
///
/// 两边必须一字不差:这里写 Movies/Jicun/Video,那边就得真存到那儿,否则这页就是
/// 在骗用户(上一版就是:显示 Download/Jicun/*,实际存 Movies/JICUN、Pictures/Pictures)。
class _StorageLocationCard extends StatelessWidget {
  const _StorageLocationCard({required this.isDark});

  final bool isDark;

  static const _rows = <(String, String)>[
    ('视频 / 实况', 'Movies/Jicun/Video'),
    ('图片', 'Pictures/Jicun/Picture'),
    ('音频', 'Music/Jicun/Music'),
  ];

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: _GoogleCardTitle(isDark: isDark, text: '存储保存位置'),
          ),
          for (final (label, path) in _rows)
            _GoogleValueRow(isDark: isDark, label: label, value: path),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

/// 顶栏图的宽高比,按资源实际尺寸(1406x605,见 assets/theme-header)定。
/// 高度一律由屏宽算出来,不写死像素:页面外面套着 _UiZoom,界面缩放不是
/// 1.0 时像素高度会和其它内容对不上。
const double _kHeaderArtAspect = 1406 / 605;

/// 一个平台的卡片要显示的四样东西。
///
/// [contents] 是「支持解析的内容」,原样列出上游真能给的媒体类型 —— 别为了好看
/// 往里加:这张卡就是用户拿去对「为什么这条解析不出来」的凭据,写多了等于骗人。
/// 上游能力见 parse_service.dart 的平台枚举与各家实测注释。
///
/// [tutorial] 卡里默认收起,点一下才滑出来(见 [Reveal])。
class _PlatformCardInfo {
  const _PlatformCardInfo(
    this.name,
    this.asset,
    this.contents, {
    this.tutorial = '复制 App 内的分享链接,回到本 APP 粘贴解析即可',
  });

  final String name;

  /// assets/platform-icons/ 下的图标文件名。由 tool/fetch_platform_icons.py 从
  /// App Store 直接拉,改版了重跑那个脚本就能跟上。
  final String asset;

  final String contents;
  final String tutorial;
}

/// 支持解析的平台清单,顺序就是页面里的卡片顺序。
///
/// 图标:「微信公众号」和「微信视频号」都用微信那张 —— 视频号没有独立 App,
/// 商店里也没有单独的图标,拿别的图顶上反而认不出来(见 PLATFORMS 的注释)。
///
/// 教程只有豆包那句不一样:它分享的是对话,不是帖子,写「分享链接」会让人去找
/// 一条根本不存在的分享按钮。
const List<_PlatformCardInfo> _kPlatforms = [
  _PlatformCardInfo('今日头条', 'toutiao.png', '视频、图片、文章'),
  _PlatformCardInfo('快手', 'kuaishou.png', '视频、图片、实况、文案'),
  _PlatformCardInfo('抖音', 'douyin.png', '视频、图片、实况、文案'),
  _PlatformCardInfo('微信公众号', 'wechat.png', '视频、图片、文章'),
  _PlatformCardInfo('微信视频号', 'wechat_channels.png', '视频'),
  _PlatformCardInfo('小红书', 'xiaohongshu.png', '视频、图片、实况、文案'),
  _PlatformCardInfo('汽水音乐', 'qishui.png', '仅免费音乐'),
  _PlatformCardInfo(
    '豆包',
    'doubao.png',
    '无水印图片、无水印视频',
    tutorial: '复制对话分享链接,回到本 APP 粘贴解析即可',
  ),
  _PlatformCardInfo('哔哩哔哩', 'bilibili.png', '有水印视频'),
  _PlatformCardInfo('微博', 'weibo.png', '图文、视频、实况'),
  _PlatformCardInfo('央视频', 'yangshipin.png', '视频'),
  _PlatformCardInfo('皮皮搞笑', 'pipigaoxiao.png', '视频、图片、文案'),
  _PlatformCardInfo('皮皮虾', 'pipixia.png', '视频、图片、文案'),
  _PlatformCardInfo('最右', 'zuiyou.png', '视频、图片、实况、文案'),
  _PlatformCardInfo('红果短剧', 'hongguoduanju.png', '视频'),
  _PlatformCardInfo('红果漫剧', 'hongguomanju.png', '视频'),
  _PlatformCardInfo('好看视频', 'haokan.png', '视频'),
  _PlatformCardInfo('西瓜视频', 'xigua.png', '视频'),
];

/// 「设置 → 使用帮助及反馈」的二级页。
///
/// 第一张是反馈渠道,第二张起一个平台一张伸缩卡。
class _HelpFeedbackPage extends StatelessWidget {
  const _HelpFeedbackPage();

  /// 图里那排角色离标题太远,整张图往上抬这么多,让脑袋贴到标题下面。
  static const double _headerLift = 24;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    // 给顶栏图让出的高度,和别的二级页同一条算式。
    final headerHeight = MediaQuery.sizeOf(context).width / _kHeaderArtAspect;
    // 画面底边在画布 484/605 处(落点 y=40 + 画面高 444,实测 bbox)。图被抬高了
    // _headerLift,所以卡片位置也跟着减掉同样的值,间距仍是 5dp。
    final headerBottom = headerHeight * 484 / 605 - _headerLift;

    return _SubPage(
      title: '使用帮助及反馈',
      // 原图直接按比例缩进画布:居中、四周 52px 留白、不加白描边、整体上移
      // (--top 40)。复现命令见 tool/make_header_art.py --margin 52 --outline 0。
      headerImage: 'assets/theme-header/theme_top_4.png',
      headerLift: _headerLift,
      child: _GoogleSurface(
        brightness: isDark ? Brightness.dark : Brightness.light,
        child: SafeArea(
          child: ListView(
            physics: const ShortBounceScrollPhysics(),
            padding: EdgeInsets.fromLTRB(20, headerBottom + 5, 20, 32),
            children: [
              _FeedbackChannelsCard(isDark: isDark),
              for (final platform in _kPlatforms) ...[
                const SizedBox(height: 16),
                _PlatformCard(isDark: isDark, info: platform),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 「反馈渠道」卡。摊开不伸缩:只有两行,而且是这页最想看的东西,
/// 不该再点一下才给(同 [_StorageLocationCard] 的理由)。
class _FeedbackChannelsCard extends StatelessWidget {
  const _FeedbackChannelsCard({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 14, 8),
            child: _GoogleCardTitle(isDark: isDark, text: '反馈渠道'),
          ),
          _CopyableRow(
            isDark: isDark,
            label: 'QQ群',
            value: '1124541108',
            hint: '点击即可复制',
          ),
          _CopyableRow(
            isDark: isDark,
            label: 'QQ邮箱',
            value: '1515068599@qq.com',
            hint: '点击即可复制',
          ),
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}

/// 「标签 + 可复制值」。整行点一下就进剪贴板,右边那句说明为什么要复制。
///
/// 反馈渠道是号码/邮箱,用户没法从卡片上直接选中复制,所以整行当按钮用;
/// 点了弹一句回音 —— 复制成功在这张卡上看不出任何变化,不给回音就像没点到。
class _CopyableRow extends StatelessWidget {
  const _CopyableRow({
    required this.isDark,
    required this.label,
    required this.value,
    required this.hint,
  });

  final bool isDark;
  final String label;
  final String value;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final (foreground: foreground, secondary: secondary) = settingsPalette(
      isDark,
    );
    return PlainTap(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: value));
        if (!context.mounted) return;
        // 和「复制文案」同一个回音弹窗,全 APP 一套
        showInfo(context, '已复制', '$label:$value');
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
        child: Row(
          children: [
            Text(label, style: TextStyle(color: foreground, fontSize: 15)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                value,
                style: TextStyle(
                  color: secondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(hint, style: TextStyle(color: secondary, fontSize: 11.5)),
            const SizedBox(width: 6),
            Icon(CupertinoIcons.doc_on_doc, size: 16, color: secondary),
          ],
        ),
      ),
    );
  }
}

/// 一张平台卡:左边商店图标,右边平台名 + 支持解析的内容,点开滑出教程。
///
/// 伸缩(时长、曲线、箭头)与「主题与外观」那三张卡共用 [Reveal] / [RevealChevron],
/// 手感一致。
class _PlatformCard extends StatefulWidget {
  const _PlatformCard({required this.isDark, required this.info});

  final bool isDark;
  final _PlatformCardInfo info;

  @override
  State<_PlatformCard> createState() => _PlatformCardState();
}

class _PlatformCardState extends State<_PlatformCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final info = widget.info;
    final secondary = settingsPalette(isDark).secondary;

    return GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PlainTap(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              // 左边 18 和标题行对齐;右边 14 留给箭头自己的视觉留白
              padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
              child: Row(
                children: [
                  _PlatformIcon(asset: info.asset),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          info.name,
                          style: TextStyle(
                            color: settingsPalette(isDark).foreground,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          info.contents,
                          style: TextStyle(
                            color: secondary,
                            fontSize: 13,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  RevealChevron(expanded: _expanded, color: secondary),
                ],
              ),
            ),
          ),
          // 挂个 key 是为了测试能直接量这一块的高度:里面的 Text 被裁掉之后
          // 自己的 RenderBox 还是原尺寸,量不到「收起=0」。
          KeyedSubtree(
            key: ValueKey('platformTutorial.${info.name}'),
            child: Reveal(
              expanded: _expanded,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                child: Text(
                  '教程:${info.tutorial}',
                  style: TextStyle(
                    color: secondary,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 平台图标:商店原图是方形满幅的,套一个超椭圆外形才和卡片的转角一个路数。
///
/// 底下一层极淡的色块只是兜底:图标自己有底色,正常情况下看不见;万一某张图
/// 拉失败(errorBuilder 给空盒子),这一层就当占位,卡片不会塌下去。
class _PlatformIcon extends StatelessWidget {
  const _PlatformIcon({required this.asset});

  final String asset;

  /// 画多大。和 [_GoogleSwitchRow] 的行高同量级,不至于把卡片撑高。
  static const double _size = 40;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final shape = LiquidRoundedSuperellipse(borderRadius: _size * 0.3);
    return SizedBox(
      width: _size,
      height: _size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          color: isDark ? const Color(0x1FFFFFFF) : const Color(0x0F000000),
        ),
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: shape),
          child: Image.asset(
            'assets/platform-icons/$asset',
            fit: BoxFit.cover,
            // 图标缺失不该把整页拖垮:留个占位块,卡片其它信息照常显示
            errorBuilder: (_, _, _) => const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

/// 「关于本APP」上的开源仓库地址。
///
/// 要和 update_service.dart 里的 [kRepoOwner] / [kRepoName] 对得上 —— 那边是
/// 检查更新实际去打的仓库,这里写错就是让人去一个不存在的地方看源码。
const String _kRepoUrl = 'https://github.com/dhvbjvvb/jicun';

/// 「设置 → 关于本APP」的二级页。
///
/// 四张一行卡 + 右下角那个彩蛋。
class _AboutAppPage extends StatelessWidget {
  const _AboutAppPage();

  /// 和「使用帮助及反馈」同一套摆法:图往上抬一截,角色贴到标题下面。
  static const double _headerLift = 24;

  /// 这张顶栏图自己的宽高比。插画本体是 1672x941,比画布 [_kHeaderArtAspect]
  /// 宽得多:按画布比例画,角色会缩掉一大圈,所以照它自己的比例来。
  static const double _headerAspect = 1672 / 941;

  /// 彩蛋素材。静图就是动图的第 0 帧 —— 两者同尺寸,切换时像素重合,看不出接缝
  /// (见 widgets/tap_easter_egg.dart 的类文档)。
  static const String _eggStill = 'assets/easter-egg/laugh_still.webp';
  static const String _eggAnimated = 'assets/easter-egg/laugh.webp';

  /// 彩蛋音效。原素材 18.7s,裁到 3.17s —— 和动图一轮等长,图和声一起收。
  /// 2.92s 起 250ms 淡出:那一段本来就是笑收尾的气口(约 -14~-19 dB),淡掉听不出来。
  /// 单声道 96kbps,39 KB。
  static const String _eggSound = 'assets/easter-egg/laugh.mp3';

  /// 彩蛋显示宽度。素材是 300x486 的竖构图,150 宽在手机上约合屏宽的四成。
  static const double _eggWidth = 150;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    // 给顶栏图让出的高度,按这张图自己的比例算,和 _SubPage 里画的是同一个数。
    final headerHeight = MediaQuery.sizeOf(context).width / _headerAspect;
    // 画面底边在画布 537/605 处(落点 y=68 + 画面高 469),再减掉抬高量。
    final headerBottom = headerHeight * 537 / 605 - _headerLift;

    return _SubPage(
      title: '关于本APP',
      // 原图直接按比例缩进画布:居中、四周 6px 留白、不加白描边。复现命令见
      // tool/make_header_art.py --margin 6 --outline 0。
      headerImage: 'assets/theme-header/theme_top_5.png',
      headerAspect: _headerAspect,
      headerLift: _headerLift,
      child: _GoogleSurface(
        brightness: isDark ? Brightness.dark : Brightness.light,
        child: SafeArea(
          child: Stack(
            children: [
              ListView(
                physics: const ShortBounceScrollPhysics(),
                padding: EdgeInsets.fromLTRB(20, headerBottom + 5, 20, 32),
                children: [
                  _AboutInfoCard(
                    title: '开源地址',
                    value: _kRepoUrl,
                    // 点了就复制,不提示怎么点 —— URL 在卡片上选不中,只能这么给
                    onTap: () async {
                      await Clipboard.setData(
                        const ClipboardData(text: _kRepoUrl),
                      );
                      if (!context.mounted) return;
                      showInfo(context, '已复制', '开源地址已复制到剪贴板。');
                    },
                  ),
                  const SizedBox(height: 12),
                  const _AboutInfoCard(title: '制作人', value: '春日大阪'),
                  const SizedBox(height: 12),
                  const _AboutInfoCard(
                    title: '彩蛋出席',
                    value: '奶龙,不知名小人物,不知名大人物',
                  ),
                  const SizedBox(height: 12),
                  const _AboutInfoCard(
                    title: '后续维护',
                    value: '原则上,来讲是永久免费(看后续精力)',
                  ),
                ],
              ),
              // 彩蛋钉在内容区右下角,浮在卡片之上。**不能**挪进 ListView 当最后
              // 一项:它本来是贴在屏幕右下角的,跟着列表滚就跑到内容末尾去了。
              Positioned(
                right: 0,
                bottom: 0,
                child: TapEasterEgg(
                  still: _eggStill,
                  animated: _eggAnimated,
                  sound: _eggSound,
                  width: _eggWidth,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 关于页的一张卡:只有一行「标题:内容」,和文案长得一样。
///
/// 刻意做成一行:这四张卡就是四句话,不是四块版面。分两行摆(标题一行、值一行)
/// 会把卡片撑到两倍高,四张摞起来像四个板块。
///
/// [onTap] 非空时整行可点(开源地址那张用它复制)。**不给"点击即可复制"这类提示**:
/// 是用户点名的。点了有回音就够了。
class _AboutInfoCard extends StatelessWidget {
  const _AboutInfoCard({required this.title, required this.value, this.onTap});

  final String title;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final (foreground: foreground, secondary: secondary) = settingsPalette(
      isDark,
    );
    // RichText 而不是 Text.rich:标题和内容一个色号、只差字重,拆成两段 Span
    // 排版上就是一行,长内容自然换行时也不用管缩进对不对齐。
    final line = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$title:',
            style: TextStyle(fontWeight: FontWeight.w600, color: foreground),
          ),
          TextSpan(
            text: value,
            style: TextStyle(color: secondary),
          ),
        ],
      ),
      style: const TextStyle(fontSize: 14.5, height: 1.35),
    );

    return GlassPanel(
      isDark: isDark,
      child: onTap == null
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: line,
            )
          : PlainTap(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 16,
                ),
                child: line,
              ),
            ),
    );
  }
}

/// 「设置 → 彩蛋提示」的二级页。
///
/// 只摆一张卡,摊开不伸缩 —— 这页本来就是来看这一句话的,再点一下才给没有意义
/// (同 [_FeedbackChannelsCard] 的理由)。
class _EasterEggHintPage extends StatelessWidget {
  const _EasterEggHintPage();

  /// 底部两个角色的底衬高度,占屏宽的比例。
  ///
  /// 素材出库时已经裁到角色本体(见 tool/make_egg_hint_art.py),一左一右各占
  /// 半个屏宽,所以真正卡住角色大小的是这个高度而不是宽度:给到 0.9 / 2 的
  /// 宽高比时两个角色才铺满各自那一半。素材本身就是 720x812 / 720x943,高度
  /// 是宽度的 1.13 / 1.31 倍,这里按 1.13 算 —— 取更宽的那个反而会把两个角色
  /// 挤到一起。
  static const double _artAspect = 0.9 / 2 / 1.13;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    // 底衬按屏宽算,和图片里角色的大小同一个比例,换机型不会一边大一边小。
    final artHeight = MediaQuery.sizeOf(context).width * _artAspect;

    return _SubPage(
      title: '彩蛋提示',
      child: _GoogleSurface(
        brightness: isDark ? Brightness.dark : Brightness.light,
        child: SafeArea(
          child: Stack(
            children: [
              ListView(
                physics: const ShortBounceScrollPhysics(),
                // 底部留出底衬的高度 + 32:滚动到底时卡片不会被角色盖住。
                padding: EdgeInsets.fromLTRB(20, 18, 20, artHeight + 32),
                children: [_EggHintCard(isDark: isDark)],
              ),
              // 两个角色钉在内容区底部,浮在卡片之上。**不能**挪进 ListView 当最后
              // 一项:它们要的是贴着屏幕右下角不动,跟着列表滚就跑到内容末尾去了
              // (同 [_AboutAppPage] 的彩蛋)。
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: SizedBox(
                    height: artHeight,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: const [
                        Expanded(
                          child: Image(
                            image: AssetImage(
                              'assets/easter-egg-hint/left.png',
                            ),
                            fit: BoxFit.contain,
                            alignment: Alignment.bottomLeft,
                          ),
                        ),
                        Expanded(
                          child: Image(
                            image: AssetImage(
                              'assets/easter-egg-hint/right.png',
                            ),
                            fit: BoxFit.contain,
                            alignment: Alignment.bottomRight,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 彩蛋提示页唯一那张卡:标题一行,内容一行。摊开不伸缩。
class _EggHintCard extends StatelessWidget {
  const _EggHintCard({required this.isDark});

  final bool isDark;

  static const String _hint = '也许在某个设置中的2级界面,快速连续3次点击人物,它会发出声音🤯';

  @override
  Widget build(BuildContext context) {
    final (foreground: _, secondary: secondary) = settingsPalette(isDark);
    return GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 14, 8),
            child: _GoogleCardTitle(isDark: isDark, text: '提示'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
            child: Text(
              _hint,
              style: TextStyle(
                color: secondary,
                fontSize: 14.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 二级页统一外壳。
///
/// 关键:背景必须由**全屏**的 ThemeBackground 来画。直接用
/// CupertinoPageScaffold(child: ThemeBackground(...)) 时,child 从导航栏下方
/// 才开始布局,于是顶部露出 scaffold 的纯色 #CDDCDC,而且 ThemeBackground 里
/// 的渐变是按更小的矩形重算的 —— 同一屏幕位置的颜色就和主页面对不上。
/// 这里改成:背景铺满全屏 + scaffold 与导航栏透明,和主页面完全一致。
class _SubPage extends StatelessWidget {
  const _SubPage({
    required this.title,
    required this.child,
    this.headerImage,
    this.headerAspect = _kHeaderArtAspect,
    this.headerLift = 0,
  });

  final String title;
  final Widget child;

  /// 顶部整宽图。null 表示这页不放图。
  ///
  /// 它只负责画,不占位:传了图的页面要自己把内容往下让出
  /// `屏宽 / headerAspect` 的高度,否则图会盖住第一张卡片。
  final String? headerImage;

  /// 顶栏图的宽高比。默认是画布比例 [_kHeaderArtAspect];源图比例和画布差得多的
  /// 那张(见 [_AboutAppPage])要传自己的,否则图会被拉伸或缩得比预期小一圈。
  final double headerAspect;

  /// 顶栏图整体上移多少(逻辑像素)。
  ///
  /// 图默认从内容区顶端(返回栏下方)开始画。有些图角色偏小、离标题太远,就抬上来
  /// 一截,靠 Clip.none 画到返回栏那一行去,标题压在图上。调用方记得把列表顶边距
  /// 也减去同样的值。
  final double headerLift;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final foreground = isDark
        ? const Color(0xFFF5F7FA)
        : const Color(0xFF1B2430);
    // 二级页也吃「界面缩放大小」:底栏不缩放,所以缩放只能落在页面内容这一层,
    // 这里和主页 body 一样包一层。
    return _UiZoom(
      scale: _UiScale.of(context),
      child: Stack(
        children: [
          Positioned.fill(
            // RepaintBoundary:背景是静态的(只依赖 isDark),缓存成一层纹理后
            // 转场时只需重新合成,不必每帧重跑全屏 BlendMode.overlay/screen。
            child: RepaintBoundary(
              child: ThemeBackground(
                isDark: isDark,
                tag: 'subpage',
                child: const SizedBox.expand(),
              ),
            ),
          ),
          Column(
            children: [
              // 不用 CupertinoNavigationBar:它的底色非全不透明时会挂一层整宽
              // BackdropFilter(blur 10),转场时每帧都要重跑。这里只需要一个返回
              // 按钮和标题,手写一行更省,视觉一致。
              SafeArea(
                bottom: false,
                child: SizedBox(
                  height: 44,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: CupertinoButton(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          minimumSize: Size.zero,
                          onPressed: () => Navigator.of(context).maybePop(),
                          child: const Icon(CupertinoIcons.back, size: 26),
                        ),
                      ),
                      Text(
                        title,
                        style: TextStyle(
                          color: foreground,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 顶部内边距已由上面的 SafeArea 处理,这里必须把它从子树的 MediaQuery
              // 里去掉 —— 否则页面自身的 SafeArea 会再加一次状态栏高度(两者是兄弟
              // 节点,不是父子),内容会被顶下去一个状态栏的高度。
              Expanded(
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  child: headerImage == null
                      ? child
                      : Stack(
                          // headerLift > 0 时图要画到这一层外面(返回栏那一行),
                          // 所以不能裁。列表自己会裁自己的滚动内容,不受影响。
                          clipBehavior: headerLift > 0
                              ? Clip.none
                              : Clip.hardEdge,
                          children: [
                            child,
                            // 图铺在内容之上,而不是和内容上下分家:向上滚的卡片是
                            // 从图的淡出区里化掉的,不会被一条直边切断。调用方因此
                            // 要在自己的列表顶部留出图的高度(见 _ThemeAppearancePage),
                            // 图只负责画,不占位。
                            Positioned(
                              top: -headerLift,
                              left: 0,
                              right: 0,
                              child: IgnorePointer(
                                child: AspectRatio(
                                  aspectRatio: headerAspect,
                                  child: Image.asset(
                                    headerImage!,
                                    fit: BoxFit.fitWidth,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 系统主题的三个选项
enum AppThemeMode { system, light, dark }

/// 「系统主题」卡:收起时只有一行(标题 + 当前值 + 向下箭头),点箭头向下滑出
/// 三个选项;选完自己回弹收起。
///
/// 展开态是纯界面状态,所以留在本组件里 —— 每次进二级页都从收起开始。
class _ThemeModeCard extends StatefulWidget {
  const _ThemeModeCard({required this.app, required this.isDark});

  final HomeShellState app;
  final bool isDark;

  @override
  State<_ThemeModeCard> createState() => _ThemeModeCardState();
}

class _ThemeModeCardState extends State<_ThemeModeCard> {
  static const List<(AppThemeMode, String)> _options = [
    (AppThemeMode.system, '跟随系统'),
    (AppThemeMode.light, '浅色'),
    (AppThemeMode.dark, '深色'),
  ];

  bool _expanded = false;

  String get _currentLabel =>
      _options.firstWhere((o) => o.$1 == widget.app._themeMode).$2;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final secondary = settingsPalette(isDark).secondary;

    return GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PlainTap(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 22, 14, 22),
              child: Row(
                children: [
                  _GoogleCardTitle(isDark: isDark, text: '系统主题'),
                  const Spacer(),
                  Text(
                    _currentLabel,
                    style: TextStyle(
                      color: secondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  RevealChevron(expanded: _expanded, color: secondary),
                ],
              ),
            ),
          ),
          Reveal(
            expanded: _expanded,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: RadioGroup<AppThemeMode>(
                groupValue: widget.app._themeMode,
                onChanged: (mode) {
                  if (mode == null) return;
                  widget.app.applySetting(() => widget.app._themeMode = mode);
                  widget.app.syncNightModeToNative(mode);
                  // 选完缩回去,回到收起卡片
                  setState(() => _expanded = false);
                },
                child: Column(
                  children: [
                    for (final (mode, label) in _options)
                      _GoogleChoiceRow<AppThemeMode>(
                        isDark: isDark,
                        value: mode,
                        label: label,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 二级页统一走的路由。
///
/// 比 CupertinoPageRoute 少两样东西:
/// 1. **压在下面那页的 9% 黑罩**。CupertinoRouteTransitionMixin 的 barrierColor 是
///    0x18000000,由 AnimatedModalBarrier 跟着转场动画淡入淡出(routes.dart 的
///    _buildModalBarrier 用 ColorTween 从全透明到 barrierColor)。结果就是返回时
///    设置主界面先从暗处浮上来 —— 明明是同一层页面,却像亮度没对齐。
/// 2. **把 500ms 收到 320ms**。iOS 那套 500ms 在这台机器上返回时总觉得慢半拍。
class _SubPageRoute<T> extends CupertinoPageRoute<T> {
  _SubPageRoute({required super.builder});

  @override
  Color? get barrierColor => null;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 320);
}

/// 「设置 → 主题与外观」的二级页
class _ThemeAppearancePage extends StatelessWidget {
  const _ThemeAppearancePage({required this.app});

  final HomeShellState app;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    // 给顶栏图让出的高度。图是按屏宽等比缩的,所以这里也按屏宽算,
    // 两边同一个 _kHeaderArtAspect,界面缩放下不会错位。
    final headerHeight = MediaQuery.sizeOf(context).width / _kHeaderArtAspect;
    // 这张画面基本铺满画布,底边实测在 599/605 处。第一张卡从图底边往下 5dp 起。
    final headerBottom = headerHeight * 599 / 605;

    return _SubPage(
      title: '主题与外观',
      // 一张图两种模式共用:不补轮廓光,所以深浅模式不需要两版。
      headerImage: 'assets/theme-header/theme_top.png',
      child: _GoogleSurface(
        brightness: isDark ? Brightness.dark : Brightness.light,
        child: SafeArea(
          child: ListView(
            physics: const ShortBounceScrollPhysics(),
            padding: EdgeInsets.fromLTRB(20, headerBottom + 5, 20, 32),
            children: [
              _ThemeModeCard(app: app, isDark: isDark),
              const SizedBox(height: 16),
              _BarAppearanceCard(app: app, isDark: isDark),
              const SizedBox(height: 16),
              _UiScaleCard(app: app, isDark: isDark),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「底栏外观样式」卡:两个开关都只作用于底栏,所以合成一张。
///
/// 展开/收起与「系统主题」卡同一套(收起时只留一行标题 + 当前样式 + 箭头,
/// 点开向下滑出,见 [Reveal])。
class _BarAppearanceCard extends StatefulWidget {
  const _BarAppearanceCard({required this.app, required this.isDark});

  final HomeShellState app;
  final bool isDark;

  @override
  State<_BarAppearanceCard> createState() => _BarAppearanceCardState();
}

class _BarAppearanceCardState extends State<_BarAppearanceCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final app = widget.app;
    final secondary = settingsPalette(isDark).secondary;

    return GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PlainTap(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 22, 14, 22),
              child: Row(
                children: [
                  _GoogleCardTitle(isDark: isDark, text: '底栏外观样式'),
                  const Spacer(),
                  Text(
                    // 收起时这一行就是这张卡的「当前值」:和系统主题卡同一位置
                    app._glassBottomBar ? '液态玻璃' : '渐变按钮',
                    style: TextStyle(
                      color: secondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  RevealChevron(expanded: _expanded, color: secondary),
                ],
              ),
            ),
          ),
          Reveal(
            expanded: _expanded,
            child: Column(
              children: [
                _GoogleSwitchRow(
                  isDark: isDark,
                  title: '底栏文字标识隐藏',
                  subtitle: '开启后隐藏底栏的解析、历史、设置文字',
                  value: app._hideTabLabels,
                  onChanged: (v) =>
                      app.applySetting(() => app._hideTabLabels = v),
                ),
                _GoogleSwitchRow(
                  isDark: isDark,
                  title: 'Apple 底栏液态玻璃风格',
                  subtitle: '关闭后底栏取消液态玻璃,改用渐变按钮样式',
                  value: app._glassBottomBar,
                  onChanged: (v) =>
                      app.applySetting(() => app._glassBottomBar = v),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 「界面缩放大小」卡。
///
/// 收起/展开与系统主题、底栏外观样式同一套;拖动中的值只存在这张卡自己的 State 里:
/// 每帧只重建这一小块,不惊动整棵树,所以滑杆跟手。松手(onChangeEnd)才把值交给
/// 根 State 去真正缩放并落盘 —— 缩放会让整屏按新尺寸重新布局,每帧都做必然拖不动。
class _UiScaleCard extends StatefulWidget {
  const _UiScaleCard({required this.app, required this.isDark});

  static const double min = 0.8;
  static const double max = 1.3;

  final HomeShellState app;
  final bool isDark;

  @override
  State<_UiScaleCard> createState() => _UiScaleCardState();
}

class _UiScaleCardState extends State<_UiScaleCard> {
  late double _draft = widget.app._uiScale;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final secondary = settingsPalette(isDark).secondary;
    return GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PlainTap(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 22, 14, 22),
              child: Row(
                children: [
                  _GoogleCardTitle(isDark: isDark, text: '界面缩放大小'),
                  const Spacer(),
                  Text(
                    '${(_draft * 100).round()}%',
                    style: TextStyle(
                      color: secondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  RevealChevron(expanded: _expanded, color: secondary),
                ],
              ),
            ),
          ),
          Reveal(
            expanded: _expanded,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SliderTheme(
                    // 拖动时不画把手的灰色光晕:压在玻璃卡上就是一团阴影
                    data: SliderTheme.of(context)
                        .copyWith(overlayShape: SliderComponentShape.noOverlay),
                    child: Slider(
                      value: _draft,
                      min: _UiScaleCard.min,
                      max: _UiScaleCard.max,
                      // 不设 divisions:刻度会让把手一格一格跳,手感发涩、不跟手
                      label: '${(_draft * 100).round()}%',
                      onChanged: (v) => setState(() => _draft = v),
                      onChangeEnd: (v) => widget.app.applySetting(
                        () => widget.app._uiScale = v,
                      ),
                    ),
                  ),
                  Text(
                    '拖动调整,松手应用',
                    style: TextStyle(color: secondary, fontSize: 12.5),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 把「键盘内缩」(viewInsets.bottom)从子树上摘掉。
///
/// 页面本身不为键盘让位(见 GlassScaffold 的 resizeToAvoidBottomInset 注释),
/// 也不需要知道键盘多高。但 MediaQuery 里的 viewInsets 一变,依赖它的子树就会
/// 全部重建 —— 键盘弹出动画期间那是每帧一次,点输入框的卡顿就来自这里。
/// 摘掉之后键盘只影响底栏那一层,页面不动。
///
/// 注意只摘 bottom:顶部安全区(padding)照旧,输入框在页面顶部也不会被键盘
/// 盖住,所以不需要 EditableText 那套「自动滚到可见区」的逻辑。
class _NoKeyboardInset extends StatelessWidget {
  const _NoKeyboardInset({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => MediaQuery.removeViewInsets(
    context: context,
    removeBottom: true,
    child: child,
  );
}

/// 把当前缩放值发到整棵树。
///
/// 缩放不能包在路由外面(会把底栏的 BackdropFilter 一起卷进来,见 CupertinoApp
/// 的 builder 注释),所以改成「谁需要谁自己取」:主页 body 与二级页各自包一层
/// _UiZoom。
class _UiScale extends InheritedWidget {
  const _UiScale({required this.scale, required super.child});

  final double scale;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_UiScale>()?.scale ?? 1;

  @override
  bool updateShouldNotify(_UiScale oldWidget) => oldWidget.scale != scale;
}

/// 「界面缩放大小」的执行者:把页面内容(主页 body、二级页)按 scale 等比放大缩小。
///
/// 底栏不在这里 —— 它内部有 BackdropFilter,绘制期 Transform 会让它采样错位
/// (见 CupertinoApp 的 builder 注释),所以底栏分成独立绘制层、永远按 100% 画。
///
/// 做法:让子树按「虚拟尺寸 = 真实尺寸 / scale」重新布局,再把画出来的东西整体
/// 乘 scale。等于临时把这块屏幕当成更大/更小的手机,所以安全区、留白、字号一起
/// 等比变化,两个方向都不会留空边,也不会被裁掉。
/// 拖动滑杆时 scale 不变,这里就不会每帧重排整屏。
class _UiZoom extends StatelessWidget {
  const _UiZoom({required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (scale == 1) return child;
    final mq = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final real = constraints.biggest;
        final virtual = Size(real.width / scale, real.height / scale);
        // RepaintBoundary + ClipRect:
        // 缩放是靠绘制期 Transform 做的,子树的「布局尺寸」是虚拟画布、真正画出来
        // 的却是整屏。切主题时 Flutter 只按布局尺寸去重画脏区,右侧/底部那条多出来
        // 的窄条不会被刷新 —— 上一套主题的像素留在这里,看着就是底栏错位/重影。
        // 包一层 RepaintBoundary 之后任何一处脏都会整层重画,脏区按真实屏幕裁剪。
        return RepaintBoundary(
          child: ClipRect(
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              // 虚拟画布比真实屏幕大(缩小时),得让父级放行超出的部分
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: 0,
                maxWidth: double.infinity,
                minHeight: 0,
                maxHeight: double.infinity,
                child: SizedBox(
                  width: virtual.width,
                  height: virtual.height,
                  child: MediaQuery(
                    // 安全区也要跟着虚拟尺寸走,否则状态栏留白会和内容对不上
                    data: mq.copyWith(
                      size: virtual,
                      padding: mq.padding / scale,
                      viewPadding: mq.viewPadding / scale,
                      viewInsets: mq.viewInsets / scale,
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 二级设置页的 Material 3 环境。
///
/// 卡片本身与一级设置列表同一种毛玻璃(见 GlassPanel),这里只负责控件配色:
/// 一份 Material 3 的 ColorScheme(用品牌蓝做种子,所以强调色仍是即存的蓝,
/// 而不是 Google 默认的紫)。下面所有开关与单选都从它取色。
class _GoogleSurface extends StatelessWidget {
  const _GoogleSurface({required this.brightness, required this.child});

  final Brightness brightness;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1677FF),
          brightness: brightness,
        ),
      ),
      // Material 祖先:Switch / Radio / FilledButton 的涟漪与状态层挂在这里。
      // transparency 保证它不画自己的底色,渐变背景照旧透出来。
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}

/// 一级设置列表与二级设置页共用的毛玻璃面板:超椭圆转角 + 半透明底。
///
/// 刻意**不挂** BackdropFilter:背景是平滑渐变,模糊它得到的像素几乎不变,每帧却
/// 要为每张卡片各跑一次全宽模糊(转场掉帧的主因)。
///
/// 也刻意**不画投影**:列表里卡片间距只有 12,而投影(blur 18 / 下移 8)会越过
/// 间隙盖到下一张卡上,深色模式下就是一整条发黑的带子把两张卡连在一起,卡片越多
/// 越明显。卡片与背景的层次改由半透明底自己承担。
class GlassPanel extends StatelessWidget {
  const GlassPanel({super.key, required this.isDark, required this.child});

  final bool isDark;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 超椭圆转角,与库其它玻璃面一致(用正圆弧会和它们对不上)
    final shape = const LiquidRoundedSuperellipse(borderRadius: 20);
    return DecoratedBox(
      decoration: ShapeDecoration(shape: shape),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: shape,
            color: isDark ? const Color(0x26FFFFFF) : const Color(0x8CFFFFFF),
          ),
          // 卡片自己再当一次 Material 宿主,涟漪才画在半透明底之上而不是被它压暗
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

class _GoogleCardTitle extends StatelessWidget {
  const _GoogleCardTitle({required this.isDark, required this.text});

  final bool isDark;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: settingsPalette(isDark).foreground,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// 一行「标签 + 值」。用在只读信息上(比如保存位置):左边说明,右边是路径。
///
/// 值用等宽字体:路径里全是斜杠和大小写,等宽比比例字体好认。
class _GoogleValueRow extends StatelessWidget {
  const _GoogleValueRow({
    required this.isDark,
    required this.label,
    required this.value,
  });

  final bool isDark;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final (foreground: foreground, secondary: secondary) = settingsPalette(
      isDark,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 7, 16, 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: foreground, fontSize: 15)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: secondary,
                fontSize: 13,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 卡片里的点击区:不要涟漪、不要按下高亮。
///
/// Flutter 默认按下时给整行铺一层灰(highlight + splash),在玻璃卡上就是一块
/// 边界清楚的灰矩形,看着像把卡片切成了两半 —— 所以这里全部关掉。
/// 点了仍然有反应,只是反应交给控件本身(开关滑动、单选变蓝、卡片展开)。
class PlainTap extends StatelessWidget {
  const PlainTap({super.key, required this.onTap, required this.child});

  final VoidCallback? onTap;
  final Widget child;

  static const Color _none = Color(0x00000000);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      splashFactory: NoSplash.splashFactory,
      highlightColor: _none,
      hoverColor: _none,
      focusColor: _none,
      child: child,
    );
  }
}

/// 控件自带的状态层(Switch / Radio 按下时那圈灰)也一并关掉
const WidgetStateProperty<Color?> _noOverlay = WidgetStatePropertyAll<Color?>(
  Color(0x00000000),
);

/// 一行「标题 + 说明 + Material 3 开关」。
class _GoogleSwitchRow extends StatelessWidget {
  const _GoogleSwitchRow({
    required this.isDark,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final bool isDark;
  final String title;
  final String subtitle;
  final bool value;

  /// null = 这个开关当前不生效,置灰(和 [Switch] 一样:传 null 就是禁用)。
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (foreground: foreground, secondary: secondary) = settingsPalette(
      isDark,
    );
    return Padding(
      // 右边留 8:开关自己带 8 的触控留白,视觉间距才是 16
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: secondary,
                    fontSize: 13,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: value,
            onChanged: onChanged,
            overlayColor: _noOverlay,
            // M3 规范里关闭态是「底色 + 2dp 描边」,Flutter 默认只画底色。
            // 补上描边才是 Google 设置页里那个开关的样子;开启态不描边。
            trackOutlineColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? const Color(0x00000000)
                  : scheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

/// 一行「Material 3 单选 + 文字」。整行可点,选中值由上层 RadioGroup 管。
class _GoogleChoiceRow<T> extends StatelessWidget {
  const _GoogleChoiceRow({
    required this.isDark,
    required this.value,
    required this.label,
  });

  final bool isDark;
  final T value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final onChanged = RadioGroup.maybeOf<T>(context)?.onChanged;
    return PlainTap(
      onTap: onChanged == null ? null : () => onChanged(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Radio<T>(value: value, overlayColor: _noOverlay),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: settingsPalette(isDark).foreground,
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
