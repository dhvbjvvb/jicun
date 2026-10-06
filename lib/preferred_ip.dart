import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'api_host.dart';
import 'failure.dart';

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
    return Future<T>.error(const SocketException('没有可用的候选地址'));
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
          completer.completeError(const SocketException('候选地址全部连接失败'));
        }
      },
    );
  }

  return completer.future;
}

/// 一次兜底赛跑的战果，上报给服务端。
///
/// 以前只报 [ip] 和 [ms]（而且 [ip] 还可能是域名），服务端只能数出「谁赢过几回」，
/// 既算不出各候选的成功率，也分不清一次兜底到底是**救命**（主线路被墙死）还是
/// **顺手提速**（主线路只是慢）。补上 [dnsMs] 和 [candidates] 之后这两个问题才答得了。
///
/// 字段名与 nginx 的 `jicun_cfip` 日志格式一一对应，改一边要同步改另一边。
typedef WinnerReport = ({
  /// 这次**真正连上**的对端地址（`socket.remoteAddress`），域名和 IP 都不例外。
  String ip,

  /// 赢家这次 TCP + TLS 握手花了多久。
  int ms,

  /// 主线路失败前耗了多久。接近 [PreferredIpConnector._connectTimeout] 说明是被
  /// 卡到超时（真失败）；只有几十毫秒说明是快速报错（DNS 无应答、连接被拒）。
  int dnsMs,

  /// 这次赛跑一共几个候选。用来判断赢家的"含金量"。
  int candidates,
});

/// 把「连到优选 IP」和「换个域名重连」这两件事接进 `HttpClient`。
///
/// `HttpClient.connectionFactory` 拿到的是**已经建好的 Socket** —— dart:io 不会替你
/// 包 TLS(见 SDK 里 `_ConnectionTarget.connect` 的分支),所以 HTTPS 必须自己
/// `SecureSocket.secure(host: 真域名)`,否则证书校验会拿 IP 去比,直接失败。
/// 这里全程用真域名做 SNI 和证书校验,没有降级验证。
///
/// 两条备用线路都挂在这里,是因为它们是同一件事的两种失败面:
///   1. **换 IP**:域名没问题,但系统 DNS 给的 Cloudflare 边缘节点这条路不通 ——
///      所以拿优选 IP 去连**别的**边缘节点。这些 IP 只能绑在 [cfHost](走 CF 回源的
///      那个域名)上,SNI 与证书校验都按它来。
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
  /// **这张表属于 [cfHost] 那个 Cloudflare zone**:里面全是 Cloudflare 边缘节点的
  /// 地址,只有拿 CF 那个域名做 SNI 才连得上。直连域名的路上用不着它们。
  static List<String> remote = const <String>[];

  /// 优选 IP 该绑到哪个域名上 —— 服务端下发的 `cf_host`,即**走 CF 回源的那个**入口域名。
  ///
  /// 连 CF 边缘时要拿域名做 SNI 与证书校验,报一个 CF 不认的域名(比如直连的主用域名)
  /// 握手会当场失败。所以这个值不靠猜 `hosts` 的顺序,由服务端明确下发。
  ///
  /// 空串 = 服务端没给(或那个域名已经下线),那时 [fallbackTargets] 干脆不赛跑 IP。
  static String cfHost = '';

  /// 服务端下发的域名表([kApiHosts] 之外还要考虑的候选)。
  static List<String> remoteHosts = const <String>[];

  /// 被固定成单个域名的连接器(旧注入方式)。普通构造为 null。
  final String? pinnedHost;

  final List<String> pool;

  /// 上次赢家的保鲜期。过期就不用它当第一个候选了。
  final Duration winnerTtl;

  /// 赛跑出赢家时回调一次。用来上报给服务端。
  final void Function(WinnerReport report)? onWinner;

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

  /// 备用线路的候选(顺序即优先级):当前域名 → 服务端下发/内置的其它域名 → 优选 IP。
  /// 返回的每一项是 `(做 SNI 的域名, 实际连接目标)`。
  ///
  /// 系统 DNS 不给当前域名留候选 —— 它是主线路,由 [connect] 单独先打一次,这样
  /// 优选 IP 不会在正常请求上抢跑或改变默认行为。
  List<(String host, String target)> get fallbackTargets {
    final hosts = managedHosts;
    final result = <(String, String)>[];
    for (final host in hosts) {
      result.add((host, host));
    }
    // 优选 IP 池里全是 **Cloudflare 边缘节点**的地址,只能绑在走 CF 的那个域名上。
    //
    // 别改回 `hosts.first`:那是主用域名,而主用是**直连**的(不经过 CF)—— 拿它
    // 当 SNI 去连 CF 的边缘 IP,CF 边缘不认这个域名,握手当场失败,那 3 个赛跑位
    // 就白占了。
    //
    // 服务端没给 [cfHost] 时一个 IP 都不赛跑:宁可不试,也不要拿几个注定失败的
    // 候选去挤掉本可以试的域名。
    final ipHost = cfHost;
    if (ipHost.isEmpty) return result;
    var pinned = 0;
    for (final ip in [...remote, ...pool]) {
      if (pinned >= _racePinned) break;
      if (result.any((entry) => entry.$2 == ip)) continue;
      result.add((ipHost, ip));
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
    //
    // 顺带量一下主线路**失败前**耗了多久([primaryMs])。它区分得开两种完全不同的
    // 情况:卡到 [_connectTimeout] 才断(域名/DNS 真的出问题了) vs 几十毫秒就报错
    // (连接被拒、解析立刻失败)。没有这个数,服务端就永远答不了"兜底救了多少人"。
    var primaryMs = 0;
    final primaryWatch = Stopwatch()..start();
    try {
      final remembered = _freshWinner();
      final socket = await _dial(
        remembered?.$2 ?? key,
        uri,
        key: remembered?.$1,
        secure: secure,
      );
      primaryWatch.stop();
      return _task(socket);
    } catch (_) {
      // 主线路失败:接着赛跑其它域名和优选 IP。
      primaryWatch.stop();
      primaryMs = primaryWatch.elapsedMilliseconds;
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
      // 报**真实连上的对端地址**，不是候选里的 target 字符串。
      //
      // target 可能是域名 —— [fallbackTargets] 里"换域名重连"那几项就是
      // `(host, host)`。以前直接报 target，于是一旦靠换域名救场成功，上报出去的
      // `ip=` 那栏是域名，而服务端的 awk 只认 IPv4 点分十进制，
      // 整条样本被丢掉（实测占上报量的 18%）。IPv6 也会被 URL 编码成 %3A 后丢掉。
      //
      // remoteAddress 拿到的永远是这次真正握手成功的那个地址，域名和 IP 都不例外。
      onWinner?.call((
        ip: winner.$3.remoteAddress.address,
        ms: watch.elapsedMilliseconds,
        dnsMs: primaryMs,
        candidates: candidates.length,
      ));
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
      } catch (error, stack) {
        // 连销毁都失败:没关系,这个 socket 已经废了,只是多占一会儿 FD。
        swallow('ip.socket-destroy', error, stack);
      }
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
/// 上报走独立的 http client,不进优选 IP:上报是纯附带的,不值得为它多开一条线路。
///
/// 拉配置则**先试普通线路,全挂了才换带优选 IP 连接器的 client**(见 [fetch]):
/// 万一内置池整个失效,普通线路那条路还得通着。
class PreferredIpUpdater {
  PreferredIpUpdater({http.Client? client}) : _client = client ?? http.Client();

  /// 替换全局实例的 http client。**只给测试用**。
  ///
  /// 全局实例是懒加载的:真正发起第一次请求之前不会建 client。所以测试在
  /// `setUp` 里换掉它,就能保证启动流程那条路永远不会真发网络请求。
  static void overrideClient(http.Client client) => instance._client = client;

  /// 拉配置**兜底**用的 http client:和 [ParseService.clientFactory] 同一套,挂优选 IP。
  ///
  /// 只在普通线路一个域名都没答上来时才会用到。为什么非要有它:`/parse` 一直是走
  /// 连接器的(系统 DNS 打不通就换 IP / 换域名),而拉配置有段时间只用普通
  /// `http.Client()`。于是正好在机制为之而生的那批设备上(当前域名被 SNI 阻断,或
  /// 系统 DNS 给的边缘节点不可达),配置永远拉不回来 —— 白名单、服务端下发的域名表
  /// 全部拿不到,而 `/parse` 却还能用。域名被阻断时,只有连接器那条路出得去。
  ///
  /// 留成静态字段同时也是测试的口子:用例里换成 MockClient,免得真去连接口域名。
  static http.Client Function() fallbackClientFactory = () => IOClient(
    HttpClient()
      ..connectionFactory = PreferredIpConnector(
        onWinner: instance.reportWinner,
        onHost: (_) => instance.refresh(),
      ).connect,
  );

  /// 换掉兜底 client。**只给测试用**(和 [overrideClient] 一样,生产代码不碰)。
  @visibleForTesting
  static void overrideFallbackClient(http.Client client) =>
      fallbackClientFactory = () => client;

  /// 全局唯一实例。列表是全局状态(整个 APP 一个连接器),没必要搞注入。
  static final PreferredIpUpdater instance = PreferredIpUpdater();

  static String get reportUrl => apiUrl('/cfip/report');

  static const int maxIps = 16;
  static const int maxHosts = 4;
  static const Duration _timeout = Duration(seconds: 8);

  http.Client _client;

  /// 两次上报之间的最短间隔。
  ///
  /// 以前是 `bool _reported` —— 每次启动只报一条。那让样本稀到没法用:跑了十天,
  /// 达标(≥2 票)的 IP 只有 3 个,而且全在硬编码的种子列表里,上报环节一个新 IP
  /// 都没发现过。
  ///
  /// 换成时间闸门就够:上报只在**兜底赛跑成功**时发生,而赢家会被记住十分钟
  /// ([PreferredIpConnector.winnerTtl]),那段时间不会再赛跑、也就不会再上报 ——
  /// 天然就有十分钟间隔。这里再压一道 60 秒,防的是连续失败重试把端点点爆。
  static const Duration _minReportInterval = Duration(seconds: 60);
  DateTime? _lastReportAt;

  /// 上一次真的答上来的候选域名。诊断用:启动日志里能看出当前这条线路是谁扛的。
  String? get lastHost => _lastHost;
  String? _lastHost;

  /// 拉一次配置并生效。任何失败都返回空配置,调用方继续用内置兜底 ——
  /// 这不是错误路径。
  ///
  /// **先走普通线路(系统 DNS),整条路全挂了才换成带优选 IP 连接器的 client 再来一遍。**
  ///
  /// 顺序不能颠倒:万一内置优选池整个失效(列表会过期,见文件头那段),普通线路就是
  /// 唯一能把新配置拉回来的路。所以它是第一发,不是备选。
  ///
  /// 但也不能只有它:当前域名被运营商按 SNI 阻断、或者系统 DNS 给的那个边缘节点不可达
  /// 时,普通线路一个域名都答不上来,而这恰好是 [PreferredIpConnector] 存在的理由
  /// (换 IP / 换域名)。漏掉这一道,那批设备就会永远拉不到配置 —— 没有白名单、没有
  /// 服务端下发的域名表,而 `/parse` 因为一直走连接器反而还能用。
  Future<ServerConfig> fetch() async {
    final plain = await _fetchWith(_client);
    if (!plain.isEmpty) return plain;
    return _fetchWith(fallbackClientFactory());
  }

  /// 用 [client] 把候选域名挨个打一遍,谁先给出**有效**配置就返回它。
  ///
  /// 先打当前域名,失败再挨个打别的候选域名。串行而不是并发:这里是启动后的
  /// 后台刷新,没有人在等它;而并发打多个域名会在被阻断的域名上白白挂 8 秒超时,
  /// 还把候选数量乘上请求数。
  Future<ServerConfig> _fetchWith(http.Client client) async {
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
        final response = await client
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
      } catch (error, stack) {
        // 这个域名不通,换下一个。
        swallow('ip.probe', error, stack);
      }
    }
    return const ServerConfig();
  }

  /// 生效:换域名、换优选 IP 表、换 CF 入口域名、记住服务端下发的域名候选。
  void _apply(ServerConfig config, {required String answeredBy}) {
    if (config.ips.isNotEmpty) PreferredIpConnector.remote = config.ips;
    if (config.hosts.isNotEmpty) {
      PreferredIpConnector.remoteHosts = config.hosts;
    }
    // cf_host 同样**无条件覆盖**（和 supported 一个理由）：服务端撤掉它对 APP 说来
    // 就是「别再用优选 IP 了」，这时必须跟着关 —— 不然会拿着一份过期的 CF 域名继续绑 IP。
    PreferredIpConnector.cfHost = config.cfHost;
    // 支持域名表**无条件覆盖**（不是 `if (isNotEmpty)`）：服务端放开或再关掉某个平台时
    // 这份表会跟着变长变短 —— 必须整个换掉，否则被放开的平台会因为本地还留着旧的
    // 白名单而一直被拦着，用户永远看不到它已经恢复了。
    supportedHosts = config.supported;
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
  ///
  /// 参数名要和 nginx 的 `jicun_cfip` 日志格式对齐(`x=$arg_x`),
  /// 也要和聚合脚本 jicun-cfip.sh 的解析对齐,改一处要同步另外两处。
  void reportWinner(WinnerReport report) {
    final now = DateTime.now();
    final last = _lastReportAt;
    if (last != null && now.difference(last) < _minReportInterval) return;
    _lastReportAt = now;
    try {
      _client
          .get(
            Uri.parse(reportUrl).replace(
              queryParameters: {
                'ip': report.ip,
                'ms': '${report.ms}',
                'dns_ms': '${report.dnsMs}',
                'n': '${report.candidates}',
              },
            ),
          )
          .timeout(_timeout)
          .ignore();
    } catch (error, stack) {
      // 一条诊断样本,发不出去就算了 —— 上报失败不该影响用户任何体验。
      swallow('ip.report', error, stack);
    }
  }
}
