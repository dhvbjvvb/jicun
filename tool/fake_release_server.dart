/// 联调用的假更新服务:假装自己是 mxper.cc.cd 上的 GitHub 反代。
///
/// 只在真机联调「版本更新」整条链路时用 —— APP 那边用
/// `--dart-define=JICUN_MIRROR=http://127.0.0.1:8080` 指过来,配合
/// `adb reverse tcp:8080 tcp:8080`。
///
///     dart run tool/fake_release_server.dart [端口] [APK路径] [tag]
///
/// 默认:8080 端口、APK 用刚 build 出来的 debug 包、tag 用一个比本机高的版本号,
/// 好让 APP 认为"有新版本"。发布说明故意写长(超过 12 行),顺带验预览窗口的滚动条。
library;

import 'dart:convert';
import 'dart:io';

/// 故意超过 12 行:预览窗口固定 12 行高,超出的部分要能滚。
const String _notes = '''
## 本次更新

**新增**
- 应用内检查更新:启动自动检测,有新版弹「版本更新」卡片
- 说明按 markdown 渲染,预览窗口固定 12 行高
- 底部左边「更新」、右边「忽略」,忽略后不再打扰

**修复**
- 头条动图下载后被命名成静态图后缀的问题
- 下载大文件时进度条偶尔回退

**说明**
1. 点「更新」会在 APP 内下载安装包
2. 下完直接拉起系统安装器覆盖安装
3. 如果系统提示需要「安装未知应用」权限,允许一次即可

> 这条说明故意写长,用来验证预览窗口的滚动条。
''';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 8080;
  final apkPath = args.length > 1
      ? args[1]
      : 'build/app/outputs/flutter-apk/app-debug.apk';
  final tag = args.length > 2 ? args[2] : 'v9.9.9';
  final apkName = 'jicun-${tag.replaceAll('v', '')}.apk';

  final apk = File(apkPath);
  if (!apk.existsSync()) {
    stderr.writeln('APK 不在:$apkPath');
    exitCode = 2;
    return;
  }
  final apkBytes = apk.readAsBytesSync();

  final release = <String, dynamic>{
    'tag_name': tag,
    'name': tag,
    'body': _notes,
    'published_at': DateTime.now().toUtc().toIso8601String(),
    'assets': <dynamic>[
      <String, String>{'name': 'source code (zip)'},
      <String, String>{'name': apkName},
    ],
  };

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('假更新服务已起:http://127.0.0.1:$port');
  stdout.writeln(
    '  GET /releases/latest          → $tag,说明 ${_notes.length} 字',
  );
  stdout.writeln('  GET /dl/$tag/$apkName → ${apkBytes.length} 字节');
  stdout.writeln('');
  stdout.writeln(
    'APP 侧: flutter run --dart-define=JICUN_MIRROR=http://127.0.0.1:$port',
  );
  stdout.writeln('手机上: adb reverse tcp:$port tcp:$port');

  await for (final request in server) {
    final path = request.uri.path;
    stdout.writeln('${request.method} $path');
    if (path == '/releases/latest') {
      final body = utf8.encode(jsonEncode(release));
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType('application', 'json')
        ..headers.contentLength = body.length
        ..add(body);
    } else if (path == '/dl/$tag/$apkName') {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType(
          'application',
          'vnd.android.package-archive',
        )
        ..headers.contentLength = apkBytes.length
        ..add(apkBytes);
    } else {
      request.response
        ..statusCode = 404
        ..write('not found');
    }
    await request.response.close();
  }
}
