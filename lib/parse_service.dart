import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'api_host.dart';
import 'device_identity.dart';
import 'preferred_ip.dart';
import 'secrets.dart';
import 'upstream_mapping.dart';

// 模型(ParseResult / VideoQuality / VideoItem / LivePhoto …)搬去了
// upstream_mapping.dart,而全项目几十处 import 的是这个文件 —— 这里转出去,
// 调用点一行都不用改。新代码要用模型的话,**直接 import upstream_mapping.dart**,
// 免得解析服务和模型层的依赖又黏回去。
export 'upstream_mapping.dart';

/// 解析服务。
///
/// 三条路:
/// - **付费第三方聚合接口**:抖音 / 快手 / 微信视频号 / 豆包 先走这里(见
///   [upstreamPaths])。APP **直连**它,不经我们自己的服务器 —— 中间那跳只会加
///   一个来回,而它并不参与下载(下载是手机直连 CDN),所以去掉它只有好处。
///   代价是密钥必须编译进客户端(见 [upstreamApiKey]),反编译能拿到。
/// - **免密钥第三方**:汽水音乐先走这里(见 [publicUpstreamPaths])。同样直连,
///   但接口是公开的、不要密钥 —— 所以那份密钥**绝不能**发给它。
/// - **media-parser**:我们自建的那个,什么链接都吃。上面两条失败时兜底,
///   其余平台直接走它。
///
/// 还有一条**只为了补一张封面**的特殊用法:汽水音乐那条接口不给专辑封面,那种情况
/// 会再问一次 media-parser,只取 `cover_url`(见 [_withServerCover])—— 它不算回落,
/// 解析结论仍然是第三方那一份。
///
/// 路由规则见 [parse]。
class ParseService {
  ParseService({http.Client? client}) : _client = client ?? clientFactory();

  /// 构造 http client 的方式。
  ///
  /// 留成静态字段是为了让页面级的 widget 测试能换成 MockClient ——
  /// 否则点一下「开始解析」就会真发一次网络请求。生产代码不碰它。
  ///
  /// 生产环境挂上优选 IP:必须自己造 `HttpClient` 才拿得到 `connectionFactory`,
  /// `http.Client()` 内部那个实例摸不着。原理见 [PreferredIpConnector]。
  static http.Client Function() clientFactory = () => IOClient(
    HttpClient()
      ..connectionFactory = PreferredIpConnector(
        // 赛跑出来的赢家报回服务端:优选 IP 的排名只能来自真实客户端。
        onWinner: PreferredIpUpdater.instance.reportWinner,
        // 域名换成功了就立刻拉一次配置:域名变了,优选 IP 池和域名候选都属于
        // 上一个域名的 zone,得尽快换成新的(拉取失败也不影响这次请求)。
        onHost: (_) => PreferredIpUpdater.instance.refresh(),
      ).connect,
  );

  /// 兜底反代地址(media-parser)。换域名或换路径时只改这一行。
  ///
  /// 由 nginx 提供(站点配置在服务器上,不进版本库)。这条**仍然经过我们自己
  /// 的服务器**:media-parser 是我们自建的服务,密钥由 nginx 注入,不下发客户端。
  ///
  /// 域名不写死:用 [apiHost] —— 它可能已经被服务端下发的新域名换掉了(域名被
  /// 运营商阻断时,换域名是唯一的出路,见 api_host.dart)。
  static String get endpoint => apiUrl('/parse');

  /// 上游聚合接口的站点(第三方)。**APP 直连,不经我们的服务器。**
  ///
  /// 两个站点都实测过,差别**不在解析快慢,而在签出来的下载 CDN**:
  ///
  /// | 站点 | 原画 | 720P / 540P |
  /// |---|---|---|
  /// | 国内站点 | ixigua | **volcautovod.com(火山,国内 CDN)** |
  /// | 国外站点 | ixigua | ixigua |
  ///
  /// ixigua 那批地址在**移动数据上不可用**(运营商按域名掐):表现是预览播放器
  /// 初始化不了(卡片上没有时长)、点下载进度不动。所以只要用户在移动数据上,
  /// 就必须用国内站点 —— 它把非原画那几档换成了国内 CDN。
  ///
  /// 原画那档两个站点都只从 ixigua 签,移动数据下仍然不可用 —— 这是上游的取流
  /// 策略,我们改不了。要根治得让上游给原画也签国内 CDN。
  ///
  /// 换站点只改这一行 + [upstreamApiKey],APP 逻辑不动。
  // 域名同样不入库 —— 真值在 lib/secrets.dart（见 upstreamBaseUrl）。
  static const String upstreamBase = upstreamBaseUrl;

  /// 上游的密钥。
  ///
  /// **编译进客户端了** —— 这是刻意的取舍:直连省掉中间那一跳(少一个来回),
  /// 代价是反编译 APK 能拿到这个 key。换 key 需要重新发版(以前是改服务器上的
  /// 文件就行)。上游站点按 key 计费,别把它贴到公开地方。
  ///
  /// 真值在本地私有的 `lib/secrets.dart`(已 gitignore),模板见
  /// `lib/secrets.example.dart`。缺这个文件时是空串,四个平台自动落到
  /// media-parser 兜底,不影响编译。
  static const String upstreamApiKey = upstreamServiceKey;

  /// 平台 → 上游那条接口的完整地址(**带我们密钥的那条**,见 [upstreamApiKey])。
  ///
  /// 上游**每个平台一条独立接口**,拿错平台的链接去问会回 422「解析参数与该平台
  /// 不匹配」,所以一条路对一个平台。
  ///
  /// **这张表连同 [publicUpstreamPaths] 就是「先走第三方」的名单**:在表里的先打
  /// 第三方,失败(或两张表里都没有)才走 media-parser。加一个平台 = 这里加一行;
  /// 加一个**免密钥**的第三方 = [publicUpstreamPaths] 加一行。
  ///
  /// ⚠️ 这张表和「服务端支持哪些平台」是**两回事**,别混:
  ///
  /// 微信视频号在服务端是关掉的(`platform_settings` 里 `enabled=0`),但它仍然
  /// 在这张表里 —— 因为视频号能不能解析完全取决于上游那条接口,跟 media-parser
  /// 一点关系都没有。服务端关掉它,只说明「media-parser 解析不了视频号」;
  /// 上游失败之后回落过来拿到「视频号 接口维护中」,那正是预期结果。
  ///
  /// 别因为「服务端把这个平台关了」就把这一行删掉:删了它连上游都不会试,
  /// 直接落到服务端拿维护中提示,这个平台就整个不能用了。(改前确实这么错过一次。)
  static const Map<ParsePlatform, String> upstreamPaths =
      <ParsePlatform, String>{
        ParsePlatform.douyin: '$upstreamBase/api/dyjx',
        ParsePlatform.kuaishou: '$upstreamBase/api/ksjx',
        ParsePlatform.wechatChannels: '$upstreamBase/api/wxsph',
        ParsePlatform.doubao: '$upstreamBase/api/doubao',
      };

  /// 免密钥的第三方上游 —— 和 [upstreamPaths] 一样「先走第三方」,但接口是公开的。
  ///
  /// **为什么必须和 [upstreamPaths] 分开存**:两张表的差别只有一条 —— 要不要带上
  /// [upstreamApiKey]。付费那家的接口按 key 计费,而这一家的接口谁都能直接调;
  /// 合成一张表的话,[_request] 会把我们的密钥原样发给一个跟我们没有任何关系的
  /// 第三方服务器。所以密钥的开关跟着**表**走,不看平台。
  ///
  /// 汽水音乐在这张表里。两条路的关系:
  ///   - 它那条接口**失败/答空**时照样回落到 media-parser —— 汽水音乐本来就是
  ///     media-parser 能解析的平台之一(见 [ParseResult.fromQishuiMusic]);
  ///   - 它**成功**时,如果应答里没有专辑封面(只有歌手头像),还会再问一次
  ///     media-parser 补一张真封面(见 [_withServerCover])—— 那一趟不算回落。
  static const Map<ParsePlatform, String> publicUpstreamPaths =
      <ParsePlatform, String>{
        // bugpk 的公开接口:免密钥、GET、参数名 `url`(实测 2026-10-06)。
        ParsePlatform.qishuiMusic: 'https://api.bugpk.com/api/qsmusic',
      };

  /// 预热地址。由 nginx 直接返回 204,不走上游、不占解析限流额度,
  /// 目的只是把 DNS + TCP + TLS 这三个往返提前付掉。
  static String get pingUrl => apiUrl('/ping');

  /// 兜底那条路的超时。media-parser 要打第三方平台,给宽一点。
  static const Duration _timeout = Duration(seconds: 20);

  /// 上游那条路的超时,比 [_timeout] 短。
  ///
  /// 这条路失败还要接着走兜底,两次串起来不能让用户等 40 秒 —— 上游 12 秒还没
  /// 答就判它这次不行(它自己也会打第三方平台,常态是 1~3 秒)。
  static const Duration _upstreamTimeout = Duration(seconds: 12);

  final http.Client _client;

  /// 解析实际上走了哪条路。**只给探针和排障用**,APP 界面不依赖它。
  ///
  /// 报告里要能回答「这条链接到底走的哪个上游」,而两个上游的应答都长得差不多,
  /// 从结果上看不出来。
  String? lastRoute;

  /// 提前把到反代的连接建起来。
  ///
  /// 用户点输入框、或刚启动 APP 的时候调用 —— 那会儿他还在粘链接、还没点「开始解析」,
  /// 正好把握手那几百毫秒花掉。`_client` 自己带连接池,解析请求直接复用这条连接。
  /// 失败一律吞掉,预热不该让用户看到任何错误。
  ///
  /// 前一次预热太久了就再打一次:dart:io 的连接池空闲 15 秒就把连接断了(见
  /// `HttpClient.idleTimeout`)。少了这一步,「启动时预热过一次」会把后面每次点
  /// 输入框的预热全挡掉,而那时连接其实早就没了。
  void warmUp() {
    final now = DateTime.now();
    final last = _warmedAt;
    if (last != null && now.difference(last) < _warmTtl) return;
    _warmedAt = now;
    _client.get(Uri.parse(pingUrl)).ignore();
  }

  /// 预热有效期,比 `HttpClient.idleTimeout`(15 秒)短一点。
  static const Duration _warmTtl = Duration(seconds: 12);

  DateTime? _warmedAt;

  /// 解析一条分享链接。
  ///
  /// 路由:
  /// - 在 [upstreamPaths] 或 [publicUpstreamPaths] 里的平台 → 先打该平台那条第三方
  ///   接口(前者带我们的密钥,后者是公开接口、不带);
  /// - 其他平台 → 只用 media-parser。
  ///
  /// **上游那一趟只要没拿到能用的结果就回落**,四种情况都算:
  ///   1. 超时、限流、连不上、返回的不是 JSON(比如反代还没配 `/parse2`,会回
  ///      一个 HTML 404)—— 见 [_request] 抛出来的 [ParseException];
  ///   2. `code` 不为成功;
  ///   3. 应答里一条媒体都没有 —— 上游对部分链接会回 200 + 空结果,那不是解析
  ///      成功,拿它当结论用户会看到一张空卡片;
  ///   4. 兜底那条路自己抛异常(见下面的 catch)。
  ///
  /// 第 4 条看着多余,其实是最要紧的一条:**反代还没部署上游那几条路时,上一版
  /// 会把这个异常直接甩给用户**(「网络连接失败,请检查网络后重试」),而其实
  /// media-parser 照样能解析这条链接。回落之后用户什么都不会察觉,只是少了个
  /// 分辨率选项。
  ///
  /// 回落是**串行**的,不是抢跑:两个上游都可能收费,抢跑等于每次都付两份钱。
  Future<ParseResult> parse(String shareUrl) async {
    final platform = detectPlatform(shareUrl);
    // 「先走第三方」的名单有两张:付费那家带密钥,公开那家不带。一个平台只会落在
    // 其中一张里,所以两张合起来查一次就够了。
    final upstream = upstreamPaths[platform] ?? publicUpstreamPaths[platform];
    // 密钥跟着**表**走,不看平台:打进 [publicUpstreamPaths] 的接口是公开的,给它
    // 发我们的密钥等于把计费凭据白送出去。
    final withApiKey = upstreamPaths.containsKey(platform);

    // 不在服务端下发的支持名单里就在本地拦掉，一次请求都不发 ——
    // 但**只对本来就要打到我们服务器的平台**（[upstream] 为空）。
    //
    // 走第三方上游的平台绝不能在这里拦。服务端关掉一个平台只代表「media-parser
    // 解析不了它」，不代表这个平台整个不能用：视频号就是活例子，它完全靠上游，
    // 服务端关它反而是必然的，所以它**根本不在支持名单里** —— 拿白名单直接套它
    // 会把它整个拒掉。(改前确实这么错过一次。)
    //
    // 名单拉不到时 [unsupportedPlatformMessage] 返回 null（不拦），行为退回
    // 改动前 —— 拦是优化，不是正确性的一部分。
    if (upstream == null) {
      final blocked = unsupportedPlatformMessage(shareUrl);
      if (blocked != null) {
        lastRoute = 'blocked-local';
        throw ParseException(blocked);
      }
    }

    if (upstream != null) {
      ParseException? upstreamError;
      try {
        final result = await _request(
          upstream,
          shareUrl,
          _upstreamTimeout,
          platform: platform,
          fromUpstream: true,
          apiKey: withApiKey ? upstreamApiKey : null,
        );
        if (result.hasVideo || result.hasImages || result.hasAudio) {
          lastRoute = 'upstream:${platform.name}';
          // 汽水音乐那条接口不给专辑封面(只给歌手头像):这一位就是它置的,
          // 拿它去我们自己的服务器补一次真封面 —— **结论仍然算第三方的**,
          // 只是多一张图(见 [_withServerCover])。
          if (!result.coverFromFallback) return result;
          final covered = await _withServerCover(result, shareUrl);
          lastRoute = covered.coverFromFallback
              ? '$lastRoute+cover-miss'
              : '$lastRoute+cover';
          return covered;
        }
        lastRoute = 'upstream:${platform.name}-empty';
      } on ParseException catch (error) {
        // 上游自己的失败理由(链接失效、平台不支持…)对用户没用 —— 我们还有兜底,
        // 兜底那条路说出来的话才是这一趟真正的结论。所以这里只是接着往下走,
        // 真到了两条都失败那一步才拿它垫底(见下面的 catch)。
        lastRoute = 'upstream:${platform.name}-failed';
        upstreamError = error;
      }

      try {
        final result = await _request(endpoint, shareUrl, _timeout);
        lastRoute = '$lastRoute→fallback';
        return result;
      } on ParseException {
        // 兜底也挂了:这时候抛上游那句更准确 —— 它多半是「链接失效」「平台不支持」
        // 这类真实原因,而兜底那条路只会说「服务器异常」。
        throw upstreamError ?? ParseException('解析失败,换个链接或稍后再试');
      }
    }

    lastRoute = 'fallback-only';
    return _request(endpoint, shareUrl, _timeout);
  }

  /// 补一张**真专辑封面**。
  ///
  /// 为什么需要:汽水音乐那条第三方接口真的不给专辑封面,只给歌手头像
  /// (见 [ParseResult.coverFromFallback]),而这条链接我们的服务器解析得出来 ——
  /// media-parser 回的 `cover_url` 就是那张 375x375 的专辑封面图。封面不是可有可无
  /// 的东西:它要内嵌进下载下来的音频、还要当媒体卡的缩略图(见 lib/audio_tags.dart
  /// 的 `AudioTagInfo.coverUrl`)。
  ///
  /// 三条约束:
  /// - **只取封面**,其余字段一个都不动 —— 这一趟的解析结论仍然是第三方那一份;
  /// - **网络失败要重试一次**(见 [_coverAttempts]),但失败本身不再往上抛:
  ///   封面是加分项,补不到就返回原样的结果,卡片照样能用;
  /// - 超时给得短(见 [_coverTimeout]):这一步在解析**成功之后**,用户已经在看卡片了,
  ///   这时候让一张封面把整条链路拖住是划不来的。
  Future<ParseResult> _withServerCover(
    ParseResult result,
    String shareUrl,
  ) async {
    for (var attempt = 1; attempt <= _coverAttempts; attempt++) {
      try {
        final source = await _request(endpoint, shareUrl, _coverTimeout);
        final cover = source.coverUrl;
        if (cover == null || cover.isEmpty) {
          // 服务端答得清清楚楚:它这条链接也没封面。再问一次不会有别的答案。
          if (kDebugMode) debugPrint('补封面:服务端也没给封面($shareUrl)');
          return result;
        }
        return result.withCover(cover);
      } on ParseException catch (error) {
        // 留着这行日志:`cover_url` 为 null 时,靠它才能分清「服务端没有」还是
        // 「这一趟网络没成」—— 两种情况的处理完全不同(前者只能认命)。
        if (kDebugMode) {
          debugPrint('补封面第 $attempt/$_coverAttempts 次失败:$error($shareUrl)');
        }
      }
    }
    return result;
  }

  /// 补封面那次请求的超时。见 [_withServerCover]。
  static const Duration _coverTimeout = Duration(seconds: 8);

  /// 补封面那趟最多试几次。
  ///
  /// **为什么是两次**:这条路会**偶发**失败,失败被咽掉之后那首歌就永远没封面
  /// 了(卡片空白,下载下来的文件也没有 `covr`)。2026-10-06 用户在手机上下了
  /// 三首歌,同一份包、前后一分钟内,两条补上了、中间那条没补上
  /// (`shared_prefs` 里那条记录的 `cover_url` 是 null);同一天在 PC 上对这两条
  /// 链接真网络各打三次,六次全成、单次 1.2 秒。所以不是逻辑错,是那一下网络
  /// 没成 —— 再给一次机会就够了,不值得为它把卡片拖上十几秒。
  static const int _coverAttempts = 2;

  /// 打一个第三方接口(或者兜底的那条),把应答翻成 [ParseResult]。
  ///
  /// [fromUpstream] 为真表示这是**第三方**那条路:应答结构是另一套(见
  /// [ParseResult.fromUpstream]),而且它失败之后还有 media-parser 兜底。
  /// 带不带密钥看 [apiKey] —— 传 null 就是一个字节都不发(公开接口,见
  /// [publicUpstreamPaths])。
  ///
  /// [platform] 有两个用处:决定用哪个映射器(汽水音乐那条接口回的是一首歌,走
  /// [ParseResult.fromQishuiMusic]),以及应答里没写平台名时兜一个中文名给卡片。
  Future<ParseResult> _request(
    String endpoint,
    String shareUrl,
    Duration timeout, {
    ParsePlatform? platform,
    bool fromUpstream = false,
    String? apiKey,
  }) async {
    final uri = Uri.parse(endpoint).replace(queryParameters: {'url': shareUrl});
    // 密钥**只发给付费那家**:media-parser 的密钥由我们自己在 nginx 上注入,
    // 客户端手里没有(也不该有);公开的第三方更不该拿到它。
    var headers = apiKey == null
        ? null
        : <String, String>{'X-API-Key': apiKey};
    // 设备签名头(硬件密钥证明,见 lib/device_identity.dart)**只加给我们自己的端点**。
    // endpoint 由 apiUrl(...) 拼出来就算我们的;第三方上游那一批地址一律不加 ——
    // 那四个头里有 device_id,漏给第三方等于把「这台设备是谁」白送出去,和密钥同一条纪律。
    if (endpoint.startsWith(apiUrl(''))) {
      // 首次请求可能赶在启动那次身份登记办完之前 —— **用户一进来就粘贴解析**就是这种情形。
      // 那一次会不带签名头,在 enforce 下被服务端 403(线上实测:第一次粘上去必失败,
      // 把最后一个字符删掉重打一遍就好了)。等一次已经在跑的登记就行,已经有身份时不耽搁。
      await awaitDeviceIdentity();
      // 查询串传的是**原始那一整段**(`uri.query`):签名里含它的 sha256,而解码过的
      // 参数表和真正发出去的编码可能不一样(见 deviceHeaders 的说明)。
      final device = await deviceHeaders('GET', uri.path, uri.query);
      if (device.isNotEmpty) {
        headers = <String, String>{...?headers, ...device};
      }
    }
    Future<http.Response> retryWithSystemClient() async {
      final fallback = http.Client();
      try {
        // 这条兜底的标准连接也要带上同一份头:签名盖的是「方法 + 路径 + 查询串」,
        // 换个 client 重发不会让它失效。少带了的话这一趟在服务端就是一次**未签名**请求
        // (现在只记录,但日志里会凭空多出一条「没签名」)。
        return await fallback.get(uri, headers: headers).timeout(timeout);
      } finally {
        fallback.close();
      }
    }

    late http.Response response;
    try {
      response = headers == null
          ? await _client.get(uri).timeout(timeout)
          : await _client.get(uri, headers: headers).timeout(timeout);
    } on TimeoutException catch (error, stack) {
      if (!fromUpstream && _client is IOClient) {
        try {
          response = await retryWithSystemClient();
        } catch (fallbackError, fallbackStack) {
          if (kDebugMode) {
            debugPrint(
              '解析请求超时($endpoint):$error; 标准连接也失败: '
              '$fallbackError\n$stack\n$fallbackStack',
            );
          }
          throw ParseException('解析超时,请重试');
        }
      } else {
        throw ParseException('解析超时,请重试');
      }
    } catch (error, stack) {
      // 移动网络对 Cloudflare 某些优选 IP 可能不可达,而系统 DNS 的地址是通的。
      // 兜底接口只重试一次标准连接;第三方接口(付费的和公开的)保持原有行为,不重复请求。
      if (!fromUpstream && _client is IOClient) {
        try {
          response = await retryWithSystemClient();
        } catch (fallbackError, fallbackStack) {
          if (kDebugMode) {
            debugPrint(
              '解析请求失败($endpoint):$error; 标准连接也失败: '
              '$fallbackError\n$stack\n$fallbackStack',
            );
          }
          throw ParseException('网络连接失败,请检查网络后重试');
        }
      } else {
        // 原始错误只在 debug 里露头:线上那句「网络连接失败」是给用户看的,
        // 而排障要的是底下到底是 SocketException、还是 MockClient 里抛的断言。
        if (kDebugMode) debugPrint('解析请求失败($endpoint):$error\n$stack');
        throw ParseException('网络连接失败,请检查网络后重试');
      }
    }

    if (response.statusCode == 429) {
      throw ParseException('请求太频繁,请稍后再试');
    }

    Map<String, dynamic>? body;
    try {
      // 用 bodyBytes 手工解 UTF-8:上游若没在 Content-Type 里写 charset,
      // response.body 会按 latin-1 解,中文标题全变乱码。
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {
      body = null;
    }

    // 非 JSON 响应(网关错误页之类)只能靠状态码说话。
    if (body == null) {
      // 排障:直连上游时最怕"状态码 200 但不是 JSON"(网关错误页、CDN 拦截页)。
      // 只看中文提示分不清是哪一种,把状态码和前 200 字节打出来。
      if (kDebugMode) {
        final head = utf8.decode(response.bodyBytes, allowMalformed: true);
        debugPrint(
          '解析应答不是 JSON($endpoint): HTTP ${response.statusCode} '
          '${head.length > 200 ? head.substring(0, 200) : head}',
        );
      }
      if (response.statusCode == 200) throw ParseException('返回内容无法识别');
      throw ParseException('服务器异常(${response.statusCode}),请稍后再试');
    }

    if (_isSuccess(body) && _dataOf(body) is Map) {
      // 明文地址在这里就升成 https —— 这是所有路共用的唯一入口,升一次全都干净。
      // 不升的话 Android 会拦(禁明文),下载和预览都会失败;原因见 secureMediaUrls。
      final data = secureMediaUrls(_dataOf(body)) as Map<String, dynamic>;
      if (!fromUpstream) return ParseResult.fromJson(data);
      // 汽水音乐那条接口回的是**一首歌**:根上那条地址有可能就是音频流本身,所以
      // 它有自己一套映射(见 [ParseResult.fromQishuiMusic])。其余第三方共用一套结构。
      return platform == ParsePlatform.qishuiMusic
          ? ParseResult.fromQishuiMusic(data)
          : ParseResult.fromUpstream(data, platform: platform?.label ?? '');
    }

    // 关键:上游解析失败时用的是 HTTP 400 + retdesc,不是 200 + succ:false。
    // 所以不能拿状态码当结论 —— 那样只会弹出一句没用的「服务器异常(400)」,
    // 把 retdesc 里真正的原因(版权限制、链接失效、平台不支持)全丢掉。
    //
    // 上游那套用 `error` / `message`(实测:422「解析参数与该平台不匹配」),
    // media-parser 用 `retdesc` —— 两个都读。
    final retdesc =
        _str(body['retdesc']) ??
        _str(body['error']) ??
        _str(body['message']) ??
        _str(body['msg']);
    if (retdesc != null) throw ParseException(retdesc);
    throw ParseException('解析失败(${response.statusCode}),换个链接或稍后再试');
  }

  /// 应答是不是「成功」。
  ///
  /// 我们先接的是 media-parser 那套(`succ: true`)。第二个上游是另一套代码,
  /// 判定字段得容错:`succ` 真、或者 `code` 是 200/0 —— 两者都没有时只要带了
  /// `data` 对象就也认,免得因为少一个字段把一整条能用的结果判死。
  static bool _isSuccess(Map<String, dynamic> body) {
    if (body['succ'] == true) return true;
    final code = body['code'] ?? body['retcode'] ?? body['status'];
    if (code is num) return code == 200 || code == 0;
    if (code is String) {
      final text = code.trim();
      return text == '200' || text == '0' || text.toLowerCase() == 'ok';
    }
    return _dataOf(body) is Map;
  }

  /// 结果体。两个上游一个叫 `data`,一个叫 `result`,都认。
  static Object? _dataOf(Map<String, dynamic> body) =>
      body['data'] is Map ? body['data'] : body['result'];

  void dispose() => _client.close();

  static String? _str(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;
}

/// 支持的平台。**只用来决定走哪个上游**,不是「能不能解析」的白名单 ——
/// media-parser 那边还认一堆别的平台(微博、头条…),它们都归到
/// [ParsePlatform.unknown]。
enum ParsePlatform {
  douyin('抖音'),
  kuaishou('快手'),
  doubao('豆包'),
  wechatChannels('微信视频号'),
  /// 汽水音乐。**它有自己一条免密钥的第三方接口**(见
  /// [ParseService.publicUpstreamPaths]),不是走付费那家。
  qishuiMusic('汽水音乐'),

  /// 认不出/不在名单里。走 media-parser。
  unknown('');

  const ParsePlatform(this.label);

  /// 展示用的中文名。历史卡上「平台」那一栏就是它(见 lib/pages/history.dart
  /// 的 entrySubtitle)。
  final String label;
}

/// 短链域名 → 平台。
///
/// 判据只认**域名**,不认整段文本:分享文案里出现「抖音」两个字不代表这条链接
/// 是抖音的(用户转发别人的文案很常见)。域名认不出就交给兜底那条路,不会错——
/// media-parser 什么链接都吃。
const Map<String, ParsePlatform> _kPlatformHosts = <String, ParsePlatform>{
  // ⚠️ 汽水音乐**必须排在 douyin.com 前面**:它的分享短链是 `qishui.douyin.com/s/…`,
  // 而 [detectPlatform] 认子域(见下),顺序反了它就被当成抖音、送去抖音那条上游了。
  // 实测 2026-10-06:`https://qishui.douyin.com/s/…` 跳转后落在
  // `music.douyin.com/qishui/share/{track,album,playlist,mv,ugc_video}?…`。
  'qishui.douyin.com': ParsePlatform.qishuiMusic,
  // 汽水音乐网页版(www.qishui.com)。用户从浏览器里复制出来的就是这一类。
  'qishui.com': ParsePlatform.qishuiMusic,
  // 抖音:主站、短链、以及它的图集/去水印域名
  'douyin.com': ParsePlatform.douyin,
  'iesdouyin.com': ParsePlatform.douyin,
  'ixigua.com': ParsePlatform.douyin,
  // 快手:主站和它那两个短链
  'kuaishou.com': ParsePlatform.kuaishou,
  'gifshow.com': ParsePlatform.kuaishou,
  'chenzhongtech.com': ParsePlatform.kuaishou,
  'kwai.com': ParsePlatform.kuaishou,
  // 豆包
  'doubao.com': ParsePlatform.doubao,
  'doubao.cn': ParsePlatform.doubao,
  // 微信视频号
  'channels.weixin.qq.com': ParsePlatform.wechatChannels,
  'finder.video.qq.com': ParsePlatform.wechatChannels,
  'weixin.qq.com': ParsePlatform.wechatChannels,
};

/// 认这条链接属于哪个平台。认不出返回 [ParsePlatform.unknown]。
///
/// 大小写、子域名都归一到同一个平台:`v.douyin.com` → 抖音。
ParsePlatform detectPlatform(String url) {
  final uri = Uri.tryParse(url.trim());
  final host = uri?.host.toLowerCase() ?? '';
  if (host.isEmpty) return ParsePlatform.unknown;
  // 汽水音乐的分享页挂在 `music.douyin.com/qishui/…` 上(短链跳转后的地址就是它),
  // 而那个域名整体是抖音的 —— 这个只能连路径一起看,不然就得把整个域名让出去。
  if (host == 'music.douyin.com' && (uri?.path.startsWith('/qishui') ?? false)) {
    return ParsePlatform.qishuiMusic;
  }
  for (final entry in _kPlatformHosts.entries) {
    if (host == entry.key || host.endsWith('.${entry.key}')) {
      return entry.value;
    }
  }
  return ParsePlatform.unknown;
}

// absoluteMediaUrl 搬去了 upstream_mapping.dart:它是“读应答字段”这一步的一部分
// (被 ParseResult._decode 调用),留在网络层会让模型层反过来依赖路由。

/// 平台中文名。认不出返回空串 —— 卡片上宁可不写,也别写「未知平台」。
String platformLabel(String url) => detectPlatform(url).label;

/// 链接尾部可能粘上的字符:中英文标点、引号、括号。
const String _kTrailingJunk = '.,;:!?)]}。，、！？）》」』"\'';

/// 从粘贴进来的分享文本里挑出真正的链接。
///
/// 各平台复制出来的分享内容都裹着一堆前后缀,例如:
///   「7.62 复制打开抖音,看看【某某的作品】https://v.douyin.com/abc/ 复制此链接…」
/// 整段塞给接口只会解析失败。这里只取第一个 http(s) 链接。
///
/// 返回 null 表示这段文本里没有链接 —— 调用方据此决定要不要改写输入框。
String? extractShareUrl(String raw) {
  // `\S+?` 非贪婪 + `(?=https?://|\s|$)` 前瞻:只在「下一个链接的开头 / 空白 /
  // 文本结尾」三处停下。
  //
  // 原来用的是贪婪的 `https?://\S+`,剪贴板里两条链接紧挨着(中间没有空格)时会把
  // 两条一起吞进来,实测占全部请求的 0.5%,例如:
  //   https://mp.weixin.qq.com/s/St09HkNiic2pKhttps://mp.weixin.qq.com/s/St09HkNiic2pK9ngxghOqw9ngxghOqw
  // 这种拼接串发给接口只会解析失败。
  //
  // 代价:如果某条链接的查询串里带**未做百分号编码**的 `https://`,会在那里被截断。
  // 实测这种写法没有出现过(浏览器和 APP 复制出来的查询串都是 %3A%2F%2F),
  // 而拼接串的 bug 是真实存在的,所以取这一边。
  final match = RegExp(
    r'https?://\S+?(?=https?://|\s|$)',
    caseSensitive: false,
  ).firstMatch(raw);
  if (match == null) return null;

  var url = match.group(0)!;

  // 中间没有空格时,链接后面会直接粘上中文(「…/abc/复制此链接」)。
  // 合法 URL 里不会出现裸的中日韩字符(要出现也是百分号编码),所以从这里截断。
  final cjk = RegExp(r'[\u2e80-\u9fff\u3000-\u303f\uff00-\uffef]')
      .firstMatch(url);
  if (cjk != null) url = url.substring(0, cjk.start);

  // 再削掉尾部粘着的标点:句号、逗号、右括号这些。
  while (url.isNotEmpty && _kTrailingJunk.contains(url[url.length - 1])) {
    url = url.substring(0, url.length - 1);
  }

  // 只有 scheme 没有主机名的残片不算链接。
  return url.length > 'https://'.length ? url : null;
}
