import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:jicun/downloader.dart';

/// 一个假的 CDN:认 Range,回 206。用来证明大文件真的走了分段并行,
/// 而且是**并发**在拉 —— 单连接串行也能拼出正确结果,所以光看文件内容不够。
///
/// 故意**不发** `Accept-Ranges`:抖音视频 CDN 就是这样,回 206 但不带这个头。
/// 判定要是只认这个头,360MB 的视频就会被当成"不分段"。
class _FakeCdn {
  _FakeCdn(this.bytes);

  final List<int> bytes;
  final Set<int> rangesSeen = <int>{};
  int peak = 0;
  int _live = 0;
  late HttpServer server;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range == null) {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
        return;
      }
      final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
      final start = int.parse(match.group(1)!);
      final end = math.min(int.parse(match.group(2)!), bytes.length - 1);
      _live++;
      peak = math.max(peak, _live);
      rangesSeen.add(start);
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${bytes.length}',
        )
        ..headers.contentLength = end - start + 1;
      // 分几次写,别一次把整段推完 —— 不然并发看不到重叠
      final slice = bytes.sublist(start, end + 1);
      const step = 1024;
      for (var i = 0; i < slice.length; i += step) {
        request.response.add(
          slice.sublist(i, math.min(i + step, slice.length)),
        );
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      await request.response.close();
      _live--;
    });
  }

  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}/v.mp4');

  Future<void> stop() => server.close(force: true);
}

void main() {
  test('大文件走 Range 分段并行,拼出来的字节和原文件一致', () async {
    final original = List<int>.generate(64 * 1024, (i) => i % 251);
    final cdn = _FakeCdn(original);
    await cdn.start();
    addTearDown(cdn.stop);

    final temp = await Directory.systemTemp.createTemp('jicun_seg');
    addTearDown(() => temp.deleteSync(recursive: true));

    // 把阈值调小,免得测试真下 8MB
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
        url: cdn.uri.toString(),
        fileName: 'big.mp4',
        kind: MediaKind.video,
      ),
      temp,
      (_) {},
      null,
      (_) {},
      client,
    );

    expect(await file.readAsBytes(), equals(original));
    // 分段并行:至少两条连接同时在拉
    expect(cdn.peak, greaterThan(1));
    expect(cdn.rangesSeen.length, greaterThan(1));
  });

  test('服务端不发 Accept-Ranges 也要分段:206 就算认 Range', () async {
    // 抖音视频 CDN 就是这样:Range 请求回 206,但响应里没有 Accept-Ranges。
    // 真机踩过:判定只看这个头时,360MB 的视频被判成"不分段",退回单连接。
    final original = List<int>.generate(64 * 1024, (i) => i % 131);
    final cdn = _FakeCdn(original);
    await cdn.start();
    addTearDown(cdn.stop);

    final temp = await Directory.systemTemp.createTemp('jicun_nohdr');
    addTearDown(() => temp.deleteSync(recursive: true));

    final realFrom = Downloader.segmentedFromBytes;
    final realChunk = Downloader.segmentBytes;
    final realSegments = Downloader.maxSegments;
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
        url: cdn.uri.toString(),
        fileName: 'nohdr.mp4',
        kind: MediaKind.video,
      ),
      temp,
      (_) {},
      null,
      (_) {},
      client,
    );

    expect(await file.readAsBytes(), equals(original));
    // 只有探针那一发的话,peak 就是 1、rangesSeen 只有 {0}
    expect(cdn.peak, greaterThan(1));
    expect(cdn.rangesSeen.length, greaterThan(1));
  });

  test('小文件不分段:一条连接整条下', () async {
    final original = List<int>.generate(4096, (i) => i % 97);
    final cdn = _FakeCdn(original);
    await cdn.start();
    addTearDown(cdn.stop);

    final temp = await Directory.systemTemp.createTemp('jicun_small');
    addTearDown(() => temp.deleteSync(recursive: true));

    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final file = await Downloader.fetchImpl(
      DownloadItem(
        url: cdn.uri.toString(),
        fileName: 'small.jpg',
        kind: MediaKind.image,
      ),
      temp,
      (_) {},
      null,
      (_) {},
      client,
    );

    expect(await file.readAsBytes(), equals(original));
    // 只有探针那一次 Range,没有分段并行
    expect(cdn.rangesSeen, equals(<int>{0}));
    expect(cdn.peak, lessThanOrEqualTo(1));
  });

  test('取消时不留半个文件,也不留段', () async {
    final original = List<int>.generate(64 * 1024, (i) => i % 13);
    final cdn = _FakeCdn(original);
    await cdn.start();
    addTearDown(cdn.stop);

    final temp = await Directory.systemTemp.createTemp('jicun_cancel');
    addTearDown(() => temp.deleteSync(recursive: true));

    final realFrom = Downloader.segmentedFromBytes;
    final realChunk = Downloader.segmentBytes;
    Downloader.segmentedFromBytes = 16 * 1024;
    Downloader.segmentBytes = 16 * 1024;
    final realSegments = Downloader.maxSegments;
    Downloader.maxSegments = 4;
    addTearDown(() {
      Downloader.segmentedFromBytes = realFrom;
      Downloader.segmentBytes = realChunk;
      Downloader.maxSegments = realSegments;
    });

    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    var checks = 0;
    await expectLater(
      Downloader.fetchImpl(
        DownloadItem(
          url: cdn.uri.toString(),
          fileName: 'cancel.mp4',
          kind: MediaKind.video,
        ),
        temp,
        (_) {},
        // 读几段之后要求取消
        () => checks++ > 2,
        (_) {},
        client,
      ),
      throwsA(isA<DownloadCancelled>()),
    );

    final leftovers = temp
        .listSync()
        .map((e) => e.path.split(Platform.pathSeparator).last)
        .toList();
    expect(leftovers, isEmpty);
  });
}
