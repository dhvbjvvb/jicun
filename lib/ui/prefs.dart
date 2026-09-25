import 'package:jicun/update_service.dart';

// 二级设置页那几项偏好的存储键
const String kPrefsThemeMode = 'ui.themeMode';
const String kPrefsHideTabLabels = 'ui.hideTabLabels';
const String kPrefsGlassBottomBar = 'ui.glassBottomBar';
const String kPrefsUiScale = 'ui.scale';

// 「通知管理与下载」页的两个开关
const String kPrefsNotifyDownloadDone = 'notify.downloadDone';
const String kPrefsNotifyDownloadFailed = 'notify.downloadFailed';

// 「自动粘贴并解析」页的开关:打开 APP 时自动粘贴剪贴板首条链接并解析。
const String kPrefsAutoPasteParse = 'clipboard.autoPasteParse';

/// 用户点过「忽略」的那个版本。存的是版本号本身(如 `1.1.0`):
/// 只有仓库又发了**更高**的版本才会再弹(见 [UpdateService.shouldPrompt])。
const String kPrefsIgnoredVersion = 'update.ignoredVersion';

/// 首次安装的权限引导弹过没有。只在第一次装好后问一次(见 `_askPermissionsOnFirstLaunch`)。
const String kPrefsPermissionsAsked = 'perm.asked';

// 服务端下发的优选 IP 列表、可用域名及其拉取时间(缓存用)
const String kPrefsPreferredIps = 'cfip.list';
const String kPrefsPreferredIpsAt = 'cfip.listAt';
const String kPrefsApiHost = 'api.host';

/// 系统主题的三个选项。存进 [kPrefsThemeMode],设置页与根壳都读它 ——
/// 放在这里是为了让 ShellController 和设置页都能引用,不必互相 import。
enum AppThemeMode { system, light, dark }

