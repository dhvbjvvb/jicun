import 'dart:convert';
import 'dart:io';

import 'secrets.dart';

/// 我们自己服务的域名池,以及「当前用哪个域名」这个全局状态。
///
/// 背景:域名会被国内运营商按 SNI 阻断(表现为 `ERR_CONNECTION_RESET`),换 IP、
/// 加优选 IP 都没用 —— 阻断认的是域名。所以域名必须**能在服务端换掉,而不用
/// 重新发版**:APP 启动后从 `/ips.json` 拉一份当前可用的域名表,拉到了就用它,
/// 拉不到就用这里编译进去的兜底。
///
/// 顺序即优先级:第一个是主用域名,后面的是主用域名连不上时的候选。
///
/// **编译期一共两个我们自己的域名,一个都不能省:**
///
///   [ownApiHost]    主用 —— Cloudflare 灰云、DNS 直连源站,国内 ~50ms
///   [escapeApiHost] 逃生 —— Cloudflare 橙云、经 CF 回源,~245ms,但抗 SNI 阻断
///
/// 为什么必须是**两个不同名**的域名:运营商是按 SNI 阻断域名的,那时换 IP、
/// 加优选 IP 都没用,只有换一个没被封的域名才救得回来。如果这里只留一个
/// (也就是把 [ownApiHost] 单独放进来),那 `_fetchWith` 在冷启动、本地还没有
/// 缓存配置时(见 preferred_ip.dart)试的 `apiHost → kApiHosts → remoteHosts`
/// 三条全是同一个域名 —— 域名一旦被墙,APP 连 `/ips.json` 都拉不到,也就永远
/// 不知道还有别的域名可用,新装用户直接卡死。
///
/// 注意这里只是**最初始的入口**。服务端换域名后会把新域名通过 `/ips.json` 的
/// `hosts` 字段推下来(`PreferredIpUpdater._apply` 会 setApiHost),不用重新发版 ——
/// 但那条路的前提是**已经连上某一个域名**,所以列表本身空不得。
const List<String> kApiHosts = <String>[ownApiHost, escapeApiHost];

/// 当前生效的域名。所有请求(解析兜底、预热、更新镜像)都按它拼地址。
///
/// 进程内全局状态,和 `PreferredIpConnector.remote` 同一个路数:连接器活在
/// `HttpClient` 里,拿不到它的地方(启动流程、更新弹窗)也要能读写当前域名,
/// 一路传参只会把签名搅乱。
String _active = kApiHosts.first;

String get apiHost => _active;

/// 换域名。返回是否真的变了 —— 变了的话调用方要把新值落盘。
bool setApiHost(String host) {
  final next = host.trim().toLowerCase();
  if (next.isEmpty || next == _active) return false;
  _active = next;
  return true;
}

/// 把路径拼成我们服务的绝对地址,例如 `apiUrl('/parse')`。
String apiUrl(String path) => 'https://$apiHost$path';

/// 服务端下发的整个配置:可用域名 + 优选 IP + CF 入口域名。
///
/// 这些字段一起下发是有意的:它们来自同一份服务端配置,分两次请求只会在
/// 「域名刚换、IP 还是旧域名那套」这种窗口里制造不一致。
class ServerConfig {
  const ServerConfig({
    this.hosts = const <String>[],
    this.ips = const <String>[],
    this.supported = const <String>[],
    this.cfHost = '',
  });

  /// 可用域名(顺序即优先级:第一个是主用)。
  final List<String> hosts;

  /// 优选 IP 池。**全是 Cloudflare 边缘节点地址**,只能绑到 [cfHost] 上用。
  final List<String> ips;

  /// 走 CF 回源的那个入口域名 —— 优选 IP 的 SNI 与证书校验目标。
  ///
  /// 为什么不直接拿 `hosts.first`:主用域名是**直连**的(不经过 CF),把 CF 的
  /// 边缘 IP 绑到它上面,CF 边缘不认这个域名,握手必然失败 —— 那 3 个赛跑位就
  /// 白占了。服务端单独下发这个字段,APP 就不用再去猜。
  ///
  /// 空串 = 没有可用的 CF 域名,那时干脆不赛跑 IP(见
  /// [PreferredIpConnector.fallbackTargets])。
  final String cfHost;

  /// 服务端**支持**的平台域名 —— 一份**白名单**。不在表里的域名一律本地拦掉，
  /// 一次请求都不发。
  ///
  /// 为什么不发黑名单:解析接口开在公网，谁都能拿任意链接来打。只发"关停的平台"
  /// 那份黑名单的话，名单之外的（TikTok、各种网盘、任何我们不认识的域名）照样会
  /// 被提交，白占一次往返、一条 request_logs、一份限流额度。实测"未识别"那一类
  /// 占了全部请求的三分之一。
  ///
  /// 判据是**精确匹配**（见 [unsupportedPlatformMessage]），和服务端
  /// `DOMAIN_TO_NAME` 的查表语义一致。不能用后缀匹配 —— 实测踩过:
  /// 视频号(已关)名下的 `weixin.qq.com` 会把微信公众号的 `mp.weixin.qq.com` 误伤。
  final List<String> supported;

  bool get isEmpty => hosts.isEmpty && ips.isEmpty && supported.isEmpty;
}

/// 这条链接我们能不能解析。不能就返回给用户看的那句话，能就返回 null。
///
/// **精确匹配主机名**，和服务端 `UrlParser.get_platform` 的 `DOMAIN_TO_NAME.get(domain)`
/// 完全同构 —— 那份表把每个平台名下的子域都单独列了（比如一条平台的 www 和裸域
/// 是两条），所以精确匹配不会漏。
///
/// 别改成后缀匹配:父域会遮蔽子域。`weixin.qq.com` 属于已关的视频号，而
/// `mp.weixin.qq.com` 属于在用的微信公众号 —— 后缀匹配会把后者一起拦掉。
///
/// 列表为空（还没拉到过配置）时一律放行:本地拦是优化，不是正确性的一部分，
/// 不做也不会错，只是多一次往返。
///
/// ⚠️ 调用方必须跳过「走第三方上游」的平台，见 lib/parse_service.dart 的 parse():
///    视频号在服务端是关掉的，所以**不在这份白名单里**，但它在 APP 里完全靠上游。
///    直接拿白名单套它 = 把这个平台整个拒掉（改前确实这么错过一次）。
String? unsupportedPlatformMessage(String url) {
  if (supportedHosts.isEmpty) return null;
  final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
  if (host.isEmpty) return null;
  return supportedHosts.contains(host) ? null : '暂不支持该平台';
}

/// 服务端下发的支持域名表（白名单）。由 [PreferredIpConnector] 在拿到配置时写入，
/// 放这里是为了让 [unsupportedPlatformMessage] 和它的判据待在一起。
List<String> supportedHosts = const <String>[];

/// 解析 `/ips.json` 的响应体。
///
/// 这是信任边界:内容来自网络,之后会被拼进请求地址、并当作 SNI 与证书校验的
/// 目标,或者直接喂给 `Socket.connect()`。所以域名只认长得像域名的条目,IP 只认
/// 解得出来的,两边都有条数上限 —— 一份被灌了十万条的表会让每次建连接都去开
/// 十万个 socket。
///
/// 坏数据一律跳过,不抛异常:拉不到配置不是错误,继续用内置兜底就是了。
ServerConfig parseServerConfig(
  String body, {
  int maxHosts = 4,
  int maxIps = 16,
  int maxSupported = 512,
}) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return const ServerConfig();
  }
  if (decoded is! Map) return const ServerConfig();
  return ServerConfig(
    hosts: parseApiHostList(decoded['hosts'], max: maxHosts),
    ips: parsePreferredIpList(decoded['ips'], max: maxIps),
    // 支持域名表用同一套域名校验（长度、只认 [a-z0-9.-]、带点）。
    // 上限给得比 hosts 宽得多:服务端 50 个平台名下共 176 个域名，其中开启的
    // 20 个平台是 80 条（2026-09-30 实测）。
    supported: parseApiHostList(decoded['supported'], max: maxSupported),
    // 走 CF 回源的那个入口域名。优选 IP 池里全是 Cloudflare 边缘节点地址，
    // 只能绑在它上面 —— 见 PreferredIpConnector.fallbackTargets。
    cfHost: _singleHost(decoded['cf_host']),
  );
}

/// 读一个只有单个值的域名字段（`cf_host` 这种）。
///
/// 复用域名表那套校验（长度、只认 `[a-z0-9.-]`、必须带点、拒绝 `host:port`），
/// 认不出来就当没有。这个值会被拿去当 SNI 与证书校验的目标，不能将就。
String _singleHost(Object? raw) {
  final list = parseApiHostList(<Object?>[raw], max: 1);
  return list.isEmpty ? '' : list.first;
}

/// 解析域名表。只认字母数字开头、只含 `[a-z0-9.-]`、带点的条目。
///
/// 带冒号的(比如 `evil.com:8443`)一律拒绝 —— 免得把端口或 `host:port` 这种
/// 形状带进请求地址。
List<String> parseApiHostList(Object? raw, {int max = 4}) {
  if (raw is! List) return const <String>[];
  final result = <String>[];
  for (final item in raw) {
    if (item is! String) continue;
    final host = item.trim().toLowerCase();
    if (host.length > 253) continue;
    if (!_hostPattern.hasMatch(host)) continue;
    if (result.contains(host)) continue;
    result.add(host);
    if (result.length >= max) break;
  }
  return result;
}

final RegExp _hostPattern = RegExp(
  r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?'
  r'(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$',
);

/// 解析优选 IP 表(形如 `{"ips":["1.2.3.4", ...]}`)。
List<String> parsePreferredIpList(Object? raw, {int max = 16}) {
  if (raw is! List) return const <String>[];
  final result = <String>[];
  for (final item in raw) {
    if (item is! String) continue;
    final ip = item.trim();
    if (InternetAddress.tryParse(ip) == null) continue;
    if (result.contains(ip)) continue;
    result.add(ip);
    if (result.length >= max) break;
  }
  return result;
}

/// 自测:域名/IP 解析的信任边界。不依赖 Flutter,`dart run` 直接可跑。
void serverConfigSelfCheck() {
  assert(
    (parseApiHostList(<String>[
          'API.Example.COM',
          'evil.com:8443',
          'ok.example.com',
          'ok.example.com',
          'x',
        ]) ==
        const <String>['api.example.com', 'ok.example.com']),
    '域名解析:大小写归一、拒绝端口、去重、拒绝单段',
  );
  assert(parseApiHostList('nope').isEmpty, '非列表输入应为空');
  assert(parseApiHostList(<String>['a_b.example.com']).isEmpty, '下划线域名应拒绝');

  final config = parseServerConfig(
    '{"hosts":["a.example.com"],"ips":["1.2.3.4","nope"]}',
  );
  assert(config.hosts.single == 'a.example.com');
  assert(config.ips.single == '1.2.3.4', 'IP 表只认能解析的条目');
  assert(config.cfHost.isEmpty, '没下发 cf_host 就是空串');
  assert(parseServerConfig('{bad json').isEmpty, '坏 JSON 应为空配置');
  assert(
    parseServerConfig('{"cf_host":"cf.example.com"}').cfHost ==
        'cf.example.com',
    'cf_host 要认得出来',
  );
  assert(
    parseServerConfig('{"cf_host":"evil.com:8443"}').cfHost.isEmpty,
    'cf_host 同样要拒绝端口',
  );

  assert(apiUrl('/parse') == 'https://$apiHost/parse');
  assert(setApiHost('  example.com ') && apiHost == 'example.com');
}
