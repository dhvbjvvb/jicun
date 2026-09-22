import 'dart:convert';
import 'dart:io';

import 'package:untitled/api_host.dart';

void main() {
  final body = jsonDecode(
    jsonEncode({
      'updated': '2026-09-17T13:39:16+00:00',
      'hosts': ['videofix.top'],
      'ips': ['173.245.49.168', '104.16.78.124'],
    }),
  );
  stdout.writeln('body type: ${body.runtimeType}');
  stdout.writeln('tryParse: ${InternetAddress.tryParse('173.245.49.168')}');
  stdout.writeln('parsePreferredIpList: ${parsePreferredIpList(body['ips'])}');
  stdout.writeln('parseApiHostList: ${parseApiHostList(body['hosts'])}');
  final config = parseServerConfig(jsonEncode(body));
  stdout.writeln('parseServerConfig hosts=${config.hosts} ips=${config.ips}');
  stdout.writeln('apiUrl: ${apiUrl('/parse')}');
  serverConfigSelfCheck();
  stdout.writeln('selfCheck passed');
}
