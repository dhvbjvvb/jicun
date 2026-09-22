import 'dart:convert';
import 'dart:io';

/// 我们自己服务的域名池,以及「当前用哪个域名」这个全局状态。
///
/// 背景:域名会被国内运营商按 SNI 阻断(表现为 `ERR_CONNECTION_RESET`),换 IP、
/// 加优选 IP 都没用 —— 阻断认的是域名。所以域名必须**能在服务端换掉,而不用
/// 重新发版**:APP 启动后从 `/ips.json` 拉一份当前可用的域名表,拉到了就用它,
/// 拉不到就用这里编译进去的兜底。
///
/// 顺序即优先级:第一个是主域名,后面的是主域名又被封时的候选。
const List<String> kApiHosts = <String>['videofix.top', 'mxper.cc.cd'];

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

/// 服务端下发的整个配置:可用域名 + 优选 IP。
///
/// 两个字段一起下发是有意的:它们来自同一份服务端配置,分两次请求只会在
/// 「域名刚换、IP 还是旧域名那套」这种窗口里制造不一致。
class ServerConfig {
  const ServerConfig({
    this.hosts = const <String>[],
    this.ips = const <String>[],
  });

  final List<String> hosts;
  final List<String> ips;

  bool get isEmpty => hosts.isEmpty && ips.isEmpty;
}

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
  );
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
          'VideoFix.top',
          'evil.com:8443',
          'ok.example.com',
          'ok.example.com',
          'x',
        ]) ==
        const <String>['videofix.top', 'ok.example.com']),
    '域名解析:大小写归一、拒绝端口、去重、拒绝单段',
  );
  assert(parseApiHostList('nope').isEmpty, '非列表输入应为空');
  assert(parseApiHostList(<String>['a_b.example.com']).isEmpty, '下划线域名应拒绝');

  final config = parseServerConfig(
    '{"hosts":["a.example.com"],"ips":["1.2.3.4","nope"]}',
  );
  assert(config.hosts.single == 'a.example.com');
  assert(config.ips.single == '1.2.3.4', 'IP 表只认能解析的条目');
  assert(parseServerConfig('{bad json').isEmpty, '坏 JSON 应为空配置');

  assert(apiUrl('/parse') == 'https://$apiHost/parse');
  assert(setApiHost('  example.com ') && apiHost == 'example.com');
}
