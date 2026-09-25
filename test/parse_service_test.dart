import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jicun/api_host.dart';
import 'package:jicun/downloader.dart';
import 'package:jicun/parse_service.dart';

void main() {
  group('ParseResult.fromJson', () {
    test('取到标题、作者、视频、封面、音频', () {
      final result = ParseResult.fromJson({
        'title': '视频标题',
        'desc': '文案',
        'platform': '抖音',
        'author': {'nickname': '某人', 'author_id': '1'},
        'video_url': 'https://cdn.example/v.mp4',
        'cover_url': 'https://cdn.example/c.jpg',
        'audio_url': 'https://cdn.example/a.mp3',
      });

      expect(result.title, '视频标题');
      expect(result.platform, '抖音');
      expect(result.authorName, '某人');
      expect(result.hasVideo, isTrue);
      expect(result.hasAudio, isTrue);
      expect(result.coverUrl, 'https://cdn.example/c.jpg');
      // 文案只取描述 —— 标题和作者不上文案卡,复制时也不带
      expect(result.copyText, '文案');
      expect(result.hasCopy, isTrue);
    });

    // 实况帖:接口不给 video_url,视频只在 image_list[].live_photo_url 里。
    // 实测 https://v.douyin.com/87q9bOkq0bs/ 就是这样 —— 播放器和下载早先
    // 直接读 video_url 字段,拿到 null,表现是「有封面、点不动、没有时长、下不了」。
    test('实况帖没有 video_url 时,主视频取实况里的 MP4', () {
      final result = ParseResult.fromJson({
        'title': '神的睡觉方式',
        'desc': '神的睡觉方式',
        'platform': '抖音',
        'video_url': null,
        'cover_url': 'https://cdn.example/cover.jpg',
        'audio_url': 'https://cdn.example/a.mp3',
        'image_list': [
          {
            'url': 'https://cdn.example/live.jpg',
            'live_photo_url': 'https://cdn.example/live.mp4',
          },
        ],
      });

      expect(result.hasVideo, isTrue);
      expect(result.hasMultiVideo, isFalse);
      // 播放器和「单条下载」都只认这一个入口
      expect(result.primaryVideoUrl, 'https://cdn.example/live.mp4');
      // 封面用实况图自己的静态帧,不是接口那个 cover_url
      expect(result.primaryVideoCoverUrl, 'https://cdn.example/live.jpg');
      expect(result.audioSource, 'https://cdn.example/a.mp3');
    });

    // 只有一条 video_list、没有 video_url 的链接同理:主视频得能取到。
    test('只有一条 video_list 时,主视频取那一条', () {
      final result = ParseResult.fromJson({
        'title': '单条合集',
        'platform': '抖音',
        'video_url': null,
        'video_list': [
          {
            'url': 'https://cdn.example/one.mp4',
            'cover_url': 'https://cdn.example/one.jpg',
          },
        ],
      });

      expect(result.primaryVideoUrl, 'https://cdn.example/one.mp4');
      expect(result.primaryVideoCoverUrl, 'https://cdn.example/one.jpg');
      // 没有 audio_url 时按老规矩退回 `video_url` 字段(这里是 null)—— 只有
      // video_list 的链接不该凭空多出一张音频卡,那条边界由 widget 测试守着。
      expect(result.audioSource, isNull);
    });

    test('字段缺失或类型不符时退化成空,不抛异常', () {
      // 上游是第三方解析站,字段类型没人保证。这条就是防它抽风。
      final result = ParseResult.fromJson({
        'title': 42,
        'author': 'not-a-map',
        'video_url': null,
        'desc': '  只有文案  ',
      });

      expect(result.title, '');
      expect(result.authorName, '');
      expect(result.videoUrl, isNull);
      expect(result.hasVideo, isFalse);
      expect(result.desc, '只有文案');
      expect(result.copyText, '只有文案');
    });

    test('描述为空就没有文案,哪怕标题有内容', () {
      // 文案卡只放描述;没有描述这张卡整张都不该出现。
      final result = ParseResult.fromJson({'title': '只有标题'});
      expect(result.hasCopy, isFalse);
      expect(result.copyText, '');

      // 接口对图集之类会用正文兜底填 title,所以 title 有值不代表有文案。
      expect(ParseResult.fromJson(const {}).hasCopy, isFalse);
    });

    test('快手纯视频:image_list 里那两条封面不算图集,卡片不该走混合', () {
      // 真机实测应答:纯视频链接,image_list = [封面, 封面](两条一模一样)。
      // 照单全收就会判成「又有视频又有图」,卡片变混合预览,两格还是同一张封面。
      final result = ParseResult.fromJson({
        'title': '标题',
        'desc': '文案',
        'platform': '快手',
        'video_url': 'https://cdn.example/v.mp4',
        'cover_url': 'https://cdn.example/c.jpg',
        'image_list': <dynamic>[
          'https://cdn.example/c.jpg',
          'https://cdn.example/c.jpg',
        ],
      });

      expect(result.imageUrls, isEmpty);
      expect(result.hasImages, isFalse);
      expect(result.videoItems, hasLength(1));
    });

    test('有视频时,与封面同址的图剔掉,真图留着', () {
      final result = ParseResult.fromJson({
        'video_url': 'https://cdn.example/v.mp4',
        'cover_url': 'https://cdn.example/c.jpg',
        'image_list': <dynamic>[
          'https://cdn.example/c.jpg',
          'https://cdn.example/1.jpg',
        ],
      });

      expect(result.imageUrls, ['https://cdn.example/1.jpg']);
    });

    test('纯图集不剔封面:图集的封面本来就是第一张图', () {
      final result = ParseResult.fromJson({
        'cover_url': 'https://cdn.example/1.jpg',
        'image_list': <dynamic>[
          'https://cdn.example/1.jpg',
          'https://cdn.example/2.jpg',
        ],
      });

      expect(result.imageUrls, [
        'https://cdn.example/1.jpg',
        'https://cdn.example/2.jpg',
      ]);
      expect(result.hasImages, isTrue);
    });

    test('图集里重复的地址只留一条', () {
      final result = ParseResult.fromJson({
        'image_list': <dynamic>[
          'https://cdn.example/1.jpg',
          'https://cdn.example/1.jpg',
        ],
      });

      expect(result.imageUrls, ['https://cdn.example/1.jpg']);
    });

    test('有视频时,封面换个 host/签名也算同一张,同样剔掉', () {
      // 得物实测:封面在 image-cdn.dewu.com,image_list 里那条在
      // image-cdn.poizon.com,路径一模一样、字节数也一样。
      final result = ParseResult.fromJson({
        'video_url': 'https://v.example/v.mp4',
        'cover_url':
            'https://image-cdn.dewu.com/app/2026/community/abc_w714_h952.webp',
        'image_list': <dynamic>[
          'https://image-cdn.poizon.com/app/2026/community/abc_w714_h952.webp',
        ],
      });

      expect(result.imageUrls, isEmpty);
      expect(result.hasImages, isFalse);
    });

    test('合集里 video_list 把主视频又放了一遍,不重复列出来', () {
      // 接口文档:video_list「首项与 video_url 相同」;QQ 音乐实测两条整串一致。
      final result = ParseResult.fromJson({
        'video_url': 'https://cdn.example/1.mp4?sign=abc',
        'video_list': <dynamic>[
          {'url': 'https://cdn.example/1.mp4?sign=abc'},
          {'url': 'https://cdn.example/2.mp4'},
        ],
      });

      expect(result.videoItems.map((v) => v.url), [
        'https://cdn.example/1.mp4?sign=abc',
        'https://cdn.example/2.mp4',
      ]);
      expect(result.hasMultiVideo, isTrue);
    });

    test('video_list 内部重复的条目也去重', () {
      final result = ParseResult.fromJson({
        'video_list': <dynamic>[
          'https://cdn.example/1.mp4?a=1',
          'https://cdn.example/1.mp4?a=2',
          'https://cdn.example/2.mp4',
        ],
      });

      // 同一条视频换个签名出现两次,只留一条;剩下两条不同的仍然是多视频
      expect(result.videoItems.map((v) => v.url), [
        'https://cdn.example/1.mp4?a=1',
        'https://cdn.example/2.mp4',
      ]);
      expect(result.hasMultiVideo, isTrue);
    });

    test('占位文案当成没有文案:今日头条的「视频加载中...」', () {
      final result = ParseResult.fromJson({
        'title': '中东局势暗流涌动',
        'desc': '视频加载中...',
      });

      expect(result.desc, isEmpty);
      expect(result.hasCopy, isFalse);
    });

    test('文案清洗:去掉「(yn)」、还原双重转义的 \\n、压掉空行', () {
      // 上游把换行转义了两次:字符串里是两个字符(反斜杠 + n)
      final result = ParseResult.fromJson({
        'desc': '#媒体原创\\n云南一名00后女孩创业。（yn）\\n\\n#国红山泉 #农夫山泉',
      });

      expect(result.copyText, '#媒体原创\n云南一名00后女孩创业。\n#国红山泉 #农夫山泉');
      expect(result.title, isEmpty);
    });

    test('文案清洗:真换行保留,标题也一起清', () {
      final result = ParseResult.fromJson({
        'title': '标题（yn）',
        'desc': '第一行  \n\n\n第二行',
      });

      expect(result.title, '标题');
      expect(result.copyText, '第一行\n第二行');
    });

    test('音频音源优先用 audio_url,接口没给才退回视频', () {
      // audio_url 是一份独立的完整音频文件 —— 实测这条抖音链接:视频 360MB /
      // 标称 1.6Mbps ≈ 30.7 分钟,音频 27.5MB 的 mp3 ≈ 28.7 分钟,对得上。
      // 所以有 audio_url 就用它,不该拿视频去顶。
      final both = ParseResult.fromJson({
        'video_url': 'https://cdn.example/v.mp4',
        'audio_url': 'https://cdn.example/a.mp3',
      });
      expect(both.audioSource, 'https://cdn.example/a.mp3');
      expect(both.hasStandaloneAudio, isTrue);
      expect(both.hasPlayableAudio, isTrue);

      // 接口没给 audio_url 时退回视频:视频自带音轨,一样能听
      final videoOnly = ParseResult.fromJson({
        'video_url': 'https://cdn.example/v.mp4',
      });
      expect(videoOnly.audioSource, 'https://cdn.example/v.mp4');
      expect(videoOnly.hasStandaloneAudio, isFalse);
      expect(videoOnly.hasPlayableAudio, isTrue);

      // 纯音频链接
      final audioOnly = ParseResult.fromJson({
        'audio_url': 'https://cdn.example/a.mp3',
      });
      expect(audioOnly.audioSource, 'https://cdn.example/a.mp3');
      expect(audioOnly.hasStandaloneAudio, isTrue);

      expect(ParseResult.fromJson(const {}).audioSource, isNull);
      expect(ParseResult.fromJson(const {}).hasPlayableAudio, isFalse);
    });

    test('图集:字符串和对象两种元素都收,脏元素跳过', () {
      // 上游 image_list 的元素既可能是地址字符串,也可能是 {url: ...} /
      // {live_photo_url: ...} 的对象,顺序就是平台里看到的顺序。
      final result = ParseResult.fromJson({
        'image_list': [
          'https://cdn.example/1.jpeg',
          {'url': 'https://cdn.example/2.webp'},
          {'live_photo_url': 'https://cdn.example/3.jpg'},
          {'url': '   '},
          42,
          null,
        ],
      });

      expect(result.hasImages, isTrue);
      expect(result.imageUrls, [
        'https://cdn.example/1.jpeg',
        'https://cdn.example/2.webp',
      ]);
      // 带 live_photo_url 的那条是实况图:下载地址是 MP4,归视频,不进图集
      expect(result.livePhotos.length, 1);
      expect(result.livePhotos.single.videoUrl, 'https://cdn.example/3.jpg');
      expect(result.livePhotos.single.thumbUrl, isNull);
    });

    test('实况图:静态图当缩略图,MP4 归视频,从图集里剔除', () {
      final result = ParseResult.fromJson({
        'image_list': [
          {
            'url': 'https://cdn.example/live1.jpg',
            'live_photo_url': 'https://cdn.example/live1.mp4',
          },
          {
            'url': 'https://cdn.example/live2.jpg',
            'live_photo_url': 'https://cdn.example/live2.mp4',
          },
        ],
      });

      // 只有实况图:图集卡不该出现(hasImages 为假)
      expect(result.hasImages, isFalse);
      expect(result.imageUrls, isEmpty);
      expect(result.livePhotos.length, 2);
      expect(result.hasMultiVideo, isTrue);

      // 媒体卡列的是两条视频,缩略图用各自那张静态图
      expect(result.videoItems.length, 2);
      expect(result.videoItems.first.url, 'https://cdn.example/live1.mp4');
      expect(result.videoItems.first.coverUrl, 'https://cdn.example/live1.jpg');
      expect(result.videoItems[1].url, 'https://cdn.example/live2.mp4');
      expect(result.videoItems[1].coverUrl, 'https://cdn.example/live2.jpg');

      // 存历史再读回来:实况图不能丢,也不能变成图片
      final back = ParseResult.fromJson(result.toJson());
      expect(back.livePhotos.length, 2);
      expect(back.imageUrls, isEmpty);
      expect(back.videoItems[1].coverUrl, 'https://cdn.example/live2.jpg');
    });

    test('最右实况帖:封面就是图集第一张,别把它当视频封面剔掉', () {
      // 实测 pid=425444752:2 张静态图 + 7 张实况,cover_url 取的正是第一张静态图
      // (只是签名不同)。实况图的静态帧在 image_list 里是对象,不在 images 里,
      // 所以这里"封面同址"的那张是真图,剔掉等于少给用户一张。
      final result = ParseResult.fromJson({
        'platform': '最右',
        'title': '苦逼日子',
        'video_url': '',
        'cover_url':
            'https://web-f01.izuiyou.com/img/view/id/2546162437/sz/src?a=1',
        'image_list': [
          'https://web-f01.izuiyou.com/img/view/id/2546162437/sz/src?a=2',
          {
            'url':
                'https://web-f01.izuiyou.com/img/view/id/2546162444/sz/540?a=3',
            'live_photo_url':
                'https://web-v01.izuiyou.com/zyvqwz/264/f7/e8/1104-ab43.mp4',
          },
          'https://web-f01.izuiyou.com/img/view/id/2546162445/sz/src?a=4',
        ],
      });

      // 两张静态图都要留着
      expect(result.imageUrls, [
        'https://web-f01.izuiyou.com/img/view/id/2546162437/sz/src?a=2',
        'https://web-f01.izuiyou.com/img/view/id/2546162445/sz/src?a=4',
      ]);
      // 实况图归视频,缩略图用自己那张静态帧
      expect(result.videoUrl, isNull);
      expect(result.livePhotos.length, 1);
      expect(result.videoItems.length, 1);
      expect(result.videoItems.single.coverUrl, contains('2546162444'));
      // 图集卡和媒体卡都要出
      expect(result.hasImages, isTrue);
      expect(result.hasVideo, isTrue);
    });

    test('没有 image_list 或类型不对时是空图集,而不是抛异常', () {
      expect(ParseResult.fromJson(const {}).imageUrls, isEmpty);
      expect(
        ParseResult.fromJson(const {'image_list': '不是列表'}).hasImages,
        isFalse,
      );
    });

    test('视频合集:video_list 的元素两种写法都收,脏元素跳过', () {
      // 普通单条链接只有 video_url,没有 video_list —— 那种 case 不算多视频。
      final single = ParseResult.fromJson({
        'video_url': 'https://cdn.example/v.mp4',
        'cover_url': 'https://cdn.example/c.jpg',
      });
      expect(single.hasMultiVideo, isFalse);
      expect(single.videoItems.single.url, 'https://cdn.example/v.mp4');
      expect(single.videoItems.single.coverUrl, 'https://cdn.example/c.jpg');

      // 合集:元素可能是字符串,也可能是对象;地址字段各家叫法不一。
      final collection = ParseResult.fromJson({
        'video_list': [
          'https://cdn.example/1.mp4',
          {
            'url': 'https://cdn.example/2.mp4',
            'cover_url': 'https://cdn.example/2.jpg',
          },
          {
            'play_url': 'https://cdn.example/3.mp4',
            'cover': 'https://cdn.example/3.jpg',
          },
          {'video_url': 'https://cdn.example/4.mp4'},
          {'cover_url': 'https://cdn.example/no-url.jpg'},
          42,
        ],
      });
      expect(collection.hasVideo, isTrue);
      expect(collection.hasMultiVideo, isTrue);
      expect(collection.videoItems.length, 4);
      expect(collection.videoItems.first.coverUrl, isNull);
      expect(collection.videoItems[1].coverUrl, 'https://cdn.example/2.jpg');
      expect(collection.videoItems[2].url, 'https://cdn.example/3.mp4');
      expect(collection.videoItems[2].coverUrl, 'https://cdn.example/3.jpg');

      // 存历史再读回来,合集不能丢
      final back = ParseResult.fromJson(collection.toJson());
      expect(back.videoItems.map((v) => v.url), [
        'https://cdn.example/1.mp4',
        'https://cdn.example/2.mp4',
        'https://cdn.example/3.mp4',
        'https://cdn.example/4.mp4',
      ]);
      expect(back.hasMultiVideo, isTrue);
    });

    test('描述和标题相同时不重复拼接', () {
      final result = ParseResult.fromJson({'title': '同一句话', 'desc': '同一句话'});
      expect(result.copyText, '同一句话');
    });
  });

  group('ParseService', () {
    ParseService serviceReturning(String body, {int status = 200}) =>
        ParseService(
          client: MockClient(
            (_) async => http.Response.bytes(
              utf8.encode(body),
              status,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );

    test('兜底接口使用 /parse 的 GET,不回退到 /api/v1/parse', () async {
      // 域名取自全局 apiHost —— 服务端可以下发新域名,所以这里不断言具体域名,
      // 只断言路径没变。
      expect(Uri.parse(ParseService.endpoint).path, '/parse');
      expect(Uri.parse(ParseService.endpoint).host, apiHost);
      final requests = <http.BaseRequest>[];
      final service = ParseService(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'succ': true,
                'retcode': 200,
                'data': {
                  'title': '接口测试',
                  'video_url': 'https://cdn.example/v.mp4',
                },
              }),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await service.parse('https://example.com/share/123');

      expect(requests, hasLength(1));
      expect(requests.single.method, 'GET');
      expect(requests.single.url.path, '/parse');
      expect(
        requests.single.url.queryParameters['url'],
        'https://example.com/share/123',
      );
    });

    test('预热只打一次,而且打的是 /ping', () async {
      final paths = <String>[];
      final service = ParseService(
        client: MockClient((request) async {
          paths.add(request.url.path);
          return http.Response('', 204);
        }),
      );

      service.warmUp();
      service.warmUp();
      await Future<void>.delayed(Duration.zero);

      expect(paths, ['/ping']);
    });

    test('预热失败不抛异常', () async {
      final service = ParseService(
        client: MockClient((_) async => throw http.ClientException('boom')),
      );

      service.warmUp();
      await Future<void>.delayed(Duration.zero);
    });

    test('成功时解析出结果,中文不乱码', () async {
      final result = await serviceReturning(
        jsonEncode({
          'succ': true,
          'retcode': 200,
          'data': {'title': '中文标题', 'video_url': 'https://cdn.example/v.mp4'},
        }),
      ).parse('https://v.douyin.com/xxx/');

      expect(result.title, '中文标题');
      expect(result.hasVideo, isTrue);
    });

    test('上游解析失败用的是 HTTP 400 + retdesc,要把 retdesc 原样抛给用户', () async {
      // 这是线上真实返回(拿一条已删除的抖音链接打出来的):
      //   {"retcode":400,"retdesc":"因版权限制或已被删除,无法观看,去看看其他作品吧",
      //    "succ":false,"data":null,"error_code":"MEDIA_DELETED_OR_PRIVATE"}
      // 不能因为状态码是 400 就丢掉 retdesc。
      final service = serviceReturning(
        jsonEncode({
          'retcode': 400,
          'retdesc': '因版权限制或已被删除,无法观看,去看看其他作品吧',
          'succ': false,
          'data': null,
          'error_code': 'MEDIA_DELETED_OR_PRIVATE',
        }),
        status: 400,
      );

      await expectLater(
        service.parse('x'),
        throwsA(
          isA<ParseException>().having(
            (e) => e.message,
            'message',
            '因版权限制或已被删除,无法观看,去看看其他作品吧',
          ),
        ),
      );
    });

    test('200 但 succ 为假时,同样用 retdesc', () async {
      final service = serviceReturning(
        jsonEncode({
          'succ': false,
          'retcode': 400,
          'retdesc': '该链接尚未支持提取 / 解析失败',
          'data': null,
        }),
      );

      await expectLater(
        service.parse('x'),
        throwsA(
          isA<ParseException>().having(
            (e) => e.message,
            'message',
            '该链接尚未支持提取 / 解析失败',
          ),
        ),
      );
    });

    test('429 换成看得懂的话', () async {
      final service = serviceReturning('{}', status: 429);

      await expectLater(
        service.parse('x'),
        throwsA(
          isA<ParseException>().having(
            (e) => e.message,
            'message',
            '请求太频繁,请稍后再试',
          ),
        ),
      );
    });

    test('返回的不是 JSON 时给一句人话,而不是抛 FormatException', () async {
      final service = serviceReturning('<html>502 Bad Gateway</html>');

      await expectLater(
        service.parse('x'),
        throwsA(
          isA<ParseException>().having((e) => e.message, 'message', '返回内容无法识别'),
        ),
      );
    });
  });

  group('safeFileName', () {
    test('清掉路径分隔符和非法字符,保留中文', () {
      expect(safeFileName('a/b\\c:d*e?f"g<h>i|j'), 'a_b_c_d_e_f_g_h_i_j');
      expect(safeFileName('  微信视频  '), '微信视频');
    });

    test('空标题退回兜底名', () {
      expect(safeFileName('   '), '即存媒体');
    });

    test('短标题原样保留', () {
      expect(safeFileName('挪威冬日'), '挪威冬日');
      expect(safeFileName('  微信视频  '), '微信视频');
    });

    test('按字节截断,不会把 .mp4 顶掉', () {
      // 60 个汉字 = 180 字节。DownloadManager 限的是字节,从尾部截断会把
      // 扩展名切掉(线上实测过),所以这里必须按字节收口。
      final long = safeFileName('极' * 60);
      expect(utf8.encode(long).length, lessThanOrEqualTo(66));
      expect(long.length, greaterThan(15)); // 别缩得太狠

      // 截断处不能留下半个 UTF-8 字符变成的乱码方块
      expect(long.contains('\uFFFD'), isFalse);
    });

    test('ASCII 长标题按字节截断', () {
      // 后缀和序号也得算进 66 上限里:解析期是在这个返回值后面再拼 `.mp4` 和 `_2`
      // 的,不先扣掉的话总量会超(线上实测 81 字节就被系统砍掉过扩展名)。
      expect(utf8.encode(safeFileName('x' * 200, ext: '.mp4')).length, 62);
      // `.jpeg` 按 5 字节封顶扣(见 safeFileName),所以是 66 - 5 - 2 = 59
      expect(
        utf8.encode(safeFileName('x' * 200, ext: '.jpeg', index: 2)).length,
        61,
      );
      // 上限算的是"标题 + 后缀 + 序号",不是标题自己
      expect(
        utf8
                .encode(safeFileName('x' * 200, ext: '.mp4', index: 2))
                .length +
            4 +
            2,
        68,
      );
    });
  });

  group('shortenTitle / safeFileName 让标题变短', () {
    test('剥掉话题标签', () {
      expect(shortenTitle('挪威冬日高画 #旅行 #vlog'), '挪威冬日高画');
      // 标签在中间:只换掉标签本身,前后的字留着
      expect(shortenTitle('原神#蒙德 风景'), '原神 风景');
    });

    test('整个标题都是标签时不清,免得变成空名字', () {
      // 清完是空串,那就退回原名 —— 至少还看得出是哪个话题
      expect(shortenTitle('#冬日#旅行'), '');
      expect(safeFileName('#冬日#旅行'), '#冬日#旅行');
      expect(safeFileName('#冬日 #旅行'), '#冬日 #旅行');
    });

    test('清掉 emoji', () {
      expect(shortenTitle('挪威冬日 🎬🔥'), '挪威冬日');
      // 变体选择符(⚠️ 的那个)也不能留下
      expect(shortenTitle('警告⚠️ 结冰'), '警告 结冰');
    });

    test('收掉重复的标点', () {
      expect(shortenTitle('太好看了!!!'), '太好看了!');
      // 两个不算连打:用户真打出来的语气别动
      expect(shortenTitle('太好了!!'), '太好了!!');
    });

    test('整个标题都是 emoji 时不清,免得变成空名字', () {
      expect(safeFileName('🎬🔥'), '🎬🔥');
    });

    test('标签和 emoji 一起拿掉后不留一长串下划线', () {
      final name = safeFileName('原神#蒙德#璃月🎬 风景');
      expect(name, '原神 风景');
      expect(name.contains('__'), isFalse);
    });
  });

  group('extractShareUrl', () {
    test('从整段分享文本里挑出链接', () {
      // 这是抖音复制出来的真实样子
      expect(
        extractShareUrl(
          '7.62 复制打开抖音,看看【某某的作品】'
          'https://v.douyin.com/MM-UwrwuwWU/ 复制此链接,打开Dou音搜索',
        ),
        'https://v.douyin.com/MM-UwrwuwWU/',
      );
    });

    test('链接后面没有空格、直接粘中文,也能截断', () {
      expect(
        extractShareUrl('看这个 https://v.douyin.com/abc/复制此链接'),
        'https://v.douyin.com/abc/',
      );
    });

    test('削掉尾部粘上的中英文标点', () {
      expect(extractShareUrl('链接:https://b23.tv/abcd。'), 'https://b23.tv/abcd');
      expect(extractShareUrl('(https://b23.tv/abcd)'), 'https://b23.tv/abcd');
    });

    test('干净的链接原样返回', () {
      const url = 'https://v.douyin.com/MM-UwrwuwWU/';
      expect(extractShareUrl(url), url);
      expect(extractShareUrl('  $url  '), url);
    });

    test('没有链接时返回 null,而不是返回半截东西', () {
      expect(extractShareUrl('这是一段没有链接的文字'), isNull);
      expect(extractShareUrl(''), isNull);
      // 只有 scheme 没有主机名的残片不算链接
      expect(extractShareUrl('https://'), isNull);
    });

    test('取第一个链接', () {
      expect(
        extractShareUrl(
          'https://v.douyin.com/first/ 和 https://v.douyin.com/second/',
        ),
        'https://v.douyin.com/first/',
      );
    });
  });
}
