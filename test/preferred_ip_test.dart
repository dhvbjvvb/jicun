import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:untitled/api_host.dart';
import 'package:untitled/preferred_ip.dart';

void main() {
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

      expect(connector.managedHosts.first, kApiHosts.first);
      expect(connector.managedHosts, contains(kApiHosts.last));
    });

    test('服务端下发的域名排在当前域名之后,不替换它', () {
      PreferredIpConnector.remoteHosts = const ['new.example.com'];

      final connector = PreferredIpConnector(pool: const ['1.1.1.1']);

      expect(connector.managedHosts, [
        kApiHosts.first,
        kApiHosts.last,
        'new.example.com',
      ]);
    });

    test('备用线路顺序:当前域名 → 其它域名 → 优选 IP(截断到 3 个)', () {
      PreferredIpConnector.remote = const ['9.9.9.9'];
      final connector = PreferredIpConnector(
        pool: const ['1.1.1.1', '2.2.2.2', '3.3.3.3'],
      );

      expect(connector.fallbackTargets, [
        (kApiHosts.first, kApiHosts.first),
        (kApiHosts.last, kApiHosts.last),
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

    test('拉回来的域名表和 IP 表都生效', () async {
      final updater = PreferredIpUpdater(
        client: MockClient(
          (_) async => http.Response(
            '{"hosts":["videofix.top"],"ips":["9.9.9.9","8.8.8.8"]}',
            200,
          ),
        ),
      );

      final config = await updater.fetch();
      expect(config.hosts, ['videofix.top']);
      expect(config.ips, ['9.9.9.9', '8.8.8.8']);
      expect(PreferredIpConnector.remote, ['9.9.9.9', '8.8.8.8']);
      expect(PreferredIpConnector.remoteHosts, ['videofix.top']);
    });

    test('服务端把某个域名排第一,就切到那个域名', () async {
      // 当前域名(videofix.top)先答,但它把 old.example.com 排在自己前面 ——
      // 服务端用顺序表达「请大家都用这个」。
      final updater = PreferredIpUpdater(
        client: MockClient(
          (_) async => http.Response(
            '{"hosts":["old.example.com","videofix.top"],"ips":["9.9.9.9"]}',
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

      expect(seen, [kApiHosts.first, kApiHosts.last]);
      expect(config.hosts, ['backup.example.com']);
      expect(updater.lastHost, kApiHosts.last);
    });

    test('请求抛异常也返回空配置', () async {
      final updater = PreferredIpUpdater(
        client: MockClient((_) async => throw const SocketException('断了')),
      );

      expect((await updater.fetch()).isEmpty, isTrue);
    });

    test('每次启动只报一条,不变成心跳', () async {
      final reports = <Uri>[];
      final updater = PreferredIpUpdater(
        client: MockClient((request) async {
          reports.add(request.url);
          return http.Response('', 204);
        }),
      );

      updater.reportWinner('173.245.49.168', 210);
      updater.reportWinner('173.245.49.168', 215);
      await Future<void>.delayed(Duration.zero);

      expect(reports, hasLength(1));
      expect(reports.single.queryParameters['ip'], '173.245.49.168');
      expect(reports.single.queryParameters['ms'], '210');
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
}
