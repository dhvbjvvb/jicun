import 'package:jicun/update_service.dart';

// 二级设置页那几项偏好的存储键
const String kPrefsThemeMode = 'ui.themeMode';
const String kPrefsHideTabLabels = 'ui.hideTabLabels';
const String kPrefsGlassBottomBar = 'ui.glassBottomBar';
const String kPrefsUiScale = 'ui.scale';

/// 自定义背景图的绝对路径(选图后复制进应用目录的那张)。空 = 用默认深浅背景。
/// 只作用于解析/历史/设置三个板块页,二级页不展示。
const String kPrefsCustomBackground = 'ui.customBackground';

// 「通知管理与下载」页的两个开关
const String kPrefsNotifyDownloadDone = 'notify.downloadDone';
const String kPrefsNotifyDownloadFailed = 'notify.downloadFailed';

// 「自动粘贴并解析」页的开关:打开 APP 时自动粘贴剪贴板首条链接并解析。
const String kPrefsAutoPasteParse = 'clipboard.autoPasteParse';

// 「通知管理与下载 → 存储保存位置」里,用户给每个分类选的系统目录(SAF tree uri)
// 和它的可读名字。为空 = 该分类走默认媒体库路径。键按 MediaKind.wireName 拼,
// 不 import downloader,免得偏好这层反过来依赖下载器。
String kPrefsStorageTreeKey(String kind) => 'storage.$kind.tree';
String kPrefsStorageLabelKey(String kind) => 'storage.$kind.label';

/// 用户点过「忽略」的那个版本。存的是版本号本身(如 `1.1.0`):
/// 只有仓库又发了**更高**的版本才会再弹(见 [UpdateService.shouldPrompt])。
const String kPrefsIgnoredVersion = 'update.ignoredVersion';

/// 首次安装的权限引导弹过没有。只在第一次装好后问一次(见 `PermissionsGate.askOnFirstLaunch`)。
const String kPrefsPermissionsAsked = 'perm.asked';

// 服务端下发的优选 IP 列表、可用域名及其拉取时间(缓存用)
const String kPrefsPreferredIps = 'cfip.list';
const String kPrefsPreferredIpsAt = 'cfip.listAt';
const String kPrefsApiHost = 'api.host';

/// 服务端下发的赞助名单(/sponsors.json)的原文缓存。
///
/// 存原文而不是解析结果:读回来时走同一个 parseSponsors,净化与上限的判据
/// 只有一份(见 lib/sponsor_store.dart)。
const String kPrefsSponsors = 'sponsors.list';

// 设备身份(硬件密钥证明),见 lib/device_identity.dart。
//
// `device.id` 是服务端认设备的那个 id(它自己也是从硬件公钥推出来的);另外两个是本地
// 时间戳 —— 前者记证明是什么时候办下来的(排障用),后者用来做失败重试的退避:
// 没它的话每次解析请求都会先去打注册接口(见 kDeviceRetryInterval)。
const String kPrefsDeviceId = 'device.id';
const String kPrefsDeviceAttestedAt = 'device.attestedAt';
const String kPrefsDeviceLastAttempt = 'device.lastAttempt';
// 上次登记时上报的 App 版本。它只用来判断「要不要补登记一次」:机型、android_api、
// App 版本都是**登记那一刻**报上去的,升级后不补一次,后台那条记录就永远停在旧值
// (机型那列会一直空着)。见 device_identity.dart 的 _refreshRegistrationIfVersionChanged。
const String kPrefsDeviceVersion = 'device.version';

/// 系统主题的三个选项。存进 [kPrefsThemeMode],设置页与根壳都读它 ——
/// 放在这里是为了让 ShellController 和设置页都能引用,不必互相 import。
enum AppThemeMode { system, light, dark }
