import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jicun/api_host.dart';
import 'package:jicun/parse_service.dart';

/// 只有服务端支持名单里的平台才提交解析，其余在本地直接拦掉。
///
/// 重点是 [unsupportedPlatformMessage] 的**精确匹配**语义:服务端 `UrlParser.get_platform`
/// 用的是 `DOMAIN_TO_NAME.get(domain)` 精确查表，客户端必须同构 —— 一旦改成后缀匹配，
/// 视频号(已关，白名单里没有它)名下的 `weixin.qq.com` 就会把微信公众号(在用)的
/// `mp.weixin.qq.com` 一起误伤。实测踩过。
///
/// 另一条同样重要:**走第三方上游的平台不做本地拦截**。视频号在服务端是关掉的，
/// 根本不在白名单里，但它完全靠上游 —— 拿白名单直接套它会把它整个拒掉。
void main() {
  setUp(() => supportedHosts = const <String>[]);
  tearDown(() => supportedHosts = const <String>[]);

  group('parseServerConfig 解析 supported', () {
    test('普通一张表', () {
      final c = parseServerConfig(
        '{"hosts":["api.example.com"],"ips":["9.9.9.9"],'
        '"supported":["douyin.com","v.douyin.com","b23.tv"]}',
      );
      expect(c.supported, ['douyin.com', 'v.douyin.com', 'b23.tv']);
      expect(c.hosts, ['api.example.com']);
      expect(c.ips, ['9.9.9.9']);
    });

    test('老缓存里没有 supported 字段 —— 不能因此判成空配置', () {
      final c = parseServerConfig('{"ips":["9.9.9.9"]}');
      expect(c.supported, isEmpty);
      expect(c.isEmpty, isFalse, reason: '有 ips 就不算空配置');
    });

    test('坏条目按域名规则剔掉，不影响好条目', () {
      final c = parseServerConfig(
        '{"supported":["ok.example.com","evil.com:8443","x","a_b.example.com",'
        '"OK.EXAMPLE.COM","ok2.example.com"]}',
      );
      // 带端口的、单段的、带下划线的都拒；大小写归一后去重
      expect(c.supported, ['ok.example.com', 'ok2.example.com']);
    });

    test('非列表输入不炸', () {
      expect(parseServerConfig('{"supported":"douyin.com"}').supported, isEmpty);
    });

    test('只有 supported 时也不算空配置（否则会被 fetch 丢掉）', () {
      expect(parseServerConfig('{"supported":["b23.tv"]}').isEmpty, isFalse);
    });
  });

  group('unsupportedPlatformMessage 的匹配语义', () {
    test('白名单里的一律放行', () {
      supportedHosts = const ['b23.tv', 'v.douyin.com'];
      expect(unsupportedPlatformMessage('https://b23.tv/abc'), isNull);
      expect(unsupportedPlatformMessage('https://v.douyin.com/abc/'), isNull);
    });

    test('不在白名单里的一律拦', () {
      supportedHosts = const ['b23.tv'];
      expect(unsupportedPlatformMessage('https://www.tiktok.com/x'), '暂不支持该平台');
      expect(unsupportedPlatformMessage('https://pan.quark.cn/x'), '暂不支持该平台');
      expect(unsupportedPlatformMessage('https://www.zhihu.com/x'), '暂不支持该平台');
    });

    test('大小写归一', () {
      supportedHosts = const ['b23.tv'];
      expect(unsupportedPlatformMessage('https://B23.TV/abc'), isNull);
      expect(unsupportedPlatformMessage('https://WWW.TIKTOK.COM/x'), '暂不支持该平台');
    });

    test('列表为空时一律放行 —— 拉不到配置不改变原有行为', () {
      supportedHosts = const [];
      expect(unsupportedPlatformMessage('https://www.tiktok.com/x'), isNull);
    });

    test('认不出的输入放行（交给服务端去判）', () {
      supportedHosts = const ['b23.tv'];
      expect(unsupportedPlatformMessage(''), isNull);
      expect(unsupportedPlatformMessage('不是链接'), isNull);
    });

    test('精确匹配不认子域（服务端会把每个子域单独列出来）', () {
      // 只列了 douyin.com 时 v.douyin.com 会被判不支持。服务端下发的表其实两条都带
      // （实测 80 条 = 20 个开启平台名下的全部域名）。
      supportedHosts = const ['douyin.com'];
      expect(unsupportedPlatformMessage('https://v.douyin.com/abc'), '暂不支持该平台');
    });

    test('回归:白名单里没有的父域，不能连坐已在用的子域', () {
      // 视频号(已关)名下有 weixin.qq.com，白名单里不会有它；微信公众号在用的
      // mp.weixin.qq.com 有自己的条目。精确匹配下两者互不影响。
      supportedHosts = const ['mp.weixin.qq.com', 'b23.tv'];
      expect(unsupportedPlatformMessage('https://mp.weixin.qq.com/s/abc'), isNull);
      expect(
        unsupportedPlatformMessage('https://channels.weixin.qq.com/x'),
        '暂不支持该平台',
      );
    });
  });

  group('ParseService.parse 的本地拦截', () {
    test('不支持的平台一次请求都不发，直接抛', () async {
      supportedHosts = const ['b23.tv'];
      final hits = <String>[];
      ParseService.clientFactory = () => _recorder(hits);
      addTearDown(() => ParseService.clientFactory = http.Client.new);

      final service = ParseService();
      addTearDown(service.dispose);

      await expectLater(
        service.parse('https://www.tiktok.com/@x/video/1'),
        throwsA(
          isA<ParseException>().having((e) => e.message, 'message', '暂不支持该平台'),
        ),
      );
      expect(hits, isEmpty, reason: '本地拦掉就不该有任何网络请求');
      expect(service.lastRoute, 'blocked-local');
    });

    test('白名单里的平台照常走网络', () async {
      supportedHosts = const ['b23.tv'];
      final hits = <String>[];
      ParseService.clientFactory = () => _recorder(hits);
      addTearDown(() => ParseService.clientFactory = http.Client.new);

      final service = ParseService();
      addTearDown(service.dispose);

      // 不关心解析成败，只确认它确实发了请求
      try {
        await service.parse('https://b23.tv/abc');
      } catch (_) {}
      expect(hits, isNotEmpty);
    });

    test('回归:走上游的平台即使不在白名单里，也不许在本地拦', () async {
      // 视频号在服务端是关掉的，所以它**不在** supported 里；但它走第三方上游，
      // 能不能解析完全取决于那条接口。拿白名单直接套它 = 把这个平台整个废掉。
      // 这一条锁住「有上游路径就不做本地拦截」。
      supportedHosts = const ['b23.tv'];
      final hits = <String>[];
      ParseService.clientFactory = () => _recorder(hits);
      addTearDown(() => ParseService.clientFactory = http.Client.new);

      final service = ParseService();
      addTearDown(service.dispose);

      try {
        await service.parse('https://channels.weixin.qq.com/x');
      } catch (_) {}

      expect(
        hits.any((h) => h.contains('api/wxsph')),
        isTrue,
        reason: '视频号必须打到上游，而不是被本地拦掉',
      );
      expect(service.lastRoute, isNot('blocked-local'));
    });
  });
}

http.Client _recorder(List<String> hits) => MockClient((req) async {
  hits.add('${req.url.host}${req.url.path}');
  return http.Response('{"succ":false,"retcode":400,"retdesc":"x"}', 400);
});
