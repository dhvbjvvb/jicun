import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_host.dart';
import 'failure.dart';
import 'preferred_ip.dart';
import 'ui/prefs.dart';

/// 「赞助名单」的数据源:服务端下发的 /sponsors.json + 落盘缓存 + 内置兜底。
///
/// 背景:这张表以前是编译进包里的常量(见 lib/pages/settings.dart 的 SponsorPage),
/// 改一行就得发一个版。现在服务端那位小兄弟
/// (/usr/local/bin/jicun-sponsors.py,源文件在 deploy/jicun-sponsors.py)按需去飞书
/// 多维表格拉全表、写成静态 JSON,APP 这边只要读它 —— **改表不用发版**。
///
/// 三层兜底,和 [PreferredIpUpdater] 拉 /ips.json 同一个路数:
///   1. 内置常量 [kSponsorFallback]:从没联网成功过也有一份能看的表;
///   2. SharedPreferences 缓存:上次拉到的那份,冷启动第一帧就能用;
///   3. 网络:页面打开时在后台刷,回来再重画。
/// 任何一层失败都不是错误路径,继续用手里那份就是。
///
/// 为什么不直连飞书:tenant_access_token 要用 app_secret 换,secret 打进 APK
/// 等于公开;分享链接又是个前端渲染的 SPA,抓不到 JSON。所以必须有一层中转,
/// 既然有中转,APP 直接读静态 JSON 最省。
typedef Sponsor = (String, String, String);

/// 内置兜底名单,内容就是改造前硬编码进 SponsorPage 的那 8 行。
///
/// **只在一次都没成功从网上拉到过时才会被看到。** 它和服务端那份的差别只有
/// 一行:表里多了一条 "*° / 10月1日 / ¥0.50"(后来补捐的),联网一次之后
/// 就会被真实数据覆盖。别拿它当"最新",它是"能不能显示"的底线。
const List<Sponsor> kSponsorFallback = <Sponsor>[
  ('*', '10月1日', '¥10.00'),
  ('*（特殊符号）', '9月30日', '¥5.00'),
  ('*钱', '9月30日', '¥10.00'),
  ('*😵', '9月29日', '¥3.74'),
  ('Z*Q', '9月29日', '¥2.00'),
  ('*海：', '9月28日', '¥5.00'),
  ('Q*N：', '9月26日', '¥8.88'),
  ('*（特殊符号）', '9月25日', '¥6.66'),
];

/// 解析 /sponsors.json 的响应体。
///
/// 这是信任边界:内容来自网络,之后会被原样画到界面上。所以每个字段都过一遍
/// [_clean](剥控制字符 + 截断),昵称为空的条目直接丢,整表有条数上限 ——
/// 一份被灌了几万条的表会让这个页面在构建时卡住。
///
/// 坏数据一律跳过、坏 JSON 返回空表,不抛异常:拉不到就用手里那份旧的,
/// 这不是错误。和 [parseServerConfig] 是同一套写法,故意的。
List<Sponsor> parseSponsors(String body, {int max = kMaxSponsors}) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return const <Sponsor>[];
  }
  if (decoded is! Map) return const <Sponsor>[];
  final Object? raw = decoded['sponsors'];
  if (raw is! List) return const <Sponsor>[];

  final result = <Sponsor>[];
  for (final Object? item in raw) {
    if (item is! Map) continue;
    final String name = _clean(item['name'], kMaxSponsorName);
    // 没昵称的行没有展示意义(服务端也会把空行滤掉,这里是第二道闸)。
    if (name.isEmpty) continue;
    result.add((
      name,
      _clean(item['date'], kMaxSponsorDate),
      _clean(item['amount'], kMaxSponsorAmount),
    ));
    if (result.length >= max) break;
  }
  return result;
}

/// 单个字段的净化:剥掉控制字符(含换行、制表)再去首尾空白,最后截断。
///
/// 控制字符必须剥 —— 昵称是用户自己填的,一个换行就能把表格的一行撑成两行。
String _clean(Object? value, int limit) {
  if (value is! String) return '';
  final String text = value.replaceAll(_controlChars, '').trim();
  return text.length <= limit ? text : text.substring(0, limit);
}

final RegExp _controlChars = RegExp(r'[\u0000-\u001f\u007f]');

/// 整表条数上限。服务端那位同步脚本自己就卡在 200 行(deploy/jicun-sponsors.py
/// 的 MAX_ROWS),这里跟着它,免得将来两边不一致。
const int kMaxSponsors = 200;

/// 昵称上限,和服务端 NAME_LIMIT 一致。
const int kMaxSponsorName = 32;

/// 日期上限,和服务端 DATE_LIMIT 一致。
const int kMaxSponsorDate = 16;

/// 金额上限,和服务端 AMOUNT_LIMIT 一致。
const int kMaxSponsorAmount = 16;

/// 缓存里的原文超过这个长度就不落盘了。9 行表大概 400 字节,64K 是"这肯定不对劲"
/// 的界线 —— 别让一份畸形的响应把偏好存储撑坏。
const int kMaxSponsorCache = 64 * 1024;

/// 全局唯一实例。名单和域名一样是应用级状态,没必要一路传参。
final SponsorStore sponsorStore = SponsorStore();

/// 赞助名单的持有者:落盘缓存 + 网络刷新 + 变更通知。
///
/// 界面只读 [list],并在 ListenableBuilder 里重建 —— 刷新回来自己会重画,
/// 打开页面的那个瞬间永远不等网络。
class SponsorStore extends ChangeNotifier {
  SponsorStore({http.Client? client}) : _client = client ?? http.Client();

  static const Duration _timeout = Duration(seconds: 8);

  /// 两次网络刷新之间的最短间隔。服务端那边 5 秒(见 STALE_SECONDS)就认为
  /// 自己的文件旧了、来请求时当场去飞书拉一遍;APP 这边留宽一点(10 秒),
  /// 挡的是"连着开关几次这个页面"的重复请求,又不至于让人看到十几秒前的表。
  static const Duration _minRefreshInterval = Duration(seconds: 10);

  final http.Client _client;

  /// 用例里把**整条**取数换掉。换的是整条: [_fetch] 先走普通 client,失败还会拿
  /// [PreferredIpUpdater.fallbackClientFactory] 的优选 IP 连接器再试一遍 ——
  /// 只替一个的话另一个照样会去连真接口。给 null 就是恢复真网络。
  @visibleForTesting
  Future<String?> Function(Uri uri)? fetchOverride;

  List<Sponsor> _list = kSponsorFallback;

  /// 当前该显示的那份。第一帧之前是内置兜底,读过缓存之后是缓存,
  /// 网络回来之后是最新的。
  List<Sponsor> get list => _list;

  bool _cacheLoaded = false;
  bool _inFlight = false;
  DateTime? _lastAttemptAt;

  /// 把落盘的缓存读回来。**同步**,故意做成同步的:bootstrap 要在第一帧之前
  /// 调它,而 SharedPreferences 的读在拿到实例之后本来就是内存操作。
  ///
  /// [cached] 为 null(从没拉到过)或解析结果为空就什么都不做,继续用兜底。
  void loadCached(String? cached) {
    _cacheLoaded = true;
    if (cached == null) return;
    final List<Sponsor> parsed = parseSponsors(cached);
    if (parsed.isEmpty) return;
    _list = parsed;
    notifyListeners();
  }

  /// 页面的入口:缓存没读过就读一次,然后按 [_minRefreshInterval] 决定要不要刷新。
  ///
  /// 幂等,连着调没事 —— 页面每次 initState 都会调,而网络那一步被时间闸门挡着。
  Future<void> ensureLoaded() async {
    if (!_cacheLoaded) {
      try {
        final prefs = await SharedPreferences.getInstance();
        loadCached(prefs.getString(kPrefsSponsors));
      } catch (_) {
        // 读不到偏好不是错误,继续用兜底。
        _cacheLoaded = true;
      }
    }
    await refresh(minInterval: _minRefreshInterval);
  }

  /// 拉一次并生效。[minInterval] 之内已经试过就直接返回。
  ///
  /// 任何失败都只是"这次没刷成":手里的那份继续用,不抛异常、不清空。
  Future<void> refresh({Duration minInterval = Duration.zero}) async {
    final DateTime now = DateTime.now();
    final DateTime? last = _lastAttemptAt;
    if (last != null && now.difference(last) < minInterval) return;
    if (_inFlight) return;
    _inFlight = true;
    _lastAttemptAt = now;
    try {
      final String? body = await _fetch();
      if (body == null) return;
      final List<Sponsor> parsed = parseSponsors(body);
      // 拉回来是空表就当作没拉到:宁可显示旧的那份,也不要把表格清空。
      if (parsed.isEmpty) return;
      _list = parsed;
      notifyListeners();
      await _save(body);
    } catch (error, stack) {
      // 网络问题不是错误路径,继续用手里那份。
      swallow('sponsor.refresh', error, stack);
    } finally {
      _inFlight = false;
    }
  }

  /// 普通线路先打,全挂了再换带优选 IP 连接器的 client 来一遍。
  ///
  /// 顺序和 [PreferredIpUpdater.fetch] 一致,理由也一样:当前域名被运营商按 SNI
  /// 阻断时只有连接器那条路出得去,而连接器整个失效时普通线路是唯一的备选。
  Future<String?> _fetch() async {
    final Uri uri = Uri.parse(apiUrl('/sponsors.json'));
    final Future<String?> Function(Uri uri)? override = fetchOverride;
    if (override != null) return override(uri);
    final String? plain = await _get(_client, uri);
    if (plain != null) return plain;
    return _get(PreferredIpUpdater.fallbackClientFactory(), uri);
  }

  Future<String?> _get(http.Client client, Uri uri) async {
    try {
      final http.Response response = await client.get(uri).timeout(_timeout);
      if (response.statusCode != 200) return null;
      return utf8.decode(response.bodyBytes);
    } catch (_) {
      return null;
    }
  }

  /// 存原文而不是解析后的结果:下次读回来走同一个 [parseSponsors],
  /// 净化/上限的判据只有一份,不会出现"缓存里的和网上的两套规则"。
  Future<void> _save(String body) async {
    if (body.length > kMaxSponsorCache) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kPrefsSponsors, body);
    } catch (error, stack) {
      // 存不下就算了,下次冷启动退回兜底,不影响这次显示。
      swallow('sponsor.save', error, stack);
    }
  }
}

/// 自测:赞助名单解析的信任边界。逻辑上和 api_host.dart 的 [serverConfigSelfCheck]
/// 是一对 —— 那边的边界是域名/IP,这边的边界是「会原样画到界面上的文本」。
///
/// 完整用例在 test/sponsor_store_test.dart(这一份是给读代码的人看的)。
void sponsorSelfCheck() {
  const String good =
      '{"updated":"2026-10-02T14:52:44+08:00","sponsors":['
      '{"name":"*","date":"10月1日","amount":"¥10.00"},'
      '{"name":"*°","date":"10月1日","amount":"¥0.50"}]}';
  final List<Sponsor> ok = parseSponsors(good);
  assert(ok.length == 2, '正常响应应解析出两条');
  assert(ok.first == ('*', '10月1日', '¥10.00'), '字段顺序:昵称/日期/金额');

  assert(parseSponsors('{bad json').isEmpty, '坏 JSON 应为空');
  assert(parseSponsors('[]').isEmpty, '顶层不是对象应为空');
  assert(parseSponsors('{"sponsors":"nope"}').isEmpty, 'sponsors 不是数组应为空');
  assert(
    parseSponsors(
      '{"sponsors":[{"name":"","date":"x","amount":"y"},'
      '{"date":"x","amount":"y"}]}',
    ).isEmpty,
    '没昵称的条目应跳过',
  );
  assert(
    parseSponsors('{"sponsors":[{"name":"a\nb","date":"x","amount":"y"}]}')
            .single
            .$1 ==
        'ab',
    '昵称里的换行应剥掉',
  );
  final String longName = List<String>.filled(100, 'x').join();
  assert(
    parseSponsors('{"sponsors":[{"name":"$longName","date":"y","amount":"z"}]}')
            .single
            .$1
            .length ==
        kMaxSponsorName,
    '超长昵称应截断',
  );
}
