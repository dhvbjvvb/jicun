// 第二个解析上游的接入测试。
//
// 三件事各验一段:
//   1. 路由:抖音/快手/微信视频号/豆包先走上游,失败才回落到 media-parser;
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

import 'package:jicun/api_host.dart';
import 'package:jicun/downloader.dart';
import 'package:jicun/main.dart';
import 'package:jicun/parse_service.dart';

import 'fixtures/upstream_real_responses.dart';

/// 上游站点的 host。
///
/// **不写死**:域名跟 `lib/secrets.dart` 走(那个文件不入库),测试里抄一份
/// 就等于把真域名又写回版本库 —— 脱敏就成了白做。
final String _upstreamHost = Uri.parse(ParseService.upstreamBase).host;

/// 第二个上游的应答:同一条视频两档分辨率,1080P 故意给两个码率。
///
/// 1080P 那两条是这次去重规则的靶子:高的(4000000 / 30MB)必须留下,
/// 低的那条(2000000)必须消失。
/// 上游的应答结构,按实测那条抖音链接抄的(字段名逐个对应)。
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

/// 汽水音乐那条**免密钥**接口(bugpk)的 host。
///
/// 同样不写死:真值在 [ParseService.publicUpstreamPaths] 里。测试里抄一份域名
/// 就等于把「这条链接打去哪」也一起写进了测试 —— 换接口时两边会一起错。
final String _publicHost = Uri.parse(
  ParseService.publicUpstreamPaths[ParsePlatform.qishuiMusic]!,
).host;

/// 免密钥那家的应答外壳:`code` + `msg` + `data`(注意**没有** `succ`)。
http.Response _publicOk(Map<String, dynamic> data) => http.Response.bytes(
  utf8.encode(
    jsonEncode(<String, dynamic>{'code': 200, 'msg': '解析成功-esa', 'data': data}),
  ),
  200,
  headers: const <String, String>{'content-type': 'application/json'},
);

/// 免密钥那家的失败:实测(2026-10-06)它**回的是 HTTP 200**,理由在 `msg` 里 ——
/// `{"code":404,"msg":"获取失败"}` / `{"code":400,"msg":"无法解析视频 ID"}`。
/// 所以「状态码 200 就等于成功」那套判据在这里必须不管用。
http.Response _publicFail([String message = '获取失败']) => http.Response.bytes(
  utf8.encode(jsonEncode(<String, dynamic>{'code': 404, 'msg': message})),
  200,
  headers: const <String, String>{'content-type': 'application/json'},
);

/// 汽水音乐那条接口回的那条音轨地址。
///
/// 照真实应答抄的:路径是个不带后缀的 ID,格式写在 query 里(`mime_type=audio_mp4`)
/// —— 分流就是靠这个东西,不是靠扩展名。
const String _kQishuiAudioUrl =
    'https://v11-luna.douyinvod.com/dd840183d5b5f4e0a4147cbed178f1eb/6ac536ba/'
    'video/tos/cn/tos-cn-ve-2774/o0HA2iq2geZQEcktFPCsVQYDZgjDjpsBKafHKl/'
    '?a=8478&ch=0&cr=5&br=251&bt=251&mime_type=audio_mp4&qs=7';

/// 汽水音乐那条接口回的**一首歌** —— 字段逐个照真实应答抄(2026-10-06,
/// `https://qishui.douyin.com/s/iXqRAg7Q/`),只把地址和歌词截短。
Map<String, dynamic> _qishuiSongData({
  String url = _kQishuiAudioUrl,
}) => <String, dynamic>{
  'url': url,
  'video_meta': <String, dynamic>{
    'quality': 'highest',
    'vtype': 'm4a',
    'bitrate': 257535,
    'codec_type': 'aac',
    'size': 4011636,
    'file_id': '3b22eed8828b4a85ab7b4bf8eab67d49',
    'file_hash': '561e23049d99ab884bc6b1ab13a1860e',
    'real_bitrate': 257535,
    'audio_sample_rate': 44100,
  },
  'lyric': '[1880,3710]<0,240,0>You <240,260,0>thought <500,220,0>that '
      '<720,240,0>you <960,220,0>would <1180,220,0>use <1400,240,0>me\n'
      '[5600,3710]<0,180,0>When <180,150,0>I <330,170,0>fell',
  'albumname': 'Left alone',
  'artistsid': 2344610331113192,
  'artistsname': 'TI_C',
  'artistsmedium_avatar_url': <dynamic>[
    'https://p3.douyinpic.com/aweme/720x720/aweme-avatar/tos-cn-avt-0015_x.jpeg',
  ],
};

/// 装后端:记录每次请求的地址,[upstream] / [publicUpstream] 决定第三方那几条接口
/// 怎么答。
///
/// 记的是 **host + path**(不再是纯 path):APP 现在直连第三方站点,路径里区分不出
/// "是第三方还是兜底"了 —— 得看域名。
///
/// 返回的列表就是调用顺序 —— 用它断言「先第三方、后兜底」,以及「有没有碰过第三方」。
List<String> useStubTwoUpstreams({
  http.Response Function()? upstream,
  http.Response Function()? fallback,
  http.Response Function()? publicUpstream,
}) {
  final hits = <String>[];
  ParseService.clientFactory = () => MockClient((request) async {
    final url = request.url;
    // 预热是另一回事,不算解析调用
    if (url.path == '/ping') return http.Response('', 204);
    final where = '${url.host}${url.path}';
    hits.add(where);
    // 付费那家 vs 我们自己的反代 vs 免密钥那家:按域名分。顺手确认该带密钥的那条
    // 带了(**客户端里那份**),漏了就会 401,这条断言就是防这个的。
    if (url.host == Uri.parse(ParseService.upstreamBase).host) {
      expect(
        request.headers['X-API-Key'],
        ParseService.upstreamApiKey,
        reason: '直连付费上游必须带 X-API-Key',
      );
      return (upstream ?? () => _upstreamOk(_upstreamVideoData()))();
    }
    if (url.host == _publicHost) {
      expect(
        request.headers['X-API-Key'],
        isNull,
        reason: '公开接口是免密钥的,我们的密钥一个字节都不该发过去',
      );
      return (publicUpstream ?? () => _publicOk(_qishuiSongData()))();
    }
    expect(
      request.headers['X-API-Key'],
      isNull,
      reason: 'media-parser 那条不该带上游密钥',
    );
    return (fallback ?? () => _ok(_fallbackVideoData()))();
  });
  addTearDown(() => ParseService.clientFactory = http.Client.new);
  return hits;
}

/// 最近一份假下载器。页面是从 `ShellController.downloader` 拿下载器的,所以
/// 得把它喂给 [LiquidGlassDemo] 的 `downloader` 参数才算装上。
Downloader? _stubDownloader;

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
  _stubDownloader = Downloader(
    useDartEngine: true,
    deps: DownloadDeps(
      fetch: (item, ctx) async {
        items.add(item);
        ctx.onSize?.call(100);
        ctx.onFraction(1);
        return File('${ctx.temp.path}/${item.fileName}');
      },
      publish: (item, file) async => null,
    ),
  );
  return items;
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
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
        'https://$_upstreamHost/api/dyjx',
      );
      expect(
        ParseService.upstreamPaths[ParsePlatform.kuaishou],
        'https://$_upstreamHost/api/ksjx',
      );
      // 视频号虽然在服务端被关掉(platform_settings 里 enabled=0),但它必须留在
      // 这张表里 —— 它能不能解析完全取决于这条上游接口,跟 media-parser 无关。
      // 删掉这一行会让它连上游都不试,直接拿到「接口维护中」,平台整个不能用。
      expect(
        ParseService.upstreamPaths[ParsePlatform.wechatChannels],
        'https://$_upstreamHost/api/wxsph',
      );
      expect(
        ParseService.upstreamPaths[ParsePlatform.doubao],
        'https://$_upstreamHost/api/doubao',
      );
      // 认不出的平台不走上游
      expect(
        ParseService.upstreamPaths.containsKey(ParsePlatform.unknown),
        isFalse,
      );
    });

    test('汽水音乐:短链、分享页、网页版都归到它', () {
      // 分享短链。这条最要紧:qishui.douyin.com 是 douyin.com 的**子域**,
      // 而 detectPlatform 认子域 —— 靠的是它在 _kPlatformHosts 里排在抖音前面。
      expect(
        detectPlatform('https://qishui.douyin.com/s/69HXcAV/'),
        ParsePlatform.qishuiMusic,
      );
      // 短链跳转后的分享页:挂在整个属于抖音的域名上,只能连路径一起认
      expect(
        detectPlatform('https://music.douyin.com/qishui/share/track?track_id=1'),
        ParsePlatform.qishuiMusic,
      );
      expect(detectPlatform('https://www.qishui.com/'), ParsePlatform.qishuiMusic);
      // 抖音还是抖音 —— 上面那两条不能把整个域名带跑
      expect(
        detectPlatform('https://music.douyin.com/aweme/1'),
        ParsePlatform.douyin,
      );
      expect(
        detectPlatform('https://www.douyin.com/video/1'),
        ParsePlatform.douyin,
      );
    });

    test('汽水音乐在免密钥那张表里,不在付费那张', () {
      // 进了付费那张表,[_request] 就会把我们按量计费的密钥发到这个第三方站点
      expect(
        ParseService.upstreamPaths.containsKey(ParsePlatform.qishuiMusic),
        isFalse,
      );
      expect(ParseService.upstreamPaths[ParsePlatform.qishuiMusic], isNull);
      expect(
        ParseService.publicUpstreamPaths[ParsePlatform.qishuiMusic],
        'https://api.bugpk.com/api/qsmusic',
      );
    });
  });

  group('明文地址升到 https', () {
    // Android 9 起、targetSdk ≥ 28 默认禁明文,清单里也没放开 —— 原生下载器
    // (`HttpURLConnection`)和预览播放器(ExoPlayer)拿到 `http://` 会直接抛
    // `java.io.IOException: Cleartext HTTP traffic to … not permitted`,
    // 落进「网络中断,请重试」那一档。
    //
    // 实测(2026-09-30,真机 vivo V2502A + 模拟器):快手一条图集帖,上游给的
    // 17 张图 + 1 条 m4a 全是 http,原生下载器逐条抛上面那句;换 https 后
    // 177408 / 727697 字节都下得来。
    test('只换 http:// 前缀,https 和其它 scheme 原样', () {
      expect(
        secureMediaUrls('http://a.kwimgs.com/x.webp?sig=abc'),
        'https://a.kwimgs.com/x.webp?sig=abc',
      );
      // `https://` 也以 "http" 开头 —— 判据必须是完整前缀,否则会拼成 https://s://…
      expect(secureMediaUrls('https://a.com/x'), 'https://a.com/x');
      expect(secureMediaUrls('httpx://a.com/x'), 'httpx://a.com/x');
      expect(secureMediaUrls('/api/audio?token=x'), '/api/audio?token=x');
      // 非地址的字符串不动(标题里出现 http:// 字样也只当普通文本处理)
      expect(secureMediaUrls('文案'), '文案');
      expect(secureMediaUrls(42), 42);
      expect(secureMediaUrls(null), isNull);
    });

    test('嵌套结构整份过一遍:图集 / 实况图 / 独立音轨都逃不掉', () {
      final out =
          secureMediaUrls(<String, dynamic>{
                'url': 'http://a.com/v.mp4',
                'images': <dynamic>[
                  'http://a.com/1.webp',
                  'http://a.com/2.webp',
                ],
                'live_photo': <dynamic>[
                  <String, dynamic>{
                    'image': 'http://a.com/f.webp',
                    'video': 'http://a.com/l.mp4',
                  },
                ],
                'music': <String, dynamic>{'url': 'http://a.com/a.m4a'},
                'video_backup': <dynamic>[
                  <String, dynamic>{
                    'url': 'http://a.com/720.mp4',
                    'label': '高清',
                  },
                ],
              })!
              as Map<String, dynamic>;

      expect(out['url'], 'https://a.com/v.mp4');
      expect(out['images'], <String>[
        'https://a.com/1.webp',
        'https://a.com/2.webp',
      ]);
      expect((out['live_photo'] as List).first['video'], 'https://a.com/l.mp4');
      expect(out['music']['url'], 'https://a.com/a.m4a');
      expect(
        (out['video_backup'] as List).first['url'],
        'https://a.com/720.mp4',
      );
    });

    test('端到端:上游给的全是 http,解析出来后模型里一个 http 都不剩', () async {
      final data = _upstreamVideoData(videoUrl: 'http://example.invalid/v.mp4');
      data['cover'] = 'http://example.invalid/c.jpg';
      data['images'] = <dynamic>['http://example.invalid/1.webp'];
      data['music'] = <String, dynamic>{'url': 'http://example.invalid/a.m4a'};
      data['live_photo'] = <dynamic>[
        <String, dynamic>{
          'image': 'http://example.invalid/f.webp',
          'video': 'http://example.invalid/l.mp4',
        },
      ];
      useStubTwoUpstreams(upstream: () => _upstreamOk(data));
      final service = ParseService();
      addTearDown(service.dispose);

      final result = await service.parse('https://v.kuaishou.com/abcd');

      String noHttp(String? url) => url ?? '';
      expect(noHttp(result.coverUrl), 'https://example.invalid/c.jpg');
      expect(noHttp(result.primaryVideoUrl), 'https://example.invalid/v.mp4');
      expect(noHttp(result.audioUrl), 'https://example.invalid/a.m4a');
      expect(result.imageUrls, contains('https://example.invalid/1.webp'));
      // 备选清晰度也是下载地址,一样不能留明文
      expect(
        result.primaryVideo!.qualities.map((q) => q.url),
        everyElement(startsWith('https://')),
      );
      // 兜底再兜一层:模型里任何一个地址都不该还是 http
      expect(
        <String>[
          ...result.imageUrls,
          ...result.videos.map((v) => v.url),
          ...result.videos.expand((v) => v.qualities.map((q) => q.url)),
          ...result.livePhotos.map((p) => p.videoUrl),
        ].where((u) => u.startsWith('http://')),
        isEmpty,
      );
    });
  });

  group('路由', () {
    test('抖音:先走上游直连接口,成功就不碰兜底', () async {
      final hits = useStubTwoUpstreams();
      final service = ParseService();
      addTearDown(service.dispose);

      final result = await service.parse('https://v.douyin.com/abcd/');

      expect(hits, <String>['$_upstreamHost/api/dyjx']);
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
        '$_upstreamHost/api/ksjx',
        '$_upstreamHost/api/wxsph',
      ]);
    });

    test('快手:上游失败就回落 media-parser', () async {
      final hits = useStubTwoUpstreams(upstream: _upstreamFail);
      final service = ParseService();
      addTearDown(service.dispose);

      final result = await service.parse('https://v.kuaishou.com/abcd');

      expect(hits, <String>['$_upstreamHost/api/ksjx', '$apiHost/parse']);
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

      expect(hits, <String>['$_upstreamHost/api/wxsph', '$apiHost/parse']);
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

      expect(hits, <String>['$_upstreamHost/api/dyjx']);
      expect(result.title, '兜底视频');
      expect(result.primaryVideoUrl, 'https://example.invalid/fallback.mp4');
    });

    test('豆包:走上游直连接口,上游失败回落 media-parser', () async {
      final hits = useStubTwoUpstreams(upstream: _upstreamFail);
      final service = ParseService();
      addTearDown(service.dispose);

      final result = await service.parse('https://www.doubao.com/thread/abc');

      expect(hits, <String>['$_upstreamHost/api/doubao', '$apiHost/parse']);
      expect(service.lastRoute, 'upstream:doubao-failed→fallback');
      expect(result.title, '兜底视频');
    });

    test('豆包:上游成功就用上游的', () async {
      final hits = useStubTwoUpstreams();
      final service = ParseService();
      addTearDown(service.dispose);

      final result = await service.parse('https://www.doubao.com/thread/abc');

      expect(hits, <String>['$_upstreamHost/api/doubao']);
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

      expect(hits, <String>['$_upstreamHost/api/dyjx', '$apiHost/parse']);
      expect(result.title, '兜底视频');
      expect(service.lastRoute, 'upstream:douyin-failed→fallback');
    });
  });

  group('汽水音乐的路由', () {
    // 汽水音乐的分享短链(实测 2026-10-06 那一批里的一条)。
    const link = 'https://qishui.douyin.com/s/69HXcAV/';

    test('先打第三方(免密钥):成功就用它的,不再走兜底的解析', () async {
      // 这一条应答自带封面 → 不需要补封面那一趟(见下面两条)
      final hits = useStubTwoUpstreams(
        publicUpstream: () => _publicOk(<String, dynamic>{
          ..._qishuiSongData(),
          'cover': 'https://example.invalid/album.jpg',
        }),
      );
      final service = ParseService();
      addTearDown(service.dispose);

      final result = await service.parse(link);

      expect(hits, <String>['$_publicHost/api/qsmusic']);
      expect(service.lastRoute, 'upstream:qishuiMusic');
      expect(result.title, 'Left alone');
      expect(result.platform, '汽水音乐');
      expect(result.authorName, 'TI_C');
      expect(result.coverUrl, 'https://example.invalid/album.jpg');
      // 这条应答回的是**音频流**(`mime_type=audio_mp4`):出来的该是音频卡,
      // 不是「媒体卡上挂一个 m4a」。判据就是这两个(见 preview.dart 的 forResult)。
      expect(result.hasStandaloneAudio, isTrue);
      expect(result.hasVideo, isFalse);
      expect(result.audioUrl, _kQishuiAudioUrl);
    });

    test('第三方没给专辑封面:补一次我们服务器,只取那张真封面', () async {
      // 真实应答就是这样:只有歌手头像,没有封面字段。补回来的是我们服务器那条
      // (`_fallbackVideoData` 里的 `cover_url`)。
      final hits = useStubTwoUpstreams(
        publicUpstream: () => _publicOk(_qishuiSongData()),
      );
      final service = ParseService();
      addTearDown(service.dispose);

      final result = await service.parse(link);

      expect(hits, <String>['$_publicHost/api/qsmusic', '$apiHost/parse']);
      // 结论仍然是第三方那一份:线路名只多一段 `+cover`,不是 `→fallback`
      expect(service.lastRoute, 'upstream:qishuiMusic+cover');
      expect(result.coverUrl, 'https://example.invalid/c.jpg');
      // 别的字段一个都没被我们服务器那一份顶掉
      expect(result.title, 'Left alone');
      expect(result.authorName, 'TI_C');
      expect(result.audioUrl, _kQishuiAudioUrl);
      // 歌词也是第三方那一份(转成了 LRC),没被我们服务器那份顶掉
      expect(result.lyrics, startsWith('[00:01.88]You thought'));
    });

    test('补封面两次都没成:留着歌手头像,别把解析结论弄丢', () async {
      final hits = useStubTwoUpstreams(
        publicUpstream: () => _publicOk(_qishuiSongData()),
        fallback: () => _fail('服务器异常'),
      );
      final service = ParseService();
      addTearDown(service.dispose);

      final result = await service.parse(link);

      // 补封面会**重试一次**(那一下网络没成是常事,见 parse_service.dart 的
      // [_coverAttempts]),所以兜底那条被打两次 —— 但两次都没成的结论和以前一样:
      // 还是第三方那一份,封面留着头像。
      expect(hits, <String>[
        '$_publicHost/api/qsmusic',
        '$apiHost/parse',
        '$apiHost/parse',
      ]);
      expect(service.lastRoute, 'upstream:qishuiMusic+cover-miss');
      expect(
        result.coverUrl,
        'https://p3.douyinpic.com/aweme/720x720/aweme-avatar/tos-cn-avt-0015_x.jpeg',
      );
      expect(result.title, 'Left alone');
      expect(result.hasStandaloneAudio, isTrue);
    });

    test('补封面第一次没成、第二次成了:结论还是第三方那份,封面补上', () async {
      // 这正是 2026-10-06 用户手机上那条的现场:同一份包、同一分钟内下了三首,
      // 两条补上了封面、中间那条 `cover_url` 是 null。第一次网络没成是常事,
      // 没有这次重试,那首歌就永远没封面(卡片和内嵌 covr 一起空着)。
      var attempts = 0;
      final hits = useStubTwoUpstreams(
        publicUpstream: () => _publicOk(_qishuiSongData()),
        fallback: () {
          attempts++;
          return attempts == 1 ? _fail('网络连接失败') : _ok(_fallbackVideoData());
        },
      );
      final service = ParseService();
      addTearDown(service.dispose);

      final result = await service.parse(link);

      expect(hits, <String>[
        '$_publicHost/api/qsmusic',
        '$apiHost/parse',
        '$apiHost/parse',
      ]);
      expect(service.lastRoute, 'upstream:qishuiMusic+cover');
      expect(result.coverUrl, 'https://example.invalid/c.jpg');
      // 只换了封面:标题 / 作者 / 歌词 / 音轨仍然是第三方那一份
      expect(result.title, 'Left alone');
      expect(result.authorName, 'TI_C');
      expect(result.audioUrl, _kQishuiAudioUrl);
      expect(result.lyrics, startsWith('[00:01.88]You thought'));
    });

    test('第三方回 HTTP 200 + code 404:那不是成功,回落 media-parser', () async {
      final hits = useStubTwoUpstreams(publicUpstream: _publicFail);
      final service = ParseService();
      addTearDown(service.dispose);

      final result = await service.parse(link);

      expect(hits, <String>['$_publicHost/api/qsmusic', '$apiHost/parse']);
      expect(service.lastRoute, 'upstream:qishuiMusic-failed→fallback');
      expect(result.title, '兜底视频');
    });

    test('第三方回 200 + 空结果(一条媒体都没有)也算失败,回落', () async {
      final hits = useStubTwoUpstreams(
        publicUpstream: () => _publicOk(<String, dynamic>{
          'type': 'music',
          'title': '空结果',
        }),
      );
      final service = ParseService();
      addTearDown(service.dispose);

      await service.parse(link);

      expect(hits, <String>['$_publicHost/api/qsmusic', '$apiHost/parse']);
      expect(service.lastRoute, 'upstream:qishuiMusic-empty→fallback');
    });

    test('两条都失败:报第三方那句(它才是真原因)', () async {
      useStubTwoUpstreams(
        publicUpstream: _publicFail,
        fallback: () => _fail('该平台暂不支持'),
      );
      final service = ParseService();
      addTearDown(service.dispose);

      Object? thrown;
      try {
        await service.parse(link);
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ParseException>());
      expect((thrown! as ParseException).message, '获取失败');
    });
  });

  group('分辨率', () {
    test('上游那套字段:主地址算最高档,video_backup 补齐其余,同档只留高码率', () {
      final result = ParseResult.fromUpstream(_upstreamVideoData());
      final qualities = result.primaryVideo!.qualities;

      // 主地址(「原画」,上游给了 7680x3210,所以档位名是 8K,34 Mbps)>
      // 1080P(4 Mbps,低码率那条被去掉了)> 720P > 无标签
      expect(
        <String>[for (final q in qualities) q.label],
        <String>['8K', '1080P', '720P', ''],
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

      // 主地址(「原画」按宽高 7680x3210 算成 8K,34.7 Mbps)>
      // 720P(1.7 Mbps)> 540P(1.3 Mbps)
      final qualities = result.primaryVideo!.qualities;
      expect(
        <String>[for (final q in qualities) q.label],
        <String>['8K', '720P', '540P'],
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
      // 两档:主地址(快手根上只有 `quality`=`原画`,没给宽高,所以留原名)+ 720P。
      // 「720P」不是上游那个「高清」:数字档位才跨平台一致,也才去得掉重
      expect(
        <String>[for (final q in qualities) q.label],
        <String>['原画', '720P'],
      );
      // 原画排第一:rank 3000 比任何数字档位都高,它本来就是最高档
      expect(qualities[0].url, startsWith('https://tymov2.a.kwimgs.com/upic/'));
      // 上游把同一条 720P 给了两遍(地址只差 query 签名),去重后只剩一条
      expect(qualities[1].bitrate, 266000);
      expect(
        qualities[1].url,
        startsWith('https://k0u7cyeeyf5yc2zw240exb1x9801x406x800xx3z.djvod'),
      );
      expect(result.primaryVideo!.hasQualityChoice, isTrue);
    });

    test('回归:快手 video_backup 里的 .m3u8 不许当清晰度列出来', () {
      // 2026-09-30 抓的真实应答:一条 85MB 的快手视频,根上的 `url` 是真 mp4,
      // 而 `video_backup[]` 里 4 条**全是 .m3u8**(HLS 播放列表),标着「高清 720P」
      // 和「fhd15」,`size` 字段是 0。
      //
      // 下载器是一条 Range 一条连接地收字节、不做 HLS 分片拼接(见
      // android/.../NativeDownloader.kt),把播放列表列成档位,用户一选就下回来
      // 11KB 的文本 —— 这就是「能解析、一下载就报错」的来源。
      const mp4 = 'https://tymov2.a.kwimgs.com/upic/x_b.mp4?di=7bf65b1d';
      const m3u8 =
          'https://v23-vod-3.kwaicdn.com/vod-rt-remux/hls-ts/v0/'
          'REALTIME_REMUX_TS_4999/video-def/enc_x_b.mp4/x_7390_hlsob.m3u8'
          '?x-kcdn-pid=12021&pkey=AAXzct5R';
      final result = ParseResult.fromUpstream(<String, dynamic>{
        'type': 'video',
        'url': mp4,
        'label': '原画',
        'size': 89710839,
        'video_backup': <Map<String, dynamic>>[
          {'url': mp4, 'label': '原画', 'quality': '原画', 'size': 89710839},
          {
            'url': m3u8,
            'label': '高清',
            'quality': '720p',
            'bit_rate': 1941000,
            'size': 0,
          },
          {
            'url': m3u8,
            'label': '高清',
            'quality': '720p',
            'bit_rate': 1941000,
            'size': 0,
          },
        ],
      }, platform: '快手');

      final qualities = result.primaryVideo!.qualities;
      expect(
        <String>[for (final q in qualities) q.url],
        <String>[mp4],
        reason: '只该剩原画那一条 mp4',
      );
      expect(
        qualities.any((q) => q.label.contains('720')),
        isFalse,
        reason: 'm3u8 那一档必须消失,否则用户选了就下回来一个播放列表',
      );
      // 只剩一档就不该再弹选择窗(见「下载前的分辨率弹窗」那组)
      expect(result.primaryVideo!.hasQualityChoice, isFalse);
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

    test('不同档位共用同一条 CDN 路径时,两条都要留', () {
      // 抖音实测:同一个 host+path、只改 query 里的 `br` 发不同清晰度。
      // 曾经按资源一刀切,720P 会被原画当成重复丢掉 —— 弹窗里只剩原画 + 540P。
      final qualities = dedupeQualities(const <VideoQuality>[
        VideoQuality(
          url: 'https://cdn.example/tos/abc/?br=33885',
          label: '原画',
          bitrate: 34698694,
        ),
        VideoQuality(
          url: 'https://cdn.example/tos/abc/?br=1639',
          label: '720P',
          bitrate: 1678555,
        ),
        VideoQuality(
          url: 'https://cdn.example/tos/def/?br=1294',
          label: '540P',
          bitrate: 1294152,
        ),
      ]);
      expect(
        <String>[for (final q in qualities) q.label],
        <String>['原画', '720P', '540P'],
      );
    });

    test('K 档排序:8K / 4K 排在 1080P 之上', () {
      final qualities = dedupeQualities(const <VideoQuality>[
        VideoQuality(url: 'a', label: '1080P', bitrate: 4000000),
        VideoQuality(url: 'b', label: '4K', bitrate: 20000000),
        VideoQuality(url: 'c', label: '8K', bitrate: 40000000),
      ]);
      expect(
        <String>[for (final q in qualities) q.label],
        <String>['8K', '4K', '1080P'],
      );
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
      // 只有一档:不弹窗(见 lib/pages/preview.dart 的 _qualityChoice)
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
        <String>['8K', '1080P', '720P', ''],
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
      // 音频卡出现:图集帖本来就只有这条路能听声音
      expect(result.hasStandaloneAudio, isTrue);
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

    test('music 是空对象(豆包 AI 音乐分享实测):没有独立音频,音频卡不出现', () {
      final result = ParseResult.fromUpstream(<String, dynamic>{
        'type': 'video',
        'url': 'https://example.invalid/v.mp4',
        'music': <String, dynamic>{},
      });

      expect(result.audioUrl, isNull);
      expect(result.hasStandaloneAudio, isFalse);
      // 有视频,所以面板上照样有视频卡 —— 只是没有音频卡,也不会拿视频顶一张
      expect(result.hasVideo, isTrue);
    });
  });

  group('汽水音乐的映射', () {
    test('真实应答(一首歌):根上的 url 是音频流,出来的是音频卡', () {
      final result = ParseResult.fromQishuiMusic(_qishuiSongData());

      // 音频卡的判据就是这两个(见 lib/pages/preview.dart 的 forResult):
      expect(result.hasVideo, isFalse);
      expect(result.hasStandaloneAudio, isTrue);
      expect(result.audioUrl, _kQishuiAudioUrl);
      expect(result.videoUrl, isNull);
      expect(result.primaryVideo, isNull);
      // 名字在 `albumname`、歌手在 `artistsname`、封面只有歌手头像顶
      expect(result.title, 'Left alone');
      expect(result.authorName, 'TI_C');
      expect(
        result.coverUrl,
        'https://p3.douyinpic.com/aweme/720x720/aweme-avatar/tos-cn-avt-0015_x.jpeg',
      );
      // 这张是歌手头像兜的,不是专辑封面 —— 服务端据此再补一张真的(见 coverFromFallback)
      expect(result.coverFromFallback, isTrue);
      // 平台名是给用户看的中文
      expect(result.platform, '汽水音乐');
    });

    test('真实应答:逐字歌词转成标准 LRC —— 落盘的歌词就是这一份(带时间轴)', () {
      final result = ParseResult.fromQishuiMusic(_qishuiSongData());

      // 这一份同时写进 `©lyr` 与 `©des`(见 lib/audio_tags.dart 的 AudioTagInfo.lyrics):
      // 播放器认哪个字段各不相同,但两边都必须是**带时间轴**的,否则它滚动不起来。
      expect(
        result.lyrics,
        '[00:01.88]You thought that you would use me\n[00:05.60]When I fell',
      );
    });

    test('MV(url 与元数据都说 video)照旧当视频', () {
      final result = ParseResult.fromQishuiMusic(<String, dynamic>{
        'url': 'https://v11-luna.douyinvod.com/x/6ac5/tos/cn/mv/?mime_type=video_mp4',
        'video_meta': <String, dynamic>{'vtype': 'mp4', 'codec_type': 'h264'},
        'albumname': '某支 MV',
        'artistsname': '某歌手',
      });

      expect(result.primaryVideoUrl, startsWith('https://v11-luna'));
      expect(result.hasVideo, isTrue);
      expect(result.hasStandaloneAudio, isFalse);
      expect(result.title, '某支 MV');
    });

    test('同站 /api/douyin 那套结构也认:根上是音轨就挪进 audio_url', () {
      final result = ParseResult.fromQishuiMusic(<String, dynamic>{
        'type': 'music',
        'title': '歌名',
        'cover': 'https://example.invalid/cover.jpg',
        'url': 'https://example.invalid/song.mp3',
        'video_backup': <dynamic>[],
        'music': <String, dynamic>{'url': 'https://example.invalid/song.mp3'},
      });

      expect(result.audioUrl, 'https://example.invalid/song.mp3');
      expect(result.hasStandaloneAudio, isTrue);
      expect(result.title, '歌名');
      expect(result.coverUrl, 'https://example.invalid/cover.jpg');
      // 这一份自带封面 → 不是兜底图,服务端不会再补一趟(见 coverFromFallback)
      expect(result.coverFromFallback, isFalse);
    });

    test('同站那套结构里根上是 mp4:当视频,另给的音轨进音频卡', () {
      final result = ParseResult.fromQishuiMusic(<String, dynamic>{
        'type': 'video',
        'title': 'MV',
        'cover': 'https://example.invalid/c.jpg',
        'url': 'https://example.invalid/mv.mp4',
        'label': '原画',
        'music': <String, dynamic>{'url': 'https://example.invalid/bgm.mp3'},
      });

      expect(result.primaryVideoUrl, 'https://example.invalid/mv.mp4');
      expect(result.hasVideo, isTrue);
      expect(result.hasStandaloneAudio, isTrue);
    });

    test('同站那套结构里备选只有 HLS 播放列表时,一首歌仍然是歌', () {
      // 那种 m3u8 本来就会被丢掉(下载器不做 HLS 分片拼接),拿它把整份应答判成
      // 「MV」只会让这首歌顶着一张视频卡,而卡上那条地址下回来是个播放列表文本。
      final result = ParseResult.fromQishuiMusic(<String, dynamic>{
        'type': 'music',
        'url': 'https://example.invalid/song.mp3',
        'video_backup': <dynamic>[
          <String, dynamic>{
            'url': 'https://example.invalid/song_hlsob.m3u8',
            'quality': '720p',
          },
        ],
      });

      expect(result.primaryVideo, isNull);
      expect(result.audioUrl, 'https://example.invalid/song.mp3');
    });

    test('扩展名、MIME、元数据都说不清时按视频走(保守那边)', () {
      // 判成音频而视频卡不出现,用户就完全拿不到那一条流了;反过来只是卡片类型
      // 不准 —— 所以认不出来时站视频这边。
      final result = ParseResult.fromQishuiMusic(<String, dynamic>{
        'url': 'https://example.invalid/tos/abc/?br=981',
        'video_meta': <String, dynamic>{'vtype': 'unknown'},
      });

      expect(result.hasVideo, isTrue);
      expect(result.hasStandaloneAudio, isFalse);
    });

    test('存历史再读回来还是音频', () {
      final result = ParseResult.fromQishuiMusic(_qishuiSongData());
      final restored = ParseResult.fromJson(result.toJson());

      expect(restored.audioUrl, _kQishuiAudioUrl);
      expect(restored.hasStandaloneAudio, isTrue);
      expect(restored.hasVideo, isFalse);
      expect(restored.title, 'Left alone');
    });
  });

  group('下载前的分辨率弹窗', () {
    /// 起一次 App、解析一条链接,停在结果页。
    Future<void> parseLink(WidgetTester tester, String link) async {
      tester.view.physicalSize = const Size(1260, 2800);
      tester.view.devicePixelRatio = 3.5;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(LiquidGlassDemo(downloader: _stubDownloader));
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
      expect(hits, <String>['$_upstreamHost/api/dyjx']);

      await tester.tap(find.text('下载媒体').first);
      await tester.pumpAndSettle();

      // 弹窗出现,档位按高到低排;同档 1080P 只该有一格
      expect(find.text('选择清晰度'), findsOneWidget);
      expect(find.text('8K'), findsOneWidget);
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
