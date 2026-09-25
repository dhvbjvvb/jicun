/// 检查更新探针:把反代和直连各打一遍,把 APP 会看到的东西原样打出来。
///
/// 用来回答「为什么 APP 不提示更新 / 为什么更新下不下来」这类问题 —— 页面上只有
/// "已是最新版本"或者一句失败提示,看不到具体是哪个地址、哪个状态码、比出来是几比几。
///
///     dart run tool/update_probe.dart                 # 两条都试(和 APP 一样)
///     dart run tool/update_probe.dart --mirror        # 只试自建反代
///     dart run tool/update_probe.dart --direct        # 只试直连 GitHub
///     dart run tool/update_probe.dart --local 1.0.0   # 顺便按本机版本判一次要不要弹
///
/// 反代那条 404/502 是正常的:nginx 里那段配置没部署时它就还没通,APP 会自动回落
/// 直连(见 lib/update_service.dart 的 kMirrorBase)。
library;

import 'dart:io';

import 'package:jicun/update_service.dart';

Future<void> main(List<String> args) async {
  var which = 'both';
  String? localVersion;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--mirror':
        which = 'mirror';
      case '--direct':
        which = 'direct';
      case '--local':
        if (i + 1 < args.length) localVersion = args[++i];
      default:
        stderr.writeln(
          '用法: dart run tool/update_probe.dart '
          '[--mirror | --direct] [--local 1.0.0]',
        );
        exitCode = 2;
        return;
    }
  }

  final urls = switch (which) {
    'mirror' => <String>[kMirrorReleasesApi],
    'direct' => <String>[kReleasesApi],
    _ => <String>[kMirrorReleasesApi, kReleasesApi],
  };
  final labels = switch (which) {
    'mirror' => <String>['反代'],
    'direct' => <String>['直连'],
    _ => <String>['反代', '直连'],
  };

  final out = stdout;
  out.writeln('仓库      $kRepoOwner/$kRepoName');
  for (var i = 0; i < urls.length; i++) {
    out.writeln('${labels[i]}地址  ${urls[i]}');
  }
  out.writeln('');

  final service = UpdateService();
  try {
    final release = await service.fetchLatest(urls: urls);
    if (release == null) {
      out.writeln('结果:仓库里没有可用的 release(还没发版本,或者 latest 里没挂 .apk)');
      return;
    }
    out.writeln('结果:拿到 v${release.version}');
    out.writeln('  tag        ${release.tag}');
    out.writeln(
      '  发布说明   ${release.notes.length} 字'
      '${release.notes.isEmpty ? '(空)' : ''}',
    );
    if (release.notes.isNotEmpty) {
      // 只打前几行:探针是给终端看的,整篇说明交给 APP 的预览窗口
      final lines = parseMarkdown(release.notes);
      out.writeln('  解析成     ${lines.length} 行 markdown');
      for (final line in lines.take(6)) {
        out.writeln('    | ${line.prefix}${line.text}');
      }
      if (lines.length > 6) out.writeln('    | …还有 ${lines.length - 6} 行');
    }
    out.writeln('  APK        ${release.apkName}');
    out.writeln('  反代下载   ${release.mirrorUrl}');
    out.writeln('  直连下载   ${release.directUrl}');
    if (release.publishedAt != null) {
      out.writeln('  发布时间   ${release.publishedAt!.toLocal()}');
    }
    if (localVersion != null) {
      final newer = isNewerVersion(release.version, localVersion);
      out.writeln('');
      out.writeln(
        '本机 $localVersion vs 仓库 v${release.version} → '
        '${newer ? '会弹「版本更新」卡片' : '不弹(不算新版)'}',
      );
    }
  } on UpdateException catch (e) {
    out.writeln('结果:检查失败');
    out.writeln(e.message);
    exitCode = 1;
  } finally {
    service.dispose();
  }
}
