import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jicun/parse_service.dart';

/// 拿上游真实应答做回归。
///
/// 样本由 `_audit/sweep.ps1` 用各平台代表性链接打 `https://mxper.cc.cd/parse`
/// 抓回来(samples 取自上游自带的 300+ 条真实样本库),原样存进
/// `test/fixtures/upstream_samples.json`。
///
/// 这里断言的是**我们的分类规则在真实数据上不变量成立** —— 卡片的取舍
/// (媒体/图集/混合/音频/文案)全由这些字段决定,破了任何一条,
/// 用户看到的就是「明明单视频却进了混合卡」或「文案里一堆 (yn)」。
void main() {
  final raw = File('test/fixtures/upstream_samples.json').readAsStringSync();
  final cases = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();

  /// 资源标识:与 ParseResult 内部的判据一致 —— 只看路径。
  String identity(String url) {
    final uri = Uri.tryParse(url);
    return uri == null || uri.path.isEmpty ? url : uri.path;
  }

  test('样本库不为空(至少覆盖抖音/快手/微博/得物这些大平台)', () {
    expect(cases.length, greaterThanOrEqualTo(20));
    final platforms = cases.map((c) => c['platform']).toSet();
    for (final p in ['抖音', '快手', '微博', '得物', 'QQ音乐']) {
      expect(platforms, contains(p));
    }
  });

  test('每个平台的真实应答都不再触犯这些规则', () {
    for (final c in cases) {
      final platform = c['platform'] as String;
      final data = (c['data'] as Map).cast<String, dynamic>();
      final r = ParseResult.fromJson(data);

      // 1. 图集内部不能有同一个资源出现两次
      final imageIds = r.imageUrls.map(identity).toList();
      expect(
        imageIds.toSet().length,
        imageIds.length,
        reason: '$platform:图集里有重复资源',
      );

      // 2. 有真视频时,图集里不该再出现"视频封面"那张。
      //    判据只看 video_url / video_list:实况图不算「有视频」(见 ParseResult._cleanImages)——
      //    实况帖的封面往往就是图集第一张真图,拿它当视频封面剔掉会平白少一张。
      if (r.videoUrl != null || r.videos.isNotEmpty) {
        final cover = identity(r.coverUrl ?? '');
        expect(
          imageIds.contains(cover),
          isFalse,
          reason: '$platform:图集里混进了视频封面',
        );
      }

      // 3. 视频条目不能重复(上游会把主视频也塞进 video_list)
      final videoIds = r.videoItems.map((v) => identity(v.url)).toList();
      expect(
        videoIds.toSet().length,
        videoIds.length,
        reason: '$platform:视频条目重复',
      );

      // 4. 文案里不该留字面 \n、平台标记、占位文案
      for (final (name, text) in [('desc', r.desc), ('title', r.title)]) {
        expect(
          text.contains(r'\n'),
          isFalse,
          reason: '$platform:$name 里还有字面 \\n',
        );
        expect(
          RegExp(r'[（(]\s*yn\s*[)）]', caseSensitive: false).hasMatch(text),
          isFalse,
          reason: '$platform:$name 里还有 (yn)',
        );
        expect(text.contains('\r'), isFalse, reason: '$platform:$name 里还有 \\r');
        expect(
          const {'视频加载中...', '视频加载中', '分享视频', '网页链接'}.contains(text),
          isFalse,
          reason: '$platform:$name 是平台占位文案',
        );
        expect(
          text.startsWith('\n') || text.endsWith('\n'),
          isFalse,
          reason: '$platform:$name 首尾还有空行',
        );
      }
    }
  });

  test('有内容的应答至少能撑起一张卡', () {
    for (final c in cases) {
      final platform = c['platform'] as String;
      final r = ParseResult.fromJson(
        (c['data'] as Map).cast<String, dynamic>(),
      );
      final hasAnyCard =
          r.hasVideo || r.hasImages || r.hasPlayableAudio || r.hasCopy;
      expect(hasAnyCard, isTrue, reason: '$platform:一张卡都出不来');
    }
  });
}
