import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'failure.dart';
import '../ui/download_progress_card.dart';
import '../ui/popup.dart';
import '../ui/prefs.dart';
import '../ui/update_card.dart';
import '../update_service.dart';

/// 「检查更新 → 下载 → 交给系统安装器」这一整条链路。
///
/// 从 [HomeShellState] 里搬出来的一块。它以前是根 State 上的五个字段加九个方法
/// (忽略的版本、弹过没有、本机版本号、等待安装的包、正在检查),彼此之间还有顺序
/// 依赖 —— 比如「自动检查前必须等忽略状态从存储里读回来」,否则会把用户已经忽略
/// 过的版本又弹一遍。这些顺序约束放在一个同时管着解析、历史、主题的大 State 里,
/// 谁都不敢动。
///
/// 搬出来之后它只有三个外部依赖,都是显式传进来的:
/// - [popupContext]:弹层要挂在 Navigator 上(根 State 的 context 在 CupertinoApp
///   之上,拿它弹窗会报 "context does not include a Navigator");
/// - [installChannel]:装 APK 的平台通道(测试里换成假的);
/// - [prefs]:偏好存储,可空 —— 测试里常传 null,那就只是不落盘。
///
/// [busy] 是个 [ValueNotifier] 而不是普通字段:设置页那颗「检查更新」按钮要跟着转,
/// 而页面拿不到这个对象的 setState。
class UpdateCoordinator {
  UpdateCoordinator({
    required this.prefs,
    required this.popupContext,
    this.channel = const MethodChannel('jicun/downloader'),
    UpdateService? service,
  }) : updates = service ?? UpdateService();

  /// 偏好存储。可空:测试里不落盘。
  final SharedPreferences? prefs;

  /// 取弹层用的 context。拿不到(还没挂上 Navigator)就跳过这次提示 ——
  /// 更新提示不值得为它崩一次。
  final BuildContext? Function() popupContext;

  /// 安装 APK 走的平台通道。和下载器共用一条(见 Downloader.channel 的说明)。
  final MethodChannel channel;

  final UpdateService updates;

  /// 正在检查更新。设置页那颗按钮跟着它转。
  final ValueNotifier<bool> busy = ValueNotifier<bool>(false);

  /// 本机版本号,问一次 package_info。空串 = 还没问到。
  ///
  /// 不阻塞启动:它只在 [PackageInfo] 回来的那一刻才可能影响"要不要弹更新卡",
  /// 而那时候更新接口多半也还没回。
  String localVersion = '';

  /// 用户上次忽略的版本。
  String? _ignoredVersion;

  /// 「已忽略的版本」那次异步读。检查更新前要 await 它落地。
  Future<void> ignoredLoaded = Future<void>.value();

  /// 这一趟会话里自动检查的更新卡已经弹过/正在弹,避免"切个 tab 回来又弹一次"。
  bool _promptShown = false;

  /// 下好却卡在「安装未知应用」授权上的那个包。用户去系统设置页开权限时 APP 会退到
  /// 后台,所以留着它,等回到前台再接着装(见 [finishPendingInstall])。
  String? _pendingInstall;

  /// 启动时调一次:把偏好里读过的那份忽略状态接过来,没有就异步补读一次。
  ///
  /// 忽略状态读不到就等于"没忽略过",每次启动都会再弹一次 —— 所以这条不能只靠
  /// 调用方传进来的那一份,读是一次异步,存成 Future 让检查更新那边先等它。
  void loadIgnoredVersion({String? cached}) {
    _ignoredVersion = cached;
    if (cached == null) ignoredLoaded = _readIgnoredVersion();
  }

  Future<void> _readIgnoredVersion() async {
    try {
      final store = prefs ?? await SharedPreferences.getInstance();
      final ignored = store.getString(kPrefsIgnoredVersion);
      if (ignored != null && ignored.isNotEmpty) _ignoredVersion = ignored;
    } catch (error, stack) {
      // 读不到就当没忽略过
      swallow('update.read-ignored', error, stack);
    }
  }

  /// 把「已忽略的版本」写进偏好存储。拿不到存储就算了 —— 那说明这台设备上偏好读写
  /// 整个用不了,别的设置也早就不生效了,这里再抛一次只会把点「忽略」变成崩溃。
  Future<void> _rememberIgnored(String version) async {
    try {
      final store = prefs ?? await SharedPreferences.getInstance();
      await store.setString(kPrefsIgnoredVersion, version);
    } catch (error, stack) {
      swallow('update.remember-ignored', error, stack);
    }
  }

  /// 检查一次有没有新版本。
  ///
  /// [manual] 是用户在设置里点的。手动检查有两处不一样:
  /// 1. "没有新版"时要给个回音(自动检查那时候什么都不弹,没人喜欢每次启动都被
  ///    通知一句"已是最新");
  /// 2. 用户忽略过的版本**照样弹更新卡** —— 是他自己点的检查,不该被上次的「忽略」
  ///    堵住;自动检查才按忽略状态闭嘴。
  Future<void> check({bool manual = false}) async {
    // 桌面端没有这条路:发的资产是 APK,靠系统安装器装。入口那边已经不显示了,
    // 这里再挡一道 —— 只挡入口的话,以后多一个调用点就又漏出来了。
    if (!updateSupported) return;
    if (busy.value) return;
    busy.value = true;
    try {
      if (localVersion.isEmpty) {
        // 第一次启动时 package_info 可能还没回来。等它一下,不然会把自己当成
        // "版本未知",任何 release 都判不出新旧。
        await refreshLocalVersion();
      }
      final release = await updates.fetchLatest();
      // 忽略状态可能还在从存储里读(见 loadIgnoredVersion):先等它落地,
      // 不然自动检查会把用户已经忽略过的版本又弹一遍。
      await ignoredLoaded;
      final popup = popupContext();

      if (release == null) {
        if (manual && popup != null && popup.mounted) {
          showInfo(popup, '检查更新', '仓库里还没有发布任何版本。');
        }
        return;
      }
      if (!isNewerVersion(release.version, localVersion)) {
        if (manual && popup != null && popup.mounted) {
          showInfo(popup, '检查更新', '当前已是最新版本($localVersion)。');
        }
        return;
      }
      // 忽略过这个版本(或更高的版本)就不再**自动**打扰。手动检查不在此列。
      final ignored = !updates.shouldPrompt(
        localVersion: localVersion,
        ignored: _ignoredVersion,
        release: release,
      );
      if (ignored && !manual) return;
      if (popup == null || !popup.mounted) return;
      if (_promptShown && !manual) return;
      _promptShown = true;
      await _showUpdateCard(popup, release);
    } on UpdateException catch (error) {
      final popup = popupContext();
      if (manual && popup != null && popup.mounted) {
        showInfo(popup, '检查更新失败', error.message);
      }
    } catch (error) {
      final popup = popupContext();
      if (manual && popup != null && popup.mounted) {
        showInfo(popup, '检查更新失败', '$error');
      }
    } finally {
      busy.value = false;
    }
  }

  /// 问一次本机版本号。平台侧没有这个插件(测试环境)就留空。
  Future<void> refreshLocalVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      localVersion = info.version;
    } catch (error, stack) {
      swallow('update.local-version', error, stack);
    }
  }

  /// 弹「版本更新」卡片。用户选完(更新/忽略)才返回。
  Future<void> _showUpdateCard(BuildContext context, ReleaseInfo release) =>
      showUpdateCard(
        context,
        release: release,
        currentVersion: localVersion,
        onIgnore: () {
          // 记住这个版本:下次启动不再提示,直到仓库发了更高的版本。
          _ignoredVersion = release.version;
          unawaited(_rememberIgnored(release.version));
        },
        onUpdate: () => downloadAndInstall(release),
      );

  /// 点「更新」:开窗口 → 下载 → 交给系统安装器。
  ///
  /// 「安装未知应用」那道授权**不在这里问** —— 它要等包下完了才问:那时用户刚看着
  /// 进度条走完,跳过去授权是一目了然的;一上来就跳系统设置页,用户只会觉得莫名其妙。
  Future<void> downloadAndInstall(ReleaseInfo release) async {
    final popup = popupContext();
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
        await updates.downloadApk(
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
      final path = '${dir.path}/${release.apkName}';
      if (!await canInstallApk()) {
        // 包已经在缓存里了,现在只差系统那道「安装未知应用」授权。**直接跳过去,
        // 不弹 APP 自己的说明卡**:用户刚看着进度条走完,为什么跳是一目了然的;
        // 等到从设置页回来(见 finishPendingInstall)再自动装,不用重新点「更新」,
        // 包也不会重下。
        _pendingInstall = path;
        controller.close();
        if (!await openInstallPermission()) unawaited(finishPendingInstall());
        return;
      }
      await installApk(path);
      controller.close();
    } on UpdateCancelled {
      controller.close();
    } catch (error) {
      controller.fail('$error');
    }
  }

  /// 系统让不让装:有「安装未知应用」授权就是 true。
  ///
  /// 和 [openInstallPermission] 一样做成实例方法而不是闭包字段 —— 字段初始化
  /// 里读不到 this.channel,而测试要能换成假通道,不想真去拉安装器。
  Future<bool> canInstallApk() async {
    try {
      final ok = await channel.invokeMethod<bool>('canInstallApk');
      return ok ?? true;
    } catch (_) {
      // 平台侧没有这个方法(比如测试环境):按"可以"处理,别把路堵死
      return true;
    }
  }

  /// 跳到系统的「安装未知应用」授权页。返回是否真的跳过去了。
  Future<bool> openInstallPermission() async {
    try {
      final ok = await channel.invokeMethod<bool>('openInstallPermission');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> installApk(String path) async {
    try {
      await channel.invokeMethod<String>('installApk', {'path': path});
    } catch (error) {
      final popup = popupContext();
      if (popup != null && popup.mounted) {
        showInfo(popup, '安装没能开始', '$error');
      }
    }
  }

  /// 从设置页回来:权限开了就把包交给安装器,没开就明说一句。
  ///
  /// 这一步不能省:用户点了「更新」、看着包下完、又被带去设置页,回来时如果什么都
  /// 不发生,他会以为更新坏了。
  Future<void> finishPendingInstall() async {
    final path = _pendingInstall;
    if (path == null) return;
    _pendingInstall = null;
    if (await canInstallApk()) {
      await installApk(path);
      return;
    }
    final popup = popupContext();
    if (popup != null && popup.mounted) {
      showInfo(popup, '还差一步', '请在系统设置里允许「即存」安装应用,回来就会自动安装。');
    }
  }

  void dispose() {
    busy.dispose();
    updates.dispose();
  }
}
