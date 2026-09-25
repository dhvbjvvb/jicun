/// 解析探针:把一条分享链接打给反代,按 `ParseResult` 映射出来,再逐项打印。
///
/// 用来回答「这条链接为什么没有视频卡 / 为什么不能下载 / 为什么没弹分辨率」这类问题 ——
/// 页面上看到的是映射之后的模型,直接看接口的原始 JSON 常常对不上号。
///
///     dart run tool/parse_probe.dart https://v.douyin.com/xxxx/
///     dart run tool/parse_probe.dart --raw https://v.douyin.com/xxxx/
///
/// `--raw` 会把接口原样吐出来的 JSON 打出来 —— 接新上游、上游换了字段名的时候,
/// 靠它对着字段改 `parse_service.dart` 里的候选名。
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:jicun/parse_service.dart';

Future<void> main(List<String> args) async {
  final raw = args.contains('--raw');
  final links = args.where((a) => !a.startsWith('--')).toList();
  if (links.isEmpty) {
    stderr.writeln('用法: dart run tool/parse_probe.dart [--raw] <分享链接> [更多链接…]');
    exitCode = 2;
    return;
  }

  for (final link in links) {
    if (args.indexOf(link) > 0) stdout.writeln('');
    stdout.writeln('=== $link ===');
    stdout.writeln(
      '平台识别 ${platformLabel(link).isEmpty ? '(认不出)' : platformLabel(link)}',
    );
    if (raw) {
      await _dumpRaw(link);
    } else {
      await _dumpMapped(link);
    }
  }
}

/// 原样打印两条上游的应答。只用来对着字段名 —— 这里不做任何映射。
Future<void> _dumpRaw(String link) async {
  // 上游是每个平台一条接口,`upstreamPaths` 里存的就是**完整地址**(APP 直连,
  // 不经我们的反代了)。认不出平台就说明这条不走上游。
  final upstream = ParseService.upstreamPaths[detectPlatform(link)];
  final endpoints = <String>[?upstream, ParseService.endpoint];
  for (final endpoint in endpoints) {
    final uri = Uri.parse(endpoint).replace(queryParameters: {'url': link});
    try {
      // 上游那条要带密钥(客户端里那份),media-parser 那条不带 —— 它的密钥由
      // 我们自己的 nginx 注入。
      final isUpstream = endpoint == upstream;
      final response = await http
          .get(
            uri,
            headers: isUpstream
                ? const <String, String>{
                    'X-API-Key': ParseService.upstreamApiKey,
                  }
                : null,
          )
          .timeout(const Duration(seconds: 30));
      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      stdout.writeln('--- $endpoint → HTTP ${response.statusCode} ---');
      stdout.writeln(_pretty(body));
    } catch (error) {
      stdout.writeln('--- $endpoint → 请求失败: $error ---');
    }
  }
}

Future<void> _dumpMapped(String link) async {
  final service = ParseService();
  try {
    final r = await service.parse(link);
    stdout.writeln('走的线路  ${service.lastRoute ?? '(未知)'}');
    stdout.writeln('标题      ${r.title}');
    stdout.writeln('平台      ${r.platform}  作者 ${r.authorName}');
    stdout.writeln('文案      ${r.desc.isEmpty ? '(空)' : '${r.desc.length} 字'}');
    stdout.writeln('');
    stdout.writeln('video_url 字段   ${r.videoUrl ?? '(null)'}');
    stdout.writeln('primaryVideoUrl  ${r.primaryVideoUrl ?? '(null)'}');
    stdout.writeln('cover_url        ${r.coverUrl ?? '(null)'}');
    stdout.writeln('audio_url        ${r.audioUrl ?? '(null)'}');
    stdout.writeln(
      'audioSource      ${r.audioSource ?? '(null)'} '
      '(独立音轨: ${r.hasStandaloneAudio})',
    );
    stdout.writeln('');
    stdout.writeln(
      'hasVideo=${r.hasVideo}  hasImages=${r.hasImages}  '
      'hasCopy=${r.hasCopy}  hasAudio=${r.hasAudio}  '
      'hasMultiVideo=${r.hasMultiVideo}',
    );

    // 分辨率:这是「点下载会不会弹窗」的唯一依据,所以单独打一块 ——
    // 一档都没有时明说,免得把「上游没给」看成「探针没打」。
    final qualities = r.primaryVideo?.qualities ?? const <VideoQuality>[];
    stdout.writeln('');
    stdout.writeln(
      '清晰度 ${qualities.length} 档'
      '(两档以上下载前才弹窗: ${r.primaryVideo?.hasQualityChoice ?? false})',
    );
    if (qualities.isEmpty) stdout.writeln('  (上游没给清晰度列表)');
    for (final q in qualities) {
      stdout.writeln(
        '  ${q.label.isEmpty ? '(未标注)' : q.label}'
        '  ${q.detail.isEmpty ? '' : q.detail}'
        '  ${_short(q.url)}',
      );
    }

    stdout.writeln('');
    stdout.writeln('图集 ${r.imageUrls.length} 张:');
    for (final u in r.imageUrls) {
      stdout.writeln('  ${_short(u)}');
    }
    stdout.writeln('实况 ${r.livePhotos.length} 条:');
    for (final p in r.livePhotos) {
      stdout.writeln('  动态 ${_short(p.videoUrl)}');
      stdout.writeln('  静态 ${_short(p.thumbUrl)}');
    }
    stdout.writeln('媒体卡条目 ${r.videoItems.length} 条(播放/下载用的是第一条):');
    for (final v in r.videoItems) {
      stdout.writeln('  ${_short(v.url)}');
      stdout.writeln('   封面 ${_short(v.coverUrl)}');
      if (v.qualities.isNotEmpty) {
        stdout.writeln(
          '   清晰度 ${v.qualities.map((q) => q.label.isEmpty ? '(未标注)' : q.label).join(' / ')}',
        );
      }
    }
  } on ParseException catch (e) {
    stdout.writeln('解析失败: ${e.message}');
    exitCode = 1;
  } finally {
    service.dispose();
  }
}

String _pretty(String body) {
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(body));
  } catch (_) {
    return body;
  }
}

/// URL 太长,只留主机 + 路径尾段,方便一眼看出「播的到底是哪一条」。
String _short(String? url) {
  if (url == null) return '(null)';
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  final path = uri.path;
  final tail = path.length > 36 ? '…${path.substring(path.length - 36)}' : path;
  return '${uri.host}$tail';
}
