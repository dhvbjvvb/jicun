import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jicun/update_service.dart';

/// 造一份 release JSON,默认带一个 `jicun-<版本>.apk` 资产。
Map<String, dynamic> _release({
  String tag = 'v1.1.0',
  String body = '修了几个 bug',
  String? assetName,
  bool withApk = true,
}) => <String, dynamic>{
  'tag_name': tag,
  'body': body,
  'published_at': '2026-09-19T10:00:00Z',
  'assets': <dynamic>[
    <String, dynamic>{'name': 'source code (zip)'},
    if (withApk)
      <String, dynamic>{
        'name': assetName ?? 'jicun-${tag.replaceAll('v', '')}.apk',
      },
  ],
};

/// 200 + JSON。**必须走 bytes**:`http.Response(String, ...)` 按 Latin-1 编码,
/// 说明里的中文会直接抛 "Contains invalid characters"。
http.Response _json(Map<String, dynamic> body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: const <String, String>{'content-type': 'application/json'},
);

/// GitHub API 在仓库还没有 release 时回的那个 404:JSON 体 + `message: Not Found`。
///
/// 这个形状必须认准 —— 拿 HTML/空体的 404 冒充它,就等于把"这台机器没配这个接口"
/// 说成"仓库里没有版本"。
http.Response _githubNotFound() => http.Response.bytes(
  utf8.encode(
    jsonEncode({
      'message': 'Not Found',
      'documentation_url': 'https://docs.github.com/rest/releases/releases#get-the-latest-release',
      'status': '404',
    }),
  ),
  404,
  headers: const <String, String>{
    'content-type': 'application/json; charset=utf-8',
  },
);

/// nginx/CDN 的默认 404:HTML,不是 GitHub 的应答。
http.Response _nginxNotFound() => http.Response(
  '<html><head><title>404 Not Found</title></head></html>',
  404,
  headers: const <String, String>{'content-type': 'text/html'},
);

/// 换掉 UpdateService 的 client,用完还原。
void useStubUpdateClient(http.Client client) {
  UpdateService.clientFactory = () => client;
  addTearDown(() => UpdateService.clientFactory = () => http.Client());
}

/// 一个"按地址给应答"的假后端。
MockClient _backend(Map<String, http.Response> routes, {List<String>? seen}) =>
    MockClient((request) async {
      seen?.add(request.url.toString());
      return routes[request.url.toString()] ?? http.Response('not found', 404);
    });

ReleaseInfo _parse(Map<String, dynamic> json) => releaseFromJson(json)!;

void main() {
  // 用例里没有平台通道:架构查询直接给 null(等于"查不到"),走通用包那条路。
  // 要专门验 ABI 选择的用例自己再覆盖一次。
  setUp(() => UpdateService.abiResolver = () async => null);
  tearDown(() => UpdateService.abiResolver = deviceAbi);

  group('版本号', () {
    test('带不带 v、几位都能认', () {
      expect(parseVersion('v1.1.0'), [1, 1, 0]);
      expect(parseVersion('1.2'), [1, 2]);
      expect(parseVersion('V2'), [2]);
      expect(parseVersion('1.10.3'), [1, 10, 3]);
      // 预发布/构建元数据不参与比较
      expect(parseVersion('v1.1.0-beta.1'), [1, 1, 0]);
      expect(parseVersion('1.1.0+2'), [1, 1, 0]);
    });

    test('认不出的返回空表:空串、纯字母、带斜杠的都不是版本号', () {
      expect(parseVersion(''), isEmpty);
      expect(parseVersion('v'), isEmpty);
      expect(parseVersion('latest'), isEmpty);
      expect(parseVersion('release/1.1'), isEmpty);
    });

    test('比较:缺的段按 0 补,认不出就不算新版', () {
      expect(isNewerVersion('1.1.0', '1.0.0'), isTrue);
      expect(isNewerVersion('1.0.0', '1.1.0'), isFalse);
      expect(isNewerVersion('1.1.0', '1.1.0'), isFalse);
      // 1.1 和 1.1.0 是同一个版本
      expect(isNewerVersion('1.1', '1.1.0'), isFalse);
      expect(isNewerVersion('1.1.1', '1.1'), isTrue);
      // 数字段按数字比:1.10 > 1.9(按字符串比会反过来)
      expect(isNewerVersion('1.10.0', '1.9.0'), isTrue);
      // 认不出的一律不提示
      expect(isNewerVersion('latest', '1.0.0'), isFalse);
      expect(isNewerVersion('1.1.0', ''), isFalse);
    });
  });

  group('release JSON', () {
    test('挑第一个 .apk,跳过 source code 压缩包', () {
      final json = _release(tag: 'v1.1.0');
      expect(pickApkAsset(json)?['name'], 'jicun-1.1.0.apk');
    });

    test('没有 apk 资产就算没有可升级的版本', () {
      expect(releaseFromJson(_release(withApk: false)), isNull);
      expect(pickApkAsset(_release(withApk: false)), isNull);
      expect(pickApkAsset(<String, dynamic>{}), isNull);
      expect(pickApkAsset(<String, dynamic>{'assets': '不是列表'}), isNull);
    });

    test('挂了 ABI 拆分包时,按本机架构挑小的那份', () {
      final json = <String, dynamic>{
        'tag_name': 'v1.1.0',
        'assets': <dynamic>[
          {'name': 'jicun-1.1.0.apk'},
          {'name': 'jicun-1.1.0-arm64-v8a.apk'},
          {'name': 'jicun-1.1.0-armeabi-v7a.apk'},
        ],
      };

      // 老逻辑(以及原生查不到架构时)仍然是第一个 .apk —— 通用包,保证能装上
      expect(pickApkAsset(json)?['name'], 'jicun-1.1.0.apk');
      expect(
        pickApkAssetForAbi(json, 'arm64-v8a')?['name'],
        'jicun-1.1.0-arm64-v8a.apk',
      );
      expect(
        pickApkAssetForAbi(json, 'armeabi-v7a')?['name'],
        'jicun-1.1.0-armeabi-v7a.apk',
      );
      // 没有对应架构 / 查不到架构:交给调用方退回通用包
      expect(pickApkAssetForAbi(json, 'x86_64'), isNull);
      expect(pickApkAssetForAbi(json, null), isNull);

      expect(
        releaseFromJson(json, abi: 'arm64-v8a')?.apkName,
        'jicun-1.1.0-arm64-v8a.apk',
      );
      expect(releaseFromJson(json)?.apkName, 'jicun-1.1.0.apk');
    });

    test('tag 认不出(比如 latest)也不升级', () {
      expect(releaseFromJson(_release(tag: 'latest')), isNull);
      expect(releaseFromJson(<String, dynamic>{}), isNull);
    });

    test('映射出来的下载地址:公共镜像在前、自建反代在后、直连兜底', () {
      final release = _parse(_release(tag: 'v1.1.0'));
      expect(release.version, '1.1.0');
      expect(release.apkName, 'jicun-1.1.0.apk');
      expect(release.notes, '修了几个 bug');
      // 下载走的是公共镜像,不再依赖我们自己的站点
      for (final mirror in kGitHubMirrors) {
        expect(
          release.mirrorUrls,
          contains(
            '$mirror/https://github.com/dhvbjvvb/jicun/releases/download/'
            'v1.1.0/jicun-1.1.0.apk',
          ),
        );
      }
      expect(
        release.mirrorUrls.last,
        kMirrorAssetUrl('v1.1.0', 'jicun-1.1.0.apk'),
      );
      expect(
        release.directUrl,
        'https://github.com/dhvbjvvb/jicun/releases/download/v1.1.0/jicun-1.1.0.apk',
      );
    });

    test('body 不是字符串时说明按空处理,不抛异常', () {
      final json = _release()..['body'] = null;
      expect(_parse(json).notes, '');
    });

    test('真实 GitHub 应答(assets 为空、body 带 CRLF)也按预期处理', () {
      // 摘自 https://api.github.com/repos/httpie/cli/releases/latest 的真实字段。
      // 两件事都是真会遇到的:GitHub 允许 release 一个资产都不挂(那样就没得升级),
      // 而网页版敲出来的说明换行是 \r\n。
      final real = <String, dynamic>{
        'tag_name': '3.2.4',
        'published_at': '2024-11-01T17:33:07Z',
        'assets': <dynamic>[],
        'body':
            '- Fix default certs loading and unpin `requests`. '
            '([#1596](https://github.com/httpie/cli/issues/1596))\r\n',
      };
      // 没有 apk 资产 = 没有可升级的版本(而不是报错)
      expect(releaseFromJson(real), isNull);
      expect(pickApkAsset(real), isNull);

      // 同一个 body 换上 apk 资产就该认:"3.2.4" 这种不带 v 的 tag 也认
      final withApk = Map<String, dynamic>.from(real)
        ..['assets'] = <dynamic>[
          <String, dynamic>{'name': 'jicun-3.2.4.apk'},
        ];
      final release = _parse(withApk);
      expect(release.version, '3.2.4');
      expect(release.apkName, 'jicun-3.2.4.apk');
      // CRLF 换行要被当成一行,不能把 \r 带进正文
      final lines = parseMarkdown(release.notes);
      expect(lines, hasLength(1));
      expect(lines.single.text, contains('Fix default certs loading'));
      expect(lines.single.text, isNot(contains('\r')));
      // 链接只留文字
      expect(lines.single.text, isNot(contains('httpie/cli/issues')));
    });
  });

  group('fetchLatest:候选地址并行赛跑', () {
    // 用例里只喂两条候选,免得默认那三条(含真实域名)混进来。
    // 默认顺序由 kReleasesApis 决定,单独一个用例验。
    // 用假域名而不是 kMirrorReleasesApi:后者跟着全局 apiHost 走,别的用例
    // 改过它就会串味。
    const mirror = 'https://mirror.example/github/releases/latest';
    const direct = 'https://direct.example/releases/latest';

    test('两条都发了,先回来的那条说了算', () async {
      final seen = <String>[];
      useStubUpdateClient(
        _backend({
          mirror: _json(_release()),
          direct: _json(_release(tag: 'v1.1.0')),
        }, seen: seen),
      );
      final service = UpdateService();
      addTearDown(service.dispose);

      final release = await service.fetchLatest(urls: [mirror, direct]);
      expect(release?.version, '1.1.0');
      // 并行:不是"第一条通了就不打第二条"
      expect(seen, unorderedEquals([mirror, direct]));
    });

    test('反代挂了(500)能拿到直连的版本', () async {
      final seen = <String>[];
      useStubUpdateClient(
        _backend({
          mirror: http.Response('boom', 500),
          direct: _json(_release(tag: 'v1.2.0')),
        }, seen: seen),
      );
      final service = UpdateService();
      addTearDown(service.dispose);

      final release = await service.fetchLatest(urls: [mirror, direct]);
      expect(release?.version, '1.2.0');
      expect(seen, unorderedEquals([mirror, direct]));
    });

    test('一条地址没有这个接口(nginx 404)不代表没有新版:别的地址照拿', () async {
      // 实测就是这个形状:某条线路上没配 /github/releases/latest,回的是
      // **nginx 的 HTML 404**,而它曾经被当成"仓库里还没有任何 release"直接收工。
      const broken = 'https://broken.example/github/releases/latest';
      const good = 'https://good.example/github/releases/latest';
      useStubUpdateClient(
        _backend({
          broken: _nginxNotFound(),
          good: _json(_release(tag: 'v1.5.0')),
        }),
      );
      final service = UpdateService();
      addTearDown(service.dispose);

      final release = await service.fetchLatest(urls: [broken, good]);
      expect(release?.version, '1.5.0');
    });

    test('权威地址已经说"没有 release"就不再等慢的那条', () async {
      // 真机实测的痛点:直连 GitHub 0.1~0.7 秒就回了 GitHub 的 404,而自建反代
      // (在 CF 后面,走 IPv6 被黑洞)要 2.4~5.9 秒。权威依据到手就该收工。
      const mirror = 'https://mirror.example/github/releases/latest';
      final slowSeen = Completer<void>();
      final slowMayFinish = Completer<void>();
      useStubUpdateClient(
        MockClient((request) async {
          if (request.url.toString() == kReleasesApi) return _githubNotFound();
          // 镜像那条挂着不回,直到用例放它走
          slowSeen.complete();
          await slowMayFinish.future;
          return _githubNotFound();
        }),
      );
      final service = UpdateService();
      addTearDown(service.dispose);

      final result = await service.fetchLatest(urls: [mirror, kReleasesApi]);
      expect(result, isNull, reason: '权威地址说了没有 release,就是没有新版');
      // 关键断言:镜像那条**还没回**,这次检查就已经结束了
      await slowSeen.future;
      slowMayFinish.complete();
    });

    test('慢的那条先回来时不抢答:别人可能知道答案', () async {
      // 反过来验一遍:镜像先回 404(它不是权威),得继续等直连 GitHub 的答案 ——
      // 否则一条坏线路的 404 就会把"其实有新版"盖成"没有新版"。
      const mirror = 'https://mirror.example/github/releases/latest';
      final seen = <String>[];
      useStubUpdateClient(
        MockClient((request) async {
          seen.add(request.url.toString());
          if (request.url.toString() == mirror) return _nginxNotFound();
          return _json(_release(tag: 'v1.9.0'));
        }),
      );
      final service = UpdateService();
      addTearDown(service.dispose);

      final release = await service.fetchLatest(urls: [mirror, kReleasesApi]);
      expect(release?.version, '1.9.0');
      expect(seen, contains(kReleasesApi));
    });

    test('反代连不上(抛异常)也能拿到直连的版本', () async {
      useStubUpdateClient(
        MockClient((request) async {
          if (request.url.toString() == mirror) {
            throw const SocketException('connection refused');
          }
          return _json(_release(tag: 'v1.3.0'));
        }),
      );
      final service = UpdateService();
      addTearDown(service.dispose);

      expect(
        (await service.fetchLatest(urls: [mirror, direct]))?.version,
        '1.3.0',
      );
    });

    test('两条都不通:抛 UpdateException,消息里带上两条失败原因', () async {
      useStubUpdateClient(
        _backend({
          mirror: http.Response('boom', 500),
          direct: http.Response('boom', 503),
        }),
      );
      final service = UpdateService();
      addTearDown(service.dispose);

      await expectLater(
        service.fetchLatest(urls: [mirror, direct]),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            allOf(contains('500'), contains('503')),
          ),
        ),
      );
    });

    test('全是 GitHub 的 404 才是"没有新版"', () async {
      useStubUpdateClient(
        _backend({mirror: _githubNotFound(), direct: _githubNotFound()}),
      );
      final service = UpdateService();
      addTearDown(service.dispose);

      expect(await service.fetchLatest(urls: [mirror, direct]), isNull);
    });

    test('一条回 HTML 404(没配接口)一条不通:算失败,不能报"已是最新"', () async {
      // 一边是"我这儿没这个接口",一边是"网络不通" —— 谁也没说"仓库里没有版本",
      // 这种时候报"当前已是最新版本"就是在骗用户。
      useStubUpdateClient(
        _backend({
          mirror: _nginxNotFound(),
          direct: http.Response('boom', 503),
        }),
      );
      final service = UpdateService();
      addTearDown(service.dispose);

      await expectLater(
        service.fetchLatest(urls: [mirror, direct]),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('没配这个接口'),
          ),
        ),
      );
    });

    test('只有一条 HTML 404(没配接口)也算失败,不能报"没有新版"', () async {
      // 这一条是这次修的核心:nginx 的 404 和 GitHub 的 404 **都是 404**,
      // 之前只看状态码,于是"接口没配"被读成了"仓库里没有 release"。
      useStubUpdateClient(_backend({mirror: _nginxNotFound()}));
      final service = UpdateService();
      addTearDown(service.dispose);

      await expectLater(
        service.fetchLatest(urls: [mirror]),
        throwsA(isA<UpdateException>()),
      );
    });

    test('release 里只挂了源码包,也算没有新版', () async {
      useStubUpdateClient(_backend({mirror: _json(_release(withApk: false))}));
      final service = UpdateService();
      addTearDown(service.dispose);

      expect(await service.fetchLatest(urls: [mirror]), isNull);
    });

    test('默认候选:公共镜像打头,自建反代和直连留在后面兜底', () {
      // 实测手机网络上只有公共镜像真能答上来(mxper.cc.cd 被 reset、videofix.top
      // 没配那个 location、api.github.com 直连到不了),所以它们排前面。
      // 谁先答听谁的(见 fetchLatest),顺序只影响平时谁先答。
      expect(kReleasesApis.first, '${kGitHubMirrors.first}/$kReleasesApi');
      expect(kReleasesApis, contains(kMirrorReleasesApi));
      expect(kReleasesApis.last, kReleasesApi);
      // 两条自建/兜底不能丢:公共镜像哪天集体失效,更新不能跟着一起哑掉
      expect(kReleasesApis, hasLength(kGitHubMirrors.length + 2));
    });
  });

  group('该不该弹更新卡', () {
    // 这一组不碰网络,client 随便给一个
    UpdateService service() =>
        UpdateService(client: MockClient((_) async => http.Response('', 200)));

    bool prompt(String local, String? ignored, String? remote) =>
        service().shouldPrompt(
          localVersion: local,
          ignored: ignored,
          release: remote == null ? null : _parse(_release(tag: remote)),
        );

    test('比本机新才弹', () {
      expect(prompt('1.0.0', null, 'v1.1.0'), isTrue);
      expect(prompt('1.1.0', null, 'v1.1.0'), isFalse);
      expect(prompt('1.2.0', null, 'v1.1.0'), isFalse);
    });

    test('没有 release 就不弹', () {
      expect(prompt('1.0.0', null, null), isFalse);
    });

    test('忽略过的版本不再弹,直到仓库发了更高的', () {
      // 1.0 忽略 1.1 → 不再弹
      expect(prompt('1.0.0', '1.1.0', 'v1.1.0'), isFalse);
      // 仓库发到 1.2 → 重新弹(需求里就是这么定的)
      expect(prompt('1.0.0', '1.1.0', 'v1.2.0'), isTrue);
      // 忽略的是更高的版本同样不弹
      expect(prompt('1.0.0', '2.0.0', 'v1.1.0'), isFalse);
    });
  });

  group('下载 APK', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('jicun_apk');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    /// 直接喂一段流,不走真网络。
    MockClient streaming({required List<int> bytes}) =>
        MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(
            Stream<List<int>>.fromIterable(<List<int>>[
              bytes.sublist(0, bytes.length ~/ 2),
              bytes.sublist(bytes.length ~/ 2),
            ]),
            200,
            contentLength: bytes.length,
          );
        });

    test('下完落成正式文件名,进度累计到 100%', () async {
      final bytes = List<int>.generate(2048, (i) => i % 251);
      final release = _parse(_release());
      useStubUpdateClient(streaming(bytes: bytes));
      final service = UpdateService();
      addTearDown(service.dispose);

      final progress = <double>[];
      final file = await service.downloadApk(
        release,
        dir: dir,
        onProgress: (p) => progress.add(p.fraction),
      );

      expect(file.path, endsWith('jicun-1.1.0.apk'));
      expect(await file.readAsBytes(), equals(bytes));
      expect(progress.last, 1.0);
      // 没有留下 .part
      expect(
        dir.listSync().map((e) => e.path).where((p) => p.endsWith('.part')),
        isEmpty,
      );
    });

    test('镜像下载失败(403)就换下一个,直到直连兜底', () async {
      final bytes = List<int>.generate(512, (i) => i % 97);
      final release = _parse(_release());
      final seen = <String>[];
      useStubUpdateClient(
        MockClient.streaming((request, bodyStream) async {
          seen.add(request.url.toString());
          // 所有镜像都 403,只有直连给字节
          if (request.url.toString() != release.directUrl) {
            return http.StreamedResponse(const Stream<List<int>>.empty(), 403);
          }
          return http.StreamedResponse(
            Stream<List<int>>.value(bytes),
            200,
            contentLength: bytes.length,
          );
        }),
      );
      final service = UpdateService();
      addTearDown(service.dispose);

      final file = await service.downloadApk(
        release,
        dir: dir,
        onProgress: (_) {},
      );
      expect(seen, [...release.mirrorUrls, release.directUrl]);
      expect(await file.readAsBytes(), equals(bytes));
    });

    test('第一个镜像通了就不再试后面的', () async {
      final bytes = List<int>.generate(128, (i) => i % 31);
      final release = _parse(_release());
      final seen = <String>[];
      useStubUpdateClient(
        MockClient.streaming((request, bodyStream) async {
          seen.add(request.url.toString());
          return http.StreamedResponse(
            Stream<List<int>>.value(bytes),
            200,
            contentLength: bytes.length,
          );
        }),
      );
      final service = UpdateService();
      addTearDown(service.dispose);

      await service.downloadApk(release, dir: dir, onProgress: (_) {});
      expect(seen, [release.mirrorUrl]);
    });

    test('反代透传的 302 要跟到 CDN 才拿得到包', () async {
      // 真实链路:反代把 GitHub 的 302(Location → objects.githubusercontent.com)
      // 原样透传,APP 必须跟这一跳。`http.Request.followRedirects` 默认是 false,
      // 不打开的话真机上拿到的就是一个 302,下载直接失败(实测联调就是这么断的)。
      final bytes = List<int>.generate(1024, (i) => i % 199);
      final release = _parse(_release());
      const cdn = 'https://objects.githubusercontent.com/signed/asset.apk';
      final seen = <String>[];
      useStubUpdateClient(
        MockClient.streaming((request, bodyStream) async {
          final url = request.url.toString();
          seen.add(url);
          if (url == release.mirrorUrl) {
            return http.StreamedResponse(
              const Stream<List<int>>.empty(),
              302,
              headers: const <String, String>{'location': cdn},
            );
          }
          if (url == cdn) {
            return http.StreamedResponse(
              Stream<List<int>>.value(bytes),
              200,
              contentLength: bytes.length,
            );
          }
          return http.StreamedResponse(const Stream<List<int>>.empty(), 404);
        }),
      );
      final service = UpdateService();
      addTearDown(service.dispose);

      final file = await service.downloadApk(
        release,
        dir: dir,
        onProgress: (_) {},
      );
      expect(seen, [release.mirrorUrl, cdn], reason: '要跟这一跳');
      expect(await file.readAsBytes(), equals(bytes));
    });

    test('一直 302 打转时报错,不会无限跟', () async {
      final release = _parse(_release());
      useStubUpdateClient(
        MockClient.streaming((request, bodyStream) async {
          // 永远 302 到别处
          return http.StreamedResponse(
            const Stream<List<int>>.empty(),
            302,
            headers: const <String, String>{
              'location': 'https://objects.githubusercontent.com/loop.apk',
            },
          );
        }),
      );
      final service = UpdateService();
      addTearDown(service.dispose);

      // 跟不下去就是失败,而且不留半个文件(具体异常类型由 http 包决定)
      await expectLater(
        service.downloadApk(release, dir: dir, onProgress: (_) {}),
        throwsA(isA<Exception>()),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('两条都不通:抛异常,不留半个文件', () async {
      final release = _parse(_release());
      useStubUpdateClient(
        MockClient.streaming(
          (request, bodyStream) async =>
              http.StreamedResponse(const Stream<List<int>>.empty(), 502),
        ),
      );
      final service = UpdateService();
      addTearDown(service.dispose);

      await expectLater(
        service.downloadApk(release, dir: dir, onProgress: (_) {}),
        throwsA(isA<UpdateException>()),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('收到一半取消:抛 UpdateCancelled,不留半个文件', () async {
      final bytes = List<int>.generate(4096, (i) => i % 131);
      final release = _parse(_release());
      useStubUpdateClient(streaming(bytes: bytes));
      final service = UpdateService();
      addTearDown(service.dispose);

      var chunks = 0;
      await expectLater(
        service.downloadApk(
          release,
          dir: dir,
          onProgress: (_) => chunks++,
          // 收第一段之后就要求取消
          cancelled: () => chunks >= 1,
        ),
        throwsA(isA<UpdateCancelled>()),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('字节数对不上(服务端中途断流)按失败处理', () async {
      final release = _parse(_release());
      useStubUpdateClient(
        MockClient.streaming((request, bodyStream) async {
          final mirror = request.url.toString() == release.mirrorUrl;
          return http.StreamedResponse(
            // 说好 100 字节,只给 10 字节
            Stream<List<int>>.value(List<int>.filled(10, 1)),
            mirror ? 200 : 502,
            contentLength: 100,
          );
        }),
      );
      final service = UpdateService();
      addTearDown(service.dispose);

      await expectLater(
        service.downloadApk(release, dir: dir, onProgress: (_) {}),
        throwsA(isA<UpdateException>()),
      );
      expect(dir.listSync(), isEmpty);
    });
  });

  group('已下好的包', () {
    test('还在就用它,0 字节的残件不算', () async {
      final dir = await Directory.systemTemp.createTemp('jicun_cache');
      addTearDown(() => dir.deleteSync(recursive: true));
      final release = _parse(_release());

      expect(ApkCache.existing(release, dir), isNull);

      final file = File('${dir.path}/${release.apkName}');
      file.writeAsBytesSync(const <int>[]);
      expect(ApkCache.existing(release, dir), isNull, reason: '空文件是残件');

      file.writeAsBytesSync(List<int>.filled(16, 7));
      expect(ApkCache.existing(release, dir)?.path, file.path);
    });
  });

  group('release 说明的 markdown', () {
    test('标题/列表/引用都翻成纯文本,前缀单独带出来', () {
      final lines = parseMarkdown(
        '# 新版本\n'
        '\n'
        '- 修了 A 的崩溃\n'
        '* 修了 B 的卡顿\n'
        '1. 先做这个\n'
        '2) 再做那个\n'
        '> 注意要重装\n'
        '普通一行',
      );
      expect(lines[0].kind, MdLineKind.heading);
      expect(lines[0].text, '新版本');
      expect(lines[1].text, '', reason: '空行保留,当段落间距');
      expect(lines[2].prefix, '• ');
      expect(lines[2].text, '修了 A 的崩溃');
      expect(lines[3].prefix, '• ');
      expect(lines[4].prefix, '1. ');
      expect(lines[5].prefix, '2. ');
      expect(lines[6].prefix, '│ ');
      expect(lines[6].text, '注意要重装');
      expect(lines[7].text, '普通一行');
    });

    test('行内标记:粗体、代码、链接、图片都只剩文字', () {
      final lines = parseMarkdown(
        '**重点**和`代码`还有[链接](https://x.example)与![图](https://x.example/a.png)',
      );
      expect(lines.single.text, '重点和代码还有链接与图');
    });

    test('代码块整块按代码样式,围栏本身不显示', () {
      final lines = parseMarkdown('前言\n```\nflutter build apk\n```\n后记');
      expect(lines.map((l) => l.text), ['前言', 'flutter build apk', '后记']);
      expect(lines[1].kind, MdLineKind.code);
    });

    test('分割线丢掉,头尾空行去掉', () {
      final lines = parseMarkdown('\n\n---\n\n正文\n\n***\n');
      expect(lines.map((l) => l.text), ['正文']);
    });

    test('空说明解析出来是空表', () {
      expect(parseMarkdown(''), isEmpty);
      expect(parseMarkdown('\n\n'), isEmpty);
    });
  });
}
