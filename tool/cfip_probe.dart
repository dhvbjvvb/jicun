// 一次性诊断脚本:量优选 IP 相对系统 DNS 的真实差距,并确认 connectionFactory
// 这条路上 TLS 包对了(证书按域名校验,不是拿 IP 去比)。
//
// 用法:dart run tool/cfip_probe.dart
// 用完就删,不进 App 逻辑。
import 'dart:io';

import 'package:jicun/api_host.dart';
import 'package:jicun/preferred_ip.dart';

Future<void> main() async {
  // 先走一遍生产路径的「拉配置」:桌面没有 SharedPreferences(缓存那步在 main.dart
  // 里),所以这里直接取网络结果塞进连接器 —— 正好验证拉取、域名切换和校验这段。
  final updater = PreferredIpUpdater();
  final config = await updater.fetch();
  PreferredIpConnector.remote = config.ips;
  PreferredIpConnector.remoteHosts = config.hosts;
  stdout.writeln('服务端下发的域名: ${config.hosts}');
  stdout.writeln('服务端下发的列表: ${config.ips}');
  stdout.writeln('答上来的域名: ${updater.lastHost} / 当前域名: $apiHost');

  final connector = PreferredIpConnector();
  final client = HttpClient()..connectionFactory = connector.connect;

  for (var i = 1; i <= 3; i++) {
    final watch = Stopwatch()..start();
    try {
      final request = await client.getUrl(Uri.parse(apiUrl('/ping')));
      final response = await request.close();
      await response.drain<void>();
      watch.stop();
      stdout.writeln(
        '第 $i 次: ${response.statusCode} ${watch.elapsedMilliseconds} ms '
        '(用的地址: ${connector.winner})',
      );
    } catch (e) {
      watch.stop();
      stdout.writeln('第 $i 次:失败 $e');
    }
  }

  client.close(force: true);
}
