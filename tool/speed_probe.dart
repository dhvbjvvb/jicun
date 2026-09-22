// 一次性诊断脚本:量「大文件单连接」和「按 Range 分段并行」的真实差距。
// 用完就删,不进 App 逻辑。
import 'dart:convert';
import 'dart:io';

import 'package:untitled/downloader.dart';

Future<void> main(List<String> args) async {
  const share = 'https://v.douyin.com/iGYPHTC5mTQ/';
  final client = HttpClient();
  final res = await (await client.getUrl(
    Uri.parse('https://mxper.cc.cd/parse')
        .replace(queryParameters: {'url': share}),
  )).close();
  final data =
      (jsonDecode(await res.transform(utf8.decoder).join()) as Map)['data']
          as Map<String, dynamic>;
  // 挑最大的那张实况图,好看出差距
  final urls = <String>[
    for (final item in (data['image_list'] as List))
      if (item is Map && item['live_photo_url'] != null)
        item['live_photo_url'] as String,
  ].take(12).toList();
  client.close();

  final temp = await Directory.systemTemp.createTemp('jicun_speed');
  // 真 CDN 上找不到 8MB 的一条,把阈值压到 512KB 才走得分段
  Downloader.segmentedFromBytes = 512 * 1024;
  Downloader.segmentBytes = 256 * 1024;
  Downloader.maxSegments = 8;

  var singleBytes = 0;
  final single = Stopwatch()..start();
  for (final url in urls) {
    final http = HttpClient();
    final f = await Downloader.fetchImpl(
      DownloadItem(url: url, fileName: 'a.mp4', kind: MediaKind.video),
      temp,
      (_) {},
      null,
      (_) {},
      http,
    );
    singleBytes += f.lengthSync();
    http.close(force: true);
  }
  single.stop();

  // 分段那条:临时把阈值/段数调回单连接,好做对照
  final saved = [
    Downloader.segmentedFromBytes,
    Downloader.segmentBytes,
    Downloader.maxSegments,
  ];
  Downloader.segmentedFromBytes = 1 << 30;
  var plainBytes = 0;
  final plain = Stopwatch()..start();
  for (final url in urls) {
    final http = HttpClient();
    final f = await Downloader.fetchImpl(
      DownloadItem(url: url, fileName: 'b.mp4', kind: MediaKind.video),
      temp,
      (_) {},
      null,
      (_) {},
      http,
    );
    plainBytes += f.lengthSync();
    http.close(force: true);
  }
  plain.stop();
  Downloader.segmentedFromBytes = saved[0];
  Downloader.segmentBytes = saved[1];
  Downloader.maxSegments = saved[2];

  stdout.writeln('${urls.length} 条实况图,共 $singleBytes 字节');
  stdout.writeln(
    '单连接 : ${plain.elapsedMilliseconds} ms '
    '(${(plainBytes / 1024 / (plain.elapsedMilliseconds / 1000)).toStringAsFixed(0)} KB/s)',
  );
  stdout.writeln(
    '分段并行: ${single.elapsedMilliseconds} ms '
    '(${(singleBytes / 1024 / (single.elapsedMilliseconds / 1000)).toStringAsFixed(0)} KB/s)',
  );
  temp.deleteSync(recursive: true);
}
