// 第二个解析上游(BugPk)的接入测试。
//
// 三件事各验一段:
//   1. 路由:抖音/快手/微信视频号先走上游,失败才回落到 media-parser;
//      其他平台一次都不碰上游。
//   2. 分辨率:同一档分辨率只留码率最高的一条。
//   3. 下载:只有「上游给的、且有多档」的视频才弹分辨率选择窗;
//      media-parser 的结果直接下,一次点击都不多。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:untitled/api_host.dart';
import 'package:untitled/downloader.dart';
import 'package:untitled/main.dart';
import 'package:untitled/parse_service.dart';

import 'fixtures/upstream_real_responses.dart';

/// 第二个上游的应答:同一条视频两档分辨率,1080P 故意给两个码率。
///
/// 1080P 那两条是这次去重规则的靶子:高的(4000000 / 30MB)必须留下,
/// 低的那条(2000000)必须消失。
/// 上游(BugPk)的应答结构,按实测那条抖音链接抄的(字段名逐个对应)。
///
/// `video_backup` 里故意放三个 1080P(码率不同)+ 一个 720P —— 去重的靶子。
/// `url` 是主地址(最高档),`label` 是它的档位名。
Map<String, dynamic> _upstreamVideoData({
  String videoUrl = 'https://example.invalid/v.mp4',
}) => <String, dynamic>{
  'type': 'video',
  'title': '上游视频',
  'desc': '文案',
  'author': <String, dynamic>{'name': '上游作者', 'id': '1', 'avatar': ''},
  'cover': 'https://example.invalid/c.jpg',
  'url': videoUrl,
  'label': '原画',
  'quality': 'original',
  'size': 700000000,
  'bit_rate': 34000000,
  'width': 7680,
  'height': 3210,
  'video_backup': <dynamic>[
    <String, dynamic>{
      'label': '1080P超清',
      'quality': '1080p',
      'url': 'https://example.invalid/v-1080-low.mp4',
      'bit_rate': 2000000,
      'size': 10000000,
      'width': 1920,
      'height': 1080,
    },
    <String, dynamic>{
      'label': '1080P',
      'quality': '1080p',
      'url': 'https://example.invalid/v-1080-high.mp4',
      'bit_rate': 4000000,
      'size': 30000000,
      'width': 1920,
      'height': 1080,
    },
    <String, dynamic>{
      'label': '720P高清',
      'quality': '720p',
      'url': 'https://example.invalid/v-720.mp4',
      'bit_rate': 1500000,
      'size': 8000000,
      'width': 1280,
      'height': 720,
    },
    // 认不出档位的一条:不参与去重,原样留着
    <String, dynamic>{'url': 'https://example.invalid/v-unknown.mp4'},
  ],
  'images': <dynamic>[],
  'live_photo': <dynamic>[],
  'music': <String, dynamic>{
    'title': '背景音乐',
    'url': 'https://example.invalid/bgm.mp3',
  },
};

/// 上游的图集/实况帖:`url` 是空的,媒体全在 `images` + `live_photo` 里。
Map<String, dynamic> _upstreamLiveData() => <String, dynamic>{
  'type': 'live',
  'title': '上游实况帖',
  'desc': '文案',
  'author': <String, dynamic>{'name': '上游作者'},
  'cover': 'https://example.invalid/c.jpg',
  'url': null,
  'images': <dynamic>['https://example.invalid/1.jpeg', null],
  'live_photo': <dynamic>[
    <String, dynamic>{
      'image': 'https://example.invalid/live-thumb.jpeg',
      'video': 'https://example.invalid/live.mp4',
    },
  ],
  'video_backup': <dynamic>[],
};

/// media-parser 的应答:只有一条地址,没有清晰度列表。
Map<String, dynamic> _fallbackVideoData() => <String, dynamic>{
  'title': '兜底视频',
  'desc': '文案',
  'platform': '抖音',
  'video_url': 'https://example.invalid/fallback.mp4',
  'cover_url': 'https://example.invalid/c.jpg',
  'image_list': <dynamic>[],
};

/// 上游那套应答外壳:`code` + `data`(media-parser 是 `succ` + `data`)。
http.Response _upstreamOk(Map<String, dynamic> data) => http.Response.bytes(
  utf8.encode(
    jsonEncode(<String, dynamic>{'code': 200, 'msg': '解析成功-eo', 'data': data}),
  ),
  200,
  headers: const <String, String>{'content-type': 'application/json'},
);

http.Response _ok(Map<String, dynamic> data) => http.Response.bytes(
  utf8.encode(
    jsonEncode(<String, dynamic>{'succ': true, 'retcode': 200, 'data': data}),
  ),
  200,
  headers: const <String, String>{'content-type': 'application/json'},
);

/// 失败应答。注意必须走 `Response.bytes` + UTF-8:`http.Response('中文')` 会用
/// latin-1 编码,中文直接抛异常,于是「上游答 400」变成「网络连接失败」。
http.Response _fail([String message = '链接失效']) => http.Response.bytes(
  utf8.encode(jsonEncode(<String, dynamic>{'succ': false, 'retdesc': message})),
  400,
  headers: const <String, String>{'content-type': 'application/json'},
);

/// 上游那种失败:HTTP 422 + `error` 字段(实测拿错平台的链接就是这个)。
http.Response _upstreamFail([String message = '解析参数与该平台不匹配']) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(<String, dynamic>{'code': -1, 'error': message})),
      422,
      headers: const <String, String>{'content-type': 'application/json'},
    );

/// 装后端:记录每次请求的地址,[upstream] 决定上游那几条接口怎么答。
///
/// 记的是 **host + path**(不再是纯 path):APP 现在直连上游站点,路径里区分不出
/// "是上游还是兜底"了 —— 得看域名。
///
/// 返回的列表就是调用顺序 —— 用它断言「先上游、后兜底」,以及「有没有碰过上游」。
List<String> useStubTwoUpstreams({
  http.Response Function()? upstream,
  http.Response Function()? fallback,
}) {
  final hits = <String>[];
  ParseService.clientFactory = () => MockClient((request) async {
    final url = request.url;
    // 预热是另一回事,不算解析调用
    if (url.path == '/ping') return http.Response('', 204);
    final where = '${url.host}${url.path}';
    hits.add(where);
    // 上游站点 vs 我们自己的反代:按域名分。顺手确认上游那条带了密钥头 ——
    // 密钥在客户端里,漏了就会 401,这条断言就是防这个的。
    if (url.host == Uri.parse(ParseService.upstreamBase).host) {
      expect(
        request.headers['X-API-Key'],
        ParseService.upstreamApiKey,
        reason: '直连上游必须带 X-API-Key',
      );
      return (upstream ?? () => _upstreamOk(_upstreamVideoData()))();
    }
    expect(
      request.headers['X-API-Key'],
      isNull,
      reason: 'media-parser 那条不该带上游密钥',
    );
    return (fallback ?? () => _ok(_fallbackVideoData()))();
  });
  addTearDown(() => ParseService.clientFactory = () => http.Client());
  return hits;
}

/// 假下载器:不碰网络、不碰媒体库,只把每条要下的东西记下来。
List<DownloadItem> useStubDownloader() {
  // 下载第一步要问系统要临时目录。测试里没有真的 path_provider 插件,
  // 不接一下这一步会一直等下去。
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => call.method == 'getTemporaryDirectory'
            ? Directory.systemTemp.createTempSync('jicun_test').path
            : null,
      );
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        ),
  );

  final items = <DownloadItem>[];
  final realFetch = Downloader.fetchImpl;
  final realPublish = Downloader.publishImpl;
  Downloader.fetchImpl =
      (item, temp, onFraction, cancelled, onSize, client) async {
        items.add(item);
        onSize?.call(100);
        onFraction(1);
        return File('${temp.path}/${item.fileName}');
      };
  Downloader.publishImpl = (item, file) async => null;
  addTearDown(() {
    Downloader.fetchImpl = realFetch;
    Downloader.publishImpl = realPublish;
  });
  return items;
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // 收流那一步生产上是原生的(平台通道),测试里到不了替身 —— 走 Dart 实现,
    // 替身(fetchImpl)才生效。见 Downloader.useDartEngine。
    Downloader.useDartEngine = true;
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('平台识别', () {
    test('短链和子域名都归到同一个平台', () {
      expect(
        detectPlatform('https://v.douyin.com/abcd/'),
        ParsePlatform.douyin,
      );
      expect(
        detectPlatform('https://www.douyin.com/video/1'),
        ParsePlatform.douyin,
      );
      expect(
        detectPlatform('https://v.kuaishou.com/abcd'),
        ParsePlatform.kuaishou,
      );
      expect(
        detectPlatform('https://channels.weixin.qq.com/x'),
        ParsePlatform.wechatChannels,
      );
    });

    test('别的平台认成 unknown,不吃上游', () {
      expect(
        detectPlatform('https://www.bilibili.com/video/BV1'),
        ParsePlatform.unknown,
      );
      expect(detectPlatform('https://weibo.com/1'), ParsePlatform.unknown);
      // 域名里带 douyin 但不是它的子域:不能认成抖音
      expect(
        detectPlatform('https://douyin.com.evil.example/x'),
        ParsePlatform.unknown,
      );
    });

    test('四个平台各有各的上游路径', () {
      // 上游是每平台一条独立接口,拿错平台的链接会回 422
      expect(
        ParseService.upstreamPaths[ParsePlatform.douyin],
        'https://api-new.ifphp.com/api/dyjx',
      );
      expect(
        ParseService.upstreamPaths[ParsePlatform.kuaishou],
        'https://api-new.ifphp.com/api/ksjx',
      );
      expect(
        ParseService.upstreamPaths[ParsePlatform.wechatChannels],
        'https://api-new.ifphp.com/api/wxsph',
      );
      expect(
        ParseService.upstreamPaths[ParsePlatform.doubao],
        'https://api-new.ifphp.com/api/doubao',
      );
      // 认不出的平台不走上游
      expect(
        ParseService.upstreamPaths.containsKey(ParsePlatform.unknown),
        isFalse,
      );
    });
  });

  group('路由', () {
    test('抖音:先走上游直连接口,成功就不碰兜底', () async {
      final hits = useStubTwoUpstreams();
      final service = ParseService();
      addTearDown(service.dispose);

      final result = await service.parse('https://v.douyin.com/abcd/');

      expect(hits, <String>['api-new.ifphp.com/api/dyjx']);
      expect(service.lastRoute, 'upstream:douyin');
      expect(result.title, '上游视频');
      // 上游那个 `platform` 是英文名(douyin),给用户看的应该是中文
      expect(result.platform, '抖音');
      expect(result.authorName, '上游作者');
      expect(result.coverUrl, 'https://example.invalid/c.jpg');
    });

    test('快手和视频号各走各的路,不会串', () async {
      final hits = useStubTwoUpstreams();
      final service = ParseService();
      addTearDown(service.dispose);

      await service.parse('https://v.kuaishou.com/abcd');
      await service.parse('https://channels.weixin.qq.com/x');

      expect(hits, <String>[
        'api-new.ifphp.com/api/ksjx',
        'api-new.ifphp.com/api/wxsph',
      ]);
    });

    test('快手:上游失败就回落 media-parser', () async {
      final hits = useStubTwoUpstreams(upstream: _upstreamFail);
      final service = ParseService();
      addTearDown(service.dispose);

      final result = await service.parse('https://v.kuaishou.com/abcd');

      expect(hits, <String>['api-new.ifphp.com/api/ksjx', '$apiHost/parse']);
      expect(service.lastRoute, 'upstream:kuaishou-failed→fallback');
      expect(result.title, '兜底视频');
    });

    test('微信视频号:上游没解析出东西也算失败,回落兜底', () async {
      // 200 + code:200,但 data 里一条媒体都没有 —— 不能当成功
      final hits = useStubTwoUpstreams(
        upstream: () => _upstreamOk(<String, dynamic>{'title': '空结果'}),
      );
      final service = ParseService();
      addTearDown(service.dispose);

      final result = await service.parse('https://channels.weixin.qq.com/x');

      expect(hits, <String>['api-new.ifphp.com/api/wxsph', '$apiHost/parse']);
      expect(result.title, '兜底视频');
    });

    test('上游回的是 media-parser 那套结构时也认,不再白打一次兜底', () async {
      // 反代或上游某天原样透传 media-parser 的应答。这时候不能映射成一个空结果 ——
      // 空结果会被判成「上游没解析出东西」,于是再打一次兜底:用户白等一个来回,
      // 平台那边也多花一次调用。
      final hits = useStubTwoUpstreams(
        upstream: () => _ok(_fallbackVideoData()),
      );
      final service = ParseService();
      addTearDown(service.dispose);

      final result = await service.parse('https://v.douyin.com/abcd/');

      expect(hits, <String>['api-new.ifphp.com/api/dyjx']);
      expect(result.title, '兜底视频');
      expect(result.primaryVideoUrl, 'https://example.invalid/fallback.mp4');
    });

    test('豆包:走上游直连接口,上游失败回落 media-parser', () async {
      final hits = useStubTwoUpstreams(upstream: _upstreamFail);
      final service = ParseService();
      addTearDown(service.dispose);

      final result = await service.parse('https://www.doubao.com/thread/abc');

      expect(hits, <String>['api-new.ifphp.com/api/doubao', '$apiHost/parse']);
      expect(service.lastRoute, 'upstream:doubao-failed→fallback');
      expect(result.title, '兜底视频');
    });

    test('豆包:上游成功就用上游的', () async {
      final hits = useStubTwoUpstreams();
      final service = ParseService();
      addTearDown(service.dispose);

      final result = await service.parse('https://www.doubao.com/thread/abc');

      expect(hits, <String>['api-new.ifphp.com/api/doubao']);
      expect(result.platform, '豆包');
      expect(result.primaryVideo!.hasQualityChoice, isTrue);
    });

    test('其他平台:一次都不打上游', () async {
      final hits = useStubTwoUpstreams();
      final service = ParseService();
      addTearDown(service.dispose);

      await service.parse('https://www.bilibili.com/video/BV1');

      expect(hits, <String>['$apiHost/parse']);
      expect(service.lastRoute, 'fallback-only');
    });

    test('两条路都失败:报上游那句(它才是真原因),不是兜底那句', () async {
      useStubTwoUpstreams(
        upstream: _upstreamFail,
        fallback: () => _fail('该平台暂不支持'),
      );
      final service = ParseService();
      addTearDown(service.dispose);

      // 兜底那条路只会说「服务器异常」这类没信息量的话,而上游那句往往是
      // 「链接失效」「平台不支持」这种真原因 —— 两条都挂时报上游那句。
      Object? thrown;
      try {
        await service.parse('https://v.douyin.com/abcd/');
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ParseException>());
      expect((thrown! as ParseException).message, '解析参数与该平台不匹配');
    });

    test('上游回了 HTML 404(不是 JSON),也要靠兜底解析出来', () async {
      // 实测踩到过的真事:上游那条路回了非 JSON(404 的 HTML 错误页)。上一版会
      // 把它直接翻成「网络连接失败」甩给用户,而其实 media-parser 照样能解析这条
      // 链接。现在必须回落 —— 用户什么都不会察觉,只是少了个分辨率选项。
      final hits = useStubTwoUpstreams(
        upstream: () => http.Response.bytes(
          utf8.encode('<html><title>404 Not Found</title></html>'),
          404,
          headers: const <String, String>{'content-type': 'text/html'},
        ),
      );
      final service = ParseService();
      addTearDown(service.dispose);

      final result = await service.parse('https://v.douyin.com/abcd/');

      expect(hits, <String>['api-new.ifphp.com/api/dyjx', '$apiHost/parse']);
      expect(result.title, '兜底视频');
      expect(service.lastRoute, 'upstream:douyin-failed→fallback');
    });
  });

  group('分辨率', () {
    test('上游那套字段:主地址算最高档,video_backup 补齐其余,同档只留高码率', () {
      final result = ParseResult.fromUpstream(_upstreamVideoData());
      final qualities = result.primaryVideo!.qualities;

      // 原画(主地址,34 Mbps)> 1080P(4 Mbps,低码率那条被去掉了)> 720P > 无标签
      expect(
        <String>[for (final q in qualities) q.label],
        <String>['原画', '1080P', '720P', ''],
      );
      expect(qualities[1].url, 'https://example.invalid/v-1080-high.mp4');
      expect(qualities[1].bitrate, 4000000);
      // 弹窗右边那行说明:码率 + 体积。10 Mbps 以下留一位小数,再大取整
      // (42.0 Mbps 那种写法没有信息量);体积超过 100MB 也取整。
      expect(qualities[1].detail, '4.0 Mbps · 28.6 MB');
      expect(qualities.first.detail, '34 Mbps · 668 MB');
    });

    test('图集/实况帖:url 是空的,媒体从 images + live_photo 里来', () {
      final result = ParseResult.fromUpstream(_upstreamLiveData());
      // images 里的 null 要被剔掉
      expect(result.imageUrls, <String>['https://example.invalid/1.jpeg']);
      expect(result.livePhotos.length, 1);
      expect(
        result.livePhotos.single.videoUrl,
        'https://example.invalid/live.mp4',
      );
      expect(
        result.livePhotos.single.thumbUrl,
        'https://example.invalid/live-thumb.jpeg',
      );
      // 实况图算视频:媒体卡该列出来
      expect(result.hasVideo, isTrue);
      // 这条应答里没有独立音频字段 —— 音频卡只能退回视频自带音轨
      expect(result.audioUrl, isNull);
    });

    test('真实应答(抖音视频帖):字段名逐个对上,主地址就是最高档', () {
      final data = kRealDouyinVideo['data'] as Map<String, dynamic>;
      final result = ParseResult.fromUpstream(data, platform: '抖音');

      expect(result.title, startsWith('【8KHDR素材】'));
      expect(result.platform, '抖音');
      expect(result.authorName, '8K视界');
      expect(result.coverUrl, startsWith('https://p3-sign.douyinpic.com/'));
      expect(result.videoUrl, startsWith('https://v3-dy-a-x.ixigua.com/'));
      // `music.url` 就是这条帖子的原声:收进 audio_url,音频卡放它
      expect(
        result.audioUrl,
        startsWith('https://sf6-cdn-tos.douyinstatic.com/obj/ies-music/'),
      );
      expect(result.hasStandaloneAudio, isTrue);
      expect(result.audioSource, result.audioUrl);

      // 原画(主地址,34.7 Mbps)> 720P(1.7 Mbps)> 540P(1.3 Mbps)
      final qualities = result.primaryVideo!.qualities;
      expect(
        <String>[for (final q in qualities) q.label],
        <String>['原画', '720P', '540P'],
      );
      expect(qualities[0].url, result.videoUrl);
      expect(qualities[0].bitrate, 34698694);
      expect(qualities[0].size, 7807454953);
      expect(qualities[1].bitrate, 1678555);
      expect(qualities[1].url, startsWith('https://v6-hscy.ixigua.com/'));
      // 「720P高清」那个后缀已经削掉,不会和别的档位重名
      expect(qualities[2].label, '540P');
      expect(result.primaryVideo!.hasQualityChoice, isTrue);

      // 预览走最低那档:主地址是 8K / 34.7 Mbps,预览播放器按秒缓冲,几十秒
      // 就把 Java 堆吃光(真机 tombstone 实测 OOM)。下载仍然按用户选的那档走。
      expect(result.previewVideoUrl, qualities.last.url);
      expect(result.previewVideoUrl, isNot(result.primaryVideoUrl));
      expect(qualities.last.bitrate, 1294152);
    });

    test('真实应答(抖音实况帖):url 是 null,媒体来自 images + live_photo', () {
      final data = kRealDouyinLive['data'] as Map<String, dynamic>;
      final result = ParseResult.fromUpstream(data, platform: '抖音');

      expect(result.videoUrl, isNull);
      expect(result.authorName, '多少u才算够');
      // images 里那一张就是实况的静态帧:实况不算"有视频",所以它不该被当封面剔掉
      expect(result.imageUrls.length, 1);
      expect(result.livePhotos.length, 1);
      expect(
        result.livePhotos.single.videoUrl,
        startsWith('https://v3-chameleon.usergrowth.com.cn/'),
      );
      expect(
        result.livePhotos.single.thumbUrl,
        startsWith('https://p3-pc-sign.douyinpic.com/'),
      );
      // 实况图算视频,所以媒体卡有东西可列 —— 这也是「上游空结果」判据的来源
      expect(result.hasVideo, isTrue);
      expect(result.primaryVideoUrl, result.livePhotos.single.videoUrl);
      // 实况帖没有清晰度可选(上游 video_backup 是空的)
      expect(result.primaryVideo!.hasQualityChoice, isFalse);
    });

    test('真实应答(快手):标签取数字档位,同一条 720P 出现两遍也只留一格', () {
      final data = kRealKuaishouVideo['data'] as Map<String, dynamic>;
      final result = ParseResult.fromUpstream(data, platform: '快手');

      expect(result.title, startsWith('你在找的'));
      expect(result.platform, '快手');
      expect(result.authorName, '沐沐-游戏推荐');
      // 快手这条没给封面、没给 size —— 缺字段不该让整条映射崩掉
      expect(result.coverUrl, isNull);

      final qualities = result.primaryVideo!.qualities;
      // 两档:主地址(快手这里 label/bit_rate 都是空的)+ 720P
      // 「720P」不是上游那个「高清」:数字档位才跨平台一致,也才去得掉重
      expect(
        <String>[for (final q in qualities) q.label],
        <String>['720P', ''],
      );
      // 上游把同一条 720P 给了两遍(地址只差 query 签名),去重后只剩一条
      expect(qualities[0].bitrate, 266000);
      expect(
        qualities[0].url,
        startsWith('https://k0u7cyeeyf5yc2zw240exb1x9801x406x800xx3z.djvod'),
      );
      expect(result.primaryVideo!.hasQualityChoice, isTrue);
    });

    test('同一个资源只算一次:host+path 一样、query 不同的两条地址', () {
      final qualities = dedupeQualities(const <VideoQuality>[
        VideoQuality(
          url: 'https://cdn.example/a.mp4?sig=first',
          label: '720P',
          bitrate: 200000,
        ),
        VideoQuality(
          url: 'https://cdn.example/a.mp4?sig=second',
          label: '720P',
          bitrate: 300000,
        ),
      ]);
      expect(qualities.length, 1);
      // 同一条资源留码率高的那个签名
      expect(qualities.single.bitrate, 300000);
      expect(qualities.single.url, 'https://cdn.example/a.mp4?sig=second');
    });

    test('码率一样时留文件大的那条', () {
      final qualities = dedupeQualities(const <VideoQuality>[
        VideoQuality(url: 'a', label: '1080P', bitrate: 3000000, size: 100),
        VideoQuality(url: 'b', label: '1080P', bitrate: 3000000, size: 200),
      ]);
      expect(qualities.length, 1);
      expect(qualities.single.url, 'b');
    });

    test('预览取最低档,这条对所有平台都一样', () {
      // 快手:主地址(没标码率)+ 720P
      final ks = ParseResult.fromUpstream(
        kRealKuaishouVideo['data'] as Map<String, dynamic>,
        platform: '快手',
      );
      expect(ks.previewVideoUrl, ks.primaryVideo!.qualities.last.url);

      // 只有一档的(media-parser):就是它本身,行为跟以前一致
      final single = ParseResult.fromJson(_fallbackVideoData());
      expect(single.previewVideoUrl, single.primaryVideoUrl);

      // 完全没有视频:null,不该抛
      final none = ParseResult.fromJson(<String, dynamic>{'title': '空'});
      expect(none.previewVideoUrl, isNull);
    });

    test('media-parser 那种只有地址的结果没有可选项', () {
      final result = ParseResult.fromJson(_fallbackVideoData());
      expect(result.primaryVideo!.qualities, isEmpty);
      expect(result.primaryVideo!.hasQualityChoice, isFalse);
    });

    test('media-parser 单条 video_url + bit_rate 也算一档,但不够两档不给选', () {
      final result = ParseResult.fromJson(<String, dynamic>{
        'title': 't',
        'video_url': 'https://example.invalid/v.mp4',
        'bit_rate': 2500000,
      });
      expect(result.primaryVideo!.qualities.single.label, '');
      expect(result.primaryVideo!.qualities.single.bitrate, 2500000);
      // 只有一档:不弹窗(见 main.dart 的 _qualityChoice)
      expect(result.primaryVideo!.hasQualityChoice, isFalse);
    });

    test('分辨率归一化:后缀、大小写、交叉写法都并到同一档', () {
      expect(normalizeQualityLabel('1080p'), '1080P');
      expect(normalizeQualityLabel('720P高清'), '720P');
      expect(normalizeQualityLabel('1080P超清'), '1080P');
      expect(normalizeQualityLabel('超清 1080'), '1080P');
      expect(normalizeQualityLabel('1920x1080'), '1080P');
      expect(normalizeQualityLabel('原画'), '原画');
      expect(normalizeQualityLabel(''), '');
    });

    test('存历史再读回来,分辨率还在', () {
      final result = ParseResult.fromUpstream(_upstreamVideoData());
      final restored = ParseResult.fromJson(result.toJson());
      expect(
        <String>[for (final q in restored.primaryVideo!.qualities) q.label],
        <String>['原画', '1080P', '720P', ''],
      );
      expect(
        restored.primaryVideo!.qualities[1].url,
        'https://example.invalid/v-1080-high.mp4',
      );
      expect(restored.primaryVideo!.qualities[1].bitrate, 4000000);
      expect(restored.primaryVideo!.qualities[1].size, 30000000);
    });
  });

  group('上游音频', () {
    test('music.url 收进 audio_url(快手图集/抖音实况实测都在这)', () {
      final result = ParseResult.fromUpstream(<String, dynamic>{
        'type': 'live',
        'url': null,
        'images': <dynamic>['https://example.invalid/1.webp'],
        'live_photo': <dynamic>[],
        'music': <String, dynamic>{'url': 'https://example.invalid/voice.m4a'},
      });

      expect(result.audioUrl, 'https://example.invalid/voice.m4a');
      expect(result.audioSource, 'https://example.invalid/voice.m4a');
      expect(result.hasStandaloneAudio, isTrue);
      // 音频卡出现:图集帖本来就只有这条路能听声音
      expect(result.hasPlayableAudio, isTrue);
    });

    test('music 是纯地址、以及 audio_url 那种写法,一样收', () {
      expect(
        ParseResult.fromUpstream(<String, dynamic>{
          'type': 'video',
          'music': 'https://example.invalid/voice.mp3',
        }).audioUrl,
        'https://example.invalid/voice.mp3',
      );
      expect(
        ParseResult.fromUpstream(<String, dynamic>{
          'type': 'video',
          'audio_url': 'https://example.invalid/voice.mp3',
        }).audioUrl,
        'https://example.invalid/voice.mp3',
      );
    });

    test('music 是空对象(豆包 AI 音乐分享实测):没有独立音频,退回视频音轨', () {
      final result = ParseResult.fromUpstream(<String, dynamic>{
        'type': 'video',
        'url': 'https://example.invalid/v.mp4',
        'music': <String, dynamic>{},
      });

      expect(result.audioUrl, isNull);
      expect(result.hasStandaloneAudio, isFalse);
      expect(result.audioSource, 'https://example.invalid/v.mp4');
    });
  });

  group('下载前的分辨率弹窗', () {
    /// 起一次 App、解析一条链接,停在结果页。
    Future<void> parseLink(WidgetTester tester, String link) async {
      tester.view.physicalSize = const Size(1260, 2800);
      tester.view.devicePixelRatio = 3.5;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const LiquidGlassDemo());
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(CupertinoTextField), link);
      await tester.pump();
      await tester.tap(find.text('开始解析'));
      await tester.pumpAndSettle();
    }

    testWidgets('抖音上游结果:点下载先弹清晰度窗,选了才下', (tester) async {
      final hits = useStubTwoUpstreams();
      final items = useStubDownloader();
      await parseLink(tester, 'https://v.douyin.com/abcd/');
      expect(hits, <String>['api-new.ifphp.com/api/dyjx']);

      await tester.tap(find.text('下载媒体').first);
      await tester.pumpAndSettle();

      // 弹窗出现,档位按高到低排;同档 1080P 只该有一格
      expect(find.text('选择清晰度'), findsOneWidget);
      expect(find.text('原画'), findsOneWidget);
      expect(find.text('1080P'), findsOneWidget);
      expect(find.text('720P'), findsOneWidget);
      // 还没选:什么都不能开始下
      expect(items, isEmpty);

      await tester.tap(find.text('1080P'));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('选择清晰度'), findsNothing);
      expect(items.length, 1);
      expect(items.single.url, 'https://example.invalid/v-1080-high.mp4');
    });

    testWidgets('点叉关掉弹窗:这次下载取消,不留后台任务', (tester) async {
      useStubTwoUpstreams();
      final items = useStubDownloader();
      await parseLink(tester, 'https://v.douyin.com/abcd/');

      await tester.tap(find.text('下载媒体').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(CupertinoIcons.xmark));
      await tester.pumpAndSettle();

      expect(find.text('选择清晰度'), findsNothing);
      expect(find.text('下载进度'), findsNothing);
      expect(items, isEmpty);
    });

    testWidgets('media-parser 结果:没有清晰度列表,直接开始下载', (tester) async {
      useStubTwoUpstreams(
        upstream: _upstreamFail,
        fallback: () => _ok(_fallbackVideoData()),
      );
      final items = useStubDownloader();
      await parseLink(tester, 'https://v.kuaishou.com/abcd');

      await tester.tap(find.text('下载媒体').first);
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      // 一次点击就进进度卡:中间不该冒出清晰度窗
      expect(find.text('选择清晰度'), findsNothing);
      expect(find.text('下载进度'), findsOneWidget);
      expect(items.single.url, 'https://example.invalid/fallback.mp4');
    });
  });
}
