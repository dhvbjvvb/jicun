import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:untitled/downloader.dart';

/// `saveAll` 会去问临时目录。这里直接把平台实现换掉,而不是启动
/// `TestWidgetsFlutterBinding` —— 那个 binding 一装上,整个套件里的 HttpClient
/// 都会被拦成 400(实测),本文件里几个用例要靠真本机 HTTP 服务端。
class _TempDir extends PathProviderPlatform with MockPlatformInterfaceMixin {
  @override
  Future<String?> getTemporaryPath() async =>
      Directory.systemTemp.createTempSync('jicun_ext').path;
}

/// 头条 CDN 那种直链:路径最后一段是 `~tplv-tt-large.image`,没有可猜的后缀,
/// 格式只在响应头里。这里照抄那个形状。
class _FakeToutiao {
  _FakeToutiao(this.bytes, this.contentType);

  final List<int> bytes;
  final String contentType;
  late HttpServer server;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      request.response.headers.set(HttpHeaders.contentTypeHeader, contentType);
      // 探针就是 `bytes=0-0`。认 Range 就回 206 —— 和真 CDN 一样,而且不带
      // Accept-Ranges(头条/抖音都不带)。
      if (range != null) {
        final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
        final start = int.parse(match.group(1)!);
        final end = math.min(int.parse(match.group(2)!), bytes.length - 1);
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${bytes.length}',
          )
          ..headers.contentLength = end - start + 1;
        request.response.add(bytes.sublist(start, end + 1));
        await request.response.close();
        return;
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
  }

  Future<void> stop() => server.close(force: true);

  String get url => 'http://127.0.0.1:${server.port}$_toutiaoPath?_iz=30575';
}

/// 头条那条动图直链的真实形状:末段是 `~tplv-tt-large.image`,没有后缀可猜。
const String _toutiaoPath =
    '/dcb7288dbb3d4eb5a077765c756fb60c~tplv-tt-large.image';

/// GIF89a 文件头 + 一段填充。够看出格式就行,内容不必是真能解码的动图。
List<int> _gifBytes(int length) {
  final bytes = List<int>.filled(length, 0);
  const header = <int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61];
  for (var i = 0; i < header.length; i++) {
    bytes[i] = header[i];
  }
  return bytes;
}

void main() {
  // 收流那一步生产上是原生的(走平台通道),测试里到不了替身 —— 统一改走 Dart 实现。
  // 见 Downloader.useDartEngine。
  Downloader.useDartEngine = true;

  group('扩展名按内容定,不按地址猜', () {
    test('Content-Type 认得出就对得上类型,认不出或对不上都给空', () {
      expect(extensionForContentType('image/gif', MediaKind.image), '.gif');
      expect(
        extensionForContentType('image/jpeg; charset=utf-8', MediaKind.image),
        '.jpg',
      );
      expect(extensionForContentType('IMAGE/PNG', MediaKind.image), '.png');
      // 没信息的头:别乱认
      expect(extensionForContentType(null, MediaKind.image), '');
      expect(extensionForContentType('', MediaKind.image), '');
      expect(
        extensionForContentType('application/octet-stream', MediaKind.image),
        '',
      );
      // 类型对不上:标着视频却回图片,按视频登记进媒体库会被系统拒收
      expect(extensionForContentType('image/gif', MediaKind.video), '');
    });

    test('文件头嗅探', () {
      expect(extensionForBytes(_gifBytes(16)), '.gif');
      expect(
        extensionForBytes(const <int>[
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
        ]),
        '.png',
      );
      expect(
        extensionForBytes(const <int>[0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0]),
        '.jpg',
      );
      expect(
        extensionForBytes(const <int>[
          0x52,
          0x49,
          0x46,
          0x46,
          0,
          0,
          0,
          0,
          0x57,
          0x45,
          0x42,
          0x50,
        ]),
        '.webp',
      );
      // 认不出就承认认不出,不要瞎给一个后缀
      expect(extensionForBytes(const <int>[0x3C, 0x21, 0x44, 0x4F]), '');
      expect(extensionForBytes(const <int>[]), '');
    });

    test('真 MP4 的文件头认成 .mp4', () {
      // 真文件长这样:`00 00 00 20 'f' 't' 'y' 'p' 'i' 's' 'o' 'm' …` ——
      // 盒子大小在 0..3,'ftyp' 在 4..7,brand 在 8..11(实测 ffmpeg 产物)。
      expect(
        extensionForBytes(const <int>[
          0,
          0,
          0,
          0x20,
          0x66,
          0x74,
          0x79,
          0x70,
          0x69,
          0x73,
          0x6F,
          0x6D,
          0,
          0,
          2,
          0,
        ]),
        '.mp4',
      );
      // brand 是 qt → MOV
      expect(
        extensionForBytes(const <int>[
          0,
          0,
          0,
          0x14,
          0x66,
          0x74,
          0x79,
          0x70,
          0x71,
          0x74,
          0x20,
          0x20,
          0,
          0,
          0,
          1,
        ]),
        '.mov',
      );
    });

    test('地址上猜出来的是 .image,不是这张图真实的 gif', () {
      // 复刻解析期那段取后缀的规则:末段按最后一个点切开。切出来的是 CDN 变换名里的
      // `image`,不是扩展名 —— 它被当成扩展名记进文件名,与这张图真实格式(GIF)无关。
      // 这就是下载器必须拿响应头/文件头再定一次的原因。
      final segments = Uri.parse('https://p3-sign.toutiaoimg.com$_toutiaoPath')
          .pathSegments;
      final last = segments.last;
      expect(last.substring(last.lastIndexOf('.') + 1), 'image');
      expect(extensionForBytes(_gifBytes(16)), '.gif');
    });

    test('小文件:探针带 Content-Type,落盘改成 .gif', () async {
      final cdn = _FakeToutiao(_gifBytes(4096), 'image/gif');
      await cdn.start();
      addTearDown(cdn.stop);

      final temp = await Directory.systemTemp.createTemp('jicun_gif');
      addTearDown(() => temp.deleteSync(recursive: true));

      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      // 解析期按地址猜出来的名字:就是线上那个错名字(没有后缀可猜 → 兜底)
      final item = DownloadItem(
        url: cdn.url,
        fileName: '头条动图_1.jpg',
        kind: MediaKind.image,
      );
      final file = await Downloader.fetchImpl(
        item,
        temp,
        (_) {},
        null,
        (_) {},
        client,
      );

      expect(file.path, endsWith('.gif'));
      expect(item.fileName, '头条动图_1.gif');
      expect(await file.readAsBytes(), equals(_gifBytes(4096)));
    });

    test('saveAll 走完整条路:交给 publish 的名字也必须是 .gif', () async {
      // 这一条是踩过的坑:只改临时文件名的话 publishImpl 拿到的还是 item.fileName
      // 里的错后缀,相册里照旧是 .jpg —— 真机就是这么漏过去的。
      final cdn = _FakeToutiao(_gifBytes(4096), 'image/gif');
      await cdn.start();
      addTearDown(cdn.stop);

      // saveAll 自己会去问临时目录:换掉平台实现,别装 TestWidgetsFlutterBinding
      PathProviderPlatform.instance = _TempDir();

      final published = <String>[];
      final realPublish = Downloader.publishImpl;
      Downloader.publishImpl = (item, file) async {
        // 内容也得跟着一起对:名字改成 .gif 而内容是别的格式就是另一种错
        expect(await file.readAsBytes(), equals(_gifBytes(4096)));
        published.add(item.fileName);
        return null;
      };
      addTearDown(() => Downloader.publishImpl = realPublish);

      final item = DownloadItem(
        url: cdn.url,
        fileName: '头条动图_1.jpg',
        kind: MediaKind.image,
      );
      await Downloader.saveAll([item], onProgress: (_) {});

      expect(published, ['头条动图_1.gif']);
      expect(item.fileName, '头条动图_1.gif');
    });

    test('大文件走分段并行,拼完照样认成 .gif', () async {
      final original = _gifBytes(64 * 1024);
      final cdn = _FakeToutiao(original, 'image/gif');
      await cdn.start();
      addTearDown(cdn.stop);

      final temp = await Directory.systemTemp.createTemp('jicun_gif_seg');
      addTearDown(() => temp.deleteSync(recursive: true));

      final realFrom = Downloader.segmentedFromBytes;
      final realSegments = Downloader.maxSegments;
      final realChunk = Downloader.segmentBytes;
      Downloader.segmentedFromBytes = 16 * 1024;
      Downloader.segmentBytes = 16 * 1024;
      Downloader.maxSegments = 4;
      addTearDown(() {
        Downloader.segmentedFromBytes = realFrom;
        Downloader.segmentBytes = realChunk;
        Downloader.maxSegments = realSegments;
      });

      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final file = await Downloader.fetchImpl(
        DownloadItem(
          url: cdn.url,
          fileName: '头条动图_1.jpg',
          kind: MediaKind.image,
        ),
        temp,
        (_) {},
        null,
        (_) {},
        client,
      );

      expect(file.path, endsWith('.gif'));
      expect(await file.readAsBytes(), equals(original));
    });

    test('格式认不出时留着解析期的名字,至少不留 .part', () async {
      // 服务端把图片当二进制流发(拿不到 Content-Type),文件头又认不出:
      // 这时候谁也不知道它是什么,原名原样留着最安全。
      final cdn = _FakeToutiao(
        List<int>.generate(2048, (i) => i % 251),
        'application/octet-stream',
      );
      await cdn.start();
      addTearDown(cdn.stop);

      final temp = await Directory.systemTemp.createTemp('jicun_unknown');
      addTearDown(() => temp.deleteSync(recursive: true));

      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final file = await Downloader.fetchImpl(
        DownloadItem(
          url: cdn.url,
          fileName: '头条动图_1.jpg',
          kind: MediaKind.image,
        ),
        temp,
        (_) {},
        null,
        (_) {},
        client,
      );

      expect(file.path, endsWith('头条动图_1'));
    });
  });
}
