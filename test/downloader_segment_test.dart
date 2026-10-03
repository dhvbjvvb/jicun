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
  _FakeCdn(this.bytes, {this.wholeFileAsOk = false, this.stallFirstRange = false});

  final List<int> bytes;

  /// 服务端不理 Range:请求的区间**正好是整条**时回 200 + 整条文件(实测微信视频号
  /// 就是这样)。用来看引擎认不认这种响应。
  final bool wholeFileAsOk;

  /// 第一次真实取段故意磨蹭,用来逼出「这条连接太慢,掐掉换一条」
  /// (见 shouldRotateConnection)。
  final bool stallFirstRange;

  final Set<int> rangesSeen = <int>{};
  int peak = 0;
  int _live = 0;
  bool _stalled = false;
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
      // 探针要的是 `bytes=0-0`,不算"整条"。
      final wholeFile = start == 0 && end >= bytes.length - 1;
      if (wholeFileAsOk && wholeFile) {
        // 服务端不理 Range:整条区间按一次普通 GET 回 200 + 整条文件
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
        _live--;
        return;
      }
      // 第一次真实取段磨蹭:让引擎按"太慢了"把这条连接掐掉
      final slow = stallFirstRange && !_stalled && !(start == 0 && end == 0);
      if (slow) _stalled = true;
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
        await Future<void>.delayed(Duration(milliseconds: slow ? 80 : 2));
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

  test('要整条时服务端回 200:区间本来就等于整条,照样收下', () async {
    // 微信视频号实测:要整条时它回 200 而不是 206。按偏移写会写坏,所以判据是
    // `wholeFileAsRange`(起点 0、长度和区间对得上)—— 少了这条判据,这里会报
    // 「分段下载被拒:HTTP 200」,同一个视频在原生侧能下、在 Dart 引擎上下不动。
    final original = List<int>.generate(32 * 1024, (i) => i % 199);
    final cdn = _FakeCdn(original, wholeFileAsOk: true);
    await cdn.start();
    addTearDown(cdn.stop);

    final temp = await Directory.systemTemp.createTemp('jicun_200');
    addTearDown(() => temp.deleteSync(recursive: true));

    final realFrom = Downloader.segmentedFromBytes;
    final realChunk = Downloader.segmentBytes;
    // 让一段就盖住整条 —— 这是"区间 == 整条"那条路的前提
    Downloader.segmentedFromBytes = 16 * 1024;
    Downloader.segmentBytes = 1024 * 1024;
    addTearDown(() {
      Downloader.segmentedFromBytes = realFrom;
      Downloader.segmentBytes = realChunk;
    });

    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final file = await Downloader.fetchImpl(
      DownloadItem(
        url: cdn.uri.toString(),
        fileName: 'full.mp4',
        kind: MediaKind.video,
      ),
      temp,
      (_) {},
      null,
      (_) {},
      client,
    );

    expect(await file.readAsBytes(), equals(original));
  });

  test('连接太慢会被掐掉换一条,并且从断点接着收', () async {
    // 判据在规格里(shouldRotateConnection):用了多久还没收完这一段,而不是速率。
    final original = List<int>.generate(64 * 1024, (i) => i % 211);
    final cdn = _FakeCdn(original, stallFirstRange: true);
    await cdn.start();
    addTearDown(cdn.stop);

    final temp = await Directory.systemTemp.createTemp('jicun_rotate');
    addTearDown(() => temp.deleteSync(recursive: true));

    final realFrom = Downloader.segmentedFromBytes;
    final realChunk = Downloader.segmentBytes;
    final realSegments = Downloader.maxSegments;
    final realBudget = Downloader.connectionBudgetMs;
    Downloader.segmentedFromBytes = 16 * 1024;
    Downloader.segmentBytes = 16 * 1024;
    Downloader.maxSegments = 4;
    // 正常连接收一小段只要几十毫秒,预算压到 120ms 才不用真等 10 秒
    Downloader.connectionBudgetMs = 120;
    addTearDown(() {
      Downloader.segmentedFromBytes = realFrom;
      Downloader.segmentBytes = realChunk;
      Downloader.maxSegments = realSegments;
      Downloader.connectionBudgetMs = realBudget;
    });

    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final file = await Downloader.fetchImpl(
      DownloadItem(
        url: cdn.uri.toString(),
        fileName: 'slow.mp4',
        kind: MediaKind.video,
      ),
      temp,
      (_) {},
      null,
      (_) {},
      client,
    );

    expect(await file.readAsBytes(), equals(original));
    // 断点续传的痕迹:某一次要的不是段边界(16KB 的整数倍),而是"接着上次收到的地方"
    expect(
      cdn.rangesSeen.any((s) => s != 0 && s % (16 * 1024) != 0),
      isTrue,
      reason: '被掐掉之后应该从断点接着收,而不是整段从头重来',
    );
  });

  test('下载途中落下的临时文件都以 .part 结尾(进程被杀时清扫才认得出)', () async {
    // 启动清扫按"文件名以 .part 结尾"认下载留下的临时物(见 lib/downloader.dart 的
    // sweepLeftovers)。分片名要是写成 `…_0.part.part0`,结尾就不是 `.part` —— 进程半路
    // 被杀时这些分片清扫永远扫不到,一直占着缓存。
    final original = List<int>.generate(256 * 1024, (i) => i % 173);
    final cdn = _FakeCdn(original);
    await cdn.start();
    addTearDown(cdn.stop);

    final temp = await Directory.systemTemp.createTemp('jicun_partname');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

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

    // 先不 await:让它把分片落到盘上,再看那些分片叫什么
    final pending = Downloader.fetchImpl(
      DownloadItem(
        url: cdn.uri.toString(),
        fileName: 'parts.mp4',
        kind: MediaKind.video,
      ),
      temp,
      (_) {},
      null,
      (_) {},
      client,
    );
    // 256KB / 16KB = 16 段,4 条 worker 各领 4 段,每段 1KB 一写、间隔 2ms → 整趟 100ms 以上,
    // 所以这一刻它一定还在下
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final names = temp
        .listSync()
        .whereType<File>()
        .map((f) => f.path.split(Platform.pathSeparator).last)
        .toList();

    // 把下载等回来,别把半趟留在那儿
    final file = await pending;

    expect(names, isNotEmpty, reason: '这一刻应该已经落下分片了,不然这条用例白测');
    expect(
      names.every((n) => n.endsWith('.part')),
      isTrue,
      reason: '清扫只认 `.part` 结尾,分片名必须也是这个形状(实际:$names)',
    );
    expect(await file.readAsBytes(), equals(original));
  });
}
