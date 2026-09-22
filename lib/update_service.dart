import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'api_host.dart';
import 'preferred_ip.dart';

/// 「检查更新」这件事的全部非 UI 逻辑:去哪儿问、怎么比版本、怎么下 APK。
///
/// 注意这个文件**现在会 import Flutter**(`services.dart`,为了查 ABI 那个平台
/// 通道),所以 `dart run tool/update_probe.dart` 那条路子已经不通了 ——
/// `dart:ui` 在纯 Dart 环境里没有。要验链路就在真机上开日志:
///
///     flutter run --profile --dart-define=JICUN_UPDATE_TRACE=true
///
/// 会逐条打出候选地址的结局和耗时,比探针更贴近真实网络。

/// 开源仓库。
const String kRepoOwner = 'dhvbjvvb';

const String kRepoName = 'jicun';

/// 逐条候选地址的耗时/结局要不要打到控制台。
///
/// 编译期开关,**默认关**:线上不发一行日志。
///
///     flutter run --profile --dart-define=JICUN_UPDATE_TRACE=true
///
/// 为什么需要它:更新链路的表现**因网络出口而异**(同一台机器在桌面机通、
/// 在手机 5G 上被 reset,实测过)。出问题时第一件要知道的事就是"哪条线路多久
/// 回了什么",而这个只有真机打日志能回答 —— 不用为了看一眼临时改代码再回滚。
const bool _kTraceUpdates = bool.fromEnvironment('JICUN_UPDATE_TRACE');

void _trace(String message) {
  if (_kTraceUpdates) {
    // ignore: avoid_print —— 只在显式打开开关时才有输出
    print('[update] $message');
  }
}

/// 公共 GitHub 加速镜像。GitHub 在国内直连经常几 KB/s 甚至连不上,检查更新和
/// 下 APK 都先走这些镜像。
///
/// **为什么不走我们自己那台反代**:2026-09 真机实测(5G,中国电信线路):
///
///   gh-proxy.com        能代理 **api.github.com**(不只是文件下载),842ms 拿到 JSON。
///                       代理文件下载也通(实测 682ms 起,Content-Length 正确),
///                       所以检查更新和下载 APK 可以共用同一个前缀。
///   hk.gh-proxy.com     同一家的香港入口,1792ms。排在后面当备选。
///   mxper.cc.cd         手机网络上直接 Connection reset by peer(SNI 被阻断);
///                       桌面机却通 —— 换出口就换结果,所以它不能当主力。
///   videofix.top        能连通,但**没配** /github 那两个 location,回 404。
///   api.github.com      直连,手机多半到不了;桌面机 679ms(同样不作数)。
///
/// 那两条自建反代仍然留在候选里当兜底(服务端补齐配置后它们会重新变快)。
///
/// 用法:把完整的 GitHub 地址接在后面,例如
///   `https://gh-proxy.com/https://api.github.com/repos/<owner>/<repo>/releases/latest`
const List<String> kGitHubMirrors = <String>[
  'https://gh-proxy.com',
  'https://hk.gh-proxy.com',
];

/// 自建反代的地址。取自 [apiHost](服务端可以下发新域名,见 api_host.dart),
/// 所以是 getter 而不是 const。
///
/// 发版时不用动它;真机联调更新链路时可以临时改指向本机:
///   flutter run --dart-define=JICUN_MIRROR=http://127.0.0.1:8080
/// (配合 `adb reverse tcp:8080 tcp:8080`。注意这样下到的是明文 http,只在调试时用。)
const String _kMirrorOverride = String.fromEnvironment('JICUN_MIRROR');

String get kMirrorBase =>
    _kMirrorOverride.isNotEmpty ? _kMirrorOverride : apiUrl('/github');

/// 直连地址。所有加速都不通时的最后兜底。
String get kReleasesApi =>
    'https://api.github.com/repos/$kRepoOwner/$kRepoName/releases/latest';

/// 走自建反代的 release 接口。
String get kMirrorReleasesApi => '$kMirrorBase/releases/latest';

/// 检查更新要问的地址。
///
/// 公共镜像排前面:实测它们才是**真能答上来**的那几条。谁先答听谁的
/// (见 [UpdateService.fetchLatest]),顺序只影响"平时谁先答"。
List<String> get kReleasesApis => <String>[
  for (final mirror in kGitHubMirrors) '$mirror/$kReleasesApi',
  kMirrorReleasesApi,
  kReleasesApi,
];

/// 直接问 GitHub 本体(或自建反代直转 GitHub)的那两条。
///
/// 它们回的 404 是 GitHub 自己的话,可以当"仓库里确实没有 release"的依据;
/// 镜像站回的 404 只说明它自己没给出东西,不能当依据(见 [UpdateService.fetchLatest])。
List<String> get _directReleaseApis => <String>[
  kMirrorReleasesApi,
  kReleasesApi,
];

/// 直连的资产下载地址。
String kReleaseAssetUrl(String tag, String name) =>
    'https://github.com/$kRepoOwner/$kRepoName/releases/download/'
    '${Uri.encodeComponent(tag)}/${Uri.encodeComponent(name)}';

/// 走自建反代的资产下载地址。
String kMirrorAssetUrl(String tag, String name) =>
    '$kMirrorBase/dl/${Uri.encodeComponent(tag)}/${Uri.encodeComponent(name)}';

/// 走公共镜像的资产下载地址。
String kGitHubMirrorAssetUrl(String mirror, String tag, String name) =>
    '$mirror/${kReleaseAssetUrl(tag, name)}';

/// 下 APK 时按顺序试的镜像地址(自建反代放最后:它现在多半不通,但配置补齐后能用)。
///
/// 和检查更新同一个前缀,所以镜像站点一旦集体失效,两边会一起失效 ——
/// 这也是直连必须留在候选里的原因。
List<String> kAssetMirrorUrls(String tag, String name) => <String>[
  for (final mirror in kGitHubMirrors) kGitHubMirrorAssetUrl(mirror, tag, name),
  kMirrorAssetUrl(tag, name),
];

/// 版本号:按「.」切成数字段。`v1.1.0`、`1.1`、`1.1.0-beta.1` 都认,认不出返回空表。
List<int> parseVersion(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return const <int>[];
  if (text[0] == 'v' || text[0] == 'V') text = text.substring(1);
  // 预发布/构建元数据不参与比较:1.1.0-beta.1 就按 1.1.0 算。更新提示宁可早一点,
  // 也不要因为对方挂了个 `-beta` 就把正式版判成"不是新版"。
  text = text.split(RegExp(r'[-+]')).first;
  if (text.isEmpty) return const <int>[];
  final parts = text.split('.');
  final out = <int>[];
  for (final part in parts) {
    // 纯数字才算:数字后面跟字母的(如 `1b`)截到数字为止
    final match = RegExp(r'^\d+').firstMatch(part);
    if (match == null) return const <int>[];
    out.add(int.parse(match.group(0)!));
  }
  return out;
}

/// [remote] 是不是比 [local] 新。缺的段按 0 补:`1.1` 与 `1.1.0` 相等。
///
/// 任何一边认不出(空表)都算"不是新版" —— 认不出来就别去骚扰用户。
bool isNewerVersion(String remote, String local) {
  final a = parseVersion(remote);
  final b = parseVersion(local);
  if (a.isEmpty || b.isEmpty) return false;
  final length = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// 一个可以升级的版本。
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.notes,
    required this.apkName,
    required this.mirrorUrls,
    required this.directUrl,
    this.publishedAt,
  });

  /// release 的 tag,例如 `v1.1.0`。
  final String tag;

  /// release 说明(markdown)。
  final String notes;

  /// APK 资产名,例如 `jicun-1.1.0.apk`。
  final String apkName;

  /// 下 APK 时按顺序试的镜像地址,最后再回落 [directUrl](见 [UpdateService.downloadApk])。
  final List<String> mirrorUrls;

  /// 直连 GitHub 的地址,所有镜像都不通时的兜底。
  final String directUrl;

  /// 第一条镜像地址。探针和测试用它当"那个镜像"的代表。
  String get mirrorUrl => mirrorUrls.first;

  final DateTime? publishedAt;

  String get version => tag.startsWith('v') ? tag.substring(1) : tag;
}

/// 「检查更新」这趟的任何失败。消息是给人看的。
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一条候选地址问下来的结果。
///
/// 为什么需要一个类型而不是直接回 `ReleaseInfo?`:两种"没有版本"必须分得开 ——
/// 「200,答完了,就是没有新版」和「404,我这条线路上根本没这个接口,去问别人」。
/// 前者是最终答案,后者还要接着等(见 [UpdateService.fetchLatest])。
enum _FetchOutcome {
  /// 解析出版本了。
  release,

  /// 回 404:路径没配、或者仓库里还没有 release —— 别处可能有,继续问。
  notHere,

  /// 200 但没有可用 APK:答完了,就是没有新版。
  noRelease,
}

class _FetchResult {
  const _FetchResult(this.outcome, [this.release]);

  final _FetchOutcome outcome;

  /// 只有 [outcome] 是 [_FetchOutcome.release] 时非空。
  final ReleaseInfo? release;
}

/// 从 release 的 JSON 里挑出要下的那个 APK。
///
/// 按需求资产名带版本号(`jicun-1.1.0.apk`),所以不认死名字:取第一个 `.apk`。
/// 顺手跳过 GitHub 自动附带的 `source code` 那两个压缩包。
Map<String, dynamic>? pickApkAsset(Map<String, dynamic> release) {
  final assets = release['assets'];
  if (assets is! List) return null;
  for (final asset in assets) {
    if (asset is! Map) continue;
    final name = asset['name'];
    if (name is! String || !name.toLowerCase().endsWith('.apk')) continue;
    return asset.cast<String, dynamic>();
  }
  return null;
}

/// 本机 CPU 架构。查不到(非 Android / 测试环境)返回 null。
///
/// 为什么必须问原生:`android.os.Build.SUPPORTED_ABIS` 在 Dart 侧拿不到,而拿错
/// 架构的包,系统安装器会直接以「应用未安装」拒掉 —— 不是能靠猜的事。
const MethodChannel _installChannel = MethodChannel('jicun/downloader');

Future<String?> deviceAbi() async {
  try {
    final abi = await _installChannel.invokeMethod<String>('supportedAbi');
    return abi == null || abi.isEmpty ? null : abi;
  } catch (_) {
    return null;
  }
}

/// 按本机 ABI 挑安装包。挑不出对应架构时返回 null,由调用方退回通用包。
///
/// 只按「资产名里有没有这个 ABI」判断,不依赖任何命名顺序 —— 发版时把拆分包和
/// 通用包一起挂上去,老版本 APP(只会拿第一个 `.apk`)照样能用。
Map<String, dynamic>? pickApkAssetForAbi(
  Map<String, dynamic> release,
  String? abi,
) {
  if (abi == null) return null;
  final assets = release['assets'];
  if (assets is! List) return null;
  final needle = abi.toLowerCase();
  for (final asset in assets) {
    if (asset is! Map) continue;
    final name = asset['name'];
    if (name is! String) continue;
    final lower = name.toLowerCase();
    if (!lower.endsWith('.apk')) continue;
    if (lower.contains(needle)) return asset.cast<String, dynamic>();
  }
  return null;
}

/// 把 release 的 JSON 映射成 [ReleaseInfo]。缺 APK 或者 tag 认不出就返回 null。
///
/// [abi] 是本机架构(release 挂了按 ABI 拆分的小包时才有用,见
/// [pickApkAssetForAbi]);不给或匹配不上就用通用包。
ReleaseInfo? releaseFromJson(Map<String, dynamic> json, {String? abi}) {
  final tag = json['tag_name'];
  if (tag is! String || tag.isEmpty) return null;
  if (parseVersion(tag).isEmpty) return null;
  final asset = pickApkAssetForAbi(json, abi) ?? pickApkAsset(json);
  if (asset == null) return null;
  final name = asset['name'] as String;
  final published = json['published_at'];
  return ReleaseInfo(
    tag: tag,
    notes: json['body'] is String ? json['body'] as String : '',
    apkName: name,
    mirrorUrls: kAssetMirrorUrls(tag, name),
    directUrl: kReleaseAssetUrl(tag, name),
    publishedAt: published is String ? DateTime.tryParse(published) : null,
  );
}

/// 下载进度:收了 [received] 字节,整条 [total] 字节(不知道总量时为 0)。
class ApkProgress {
  const ApkProgress({required this.received, required this.total});

  final int received;
  final int total;

  /// 0~1。总量未知时按 0 报,由界面决定显示什么。
  double get fraction =>
      total <= 0 ? 0 : (received / total).clamp(0.0, 1.0).toDouble();
}

/// 用户点了取消。
class UpdateCancelled implements Exception {
  const UpdateCancelled();

  @override
  String toString() => '更新已取消';
}

/// 检查更新 + 下载安装包。
class UpdateService {
  UpdateService({http.Client? client}) : _client = client ?? clientFactory();

  /// 造 http client 的方式。留成静态字段**只为了让测试换成 MockClient** ——
  /// 否则一个用例就要真去问一次 GitHub。生产代码不碰它。
  ///
  /// 生产环境挂上优选 IP,和 [ParseService.clientFactory] 同一套:得自己造
  /// `HttpClient` 才拿得到 `connectionFactory`(`http.Client()` 内部那个实例摸不着)。
  ///
  /// 为什么检查更新也需要它:候选里那条自建反代在 Cloudflare 后面,DNS 会给出 AAAA
  /// 记录,而国内走 IPv6 多半被黑洞 —— 实测要 2.9 秒才回落 v4,比公共镜像的 0.7~1.2
  /// 秒慢一截。优选 IP 做的就是"把若干个连接目标赛跑,谁先握手成功用谁",正好治它。
  /// 它只对自己的连接生效;镜像域名(gh-proxy.com 这类)不在域名表里,走系统 DNS。
  static http.Client Function() clientFactory = () => IOClient(
    HttpClient()
      ..connectionFactory = PreferredIpConnector(
        onWinner: PreferredIpUpdater.instance.reportWinner,
        onHost: (_) => PreferredIpUpdater.instance.refresh(),
      ).connect,
  );

  /// 查本机架构的方式。同样只为测试留的口子:用例里没有平台通道,真去问会白等
  /// 一个 channel 往返。
  static Future<String?> Function() abiResolver = deviceAbi;

  /// 只给测试换实现用。
  final http.Client _client;

  /// 接口超时。国内走反代一般一两秒,8 秒还没回就当它不通,直接换下一条。
  static const Duration _apiTimeout = Duration(seconds: 8);

  /// 所有候选地址**并行**问,最快的那个先给出结果。等这么久还没有任何一条回来
  /// 就整体判失败。
  ///
  /// 为什么是并行不是顺序:候选之间实测差 3.4 秒(videofix.top 的 IPv6 黑洞),
  /// 顺序试的话用户就要坐在那儿等第一个把超时耗完。三条一起发,拿到就是最快那条。
  /// 代价是多打两发请求 —— 只是个几 KB 的 GET,比多等 2 秒划算。
  static const Duration _raceTimeout = Duration(seconds: 10);

  /// 下载一条最多等多久没有数据。
  static const Duration _idleTimeout = Duration(seconds: 30);

  /// 问一次最新版本。
  ///
  /// 所有候选地址**并行**问,最先给出答案的那条说了算:
  /// - 200 且能解析出 release → 就是它,其余作废;
  /// - 200 但没挂 APK → "没有新版",也是最终答案,不再等别人;
  /// - 404 → 继续等别人。反代/CDN 没配这条路径时也是 404,分不出来,把它当最终
  ///   答案会让 APP 停在一条坏线路上;
  /// - 其它状态码/异常 → 记下来换别人。
  ///
  /// 全部候选都没有 release 时,报"没有新版"要有一个**说得住的依据**:只有那两个
  /// 直问 GitHub 的地址([_directReleaseApis])也说了没有,才算数 —— 它们是权威来源,
  /// 而镜像站返回什么形状我们都只能信它自己的话。依据不足就按失败报(见下面 settle)。
  ///
  /// [urls] 只是给测试指定"只试这几条"用的,APP 里不传。
  Future<ReleaseInfo?> fetchLatest({List<String>? urls}) async {
    // 问一次本机架构:release 里拆了 ABI 包时,通用包不该下(白白多一倍体积,
    // 少数机器上还会因为架构不匹配装不上)。查不到就是 null,退回通用包。
    final abi = await abiResolver();
    final candidates = urls ?? kReleasesApis;
    final completer = Completer<ReleaseInfo?>();
    final failures = <String>[];
    final notHere = <String>[];
    var pending = candidates.length;
    // 权威地址(GitHub 本体 / 自建反代直连 GitHub)是否明确说过"没有 release"
    var authoritativeAbsence = false;

    /// 一条候选问完了。[error] 非空 = 这条不通(网络错、非 200);否则看 [fetch]
    /// 的三种结局。三条路必须分开:上一版把"网络不通"和"200 但没有新版"混成
    /// 同一个 null,于是两条候选都挂掉时会报"当前已是最新版本" —— 一句都没问到。
    void settle(_FetchResult? fetch, {String? error, String? url}) {
      pending--;
      if (error != null) {
        failures.add('$url → $error');
      } else if (fetch!.outcome == _FetchOutcome.release) {
        // 拿到版本就是最终答案,不必等剩下的候选
        if (!completer.isCompleted) completer.complete(fetch.release);
        return;
      } else if (fetch.outcome == _FetchOutcome.notHere) {
        // 404:这条线路上没这个接口,或者仓库里没有 release,别处可能有,继续等
        notHere.add('$url → HTTP 404');
        if (_directReleaseApis.contains(url)) authoritativeAbsence = true;
      } else {
        // 200 但没有可用 APK:这是最终答案("没有新版")。它对任何线路都成立,
        // 不必等别人 —— 等下去只会多花一整个超时。
        if (!completer.isCompleted) completer.complete(null);
        return;
      }
      // 权威地址已经说了没有 release,而且这是唯一可能的答案了(release 会提前
      // return),就不必再等那条慢的 —— 否则用户要多等它两三秒(实测 videofix.top
      // 要 2.4~5.9 秒,而直连 GitHub 0.1~0.7 秒就答了)。
      if (authoritativeAbsence && failures.isEmpty) {
        if (!completer.isCompleted) completer.complete(null);
        return;
      }
      if (pending > 0 || completer.isCompleted) return;

      // 有候选给出过 release 就不会走到这儿。剩下的可能:
      //   全 404          → 真的没有发布版本,不是失败
      //   有失败          → 谁也没说"没有版本",算失败,并把每条的去向都带上
      //                     (只报失败那条会让人以为别处没问题,而别处其实也 404 了)
      if (failures.isEmpty) {
        completer.complete(null);
      } else {
        completer.completeError(
          UpdateException(
            '检查更新失败,请稍后再试。\n${[...failures, ...notHere].join('\n')}',
          ),
        );
      }
    }

    for (final url in candidates) {
      final started = Stopwatch()..start();
      unawaited(
        _fetchOne(url, abi).then(
          (fetch) {
            _trace(
              '$url → ${fetch.outcome.name}  ${started.elapsedMilliseconds}ms',
            );
            settle(fetch, url: url);
          },
          onError: (Object error) {
            _trace('$url → 失败  ${started.elapsedMilliseconds}ms  $error');
            settle(null, url: url, error: '$error');
          },
        ),
      );
    }

    // 全都卡住时别把「检查更新」晾在那儿转圈。
    return completer.future.timeout(
      _raceTimeout,
      onTimeout: () => throw UpdateException(
        '检查更新失败,请稍后再试。\n'
        '${failures.isEmpty ? '所有地址都没在 ${_raceTimeout.inSeconds} 秒内回应' : failures.join('\n')}',
      ),
    );
  }

  /// 问一条地址。不通就抛异常(网络错误、非 200、返回体不是对象)。
  Future<_FetchResult> _fetchOne(String url, String? abi) async {
    final response = await _client
        .get(
          Uri.parse(url),
          headers: const <String, String>{
            // 不加 UA 的话 GitHub API 会拒(GitHub 要求带 UA)。
            // 反代转发时也照传,免得两边行为不一致。
            HttpHeaders.userAgentHeader: 'jicun-app',
            'Accept': 'application/vnd.github+json',
          },
        )
        .timeout(_apiTimeout);
    if (response.statusCode == 404) {
      // 404 分两种,靠**响应体**认:GitHub 自己回的 404 是
      //   {"message":"Not Found","documentation_url":...,"status":"404"}
      // 而 nginx/CDN 的默认 404 页是 HTML 或空体。只有前者能当"仓库里还没有
      // release",后者只是这台机器没配这条路径 —— 拿它当答案会把一次失败的检查
      // 说成"当前已是最新版本"。
      if (!_notFoundFromGitHub(response)) {
        throw UpdateException('HTTP 404(不是 GitHub 的应答,这条线路上没配这个接口)');
      }
      return const _FetchResult(_FetchOutcome.notHere);
    }
    if (response.statusCode != 200) {
      throw UpdateException('HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) {
      throw UpdateException('返回体不是对象');
    }
    // 200 就是答完了:认得出 tag、挂得出 APK 才算有新版本,否则就是"没有新版"
    // (仓库确实还没发 release,或者只挂了源码包)。这是**最终答案**,不能再等
    // 别的地址 —— 否则一段认不出的 JSON 会让检查白等一整个超时。
    final release = releaseFromJson(decoded.cast<String, dynamic>(), abi: abi);
    return release == null
        ? const _FetchResult(_FetchOutcome.noRelease)
        : _FetchResult(_FetchOutcome.release, release);
  }

  /// 这个 404 是不是 GitHub API 自己的应答。见 [_fetchOne] 里的说明。
  static bool _notFoundFromGitHub(http.Response response) {
    if (!(response.headers['content-type'] ?? '').contains('json')) {
      return false;
    }
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return decoded is Map && decoded['message'] == 'Not Found';
    } catch (_) {
      return false;
    }
  }

  /// 这条 release 值不值得提示。纯函数,离线可测。
  ///
  /// [localVersion] 是本机版本(来自 package_info),`version: 1.0.0+2` 里的 `1.0.0`;
  /// [ignored] 是用户上次点「忽略」时记住的版本。
  ///
  /// 忽略只在**同一个版本**上生效:用户忽略 1.1.0 之后,仓库发到 1.2.0 还要再弹
  /// (需求就是这么定的)。
  bool shouldPrompt({
    required String localVersion,
    required String? ignored,
    required ReleaseInfo? release,
  }) {
    if (release == null) return false;
    if (!isNewerVersion(release.version, localVersion)) return false;
    if (ignored == null || ignored.isEmpty) return true;
    // 忽略的是这个版本或更旧的版本 → 不再弹;仓库又发了更高的 → 重新弹
    return isNewerVersion(release.version, ignored);
  }

  /// 把 APK 下到 [dir],返回落盘的文件。
  ///
  /// 下到一半取消/失败都不留半个文件,和媒体下载同一条规矩。
  Future<File> downloadApk(
    ReleaseInfo release, {
    required Directory dir,
    required void Function(ApkProgress) onProgress,
    bool Function()? cancelled,
  }) async {
    final target = File('${dir.path}/${release.apkName}.part');
    Object? lastError;
    // 挨个镜像试,最后直连兜底
    for (final url in <String>[...release.mirrorUrls, release.directUrl]) {
      try {
        // **跳转得自己跟**:GitHub 的资产地址一律先 302 到
        // objects.githubusercontent.com(反代把那个 302 原样透传 —— 实测它的响应头
        // 还比 nginx 默认缓冲区大,见 deploy 里的 proxy_buffer_size)。公共镜像
        // (gh-proxy 这类)自己跟完跳转再回 200,所以这条分支在它们身上用不到,
        // 但自建反代那条仍然走这里。
        // 试过 `http.Request.followRedirects = true`,**没用**:那个开关只在
        // package:http 自带的 IOClient 里实现,换成别的 client(测试里的 MockClient)
        // 就是死代码,而这类"只有真机才生效"的分支最不该留着。
        final response = await _sendFollowingRedirects(url);
        if (response.statusCode != 200) {
          lastError = UpdateException('下载失败:HTTP ${response.statusCode}');
          continue;
        }
        final total = response.contentLength ?? 0;
        var received = 0;
        // 直接写文件句柄,不用 `openWrite()` 那个 IOSink:后者的 `flush()/close()`
        // 走的是另一套事件循环,在 widget 测试的假时钟下**永远不会完成**(实测),
        // 于是"点更新"那条路在测试里根本验不动。写文件这点开销相对一次 20MB 的下载
        // 可以忽略,而这条路本来就跑在下载的 await 之间。
        final handle = target.openSync(mode: FileMode.write);
        try {
          await for (final chunk in response.stream.timeout(_idleTimeout)) {
            if (cancelled?.call() ?? false) throw const UpdateCancelled();
            handle.writeFromSync(chunk);
            received += chunk.length;
            onProgress(ApkProgress(received: received, total: total));
          }
          handle.flushSync();
        } catch (_) {
          handle.closeSync();
          if (target.existsSync()) target.deleteSync();
          rethrow;
        }
        handle.closeSync();
        // 少收了字节就是残件:宁可报错也别把一个装不上的包递给系统安装器
        if (total > 0 && received != total) {
          target.deleteSync();
          lastError = UpdateException('安装包不完整:$received/$total 字节');
          continue;
        }
        final file = File('${dir.path}/${release.apkName}');
        if (file.existsSync()) file.deleteSync();
        return target.renameSync(file.path);
      } catch (error) {
        if (error is UpdateCancelled) rethrow;
        lastError = error;
      }
    }
    final failure = lastError;
    throw failure is Exception ? failure : UpdateException('下载失败:$failure');
  }

  /// 发一发 GET,遇到 3xx 自己跟到 [maxRedirects] 跳为止,返回最终那发响应。
  ///
  /// 为什么不直接用 `http.Request.followRedirects`:那个开关只有 package:http 自带的
  /// IOClient 会实现,换成别的 client 就完全不生效 —— 于是"跟跳转"这件事在测试里
  /// 永远验不到,只能靠真机碰。这里自己做,测试才盖得住。
  Future<http.StreamedResponse> _sendFollowingRedirects(
    String url, {
    int maxRedirects = 5,
  }) async {
    var current = url;
    for (var hop = 0; ; hop++) {
      final request = http.Request('GET', Uri.parse(current))
        ..headers['User-Agent'] = 'jicun-app';
      final response = await _client.send(request).timeout(_idleTimeout);
      final next = redirectLocation(response);
      if (next == null) return response;
      // 上一跳的响应体不要了(它只是个跳转页),别让它挂在连接上
      unawaited(response.stream.drain<void>().catchError((Object _) {}));
      if (hop >= maxRedirects) {
        throw UpdateException('下载地址跳转太多次(最后到 $current)');
      }
      current = Uri.parse(current).resolve(next).toString();
    }
  }

  /// 这一跳是不是重定向,是的话返回下一个要打的地址(相对地址按当前地址解出来)。
  static String? redirectLocation(http.StreamedResponse response) {
    final code = response.statusCode;
    if (code != 301 &&
        code != 302 &&
        code != 303 &&
        code != 307 &&
        code != 308) {
      return null;
    }
    final location = response.headers['location'];
    return (location == null || location.isEmpty) ? null : location;
  }

  void dispose() => _client.close();
}

/// 已经下好的安装包。
///
/// 存在的理由:用户点更新 → 下完 → 系统安装器要求先开「安装未知应用」权限,
/// 这一步会把人带走。回到 APP 再点一次更新时,不能让他白下一遍 20MB。
///
/// 只认 `apkName`:同一个版本的包还在就直接复用,不校验哈希 —— 我们自己下的包,
/// 系统安装前还会校验签名,这里再算一次摘要换不来什么。
class ApkCache {
  const ApkCache._();

  static File? existing(ReleaseInfo release, Directory dir) {
    final file = File('${dir.path}/${release.apkName}');
    if (!file.existsSync()) return null;
    // 0 字节的残件不算(下到一半被杀进程时会留一个空文件)
    return file.lengthSync() > 0 ? file : null;
  }
}

// ───────────────────────── release 说明的 markdown ─────────────────────────

/// 预览窗口里一行字的样式。只分三档:标题、正文、代码。
enum MdLineKind { heading, body, code }

/// 解析完的一行:纯文本 + 它该用的样式档。
///
/// `[text]` 是人话(标记已经清掉),`[prefix]` 是列表符号那种前缀(没有就是空)。
class MdLine {
  const MdLine(this.text, this.kind, [this.prefix = '']);

  final String text;
  final MdLineKind kind;
  final String prefix;
}

/// 行内标记的处理:去掉 `**`、反引号、链接外壳、图片。
///
/// 刻意只做"翻译成纯文本"这一层:预览窗口要的是行数和可读性,不是排版引擎。
/// 引一个完整的 markdown 包只为了这 12 行字,不划算 —— 而且那些包在滚动区里
/// 每帧都要重排版,滚动条会跟手不动。
String mdInline(String raw) {
  var text = raw;
  // 图片 ![alt](url) → alt
  text = text.replaceAllMapped(
    RegExp(r'!\[([^\]]*)\]\([^)]*\)'),
    (m) => m.group(1) ?? '',
  );
  // 链接 [文字](url) → 文字
  text = text.replaceAllMapped(
    RegExp(r'\[([^\]]*)\]\([^)]*\)'),
    (m) => m.group(1) ?? '',
  );
  // 粗体/斜体/删除线/行内代码:标记直接去掉,样式由 MdLineKind 那几档负责
  text = text
      .replaceAll(RegExp(r'\*\*|__|~~|`'), '')
      .replaceAll(RegExp(r'(?<!\w)\*(?!\s)'), '')
      .replaceAll(RegExp(r'(?<=\S)\*(?!\w)'), '');
  return text.trimRight();
}

/// release 说明(markdown)→ 逐行文本。
///
/// 认这些:标题(`#`~`######`)、无序列表(`-`/`*`/`+`)、有序列表(`1.`)、
/// 引用(`>`)、代码块(``` 围起来的按代码样式)、分割线(丢掉)、空行(保留,当段落间距)。
List<MdLine> parseMarkdown(String source) {
  final lines = <MdLine>[];
  var inCode = false;
  for (final raw in const LineSplitter().convert(source)) {
    final trimmed = raw.trimRight();
    if (trimmed.trimLeft().startsWith('```')) {
      inCode = !inCode;
      continue;
    }
    if (inCode) {
      lines.add(MdLine(trimmed, MdLineKind.code));
      continue;
    }
    final text = trimmed.trimLeft();
    if (text.isEmpty) {
      lines.add(const MdLine('', MdLineKind.body));
      continue;
    }
    // 分割线:预览窗口里没有横线的位置,直接丢
    if (RegExp(r'^([-*_])\s*(\1\s*){2,}$').hasMatch(text)) continue;
    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(text);
    if (heading != null) {
      lines.add(MdLine(mdInline(heading.group(2)!), MdLineKind.heading));
      continue;
    }
    final quote = RegExp(r'^>\s?(.*)$').firstMatch(text);
    if (quote != null) {
      lines.add(MdLine(mdInline(quote.group(1)!), MdLineKind.body, '│ '));
      continue;
    }
    final bullet = RegExp(r'^[-*+]\s+(.*)$').firstMatch(text);
    if (bullet != null) {
      lines.add(MdLine(mdInline(bullet.group(1)!), MdLineKind.body, '• '));
      continue;
    }
    final ordered = RegExp(r'^(\d{1,3})[.)]\s+(.*)$').firstMatch(text);
    if (ordered != null) {
      lines.add(
        MdLine(
          mdInline(ordered.group(2)!),
          MdLineKind.body,
          '${ordered.group(1)}. ',
        ),
      );
      continue;
    }
    lines.add(MdLine(mdInline(text), MdLineKind.body));
  }
  // 头尾的空行去掉,免得预览窗口顶上先空一行
  while (lines.isNotEmpty && lines.first.text.isEmpty) {
    lines.removeAt(0);
  }
  while (lines.isNotEmpty && lines.last.text.isEmpty) {
    lines.removeLast();
  }
  return lines;
}
