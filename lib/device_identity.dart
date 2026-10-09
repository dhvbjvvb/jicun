/// 设备身份 + 硬件密钥证明(Dart 这一半)。
///
/// 原生那一半见 `android/app/src/main/kotlin/com/videofix/jicun/DeviceIdentity.kt`
/// (通道 `jicun/device`)。分工是刻意的:**Dart 只负责拼串,原生只负责签名** ——
/// 拼串要跟服务端逐字对齐(改一行就能核),签名必须由硬件私钥做(私钥出不了芯片)。
///
/// 三件事:
/// 1. [ensureDeviceIdentity] 启动时跑一趟 —— 没注册过就拿挑战值、让原生生成硬件密钥、
///    把证书链交给服务端换一个 device_id 落盘;注册过就只做一次「密钥还在吗」的确认,
///    顺带在 App 升级后**签名刷新**一次(把版本号 / 机型刷上去,见 [_postRefresh]);
/// 2. [deviceHeaders] 之后每个**我们自己**的请求带上四个签名头;
/// 3. 两者的失败**都必须静默** —— 一个头的有无不该让用户看到报错。
///
/// ⚠️ 这里的协议(端点、头名、待签串、device_id 的定义)由服务端**冻结**,两边逐字一致。
/// 改之前先确认服务端那边一起改了,尤其是下面 [canonicalPayload] 的顺序和分隔符。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_host.dart';
import 'preferred_ip.dart';
import 'ui/prefs.dart';

/// 设备 id。服务端按它认设备。
const String kDeviceHeaderName = 'X-Jicun-Device';

/// 请求时刻,Unix 秒(十进制字符串)。服务端据此挡重放。
const String kDeviceHeaderTs = 'X-Jicun-Ts';

/// 一次性随机串:22 字符 base64url(16 随机字节,无填充)。
const String kDeviceHeaderNonce = 'X-Jicun-Nonce';

/// 签名。base64 **标准**编码(带 `=` 填充)的 **DER** 编码 ECDSA-SHA256。
const String kDeviceHeaderSig = 'X-Jicun-Sig';

/// 原生通道名,和 MainActivity 里挂的那一个对应。
const String kDeviceChannel = 'jicun/device';

/// 刷新展示信息的**公网路径**(`POST /device/refresh`,见 [_postRefresh])。
///
/// 待签串里用的是**它**(客户端请求的那个路径),不是 nginx 改写之后的后端路径 ——
/// 服务端那边对应 src/api/device.py 的 REFRESH_PUBLIC_PATH,两边必须一字不差。
const String kDeviceRefreshPath = '/device/refresh';

/// **App 升级后刷新展示信息**那一条路的退避间隔。
///
/// 为什么是 10 分钟而不是 6 小时:刷新走的是 [_postRefresh] 那条**签名**路 —— 只用库里的私钥
/// 签一次,不生成密钥、不碰证明书,重试的代价几乎为零;而它的全部意义就是把后台看到的版本号 /
/// 机型刷新掉(挂 6 小时 = 用户看到的是 6 小时前的版本)。
///
/// 更早的版本这里是 6 小时(而且共用「失败是常态」那套理由):那时「刷新」只能靠重新登记
/// 一次,而重登在服务端**必然失败**(证明书里的挑战值一次性,见 [_postRefresh] 的说明)——
/// 慢慢退避是当时唯一不添乱的选择,代价是设备页永远停在旧值上。
///
/// 10 分钟这个量级:比「用户重启一次 App」长一点(不至于反复重启就反复打接口),又比
/// 「换个网络环境」短得多(那次失败多半就是网络)。成功之后会把它清掉,下次升级立刻能刷。
const Duration kDeviceRefreshRetryInterval = Duration(minutes: 10);

/// **从没登记成功过**的设备的退避间隔 —— 比上面那个短两个数量级。
///
/// 为什么必须分开:这种设备现在等于**没有身份**。服务端在 `enforce` 下把它的每一个请求都
/// 拒掉,而用户看到的是「请更新到最新版本」,更新了也没用 —— 这时候还按 6 小时退避,就是让
/// 他白等 6 小时。装完/重装之后第一次启动恰恰是最容易失败的一次(安全芯片刚忙完、优选 IP
/// 还在赛跑),线上就这么卡过一次:登记只走到「拿到挑战值」,之后请求全是未签名。
///
/// 10 秒只是个下限 —— 真正决定「什么时候再试」的是 [awaitDeviceIdentity](用户不发请求它不动)。
const Duration kDeviceBootstrapRetryInterval = Duration(seconds: 10);

/// 注册那两趟请求的超时。它发生在后台,失败了大不了下次再说。
const Duration _httpTimeout = Duration(seconds: 10);

/// 本机版本号的兜底值。
///
/// 正常情况下走 [PackageInfo](= pubspec 的 `version:`),**不写死** —— 写死了每次发版
/// 都要记得改这里,忘了就是一直在骗服务端。这个常量只在拿不到插件时用(用例环境,
/// 或者插件异常)。
const String _fallbackAppVersion = '3.3.0+20';

const MethodChannel _deviceChannel = MethodChannel(kDeviceChannel);

/// 注册那两趟用的 http client。
///
/// 留成可变字段是为了让用例能换成 MockClient(和 [ParseService.clientFactory] 同一个做法;
/// 这里不能直接复用那个字段 —— `parse_service.dart` 反过来要 import 本文件拿签名头,
/// 再反向 import 就成了循环依赖)。
///
/// 默认实现挂上和 [ParseService.clientFactory] **同一套优选 IP 连接器**:域名被运营商
/// 按 SNI 阻断时,只有靠优选 IP 走 Cloudflare 边缘才连得上 —— 那时候解析能用、注册却
/// 永远失败的话,这套身份就白做了。
http.Client Function() deviceClientFactory = defaultDeviceClient;

/// 默认的注册 client(挂优选 IP 连接器)。具名是为了让用例替换之后还能换回来。
http.Client defaultDeviceClient() =>
    IOClient(HttpClient()..connectionFactory = PreferredIpConnector().connect);

/// sha256 的小写十六进制。没有查询串时对**空字符串**求摘要(不是 null、不是跳过)。
String sha256Hex(String text) => sha256.convert(utf8.encode(text)).toString();

/// 待签串(canonical string),服务端逐字校验这一个函数。
///
/// 六行,`\n` 连接,**结尾没有换行**:
///
/// ```
/// METHOD
/// PATH
/// SHA256_HEX
/// TS
/// NONCE
/// DEVICE_ID
/// ```
///
/// - [method] 大写 HTTP 方法;
/// - [path] 只有路径(`/parse`),不含域名、不含查询串;
/// - [rawQuery] 是**原始查询串**,即问号后面那一整段(`url=https%3A%2F%2F…`)。这里要的是
///   发出去了什么就签什么 —— 所以传 `uri.query`,不要传解码过的参数表:两边对编码的
///   理解一有差别(空格是 `%20` 还是 `+`、`~` 编不编码),签名就对不上。
String canonicalPayload({
  required String method,
  required String path,
  required String rawQuery,
  required String timestamp,
  required String nonce,
  required String deviceId,
}) => <String>[
  method.toUpperCase(),
  path,
  sha256Hex(rawQuery),
  timestamp,
  nonce,
  deviceId,
].join('\n');

/// 22 字符的 base64url 随机串(16 字节,去掉填充)。
///
/// 16 字节编成 base64 是 24 字符带 `==`,去掉正好 22 —— 协议里写的就是这个长度,
/// 服务端拿它挡重放,所以**每次请求都必须是新的**(不能缓存一个反复用)。
String deviceNonce() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// 内存里的 device_id。`''` = 已查过、确实没有。
///
/// **它同时是签名头的唯一来源**:[deviceHeaders] 只读这一份(见 [_deviceId]),所以
/// 唯一会写它的地方就是 [ensureDeviceIdentity] —— 启动时跑一趟,把落盘/新注册的 id
/// 填进来。写的时候两种状态都要能表示:「有 id」和「确实没有」(`''`)。
String? _cachedDeviceId;

/// 正在跑的那一次注册。启动时的 [ensureDeviceIdentity] 与用例都可能撞上同一刻。
Future<void>? _inFlight;

/// 本次进程里 [ensureDeviceIdentity] 被调过没有 —— 启动流程一定会调它。
///
/// 用途只有一个:[awaitDeviceIdentity] 判断「要不要在请求路径上补起一次登记」。少了这道
/// 判断,那些**不跑启动流程**的环境(widget 用例直接 pump 一个页面)也会从解析路径发起
/// 真实网络请求 —— 踩过,整片用例超时。
bool _startedThisProcess = false;

/// 只给用例用:把内存缓存清掉,回到「还没查过」的状态。
@visibleForTesting
void resetDeviceIdentityCache() {
  _cachedDeviceId = null;
  _inFlight = null;
  _startedThisProcess = false;
}

/// 确保这台设备已经注册过(幂等,可以反复调)。
///
/// 流程:读落盘的 device_id → 有就问一次原生「密钥还在不在」→ 都在就直接返回
/// (顺带看一眼 App 版本,升级过就补登记一次,见 [_refreshRegistrationIfVersionChanged]);
/// 否则拿挑战值、生成密钥、交证书链、落盘 device_id。
///
/// **任何一步失败都不抛**:解析、播放、下载都不该因为这件事变差。拿不到身份时 APP
/// 照常发请求 —— 服务端在 `enforce` 模式下会自己拒,那是它的判断,不是 APP 该先崩
/// 给用户看的理由。
Future<void> ensureDeviceIdentity() {
  _startedThisProcess = true;
  final running = _inFlight;
  if (running != null) return running;
  final task = _ensureDeviceIdentity();
  _inFlight = task;
  return task.whenComplete(() => _inFlight = null);
}

/// 发请求前「等一次正在跑的身份登记」,最多 [timeout]。已经有身份就一秒都不等。
///
/// 为什么需要它(线上实测的 bug):登记是启动时 `unawaited(...)` 起的火,而解析请求
/// 可能在它办完之前就发出去了 —— **那一次请求不带签名头**,服务端在 `enforce` 下直接
/// 403「本接口仅供官方APP使用,请更新到最新版本」。用户看到的现象就是「第一次粘贴解析
/// 失败,把最后一个字符删掉再打回去就好了」(第二次请求时登记早就办完了)。
///
/// 三条刻意的约束:
///   1. **默认不在这儿新起一次登记**,只等已经在跑的那一个 —— 启动那次才是登记的入口。
///      **一个例外**:这台设备根本没有身份时补起一次(从没登记成功过,或者落盘的 id 已经
///      签不出东西)。那种状态下它每个请求都会被拒,用户看到的是「请更新到最新版本」而更新
///      根本没用;与其让他一直撞墙,不如救一次。频率由退避管着,而且只在跑过启动流程的进程里
///      生效(见 [_recoverMissingIdentity])。
///   2. **不吃偏好存储**:和 [deviceHeaders] 同一条纪律(见那里的说明)。上面那个例外是
///      唯一的破例,而且它被 [_startedThisProcess] 挡在用例环境之外。
///   3. **超时就往下走**,不抛:卡在这儿等,用户看到的是「一直在转」,比一个能看懂的
///      报错更糟。真正决定放不放行的是服务端。
///
/// [timeout] 默认 5 秒 —— 大约是登记那两趟里单趟超时([_httpTimeout] 10 秒)的一半。
/// 再久就等于把一个本该在后台办完的事变成用户能看见的卡顿,而那种情况通常网络本身
/// 就有问题,等着也等不到。
Future<void> awaitDeviceIdentity({
  Duration timeout = const Duration(seconds: 5),
}) async {
  if (_deviceId() != null) return;
  final running = _inFlight;
  if (running == null) {
    await _recoverMissingIdentity(timeout);
    return;
  }
  try {
    await running.timeout(timeout);
  } catch (_) {
    // 超时 / 登记失败都照常往下走:这一趟会变成一次没签名的请求,由服务端去判。
  }
}

/// 没有正在跑的登记、而且这台设备**没有身份**时,补起一次。
///
/// 为什么值得破「不在请求路径上碰网络」这条:那种设备现在等于废的 —— 服务端把它每个请求
/// 都拒掉,提示还是「请更新到最新版本」(更新了也没用)。线上实测过:重装之后有一次登记
/// 只走到「拿到挑战值」就断了(证书链读不出来,见 DeviceIdentity.kt 的 createKey),
/// 之后这台设备一直是未签名状态,用户只能反复撞墙。
///
/// 两道闸门保证它不会变成「每个请求都打两次注册接口」:
///   1. [_startedThisProcess] —— 本次进程连启动流程都没跑过就直接返回。widget 用例
///      (直接 pump 一个页面)正是这种环境,放它进来就会去打真实网络;
///   2. [_dueForRetry] —— 频率由 [kDeviceBootstrapRetryInterval](10 秒)管着。
Future<void> _recoverMissingIdentity(Duration timeout) async {
  if (!_startedThisProcess) return;
  final SharedPreferences prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } catch (_) {
    return; // 拿不到偏好存储(插件异常):什么都别做
  }
  if (!_dueForRetry(prefs, kDeviceBootstrapRetryInterval)) return;
  try {
    await ensureDeviceIdentity().timeout(timeout);
  } catch (_) {
    // 还是没成:照常发这一趟(会变成未签名请求),由服务端去判。
  }
}

Future<void> _ensureDeviceIdentity() async {
  SharedPreferences? prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } catch (error) {
    // 偏好存储拿不到(插件异常)就什么都不做 —— 没有 device_id 落盘,注册也没有意义。
    if (kDebugMode) debugPrint('设备身份:读不到偏好存储:$error');
    return;
  }

  try {
    final stored = prefs.getString(kPrefsDeviceId);
    if (stored != null && stored.isNotEmpty) {
      // 落盘的 id 和密钥必须**同时**成立。密钥会自己消失:换锁屏方式、恢复出厂设置、
      // 清数据、系统作废安全芯片里的条目 —— 那之后这个 id 谁都签不出来,拿它去请求
      // 只会被服务端记成一次失败。所以每次启动都问一次原生,不在就重建。
      if (await _nativeDeviceId() == stored) {
        _cachedDeviceId = stored;
        // id 照旧用 —— 哪怕下面这次补登记没成,密钥还在,id 就还能签。
        await _refreshRegistrationIfVersionChanged(prefs);
        return;
      }
      if (kDebugMode) {
        debugPrint('设备身份:落盘的 device_id 已经没有对应密钥,重新注册');
      }
      await prefs.remove(kPrefsDeviceId);
      _cachedDeviceId = null;
    }

    // 退避:上次试过还没成功就别再试。这里用**短的那一档** —— 走到这一步说明这台设备
    // 现在没有可用的身份(压根没落盘的 id,或者落盘的 id 已经签不出东西了),它的每个请求
    // 都会被服务端拒掉,慢慢退避是错的(见 kDeviceBootstrapRetryInterval)。
    // 时间戳**先落盘再发请求**:请求本身崩了/进程被杀,也算"试过了"。
    if (!_dueForRetry(prefs, kDeviceBootstrapRetryInterval)) return;
    await prefs.setInt(
      kPrefsDeviceLastAttempt,
      DateTime.now().millisecondsSinceEpoch,
    );

    // **没有身份**的设备:允许重建密钥。它们证书里那个挑战值很可能是上一次尝试留下的,
    // 继续用旧密钥只会永远被判「挑战值无效」(见 [_register] 的说明)。
    final registered = await _register(prefs, mayRebuildKey: true);
    if (registered == null) return;
    await _storeRegistration(prefs, registered);
    _cachedDeviceId = registered;
    if (kDebugMode) debugPrint('设备身份:注册完成 $registered');
  } catch (error) {
    // 走到这儿说明是没预料到的异常(比如偏好写入失败)。注册没成就是没成,
    // 不能让它冒到启动流程上去。
    if (kDebugMode) debugPrint('设备身份:注册失败:$error');
  }
}

/// 把一次登记的结果落盘:device_id、这次上报的版本、证明时间。
Future<void> _storeRegistration(
  SharedPreferences prefs,
  String deviceId,
) async {
  await prefs.setString(kPrefsDeviceId, deviceId);
  await prefs.setString(kPrefsDeviceVersion, await _appVersion());
  await prefs.setInt(
    kPrefsDeviceAttestedAt,
    DateTime.now().millisecondsSinceEpoch,
  );
}

/// App 升级后**刷新一次**「服务端记着的版本号 / 机型」。
///
/// 先走 [_postRefresh](`POST /device/refresh`):拿库里的私钥签一次请求,服务端验签后只写
/// 展示字段 —— 不换 device_id、不碰证明书。
///
/// 为什么不再用「重新登记一次」:证明书里的 attestationChallenge 是**生成密钥那一刻**写死的,
/// 而挑战值一次性 —— 拿旧密钥重登必然被判 CHALLENGE_INVALID。线上实测:248 台设备的版本号
/// 全停在登记那一天,一台都刷不上来。服务端现在也给这种重登放行了(见它的
/// [_registered_same_key]),但那是给**还没带签名调用的老包**留的兼容路;这里先走签名路,
/// 失败了再退回那条。
///
/// 为什么值得多发这一个请求:
///   1) 机型(manufacturer/model)、android_api 都是**登记那一刻**上报的 —— 老记录里没有,
///      不刷一次,后台设备页的机型列就一直是空的(用户就是这么反馈的);
///   2) 设备表里的「App 版本」不刷新,管理员看到的是几年前的版本号,排障会被带偏。
///
/// 失败就算了,而且**不碰**落盘的 device_id:密钥还在,那个 id 就还能签。为了刷新一条
/// 展示信息把设备弄成「没有身份」(enforce 模式下等于全量 403)是绝对划不来的。
Future<void> _refreshRegistrationIfVersionChanged(
  SharedPreferences prefs,
) async {
  final version = await _appVersion();
  if (prefs.getString(kPrefsDeviceVersion) == version) return;
  // 时间戳**先落盘再发请求**:这一趟崩了/进程被杀,也算"试过了"。
  if (!_dueForRetry(prefs, kDeviceRefreshRetryInterval)) return;
  await prefs.setInt(
    kPrefsDeviceLastAttempt,
    DateTime.now().millisecondsSinceEpoch,
  );

  // 先走签名刷新。不成的话(服务端还没这个接口、或者这次网络不通)退回「同一把密钥的
  // 补登记」那条老路 —— **不许**重建密钥:重建会把 device_id 换掉,后台凭空多一行、
  // 配额和历史全断在原地。
  var refreshed = await _postRefresh(appVersion: version);
  refreshed ??= await _register(prefs, mayRebuildKey: false);
  if (refreshed == null) {
    if (kDebugMode) debugPrint('设备身份:刷新展示信息失败,继续用原来的 id');
    return;
  }
  // 只写版本号,**不动** [kPrefsDeviceAttestedAt]:这一趟没走证明书,写它等于把「上次证明
  // 时间」记成一次没发生过的证明。
  await prefs.setString(kPrefsDeviceVersion, version);
  // 成功了就把退避清掉:下次升级(哪怕 10 分钟内)也该立刻刷上。
  await prefs.remove(kPrefsDeviceLastAttempt);
  _cachedDeviceId = refreshed;
  if (kDebugMode) debugPrint('设备身份:版本变化,已刷新展示信息 $refreshed');
}

/// 距上次尝试够久(或从来没试过)才值得再试一次。
///
/// [interval] 由调用方给,因为两条路「值不值得再试」完全不同:没有身份时用
/// [kDeviceBootstrapRetryInterval](10 秒档),只是刷新机型/版本号时用
/// [kDeviceRefreshRetryInterval](10 分钟档 —— 那条路不碰密钥,重试几乎不要钱)。
bool _dueForRetry(SharedPreferences prefs, Duration interval) {
  final lastAttempt = prefs.getInt(kPrefsDeviceLastAttempt);
  if (lastAttempt == null) return true;
  final elapsed = DateTime.now().millisecondsSinceEpoch - lastAttempt;
  return elapsed >= interval.inMilliseconds;
}

/// 问原生要一次 device_id(顺带验证密钥还在)。没有密钥返回 null。
Future<String?> _nativeDeviceId() async {
  try {
    final id = await _deviceChannel.invokeMethod<String>('deviceId');
    return (id == null || id.isEmpty) ? null : id;
  } catch (_) {
    // 原生侧没挂上通道(旧版本原生代码)或者密钥库读失败:都按「没有密钥」处理。
    return null;
  }
}

/// 完整走一遍注册,成功返回 device_id,失败返回 null(原因只进日志)。
///
/// [mayRebuildKey] 决定「拿到的挑战值和这把密钥当初那个对不上时,要不要重建密钥」:
///
///   - **没有身份的设备**(首次注册,或者落盘的 id 已经签不出东西)传 true。它们的证书里
///     那个 attestationChallenge 是**写死的** —— 密钥一生成就复用(见 DeviceIdentity.kt 的
///     `createKey`),而重登每次拿到的是新挑战值。线上实测过:这种设备一直撞
///     `CHALLENGE_INVALID`,永远登记不上,用户看到的是「本接口仅供官方App使用,请更新到
///     最新版本」而升级、重装都没用。它们反正还没有可用身份,重建一把是唯一出路。
///   - **只是刷新机型/版本号**(身份是好的)传 false。重建会把 device_id 换掉:服务端凭空
///     多一行、配额与历史断在原地 —— 划不来,刷不上去就下次再说(见
///     [_refreshRegistrationIfVersionChanged])。
Future<String?> _register(
  SharedPreferences prefs, {
  required bool mayRebuildKey,
}) async {
  final challenge = await _fetchChallenge();
  if (challenge == null) return null;

  // 证书里的挑战值只认「这把密钥生成时的那个」:对不上就必须重建(见上面的说明)。
  final rebuild =
      mayRebuildKey && prefs.getString(kPrefsDeviceChallenge) != challenge;
  if (rebuild && kDebugMode) debugPrint('设备身份:挑战值与这把密钥对不上,重建密钥');

  final Map<Object?, Object?>? created;
  try {
    created = await _deviceChannel.invokeMapMethod<Object?, Object?>(
      'createKey',
      <String, String>{
        'challenge': challenge,
        // 字符串而不是布尔:这条通道的参数一直是字符串(和 `payload` 一致),
        // 两边各写一套类型最容易在「只有真机才走到」的分支上对不上。
        if (rebuild) 'rebuild': 'true',
      },
    );
  } catch (error) {
    if (kDebugMode) debugPrint('设备身份:生成密钥失败:$error');
    return null;
  }
  if (created == null) return null;

  final deviceId = created['deviceId'];
  final chain = (created['certificateChain'] as List?)
      ?.whereType<String>()
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
  if (deviceId is! String ||
      deviceId.isEmpty ||
      chain == null ||
      chain.isEmpty) {
    if (kDebugMode) debugPrint('设备身份:原生没给出可用的密钥或证书链');
    return null;
  }
  // attested 只进日志:服务端自己从证书链里验,不信客户端这一句(它也确实不该信)。
  if (kDebugMode) debugPrint('设备身份:硬件证明 attested=${created['attested']}');

  if (rebuild) {
    // 记下「这把密钥用的是哪个挑战值」—— 下一次重登要靠它判断要不要再重建。
    // 落盘放在这里而不是登记成功之后:**密钥已经带着新挑战值生成了**(native 那边已经
    // 重建),这一步描述的就是它;至于 attest 成不成,下次照样按这个记录判断。
    await prefs.setString(kPrefsDeviceChallenge, challenge);
  }

  final androidApi = await _androidApi();
  return _postAttest(
    deviceId: deviceId,
    chain: chain,
    appVersion: await _appVersion(),
    androidApi: androidApi,
    // 取不到就是空串 —— 服务端那边两个都空就存空,不会变成「//」那种怪东西。
    manufacturer: (created['manufacturer'] as String?) ?? '',
    model: (created['model'] as String?) ?? '',
  );
}

/// `GET /device/challenge` → nonce(base64url 字符串)。
Future<String?> _fetchChallenge() async {
  final body = await _getJson(apiUrl('/device/challenge'));
  if (body == null) return null;
  final data = body['data'];
  final nonce = data is Map ? data['nonce'] : null;
  if (nonce is! String || nonce.isEmpty) {
    if (kDebugMode) debugPrint('设备身份:挑战值应答里没有 nonce');
    return null;
  }
  return nonce;
}

/// `POST /device/attest` → device_id。
///
/// 请求体:`{"cert_chain":[…叶到根…],"app_version":"3.3.0+20","android_api":29,`
/// `"manufacturer":"Xiaomi","model":"23127PN0CC"}`(后两项只用于后台显示)。
/// **证书链不要反转** —— Kotlin 的 `KeyStore.getCertificateChain()` 给的就是叶→根,
/// 服务端也是按这个顺序读的。
Future<String?> _postAttest({
  required String deviceId,
  required List<String> chain,
  required String appVersion,
  required int? androidApi,
  required String manufacturer,
  required String model,
}) async {
  final client = deviceClientFactory();
  try {
    final response = await client
        .post(
          Uri.parse(apiUrl('/device/attest')),
          headers: const <String, String>{'Content-Type': 'application/json'},
          body: jsonEncode(<String, Object?>{
            'cert_chain': chain,
            'app_version': appVersion,
            'android_api': androidApi,
            // 机型:证明书里那份 attestationId* 很多机器根本不提供(实测小米 API 36 是空的),
            // 后台要「认出这是哪台机器」只能靠这里。服务端只拿它做显示,不当任何证据用。
            'manufacturer': manufacturer,
            'model': model,
          }),
        )
        .timeout(_httpTimeout);
    final body = _decodeJson(response.bodyBytes);
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        body?['succ'] != true) {
      // 失败原因(售后 retdesc)只进日志:这条路对用户是隐形的,弹一句「设备注册失败」
      // 只会让他以为 APP 坏了。拿不到头就是不加签名头,照常解析。
      if (kDebugMode) {
        debugPrint(
          '设备身份:attest 失败 HTTP ${response.statusCode} '
          '${body?['retdesc'] ?? body?['msg'] ?? ''}',
        );
      }
      return null;
    }
    final data = body?['data'];
    final id = data is Map ? data['device_id'] : null;
    if (id is! String || id.isEmpty) {
      if (kDebugMode) debugPrint('设备身份:attest 成功但没给 device_id');
      return null;
    }
    // 服务端回的 id 就是我们签出来的那个(同一个公钥算出来的)。对不上说明中间串了,
    // 拿本地的那个更安全 —— 本地那个是真签得出来的。
    if (id != deviceId && kDebugMode) {
      debugPrint('设备身份:服务端给的 id($id)与本地推导($deviceId)不一致');
    }
    return id;
  } catch (error) {
    if (kDebugMode) debugPrint('设备身份:attest 请求失败:$error');
    return null;
  } finally {
    client.close();
  }
}

/// `POST /device/refresh` → device_id。**签名刷新**展示信息(App 版本号 / 机型)。
///
/// 请求体只有展示字段;四个签名头由 [deviceHeaders] 拼,待签串里的路径是**客户端请求的
/// 公网路径** [kDeviceRefreshPath],和服务端那个常量一字不差(和 `/parse` 同一个约定)。
///
/// 为什么单独有这条路,而不是重新登记一次:证明书里的 attestationChallenge 是**生成密钥
/// 那一刻**写死的,而服务端的挑战值一次性(命中即删、TTL 300 秒)—— 拿旧密钥重登必然被判
/// CHALLENGE_INVALID。线上实测:248 台设备的版本号全停在登记那一天、一台都刷不上来。
/// 签名刷新只用库里的私钥签一次:不生成密钥、不碰证明书,也就没有这个问题。
///
/// 任何一步不成(拿不到签名、服务端拒了、网络不通)都返回 null —— 调用方据此退回
/// 「同一把密钥的补登记」那条老路(给服务端还没这个接口的部署兜底)。
Future<String?> _postRefresh({required String appVersion}) async {
  final deviceId = _deviceId();
  if (deviceId == null) return null;
  final headers = await deviceHeaders('POST', kDeviceRefreshPath, '');
  if (headers.isEmpty) {
    // 拿不到签名就别发了:服务端对这个接口**没有签名一律拒**(它不跟 sign_mode 走),
    // 这一趟纯属白发。调用方会改走补登记。
    if (kDebugMode) debugPrint('设备身份:刷新拿不到签名头,改用补登记');
    return null;
  }
  final info = await _nativeDeviceInfo();
  final client = deviceClientFactory();
  try {
    final response = await client
        .post(
          Uri.parse(apiUrl(kDeviceRefreshPath)),
          headers: <String, String>{
            'Content-Type': 'application/json',
            ...headers,
          },
          body: jsonEncode(<String, Object?>{
            'app_version': appVersion,
            'android_api': await _androidApi(),
            // 机型是**自述值**:服务端只拿它做显示,不当任何证据用。取不到就是空串,而那边
            // 空值不当覆盖 —— 不会把库里已有的机型擦掉。
            'manufacturer': info['manufacturer'] ?? '',
            'model': info['model'] ?? '',
          }),
        )
        .timeout(_httpTimeout);
    final body = _decodeJson(response.bodyBytes);
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        body?['succ'] != true) {
      if (kDebugMode) {
        debugPrint(
          '设备身份:refresh 失败 HTTP ${response.statusCode} '
          '${body?['retdesc'] ?? body?['msg'] ?? ''}',
        );
      }
      return null;
    }
    final data = body?['data'];
    final id = data is Map ? data['device_id'] : null;
    return (id is String && id.isNotEmpty) ? id : null;
  } catch (error) {
    if (kDebugMode) debugPrint('设备身份:refresh 请求失败:$error');
    return null;
  } finally {
    client.close();
  }
}

/// 机型的自述值:`{manufacturer, model}`,来自原生 `Build.MANUFACTURER` / `Build.MODEL`。
///
/// 走的是**独立**的原生方法(见 DeviceIdentity.kt 的 deviceInfo),不经过 `createKey` ——
/// 刷新这条路不该为了报个机型去读(甚至生成)设备密钥。原生不认识这个方法(更老的包)或者
/// 报错,都回空表:服务端那边空值不当覆盖。
Future<Map<String, String>> _nativeDeviceInfo() async {
  try {
    final info = await _deviceChannel.invokeMapMethod<Object?, Object?>('deviceInfo');
    return <String, String>{
      'manufacturer': '${info?['manufacturer'] ?? ''}',
      'model': '${info?['model'] ?? ''}',
    };
  } catch (_) {
    return const <String, String>{};
  }
}

/// 打一个 GET,拿 JSON 对象。任何失败都返回 null(这条路全是静默的)。
Future<Map<String, dynamic>?> _getJson(String url) async {
  final client = deviceClientFactory();
  try {
    final response = await client.get(Uri.parse(url)).timeout(_httpTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (kDebugMode) {
        debugPrint('设备身份:$url 应答 HTTP ${response.statusCode}');
      }
      return null;
    }
    return _decodeJson(response.bodyBytes);
  } catch (error) {
    if (kDebugMode) debugPrint('设备身份:$url 请求失败:$error');
    return null;
  } finally {
    client.close();
  }
}

Map<String, dynamic>? _decodeJson(List<int> bytes) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// 本机版本号,形如 `3.3.0+20`(= pubspec 的 `version:` 那一行)。
Future<String> _appVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    final version = info.version.trim();
    if (version.isEmpty) return _fallbackAppVersion;
    final build = info.buildNumber.trim();
    return build.isEmpty ? version : '$version+$build';
  } catch (_) {
    // 插件不可用(用例环境)。服务端当前只把它记进日志,不参与判定。
    return _fallbackAppVersion;
  }
}

/// 本机 Android API 级别(`Build.VERSION.SDK_INT`)。
///
/// 从原生问,不解析 `Platform.operatingSystemVersion`:那句字符串的形态各引擎版本
/// 不一定一样,拿它去正则抠数字是在赌。
Future<int?> _androidApi() async {
  try {
    return await _deviceChannel.invokeMethod<int>('androidApi');
  } catch (_) {
    return null;
  }
}

/// 当前设备 id;没注册就是 null。
///
/// **只读内存**,不去问 SharedPreferences —— 两个理由:
///
/// 1. [deviceHeaders] 是**每个解析请求**都要走的一条路,一次偏好存储的往返在冷启动
///    那几秒里是白花的钱;而且那份 id 本来就该由 [ensureDeviceIdentity](启动时跑一次)
///    填进来,轮不到这里每次再查一遍;
/// 2. 更要紧的是它**不能成为请求的前置条件**。widget 用例里没有注册过设备,那种环境下
///    `SharedPreferences.getInstance()` 的通道没人应答,这个 Future 就永远不完成 ——
///    解析请求会跟着一起挂住(实测:解析页用例整片超时)。「拿不到头就照常发」这条降级
///    不该被一个偏好的读卡死。
String? _deviceId() =>
    (_cachedDeviceId?.isEmpty ?? true) ? null : _cachedDeviceId;

/// 给一个请求拼四个签名头。**没注册或签名失败就返回空 Map** —— 调用方据此不加头,
/// 请求照常发出去(服务端 `log` 模式下照样放行)。
///
/// ⚠️ 这里用的 id 来自 [ensureDeviceIdentity] 填的那份内存状态(见 [_deviceId]):没跑过它
/// (或那个 id 还没到位)就返回空 Map,**请求照常发出去** —— 这条路绝不能反过来等偏好存储。
///
/// [path] 是路径(`/parse`),[rawQuery] 是问号后面那一整段原始查询串(没有就是空串)。
/// 这两个必须和真正发出去的那个 URL 完全一致:签名里含 `PATH` 与查询串摘要,差一个
/// 字符服务端就算不过 —— 所以调用方要用 `uri.path` / `uri.query`,别自己拼。
Future<Map<String, String>> deviceHeaders(
  String method,
  String path,
  String rawQuery,
) async {
  final deviceId = _deviceId();
  if (deviceId == null) return const <String, String>{};

  final timestamp = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
  final nonce = deviceNonce();
  final payload = canonicalPayload(
    method: method,
    path: path,
    rawQuery: rawQuery,
    timestamp: timestamp,
    nonce: nonce,
    deviceId: deviceId,
  );
  // 只把「拼串」交给原生:签名要过安全芯片,那边拿到的是一段字节(见原生 sign)。
  final String? signature;
  try {
    signature = await _deviceChannel.invokeMethod<String>(
      'sign',
      <String, String>{'payload': base64.encode(utf8.encode(payload))},
    );
  } catch (error) {
    if (kDebugMode) debugPrint('设备身份:签名失败:$error');
    return const <String, String>{};
  }
  if (signature == null || signature.isEmpty) return const <String, String>{};
  return <String, String>{
    kDeviceHeaderName: deviceId,
    kDeviceHeaderTs: timestamp,
    kDeviceHeaderNonce: nonce,
    kDeviceHeaderSig: signature,
  };
}
