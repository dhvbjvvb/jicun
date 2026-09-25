import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'downloader.dart';

/// 下载基准:用和 [Downloader] 完全一样的网络栈(dart:io `HttpClient` + N 路
/// Range 请求)拉同一批数据,但**不落盘、不报进度、不动 UI**。
///
/// 它回答的是一个排障问题:真机上聚合速度只有 PC 的一半时,卡的是
/// 「这台设备 + 这条链路」还是「我们的下载实现(分片落盘、进度回调、UI)」。
///   - 这里也是 27 MB/s  → 设备/链路额度,和实现无关;
///   - 这里能到 43+       → 实现在拖,接着往 `Downloader._fetchSegments` 里查。
///
/// 怎么触发(debug 构建):
///   adb shell am start -n com.videofix.jicun/.MainActivity \
///     --es bench_url "<视频地址>" --ei bench_segments 24
/// 结果打在 logcat 的 flutter tag 上(`[bench]` 前缀)。
///
/// ponytail: 只给排障用,不做界面、不做持久化。用完这个文件可以整个删掉,
/// main.dart 里就一处 initBench() 的调用。
class DownloadBench {
  const DownloadBench._();

  /// 让原生把意图里的参数递进来。
  static const MethodChannel _channel = MethodChannel('jicun/bench');

  static const int _bytesPerSegment = 4 << 20;

  /// 启动时问一次原生:这次启动是不是带着基准参数来的?是就跑一轮。
  ///
  /// 两种用法:
  ///   `--es bench_url <视频地址> [--ei bench_segments N]`  跑分段基准
  ///   `--es bench_file <任意大文件地址>`                    跑顺序下载基准
  ///
  /// 调用方(main.dart)只在 debug 构建里调;release 上这个方法根本不会被调用。
  static Future<void> checkIntent() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('get');
      debugPrint('[bench] checkIntent raw=$raw');
      if (raw is! Map) return;
      final segments = (raw['segments'] as num?)?.toInt() ?? 24;
      final file = (raw['file'] as String?) ?? '';
      final url = (raw['url'] as String?) ?? '';
      final seq = (raw['seq'] as String?) ?? '';
      // `--ei dl_segments N`:把下载器的分段数临时定成 N,只影响本次进程。
      //
      // 为什么要有它:「一条文件开几路最快」只能在同一台手机、同一条网络上扫出来,
      // 而每换一个数字就重新打包一次太慢。和 `bench_segments` 分开是因为那边 24 是
      // "没传"的哨兵值,单独传 `--ei bench_segments 24` 会被当成没传。
      final dlSegments = (raw['dlSegments'] as num?)?.toInt() ?? -1;
      if (dlSegments > 0) {
        Downloader.maxSegments = dlSegments;
        _log('下载器分段数临时设为 $dlSegments(本次进程有效)');
      }
      if (seq.isNotEmpty) {
        // 顺序下载但要指定并发:N 条各拉固定字节,用来在同一份数据上比并发数。
        unawaited(_runParallelLanes(seq, segments));
        return;
      }
      if (file.isEmpty && url.isEmpty) return;
      if (file.isNotEmpty) {
        unawaited(runSequential(file));
        return;
      }
      unawaited(runSegments(url, segments));
    } catch (error) {
      _log('取基准参数失败: $error');
    }
  }

  /// [parallel] 条连接,每条拉 [laneBytes],比的是纯网络吞吐(不落盘、不回调、
  /// 不把数据留在内存里)。
  ///
  /// **每条必须拉足够大**(默认 256MB):早先每次只取 8-16MB 时,启动爬坡那几百
  /// 毫秒占了整个窗口的一大截,量出来的数字比真实值低一半以上(PC 上实测 11 vs 30)。
  /// 累计字节用一个计数器,数据本身读完就扔 —— 24 条 × 256MB 不可能放进内存。
  static Future<void> _runParallelLanes(String url, int parallel) async {
    const laneBytes = 256 << 20;
    final client = HttpClient()..maxConnectionsPerHost = parallel + 4;
    final counters = List<int>.filled(parallel, 0);
    final watch = Stopwatch()..start();
    try {
      await Future.wait([
        for (var i = 0; i < parallel; i++)
          _lane(client, url, i, laneBytes, counters),
      ]);
      watch.stop();
      final total = counters.fold<int>(0, (a, b) => a + b);
      final seconds = watch.elapsedMilliseconds / 1000;
      _log(
        '$parallel 路 × ${laneBytes >> 20}MB: '
        '${(total / (1 << 20) / seconds).toStringAsFixed(2)} MB/s '
        '(共 ${(total / (1 << 20)).toStringAsFixed(1)}MB / '
        '${seconds.toStringAsFixed(1)}s · 每路 '
        '${(total / (1 << 20) / seconds / parallel).toStringAsFixed(2)} MB/s)',
      );
    } catch (error) {
      _log('并发基准失败: $error');
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _lane(
    HttpClient client,
    String url,
    int index,
    int laneBytes,
    List<int> counters,
  ) async {
    final start = index * laneBytes;
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(
      HttpHeaders.rangeHeader,
      'bytes=$start-${start + laneBytes - 1}',
    );
    final response = await request.close();
    if (response.statusCode != 206 && response.statusCode != 200) {
      await response.drain<void>();
      throw HttpException('HTTP ${response.statusCode}');
    }
    await for (final chunk in response) {
      counters[index] += chunk.length;
    }
  }

  /// 跑一轮基准。两种模式,靠意图参数选:
  ///
  /// - `--es bench_url <视频地址>`:分段模式。量 1 路、8 路、N 路并发到那个 CDN
  ///   的吞吐 —— 用来判断"这台设备对这条 CDN 能拿多少"。
  /// - `--es bench_file <任意大文件地址>`:顺序整条下载(不带 Range、不落盘),
  ///   只报速度。用来量**这台设备 + 这条 WiFi 的物理上限** —— 换一个跟抖音 CDN
  ///   无关的源(比如阿里云镜像的大 ISO),就能把"手机射频上限"和"CDN 额度"分开。
  /// - `--es bench_seq <地址>`:**顺序**整条下载,并发数由
  ///   `--ei bench_segments N` 给(N 条各拉 64MB,不落盘)。用来在同一份数据上
  ///   对比不同并发,不用重新打包。
  static Future<void> runSegments(String url, int parallel) async {
    try {
      final one = await _once(url, 1);
      _log('1 路: ${one.mbps.toStringAsFixed(2)} MB/s');
      for (final n in [8, parallel]) {
        if (n <= 1) continue;
        final many = await _once(url, n);
        _log(
          '$n 路: ${many.mbps.toStringAsFixed(2)} MB/s'
          ' (共 ${(many.bytes / (1 << 20)).toStringAsFixed(1)}MB'
          ' / ${many.seconds.toStringAsFixed(1)}s'
          ' · 每路 ${(many.mbps / n).toStringAsFixed(2)} MB/s)',
        );
      }
    } catch (error) {
      _log('分段模式失败: $error');
    }
  }

  /// 顺序整条下载,报实时速度和均值。见 [runSegments] 的说明。
  static Future<void> runSequential(String url, {int seconds = 12}) async {
    final client = HttpClient();
    var received = 0;
    final watch = Stopwatch()..start();
    var lastLog = 0;
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.drain<void>();
        throw HttpException('HTTP ${response.statusCode}');
      }
      await for (final chunk in response) {
        received += chunk.length;
        final ms = watch.elapsedMilliseconds;
        if (ms - lastLog >= 2000) {
          lastLog = ms;
          _log(
            '顺序下载 已收 ${(received / (1 << 20)).toStringAsFixed(1)}MB'
            ' · 均值 ${(received / (ms / 1000) / (1 << 20)).toStringAsFixed(2)} MB/s',
          );
        }
        if (ms > seconds * 1000) break;
      }
      watch.stop();
      _log(
        '顺序下载结束: 共 ${(received / (1 << 20)).toStringAsFixed(1)}MB / '
        '${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s = '
        '${(received / (watch.elapsedMilliseconds / 1000) / (1 << 20)).toStringAsFixed(2)} MB/s',
      );
    } catch (error) {
      _log('顺序下载失败: $error');
    } finally {
      client.close(force: true);
    }
  }

  static Future<({double mbps, int bytes, double seconds})> _once(
    String url,
    int parallel,
  ) async {
    final client = HttpClient()..maxConnectionsPerHost = parallel + 4;
    final bytes = List<int>.filled(parallel, 0);
    final watch = Stopwatch()..start();
    await Future.wait([
      for (var i = 0; i < parallel; i++) _fetch(client, url, i, bytes),
    ]);
    watch.stop();
    client.close(force: true);

    final total = bytes.fold<int>(0, (a, b) => a + b);
    final seconds = watch.elapsedMilliseconds / 1000;
    return (mbps: total / seconds / (1 << 20), bytes: total, seconds: seconds);
  }

  static Future<void> _fetch(
    HttpClient client,
    String url,
    int index,
    List<int> bytes,
  ) async {
    final start = index * _bytesPerSegment;
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(
      HttpHeaders.rangeHeader,
      'bytes=$start-${start + _bytesPerSegment - 1}',
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

  static void _log(String message) {
    if (kDebugMode) debugPrint('[bench] $message');
  }
}
