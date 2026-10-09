import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jicun/ui/audio_stage.dart';
import 'package:jicun/ui/playback.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// 音频预览的兜底抓取(`fetchAudioPreviewFile`):请求头、落盘、目录预算与淘汰、复用。
///
/// 这里故意**不装** `TestWidgetsFlutterBinding` —— 那个 binding 一装上,整个套件里的
/// HttpClient 都会被拦成 400(实测),而本文件的判据全在真本机 HTTP 服务端收到的请求
/// 上(和 test/downloader_ext_test.dart 同一个路数)。

/// `fetchAudioPreviewFile` 要问临时目录,替掉平台实现就行(不用走通道)。
class _TempDir extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _TempDir(this.root);

  final Directory root;

  @override
  Future<String?> getTemporaryPath() async => root.path;
}

/// 一台照着脚本回答的本机 CDN:记下收到的请求头,再按要不要 `Content-Length` 回字节。
class _FakeCdn {
  _FakeCdn({this.status = 200, this.bodyBytes = 16, this.chunked = false});

  final int status;
  final int bodyBytes;

  /// 分块回(不带 `Content-Length`)。
  final bool chunked;

  late HttpServer server;
  int requests = 0;
  final List<Map<String, String?>> received = <Map<String, String?>>[];

  /// 末段抄的是 B 站那条 DASH 音轨的形状(`…-1-30280.m4s`)。
  String urlFor(String tail) =>
      'http://127.0.0.1:${server.port}/upgcxcode/94/95/$tail';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      received.add(<String, String?>{
        'user-agent': request.headers.value(HttpHeaders.userAgentHeader),
        'referer': request.headers.value(HttpHeaders.refererHeader),
        'accept-encoding': request.headers.value(
          HttpHeaders.acceptEncodingHeader,
        ),
      });
      try {
        request.response.statusCode = status;
        if (status == 200 || status == 206) {
          if (!chunked) request.response.contentLength = bodyBytes;
          request.response.add(List<int>.filled(bodyBytes, 0x41));
        } else {
          request.response.write('Access Denied');
        }
        await request.response.close();
      } catch (_) {
        // 客户端可能已经收手把连接掐了:这里静音,别把用例带红。
      }
    });
  }

  Future<void> stop() => server.close(force: true);
}

/// 缓存目录里现在有几个文件(半截的 `.part` 也算)。
List<File> _files(Directory temp) =>
    temp.listSync(recursive: true).whereType<File>().toList();

/// 缓存目录现在占多少字节。
int _totalBytes(Directory temp) =>
    _files(temp).fold(0, (sum, file) => sum + file.statSync().size);

void main() {
  late Directory temp;
  late List<_FakeCdn> servers;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('jicun_preview');
    PathProviderPlatform.instance = _TempDir(temp);
    servers = <_FakeCdn>[];
  });

  tearDown(() async {
    for (final cdn in servers) {
      await cdn.stop();
    }
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// 起一台本机 CDN 并登记收尾。
  Future<_FakeCdn> serve({
    int status = 200,
    int bodyBytes = 16,
    bool chunked = false,
  }) async {
    final cdn = _FakeCdn(
      status: status,
      bodyBytes: bodyBytes,
      chunked: chunked,
    );
    servers.add(cdn);
    await cdn.start();
    return cdn;
  }

  test('抓到本地:文件落在缓存目录、后缀按内容改成 .m4a,请求头对齐普通客户端', () async {
    final cdn = await serve(status: 206);
    final url = cdn.urlFor('42456779594-1-30280.m4s?e=1');

    final fetched = await fetchAudioPreviewFile(url);

    expect(fetched.reason, isEmpty);
    final file = fetched.file;
    expect(file, isNotNull, reason: '206 也要能抓下来');
    expect(file!.existsSync(), isTrue);
    expect(file.lengthSync(), 16);
    expect(
      file.path,
      endsWith('${previewAudioCacheKey(url)}.m4a'),
      reason: 'fMP4 的音轨不该顶着 .m4s(或 .mp3)的名字',
    );
    expect(file.parent.path, endsWith('preview_audio'));

    expect(cdn.requests, 1);
    final sent = cdn.received.single;
    expect(
      sent['user-agent'],
      kBrowserUserAgent,
      reason: '认不出的主机发浏览器 UA(和这条兜底一直以来的行为一致)',
    );
    expect(sent['accept-encoding'], 'identity', reason: '要原始字节,不要压缩');
    expect(sent['referer'], isNull, reason: '不是 B 站的主机,不该塞 Referer');
  });

  test('抓过一次就复用:同一条地址不再发请求', () async {
    final cdn = await serve();
    final url = cdn.urlFor('a-1-30280.m4s');

    final first = await fetchAudioPreviewFile(url);
    final second = await fetchAudioPreviewFile(url);

    expect(first.file!.path, second.file!.path);
    expect(cdn.requests, 1, reason: '第二趟直接命中缓存文件');
  });

  test('复用会把时间戳往后推:淘汰看的是「最久没用过」', () async {
    final cdn = await serve();
    final url = cdn.urlFor('a-1-30280.m4s');
    final first = await fetchAudioPreviewFile(url);
    // 假装它已经躺了两小时
    final old = DateTime.now().subtract(const Duration(hours: 2));
    first.file!.setLastModifiedSync(old);

    final again = await fetchAudioPreviewFile(url);

    expect(again.file!.path, first.file!.path);
    expect(
      again.file!.statSync().modified.isAfter(
        old.add(const Duration(hours: 1)),
      ),
      isTrue,
      reason: '用过一次就不该还按两小时前的旧文件算',
    );
    expect(cdn.requests, 1);
  });

  test('非 200/206:三次都没成、不留文件,理由带回状态码', () async {
    final cdn = await serve(status: 403);
    final url = cdn.urlFor('a-1-30280.m4s');

    final fetched = await fetchAudioPreviewFile(url);

    expect(fetched.file, isNull);
    expect(fetched.reason, 'HTTP 403', reason: '卡上要能看出是 403,而不是一句黑盒');
    expect(cdn.requests, 3, reason: '三次都没成才交给调用方');
    expect(_files(temp), isEmpty, reason: '失败不留半截文件');
  });

  test('目录总量超预算:淘汰最久没用过的那条,刚抓的那条永远留着', () async {
    final cdn = await serve(bodyBytes: 16);
    const budget = 32; // 每条 16 字节 → 装得下两条

    final oldest = await fetchAudioPreviewFile(
      cdn.urlFor('a-1-30280.m4s'),
      budgetBytes: budget,
    );
    oldest.file!.setLastModifiedSync(
      DateTime.now().subtract(const Duration(minutes: 10)),
    );
    final middle = await fetchAudioPreviewFile(
      cdn.urlFor('b-1-30280.m4s'),
      budgetBytes: budget,
    );
    middle.file!.setLastModifiedSync(
      DateTime.now().subtract(const Duration(minutes: 5)),
    );

    // 前两条刚好顶满预算,第三条进来必须挤掉一条
    final newest = await fetchAudioPreviewFile(
      cdn.urlFor('c-1-30280.m4s'),
      budgetBytes: budget,
    );

    expect(newest.file!.existsSync(), isTrue, reason: '这一趟要交出去的那份不删');
    expect(middle.file!.existsSync(), isTrue);
    expect(oldest.file!.existsSync(), isFalse, reason: '最久没用过的那条先走');
    expect(_totalBytes(temp), lessThanOrEqualTo(budget));
    expect(cdn.requests, 3);
  });

  test('单个文件自己就超过预算:留着它 —— 要放的就是这一条', () async {
    final cdn = await serve(bodyBytes: 64);
    final url = cdn.urlFor('a-1-30280.m4s');

    final fetched = await fetchAudioPreviewFile(url, budgetBytes: 32);

    expect(fetched.file, isNotNull);
    expect(
      fetched.file!.existsSync(),
      isTrue,
      reason: '放不下也要先能预览:它会在下一次抓取时按「最旧」被淘汰',
    );
  });
}
