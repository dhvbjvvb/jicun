import 'package:flutter/cupertino.dart';

import 'dart:async';
// 进度环的渐变要 ui.Gradient.linear:widgets 里的 Gradient 是另一套东西
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable, kDebugMode;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bench.dart';
import 'bootstrap.dart';
import 'cover_cache.dart';
import 'downloader.dart';
import 'history_store.dart';
import 'parse_service.dart';
import 'shell_controller.dart';
import 'update_coordinator.dart';
import 'update_service.dart';
import 'widgets/animated_tab_icon.dart';

import 'ui/notifications.dart';
import 'ui/prefs.dart';
import 'ui/motion.dart';
import 'ui/clipboard.dart';
import 'ui/clipboard_reader.dart';
import 'ui/palette.dart';
import 'ui/permissions_gate.dart';
import 'pages/parse.dart';
import 'pages/history.dart';
import 'pages/settings.dart';
import 'ui/glass.dart';


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
  // 启动编排搬去了 lib/bootstrap.dart:第一帧之前要办的(bootstrap)和首帧之后
  // 才办的(warmUp)分成两档,这里只负责把它们接起来。
  final prefs = await bootstrap();
  runApp(LiquidGlassWidgets.wrap(child: LiquidGlassDemo(prefs: prefs)));
  warmUp();
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
    with WidgetsBindingObserver
    implements ShellController {
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
  @override
  late AppThemeMode themeMode;
  @override
  late bool hideTabLabels;
  @override
  late bool glassBottomBar;

  /// 自定义背景图路径(应用目录里那张)。null = 默认深浅背景。
  @override
  String? customBackgroundPath;

  /// 界面缩放:已生效的值。(拖动中的草稿留在缩放卡片自己身上,见 UiScaleCard)
  @override
  late double uiScale;

  /// 下载结束后要不要发系统通知。两个开关在「通知管理与下载」页里。
  @override
  late bool notifyDownloadDone;
  @override
  late bool notifyDownloadFailed;

  /// 进入 APP 自动粘贴剪贴板首条链接并解析。开关在「自动粘贴并解析」页里，默认开。
  @override
  late bool autoPasteParse;

  /// 上一次自动粘贴解析过的链接。剪贴板没换内容时不再重复解析，
  /// 免得每次从后台回来都重新打一次解析。
  String? _lastAutoPasted;

  /// 读剪贴板那点事(700ms 兜底 + 成对收尾)搬去了 [ClipboardReader]。
  /// 见那个文件开头的说明:这种东西留在宿主 State 的字段里,早晚会有人忘了收。
  final ClipboardReader _clipboard = ClipboardReader();

  // ── 检查更新 / 首次授权 ──
  //
  // 这两块的字段与顺序约束一起搬去了 UpdateCoordinator / PermissionsGate:
  // 「自动检查前必须等忽略状态读回来」这类规则,放在一个同时管着解析、历史、
  // 主题的大 State 里没人敢动。
  late final UpdateCoordinator _update = UpdateCoordinator(
    prefs: widget.prefs,
    popupContext: () => _popupContext,
    service: widget.updates,
  );
  late final PermissionsGate _permissions = PermissionsGate(
    prefs: widget.prefs,
  );

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
  ///
  /// 状态本体在 [UpdateCoordinator.busy] 里,这里只把接口露出去。用
  /// [ValueListenable] 而不是普通 bool:设置页那颗按钮要跟着它变,而页面拿不到
  /// 根 State 的 setState(见 ShellController 里那段说明)。
  @override
  ValueListenable<bool> get checkingUpdate => _update.busy;

  // ── 解析页的状态 ──
  //
  // 刻意放在根 State 上,而不是 ParsePage 自己的 State 里:切 tab 会把整棵子树
  // 连同它的 State 一起重建,状态放在页面里的话,解析结果和输入框内容一换 tab
  // 就没了。输入框控制器同理 —— 它的内容也得活着。
  @override
  final ParseService parseService = ParseService();
  final HistoryStore _history = HistoryStore();
  @override
  final TextEditingController linkController = TextEditingController();

  /// 历史记录。同样放在根 State 上:历史页切走就会被重建,数据留在这儿才不会
  /// 每次进来都重新读一遍存储。
  ///
  /// null = 还没读到(测试里没预传、异步读还没回来)。
  @override
  List<HistoryEntry>? historyEntries;

  @override
  ParseResult? parseResult;

  /// 正在请求。按钮跟着置灰,避免连点打出多次解析。
  @override
  bool parsing = false;

  /// 上一次失败的提示文案。成功一次就清掉。
  @override
  String? parseError;

  /// 解析成功后把按钮锁成「完成解析」。点一下输入框、或清空内容才解锁。
  @override
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
  @override
  void unlockParse() {
    if (!parseLocked) return;
    setState(() => parseLocked = false);
  }

  @override
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
        unawaited(precacheImage(NetworkImage(cover), context, onError: (_, _) {}));
        // 磁盘缓存:下次冷启动进历史页就不用再等网络了
        unawaited(CoverCache.store(cover));
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
  @override
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
  @override
  Future<String?> readClipboard() => _clipboard.read();

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
  @override
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
  @override
  Future<void> deleteHistory(Set<String> ids) async {
    final entries = await _history.remove(ids);
    // 删除**立刻落盘**,不等那份 300ms 防抖:删除是用户按下去的动作,而后台被杀、
    // 用户马上切走、进程重启这些事都可能发生在防抖窗口里 —— 那时候"删掉的又回来了"
    // 比"多写一次全量 JSON"难解释得多。解析(高频那条路)仍然走防抖。
    await _history.flush();
    if (!mounted) return;
    setState(() => historyEntries = entries);
  }

  /// 供二级设置页调用。setState 是 protected,不能从外部 State 直接调,
  /// 所以在这里开一个公开入口统一刷新,顺带把改动落盘。
  @override
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
    // 自定义背景图:没有就删键,有就写路径。
    final background = customBackgroundPath;
    if (background == null || background.isEmpty) {
      prefs.remove(kPrefsCustomBackground);
    } else {
      prefs.setString(kPrefsCustomBackground, background);
    }
    // 自定义存储目录:没有就删键,有就写 tree uri + 名字。
    for (final kind in MediaKind.values) {
      final target = Downloader.customStorage[kind];
      final treeKey = kPrefsStorageTreeKey(kind.wireName);
      final labelKey = kPrefsStorageLabelKey(kind.wireName);
      if (target == null) {
        prefs.remove(treeKey);
        prefs.remove(labelKey);
      } else {
        prefs.setString(treeKey, target.treeUri);
        prefs.setString(labelKey, target.label);
      }
    }
  }

  /// 把选好的主题模式同步给原生侧(Android 的**按应用夜间模式**)。
  ///
  /// 系统启动图是按原生那一档取资源的:光落盘不够 —— 改完主题**紧接着**的一次
  /// 冷启动,启动图还会用旧的那一档(启动图是在 Activity 起来之前画好的),再开一次
  /// 才对。所以在这里当场告诉原生侧,下一次冷启动就是对的。
  ///
  /// 原生侧见 MainActivity.applyAppNightMode;老系统/别的平台没有这条路,失败就算了
  /// —— 那只影响启动图的深浅,不该让换主题这件事报错。
  @override
  void syncNightModeToNative(AppThemeMode mode) {
    Downloader.channel.invokeMethod<void>('setThemeMode', <String, String>{
      'mode': mode.name,
    }).ignore();
  }

  @override
  void initState() {
    super.initState();
    // 剪贴板走平台侧那条路(见 lib/ui/clipboard.dart 的说明:系统 getClipboard
    // 认 html / uri-list 那类剪贴板,Flutter 自带的只认 text/plain)。
    _clipboard.platformRead = readClipboardInner;
    // 排障:如果这次启动带着 bench_url(见 lib/bench.dart),跑一轮下载基准。
    // 只在 debug 构建里问;release 上这段不会被编译进去。
    if (kDebugMode) DownloadBench.checkIntent();
    final prefs = widget.prefs;
    themeMode =
        AppThemeMode.values.asNameMap()[prefs?.getString(kPrefsThemeMode)] ??
        AppThemeMode.system;
    hideTabLabels = prefs?.getBool(kPrefsHideTabLabels) ?? false;
    glassBottomBar = prefs?.getBool(kPrefsGlassBottomBar) ?? true;
    // 自定义背景图:只存路径。文件不在了(被系统清理/换机恢复)也不在这拦 ——
    // ThemeBackground 的 errorBuilder 会退回默认背景,不值得为它卡第一帧。
    customBackgroundPath = prefs?.getString(kPrefsCustomBackground);
    uiScale = (prefs?.getDouble(kPrefsUiScale) ?? 1).clamp(
      UiScaleCard.min,
      UiScaleCard.max,
    );
    // 通知开关默认都开:下载完不给个动静才是异常。
    notifyDownloadDone = prefs?.getBool(kPrefsNotifyDownloadDone) ?? true;
    notifyDownloadFailed = prefs?.getBool(kPrefsNotifyDownloadFailed) ?? true;
    // 自动粘贴解析默认开:用户从别处复制链接回来就是想解析的。
    autoPasteParse = prefs?.getBool(kPrefsAutoPasteParse) ?? true;
    // 每个分类自定义的存储目录:偏好里存 tree uri + 可读名字,读回后放进
    // Downloader.customStorage,publish 时按分类取。空 = 该分类走默认媒体库路径。
    Downloader.customStorage.clear();
    for (final kind in MediaKind.values) {
      final tree = prefs?.getString(kPrefsStorageTreeKey(kind.wireName));
      if (tree == null || tree.isEmpty) continue;
      final label = prefs?.getString(kPrefsStorageLabelKey(kind.wireName));
      Downloader.customStorage[kind] = StorageTarget(
        treeUri: tree,
        label: (label == null || label.isEmpty) ? tree : label,
      );
    }
    // 忽略的版本 / 首次授权问过没有:偏好里有就直接用,没有(widget.prefs 为 null,
    // 测试里常见)让那两个对象自己异步补读一次。读是一次异步,所以更新那边会先等
    // 它落地,不然自动检查会把用户已经忽略过的版本又弹一遍。
    _update.loadIgnoredVersion(cached: prefs?.getString(kPrefsIgnoredVersion));
    _permissions.load(cached: prefs?.getBool(kPrefsPermissionsAsked));
    WidgetsBinding.instance.addObserver(this);
    linkController.addListener(_onLinkChanged);
    // 冷启动就先把到反代的连接建起来:用户很可能几秒内就粘链接解析。
    parseService.warmUp();

    // 版本号是异步问出来的,不等它:第一帧该出什么还出什么。
    unawaited(_update.refreshLocalVersion());

    // 每次进 APP 自动检查一次。放在第一帧之后,别和启动动画抢帧。
    //
    // 桌面端整条更新链路都不存在(发的是 APK),不查(见 update_service.dart 的
    // updateSupported)。设置页那个入口在那边也不显示。
    if (widget.autoCheckUpdate && updateSupported) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        checkForUpdate();
      });
    }

    // 首次装好的权限引导。也等第一帧:它要弹卡,得先有个能挂弹层的 Navigator。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_permissions.askOnFirstLaunch());
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
    // 剪贴板那一趟还在等平台侧回话:计时器和等待由 ClipboardReader 一起收掉。
    _clipboard.dispose();
    // 历史那份写盘防抖计时器收掉,顺手把没落盘的那一次写出去。
    unawaited(_history.dispose());
    linkController.dispose();
    parseService.dispose();
    _update.dispose();
    super.dispose();
  }

  // ── 检查更新 ──

  /// 检查一次有没有新版本。实现搬去了 [UpdateCoordinator.check];这里只做转发,
  /// 因为板块页是通过 ShellController 拿这个入口的。
  @override
  Future<void> checkForUpdate({bool manual = false}) => _update.check(manual: manual);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 只认"回到前台":跳系统设置页会先后台、再前台,权限就是在那儿开的。
    if (state == AppLifecycleState.resumed) {
      unawaited(_update.finishPendingInstall());
      // 从别处复制链接后回到 APP:自动粘贴首条链接并解析(开关控制)。
      unawaited(_maybeAutoPasteParse());
      return;
    }
    // 退到后台就把历史落盘。历史的写盘有 300ms 防抖(见 HistoryStore),系统在这
    // 之后杀掉进程的话,最后那几条就没了 —— 这一下是把它兑成持久的那一次。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_history.flush());
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
            // 关掉库的「滚动边缘渐隐」。
            //
            // 库默认开着它:只要传了 bottomBar,整个 body 就会被包进
            // GlassScrollEdgeEffect。那个效果并不只是画一层渐变 —— 它用
            // RenderRepaintBoundary.toImage(pixelRatio: 1.0) 把整屏背景抓成一张
            // 纹理(见库 glass_scroll_edge_effect.dart 的 _captureBackground),而且
            // 注册了对 ModalRoute.isCurrentOf 的依赖:每次路由重新变成 current
            // (也就是每次从二级页返回一级页)都要在转场中间重新抓一次整屏。
            // 那次离屏渲染是 GPU 的活,和转场抢同一个光栅线程,慢机型上就是
            // 「一按返回就卡」。
            //
            // 观感上不损失:三个板块页的列表底部本来就留了 120(bottomPadding,
            // 见 BoardScrollView),内容滚不到底栏下面那条渐隐带里。
            //
            // 将来若真要这条渐隐,别开库那一档(它带着整屏捕获);自己画一层
            // 不模糊、不抓纹理的渐变即可。
            edgeFade: false,
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
                  // 自定义背景只铺在三个板块页;二级页的 SubPage 不传,保持默认。
                  imagePath: customBackgroundPath,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            backgroundColor: Palette.of(isDark).pageBackground,
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
    final Color fill = Palette.of(isDark).barBackground;

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
                          // 底栏里那颗「磨砂胶囊」的底:深浅两档的白色/黑色透明度
                          // (0x24 / 0x17)不在 Palette 里 —— avatar 那对是 0x24FFFFFF /
                          // 0x1F000000,浅色档对不上,硬套会加深这颗胶囊。
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
    // 未选中那颗的灰(0xFF9A9AA0 / 0xFF8A8A8E)是底栏专用的中性色,Palette 的
    // secondary 是 0xFFADB7C5 / 0xFF6E7887,两对不一样,所以留内联。
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
