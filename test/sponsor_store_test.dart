import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jicun/preferred_ip.dart';
import 'package:jicun/sponsor_store.dart';
import 'package:jicun/ui/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 赞助名单的解析信任边界 + 缓存/刷新行为。
///
/// 这张表现在是服务端下发的(/sponsors.json 由飞书多维表格导出,源文件
/// deploy/jicun-sponsors.py),所以 parseSponsors 是**信任边界**:内容来自网络,
/// 之后会原样画到界面上。坏数据必须被丢掉而不是抛异常 —— 拉不到就继续用手里
/// 那份旧的,这不是错误路径。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 兜底 client 是全局静态的,每个用例都要还回去,不然会漏到后面的用例里
  // (和 preferred_ip_test.dart 里一样的收尾)。
  final http.Client Function() originalFallback =
      PreferredIpUpdater.fallbackClientFactory;
  setUp(() => PreferredIpUpdater.fallbackClientFactory = originalFallback);
  tearDown(() => PreferredIpUpdater.fallbackClientFactory = originalFallback);

  /// 拼一份服务端形状的响应。字段名和 deploy/jicun-sponsors.py 输出的一致。
  String payload(List<Map<String, String>> rows) =>
      jsonEncode({'updated': '2026-10-02T14:52:44+08:00', 'sponsors': rows});

  http.Client ok(String body) =>
      MockClient((_) async => http.Response(body, 200, headers: {
            'content-type': 'application/json; charset=utf-8',
          }));

  http.Client dead() => MockClient((_) async => http.Response('', 500));

  group('parseSponsors', () {
    test('正常响应按顺序解析成 昵称/日期/金额', () {
      final list = parseSponsors(payload([
        {'name': '*', 'date': '10月1日', 'amount': '¥10.00'},
        {'name': '*°', 'date': '10月1日', 'amount': '¥0.50'},
      ]));
      expect(list, <Sponsor>[
        ('*', '10月1日', '¥10.00'),
        ('*°', '10月1日', '¥0.50'),
      ]);
    });

    test('坏 JSON / 顶层不是对象 / sponsors 不是数组 → 空表', () {
      expect(parseSponsors('{bad json'), isEmpty);
      expect(parseSponsors('[]'), isEmpty);
      expect(parseSponsors('null'), isEmpty);
      expect(parseSponsors('{"sponsors":"nope"}'), isEmpty);
      expect(parseSponsors('{"sponsors":[1,2,3]}'), isEmpty);
      expect(parseSponsors('{"sponsors":[]}'), isEmpty);
    });

    test('没昵称的条目跳过,非字符串字段当空串', () {
      final list = parseSponsors(payload([
        {'name': '', 'date': '9月30日', 'amount': '¥5.00'},
        {'date': '9月29日', 'amount': '¥1.00'},
        {'name': '  ', 'date': '9月28日', 'amount': '¥2.00'},
        {'name': 'keep', 'date': '9月27日', 'amount': '¥3.00'},
      ]));
      expect(list, <Sponsor>[('keep', '9月27日', '¥3.00')]);
    });

    test('昵称里的控制字符剥掉(一个换行就能撑坏表格的一行)', () {
      final list = parseSponsors(payload([
        {'name': 'a\nb\tc', 'date': 'x', 'amount': 'y'},
      ]));
      expect(list.single.$1, 'abc');
    });

    test('超长字段截断到上限', () {
      final long = List<String>.filled(100, 'x').join();
      final list = parseSponsors(payload([
        {'name': long, 'date': long, 'amount': long},
      ]));
      expect(list.single.$1.length, kMaxSponsorName);
      expect(list.single.$2.length, kMaxSponsorDate);
      expect(list.single.$3.length, kMaxSponsorAmount);
    });

    test('整表条数有上限', () {
      final rows = <Map<String, String>>[
        for (int i = 0; i < kMaxSponsors + 50; i++)
          {'name': 'n$i', 'date': 'x', 'amount': 'y'},
      ];
      expect(parseSponsors(payload(rows)).length, kMaxSponsors);
    });
  });

  group('SponsorStore', () {
    test('第一帧之前就是内置兜底', () {
      expect(SponsorStore(client: dead()).list, kSponsorFallback);
      expect(kSponsorFallback.length, 8);
    });

    test('刷新成功换掉列表并通知一次', () async {
      final store = SponsorStore(
        client: ok(payload([
          {'name': 'A', 'date': '1月1日', 'amount': '¥1.00'},
        ])),
      );
      int notified = 0;
      store.addListener(() => notified++);
      await store.refresh();
      expect(store.list.single, ('A', '1月1日', '¥1.00'));
      expect(notified, 1);
    });

    test('刷新失败:保留旧的那份,不抛异常', () async {
      final store = SponsorStore(client: dead());
      PreferredIpUpdater.overrideFallbackClient(dead());
      await store.refresh();
      expect(store.list, kSponsorFallback);
    });

    test('拉回来是空表也保留旧的那份(别把表格清空)', () async {
      final store = SponsorStore(client: ok('{"sponsors":[]}'));
      // 先塞一份进去,再让服务端返回空表。
      store.loadCached(payload([
        {'name': 'A', 'date': '1月1日', 'amount': '¥1.00'},
      ]));
      await store.refresh();
      expect(store.list.single.$1, 'A');
    });

    test('落盘之后冷启动读得回来', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = SponsorStore(
        client: ok(payload([
          {'name': 'A', 'date': '1月1日', 'amount': '¥1.00'},
        ])),
      );
      await store.refresh();

      final prefs = await SharedPreferences.getInstance();
      final String? cached = prefs.getString(kPrefsSponsors);
      expect(cached, isNotNull, reason: '成功之后必须落盘');

      final fresh = SponsorStore(client: dead());
      fresh.loadCached(cached);
      expect(fresh.list.single.$1, 'A', reason: '冷启动第一帧就该是缓存那份');
    });

    test('minInterval 之内不重复打网络', () async {
      int hits = 0;
      final store = SponsorStore(
        client: MockClient((_) async {
          hits++;
          return http.Response(
            payload([
              {'name': 'A', 'date': '1月1日', 'amount': '¥1.00'},
            ]),
            200,
          );
        }),
      );
      await store.refresh();
      await store.refresh(minInterval: const Duration(seconds: 30));
      expect(hits, 1, reason: '30 秒内第二次调用应被时间闸门挡住');
    });

    test('ensureLoaded 幂等,连着调只打一次网络', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      int hits = 0;
      final store = SponsorStore(
        client: MockClient((_) async {
          hits++;
          return http.Response(
            payload([
              {'name': 'A', 'date': '1月1日', 'amount': '¥1.00'},
            ]),
            200,
          );
        }),
      );
      await store.ensureLoaded();
      await store.ensureLoaded();
      expect(hits, 1);
    });

    test('loadCached(null) 不改变兜底', () {
      final store = SponsorStore(client: dead());
      store.loadCached(null);
      expect(store.list, kSponsorFallback);
    });
  });
}
