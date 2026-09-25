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
        OutlinedButton,
        Radio,
        RadioGroup,
        Scrollbar,
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
import 'dart:math' as math;
// 进度环的渐变要 ui.Gradient.linear:widgets 里的 Gradient 是另一套东西
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:just_audio/just_audio.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

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
import 'ui/playback.dart';

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
  State<LiquidGlassDemo> createState() => _LiquidGlassDemoState();
}

/// 横滑切板块:横向拖够这么多逻辑像素就算一次。
const double _kTabSwipeDistance = 80;

/// 横滑切板块:够快的一挥也算,不看拖了多远(px/s)。
const double _kTabSwipeVelocity = 400;

class _LiquidGlassDemoState extends State<LiquidGlassDemo>
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
  late _ThemeMode _themeMode;
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
  // 刻意放在根 State 上,而不是 _ParsePage 自己的 State 里:切 tab 会把整棵子树
  // 连同它的 State 一起重建,状态放在页面里的话,解析结果和输入框内容一换 tab
  // 就没了。输入框控制器同理 —— 它的内容也得活着。
  final ParseService _parseService = ParseService();
  final HistoryStore _history = HistoryStore();
  final TextEditingController _linkController = TextEditingController();

  /// 历史记录。同样放在根 State 上:历史页切走就会被重建,数据留在这儿才不会
  /// 每次进来都重新读一遍存储。
  ///
  /// null = 还没读到(测试里没预传、异步读还没回来)。
  List<HistoryEntry>? _historyEntries;

  ParseResult? _parseResult;

  /// 正在请求。按钮跟着置灰,避免连点打出多次解析。
  bool _parsing = false;

  /// 上一次失败的提示文案。成功一次就清掉。
  String? _parseError;

  /// 解析成功后把按钮锁成「完成解析」。点一下输入框、或清空内容才解锁。
  bool _parseLocked = false;

  /// 输入框上次是不是空的。用来判断「变空/变非空」这一下要不要重画
  /// (见 [_onLinkChanged]:不能每个字符都 setState)。
  bool _linkWasEmpty = true;

  /// 输入框内容变了:只留有效的链接,并处理清空后的解锁。
  void _onLinkChanged() {
    final raw = _linkController.text;
    final url = extractShareUrl(raw);

    // 粘进来的是整段分享文本(「7.62 复制打开抖音…https://… 复制此链接」),
    // 这里只留链接本身。改写后 listener 会再跑一次,那次 raw 已经是干净的 URL,
    // 不再匹配 —— 不会死循环。
    if (url != null && url != raw.trim()) {
      _linkController.value = TextEditingValue(
        text: url,
        selection: TextSelection.collapsed(offset: url.length),
      );
      return;
    }

    // 这里**不能**每个字符都 setState。整棵页面树(玻璃面板的 BackdropFilter、
    // 几张预览卡、SVG 图标)会跟着重建,手动输入时每个字符都卡一下。
    // 只有按钮的可用状态真的会变时才需要重画:空 ↔ 非空、以及清空后的解锁。
    final bool empty = raw.trim().isEmpty;
    if (empty == _linkWasEmpty && !(empty && _parseLocked)) return;
    setState(() {
      // 点了输入框右侧的叉清空内容 → 按钮从「完成解析」变回「开始解析」
      if (empty) _parseLocked = false;
    });
    _linkWasEmpty = empty;
  }

  /// 用户点了输入框。按需求,这时「完成解析」要放回「开始解析」。
  void _unlockParse() {
    if (!_parseLocked) return;
    setState(() => _parseLocked = false);
  }

  Future<void> _startParse(String link) async {
    final url = extractShareUrl(link) ?? link.trim();
    if (url.isEmpty) return;

    setState(() {
      _parsing = true;
      _parseError = null;
      _parseLocked = false;
    });

    try {
      final result = await _parseService.parse(url);
      if (!mounted) return;
      _linkController.text = url;
      setState(() {
        _parseResult = result;
        _parsing = false;
        _parseLocked = true;
      });
      // 只有解析成功才记历史 —— 失败不记,否则历史里全是没用的失败条目。
      // 存储出问题(写满、插件异常)不该影响这次展示,所以吞掉。
      try {
        final entries = await _history.add(result, url);
        if (mounted) setState(() => _historyEntries = entries);
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
      // 失败时**不**清空 _parseResult:换一条链接没解析出来,把上一份结果擦掉
      // 会让人以为越用越少。旧结果留着,只在上面加一条错误提示。
      setState(() {
        _parseError = e.message;
        _parsing = false;
      });
    }
  }

  /// 历史卡被单击:带着那条记录的链接回解析页重新解析。
  Future<void> _reparseFromHistory(HistoryEntry entry) async {
    if (entry.sourceUrl.isEmpty) return;
    _linkController.text = entry.sourceUrl;
    _selectTab(0);
    await _startParse(entry.sourceUrl);
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
  Future<String?> _readClipboard() async {
    final wait = Completer<String?>();
    _clipboardDeadline?.cancel();
    final timer = Timer(const Duration(milliseconds: 700), _finishClipboardRead);
    _clipboardDeadline = timer;
    _clipboardWait = wait;
    try {
      return await Future.any([_readClipboardInner(), wait.future]);
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
    if (!_autoPasteParse || _parsing) return;
    final text = await _readClipboard();
    if (!mounted) return;
    final url = text == null ? null : extractShareUrl(text);
    if (url == null || url.isEmpty) return;
    if (url == _lastAutoPasted) return;
    _lastAutoPasted = url;
    // 已经是这条且解析完了:不用再打一次。
    if (_linkController.text.trim() == url && _parseLocked) return;
    _unlockParse();
    _selectTab(0);
    _linkController.text = url;
    await _startParse(url);
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
  Future<void> _deleteHistory(Set<String> ids) async {
    final entries = await _history.remove(ids);
    if (!mounted) return;
    setState(() => _historyEntries = entries);
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
  void syncNightModeToNative(_ThemeMode mode) {
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
        _ThemeMode.values.asNameMap()[prefs?.getString(kPrefsThemeMode)] ??
        _ThemeMode.system;
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
    _linkController.addListener(_onLinkChanged);
    // 冷启动就先把到反代的连接建起来:用户很可能几秒内就粘链接解析。
    _parseService.warmUp();

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
      _historyEntries = preloaded;
      _warmHistoryCovers(preloaded);
    } else {
      _history.load().then((entries) {
        if (!mounted) return;
        setState(() => _historyEntries = entries);
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
    _linkController.dispose();
    _parseService.dispose();
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
          _showInfo(popup, '检查更新', '仓库里还没有发布任何版本。');
        }
        return;
      }
      if (!isNewerVersion(release.version, _localVersion)) {
        if (manual && popup != null && popup.mounted) {
          _showInfo(popup, '检查更新', '当前已是最新版本($_localVersion)。');
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
        _showInfo(popup, '检查更新失败', error.message);
      }
    } catch (error) {
      final popup = _popupContext;
      if (manual && popup != null && popup.mounted) {
        _showInfo(popup, '检查更新失败', '$error');
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

    final enabled = await _notificationsEnabled();
    if (!mounted) return;
    if (enabled == false) await _requestNotificationPermission();
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
        _showInfo(popup, '安装没能开始', '$error');
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
      _showInfo(popup, '还差一步', '请在系统设置里允许「即存」安装应用,回来就会自动安装。');
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
      _ThemeMode.system => _brightness,
      _ThemeMode.light => Brightness.light,
      _ThemeMode.dark => Brightness.dark,
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
          // 弹层外面那层全屏模糊(见 [_PopupShell])第一次用要现编译着色器,实测
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
                child: _ThemeBackground(
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
      _ParsePage(app: this),
      _HistoryPage(app: this),
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
        ? _settingsPalette(isDark).foreground
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

class _ThemeBackground extends StatelessWidget {
  const _ThemeBackground({
    required this.isDark,
    required this.child,
    this.tag = '?',
  });

  final bool isDark;
  final Widget child;
  final String tag;

  @override
  Widget build(BuildContext context) {
    if (isDark) {
      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF000000), Color(0xFF434343)],
          ),
        ),
        child: child,
      );
    }

    return CustomPaint(
      painter: const _LightThemeBackgroundPainter(),
      child: child,
    );
  }
}

class _LightThemeBackgroundPainter extends CustomPainter {
  const _LightThemeBackgroundPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = const Color(0xFFCDDCDC));

    final linearShader = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0x40FFFFFF), Color(0x40000000)],
    ).createShader(rect);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = linearShader
        ..blendMode = BlendMode.overlay,
    );

    final center = Offset(size.width * 0.5, size.height);
    final radius = math.sqrt(
      size.width * size.width * 0.25 + size.height * size.height,
    );
    final radialShader = RadialGradient(
      center: Alignment(
        (center.dx / size.width) * 2 - 1,
        (center.dy / size.height) * 2 - 1,
      ),
      radius: radius / size.height,
      colors: const [Color(0x80FFFFFF), Color(0x80000000)],
    ).createShader(rect);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = radialShader
        ..blendMode = BlendMode.screen,
    );
  }

  @override
  bool shouldRepaint(covariant _LightThemeBackgroundPainter oldDelegate) =>
      false;
}

/// 比 Cupertino 默认更「收」的越界回弹。
///
/// 越界拖动走多远由 `frictionFactor` 决定(正常档起始 0.52):值越小,同样的手指
/// 位移越走不动。这里砍掉一半 —— 松手后那点回弹还在,但不会再甩出去一大截,
/// 手指也不用拖很远才回到边界。
class _ShortBounceScrollPhysics extends BouncingScrollPhysics {
  const _ShortBounceScrollPhysics({super.parent});

  /// 必须重写。Scrollable 会把这里的 physics 和全局滚动物理合并
  /// (`physicsFromWidget.applyTo(configuration)`),而
  /// `BouncingScrollPhysics.applyTo` 返回的是一个**新的 BouncingScrollPhysics** ——
  /// 不重写的话这个子类会被悄悄换掉,阻力改了个寂寞。
  @override
  _ShortBounceScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _ShortBounceScrollPhysics(parent: buildParent(ancestor));

  /// 内容不满一屏时也要能拖。默认物理在这种情况下直接拒收拖动
  /// (`shouldAcceptUserOffset` 在 min==max==0 时返回 false),刚进「主题与外观」
  /// 就是这个状态 —— 手指下去毫无反应,展开一张卡把内容撑高了才突然有回弹。
  /// 这里跟 AlwaysScrollableScrollPhysics 一样放开,越界那点回弹始终在。
  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => true;

  @override
  double frictionFactor(double overscrollFraction) =>
      super.frictionFactor(overscrollFraction) * 0.5;
}

/// 「点开滑出 / 再点缩回」那套伸缩回弹的规格。系统主题卡与首页三张预览卡共用
/// 同一份,两处的开合手感才一致。
///
/// 展开比收起慢:一次性滑出一整块内容,太快像被弹开。
const Duration _kRevealExpand = Duration(milliseconds: 460);

/// 收起稍快一点更利落,但同样留回弹。
const Duration _kRevealCollapse = Duration(milliseconds: 420);

/// 回弹要留在**末尾**:曲线前半段匀速铺开,最后冲到目标高度上面一点再落回来
/// (easeOutBack 那种形状是前段猛冲、末尾慢慢蹭,看着就是「一下就完了」)。
const Curve _kRevealExpandCurve = Cubic(0.35, 0.30, 0.45, 1.25);

/// 收起的回弹只能做成「先往回涨一点再缩」—— 高度没法缩得比标题行还短。
/// 这里让曲线前三分之一下探(箱子先涨 ~9%),再一路收到 0。
const Curve _kRevealCollapseCurve = Cubic(0.70, -0.50, 0.40, 1.0);

/// 靠高度做伸缩的「滑出/缩回」盒子。
///
/// 内容一直挂在树上,收起时只是被裁掉 —— 否则收起那一瞬间内容就没了,只剩一段
/// 空白在收,看着就是「啪一下贴到底」。展开:曲线冲过目标高度再收回,落到底那下
/// 是回弹。收起:曲线开头先往回一点(anticipation),箱子先微微涨一下再缩回去。
class _Reveal extends StatelessWidget {
  const _Reveal({required this.expanded, required this.child});

  final bool expanded;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      excluding: !expanded,
      child: IgnorePointer(
        ignoring: !expanded,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: expanded ? 1 : 0),
          duration: expanded ? _kRevealExpand : _kRevealCollapse,
          curve: expanded ? _kRevealExpandCurve : _kRevealCollapseCurve,
          builder: (context, t, child) => ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: t < 0 ? 0 : t,
              child: child,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 卡片右侧那个「展开/收起」箭头,转半圈。曲线与时长跟 [_Reveal] 同一份。
class _RevealChevron extends StatelessWidget {
  const _RevealChevron({required this.expanded, required this.color});

  final bool expanded;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedRotation(
      turns: expanded ? 0.5 : 0,
      duration: expanded ? _kRevealExpand : _kRevealCollapse,
      // 回弹曲线:箭头会稍微转过头再落回来
      curve: expanded ? _kRevealExpandCurve : _kRevealCollapseCurve,
      child: Icon(CupertinoIcons.chevron_down, size: 18, color: color),
    );
  }
}

/// 解析成功后每张预览卡的入场:淡入 + 上浮 16px。
///
/// 三张卡共用一条时间线,靠 [Interval] 错开(`index` 越大越晚),所以不需要
/// 定时器、也不会出现「谁先谁后」的帧间抖动。系统「减弱动态效果」时直接给终态。
class _StaggerIn extends StatefulWidget {
  const _StaggerIn({
    required this.index,
    required this.show,
    required this.child,
  });

  /// 第几张(从 0 起),决定入场顺序。
  final int index;

  final bool show;
  final Widget child;

  @override
  State<_StaggerIn> createState() => _StaggerInState();
}

class _StaggerInState extends State<_StaggerIn>
    with SingleTickerProviderStateMixin {
  static const Duration _motion = Duration(milliseconds: 560);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _motion,
    // 已经可见时(例如热重载、从别的 tab 切回来)直接是终态,不补播
    value: widget.show ? 1 : 0,
  );

  late final Animation<double> _progress = CurvedAnimation(
    parent: _controller,
    curve: Interval(
      // 第 0 张立刻走,之后每张晚 22% 的时间线(≈120ms)
      (widget.index * 0.22).clamp(0.0, 0.7),
      1,
      curve: Curves.easeOutCubic,
    ),
  );

  @override
  void didUpdateWidget(_StaggerIn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.show == oldWidget.show) return;
    if (widget.show) {
      _controller.forward(from: 0);
    } else {
      // 收回去时不播:外层 [_Reveal] 正在把高度收回,卡片再自己淡出会看着重影
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 只要 disableAnimations 这一个 aspect:MediaQuery.of 会把键盘 insets 的
    // 变化也算成依赖,白白重建一次。
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return AnimatedBuilder(
      animation: _progress,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: _progress.value,
        child: Transform.translate(
          offset: Offset(0, (1 - _progress.value) * 16),
          child: child,
        ),
      ),
    );
  }
}

/// 板块图标目录:每个板块一套浅色、一套深色,按当前主题取。
String _boardIcon(BuildContext context, String board, String file) {
  final mode = CupertinoTheme.of(context).brightness == Brightness.dark
      ? '深色模式'
      : '浅色模式';
  return '$mode$board/$file';
}

/// 首页板块(解析页)的图标。
String _homeIcon(BuildContext context, String file) =>
    _boardIcon(context, '首页板块22x22-SVG', file);

/// 历史板块的图标。
String _historyIcon(BuildContext context, String file) =>
    _boardIcon(context, '历史板块', file);

/// 下载进度弹窗的图标。
///
/// 这套目录的名字是「下载二次弹窗**浅色模式**」—— 模式在后缀,与其它板块
/// (「浅色模式首页板块…」)正好相反,所以不能走 [_boardIcon],得单独拼。
String _popupIcon(BuildContext context, String file) {
  final mode = CupertinoTheme.of(context).brightness == Brightness.dark
      ? '深色模式'
      : '浅色模式';
  return '下载二次弹窗$mode/$file';
}

/// 设置板块图标目录里的图标。
///
/// 弹窗也用这一套:为一句提示再单独画一张图不值当,而且这些图标本来就只有浅深
/// 两份,和弹窗的取色规则完全一样。
String _settingsIcon(BuildContext context, String file) {
  final mode = CupertinoTheme.of(context).brightness == Brightness.dark
      ? '深色主题'
      : '浅色主题';
  return '$mode（设置板块选项图标）/$file';
}

Future<String?> _readClipboardInner() async {
  // 先走自带那条:纯文本它又快又准,而绝大多数时候剪贴板里就是纯文本。
  var text = await _engineClipboardText();
  if (!_hasText(text)) {
    final native = await _nativeClipboardText();
    text = native.text;
    // 平台侧明明有这个方法却读空 → 可能是刚切回前台、系统还没把剪贴板交接过来,
    // 等一下再问一次。问不出来(测试、非 Android)就别白等这一下。
    if (native.available && !_hasText(text)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      text = (await _nativeClipboardText()).text;
    }
  }
  debugPrint('[clip] text=${text?.length ?? -1}');
  return _hasText(text) ? text : null;
}

bool _hasText(String? text) => text != null && text.trim().isNotEmpty;

/// 平台侧读剪贴板。
///
/// [available] 为假 = 这个方法根本不存在(测试、非 Android)。
/// 一次最多等 [_kClipboardReadTimeout]:真机实测 3~20ms,卡住的平台调用不能把
/// 「粘贴」这颗按钮晾在那儿。
Future<({bool available, String? text})> _nativeClipboardText() async {
  try {
    final text = await Downloader.channel
        .invokeMethod<String>('getClipboardText')
        .timeout(_kClipboardReadTimeout, onTimeout: () => null);
    return (available: true, text: text);
  } catch (_) {
    return (available: false, text: null);
  }
}

const Duration _kClipboardReadTimeout = Duration(milliseconds: 300);

/// Flutter 自带那条:只认 `text/plain`,当作最后的兜底。
Future<String?> _engineClipboardText() async {
  try {
    return (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  } catch (_) {
    return null;
  }
}

/// 卡片左侧那个圆角图标块。一级设置卡与首页卡片共用同一规格,两级观感才一致。
class _GlassIconChip extends StatelessWidget {
  const _GlassIconChip({required this.isDark, required this.asset});

  final bool isDark;
  final String asset;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isDark ? const Color(0x2EFFFFFF) : const Color(0x80FFFFFF),
        borderRadius: BorderRadius.circular(13),
      ),
      // 20 而非资源的 22:图形在 22x22 画布里顶满,按原尺寸画会贴住圆角块。
      child: TintedSvgIcon(
        asset,
        size: 20,
        color: _settingsPalette(isDark).foreground,
      ),
    );
  }
}

/// 卡片里的标题 + 副标题。首页与设置页共用,字号字重只有这一份。
class _CardHeadline extends StatelessWidget {
  const _CardHeadline({
    required this.isDark,
    required this.title,
    required this.subtitle,
    this.subtitleMaxLines = 1,
  });

  // 字号与行高只写这一遍:历史卡要靠它们算出「四行」到底多高。
  static const double _titleSize = 17;
  static const double _titleLineHeight = 1.2;
  static const double _subtitleSize = 13;
  static const double _subtitleLineHeight = 1.25;
  static const double _gap = 3;

  /// 标题两行 + 间隔 + 副标题两行的总高。
  ///
  /// 历史卡把右侧文字区锁成这个高度:标题长短差一行,卡片就会一张高一张矮,
  /// 列表看着参差不齐。
  static const double fourLineHeight =
      _titleSize * _titleLineHeight * 2 +
      _gap +
      _subtitleSize * _subtitleLineHeight * 2;

  final bool isDark;
  final String title;
  final String subtitle;

  /// 副标题行数。默认一行 —— 设置页那一列卡片的高度是量过的,不能自己长高。
  /// 历史卡例外:那里要放下「时间 · 平台 · 类型」,一行只有约 15 个字。
  final int subtitleMaxLines;

  @override
  Widget build(BuildContext context) {
    final (foreground: foreground, secondary: secondary) = _settingsPalette(
      isDark,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: foreground,
            fontSize: _titleSize,
            fontWeight: FontWeight.w600,
            height: _titleLineHeight,
          ),
        ),
        const SizedBox(height: _gap),
        Text(
          subtitle,
          maxLines: subtitleMaxLines,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: secondary,
            fontSize: _subtitleSize,
            height: _subtitleLineHeight,
          ),
        ),
      ],
    );
  }
}

/// 「解析」首页:一张窄的粘贴卡 + 若干张预览卡,单列排布。
/// 卡片样式与间距全部沿用一级设置列表(_GlassPanel / 20 边距 / 12 间距),
/// 只有内容不同 —— 首页比设置页多一块「预览区 + 底部动作按钮」。
///
/// 预览卡默认**不显示**:没解析出东西之前,它们只是几块空骨架,摆在那里既没
/// 信息也占满一屏。只有解析成功后它们才逐张入场(见 [_StaggerIn]),
/// 而且只显示这次真解析出来的内容(见 [_PreviewKind.forResult])。
///
/// 状态全部挂在 [_LiquidGlassDemoState] 上,这里只是把那份状态画出来 ——
/// 状态留在本页自己的 State 里的话,切一次 tab 就被丢掉了。
class _ParsePage extends StatelessWidget {
  const _ParsePage({required this.app});

  final _LiquidGlassDemoState app;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final parsed = app._parseResult;
    // 有什么才显示什么:纯视频链接底下不该挂一张空的「图集预览」。
    final kinds = parsed == null
        ? _PreviewKind.values
        : _PreviewKind.forResult(parsed);
    final showPreviews = parsed != null && kinds.isNotEmpty;
    return ListView(
      physics: const _ShortBounceScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, _kBoardHeaderTop, 20, 120),
      children: [
        const _BoardHeader(title: '解析'),
        const SizedBox(height: 18),
        _PasteLinkCard(app: app),
        if (app._parseError != null) ...[
          const SizedBox(height: 10),
          _ErrorNotice(message: app._parseError!, isDark: isDark),
        ],
        // 入场分两层:外层 [_Reveal] 把列表高度撑开(带系统主题卡那套回弹),
        // 内层每张卡各自淡入上浮、错开一拍。所以不是「啪」一下弹出来。
        _Reveal(
          expanded: showPreviews,
          child: Column(
            children: [
              const SizedBox(height: 12),
              ...kinds.asMap().entries.map(
                (entry) => Padding(
                  padding: EdgeInsets.only(
                    bottom: entry.key == kinds.length - 1 ? 0 : 12,
                  ),
                  child: _StaggerIn(
                    index: entry.key,
                    show: showPreviews,
                    child: _PreviewCard(
                      // 带上 kind 做 key:重新解析后同一位置上可能是另一种卡,
                      // 不换 key 的话 State 会被复用,开合状态会串到新卡上。
                      key: ValueKey<_PreviewKind>(entry.value),
                      kind: entry.value,
                      result: parsed,
                      app: app,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 解析失败的提示条。
///
/// 挂在粘贴卡下面,不占预览区的位置 —— 预览区里可能还留着上一次的结果。
class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.message, required this.isDark});

  final String message;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final color = isDark ? const Color(0xFFFF7B72) : const Color(0xFFC0392B);
    return _GlassPanel(
      isDark: isDark,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Icon(CupertinoIcons.exclamationmark_circle, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: color, fontSize: 13.5, height: 1.3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 标题行高度:三个板块统一 32。
///
/// 为什么定死:历史板块右上角挂着「选择 / 删除」两颗按钮(整颗 32 高)。如果让标题
/// 和它们一起参与布局、按默认居中,标题就被按钮撑高的那一行挤下去 —— 真机实测
/// 比解析板块低 25 设备px,切板块时一眼就看出来。行高定死之后,右侧有没有按钮、
/// 按钮多高,都不再影响标题的位置。
const double _kBoardHeaderHeight = 32;

/// 标题行的顶边距。
///
/// 原来是 24,但那是对着一颗裸 Text 量的。标题现在在 32 高的行里居中,会往下走
/// (32 - 标题文字盒高) / 2 ≈ 6,所以顶边距减掉同样的 6 —— 标题墨迹位置保持和
/// 改动前「解析」那颗裸 Text 一致(真机实测 232 设备px)。
const double _kBoardHeaderTop = 18;

/// 板块左上角那行标题:标题 + 可选的右侧按钮。三个板块共用,高度才统一。
///
/// 右侧那组按钮用 FittedBox 兜底:历史板块现在有三颗(选择/全选/删除),
/// 窄屏上放不下会整行溢出(flex 溢出会画黄黑条),放不下时按比例缩一点比溢出差。
class _BoardHeader extends StatelessWidget {
  const _BoardHeader({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _kBoardHeaderHeight,
      child: Row(
        children: [
          Text(
            title,
            style: CupertinoTheme.of(context).textTheme.navTitleTextStyle,
          ),
          if (trailing != null)
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: trailing,
              ),
            ),
        ],
      ),
    );
  }
}

/// 历史板块:一列解析记录卡。卡片样式与间距沿用首页/设置页(_GlassPanel / 20 边距 /
/// 12 间距),左边是封面,右上角横排「选择 / 全选 / 删除」。
///
/// 记录**不在本页读取**:数据由 [_LiquidGlassDemoState] 持有并在启动时预读好,
/// 这里只是画出来。本页的 State 一切走就被丢掉了,数据放这儿会每次重新读盘 ——
/// 冷启动进历史页那一下空白就是这么来的。
///
/// 选择模式是纯界面状态:切走 tab 就回到未选择状态。
///
/// 非选择模式下单击一张卡 = 带着那条链接回解析页重新解析
/// (走 [_LiquidGlassDemoState._reparseFromHistory])。
class _HistoryPage extends StatefulWidget {
  const _HistoryPage({required this.app});

  final _LiquidGlassDemoState app;

  @override
  State<_HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<_HistoryPage> {
  /// 是否处于选择模式。只在选择模式下卡片左端才长出勾选圈。
  bool _selecting = false;

  /// 已选中的记录 id。多选,所以是集合而不是单个值。
  final Set<String> _selected = <String>{};

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      // 退出选择模式时清空选择,免得下次进来还带着上次的勾
      if (!_selecting) _selected.clear();
    });
  }

  void _toggleSelected(HistoryEntry entry) {
    if (!_selecting) return;
    setState(() {
      if (!_selected.remove(entry.id)) _selected.add(entry.id);
    });
  }

  /// 当前列表是不是已经全部选中。全选框的「选中」态看它。
  bool _allSelected(List<HistoryEntry> list) =>
      list.isNotEmpty && _selected.length == list.length;

  /// 全选 / 取消全选。
  ///
  /// 按需求是**切换**:已经全选中了再点一次就全部取消,而不是永远只能全选。
  void _toggleSelectAll(List<HistoryEntry> list) {
    setState(() {
      if (_allSelected(list)) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(list.map((entry) => entry.id));
      }
    });
  }

  Future<void> _deleteSelected() async {
    final ids = <String>{..._selected};
    setState(() {
      _selected.clear();
      _selecting = false;
    });
    // 落盘和刷新都由根 State 做 —— 列表在它那儿
    await widget.app._deleteHistory(ids);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final secondary = _settingsPalette(isDark).secondary;
    // 列表在根 State 上,这里只读
    final entries = widget.app._historyEntries;
    final list = entries ?? const <HistoryEntry>[];
    return ListView(
      physics: const _ShortBounceScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, _kBoardHeaderTop, 20, 120),
      children: [
        _BoardHeader(
          title: '历史',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PillAction(
                asset: _historyIcon(context, '选择.svg'),
                label: '选择',
                active: _selecting,
                // 没有记录可挑时按钮是灰的
                onTap: list.isEmpty ? null : _toggleSelecting,
              ),
              const SizedBox(width: 8),
              _PillAction(
                asset: _historyIcon(context, '全选.svg'),
                label: '全选',
                // 只有进了选择模式,全选才有意义 —— 没进之前是灰的。
                // 进了之后点一次全选中,再点一次全部取消(选中态看 _allSelected)。
                onTap: _selecting && list.isNotEmpty
                    ? () => _toggleSelectAll(list)
                    : null,
                active: _selecting && _allSelected(list),
              ),
              const SizedBox(width: 8),
              _PillAction(
                asset: _historyIcon(context, '删除.svg'),
                label: '删除',
                destructive: true,
                // 一个都没选就删不了
                onTap: _selected.isEmpty ? null : _deleteSelected,
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (list.isEmpty)
          _GlassPanel(
            isDark: isDark,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Center(
                child: Text(
                  entries == null ? '正在读取…' : '暂无解析记录',
                  style: TextStyle(color: secondary, fontSize: 14),
                ),
              ),
            ),
          )
        else
          ...list.asMap().entries.map(
            (entry) => Padding(
              padding: EdgeInsets.only(
                bottom: entry.key == list.length - 1 ? 0 : 12,
              ),
              child: _HistoryCard(
                entry: entry.value,
                isDark: isDark,
                selecting: _selecting,
                selected: _selected.contains(entry.value.id),
                // 非选择模式:单击回解析页重新解析这条链接。
                // 选择模式:单击只是勾选/取消勾选。
                onTap: _selecting
                    ? () => _toggleSelected(entry.value)
                    : () => widget.app._reparseFromHistory(entry.value),
              ),
            ),
          ),
      ],
    );
  }
}

/// 历史卡的副标题:第一行「时间 · 平台」,第二行「这次解析出了什么」。
///
/// 三段挤一行放不下(可用宽度约 15 个字),交给 Text 自动换行会断在类型列表中间
/// (「视频/音频/」+「文案」),看着像渲染坏了。所以这里显式换行,让类型整体落下去。
String _entrySubtitle(HistoryEntry entry) {
  final result = entry.result;
  final contents = <String>[
    if (result.hasVideo) '视频',
    if (result.hasImages) '图集',
    if (result.hasAudio) '音频',
    if (result.hasCopy) '文案',
  ].join('/');
  return <String>[
    <String>[
      _shortTime(entry.parsedAt),
      if (result.platform.isNotEmpty) result.platform,
    ].join(' · '),
    if (contents.isNotEmpty) contents,
  ].join('\n');
}

/// 「今天 22:52」这种短时间。副标题只有一行,塞不下完整日期时间。
String _shortTime(DateTime time) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final days = today
      .difference(DateTime(time.year, time.month, time.day))
      .inDays;
  final clock =
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
  if (days <= 0) return '今天 $clock';
  if (days == 1) return '昨天 $clock';
  return '${time.month} 月 ${time.day} 日';
}

/// 淡底 + 图标 + 文字的胶囊按钮。历史页顶栏那排「选择 / 全选 / 删除」,
/// 和解析页「粘贴链接」卡右上角的「粘贴 / 清空」,共用这一颗。
///
/// 手写而不是 FilledButton:后者自带 48 的触控区,几颗并排会把标题行撑得比标题高一截。
/// 配色沿用首页那些次级按钮(淡底 + 强调色);[destructive] 的红只给「删除」这种。
class _PillAction extends StatelessWidget {
  const _PillAction({
    super.key,
    required this.asset,
    required this.label,
    required this.onTap,
    this.active = false,
    this.destructive = false,
  });

  /// 已经解析好的资源路径(用 [_historyIcon] / [_homeIcon] 拼)。
  final String asset;
  final String label;
  final VoidCallback? onTap;

  /// 选择模式开着时高亮这颗按钮。
  final bool active;

  /// 删除键用红字,和普通动作分开。
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final enabled = onTap != null;
    final Color color = destructive
        ? (isDark ? const Color(0xFFFF7B72) : const Color(0xFFC0392B))
        : (isDark ? const Color(0xFF5AA9FF) : const Color(0xFF1257C9));
    final Color foreground = enabled
        ? color
        : _settingsPalette(isDark).secondary.withValues(alpha: 0.45);
    // 这两颗按钮不在玻璃卡里,得自己当 Material 宿主 —— _PlainTap 是 InkWell,
    // 找不到 Material 祖先会直接断言失败。
    return Material(
      type: MaterialType.transparency,
      child: _PlainTap(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            color: active
                ? color.withValues(alpha: isDark ? 0.26 : 0.14)
                : (isDark ? const Color(0x1FFFFFFF) : const Color(0x14000000)),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              TintedSvgIcon(asset, size: 18, color: foreground),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: foreground,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一条记录卡:勾选圈(仅选择模式)+ 封面 + 标题副标题。
class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    required this.entry,
    required this.isDark,
    required this.selecting,
    required this.selected,
    required this.onTap,
  });

  final HistoryEntry entry;
  final bool isDark;
  final bool selecting;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final result = entry.result;
    return _GlassPanel(
      isDark: isDark,
      child: _PlainTap(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              _SelectDot(
                visible: selecting,
                selected: selected,
                isDark: isDark,
              ),
              _CoverSlot(isDark: isDark, coverUrl: result.coverUrl),
              const SizedBox(width: 14),
              Expanded(
                // 右侧文字区锁成「标题两行 + 副标题两行」的高度。
                // 不锁的话标题占一行还是两行会把卡片撑成两种高度,列表参差不齐。
                // 高度由 _CardHeadline 自己的字号行高算出来,不写死数字。
                child: SizedBox(
                  height: _CardHeadline.fourLineHeight,
                  child: _CardHeadline(
                    isDark: isDark,
                    // 标题为空的情况少见(接口会用正文兜底),但真出现时
                    // 留一张没有名字的卡比留个空字符串好。
                    title: result.title.isEmpty ? '未命名' : result.title,
                    subtitle: _entrySubtitle(entry),
                    // 时间 · 平台 · 类型,一行放不下
                    subtitleMaxLines: 2,
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

/// 卡片左端那个勾选圈。只在选择模式下出现 —— 出现/消失走和卡片展开同一套曲线,
/// 靠宽度伸缩(和 [_Reveal] 是一个路子,只是方向横过来)。
class _SelectDot extends StatelessWidget {
  const _SelectDot({
    required this.visible,
    required this.selected,
    required this.isDark,
  });

  final bool visible;
  final bool selected;
  final bool isDark;

  static const double _size = 22;

  @override
  Widget build(BuildContext context) {
    final accent = isDark ? const Color(0xFF5AA9FF) : const Color(0xFF1257C9);
    final secondary = _settingsPalette(isDark).secondary;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: visible ? 1 : 0),
      duration: visible ? _kRevealExpand : _kRevealCollapse,
      curve: visible ? _kRevealExpandCurve : _kRevealCollapseCurve,
      builder: (context, t, child) => ClipRect(
        child: Align(
          alignment: Alignment.centerLeft,
          widthFactor: t < 0 ? 0 : t,
          child: child,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Container(
          width: _size,
          height: _size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // 空心 → 选中后填色 + 白勾
            color: selected ? accent : const Color(0x00000000),
            border: Border.all(
              color: selected
                  ? accent
                  : secondary.withValues(alpha: selected ? 1 : 0.55),
              width: 1.6,
            ),
          ),
          child: selected
              ? const Icon(
                  CupertinoIcons.check_mark,
                  size: 14,
                  color: Color(0xFFFFFFFF),
                )
              : null,
        ),
      ),
    );
  }
}

/// 封面位。
///
/// 底下那层占位**一直在**,图下来了再淡入盖上去。
/// 之前是「有地址就直接画 Image」——图没下来之前那块位置是空的,只有一层灰底,
/// 看着就是"灰块 → 图片"硬切一下,很割裂。
///
/// 优先用磁盘缓存的本地文件:这是「重启 App 直接进历史页也能立刻看到封面」的关键。
/// 内存缓存救不了冷启动,只有落盘才行。
class _CoverSlot extends StatelessWidget {
  const _CoverSlot({required this.isDark, this.coverUrl});

  static const double width = 96;
  static const double height = 60;

  final bool isDark;
  final String? coverUrl;

  /// 有本地文件就从文件解码(快,不走网络);没有才联网并淡入。
  ///
  /// [cacheWidth] 是关键:存下来的是原图(封面动辄上千像素),而这里只显示 96 宽。
  /// 不告诉解码器目标尺寸的话,它会老老实实解一张全尺寸位图再缩 —— 那点时间
  /// 就是冷启动进历史页看到的那一下空白。给了解码器就能直接降采样。
  Widget _cover(String url, int cacheWidth) {
    final file = CoverCache.fileFor(url);
    if (file != null) {
      return Image.file(
        file,
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        // 判断存在之后到真正解码之间,系统可能把缓存目录回收了 —— 退回占位
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    }
    return Image.network(
      url,
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      // 已经有帧了就淡入。同步命中内存缓存(wasSynchronouslyLoaded)时不用淡
      // —— 那时候本来就该直接是图,淡一下反而闪。
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        return AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
          child: child,
        );
      },
      // 上游给的封面是带签名的临时地址,过一段时间会 403。
      // 历史记录会长期留着,所以出错时让底下那层占位露出来就行。
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final secondary = _settingsPalette(isDark).secondary;
    final url = coverUrl;
    // 按屏幕物理像素给解码尺寸:别解一张全尺寸图再缩
    final cacheWidth = (width * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: width,
        height: height,
        child: ColoredBox(
          color: isDark ? const Color(0x1FFFFFFF) : const Color(0x12000000),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: Icon(
                  CupertinoIcons.play_circle_fill,
                  size: 24,
                  color: secondary.withValues(alpha: 0.45),
                ),
              ),
              if (url != null) _cover(url, cacheWidth),
            ],
          ),
        ),
      ),
    );
  }
}

/// 粘贴链接卡:刻意比预览卡矮 —— 一行说明 + 一个输入框 + 一颗按钮。
///
/// 输入框必须有:解析的入口是「手上有链接」,只给粘贴按钮的话,改一个字符就得去
/// 别处重来。这里留一个可编辑的框,粘贴走系统长按菜单,清除走自带按钮。
///
/// 输入框控制器和解析状态都在 [_LiquidGlassDemoState] 上,这张卡本身无状态 ——
/// 否则切一次 tab 输入框就空了。
class _PasteLinkCard extends StatelessWidget {
  const _PasteLinkCard({required this.app});

  final _LiquidGlassDemoState app;

  void _start() {
    // 收键盘:解析结果就在这张卡下面,键盘立着会把它挡掉
    FocusManager.instance.primaryFocus?.unfocus();
    app._startParse(app._linkController.text);
  }

  /// 粘贴:把剪贴板里的内容整条塞进输入框。
  ///
  /// 不挑内容、也不看输入框里有没有东西 —— 用户点了就是要「把剪贴板给我」。
  /// 复制的是整段分享文本也没关系:里面那条链接由 [_onLinkChanged] 顺手挑出来。
  ///
  /// 读不到(系统拦下、或剪贴板本来就是空的)要说一句:点了毫无反应等于坏掉。
  Future<void> _paste(BuildContext context) async {
    final text = await app._readClipboard();
    if (!context.mounted) return;
    if (text == null || text.trim().isEmpty) {
      _showInfo(
        context,
        '没读到剪贴板里的文字',
        '如果刚才确实复制了:安卓在你切走应用之后可能已经把剪贴板清掉了,'
            '回原应用重新复制一次,再回来点粘贴。',
      );
      return;
    }
    // 换了新内容:把「完成解析」放回「开始解析」,否则新粘进来的链接点不动
    app._unlockParse();
    // 顺手预热连接:粘完多半就要点解析了
    app._parseService.warmUp();
    app._linkController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// 清空输入框。解锁「完成解析」由 [_onLinkChanged] 的置空分支负责。
  void _clear() => app._linkController.clear();

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final (foreground: foreground, secondary: secondary) = _settingsPalette(
      isDark,
    );
    final bool hasLink = app._linkController.text.trim().isNotEmpty;

    // 解析成功后按钮变成「完成解析」并置灰,直到用户点输入框或清空内容。
    final String label;
    final bool canStart;
    if (app._parseLocked) {
      label = '完成解析';
      canStart = false;
    } else if (app._parsing) {
      label = '解析中…';
      canStart = false;
    } else {
      label = '开始解析';
      canStart = hasLink;
    }

    return _GlassPanel(
      isDark: isDark,
      child: Padding(
        // 与设置卡同一条内边距(16/13),所以两页的卡片起止线是对齐的
        padding: const EdgeInsets.fromLTRB(16, 13, 16, 16),
        child: Column(
          children: [
            Row(
              children: [
                _GlassIconChip(
                  isDark: isDark,
                  asset: _homeIcon(context, '粘贴链接.svg'),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _CardHeadline(
                    isDark: isDark,
                    title: '粘贴链接',
                    subtitle: '粘贴平台分享链接',
                  ),
                ),
                const SizedBox(width: 10),
                // 右上角这两颗,样式抄历史页顶栏那排:粘贴在上、清空在下,
                // 都靠右对齐(Column 的 end),右边那条线才是齐的。
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _PillAction(
                      key: const ValueKey('pasteLink.paste'),
                      asset: _homeIcon(context, '粘贴.svg'),
                      label: '粘贴',
                      onTap: () => _paste(context),
                    ),
                    const SizedBox(height: 6),
                    _PillAction(
                      key: const ValueKey('pasteLink.clear'),
                      asset: _homeIcon(context, '清空.svg'),
                      label: '清空',
                      // 没内容就没得清:灰着,且吃掉点击
                      onTap: hasLink ? _clear : null,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            CupertinoTextField(
              controller: app._linkController,
              placeholder: '粘贴或输入分享链接',
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              style: TextStyle(color: foreground, fontSize: 15),
              placeholderStyle: TextStyle(color: secondary, fontSize: 15),
              // 输入框和预览区用同一档底色:首页里三块「内容区」是一个视觉层级
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0x1FFFFFFF)
                    : const Color(0x12000000),
                borderRadius: BorderRadius.circular(12),
              ),
              // 点一下输入框就把「完成解析」放回「开始解析」——
              // 用户既然又碰了输入框,说明他还想再解析一次。
              // 顺手预热连接:他接着要粘贴、再点按钮,握手别等到那时候才开始。
              onTap: () {
                app._parseService.warmUp();
                app._unlockParse();
              },
              // 自带的叉关掉:右上角已经有专门的「清空」,两个一起出现太吵
              clearButtonMode: OverlayVisibilityMode.never,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
              ),
              // 空链接解析不出东西,按钮先灰着,省得点了没反应;
              // 解析中和已完成的置灰见上面的 label/canStart。
              onPressed: canStart ? _start : null,
              // 图标颜色不写死:交给 FilledButton 注入的 IconTheme,
              // 深浅两套 ColorScheme 的前景色(含 M3 深色模式的深蓝 onPrimary)都跟得上。
              icon: TintedSvgIcon(_homeIcon(context, '开始解析.svg'), size: 20),
              label: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}

/// 预览卡的差异只有标题、图标、中间那块预览区和底部那颗动作按钮,其余全同,
/// 所以做成一份。动作按钮跟着内容走:画面、声音、图集、混合是「下载媒体」,
/// 文字是「复制文案」。
///
/// 具体显示哪几张由 [forResult] 按解析结果决定,不是全部画出来。
enum _PreviewKind {
  media('媒体预览', '视频画面', '媒体预览.svg', '下载媒体', '下载媒体.svg'),
  gallery('图集预览', '图片列表与缩略图', '图集预览.svg', '下载媒体', '下载媒体.svg'),
  mixed('混合预览', '视频与图片', '混合预览.svg', '下载媒体', '下载媒体.svg'),
  audio('音频预览', '音频预览与下载', '音频预览.svg', '下载媒体', '下载媒体.svg'),
  text('文案预览', '描述文案', '文案预览.svg', '复制文案', '复制文案.svg');

  const _PreviewKind(
    this.title,
    this.subtitle,
    this.icon,
    this.action,
    this.actionIcon,
  );

  final String title;
  final String subtitle;
  final String icon;

  /// 底部按钮的文字,同时用作「还没接后端」提示的标题。
  final String action;
  final String actionIcon;

  /// 这次解析该显示哪几张卡 —— 有什么才显示什么。
  ///
  /// 不能直接画 [values]:上游对每条链接都会回填一堆字段(标题兜底、首图兜底),
  /// 照着全集画出来就有「有卡没内容」—— 一条纯视频链接底下挂着空的图集预览。
  ///
  /// 既有视频又有图片时只给一张 [mixed]:**不拆成媒体卡 + 图集卡两张**,
  /// 混合链接的内容就摆在混合卡这一条缩略图里,不用上下对着看两条。
  ///
  /// 顺序跟枚举声明一致,免得卡片跳来跳去。
  static List<_PreviewKind> forResult(ParseResult result) => <_PreviewKind>[
    if (result.hasVideo && result.hasImages)
      mixed
    else ...[
      if (result.hasVideo) media,
      if (result.hasImages) gallery,
    ],
    // 视频自带音轨,所以有视频就有音频卡 —— 音源见 [ParseResult.audioSource]
    if (result.hasPlayableAudio) audio,
    // 只看描述:描述为空就没有文案卡,标题和作者不单独撑起一张卡
    if (result.hasCopy) text,
  ];

  /// 解析成功后这张卡默认是否摊开。
  ///
  /// 有内容的缩略图卡先摊开让人直接看到内容;音频和文案默认收起 ——
  /// 一屏同时展开四张卡会把页面撑得很长,而这两张点一下就能看/听。
  /// 卡片是否出现不受这个影响,收起的卡一样在列表里。
  bool get defaultExpanded => this == media || this == gallery || this == mixed;
}

/// 一张预览卡。
///
/// 每张卡自己管开合:点标题行滑出/缩回预览区,手感与「系统主题」卡同一套曲线
/// (见 [_Reveal])。默认展开 —— 首页第一眼就该看到三块预览,而不是三个折叠条。
class _PreviewCard extends StatefulWidget {
  const _PreviewCard({
    super.key,
    required this.kind,
    required this.result,
    required this.app,
  });

  final _PreviewKind kind;

  /// 解析结果。null 时三块内容区都还是骨架(外层 _Reveal 这时也不会展开)。
  final ParseResult? result;

  /// 根 State。下载结束要发系统通知,而开关在「通知管理与下载」页里、存在根 State 上。
  final _LiquidGlassDemoState app;

  @override
  State<_PreviewCard> createState() => _PreviewCardState();
}

class _PreviewCardState extends State<_PreviewCard> {
  /// 初始开合状态按卡片类型定:媒体和图集默认摊开,音频和文案默认收起。
  /// 用户点过后就以他自己的选择为准。
  late bool _expanded = widget.kind.defaultExpanded;

  /// 用户自己动过开合没有。
  ///
  /// 没动过时开合跟着内容走:卡片类型会随解析结果换(有视频有图片时媒体卡换成
  /// 混合卡,见 [forResult]),State 是按位置复用的,不跟就会带着上一张卡的状态 ——
  /// 媒体卡默认摊开、混合卡也默认摊开,却显示成收起的一条。
  /// 动过之后就以用户的选择为准,解析第二次不该把他收起的卡又弹开。
  bool _userToggled = false;

  @override
  void didUpdateWidget(_PreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_userToggled) _expanded = widget.kind.defaultExpanded;
  }

  /// 已选中的缩略图下标(媒体卡的多视频、图集卡的图片共用这一份)。
  final Set<int> _selected = <int>{};

  /// 上一次算出来的可选条目。列表换了(重新解析)就清空选中 ——
  /// 否则会按旧下标选中新链接里的图/视频。
  List<String> _lastItems = const [];

  /// 卡片底部的可选条目:媒体卡是多视频的地址,图集卡是图片地址,
  /// 混合卡是视频地址加图片地址。音频/文案返回空。
  List<String> _items(ParseResult? result) {
    if (result == null) return const [];
    return switch (widget.kind) {
      _PreviewKind.media =>
        result.hasMultiVideo
            ? [for (final v in result.videoItems) v.url]
            : const [],
      _PreviewKind.gallery => result.imageUrls,
      _PreviewKind.mixed => [for (final e in _mixedMedia(result)) e.url],
      _ => const [],
    };
  }

  /// 有两条以上媒体才带选中逻辑:一条就一颗直接能下的「下载媒体」按钮。
  bool _needsSelection(ParseResult? result) => _items(result).length > 1;

  bool get _allSelected =>
      _selected.isNotEmpty && _selected.length == _lastItems.length;

  /// 同步条目列表。
  ///
  /// initState 里也要跑一次(那时 widget 已经有了),所以这里不 setState。
  void _syncItems(List<String> items) {
    // 同一条链接里点选不该被清掉:只有列表真变了才重置
    if (_sameItems(items)) return;
    _lastItems = items;
    _selected.clear();
  }

  bool _sameItems(List<String> items) {
    if (items.length != _lastItems.length) return false;
    for (var i = 0; i < items.length; i++) {
      if (items[i] != _lastItems[i]) return false;
    }
    return true;
  }

  void _toggleTile(int index) {
    setState(() {
      if (!_selected.remove(index)) _selected.add(index);
    });
  }

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(Iterable<int>.generate(_lastItems.length));
      }
    });
  }

  /// 选中的媒体地址,按下标排序(顺序就是列表里的顺序)。
  List<String> get _selectedUrls => [
    for (final i in _selected.toList()..sort()) _lastItems[i],
  ];

  /// 卡片底部那颗动作按钮当前能不能按。
  ///
  /// - 没解析出结果:不能按(灰);
  /// - 一条链接两条以上媒体:必须选中至少一条才能下(灰);
  /// - 只有一条媒体:直接能下。
  bool get _canAct {
    final result = widget.result;
    if (result == null) return false;
    return !_needsSelection(result) || _selected.isNotEmpty;
  }

  /// 卡片底部那颗动作按钮。媒体/音频/图集/混合是下载,文案是复制。
  Future<void> _runAction() async {
    final result = widget.result;
    if (result == null) return;

    if (widget.kind == _PreviewKind.text) {
      await Clipboard.setData(ClipboardData(text: result.copyText));
      if (!mounted) return;
      _showInfo(context, '已复制', '标题与文案已复制到剪贴板。');
      return;
    }

    // 文案卡已经在上面返回了,剩下的都是「下载媒体」
    //
    // 有分辨率可选时先问一句再下:上游(第二个)会把同一条视频的多个码流都列出来,
    // 用户点下载就是要挑一档。media-parser 的结果没有这份列表,这里直接跳过 ——
    // 弹窗只在有得选的时候出现。
    var qualityUrl = _selectedQualityUrl(result);
    final qualities = qualityUrl == null
        ? const <VideoQuality>[]
        : _qualityChoice(result);
    if (qualities.isNotEmpty) {
      final picked = await showQualityPicker(context, qualities: qualities);
      // 弹窗是异步的:回来时这个卡片可能已经被重新解析换掉了。
      if (!mounted) return;
      if (picked == null) return; // 用户关掉了:不下载
      qualityUrl = picked.url;
    }

    final items = _itemsToDownload(result, qualityUrl: qualityUrl);
    if (items.isEmpty) {
      _showInfo(context, '没有可下载的内容', '先选中要下载的媒体。');
      return;
    }
    // 开始下载就把正在播的预览停掉:视频和音频都在播的时候,下载会和它们抢
    // 带宽和音频焦点。只是暂停,位置留在当前进度上 —— 下载跑完由
    // [_startDownload] 发一次恢复信号,点下载前在播的那些接着播。
    Playback.requestPause();
    await _startDownload(result.title, items);
  }

  /// 这次下载该给用户哪几档清晰度。
  ///
  /// 只有「正在下的就是那条主视频」时才有得选:合集卡里选中两条视频时,两条各有
  /// 各的清晰度列表,一次弹窗说不清下的是哪条 —— 那种情况按原地址下,不弹。
  ///
  /// 音频卡走的是 [ParseResult.audioSource](接口单独给的那份音轨),也不是视频,
  /// 同样不弹。
  List<VideoQuality> _qualityChoice(ParseResult result) {
    if (widget.kind == _PreviewKind.audio) return const [];
    final video = result.primaryVideo;
    if (video == null || !video.hasQualityChoice) return const [];
    // 媒体卡的多视频:选中的必须就是第一条主视频。
    if (widget.kind == _PreviewKind.media && result.hasMultiVideo) {
      final picked = _selectedUrls;
      if (picked.length != 1 || picked.first != result.primaryVideoUrl) {
        return const [];
      }
    }
    return video.qualities;
  }

  /// 单条视频那一路现在用的地址。null = 这次没有可选的清晰度。
  ///
  /// 判据和 [_qualityChoice] 一致:只有「正在下的就是主视频」才算。
  String? _selectedQualityUrl(ParseResult result) =>
      _qualityChoice(result).isEmpty ? null : result.primaryVideoUrl;

  /// 这次要下哪几条。
  ///
  /// [qualityUrl] 是用户在清晰度弹窗里选的那一档;非空时替换掉主视频的原地址
  /// (只有单条视频那一路会传)。
  ///
  /// 两条以上先选的规则:下的是选中的那些,不是全部(见 [_needsSelection])。
  /// 混合卡的视频和图片混在一条里,所以类型按每条自己的算,不能整批用一种。
  List<DownloadItem> _itemsToDownload(
    ParseResult result, {
    String? qualityUrl,
  }) {
    // 标题里带的媒体后缀先剥掉:有的平台标题就是文件名(抖音这条实测是
    // `…挪威冬日高画.mp4`),不去掉的话下面再拼一次后缀就变成 `…高画mp4.mp4`。
    final rawTitle = stripMediaExtension(result.title);

    /// 解析期按地址猜的后缀。收尾时下载器会按文件头改成真的 —— 猜错不影响相册里的
    /// 结果,只影响临时名。所以这里只关心**猜出来的后缀有多长**:[safeFileName] 要
    /// 把它和序号一起从 66 字节的上限里扣掉,不然拼出来的名字会超(见那里的说明)。
    String guessExt(String url, MediaKind kind) =>
        kind == MediaKind.video ? _urlExt(url, 'mp4') : _imageExt(url);

    /// 这一批第 [index] 条的名字(下标从 0 起)。
    ///
    /// 后缀是逐条猜的,但整批共用一个字节预算:按最长的那条留,否则同一批的标题会
    /// 被截成两种长度,看着像两批东西。序号只在有两条以上时才加。
    String nameOf(List<String> urls, List<MediaKind> kinds, int index) {
      final exts = [
        for (var i = 0; i < urls.length; i++) guessExt(urls[i], kinds[i]),
      ];
      final reserved = exts.fold('', (a, b) => a.length >= b.length ? a : b);
      final stem = safeFileName(
        rawTitle,
        ext: reserved,
        index: urls.length > 1 ? index + 1 : 0,
      );
      return '$stem.${exts[index]}';
    }

    List<DownloadItem> pack(
      List<String> urls,
      MediaKind Function(int index) kindOf,
    ) {
      final kinds = [for (var i = 0; i < urls.length; i++) kindOf(i)];
      return [
        for (var i = 0; i < urls.length; i++)
          DownloadItem(
            url: urls[i],
            fileName: nameOf(urls, kinds, i),
            kind: kinds[i],
          ),
      ];
    }

    return switch (widget.kind) {
      _PreviewKind.gallery => () {
        final urls = result.imageUrls;
        final picked = _needsSelection(result) ? _selectedUrls : urls;
        return pack(picked, (_) => MediaKind.image);
      }(),
      _PreviewKind.mixed => () {
        // 下载地址与缩略图网格同序,但视频那格是视频地址而不是封面(见 [_mixedMedia])
        final entries = _mixedMedia(result);
        // 两条以上要先选:一条视频 + 一张图也算两条,一样要走选中
        final picked = _needsSelection(result)
            ? [
                for (var i = 0; i < entries.length; i++)
                  if (_selected.contains(i)) entries[i],
              ]
            : entries;
        return pack([
          for (final e in picked) e.url,
        ], (i) => picked[i].isVideo ? MediaKind.video : MediaKind.image);
      }(),
      // 媒体的多视频卡走缩略图选中
      _PreviewKind.media when result.hasMultiVideo => pack(
        _selectedUrls,
        (_) => MediaKind.video,
      ),
      // 单条视频 / 音频卡:播什么就下什么。音频卡下的是接口给的那份独立音频文件
      // (audio_url),不是整个视频 —— 后台里那份是现成的,没必要下一整个 MP4。
      // 视频那一路用 primaryVideoUrl:实况帖的 video_url 是 null,地址在实况里。
      _ => () {
        final isAudio = widget.kind == _PreviewKind.audio;
        // 视频那一路:用户在清晰度弹窗里选过就用他选的那档,否则用 primaryVideoUrl
        // (实况帖的 video_url 是 null,地址在实况里)。音频卡不吃 qualityUrl ——
        // 那档是视频的码流,下音频时不弹窗,这里也不会传进来。
        final url = isAudio
            ? result.audioSource
            : (qualityUrl ?? result.primaryVideoUrl);
        if (url == null) return <DownloadItem>[];
        // 音源是视频本身时(接口没给 audio_url)按视频存:Video 目录 + video/mp4。
        // 按音频存会让媒体库拿到一段 audio/mp4 的视频流,归档和播放都不对。
        final asVideo = !isAudio || !result.hasStandaloneAudio;
        final ext = _urlExt(url, asVideo ? 'mp4' : 'mp3');
        return [
          DownloadItem(
            url: url,
            fileName: '${safeFileName(rawTitle, ext: ext)}.$ext',
            kind: asVideo ? MediaKind.video : MediaKind.audio,
          ),
        ];
      }(),
    };
  }

  /// 打开下载进度卡片,把这几条下完。
  ///
  /// 进度卡片自己管取消和关闭;这里只管把结果告诉它、失败时给一句人话,
  /// 顺带按「通知管理与下载」页里的开关发一条系统通知。
  Future<void> _startDownload(String title, List<DownloadItem> items) async {
    final app = widget.app;
    await showDownloadProgressCard(
      context,
      title: title,
      total: items.length,
      run: (onProgress, cancelled) async {
        try {
          await Downloader.saveAll(
            items,
            onProgress: onProgress,
            cancelled: cancelled,
          );
        } on DownloadCancelled {
          // 取消也算失败的一种:相册里什么都没有,和网络失败的结果一样,
          // 所以照发「下载失败」通知(发不发还是「通知管理与下载」里那个开关说了算)。
          // 卡片那边不当成错误:取消是用户自己按的,直接关掉就行。
          await app.notifyDownloadFinished(
            ok: false,
            title: title,
            error: '已取消',
          );
          rethrow;
        } catch (error) {
          await app.notifyDownloadFinished(
            ok: false,
            title: title,
            error: downloadErrorMessage(error),
          );
          rethrow; // 卡片还要靠这个异常把状态标成失败、弹出那句提示
        } finally {
          // 这一趟结束了(下完/取消/失败)才把预览放回去 —— 不是卡片关掉就放:
          // 用户可以先收起卡片让下载在后台继续,那时候恢复预览又和下载抢带宽了。
          Playback.requestResume();
        }
        await app.notifyDownloadFinished(ok: true, title: title);
      },
    );
  }

  /// 卡片副标题。
  ///
  /// 音频卡按音源改口:放接口给的那份独立音频时是「试听提取出的音频」;
  /// 只有接口没给 audio_url、退回视频本身时才叫「视频原声」。
  String _subtitle(ParseResult? result) {
    if (widget.kind == _PreviewKind.audio && result != null) {
      return result.hasStandaloneAudio ? widget.kind.subtitle : '视频原声';
    }
    return widget.kind.subtitle;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final secondary = _settingsPalette(isDark).secondary;
    // 解析结果换了就把选中清掉(同一条链接内点选不受影响)
    _syncItems(_items(widget.result));
    final selectable = _needsSelection(widget.result);
    return _GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PlainTap(
            onTap: () => setState(() {
              _userToggled = true;
              _expanded = !_expanded;
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 13, 14, 13),
              child: Row(
                children: [
                  _GlassIconChip(
                    isDark: isDark,
                    asset: _homeIcon(context, widget.kind.icon),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _CardHeadline(
                      isDark: isDark,
                      title: widget.kind.title,
                      subtitle: _subtitle(widget.result),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 收起时这里就是这张卡的「当前值」,与系统主题卡同一位置
                  Text(
                    _expanded ? '' : (widget.result == null ? '未解析' : '已解析'),
                    style: TextStyle(
                      color: secondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  _RevealChevron(expanded: _expanded, color: secondary),
                ],
              ),
            ),
          ),
          _Reveal(
            expanded: _expanded,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _PreviewStage(
                    kind: widget.kind,
                    isDark: isDark,
                    result: widget.result,
                    selected: _selected,
                    onTapTile: _toggleTile,
                  ),
                  const SizedBox(height: 14),
                  // 两条以上媒体:左边多一颗「全选媒体」,右边才是下载。
                  // 全选中之后这颗按钮改口叫「取消全选」—— 用户才知道再点一次
                  // 是取消,而不是继续全选。
                  if (selectable)
                    Row(
                      children: [
                        Expanded(
                          child: _CardActionButton(
                            isDark: isDark,
                            label: _allSelected ? '取消全选' : '全选媒体',
                            icon: '全选媒体.svg',
                            active: _allSelected,
                            onPressed: _toggleAll,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _CardActionButton(
                            isDark: isDark,
                            label: widget.kind.action,
                            icon: widget.kind.actionIcon,
                            onPressed: _canAct ? _runAction : null,
                          ),
                        ),
                      ],
                    )
                  else
                    _CardActionButton(
                      isDark: isDark,
                      label: widget.kind.action,
                      icon: widget.kind.actionIcon,
                      onPressed: _canAct ? _runAction : null,
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

/// 预览区。解析前是占位骨架:高度按各自内容定死,解析出结果后原地替换内容即可,
/// 卡片不会因为内容多寡而上下跳。
class _PreviewStage extends StatelessWidget {
  const _PreviewStage({
    required this.kind,
    required this.isDark,
    required this.result,
    required this.selected,
    required this.onTapTile,
  });

  final _PreviewKind kind;
  final bool isDark;

  /// 解析结果。null 时三块内容区都还是骨架。
  final ParseResult? result;

  /// 缩略图条里已选中的下标。跟着 [_PreviewCardState] 走。
  final Set<int> selected;
  final ValueChanged<int> onTapTile;

  @override
  Widget build(BuildContext context) {
    // 占位底:比卡片玻璃再深/浅一档,把内容区和标题区分开
    final fill = isDark ? const Color(0x1FFFFFFF) : const Color(0x12000000);
    final (foreground: foreground, secondary: secondary) = _settingsPalette(
      isDark,
    );
    final parsed = result;

    return switch (kind) {
      // 视频画面:一条视频是真正的播放器(见 [_VideoStage]),两条以上就是
      // 横向封面缩略图 —— 需求里多视频与多图走同一套排版,播放组件取消掉。
      // 封面用接口给的:那是这一条自己的首帧图;接口没给就退化成播放占位图标。
      _PreviewKind.media =>
        parsed != null && parsed.hasMultiVideo
            ? _GalleryStage(
                isDark: isDark,
                entries: [
                  for (final v in parsed.videoItems)
                    (url: v.coverUrl ?? '', isVideo: true),
                ],
                selected: selected,
                onTapTile: onTapTile,
                emptyHint: '这条链接没有视频画面',
                unit: '个',
              )
            : _VideoStage(
                isDark: isDark,
                // 走 previewVideoUrl 而不是 primaryVideoUrl:预览要的是**低码率**
                // 那一档,不是主地址。上游那条 8K 原画是 34.7 Mbps,预览播放器
                // 按秒缓冲,几十秒就把 Java 堆吃光(真机 tombstone 实测 OOM)。
                // 下载仍然按用户在清晰度弹窗里选的那一档走,两者互不影响。
                url: parsed?.previewVideoUrl ?? '',
                coverUrl: parsed?.primaryVideoCoverUrl,
              ),
      // 音频:一块能按的播放器。见 [_AudioStage] —— 不是波形图。
      _PreviewKind.audio => _AudioStage(
        isDark: isDark,
        url: parsed?.audioSource ?? '',
      ),
      // 图集:横向缩略图条。两条以上要选中才能下载,见 [_PreviewCardState]。
      // 没有图集内容(纯视频链接)时给一句话,不留一块空占位让人猜是不是加载失败。
      _PreviewKind.gallery => _GalleryStage(
        isDark: isDark,
        entries: [
          for (final url in parsed?.imageUrls ?? const <String>[])
            (url: url, isVideo: false),
        ],
        selected: selected,
        onTapTile: onTapTile,
        emptyHint: '这条链接没有图集内容',
        unit: '张',
      ),
      // 混合:视频封面和图片排在一条缩略图里,视频那几格右下角带播放标识。
      // 数两样一起数,所以量词不写死。
      _PreviewKind.mixed => _GalleryStage(
        isDark: isDark,
        entries: parsed == null
            ? const <({String url, bool isVideo})>[]
            : _galleryEntries(parsed),
        selected: selected,
        onTapTile: onTapTile,
        emptyHint: '这条链接没有解析出媒体',
        unit: '项',
      ),
      // 文案卡只放描述文案。标题和作者不上卡片(副标题已经写明是「描述文案」),
      // 描述为空时这张卡根本不会被建出来(见 [forResult])。
      // 文字区最多 12 行、超过就出滚动条,见 [_CopyStage]。
      _PreviewKind.text =>
        parsed == null
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
                  child: _textSkeleton(secondary),
                ),
              )
            : _CopyStage(isDark: isDark, text: parsed.desc),
    };
  }

  /// 文案卡的骨架:五条,最后一条短一截,看着就是一段落。
  Widget _textSkeleton(Color secondary) => Column(
    children: [
      for (final (i, width) in const [
        (0, 1.0),
        (1, 0.92),
        (2, 0.84),
        (3, 0.66),
        (4, 0.38),
      ]) ...[
        if (i > 0) const SizedBox(height: 10),
        FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: width,
          child: Container(
            height: 12,
            decoration: BoxDecoration(
              color: secondary.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
      ],
    ],
  );
}

/// 文案内文字区最多显示多少行。超过就锁这么高,右侧出滚动条。
const int _kCopyMaxLines = 12;

/// 文案预览区:整块只放描述文案。
///
/// 两种排法,按真实行数二选一:
/// - **不超过 12 行**:窗口跟着文字走,有几行就几行,不留空白;
/// - **超过 12 行**:窗口锁死在 12 行高,右侧出一根滚动条,上下滑动看全文。
///
/// 这里**不能**用 `maxLines` + ellipsis 截断 —— 那是把后面的文案直接丢掉。
/// 实测一条长文案在 App 上只显示到一半,接口返回的其实是完整的。
class _CopyStage extends StatefulWidget {
  const _CopyStage({required this.isDark, required this.text});

  final bool isDark;
  final String text;

  @override
  State<_CopyStage> createState() => _CopyStageState();
}

class _CopyStageState extends State<_CopyStage> {
  final ScrollController _scroll = ScrollController();

  static const double _fontSize = 14;
  static const double _lineHeight = 1.5;

  /// 一行占的高度。字号 × 行高倍数。
  static const double _lineBox = _fontSize * _lineHeight;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color foreground = _settingsPalette(widget.isDark).foreground;
    final fill = widget.isDark
        ? const Color(0x1FFFFFFF)
        : const Color(0x12000000);
    final style = TextStyle(
      color: foreground.withValues(alpha: 0.86),
      fontSize: _fontSize,
      height: _lineHeight,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // 先用同一套样式量一遍,数出真实行数 —— 要不要锁高、要不要出滚动条
        // 全看它。不量的话这两种情况在布局前根本分不出来。
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          textDirection: Directionality.of(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.computeLineMetrics().length > _kCopyMaxLines;

        final text = Text(widget.text, style: style);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(14),
          ),
          child: ConstrainedBox(
            // 不满 12 行时不设上限,窗口自然收缩到文字高度
            constraints: BoxConstraints(
              maxHeight: overflows
                  ? _lineBox * _kCopyMaxLines
                  : double.infinity,
            ),
            child: overflows
                // 用 CupertinoScrollbar 而不是 Material 的 Scrollbar:
                // 这个文件的 material 导入是 show 白名单,没带 Scrollbar;
                // 而且整个 App 就是 Cupertino 风格,滚动条也跟着一致。
                ? CupertinoScrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      // 右边多留一点,免得滚动条压在字上
                      padding: const EdgeInsets.fromLTRB(14, 16, 10, 16),
                      child: text,
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
                    child: text,
                  ),
          ),
        );
      },
    );
  }
}

/// 从地址里取一个像样的扩展名,取不到就用 [fallback]。
///
/// 不能一律写死:抖音图集常见 .jpeg / .webp,音频有 .mp3 / .m4a,视频是 .mp4 ——
/// 扩展名和 MIME 一起决定媒体库把它归到哪、能不能被相册或播放器正确打开。
String _urlExt(String url, String fallback) {
  final segments = Uri.tryParse(url)?.pathSegments ?? const <String>[];
  if (segments.isEmpty) return fallback;
  final last = segments.last;
  final dot = last.lastIndexOf('.');
  if (dot < 0) return fallback;
  final ext = last.substring(dot + 1).toLowerCase();
  return RegExp(r'^[a-z0-9]{2,5}$').hasMatch(ext) ? ext : fallback;
}

/// 图集图片的扩展名。见 [_urlExt]。
String _imageExt(String url) => _urlExt(url, 'jpg');

/// 缩略图网格里的一格:一条地址 + 它是不是视频。
///
/// 视频那几格的封面用接口给的首帧,右下角压一个播放标识和图片区分开。
typedef _MediaThumb = ({String url, bool isVideo});

/// 混合卡的缩略图条目:视频在前、图片在后。
///
/// 顺序和 [_PreviewCardState._items] 必须一致 —— 选中状态是按这里的下标存的,
/// 两边错了就会「点第一格选中第三格」。
List<_MediaThumb> _galleryEntries(ParseResult result) => <_MediaThumb>[
  for (final v in result.videoItems) (url: v.coverUrl ?? '', isVideo: true),
  for (final url in result.imageUrls) (url: url, isVideo: false),
];

/// 混合卡里真正要下载的东西。顺序与 [_galleryEntries] 一一对应(选中按同一个下标
/// 存),但视频那一格给的是**视频地址**,不是封面。
///
/// 封面是给网格显示的 jpg。拿它当视频下,文件名会按地址取到 `.jpg`、MIME 变成
/// image/jpeg,而 kind 还是 video —— 媒体库直接拒收:
/// `publish_failed: MIME type image/jpeg cannot be inserted into
/// content://media/external_primary/video/media`。
List<({String url, bool isVideo})> _mixedMedia(ParseResult result) => [
  for (final v in result.videoItems) (url: v.url, isVideo: true),
  for (final url in result.imageUrls) (url: url, isVideo: false),
];

/// 预览区的缩略图条:一条横向缩略图,底下一行数量。
///
/// 图集用图片,两个以上视频用视频封面 —— 需求就是这两种走同一套排版。
/// 高度写死 96:横向列表在竖向列表里必须有确定高度;竖向滚动与横向滚动各管各的,
/// 手势不会互相抢。
///
/// [selectable] 为真(两条以上媒体)时点一下缩略图切换选中,选中的角标是
/// 中心一个圆圈加勾;单选一条的链接不带到选中逻辑,点图也不选中。
class _GalleryStage extends StatelessWidget {
  const _GalleryStage({
    required this.isDark,
    required this.entries,
    required this.selected,
    required this.onTapTile,
    required this.emptyHint,
    required this.unit,
  });

  static const double _tileWidth = 72;
  static const double _tileHeight = 96;

  final bool isDark;
  final List<_MediaThumb> entries;
  final Set<int> selected;
  final ValueChanged<int> onTapTile;

  /// 没有内容时显示的那句话。
  final String emptyHint;

  /// 数量后面那个量词:「张」/「个」/「项」。
  final String unit;

  /// 两条以上才有「选中」这回事:一条链接只有一条媒体时,点图不选中,
  /// 底部也直接给一颗能按的「下载媒体」。
  bool get _selectable => entries.length > 1;

  @override
  Widget build(BuildContext context) {
    final secondary = _settingsPalette(isDark).secondary;
    final fill = isDark ? const Color(0x1FFFFFFF) : const Color(0x12000000);

    if (entries.isEmpty) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(14),
        ),
        child: SizedBox(
          height: _tileHeight,
          child: Center(
            child: Text(
              emptyHint,
              style: TextStyle(color: secondary, fontSize: 13),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: _tileHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const _ShortBounceScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) => _GalleryTile(
              isDark: isDark,
              thumb: entries[index],
              width: _tileWidth,
              height: _tileHeight,
              selectable: _selectable,
              selected: selected.contains(index),
              onTap: () => onTapTile(index),
              // 视频封面不是一张能看的图,不给眼睛(它自己那格已经有播放标识)。
              onPreview: entries[index].isVideo
                  ? null
                  : () => _openPreview(context, entries[index].url),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '共 ${entries.length} $unit',
          style: TextStyle(color: secondary, fontSize: 12.5),
        ),
      ],
    );
  }

  /// 点缩略图右下角那只眼睛:开一个窗口看这张图的原片。
  ///
  /// 传进去的就是这一格自己那条地址 —— 上游给的图集地址本来就是原图,没有另给一条
  /// 缩略图地址。窗口里按图片自己的分辨率解码(`Image.network` 不传 cacheWidth),
  /// 不是把 72 宽的缩略图拉大。
  void _openPreview(BuildContext context, String url) {
    unawaited(
      _showGlassLayer<void>(
        context,
        builder: (_) => _ImageViewerDialog(url: url),
      ),
    );
  }
}

/// 缩略图条里的一格。
///
/// 静态展示时就是一个圆角图;可选中时整格可点,选中后中央压一层圆圈加勾,
/// 并给整格描一圈强调色边 —— 缩略图横条在深色玻璃上,单靠中心圈不够显眼。
class _GalleryTile extends StatelessWidget {
  const _GalleryTile({
    required this.isDark,
    required this.thumb,
    required this.width,
    required this.height,
    required this.selectable,
    required this.selected,
    required this.onTap,
    required this.onPreview,
  });

  final bool isDark;
  final _MediaThumb thumb;
  final double width;
  final double height;
  final bool selectable;
  final bool selected;
  final VoidCallback onTap;

  /// 点右下角那只眼睛的回调。null = 这格不是图片(视频封面),不给眼睛。
  final VoidCallback? onPreview;

  @override
  Widget build(BuildContext context) {
    final secondary = _settingsPalette(isDark).secondary;
    final accent = isDark ? const Color(0xFF5AA9FF) : const Color(0xFF1257C9);
    final fill = isDark ? const Color(0x1FFFFFFF) : const Color(0x12000000);

    // 尺寸写死:横向列表里 Stack 的 fit 是 expand,不给死宽度它就问父级要,
    // 而父级给的是无限宽 —— 直接崩在 layout 上。
    final tile = SizedBox(
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ColoredBox(
              color: fill,
              // 单张挂了不影响整条:退回一块占位图标(图和视频用不同的)
              child: Image.network(
                thumb.url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Center(
                  child: Icon(
                    thumb.isVideo
                        ? CupertinoIcons.play_circle_fill
                        : CupertinoIcons.photo,
                    size: 22,
                    color: secondary.withValues(alpha: 0.45),
                  ),
                ),
              ),
            ),
          ),
          // 视频那几格右下角压一个播放标识,一眼分得出哪格是视频、哪格是图片。
          if (thumb.isVideo)
            Positioned(
              right: 4,
              bottom: 4,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0x8C000000),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(3),
                  child: Icon(
                    CupertinoIcons.play_fill,
                    size: 11,
                    color: Color(0xFFFFFFFF),
                  ),
                ),
              ),
            ),
          // 图片那几格右下角压一只眼睛,和视频的播放标识同一处、同一套底(半透明黑圆
          // 加白色图形),一眼分得出这格是图片、点它能看大图。
          //
          // 触摸区比标识本身大一圈(标识 17,这里 29):11 像素的图形手指按不准。
          // 这层在 Stack 里排在后面,命中最先落到它身上,外层那颗「点图选中」不会
          // 被一起触发。
          if (onPreview != null)
            Positioned(
              right: 0,
              bottom: 0,
              child: Semantics(
                button: true,
                label: '查看大图',
                child: GestureDetector(
                  onTap: onPreview,
                  behavior: HitTestBehavior.opaque,
                  child: const Padding(
                    padding: EdgeInsets.fromLTRB(8, 8, 4, 4),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0x8C000000),
                      ),
                      child: Padding(
                        padding: EdgeInsets.all(3),
                        child: Icon(
                          CupertinoIcons.eye_fill,
                          size: 11,
                          color: Color(0xFFFFFFFF),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (selected)
            DecoratedBox(
              decoration: BoxDecoration(
                // 边框压在圆角图上会被裁掉一角,半径比图大 2:角上刚好露满
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: accent, width: 2),
              ),
            ),
          if (selected)
            Center(
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent,
                  border: Border.all(
                    color: const Color(0xFFFFFFFF),
                    width: 1.6,
                  ),
                ),
                child: const Icon(
                  CupertinoIcons.check_mark,
                  size: 16,
                  color: Color(0xFFFFFFFF),
                ),
              ),
            ),
        ],
      ),
    );

    if (!selectable) return tile;
    return GestureDetector(
      onTap: onTap,
      // 缩略图是缩略图,不是按钮:点击反馈给在选中角标上,不铺水波纹
      behavior: HitTestBehavior.opaque,
      child: tile,
    );
  }
}

/// 点缩略图右下角那只眼睛弹出来的大图预览。
///
/// 窗口里是**这张图的原片**:`Image.network` 不传 cacheWidth,解码器按图片自己的
/// 分辨率解,不是把 72 宽的缩略图拉大。加载中、加载失败时窗口一样高 —— 高度按
/// 屏幕算死,面板不给大图撑得上下跳。
///
/// 图下面那颗「关闭」是需求里指定的出口;头部右上角那颗叉是这套弹窗本来就有的,
/// 两条路都关得掉。
class _ImageViewerDialog extends StatelessWidget {
  const _ImageViewerDialog({required this.url});

  /// 原片地址。
  final String url;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final secondary = _settingsPalette(isDark).secondary;
    final fill = isDark ? const Color(0x1FFFFFFF) : const Color(0x12000000);
    final screenHeight = MediaQuery.sizeOf(context).height;
    // 图片占屏幕的 58%,再留 200 给头部、关闭按钮和面板内边距 —— 横屏或小屏上
    // 面板(Column,不滚动)会装不下那么多行,撑破就是一条黄黑警告带。
    final imageHeight = math.min(screenHeight * 0.58, screenHeight - 200);

    return _PopupShell(
      title: '图片预览',
      icon: _homeIcon(context, '图集预览.svg'),
      // 比普通提示卡宽:300 宽的面板里那张图只剩 272,看不出"大图"
      maxWidth: 380,
      onClose: () => Navigator.of(context).pop(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ColoredBox(
              color: fill,
              child: SizedBox(
                width: double.infinity,
                height: imageHeight,
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child
                      : const Center(child: CupertinoActivityIndicator()),
                  // 地址多半带签名、会过期,下来就退回一个占位图,别让窗口空着
                  errorBuilder: (_, _, _) => Center(
                    child: Icon(
                      CupertinoIcons.photo,
                      size: 34,
                      color: secondary.withValues(alpha: 0.45),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          _PopupPrimaryButton(
            label: '关闭',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// 一秒级的时间文本(mm:ss)。超过一小时会自然变成三位的分,不做特殊处理。
String _clock(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final minutes = (total ~/ 60).toString().padLeft(2, '0');
  final seconds = (total % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// 播放控件外面那层渐变底。
///
/// 音频卡整块都是这个渐变;媒体卡的播放行现在也套同一层 —— 两处的播放控件
/// 看起来才是一套东西,而不是一个有底一个光秃秃。
class _PlaybackPanel extends StatelessWidget {
  const _PlaybackPanel({required this.isDark, required this.child});

  final bool isDark;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [Color(0x3D2E6BD6), Color(0x14000000)]
              : const [Color(0x2E1677FF), Color(0x0A1677FF)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
        child: child,
      ),
    );
  }
}

/// 播放控件一行:播放/暂停 + 可拖的进度条 + 已播/总时长。
///
/// 音频和视频共用 —— 两边的播放语义完全一样,只有外面那层壳不同
/// (都套 [_PlaybackPanel],音频上面没有画面,视频上面是 16:9 画面)。
class _PlaybackRow extends StatelessWidget {
  const _PlaybackRow({
    required this.isDark,
    required this.playing,
    required this.position,
    required this.duration,
    required this.enabled,
    required this.onToggle,
    required this.onSeek,
  });

  final bool isDark;
  final bool playing;
  final Duration position;

  /// 还没读出时长时为 null(音频要等 setUrl 完成,视频要等 initialize 完成)。
  final Duration? duration;

  /// 播放器可用才亮;没地址或加载失败时整行是灰的。
  final bool enabled;
  final VoidCallback onToggle;

  /// 拖进度条。参数是目标位置。
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    final secondary = _settingsPalette(isDark).secondary;
    final accent = isDark ? const Color(0xFF5AA9FF) : const Color(0xFF1257C9);
    final total = duration;

    return Row(
      children: [
        _PlainTap(
          onTap: enabled ? onToggle : null,
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: enabled ? accent : secondary.withValues(alpha: 0.35),
              shape: BoxShape.circle,
            ),
            child: Icon(
              playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
              size: 18,
              // 深色模式的强调色是亮蓝,压白图标会糊;那里换成近黑
              color: isDark ? const Color(0xFF10161F) : const Color(0xFFFFFFFF),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            children: [
              _ScrubBar(
                position: position,
                duration: total,
                onSeek: onSeek,
                accent: accent,
                track: secondary.withValues(alpha: 0.28),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    _clock(position),
                    style: TextStyle(color: secondary, fontSize: 11.5),
                  ),
                  const Spacer(),
                  Text(
                    total == null ? '--:--' : _clock(total),
                    style: TextStyle(color: secondary, fontSize: 11.5),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 可拖可点的进度条。
///
/// 触摸区给到 20 高(而不是那 4 个像素),否则手指根本按不准;
/// 位置按整个宽度等比换算成时间。
class _ScrubBar extends StatelessWidget {
  const _ScrubBar({
    required this.position,
    required this.duration,
    required this.onSeek,
    required this.accent,
    required this.track,
  });

  final Duration position;
  final Duration? duration;
  final ValueChanged<Duration> onSeek;
  final Color accent;
  final Color track;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = duration?.inMilliseconds ?? 0;
        final width = constraints.maxWidth;
        final fraction = total <= 0
            ? 0.0
            : (position.inMilliseconds / total).clamp(0.0, 1.0);

        void seekTo(double dx) {
          if (total <= 0 || width <= 0) return;
          final f = (dx / width).clamp(0.0, 1.0);
          onSeek(Duration(milliseconds: (f * total).round()));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => seekTo(details.localPosition.dx),
          onHorizontalDragUpdate: (details) => seekTo(details.localPosition.dx),
          child: SizedBox(
            height: 20,
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: SizedBox(
                  height: 4,
                  child: Stack(
                    children: [
                      Positioned.fill(child: ColoredBox(color: track)),
                      // 宽度直接算出来,不用 Expanded(flex:):fraction 为 0 时
                      // flex 也是 0,而 flex 0 的子项在 Row 里会退化成「按自身尺寸」,
                      // 进度条会整根跳到满格。
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: width * fraction,
                        child: ColoredBox(color: accent),
                      ),
                    ],
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

/// 媒体预览区:16:9 的视频播放器。
///
/// 画面读出来之前用**封面当首帧**:接口在 `cover_url` 里给了封面,却空着窗口写
/// 「无封面」很怪。真没有封面时才退化成那句话。
///
/// 左右滑动画面可以调进度,和下面进度条走同一套 seek 逻辑。
class _VideoStage extends StatefulWidget {
  const _VideoStage({required this.isDark, required this.url, this.coverUrl});

  final bool isDark;
  final String url;

  /// 封面地址。当首帧占位用,拿不到就写「无封面」。
  final String? coverUrl;

  @override
  State<_VideoStage> createState() => _VideoStageState();
}

class _VideoStageState extends State<_VideoStage> {
  VideoPlayerController? _controller;
  bool _failed = false;

  /// seek 是异步的。拖动时每一帧都发一次会把播放器塞满,上一个没回来就丢新的。
  bool _seeking = false;

  /// 这一条视频的播放位置只接回去一次,别把用户后来的拖动也覆盖掉。
  bool _restored = false;

  /// 消费到第几次暂停/恢复信号了。只处理比自己新的那些。
  int _seenPause = 0;
  int _seenResume = 0;

  /// 点「下载媒体」那一刻这条视频在不在播。在播的话,下载结束要接着播。
  bool _resumeAfterDownload = false;

  /// 当前播放器有没有接上暂停信号。
  bool _listeningPause = false;

  @override
  void initState() {
    super.initState();
    _seenPause = Playback.pauseRequests.value;
    _seenResume = Playback.resumeRequests.value;
    Playback.pauseRequests.addListener(_onPauseRequest);
    Playback.resumeRequests.addListener(_onResumeRequest);
    _listeningPause = true;
    _load();
  }

  @override
  void didUpdateWidget(_VideoStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换一条链接重新解析时,这个 State 会被复用(同类型、同位置),initState 不会
    // 再跑。不在这里换掉播放器,画面和时长就一直停在上一条视频上。
    if (oldWidget.url != widget.url) {
      _controller?.dispose();
      _controller = null;
      _failed = false;
      _seeking = false;
      _restored = false;
      _resumeAfterDownload = false;
      _load();
    }
  }

  /// 点「下载媒体」时收到一次信号:**暂停**,播放器留着。
  ///
  /// 早先这里是直接把播放器 dispose 掉(当时预览播的是 8K 原画,缓冲几十秒就是
  /// 上百 MB,和下载抢内存)。现在预览走的是最低码率那一档(见
  /// [ParseResult.previewVideoUrl]),占的内存很小,于是改成暂停:下载结束还能
  /// 接着看,画面停在原处,不用重新缓冲。
  ///
  /// 位置先记下来,万一播放器后来还是得重建,`Playback.recall` 靠着它接回原处。
  void _onPauseRequest() {
    final request = Playback.pauseRequests.value;
    if (request == _seenPause) return;
    _seenPause = request;
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isInitialized) {
      Playback.remember(widget.url, controller.value.position);
    }
    _resumeAfterDownload = controller.value.isPlaying;
    controller.pause();
  }

  /// 下载那一趟结束了:点下载前在播的话,接着播。
  void _onResumeRequest() {
    final request = Playback.resumeRequests.value;
    if (request == _seenResume) return;
    _seenResume = request;
    if (!_resumeAfterDownload) return;
    _resumeAfterDownload = false;
    _controller?.play();
  }

  Future<void> _load() async {
    if (widget.url.isEmpty) return;
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.url),
      );
      _controller = controller;
      await controller.initialize();
      await controller.setLooping(true);
      // 这条视频上次播到哪就接回哪 —— 切走再切回来不该打回 00:00。
      final remembered = Playback.recall(widget.url);
      if (remembered != null && !_restored) {
        _restored = true;
        await controller.seekTo(remembered);
      }
      if (!mounted) return;
      setState(() {});
    } catch (_) {
      // 平台插件缺失(测试环境)或地址取不到,都退化成一块占位,
      // 不能让一张卡把整页搞崩。
      if (mounted) setState(() => _failed = true);
    }
  }

  /// 画面还没出来时的占位:有封面就铺封面,没有才写字。
  ///
  /// 加载失败也走这里 —— 黑框比封面难看,而且封面本来就是这张视频的内容。
  /// 失败时在封面上压一层暗底加一句说明,别让人以为是在加载。
  Widget _poster(Color secondary) {
    final cover = widget.coverUrl;
    Widget caption(String text) => Center(
      child: Text(text, style: TextStyle(color: secondary, fontSize: 13)),
    );

    if (cover == null) return caption(_failed ? '视频无法播放' : '无封面');

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.network(
          cover,
          fit: BoxFit.cover,
          // 封面是带签名的临时地址,过一段时间会 403 —— 那时退回那句话。
          errorBuilder: (_, _, _) => caption(_failed ? '视频无法播放' : '无封面'),
        ),
        if (_failed)
          ColoredBox(
            color: const Color(0x99000000),
            child: const Center(
              child: Text(
                '视频无法播放',
                style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 13),
              ),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    if (_listeningPause) {
      Playback.pauseRequests.removeListener(_onPauseRequest);
      Playback.resumeRequests.removeListener(_onResumeRequest);
    }
    // 离开页面前把进度记下来:页面被销毁时播放器也跟着没了,下次要靠这个接回去。
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      Playback.remember(widget.url, controller.value.position);
    }
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _seekTo(Duration target) async {
    final controller = _controller;
    if (controller == null || _seeking) return;
    _seeking = true;
    try {
      await controller.seekTo(target);
    } catch (_) {
      // 播放器已随页面销毁时会抛,忽略。
    } finally {
      _seeking = false;
    }
  }

  Future<void> _toggle() async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final secondary = _settingsPalette(isDark).secondary;
    final controller = _controller;

    if (controller == null || _failed) {
      return Column(
        children: [
          _frame(_poster(secondary)),
          const SizedBox(height: 12),
          _PlaybackPanel(
            isDark: isDark,
            child: _PlaybackRow(
              isDark: isDark,
              playing: false,
              position: Duration.zero,
              duration: null,
              enabled: false,
              onToggle: () {},
              onSeek: (_) {},
            ),
          ),
        ],
      );
    }

    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final ready = value.isInitialized;
        final duration = ready ? value.duration : null;
        // 每一帧都记一下播到哪了。销毁时再读一次是异步的、可能来不及,
        // 所以以这里为准。
        if (ready && value.position > Duration.zero) {
          Playback.remember(widget.url, value.position);
        }

        // 封面一直铺到画面真的开始走为止。
        //
        // 两个都不能用「初始化完成」:初始化只代表容器解析完了,离能看还差得远。
        // 也不能只用 isPlaying:按下播放那一刻 isPlaying 就为真,而高码率视频
        // (实测一条 8K 的缓冲了近一分钟)在这之后还要等很久才有第一帧 ——
        // 那时把封面淡掉,用户看到的就是一大片黑。
        // position > 0 说明画面已经在走了,这时候换上去才正好接上。
        final showFrame = ready && value.position > Duration.zero;

        // 比窗口还宽的视频用 cover 铺满,去掉上下黑边;比窗口窄的(竖屏短视频)
        // 保持 contain —— 竖屏视频在 16:9 窗口里 cover 会被裁成中间一条。
        final videoAspect = value.size.height > 0
            ? value.size.width / value.size.height
            : 0.0;
        final tooWide = ready && videoAspect > 16 / 9;

        return Column(
          children: [
            _frame(
              Stack(
                fit: StackFit.expand,
                children: [
                  if (ready)
                    FittedBox(
                      fit: tooWide ? BoxFit.cover : BoxFit.contain,
                      child: SizedBox(
                        width: value.size.width,
                        height: value.size.height,
                        child: VideoPlayer(controller),
                      ),
                    ),
                  // 封面压在画面上,开始播放后淡出 —— 淡出这 320ms 正好留给
                  // 首帧解码,不然按下播放会先闪一下黑。
                  AnimatedOpacity(
                    opacity: showFrame ? 0 : 1,
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeOut,
                    child: IgnorePointer(child: _poster(secondary)),
                  ),
                  // 左右滑动画面调进度。放最上层,免得手势被视频层吃掉。
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: (details) {
                          if (duration == null ||
                              duration.inMicroseconds <= 0 ||
                              constraints.maxWidth <= 0) {
                            return;
                          }
                          final delta = Duration(
                            microseconds:
                                (details.delta.dx /
                                        constraints.maxWidth *
                                        duration.inMicroseconds)
                                    .round(),
                          );
                          final target = value.position + delta;
                          _seekTo(
                            target < Duration.zero
                                ? Duration.zero
                                : (target > duration ? duration : target),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _PlaybackPanel(
              isDark: isDark,
              child: _PlaybackRow(
                isDark: isDark,
                playing: value.isPlaying,
                position: value.position,
                duration: duration,
                enabled: true,
                onToggle: _toggle,
                onSeek: _seekTo,
              ),
            ),
          ],
        );
      },
    );
  }

  /// 16:9 的画面框,圆角与底色和另外几块预览区一致。
  Widget _frame(Widget child) => ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: AspectRatio(
      aspectRatio: 16 / 9,
      child: ColoredBox(color: const Color(0xFF000000), child: child),
    ),
  );
}

/// 音频预览区:真的播放器。
///
/// 播放/暂停、时长、可拖的进度条都由 [AudioPlayer] 驱动 ——
/// 之前那颗只切换图形的假按钮已经换掉了。
class _AudioStage extends StatefulWidget {
  const _AudioStage({required this.isDark, required this.url});

  final bool isDark;
  final String url;

  @override
  State<_AudioStage> createState() => _AudioStageState();
}

class _AudioStageState extends State<_AudioStage> {
  AudioPlayer? _player;
  bool _failed = false;

  /// 这一条音频的位置只接回去一次。
  bool _restored = false;

  /// 消费到第几次暂停/恢复信号了。
  int _seenPause = 0;
  int _seenResume = 0;

  /// 点「下载媒体」那一刻这条音频在不在播。在播的话,下载结束要接着播。
  bool _resumeAfterDownload = false;

  @override
  void initState() {
    super.initState();
    _seenPause = Playback.pauseRequests.value;
    _seenResume = Playback.resumeRequests.value;
    Playback.pauseRequests.addListener(_onPauseRequest);
    Playback.resumeRequests.addListener(_onResumeRequest);
    _load();
  }

  @override
  void didUpdateWidget(_AudioStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同 _VideoStage:换链接重新解析时 State 会被复用,不在这里换播放器的话
    // 听到的还是上一条视频的音源(实测:换了链接时长还停在上一条的 00:17)。
    if (oldWidget.url != widget.url) {
      _player?.dispose();
      _player = null;
      _failed = false;
      _restored = false;
      _resumeAfterDownload = false;
      _load();
    }
  }

  /// 点「下载媒体」时收到一次信号:暂停(理由同 [_VideoStageState._onPauseRequest])。
  void _onPauseRequest() {
    final request = Playback.pauseRequests.value;
    if (request == _seenPause) return;
    _seenPause = request;
    final player = _player;
    if (player == null) return;
    Playback.remember(widget.url, player.position);
    _resumeAfterDownload = player.playing;
    player.pause();
  }

  /// 下载那一趟结束了:点下载前在播的话,接着播。
  void _onResumeRequest() {
    final request = Playback.resumeRequests.value;
    if (request == _seenResume) return;
    _seenResume = request;
    if (!_resumeAfterDownload) return;
    _resumeAfterDownload = false;
    _player?.play();
  }

  Future<void> _load() async {
    if (widget.url.isEmpty) return;
    try {
      final player = AudioPlayer();
      _player = player;
      await player.setUrl(widget.url);
      // 上次播到哪就接回哪,切走再切回来不打回 00:00。
      final remembered = Playback.recall(widget.url);
      if (remembered != null && !_restored) {
        _restored = true;
        await player.seek(remembered);
      }
      if (!mounted) return;
      setState(() {});
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    Playback.pauseRequests.removeListener(_onPauseRequest);
    Playback.resumeRequests.removeListener(_onResumeRequest);
    final player = _player;
    if (player != null) {
      Playback.remember(widget.url, player.position);
    }
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final player = _player;
    if (player == null) return;
    if (player.playing) {
      await player.pause();
    } else {
      // 播完再按就从头开始,否则按下去没反应。
      if (player.processingState == ProcessingState.completed) {
        await player.seek(Duration.zero);
      }
      await player.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final player = _player;

    return _PlaybackPanel(
      isDark: isDark,
      child: player == null || _failed
          ? _PlaybackRow(
              isDark: isDark,
              playing: false,
              position: Duration.zero,
              duration: null,
              enabled: false,
              onToggle: () {},
              onSeek: (_) {},
            )
          : StreamBuilder<PlayerState>(
              stream: player.playerStateStream,
              builder: (context, stateSnapshot) {
                final state = stateSnapshot.data;
                final playing =
                    (state?.playing ?? false) &&
                    state?.processingState != ProcessingState.completed;
                return StreamBuilder<Duration>(
                  stream: player.positionStream,
                  builder: (context, positionSnapshot) {
                    final position = positionSnapshot.data ?? Duration.zero;
                    // 每一帧记一下播到哪(销毁时再读是异步的,可能来不及)。
                    if (position > Duration.zero) {
                      Playback.remember(widget.url, position);
                    }
                    return _PlaybackRow(
                      isDark: isDark,
                      playing: playing,
                      position: position,
                      duration: player.duration,
                      enabled: true,
                      onToggle: _toggle,
                      onSeek: (target) => player.seek(target),
                    );
                  },
                );
              },
            ),
    );
  }
}

/// 三张预览卡底部那颗动作按钮(下载媒体 / 复制文案)。做成次级按钮(淡底 + 强调色
/// 文字):同一屏里出现三次,全用实心主色会把首页压成一片蓝,主按钮只留给「开始解析」。
class _CardActionButton extends StatelessWidget {
  const _CardActionButton({
    required this.isDark,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.active = false,
  });

  final bool isDark;
  final String label;
  final String icon;

  /// 解析结果还没出来、或者还没选中媒体时传 null,按钮自动置灰。
  final VoidCallback? onPressed;

  /// 「全选媒体」专用:全部选中时压一层强调色底,一眼看出当前是全选状态。
  final bool active;

  @override
  Widget build(BuildContext context) {
    final accent = isDark ? const Color(0xFF5AA9FF) : const Color(0xFF1257C9);
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(46),
        // 两颗按钮并排时文字要收着点,否则「全选媒体 + 下载媒体」在小屏上会换行
        padding: const EdgeInsets.symmetric(horizontal: 10),
        backgroundColor: active
            ? accent.withValues(alpha: isDark ? 0.30 : 0.18)
            : (isDark ? const Color(0x1FFFFFFF) : const Color(0x141257C9)),
        foregroundColor: accent,
      ),
      onPressed: onPressed,
      // 颜色跟着上面的 foregroundColor 走,不写死
      icon: TintedSvgIcon(_homeIcon(context, icon), size: 20),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

/// 下载进度卡片的干活方式:跑起来,往里推进度,并给一个「用户按了取消没」的查询。
typedef DownloadRun = Future<void> Function(
  void Function(DownloadProgress) onProgress,
  bool Function() cancelled,
);

/// 弹出下载进度卡片,把这一批媒体下完。返回时下载已经结束(或被取消)。
Future<void> showDownloadProgressCard(
  BuildContext context, {
  required String title,
  required int total,
  required DownloadRun run,
}) {
  return showCupertinoModalPopup<void>(
    context: context,
    // 卡片自己就是全部交互(取消 / 完成),点外面关掉会让人不知道下载还在不在
    barrierDismissible: false,
    // 遮罩只留很淡的一层:卡片是半透明玻璃底,遮罩一重就会把它衬得发灰、显得
    // 比预览卡"透"得多。真正的层次交给卡片背后那层模糊。
    barrierColor: const Color(0x14000000),
    builder: (context) =>
        _DownloadProgressCard(title: title, total: total, run: run),
  );
}

/// 下载进度卡片。
///
/// 右上角是「下载进度」(没有关闭按钮:窗口只靠下面的按钮收),
/// 中间是波浪进度环(见 [_ProgressRing]),下面是「取消下载」—— 下完就变成「完成」。
class _DownloadProgressCard extends StatefulWidget {
  const _DownloadProgressCard({
    required this.title,
    required this.total,
    required this.run,
  });

  final String title;
  final int total;
  final DownloadRun run;

  @override
  State<_DownloadProgressCard> createState() => _DownloadProgressCardState();
}

class _DownloadProgressCardState extends State<_DownloadProgressCard> {
  /// 用户按了「取消下载」。下载循环每一段都会问一次。
  bool _cancelled = false;
  bool _cancelling = false;

  /// 下载这一趟的 Future。取消时要等它真收完尾(删掉半个文件)才关窗口 ——
  /// 先关窗口再让下载继续跑,相册里就可能留下半个文件。
  Future<void>? _running;

  double _fraction = 0;
  bool _failed = false;

  /// 这次下载收了多少字节,以及从开始到现在过了多久。用来算实时速度。
  ///
  /// 两个都要:**只有字节数看不出快慢**,要除时间才是 MB/s。这也让"调分段数到底
  /// 有没有用"变成屏幕上能看懂的一个数字(见 Downloader.maxSegments 的注释)。
  int _received = 0;
  final Stopwatch _clock = Stopwatch();

  @override
  void initState() {
    super.initState();
    _clock.start();
    _running = widget.run(_onProgress, () => _cancelled);
    // 错误在这里处理,不往上抛:整趟下载在这张卡里闭环
    _running!.then<void>((_) {
      // 极小概率下用户点取消时下载恰好已经完成,也应该按用户意图关掉卡片。
      if (_cancelled) _close();
    }, onError: _onError);
  }

  /// 进度按字节报,条数只用来在副标题里说「一共几条」。
  void _onProgress(DownloadProgress p) {
    if (!mounted) return;
    _received = p.received;
    // 每个百分点刷一次 setState(一秒几十次的原始回调太密)。速度那一行跟着
    // 这个节奏走就够了 —— 它要的是"大概多快",不是每一帧都精确。
    if ((p.fraction * 100).floor() == (_fraction * 100).floor()) return;
    setState(() => _fraction = p.fraction);
  }

  /// 「3.2 MB/s」这类实时速度。还没收到数据、或者刚起步不到半秒时是空串 ——
  /// 那时候算出来的数字是抖的,显示出来只会让人以为卡了。
  String get _speedText {
    final seconds = _clock.elapsedMilliseconds / 1000;
    if (_received <= 0 || seconds < 0.5) return '';
    final mbps = _received / seconds / (1024 * 1024);
    return '${mbps.toStringAsFixed(1)} MB/s';
  }

  /// 还要多久。速度太低(不到 64 KB/s)时不给,那种估算只会吓人。
  String get _etaText {
    final seconds = _clock.elapsedMilliseconds / 1000;
    final total = _totalBytes;
    if (_received <= 0 || total <= 0 || seconds < 1) return '';
    final speed = _received / seconds;
    if (speed < 64 * 1024) return '';
    final remain = (total - _received) / speed;
    if (remain <= 0) return '';
    final minutes = remain ~/ 60;
    final secs = (remain % 60).round();
    return minutes > 0 ? '约 $minutes 分$secs 秒' : '约 $secs 秒';
  }

  /// 这趟下载的总字节数。进度是分数,反推出来的 —— 这一层拿不到原始总量。
  int get _totalBytes => _fraction <= 0 ? 0 : (_received / _fraction).round();

  void _onError(Object error) {
    if (!mounted) return;
    // 取消不是错误:取消是用户自己按的,窗口直接关掉
    if (error is DownloadCancelled) {
      _close();
      return;
    }
    setState(() => _failed = true);
    _showInfo(context, '下载没能完成', downloadErrorMessage(error));
  }

  bool get _done => _fraction >= 1 && !_failed;

  void _close() {
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  /// 发出取消后由下载器断开连接并清理文件;收到完成回调后再关窗口。
  void _cancel() {
    if (_cancelling) return;
    setState(() {
      _cancelled = true;
      _cancelling = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final secondary = _settingsPalette(isDark).secondary;
    return _PopupShell(
      title: '下载进度',
      icon: _popupIcon(context, '下载进度.svg'),
      // 不给关闭叉:窗口只能靠下面的「取消下载 / 完成」收,
      // 免得下载中手一滑把窗口关掉、以为下载也停了。
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _title(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: secondary, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          Center(
            child: _ProgressRing(
              progress: _fraction,
              failed: _failed,
              isDark: isDark,
            ),
          ),
          // 速度 + 预计还要多久。大文件(这条抖音的原画 7.27GB)没有这两个数字,
          // 用户只能盯着一个百分比猜;而且它也是调分段数的依据。
          if (!_failed)
            Builder(
              builder: (context) {
                final parts = <String>[
                  if (_speedText.isNotEmpty) _speedText,
                  if (_etaText.isNotEmpty) _etaText,
                ];
                if (parts.isEmpty) return const SizedBox(height: 2);
                return Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Center(
                    child: Text(
                      parts.join(' · '),
                      style: TextStyle(color: secondary, fontSize: 12.5),
                    ),
                  ),
                );
              },
            ),
          const SizedBox(height: 14),
          _PopupPrimaryButton(
            label: _done ? '完成' : (_cancelling ? '正在取消' : '取消下载'),
            onPressed: _done ? _close : _cancel,
          ),
        ],
      ),
    );
  }

  String _title() {
    if (_failed) return '${widget.title} · 下载中断';
    if (_done) return '${widget.title} · 已存到 JICUN';
    // 网络收完到相册可见之间还有一步:把文件整个搬进媒体库(见 MainActivity.publish,
    // 那一步是本地读写,没有进度可报)。这段时间进度环钉在 99%,不给一句话用户只会
    // 觉得"卡死了"。
    if (_fraction >= 0.99) return '${widget.title} · 正在保存到相册';
    // 并发下载时没法说「第几个」——几条在同时下,说条数只会有误导
    if (widget.total > 1) return '${widget.title} · 共 ${widget.total} 个';
    return widget.title;
  }
}

// ────────────────────────── 版本更新 ──────────────────────────

/// 更新卡的预览窗口固定显示这么多行。多了就在右侧出滚动条。
///
/// 需求定的是"固定 12 行字":所以窗口高度按行高算死,不随内容长短变 —— 换个
/// release 说明就是一屏不一样高,卡片会跳。
const int _kNotesLines = 12;

/// 滚动条占的宽度(量文字宽度时要减掉)。
const double _kScrollbarGutter = 10;

/// 弹「版本更新」卡片。
///
/// [onUpdate]/[onIgnore] 由调用方决定做什么(下载安装 / 记住忽略的版本),卡片
/// 自己只管显示和把选择报回去。
Future<void> showUpdateCard(
  BuildContext context, {
  required ReleaseInfo release,
  required String currentVersion,
  required VoidCallback onUpdate,
  required VoidCallback onIgnore,
}) {
  return showCupertinoModalPopup<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: const Color(0x14000000),
    builder: (context) => _UpdateCard(
      release: release,
      currentVersion: currentVersion,
      onUpdate: onUpdate,
      onIgnore: onIgnore,
    ),
  );
}

/// 「版本更新」卡片:标题 + 版本号 + 说明预览(markdown)+ 底部左更新右忽略。
class _UpdateCard extends StatelessWidget {
  const _UpdateCard({
    required this.release,
    required this.currentVersion,
    required this.onUpdate,
    required this.onIgnore,
  });

  final ReleaseInfo release;
  final String currentVersion;
  final VoidCallback onUpdate;
  final VoidCallback onIgnore;

  void _close(BuildContext context) => Navigator.of(context).maybePop();

  /// 点「更新」:**先关卡片再办事**。
  ///
  /// 顺序不能反:下载进度窗口是在根 State 上弹的,而这张卡还占着弹层栈顶,反着来
  /// 会出现"进度窗口在更新卡下面"——用户只看到更新卡还在,以为按钮没反应。
  void _update(BuildContext context) {
    _close(context);
    onUpdate();
  }

  /// 点「忽略」:关卡片 + 记住这个版本(记住这件事由调用方做)。
  void _ignore(BuildContext context) {
    _close(context);
    onIgnore();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final (foreground: foreground, secondary: secondary) = _settingsPalette(
      isDark,
    );
    return _PopupShell(
      title: '版本更新',
      icon: _popupIcon(context, '下载进度.svg'),
      onClose: () => _close(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            currentVersion.isEmpty
                ? release.version
                : '$currentVersion → ${release.version}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: secondary, fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          _ReleaseNotesPreview(
            notes: release.notes,
            foreground: foreground,
            secondary: secondary,
            isDark: isDark,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              // 需求指定:左边更新、右边忽略
              Expanded(
                child: _PopupPrimaryButton(
                  label: '更新',
                  onPressed: () => _update(context),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _PopupSecondaryButton(
                  label: '忽略',
                  onPressed: () => _ignore(context),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// release 说明的预览窗口:固定 12 行高,内容超了就出滚动条。
///
/// 高度不是"大概 12 行":按 [TextStyle.height] 把行高算死 × 12,再用 [TextPainter]
/// 量一遍真实高度决定挂不挂滚动条 —— 内容不到 12 行时不挂,挂上去会在右边留一条
/// 没东西可滚的槽。
class _ReleaseNotesPreview extends StatelessWidget {
  const _ReleaseNotesPreview({
    required this.notes,
    required this.foreground,
    required this.secondary,
    required this.isDark,
  });

  final String notes;
  final Color foreground;
  final Color secondary;
  final bool isDark;

  /// 行高系数。三档样式都用它,行距才一致(标题字大一些,行高按比例跟着大)。
  static const double _heightFactor = 1.55;

  static const double _baseFontSize = 13;

  /// 一行正文的高度。窗口高度和溢出判断都用它。
  static const double _lineHeight = _baseFontSize * _heightFactor;

  /// 内容左右留白:滚动条要占位置,不留就会压在字上。
  static const double _horizontalPadding = 10;

  static const double _verticalPadding = 10;

  TextStyle _styleFor(MdLineKind kind, {required bool empty}) {
    switch (kind) {
      case MdLineKind.heading:
        return TextStyle(
          color: foreground,
          fontSize: 14,
          height: _heightFactor,
          fontWeight: FontWeight.w600,
        );
      case MdLineKind.code:
        return TextStyle(
          color: secondary,
          fontSize: 12,
          height: _heightFactor,
          fontFamily: 'monospace',
        );
      case MdLineKind.body:
        return TextStyle(
          // 空行只是撑高度,颜色无所谓
          color: empty ? secondary : foreground,
          fontSize: _baseFontSize,
          height: _heightFactor,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = parseMarkdown(notes);
    if (lines.isEmpty) {
      // 说明是空的:给一句占位,别给用户看一个空窗口
      return SizedBox(
        height: _lineHeight * _kNotesLines,
        child: Align(
          alignment: Alignment.topLeft,
          child: Text(
            '这个版本没有写说明。',
            style: TextStyle(color: secondary, fontSize: _baseFontSize),
          ),
        ),
      );
    }

    final maxHeight = _lineHeight * _kNotesLines;
    // 半像素余量:行高是算出来的,和布局引擎里的实际值差一点点;刚好 12 行时
    // 不该被判成"超了"而多出一条滚动条。
    final scrollable =
        _measure(
          lines,
          MediaQuery.sizeOf(context),
          MediaQuery.textScalerOf(context),
        ) >
        maxHeight + 0.5;

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _horizontalPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final line in lines)
            Text(
              line.prefix.isEmpty ? line.text : '${line.prefix}${line.text}',
              style: _styleFor(line.kind, empty: line.text.isEmpty),
            ),
        ],
      ),
    );

    return Container(
      height: maxHeight,
      decoration: BoxDecoration(
        // 比卡片底色再压一层:预览窗口和卡片本体的边界就出来了,不用画线
        color: isDark ? const Color(0x1A000000) : const Color(0x0D000000),
        borderRadius: BorderRadius.circular(12),
      ),
      child: scrollable
          // 滚动条常显:窗口里明明还有内容,不显示的话用户不知道能往上拖
          ? Scrollbar(
              thumbVisibility: true,
              thickness: 3,
              radius: const Radius.circular(2),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: _verticalPadding),
                child: content,
              ),
            )
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: _verticalPadding),
              child: content,
            ),
    );
  }

  /// 把每一行按实际排版宽度量一遍,加起来就是整块内容的高度。
  ///
  /// 不能用 `maxLines: 12` 糊弄过去:那样量不出"到底超没超",而滚动条要按这个
  /// 判断挂不挂。
  double _measure(List<MdLine> lines, Size screen, TextScaler scaler) {
    // 滚动条和左右留白都要减掉,否则量出来的宽度比实际排版宽度大,行数会少算
    final width =
        screen.width -
        24 * 2 - // 弹层左右各 24
        14 * 2 - // 卡片内边距
        _horizontalPadding * 2 -
        _kScrollbarGutter;
    var total = 0.0;
    for (final line in lines) {
      final painter = TextPainter(
        text: TextSpan(
          text: line.prefix.isEmpty ? line.text : '${line.prefix}${line.text}',
          style: _styleFor(line.kind, empty: line.text.isEmpty),
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(maxWidth: width > 0 ? width : 200);
      total += painter.height;
    }
    return total;
  }
}

/// 更新包下载进度窗口。
///
/// 和媒体下载那张卡同一套骨架,区别只有三处:进度按**百分比**报(需求要的)、
/// 失败时在卡里留一句原因、下完之后不是"已存到相册"而是交给系统安装器。
Future<void> showApkDownloadCard(
  BuildContext context, {
  required String title,
  required String subtitle,
  required ApkDownloadController controller,
}) {
  return showCupertinoModalPopup<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: const Color(0x14000000),
    builder: (context) => _ApkDownloadCard(
      title: title,
      subtitle: subtitle,
      controller: controller,
    ),
  );
}

/// 更新下载的控制权。
///
/// 下载不是这张卡发起的(卡只负责显示),所以进度、取消、失败都由外面推进来 ——
/// 用一个小对象当"遥控器",比把整条下载逻辑塞进卡里清楚。
class ApkDownloadController extends ChangeNotifier {
  ApkProgress _progress = const ApkProgress(received: 0, total: 0);
  bool _cancelled = false;
  bool _closed = false;
  String? _error;

  ApkProgress get progress => _progress;
  bool get cancelled => _cancelled;
  bool get closed => _closed;
  String? get error => _error;
  bool get failed => _error != null;

  void report(ApkProgress value) {
    _progress = value;
    notifyListeners();
  }

  /// 用户点了「取消更新」。下载循环会看到 [cancelled]。
  void cancel() {
    _cancelled = true;
    notifyListeners();
  }

  void fail(String message) {
    _error = message;
    notifyListeners();
  }

  /// 收窗口(取消收尾完成 / 安装器已经拉起)。
  void close() {
    _closed = true;
    notifyListeners();
  }
}

class _ApkDownloadCard extends StatefulWidget {
  const _ApkDownloadCard({
    required this.title,
    required this.subtitle,
    required this.controller,
  });

  final String title;
  final String subtitle;
  final ApkDownloadController controller;

  @override
  State<_ApkDownloadCard> createState() => _ApkDownloadCardState();
}

class _ApkDownloadCardState extends State<_ApkDownloadCard> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    super.dispose();
  }

  void _onController() {
    if (!mounted) return;
    // 外面说"收窗口"(取消收尾完成 / 安装器已拉起)就关掉自己
    if (widget.controller.closed) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {});
  }

  void _close() {
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final (foreground: foreground, secondary: secondary) = _settingsPalette(
      isDark,
    );
    final controller = widget.controller;
    final failed = controller.failed;
    final done = controller.progress.fraction >= 1 && !failed;
    final percent = (controller.progress.fraction * 100).floor();

    return _PopupShell(
      title: widget.title,
      icon: _popupIcon(context, '下载进度.svg'),
      onClose: _close,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            failed
                ? '下载没完成'
                : done
                ? '下载完成,正在安装'
                : widget.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: secondary, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          Center(
            child: _ProgressRing(
              progress: controller.progress.fraction,
              failed: failed,
              isDark: isDark,
              diameter: 112,
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              failed ? '—' : '$percent%',
              style: TextStyle(
                color: foreground,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (failed) ...[
            const SizedBox(height: 6),
            Text(
              controller.error ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(color: secondary, fontSize: 12),
            ),
          ],
          const SizedBox(height: 14),
          _PopupPrimaryButton(
            label: failed
                ? '关闭'
                : done
                ? '完成'
                : '取消更新',
            onPressed: failed || done ? _close : controller.cancel,
          ),
        ],
      ),
    );
  }
}

/// 下载进度环:谷歌 Play 那种波浪圆环。
///
/// - 整圈浅色底,进度从 12 点整顺时针扫过,弧线是滚动的波浪(见 [_RingPainter]);
/// - 圆心是**加粗百分比**,和弧的进度严格同一个值;
/// - 下完(100%)时波浪闭合、不再爬,圆心换成蓝渐变波浪徽章加白勾(见 [_ScallopBadge]);
/// - 失败时圆心换成红渐变波浪徽章加白叉。
class _ProgressRing extends StatefulWidget {
  const _ProgressRing({
    required this.progress,
    required this.failed,
    required this.isDark,
    this.diameter = defaultDiameter,
  });

  /// 0~1。
  final double progress;
  final bool failed;
  final bool isDark;

  /// 圆环外径。整张卡收小之后环也跟着收;更新卡里还要再小一点(卡片更矮)。
  final double diameter;

  static const double defaultDiameter = 128;

  /// 画法的基准直径:[_RingPainter] 里的半径/线宽都是按 176 定的,
  /// 实际画的时候整块画布按 `diameter / 176` 缩放,这样只有一处尺寸可调。
  static const double designDiameter = 176;

  /// 波浪徽章盘面的直径(设计基准里)。徽章要**深深压到进度环的笔触下面**:
  /// 环笔触内缘 63、外缘 77(半径 70、半线宽 7),徽章半径取 70、起伏 5.5%,
  /// 浪谷 66、浪峰 74 —— 全程藏在笔触底下 3 个单位以上,抗锯齿也吃不穿,
  /// 缝里不可能露卡片底。相位和环对不对得上都无所谓,反正看不见交界。
  static const double badgeDiameter = 140;

  @override
  State<_ProgressRing> createState() => _ProgressRingState();
}

class _ProgressRingState extends State<_ProgressRing>
    with TickerProviderStateMixin {
  /// 显示用的进度。数据一段一段来,直接画会一跳一跳;补间到目标值就顺了。
  late double _shown = widget.progress;

  /// 100% 时对勾那一下弹出来。
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  /// 波浪的相位。走完 1.0 = 浪前进一个波长,所以 1 秒正好是谷歌的
  /// waveSpeed 默认值(每秒一个波长)。再快就显得躁。
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void initState() {
    super.initState();
    if (widget.progress >= 1 || widget.failed) _pop.value = 1;
    _syncWave();
  }

  @override
  void didUpdateWidget(_ProgressRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    setState(() => _shown = widget.progress);
    if (widget.progress >= 1 && oldWidget.progress < 1) _pop.forward(from: 0);
    if (widget.failed && !oldWidget.failed) _pop.forward(from: 0);
    if (widget.progress < 1 && oldWidget.progress >= 1) _pop.value = 0;
    _syncWave();
  }

  /// 只有「还在下」的时候波浪才转:下完/失败还转着,看着像没结束。
  void _syncWave() {
    final running = widget.progress < 1 && !widget.failed;
    if (running && !_wave.isAnimating) {
      _wave.repeat();
    } else if (!running && _wave.isAnimating) {
      _wave.stop();
    }
  }

  @override
  void dispose() {
    _pop.dispose();
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final done = _shown >= 1 && !widget.failed;
    final scale = widget.diameter / _ProgressRing.designDiameter;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: _shown),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      builder: (context, value, _) => SizedBox(
        width: widget.diameter,
        height: widget.diameter,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 圆心先画、圆环后画:完成/失败的徽章盘面要压进环的笔触底下,
            // 缝里才不露卡片底。下载中圆心只是百分比文字,环盖不盖它都一样。
            _center(value, done, scale),
            CustomPaint(
              size: Size.square(widget.diameter),
              painter: _RingPainter(
                scale: scale,
                progress: done ? 1 : value,
                phase: _wave,
                arcColor: widget.failed
                    ? const Color(0xFFE5484D)
                    : const Color(0xFF2F6BFF),
                // 底圈要看得见又不抢戏:太淡了整圈像没画,太重了分不出哪段是进度
                trackColor:
                    (widget.isDark
                            ? const Color(0xFFFFFFFF)
                            : const Color(0xFF1B2430))
                        .withValues(alpha: 0.22),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 圆心:没下完是加粗百分比,下完是蓝渐变波浪徽章加白勾,失败是红渐变徽章加白叉。
  Widget _center(double value, bool done, double scale) {
    final failed = widget.failed;
    final percent = '${(value * 100).round()}%';
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      child: (done || failed)
          ? ScaleTransition(
              key: ValueKey(done ? 'done' : 'failed'),
              scale: CurvedAnimation(parent: _pop, curve: Curves.elasticOut),
              child: _ScallopBadge(scale: scale, failed: failed),
            )
          : Text(
              percent,
              key: const ValueKey('percent'),
              style: TextStyle(
                // 卡片底色是磨砂浅色,百分比用深色才看得清;
                // 深色模式的卡片底是深灰,写白色。
                color: widget.isDark
                    ? const Color(0xFFFFFFFF)
                    : const Color(0xFF12203A),
                fontSize: 28 * scale,
                fontWeight: FontWeight.w700,
              ),
            ),
    );
  }
}

/// 完成/失败的波浪徽章:谷歌 Play 下载完成那种边缘起伏的圆盘。
///
/// - 边缘是正弦起伏的闭合圆(14 道浪,和外圈进度环同数,看着是一家人),
///   起伏约半径的 7%,和参考图里那圈圆润的波浪同量级;
/// - 盘面**藏进进度环的笔触底下**(见 [badgeDiameter]),和环叠在一起才是一整块,
///   中间没有任何露底的缝;
/// - 盘面渐变和进度弧**同一配方**(深 → 亮,横向),叠放处色调连得上;
///   完成走品牌蓝,失败走红;
/// - 中央符号是粗白勾 / 粗白叉,和参考图同字重。
class _ScallopBadge extends StatelessWidget {
  const _ScallopBadge({required this.scale, required this.failed});

  final double scale;
  final bool failed;

  /// 边缘起伏的瓣数。12 瓣 + 小起伏 = 圆润的花瓣,瓣数越多齿越尖
  /// (斜率 ≈ 瓣数 × 起伏,之前 14 瓣 × 7% 真机上像齿轮)。
  /// 和外圈进度环瓣数不一样没关系:交界藏在环底下,看不见。
  static const int lobes = 12;

  /// 起伏幅度占半径的比例。5.5% 配 12 瓣,圆润和参考图同量级。
  static const double ripple = 0.055;

  @override
  Widget build(BuildContext context) {
    final base = failed
        ? const Color(0xFFE5484D)
        : const Color(0xFF2F6BFF);
    // 和进度弧同一配方(见 _RingPainter 的 shader):徽章压在环底下,
    // 配方不一致的话叠放处会断色。
    const deep = Color(0xFF001F6B);
    const light = Color(0xFFFFFFFF);
    final d = _ProgressRing.badgeDiameter * scale;
    return SizedBox(
      width: d,
      height: d,
      child: CustomPaint(
        painter: _ScallopFill(
          stops: <Color>[
            Color.lerp(base, deep, 0.45)!,
            Color.lerp(base, light, 0.15)!,
          ],
        ),
        foregroundPainter: failed
            ? const _CrossPainter(color: Color(0xFFFFFFFF))
            : const _CheckPainter(color: Color(0xFFFFFFFF)),
      ),
    );
  }
}

/// 波浪徽章的盘面:起伏圆填渐变。
class _ScallopFill extends CustomPainter {
  const _ScallopFill({required this.stops});

  /// 对角渐变的上、下两档(见 [_ScallopBadge])。
  final List<Color> stops;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final center = Offset(size.width / 2, size.height / 2);
    final path = Path();
    const step = math.pi / 180;
    for (var deg = 0; deg <= 360; deg++) {
      final angle = deg * step;
      final rr =
          r *
          (1 +
              _ScallopBadge.ripple *
                  math.sin(_ScallopBadge.lobes * angle));
      final point = Offset(
        center.dx + rr * math.sin(angle),
        center.dy - rr * math.cos(angle),
      );
      if (deg == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    // 横向渐变,和进度弧的 shader 同方向同配方:徽章压在环底下,
    // 两边的色调在叠放处连得上,不会断色。
    canvas.drawPath(
      path,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, size.height / 2),
          Offset(size.width, size.height / 2),
          stops,
        ),
    );
  }

  @override
  bool shouldRepaint(_ScallopFill old) => old.stops != stops;
}

/// 徽章中央符号的线宽 = 盘子直径的这个比例。勾和叉共用:15% 已经挺粗了,
/// 再粗折角就开始糊在一起。
const double _badgeGlyphStrokeRatio = 0.15;

/// 失败徽章里的白叉,和 [_CheckPainter] 同字重。
class _CrossPainter extends CustomPainter {
  const _CrossPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * _badgeGlyphStrokeRatio
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawLine(Offset(s * 0.32, s * 0.32), Offset(s * 0.68, s * 0.68), paint);
    canvas.drawLine(Offset(s * 0.68, s * 0.32), Offset(s * 0.32, s * 0.68), paint);
  }

  @override
  bool shouldRepaint(_CrossPainter old) => old.color != color;
}

/// 波浪徽章里那个白对勾(见 [_ScallopBadge])。
///
/// 不用图标字体:`CupertinoIcons.check_mark` 的字重是定死的,要「又大又粗」
/// 只能自己画。折线按 0~1 的相对坐标定,盘子多大都合用。
class _CheckPainter extends CustomPainter {
  const _CheckPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 起笔在左下、拐到中下、甩到右上:标准的对勾三段折线
    final path = Path()
      ..moveTo(size.width * 0.24, size.height * 0.52)
      ..lineTo(size.width * 0.42, size.height * 0.70)
      ..lineTo(size.width * 0.76, size.height * 0.32);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.shortestSide * _badgeGlyphStrokeRatio
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.color != color;
}

/// 波浪进度环的画笔 —— 谷歌 Play 商店下载中围着图标那圈「皱起来的圆环」
/// (Material 3 Expressive 的 wavy circular progress)。
///
/// - **底圈**和**进度**走同一条波浪:半径在 半径 ± 浪高 之间按正弦起伏。
///   波形只跟**角度**有关(`sin(浪数 × 角度 + 相位 × 2π)`),所以任何一段弧
///   的浪都落在同一处 —— 底圈和进度上的浪对得上,进度长出来时波形也不变形;
/// - 浪数取整、按**整圈**定死:波长不会随进度变,100% 时首尾严丝合缝闭合;
/// - 进度和底圈之间留一小段**缺口**(谷歌的 gapSize,默认 4dp),
///   看着是两段线而不是一整条;
/// - 相位一秒走一个波长(谷歌 waveSpeed 的默认值就是「每秒一个波长」)。
///
/// 比例是照参考抄的:细线(约 4dp)、浪高跟线宽同量级、波长约 20dp。
/// 之前那版线宽 20、整圈 20 道浪,浪比线还密,看着像毛毛虫 —— 谷歌不是那么画的。
class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.scale,
    required this.progress,
    required this.phase,
    required this.arcColor,
    required this.trackColor,
  }) : super(repaint: phase);

  /// 画布缩放:下面的半径/线宽都按 176 的基准定,乘上它才是实际尺寸。
  final double scale;

  final double progress;

  /// 波浪相位(0~1 循环)。挂成 [repaint] 的 listenable:相位往前走不用
  /// 重建 widget,只重画这一层。
  final Animation<double> phase;

  final Color arcColor;
  final Color trackColor;

  /// 圆环中心线半径、线宽、浪高。都按 176 的基准定。
  ///
  /// 浪高 4:浪太高齿就尖了,参考图里是圆润的起伏。斜率 ≈ 浪高 × 浪数 ÷ 半径,
  /// 取 0.8 左右齿形圆,之前 5.5 那版斜率 1.1,真机上看着像齿轮。
  static const double _radius = 70;
  static const double _stroke = 14;
  static const double _amplitude = 4;

  /// 整圈的浪数。整数:整圈才闭得上。14 道 = 176 基准下 31 个单位一个波长,
  /// 换成 dp 约 23dp —— 和谷歌那支波浪进度条的波长同量级。
  static const int _waves = 14;

  /// 进度和底圈之间的缺口(按中心线量)。谷歌默认 4dp,这里取同量级。
  static const double _gapLength = 6.5;

  @override
  void paint(Canvas canvas, Size size) {
    // 半径常量按 176 的基准定:先把画布缩到实际尺寸,圆心要换算回基准坐标系,
    // 否则会按实际尺寸算一半、再被缩放一次,整个环偏到左上。
    canvas.scale(scale);
    final center = Offset(size.width / scale / 2, size.height / scale / 2);

    final clamped = progress.clamp(0.0, 1.0);
    final sweep = 2 * math.pi * clamped;
    // 缺口换算成圆心角:弧长 ÷ 半径
    final gap = _gapLength / _radius;

    Paint strokePaint(Color color) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..color = color;

    Path wave(double from, double to) => waveArcPath(
      center: center,
      radius: _radius,
      amplitude: _amplitude,
      startAngle: from,
      endAngle: to,
      phase: phase.value,
      waves: _waves,
    );

    // 底圈:从进度末端(让出一个缺口)铺到 12 点前(再让出一个缺口)。
    // 进度下满时这段自然为空,整圈都归进度。
    final trackFrom = sweep + gap;
    final trackTo = 2 * math.pi - gap;
    if (trackFrom < trackTo) {
      canvas.drawPath(wave(trackFrom, trackTo), strokePaint(trackColor));
    }

    if (clamped <= 0) return;

    canvas.drawPath(
      wave(0, sweep),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeCap = StrokeCap.round
        ..shader = ui.Gradient.linear(
          Offset(center.dx - _radius, center.dy),
          Offset(center.dx + _radius, center.dy),
          <Color>[
            // 深到浅的蓝:深浅两头都压得住底色,弧才明显
            Color.lerp(arcColor, const Color(0xFF001F6B), 0.45)!,
            Color.lerp(arcColor, const Color(0xFFFFFFFF), 0.15)!,
          ],
        ),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.scale != scale ||
      old.progress != progress ||
      old.arcColor != arcColor ||
      old.trackColor != trackColor;
}

/// 波浪弧的采样点,连成一条折线。
///
/// 角度从 **12 点整**起算、顺时针为正,[startAngle] / [endAngle] 是弧度。
/// 半径 = [radius] + [amplitude] × sin([waves] × 角度 + [phase] × 2π):
/// 波形只跟角度有关,所以同一条圆上任意两段弧在角度重叠处浪的位置一致 ——
/// 底圈和进度的浪才对得上,进度长出来时波形也不会变形。浪数取整时整圈闭合。
///
/// 采样步长 1°:一圈 360 段,每段远小于线宽,看着就是光滑的浪,比推贝塞尔省事。
Path waveArcPath({
  required Offset center,
  required double radius,
  required double amplitude,
  required double startAngle,
  required double endAngle,
  required double phase,
  required int waves,
}) {
  const double step = math.pi / 180;
  final span = endAngle - startAngle;
  final steps = math.max(2, (span / step).ceil());
  final path = Path();
  for (var i = 0; i <= steps; i++) {
    final angle = startAngle + span * i / steps;
    final r =
        radius + amplitude * math.sin(waves * angle + phase * 2 * math.pi);
    // 0 度在 12 点整,角度顺着表针长
    final point = Offset(
      center.dx + r * math.sin(angle),
      center.dy - r * math.cos(angle),
    );
    if (i == 0) {
      path.moveTo(point.dx, point.dy);
    } else {
      path.lineTo(point.dx, point.dy);
    }
  }
  return path;
}

// ────────────────────────── 弹层共用件 ──────────────────────────

/// 所有弹层的统一外壳:糊一层背景 + 玻璃面板 + 头部一行。
///
/// 四张弹层卡(媒体下载进度、版本更新、更新包下载、提示与授权)原来各自抄了一遍这段
/// 骨架,抄着抄着就分了家:提示弹窗没铺底色、标题居中、主按钮自己的配色,
/// 「需要安装权限」更是直接用了 CupertinoAlertDialog(iOS 灰底 + 细分割线),搁在满屏
/// 毛玻璃里像另一个 APP 的弹窗。统一走这里之后,弹层之间不可能再走样。
class _PopupShell extends StatelessWidget {
  const _PopupShell({
    required this.title,
    required this.icon,
    required this.child,
    this.onClose,
    this.maxWidth = 300,
  });

  final String title;

  /// 完整资源路径(用 [_settingsIcon] / [_popupIcon] 拼)。
  final String icon;

  /// 头部右侧的关闭叉。null = 不给叉:必须点下面的按钮才能走。
  final VoidCallback? onClose;

  /// 面板最大宽度。普通提示卡 300 够用;大图预览要更宽,见 [_ImageViewerDialog]。
  final double maxWidth;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final (foreground: foreground, secondary: secondary) = _settingsPalette(
      isDark,
    );
    return Stack(
      children: [
        Positioned.fill(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: const ColoredBox(color: Color(0x00000000)),
          ),
        ),
        Padding(
          // 底部留一点,弹层贴着屏幕边缘不好看
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              // 玻璃面板**不自己铺底**:它直接透过上面那层模糊采样页面本身。
              //
              // 原来这里铺了一整屏 _ThemeBackground(为了和页面同色),结果是两件事
              // 一起坏:
              // 1. 割裂 —— 卡片里透出来的是"重新画了一遍、没被糊过"的渐变,而卡片
              //    外面是被模糊+压暗的页面,同一屏两套明度,边上就是一条缝;
              // 2. 白花帧 —— 浅色模式那层是 _LightThemeBackgroundPainter:整屏三次
              //    drawRect,带 BlendMode.overlay / screen 和一个径向渐变。它叠在
              //    12 sigma 的整屏模糊底下,弹层每帧都要重算一遍,换来的只是上面
              //    那条缝。
              //
              // 弹层底下本来就只有页面自己,方向键上下滚也不会跑到别的地方去,
              // 所以直接采样即可 —— _GlassPanel 本来就没有铺底这个参数,弹层的
              // 调用方也都不自己铺垫。
              child: _GlassPanel(
                isDark: isDark,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 11, 14, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          TintedSvgIcon(icon, size: 20, color: foreground),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: foreground,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (onClose != null)
                            CupertinoButton(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(28, 28),
                              onPressed: onClose,
                              child: Icon(
                                CupertinoIcons.xmark,
                                size: 18,
                                color: secondary,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      child,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 弹层淡入的时长。
///
/// 系统那条(`showCupertinoDialog`)是 250ms 起步的弹簧。点一下就开的东西不该等
/// 半拍 —— 尤其点图片缩略图那只眼睛的时候,眼睛是个小目标,点完视线立刻落在弹层上。
const Duration _kGlassDialogFade = Duration(milliseconds: 180);

/// 玻璃弹层走的路由。
///
/// 和 `showCupertinoDialog` 用的那条比,只动时间:
///
/// - **遮蔽先到位**。系统那条路由把遮蔽和面板绑在同一条动画上,遮蔽的曲线是
///   `Curves.ease` —— 走到后半程还剩一截,面板已经压上来了、身后那片变暗还在慢慢爬,
///   看着就是"遮蔽慢半拍"。这里让它在前 40% 就铺满(180ms 的动画里约 70ms),
///   面板还在淡入时后面已经黑透了。
/// - 整个入场短一档,见 [_kGlassDialogFade]。
class _GlassDialogRoute<T> extends RawDialogRoute<T> {
  _GlassDialogRoute({required WidgetBuilder builder, required Color barrierColor})
    : super(
        pageBuilder: (context, _, _) => builder(context),
        barrierColor: barrierColor,
        barrierDismissible: true,
        // 点背景也是关掉的一条路,这句是读屏要念的
        barrierLabel: '关闭',
        transitionDuration: _kGlassDialogFade,
        transitionBuilder: (context, animation, _, child) => FadeTransition(
          opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
          child: child,
        ),
      );

  /// 遮蔽在动画的前这么多(0~1)铺满,不跟着面板慢慢爬。
  static const double barrierLead = 0.4;

  @override
  Curve get barrierCurve => const Interval(0, barrierLead, curve: Curves.easeOut);
}

/// 开一块玻璃弹层。全 App 的弹层都走这一条 —— 骨架是 [_PopupShell],路由见
/// [_GlassDialogRoute]。
///
/// 挂 root navigator(和 [showCupertinoDialog] 一样):弹层要盖住玻璃底栏,挂在
/// 当前页的 navigator 上会从底栏底下钻出来。
Future<T?> _showGlassLayer<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  return Navigator.of(context, rootNavigator: true).push<T>(
    _GlassDialogRoute<T>(
      builder: builder,
      // 系统那条用的同一个遮罩色:浅色 20% 黑、深色 48% 黑,跟着当前主题走
      barrierColor: CupertinoDynamicColor.resolve(
        kCupertinoModalBarrierColor,
        context,
      ),
    ),
  );
}

/// 弹层里的主按钮(确认 / 更新 / 一键授权 / 完成 / 取消)。
///
/// 颜色不取 ColorScheme:弹层挂在 CupertinoApp 那棵树下面,拿不到二级页的种子色,
/// 每个弹窗各写一遍 styleFrom 又必然走样 —— 所以整条配色只留这一份。
class _PopupPrimaryButton extends StatelessWidget {
  const _PopupPrimaryButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    return FilledButton(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(40),
        backgroundColor: isDark
            ? const Color(0x1FFFFFFF)
            : const Color(0x141257C9),
        foregroundColor: isDark
            ? const Color(0xFF5AA9FF)
            : const Color(0xFF1257C9),
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// 弹层里的次按钮(忽略 / 稍后)。和主按钮并排时放右边。
class _PopupSecondaryButton extends StatelessWidget {
  const _PopupSecondaryButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final secondary = _settingsPalette(isDark).secondary;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(40),
        foregroundColor: secondary,
        side: BorderSide(color: secondary.withValues(alpha: 0.35)),
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// 弹一句提示用的玻璃卡。
///
/// 骨架就是 [_PopupShell]:和「版本更新」「下载进度」同一块面板、同一行头部,所以
/// 检查更新的回音和更新卡摆在一起不会像两个 APP。
///
/// 返回值:点了主按钮为真,点了右上角的叉为假。
Future<bool> _showGlassDialog(
  BuildContext context, {
  required String title,
  required String body,
  String? icon,
  String primaryLabel = '知道了',
}) async {
  final result = await _showGlassLayer<bool>(
    context,
    builder: (context) => _GlassDialog(
      title: title,
      body: body,
      icon: icon,
      primaryLabel: primaryLabel,
    ),
  );
  return result ?? false;
}

/// 统一的轻提示。内容是 [_GlassDialog],弹层的路由与遮罩见 [_GlassDialogRoute]。
void _showInfo(
  BuildContext context,
  String title,
  String body, {
  String? icon,
}) {
  unawaited(_showGlassDialog(context, title: title, body: body, icon: icon));
}

class _GlassDialog extends StatelessWidget {
  const _GlassDialog({
    required this.title,
    required this.body,
    required this.primaryLabel,
    this.icon,
  });

  final String title;
  final String body;
  final String primaryLabel;
  final String? icon;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final foreground = _settingsPalette(isDark).foreground;
    return _PopupShell(
      title: title,
      // 没点名要哪张图就用「检查更新」:用上这个弹窗的地方多半和检查更新有关
      icon: icon ?? _settingsIcon(context, '检查更新.svg'),
      onClose: () => Navigator.of(context).pop(false),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            body,
            style: TextStyle(color: foreground, fontSize: 13.5, height: 1.45),
          ),
          const SizedBox(height: 14),
          _PopupPrimaryButton(
            label: primaryLabel,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
  }
}

/// 下载前先问一句「要哪一档清晰度」。
///
/// **只在第二个上游(有分辨率列表)解析成功时才会出现**:media-parser 的结果里
/// 根本没有 [VideoQuality],传进来就是空列表,调用方也就不该开这个弹窗。
///
/// 返回用户选中的那一档;点右上角的叉返回 null,调用方据此取消这次下载。
///
/// 两个要点:
/// - 列表里同一档分辨率只会出现一次 —— 去重在上游映射那一步就做完了
///   (见 parse_service.dart 的 dedupeQualities),这里只管显示;
/// - 不预选任何一项。默认选中会让用户顺手点「确定」下到一档他没看过的清晰度,
///   而下载是几十上百 MB 的事,值得让他自己点一下。
Future<VideoQuality?> showQualityPicker(
  BuildContext context, {
  required List<VideoQuality> qualities,
}) => _showGlassLayer<VideoQuality>(
  context,
  builder: (context) => _QualityPickerDialog(qualities: qualities),
);

class _QualityPickerDialog extends StatelessWidget {
  const _QualityPickerDialog({required this.qualities});

  final List<VideoQuality> qualities;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final (foreground: foreground, secondary: secondary) = _settingsPalette(
      isDark,
    );
    return _PopupShell(
      title: '选择清晰度',
      // 用首页板块那套图标:`下载媒体.svg` 只在「浅色/深色模式首页板块22x22-SVG/」
      // 里,设置板块那套没有它。写成 _settingsIcon 会抛
      // "Unable to load asset: 深色主题（设置板块选项图标）/下载媒体.svg" ——
      // 弹窗照常显示,但控制台每次刷一屏未捕获异常(真机实测)。
      icon: _homeIcon(context, '下载媒体.svg'),
      onClose: () => Navigator.of(context).pop(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 屏小的机器上档位可能占掉大半个屏幕,这里限高并允许滚动。
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: qualities.length,
              separatorBuilder: (_, _) => Container(
                height: 1,
                color: secondary.withValues(alpha: 0.16),
              ),
              itemBuilder: (context, index) {
                final q = qualities[index];
                return _QualityOptionRow(
                  quality: q,
                  isDark: isDark,
                  foreground: foreground,
                  secondary: secondary,
                  onPressed: () => Navigator.of(context).pop(q),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 清晰度列表里的一行:左边档位名,右边码率/体积。
class _QualityOptionRow extends StatelessWidget {
  const _QualityOptionRow({
    required this.quality,
    required this.isDark,
    required this.foreground,
    required this.secondary,
    required this.onPressed,
  });

  final VideoQuality quality;
  final bool isDark;
  final Color foreground;
  final Color secondary;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // 认不出分辨率时给一句「默认画质」,别让这一行左边空着 —— 空标签看着像没加载完。
    final label = quality.label.isEmpty ? '默认画质' : quality.label;
    final detail = quality.detail;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (detail.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(detail, style: TextStyle(color: secondary, fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 系统通知现在允不允许。问不出来返回 null。
Future<bool?> _notificationsEnabled() async {
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
Future<bool> _requestNotificationPermission() async {
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

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.app});

  /// 二级页要改的是应用级状态(主题、底栏),所以直接持有根 State。
  final _LiquidGlassDemoState app;

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
      physics: const _ShortBounceScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, _kBoardHeaderTop, 20, 120),
      children: [
        const _BoardHeader(title: '设置'),
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
    _showInfo(context, title, '该设置项将在后续版本开放。');
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
      _settingsIcon(context, '${option.icon ?? option.title}.svg');

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final secondary = _settingsPalette(isDark).secondary;

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
          _GlassIconChip(isDark: isDark, asset: _iconPath(context)),
          const SizedBox(width: 14),
          Expanded(
            child: _CardHeadline(
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

    return _GlassPanel(isDark: isDark, child: content);
  }
}

class _NotificationManagementPage extends StatefulWidget {
  const _NotificationManagementPage({required this.app});

  /// 这两个开关下载流程要用,所以和「主题与外观」一样直接持有根 State。
  final _LiquidGlassDemoState app;

  @override
  State<_NotificationManagementPage> createState() =>
      _NotificationManagementPageState();
}

class _NotificationManagementPageState
    extends State<_NotificationManagementPage> {
  bool _isSending = false;

  _LiquidGlassDemoState get app => widget.app;

  /// 要一次通知权限。和首次授权卡走同一个实现,免得两处判断分家。
  Future<bool> _requestPermission() => _requestNotificationPermission();

  /// 拨一个下载通知开关。
  ///
  /// 打开前先要系统通知权限:没权限就别把开关点亮 —— 点亮了却弹不出通知,
  /// 用户只会以为是我们没做。关闭不需要权限,直接写。
  Future<void> _setNotify({required bool onDone, required bool value}) async {
    if (value) {
      final granted = await _requestPermission();
      if (!mounted) return;
      if (!granted) {
        _showInfo(
          context,
          '通知权限未开启',
          '请在系统设置中允许即存发送通知。',
          icon: _settingsIcon(context, '通知管理.svg'),
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
        _showInfo(
          context,
          '通知权限未开启',
          '请在系统设置中允许即存发送通知。',
          icon: _settingsIcon(context, '通知管理.svg'),
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
            physics: const _ShortBounceScrollPhysics(),
            padding: EdgeInsets.fromLTRB(20, headerBottom + 5, 20, 32),
            children: [
              _GlassPanel(
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
              _GlassPanel(
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
/// (_GlassPanel + _GoogleSwitchRow,同一张顶栏图):打开后,每次进入 APP
/// 都会把剪贴板首条链接自动填进输入栏并解析(见 `_maybeAutoPasteParse`)。
class _AutoPastePage extends StatelessWidget {
  const _AutoPastePage({required this.app});

  final _LiquidGlassDemoState app;

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
            physics: const _ShortBounceScrollPhysics(),
            padding: EdgeInsets.fromLTRB(20, headerBottom + 5, 20, 32),
            children: [
              _GlassPanel(
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
    return _GlassPanel(
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
/// [tutorial] 卡里默认收起,点一下才滑出来(见 [_Reveal])。
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
            physics: const _ShortBounceScrollPhysics(),
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
    return _GlassPanel(
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
    final (foreground: foreground, secondary: secondary) = _settingsPalette(
      isDark,
    );
    return _PlainTap(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: value));
        if (!context.mounted) return;
        // 和「复制文案」同一个回音弹窗,全 APP 一套
        _showInfo(context, '已复制', '$label:$value');
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
/// 伸缩(时长、曲线、箭头)与「主题与外观」那三张卡共用 [_Reveal] / [_RevealChevron],
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
    final secondary = _settingsPalette(isDark).secondary;

    return _GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PlainTap(
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
                            color: _settingsPalette(isDark).foreground,
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
                  _RevealChevron(expanded: _expanded, color: secondary),
                ],
              ),
            ),
          ),
          // 挂个 key 是为了测试能直接量这一块的高度:里面的 Text 被裁掉之后
          // 自己的 RenderBox 还是原尺寸,量不到「收起=0」。
          KeyedSubtree(
            key: ValueKey('platformTutorial.${info.name}'),
            child: _Reveal(
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
                physics: const _ShortBounceScrollPhysics(),
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
                      _showInfo(context, '已复制', '开源地址已复制到剪贴板。');
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
    final (foreground: foreground, secondary: secondary) = _settingsPalette(
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

    return _GlassPanel(
      isDark: isDark,
      child: onTap == null
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: line,
            )
          : _PlainTap(
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
                physics: const _ShortBounceScrollPhysics(),
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
    final (foreground: _, secondary: secondary) = _settingsPalette(isDark);
    return _GlassPanel(
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
/// 关键:背景必须由**全屏**的 _ThemeBackground 来画。直接用
/// CupertinoPageScaffold(child: _ThemeBackground(...)) 时,child 从导航栏下方
/// 才开始布局,于是顶部露出 scaffold 的纯色 #CDDCDC,而且 _ThemeBackground 里
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
              child: _ThemeBackground(
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
enum _ThemeMode { system, light, dark }

/// 「系统主题」卡:收起时只有一行(标题 + 当前值 + 向下箭头),点箭头向下滑出
/// 三个选项;选完自己回弹收起。
///
/// 展开态是纯界面状态,所以留在本组件里 —— 每次进二级页都从收起开始。
class _ThemeModeCard extends StatefulWidget {
  const _ThemeModeCard({required this.app, required this.isDark});

  final _LiquidGlassDemoState app;
  final bool isDark;

  @override
  State<_ThemeModeCard> createState() => _ThemeModeCardState();
}

class _ThemeModeCardState extends State<_ThemeModeCard> {
  static const List<(_ThemeMode, String)> _options = [
    (_ThemeMode.system, '跟随系统'),
    (_ThemeMode.light, '浅色'),
    (_ThemeMode.dark, '深色'),
  ];

  bool _expanded = false;

  String get _currentLabel =>
      _options.firstWhere((o) => o.$1 == widget.app._themeMode).$2;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final secondary = _settingsPalette(isDark).secondary;

    return _GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PlainTap(
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
                  _RevealChevron(expanded: _expanded, color: secondary),
                ],
              ),
            ),
          ),
          _Reveal(
            expanded: _expanded,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: RadioGroup<_ThemeMode>(
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
                      _GoogleChoiceRow<_ThemeMode>(
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

  final _LiquidGlassDemoState app;

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
            physics: const _ShortBounceScrollPhysics(),
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
/// 点开向下滑出,见 [_Reveal])。
class _BarAppearanceCard extends StatefulWidget {
  const _BarAppearanceCard({required this.app, required this.isDark});

  final _LiquidGlassDemoState app;
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
    final secondary = _settingsPalette(isDark).secondary;

    return _GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PlainTap(
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
                  _RevealChevron(expanded: _expanded, color: secondary),
                ],
              ),
            ),
          ),
          _Reveal(
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

  final _LiquidGlassDemoState app;
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
    final secondary = _settingsPalette(isDark).secondary;
    return _GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PlainTap(
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
                  _RevealChevron(expanded: _expanded, color: secondary),
                ],
              ),
            ),
          ),
          _Reveal(
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
/// 卡片本身与一级设置列表同一种毛玻璃(见 _GlassPanel),这里只负责控件配色:
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
class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.isDark, required this.child});

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

/// 前景/次要文字色。一级列表与二级页共用同一套,两级观感才不会分家。
({Color foreground, Color secondary}) _settingsPalette(bool isDark) => (
  foreground: isDark ? const Color(0xFFF5F7FA) : const Color(0xFF1B2430),
  secondary: isDark ? const Color(0xFFADB7C5) : const Color(0xFF6E7887),
);

class _GoogleCardTitle extends StatelessWidget {
  const _GoogleCardTitle({required this.isDark, required this.text});

  final bool isDark;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: _settingsPalette(isDark).foreground,
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
    final (foreground: foreground, secondary: secondary) = _settingsPalette(
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
class _PlainTap extends StatelessWidget {
  const _PlainTap({required this.onTap, required this.child});

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
    final (foreground: foreground, secondary: secondary) = _settingsPalette(
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
    return _PlainTap(
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
                color: _settingsPalette(isDark).foreground,
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
