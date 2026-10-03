import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jicun/api_host.dart';
import 'package:jicun/bootstrap.dart';
import 'package:jicun/preferred_ip.dart';
import 'package:jicun/ui/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // 兜底 client 是全局静态的:每个用例结束时都要还回去,不然会漏到后面的用例里。
  final originalFallbackClient = PreferredIpUpdater.fallbackClientFactory;
  group('race', () {
    test('谁先成功用谁,输掉的交给 onLoser 收尾', () async {
      final slow = Completer<int>();
      final fast = Completer<int>();
      final losers = <int>[];

      final winner = race<int>([slow.future, fast.future], onLoser: losers.add);

      // 先失败一个不算赢
      slow.completeError(const SocketException('连不上'));
      fast.complete(7);

      expect(await winner, 7);
      expect(losers, isEmpty);
    });

    test('赢家先到,后面才到的输家也要收尾(不然漏 fd)', () async {
      final first = Completer<int>();
      final late = Completer<int>();
      final losers = <int>[];

      final winner = race<int>([
        first.future,
        late.future,
      ], onLoser: losers.add);
      first.complete(1);
      expect(await winner, 1);

      late.complete(2);
      await Future<void>.delayed(Duration.zero);
      expect(losers, [2]);
    });

    test('全部失败抛 SocketException', () async {
      final result = race<int>([
        Future<int>.error(const SocketException('a')),
        Future<int>.error(const SocketException('b')),
      ]);

      await expectLater(result, throwsA(isA<SocketException>()));
    });

    test('候选为空直接失败,不吊死', () async {
      await expectLater(race<int>(const []), throwsA(isA<SocketException>()));
    });
  });

  group('PreferredIpConnector 的候选线路', () {
    setUp(() {
      PreferredIpConnector.remote = const [];
      PreferredIpConnector.remoteHosts = const [];
      setApiHost(kApiHosts.first);
    });
    tearDown(() {
      PreferredIpConnector.remote = const [];
      PreferredIpConnector.remoteHosts = const [];
      setApiHost(kApiHosts.first);
    });

    test('当前域名排第一,内置域名跟上 —— 换域名是备用线路的第一步', () {
      final connector = PreferredIpConnector(
        pool: const ['1.1.1.1', '2.2.2.2', '3.3.3.3', '4.4.4.4'],
      );

      // 当前域名就是第一个内置域名,所以整张表等于 kApiHosts 本身。
      // 用 kApiHosts 而不是写死数组:内置域名增减时这条不用跟着改。
      expect(connector.managedHosts, kApiHosts);
    });

    test('服务端下发的域名排在当前域名之后,不替换它', () {
      PreferredIpConnector.remoteHosts = const ['new.example.com'];

      final connector = PreferredIpConnector(pool: const ['1.1.1.1']);

      expect(connector.managedHosts, [...kApiHosts, 'new.example.com']);
    });

    test('备用线路顺序:当前域名 → 其它域名 → 优选 IP(截断到 3 个)', () {
      PreferredIpConnector.remote = const ['9.9.9.9'];
      final connector = PreferredIpConnector(
        pool: const ['1.1.1.1', '2.2.2.2', '3.3.3.3'],
      );

      expect(connector.fallbackTargets, [
        // 域名先各占一个候选(target 就是域名本身 —— 靠 SNI 换域名重连)
        for (final host in connector.managedHosts) (host, host),
        // 然后才轮到优选 IP,且最多 3 个:池里第 4 个(3.3.3.3)会被截掉
        (kApiHosts.first, '9.9.9.9'),
        (kApiHosts.first, '1.1.1.1'),
        (kApiHosts.first, '2.2.2.2'),
      ]);
    });

    test('池里的地址不会重复参赛', () {
      PreferredIpConnector.remote = const ['1.1.1.1'];
      final connector = PreferredIpConnector(
        pool: const ['1.1.1.1', '2.2.2.2'],
      );

      final targets = connector.fallbackTargets.map((e) => e.$2).toList();
      expect(targets.where((t) => t == '1.1.1.1'), hasLength(1));
    });

    test('旧的 host 注入方式仍然只认那一个域名', () {
      final connector = PreferredIpConnector(
        host: 'pinned.example.com',
        pool: const ['1.1.1.1'],
      );

      expect(connector.managedHosts.first, 'pinned.example.com');
    });
  });

  group('parsePreferredIpList', () {
    test('正常列表照单全收', () {
      final body = jsonDecode(
        jsonEncode({
          'updated': '2026-09-17T13:39:16+00:00',
          'ips': ['173.245.49.168', '104.16.78.124'],
        }),
      );

      expect(parsePreferredIpList(body['ips']), [
        '173.245.49.168',
        '104.16.78.124',
      ]);
    });

    test('垃圾内容一律不当回事,不抛异常', () {
      expect(parsePreferredIpList(null), isEmpty);
      expect(parsePreferredIpList('nope'), isEmpty);
      expect(parsePreferredIpList({'ips': 'nope'}), isEmpty);
      expect(parsePreferredIpList([1, 2, 3]), isEmpty);
    });

    test('塞进非 IP 的东西会被剔掉 —— 这里的东西会被拿去 Socket.connect', () {
      final body = jsonDecode(
        jsonEncode({
          'ips': [
            '173.245.49.168',
            'evil.example.com',
            '1.2.3.4; rm -rf /',
            '',
            null,
            42,
          ],
        }),
      );

      expect(parsePreferredIpList(body['ips']), ['173.245.49.168']);
    });

    test('重复的只留一条,条数有上限', () {
      final body = jsonDecode(
        jsonEncode({
          'ips': ['1.1.1.1', '1.1.1.1', '2.2.2.2', '3.3.3.3', '4.4.4.4'],
        }),
      );

      expect(parsePreferredIpList(body['ips'], max: 3), [
        '1.1.1.1',
        '2.2.2.2',
        '3.3.3.3',
      ]);
    });

    test('IPv6 也认', () {
      final body = jsonDecode(
        jsonEncode({
          'ips': ['2606:4700:3033::ac43:bbaf'],
        }),
      );

      expect(parsePreferredIpList(body['ips']), ['2606:4700:3033::ac43:bbaf']);
    });
  });

  group('PreferredIpUpdater', () {
    // 兜底 client 是全局静态的:这些用例本来只关心「拉不到配置」那条路,但普通
    // client 一失败就会走到兜底那道,不挡住就会真去连接口域名。
    setUp(() {
      PreferredIpConnector.remote = const [];
      PreferredIpConnector.remoteHosts = const [];
      setApiHost(kApiHosts.first);
      PreferredIpUpdater.fallbackClientFactory = () =>
          MockClient((_) async => http.Response('', 502));
    });
    tearDown(() {
      PreferredIpConnector.remote = const [];
      PreferredIpConnector.remoteHosts = const [];
      setApiHost(kApiHosts.first);
      PreferredIpUpdater.fallbackClientFactory = originalFallbackClient;
    });

    test('拉回来的域名表和 IP 表都生效', () async {
      final updater = PreferredIpUpdater(
        client: MockClient(
          (_) async => http.Response(
            '{"hosts":["api.example.com"],"ips":["9.9.9.9","8.8.8.8"]}',
            200,
          ),
        ),
      );

      final config = await updater.fetch();
      expect(config.hosts, ['api.example.com']);
      expect(config.ips, ['9.9.9.9', '8.8.8.8']);
      expect(PreferredIpConnector.remote, ['9.9.9.9', '8.8.8.8']);
      expect(PreferredIpConnector.remoteHosts, ['api.example.com']);
    });

    test('服务端把某个域名排第一,就切到那个域名', () async {
      // 当前域名先答,但它把 old.example.com 排在自己前面 ——
      // 服务端用顺序表达「请大家都用这个」。
      final updater = PreferredIpUpdater(
        client: MockClient(
          (_) async => http.Response(
            '{"hosts":["old.example.com","${kApiHosts.first}"],"ips":["9.9.9.9"]}',
            200,
          ),
        ),
      );

      await updater.fetch();

      expect(apiHost, 'old.example.com');
      expect(updater.lastHost, kApiHosts.first);
    });

    test('服务端 5xx / 返回垃圾都返回空配置,内置兜底不受影响', () async {
      final down = PreferredIpUpdater(
        client: MockClient((_) async => http.Response('<html>502</html>', 502)),
      );
      expect((await down.fetch()).isEmpty, isTrue);

      final garbage = PreferredIpUpdater(
        client: MockClient((_) async => http.Response('{"nope":1}', 200)),
      );
      expect((await garbage.fetch()).isEmpty, isTrue);
    });

    test('当前域名不通时,挨个候选域名继续试', () async {
      // 内置域名现在只剩一个,第二个候选得由服务端下发的域名表来提供 ——
      // 这正是「换域名不用发版」那条路。
      PreferredIpConnector.remoteHosts = const ['backup.example.com'];
      final seen = <String>[];
      final updater = PreferredIpUpdater(
        client: MockClient((request) async {
          seen.add(request.url.host);
          if (request.url.host == kApiHosts.first) {
            throw const SocketException('被运营商阻断了');
          }
          return http.Response('{"hosts":["backup.example.com"]}', 200);
        }),
      );

      final config = await updater.fetch();

      expect(seen, [kApiHosts.first, 'backup.example.com']);
      expect(config.hosts, ['backup.example.com']);
      expect(updater.lastHost, 'backup.example.com');
    });

    test('请求抛异常也返回空配置', () async {
      final updater = PreferredIpUpdater(
        client: MockClient((_) async => throw const SocketException('断了')),
      );

      expect((await updater.fetch()).isEmpty, isTrue);
    });

    test('最短间隔内的重复上报会被丢掉,不变成心跳', () async {
      final reports = <Uri>[];
      final updater = PreferredIpUpdater(
        client: MockClient((request) async {
          reports.add(request.url);
          return http.Response('', 204);
        }),
      );

      // 闸门是 60 秒,两次连着的调用只该出去一条。
      updater.reportWinner((
        ip: '173.245.49.168',
        ms: 210,
        dnsMs: 3000,
        candidates: 5,
      ));
      updater.reportWinner((
        ip: '173.245.49.168',
        ms: 215,
        dnsMs: 3000,
        candidates: 5,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(reports, hasLength(1));
      final q = reports.single.queryParameters;
      expect(q['ip'], '173.245.49.168');
      expect(q['ms'], '210');
      // 新增的两个字段也要真的发出去,否则服务端还是只能数票数。
      expect(q['dns_ms'], '3000');
      expect(q['n'], '5');
    });
  });

  group('preferredIpsStale', () {
    final now = DateTime(2026, 9, 17, 12);

    test('从来没拉过就是过期', () {
      expect(preferredIpsStale(null, now: now), isTrue);
    });

    test('刚拉过不算过期', () {
      expect(
        preferredIpsStale(
          now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
          now: now,
        ),
        isFalse,
      );
    });

    test('超过有效期算过期', () {
      expect(
        preferredIpsStale(
          now
              .subtract(kPreferredIpsTtl + const Duration(minutes: 1))
              .millisecondsSinceEpoch,
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('PreferredIpUpdater 的兜底 client', () {
    setUp(() {
      PreferredIpConnector.remote = const [];
      PreferredIpConnector.remoteHosts = const [];
      supportedHosts = const [];
      setApiHost(kApiHosts.first);
    });
    tearDown(() {
      PreferredIpConnector.remote = const [];
      PreferredIpConnector.remoteHosts = const [];
      supportedHosts = const [];
      setApiHost(kApiHosts.first);
      PreferredIpUpdater.fallbackClientFactory = originalFallbackClient;
    });

    test('普通线路一个域名都不通时,换挂优选 IP 的 client 再打一遍并生效', () async {
      // 这正是那批只有连接器出得去的设备:当前域名被 SNI 阻断,普通 client
      // (系统 DNS)每个候选都失败。
      final plainSeen = <String>[];
      final fallbackSeen = <String>[];
      PreferredIpUpdater.overrideFallbackClient(
        MockClient((request) async {
          fallbackSeen.add(request.url.host);
          return http.Response(
            '{"hosts":["new.example.com"],"ips":["9.9.9.9","8.8.8.8"],'
            '"supported":["v.douyin.com"]}',
            200,
          );
        }),
      );
      final updater = PreferredIpUpdater(
        client: MockClient((request) async {
          plainSeen.add(request.url.host);
          throw const SocketException('域名被阻断了');
        }),
      );

      final config = await updater.fetch();

      // 普通线路先真的试过,全挂了才轮到兜底。
      expect(plainSeen, [kApiHosts.first]);
      expect(fallbackSeen, [kApiHosts.first]);
      // 拉回来的配置要真的生效:白名单、域名候选、IP 池、以及换域名。
      expect(config.hosts, ['new.example.com']);
      expect(supportedHosts, ['v.douyin.com']);
      expect(PreferredIpConnector.remote, ['9.9.9.9', '8.8.8.8']);
      expect(PreferredIpConnector.remoteHosts, ['new.example.com']);
      expect(apiHost, 'new.example.com');
      // lastHost 记的是**答上来的那个域名**(请求打给谁),不是服务端排第一的那个。
      expect(updater.lastHost, kApiHosts.first);
    });

    test('普通线路答上来了就不碰兜底 client', () async {
      var fallbackCalls = 0;
      PreferredIpUpdater.overrideFallbackClient(
        MockClient((_) async {
          fallbackCalls++;
          return http.Response('{"hosts":["other.example.com"]}', 200);
        }),
      );
      final updater = PreferredIpUpdater(
        client: MockClient(
          (_) async => http.Response('{"hosts":["api.example.com"]}', 200),
        ),
      );

      await updater.fetch();

      expect(fallbackCalls, 0);
    });
  });

  group('服务端配置的落盘与读回', () {
    setUp(() {
      PreferredIpConnector.remote = const [];
      PreferredIpConnector.remoteHosts = const [];
      supportedHosts = const [];
      setApiHost(kApiHosts.first);
      // 这条路上也可能走到兜底 client,一并挡住。
      PreferredIpUpdater.fallbackClientFactory = () =>
          MockClient((_) async => http.Response('', 502));
    });
    tearDown(() {
      PreferredIpConnector.remote = const [];
      PreferredIpConnector.remoteHosts = const [];
      supportedHosts = const [];
      setApiHost(kApiHosts.first);
      PreferredIpUpdater.fallbackClientFactory = originalFallbackClient;
    });

    test('refreshPreferredIps 把服务端下发的域名表也写进缓存', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      PreferredIpUpdater.overrideClient(
        MockClient(
          (_) async => http.Response(
            '{"hosts":["new.example.com"],"ips":["9.9.9.9"],'
            '"supported":["v.douyin.com"]}',
            200,
          ),
        ),
      );

      await refreshPreferredIps(prefs);

      final cached = jsonDecode(
        prefs.getString(kPrefsPreferredIps)!,
      ) as Map<String, dynamic>;
      expect(cached['hosts'], ['new.example.com']);
      expect(cached['ips'], ['9.9.9.9']);
      expect(cached['supported'], ['v.douyin.com']);
      // 换掉的域名也要落盘:下次冷启动先用它,而不是拿内置域名去撞一次墙。
      expect(prefs.getString(kPrefsApiHost), 'new.example.com');
    });

    test('冷启动把缓存里的域名表读回连接器(以前这里漏了 hosts)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      restoreCachedConfig(
        jsonEncode({
          'ips': ['9.9.9.9'],
          'hosts': ['new.example.com'],
          'supported': ['v.douyin.com'],
        }),
      );

      expect(PreferredIpConnector.remote, ['9.9.9.9']);
      expect(PreferredIpConnector.remoteHosts, ['new.example.com']);
      expect(supportedHosts, ['v.douyin.com']);
      // 没缓存(从没拉过)就什么都不动,继续用内置兜底。
      PreferredIpConnector.remoteHosts = const [];
      restoreCachedConfig(null);
      expect(PreferredIpConnector.remoteHosts, isEmpty);
    });
  });
}
