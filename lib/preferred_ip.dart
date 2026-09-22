import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_host.dart';

/// Cloudflare 优选 IP 池。
///
/// 用 XIU2/CloudflareSpeedTest(v2.3.5)在国内线路上实测出来的,按延迟从低到高排。
/// 复现命令(HTTPing 模式直接打我们自己的 /ping,所以量到的就是解析那条路的真实延迟;
/// `-dd` 关掉下载测速 —— 接口只回几 KB JSON,带宽不是瓶颈,延迟才是):
///
///     cfst.exe -f sample.txt -tp 443 -n 100 -t 2 -dd \
///         -httping -url https://<当前域名>/ping -httping-code 204 -o result.csv
///
/// sample.txt 是从 CF 各 IP 段里抽的样本(全量 IP 段有上百万个,跑不完)。
///
/// 实测(2026-09-17,电信线路,单位秒):
///
///     系统 DNS 默认(多半落到 IPv6)  ttfb 1.2 ~ 3.3,抖动大
///     173.245.49.168                ttfb 0.79 ~ 0.85
///     104.16.78.124                 ttfb 0.79 ~ 0.86
///     103.21.244.207                ttfb 0.84 ~ 1.06
///
/// 这个列表会过期 —— CF 的 IP 可用性一直在漂,而且同一个 IP 对不同运营商、不同省份
/// 的延迟能差好几倍。所以下面的 [PreferredIpConnector] 不是「信这个列表」,而是把它
/// 当备用线:系统 DNS 先正常连接,只有失败后才尝试这些 IP。列表整体失效也不会影响
/// 默认线路 —— 最差就是继续使用系统 DNS 的失败结果。
const List<String> kPreferredIps = <String>[
  '173.245.49.168',
  '104.16.78.124',
  '173.245.49.9',
  '103.21.244.207',
  '103.21.244.156',
  '188.114.96.62',
];

/// 让若干候选地址赛跑,返回**最先成功**的那个。
///
/// 用来做「优选 IP」:TCP + TLS 握手快的那个就是当前网络下最快的边缘节点。
/// 输掉的那些由 [onLoser] 收尾(连接对象得关掉,不然会漏 fd)。
/// 全部失败时抛 [SocketException]。
Future<T> race<T>(
  Iterable<Future<T>> attempts, {
  void Function(T value)? onLoser,
}) {
  final list = attempts.toList();
  if (list.isEmpty) {
    return Future<T>.error(SocketException('没有可用的候选地址'));
  }

  final completer = Completer<T>();
  var pending = list.length;

  for (final attempt in list) {
    attempt.then(
      (value) {
        if (completer.isCompleted) {
          onLoser?.call(value);
          return;
        }
        completer.complete(value);
      },
      onError: (Object _) {
        pending--;
        // 先到的那次已经让 completer 结束了,后面的失败直接忽略。
        if (pending == 0 && !completer.isCompleted) {
          completer.completeError(SocketException('候选地址全部连接失败'));
        }
      },
    );
  }

  return completer.future;
}

/// 把「连到优选 IP」和「换个域名重连」这两件事接进 `HttpClient`。
///
/// `HttpClient.connectionFactory` 拿到的是**已经建好的 Socket** —— dart:io 不会替你
/// 包 TLS(见 SDK 里 `_ConnectionTarget.connect` 的分支),所以 HTTPS 必须自己
/// `SecureSocket.secure(host: 真域名)`,否则证书校验会拿 IP 去比,直接失败。
/// 这里全程用真域名做 SNI 和证书校验,没有降级验证。
///
/// 两条备用线路都挂在这里,是因为它们是同一件事的两种失败面:
///   1. **换 IP**:域名没问题,但系统 DNS 给的边缘节点这条路不通 —— 所以拿优选 IP
///      做 SNI 仍是当前域名,证书照样过。
///   2. **换域名**:域名被运营商按 SNI 阻断,这时任何 IP 都救不了 —— 只能换一个
///      没被封的域名重连。候选域名来自 [managedHosts],即 [kApiHosts] 加上服务端
///      通过 `/ips.json` 下发的域名表,赢家由 [setApiHost] 写回全局状态。
class PreferredIpConnector {
  PreferredIpConnector({
    // 兼容旧的注入方式:传了 host 就把它当成「只认这一个域名」。
    // 现在域名由 api_host.dart 全局持有,新代码不用再传。
    String? host,
    List<String>? pool,
    this.winnerTtl = const Duration(minutes: 10),
    // 保留旧的注入参数,避免外部测试/调用方因 API 变更无法编译。
    // 系统 DNS 已经是主线路,所以它不再被拿来拼接优选 IP 候选。
    @Deprecated('系统 DNS 已是默认主线路,此参数仅为兼容保留') this.resolve,
    this.onWinner,
    this.onHost,
  }) : pinnedHost = host,
       pool = pool ?? kPreferredIps;

  /// 服务端下发的优选 IP 表,运行时会被 [PreferredIpUpdater] 换掉。
  ///
  /// 做成静态是因为整个 APP 只会有一个连接器(它活在 `ParseService.clientFactory`
  /// 造出来的那个 HttpClient 里),而拿不到它的地方(启动流程)需要能把新列表塞进去。
  /// 与其把列表一路传下去,不如让连接器每次现读。
  ///
  /// 注意:这张表属于**当前域名那个 Cloudflare zone**。换了域名之后旧 IP 上的证书
  /// 对不上新域名,那时候候选只剩域名本身,靠系统 DNS。
  static List<String> remote = const <String>[];

  /// 服务端下发的域名表([kApiHosts] 之外还要考虑的候选)。
  static List<String> remoteHosts = const <String>[];

  /// 被固定成单个域名的连接器(旧注入方式)。普通构造为 null。
  final String? pinnedHost;

  final List<String> pool;

  /// 上次赢家的保鲜期。过期就不用它当第一个候选了。
  final Duration winnerTtl;

  @Deprecated('系统 DNS 已是默认主线路,此参数仅为兼容保留')
  final Future<List<String>> Function(String host)? resolve;

  /// 赛跑出赢家时回调一次(地址 + 本次握手耗时)。用来上报给服务端。
  final void Function(String ip, int ms)? onWinner;

  /// 换域名的回调。只有真的换了域名才会调 —— 落盘用。
  final void Function(String host)? onHost;

  /// 最多拿几个优选 IP 参赛。
  static const int _racePinned = 3;

  static const Duration _connectTimeout = Duration(seconds: 3);
  (String host, String target)? _winner;
  DateTime? _winnerAt;

  /// 上一次实际用上的地址。诊断用(比如 tool/cfip_probe.dart 里打印)。
  String? get winner => _winner?.$2;

  /// 算上服务端下发的候选之后,当前要管的域名集合。
  ///
  /// 当前域名总是包含在内 —— 它可能来自磁盘缓存(上一次的赢家),不一定是
  /// [kApiHosts] 里那几个。
  List<String> get managedHosts {
    final host = pinnedHost ?? apiHost;
    final result = <String>[host.toLowerCase()];
    for (final candidate in [...kApiHosts, ...remoteHosts]) {
      final name = candidate.toLowerCase();
      if (!result.contains(name)) result.add(name);
    }
    return result;
  }

  /// 备用线路的候选(顺序即优先级):当前域名 → 服务端下发/内置的其它域名 →
  /// 优选 IP。返回的每一项是 `(做 SNI 的域名, 实际连接目标)`。
  ///
  /// 系统 DNS 不给当前域名留候选 —— 它是主线路,由 [connect] 单独先打一次,这样
  /// 优选 IP 不会在正常请求上抢跑或改变默认行为。
  List<(String host, String target)> get fallbackTargets {
    final hosts = managedHosts;
    final result = <(String, String)>[];
    for (final host in hosts) {
      result.add((host, host));
    }
    var pinned = 0;
    for (final ip in [...remote, ...pool]) {
      if (pinned >= _racePinned) break;
      if (result.any((entry) => entry.$2 == ip)) continue;
      result.add((hosts.first, ip));
      pinned++;
    }
    return result;
  }

  Future<ConnectionTask<Socket>> connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    // 不是我们自己的请求(比如直连的上游解析接口、第三方 CDN)一律走系统解析。
    //
    // **这里必须传 `uri.host`**:之前把「要钉优选 IP 的域名」当目标传下去是错的 ——
    // 那会把别的域名的请求也发去连我们的域名,然后报
    // 「Connection timed out, host: ...」。改成直连上游之后当场踩中过。
    if (!managedHosts.contains(uri.host.toLowerCase())) {
      return _task(await _dial(uri.host, uri));
    }

    final secure = uri.scheme == 'https';
    final key = uri.host.toLowerCase();

    // 系统 DNS 是默认线路。只有这条线路失败,才启用备用线路。
    try {
      final remembered = _freshWinner();
      return _task(
        await _dial(
          remembered?.$2 ?? key,
          uri,
          key: remembered?.$1,
          secure: secure,
        ),
      );
    } catch (_) {
      // 主线路失败:接着赛跑其它域名和优选 IP。
    }

    final candidates = fallbackTargets;
    try {
      // 从发起赛跑到赢家握手完成,这段就是赢家这次的真实连接耗时 ——
      // 报回服务端的就是它。
      final watch = Stopwatch()..start();
      final winner = await race<(String host, String target, Socket)>(
        candidates.map(
          (entry) async =>
              (entry.$1, entry.$2, await _dial(entry.$2, uri, key: entry.$1)),
        ),
        onLoser: (entry) => entry.$3.destroy(),
      );
      watch.stop();
      _remember(winner.$1, winner.$2);
      onWinner?.call(winner.$2, watch.elapsedMilliseconds);
      return _task(winner.$3);
    } catch (_) {
      // 备用线路也全部失败时,再给当前域名一次机会,处理短暂的解析/网络抖动。
      _winner = null;
      final host = pinnedHost ?? apiHost;
      return _task(await _dial(host, uri, secure: secure));
    }
  }

  ConnectionTask<Socket> _task(Socket socket) =>
      ConnectionTask.fromSocket(Future<Socket>.value(socket), socket.destroy);

  /// 连到 [target](优选 IP 或域名),必要时包上 TLS。
  ///
  /// [key] 是做 SNI 与证书校验、同时也是连接池身份的域名,默认就是请求自己的
  /// 域名;只有「换个域名重连」时才会传一个和请求不同的域名 —— 那时目标域名已经
  /// 不可达,但手机必须按新域名去校验证书。
  Future<Socket> _dial(
    String target,
    Uri uri, {
    String? key,
    bool? secure,
  }) async {
    final useTls = secure ?? uri.scheme == 'https';
    final host = key ?? uri.host;
    final socket = await Socket.connect(
      target,
      uri.port,
      timeout: _connectTimeout,
    );
    if (!useTls) return socket;

    try {
      return await SecureSocket.secure(
        socket,
        host: host,
      ).timeout(_connectTimeout);
    } catch (_) {
      // 握手失败的 socket 已经废了。能关就关 —— secure() 内部可能已经把
      // 底层 raw socket 摘走,那时候 destroy() 会抛,所以这里再兜一层。
      try {
        socket.destroy();
      } catch (_) {}
      rethrow;
    }
  }

  (String host, String target)? _freshWinner() {
    final winner = _winner;
    final at = _winnerAt;
    if (winner == null || at == null) return null;
    return DateTime.now().difference(at) < winnerTtl ? winner : null;
  }

  /// 记下这次赢的线路。赢家是域名时顺带把全局域名换过去。
  void _remember(String host, String target) {
    if (host != (pinnedHost ?? apiHost)) {
      setApiHost(host);
      onHost?.call(host);
    }
    _winner = (host, target);
    _winnerAt = DateTime.now();
  }
}

/// 列表多久算过期。服务端每 10 分钟重算一次,客户端没必要跟那么勤。
const Duration kPreferredIpsTtl = Duration(hours: 12);

/// 本地缓存是不是该刷了:从来没拉过、或者上次拉太久了。
///
/// 只判时间,不碰缓存内容 —— 落盘读写在 main.dart 里做,这个文件不依赖
/// Flutter 插件,这样 tool/cfip_probe.dart 能直接 `dart run` 起来验证整条链路。
bool preferredIpsStale(int? cachedAtMs, {DateTime? now}) {
  if (cachedAtMs == null) return true;
  final age = (now ?? DateTime.now()).difference(
    DateTime.fromMillisecondsSinceEpoch(cachedAtMs),
  );
  return age >= kPreferredIpsTtl;
}

/// 拉服务端下发的域名表 + 优选 IP,并把本机赛跑出来的赢家报回去。
///
/// 为什么排名得靠客户端上报:源站在美国、到 CF 走机房直连,它自己量出来的延迟
/// 对国内手机没有任何参考价值;而源站到某个 anycast 地址的路由好坏,也跟用户的
/// 请求无关(实测源站连不上 103.21.244.207,那个 IP 从国内测却是最好的之一)。
/// 只有真实客户端量出来的才算数,所以让 APP 每次赛跑完把赢家报上去,服务端聚合。
///
/// 拉配置时会把域名表里的每个域名都试一遍 —— 这一步同时承担「探活」的职责:
/// 哪个域名先答上来,哪个就是可用域名,赢家写回 [apiHost]。所以服务端换域名之后,
/// 老客户端只要**能连上任意一个候选域名**,就会自己切过去,不用重新发版。
///
/// 上报和拉取都用独立的 http client,不走优选 IP:万一内置池整个失效,
/// 拉新配置这条路还得通着。
class PreferredIpUpdater {
  PreferredIpUpdater({http.Client? client}) : _client = client ?? http.Client();

  /// 替换全局实例的 http client。**只给测试用**。
  ///
  /// 全局实例是懒加载的:真正发起第一次请求之前不会建 client。所以测试在
  /// `setUp` 里换掉它,就能保证启动流程那条路永远不会真发网络请求。
  static void overrideClient(http.Client client) => instance._client = client;

  /// 全局唯一实例。列表是全局状态(整个 APP 一个连接器),没必要搞注入。
  static final PreferredIpUpdater instance = PreferredIpUpdater();

  static String get reportUrl => apiUrl('/cfip/report');

  static const int maxIps = 16;
  static const int maxHosts = 4;
  static const Duration _timeout = Duration(seconds: 8);

  http.Client _client;

  /// 每次启动最多报一条。刚建完连接的实测值最有价值,一次就够,
  /// 没必要把上报做成心跳。
  bool _reported = false;

  /// 上一次真的答上来的候选域名。诊断用:启动日志里能看出当前这条线路是谁扛的。
  String? get lastHost => _lastHost;
  String? _lastHost;

  /// 拉一次配置并生效。任何失败都返回空配置,调用方继续用内置兜底 ——
  /// 这不是错误路径。
  ///
  /// 先打当前域名,失败再挨个打别的候选域名。串行而不是并发:这里是启动后的
  /// 后台刷新,没有人在等它;而并发打多个域名会在被阻断的域名上白白挂 8 秒超时,
  /// 还把候选数量乘上请求数。
  Future<ServerConfig> fetch() async {
    final tried = <String>[];
    for (final host in <String>[
      apiHost,
      ...kApiHosts,
      ...PreferredIpConnector.remoteHosts,
    ]) {
      if (!tried.contains(host)) tried.add(host);
    }

    for (final host in tried) {
      try {
        final response = await _client
            .get(Uri.parse('https://$host/ips.json'))
            .timeout(_timeout);
        if (response.statusCode != 200) continue;
        final config = parseServerConfig(
          utf8.decode(response.bodyBytes),
          maxHosts: maxHosts,
          maxIps: maxIps,
        );
        if (config.isEmpty) continue;
        _lastHost = host;
        _apply(config, answeredBy: host);
        return config;
      } catch (_) {
        // 这个域名不通,换下一个。
      }
    }
    return const ServerConfig();
  }

  /// 生效:换域名、换优选 IP 表、记住服务端下发的域名候选。
  void _apply(ServerConfig config, {required String answeredBy}) {
    if (config.ips.isNotEmpty) PreferredIpConnector.remote = config.ips;
    if (config.hosts.isNotEmpty) {
      PreferredIpConnector.remoteHosts = config.hosts;
    }
    // 服务端把某个域名排在第一位 = 它希望大家都用这个域名。
    final preferred = config.hosts.isNotEmpty ? config.hosts.first : answeredBy;
    setApiHost(preferred);
  }

  /// 后台刷新一次,不管结果。给「域名刚换掉」这种场景用 —— 调用方在请求路径上,
  /// 不能等它。失败就是继续用旧的优选池,不影响请求。
  void refresh() {
    fetch().ignore();
  }

  /// 上报这次赛跑的赢家。发完不管,失败也不重试 —— 一条样本而已。
  void reportWinner(String ip, int ms) {
    if (_reported) return;
    _reported = true;
    try {
      _client
          .get(
            Uri.parse(reportUrl)
                .replace(queryParameters: {'ip': ip, 'ms': '$ms'}),
          )
          .timeout(_timeout)
          .ignore();
    } catch (_) {}
  }
}
