// 真机下载基准:照抄 app 的连接方式(dart:io HttpClient + 24 路 Range 请求),
// 但把 UI / 分片落盘 / 进度回调全部去掉,测的是"这台手机连这个 CDN 到底能拿多少"。
//
// 用法(真机):
//   flutter test integration_test/dl_bench_test.dart --dart-define=URL=<视频地址>
//
// 结论怎么读:
//   - 这里也是 ~27 MB/s  → CDN/链路给这台设备的额度就到这,和 app 代码无关;
//   - 这里能到 50+        → app 的下载实现里有东西在拖(分片落盘、进度回调、UI)。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const String kUrl = String.fromEnvironment('URL');
const int kSegments = 24;
const int kBytesPerSegment = 4 << 20;

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('24 路 Range 并发:这台手机对这个 CDN 的真实吞吐', () async {
    expect(kUrl, isNotEmpty, reason: '要传 --dart-define=URL=<视频地址>');

    // --- 先量单连接 ---
    final single = await _run(1);
    debugPrint('[bench] 1  路: ${single.mbps.toStringAsFixed(2)} MB/s');

    // --- 再量 24 路 ---
    final many = await _run(kSegments);
    debugPrint(
      '[bench] $kSegments 路: ${many.mbps.toStringAsFixed(2)} MB/s '
      '(共 ${(many.bytes / (1 << 20)).toStringAsFixed(1)} MB / '
      '${many.seconds.toStringAsFixed(1)}s,每路 '
      '${(many.mbps / kSegments).toStringAsFixed(2)} MB/s)',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// 开 [parallel] 条连接,每条拉 [kBytesPerSegment] 字节,返回聚合吞吐。
Future<({double mbps, int bytes, double seconds})> _run(int parallel) async {
  final client = HttpClient()..maxConnectionsPerHost = parallel + 4;
  final bytes = List<int>.filled(parallel, 0);

  final watch = Stopwatch()..start();
  await Future.wait([
    for (var i = 0; i < parallel; i++) _one(client, i, bytes),
  ]);
  watch.stop();
  client.close(force: true);

  final total = bytes.fold<int>(0, (a, b) => a + b);
  final seconds = watch.elapsedMilliseconds / 1000;
  return (mbps: total / seconds / (1 << 20), bytes: total, seconds: seconds);
}

Future<void> _one(HttpClient client, int index, List<int> bytes) async {
  final start = index * kBytesPerSegment;
  final request = await client.getUrl(Uri.parse(kUrl));
  request.headers.set(
    HttpHeaders.rangeHeader,
    'bytes=$start-${start + kBytesPerSegment - 1}',
  );
  final response = await request.close();
  if (response.statusCode != 206 && response.statusCode != 200) {
    await response.drain<void>();
    throw HttpException('HTTP ${response.statusCode}');
  }
  await for (final chunk in response) {
    bytes[index] += chunk.length;
  }
}
