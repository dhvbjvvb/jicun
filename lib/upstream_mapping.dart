/// 上游应答 → ParseResult 的归一化层。
///
/// 这一层只做一件事:把十几家平台千奇百怪的 JSON 揉成同一套模型(见 [ParseResult])。
/// **不碰网络** —— 请求、路由与重试都在 parse_service.dart 里,那边只负责“拿回来”,
/// 拿到之后怎么读字段全在这儿。
///
/// 抽出来的理由:原来这 1000 行和 ParseService 挤在一个文件里,而它们错的后果
/// 完全不同 —— 网络那段错了是“解析失败”,这一层错了是“解析成功但内容不对”
/// (少一条清晰度、把音频当视频、文案残留话题标签)。分开之后这一层能脱离网络单测,
/// 见 test/parse_service_test.dart 与 test/upstream_routing_test.dart。
library;

import 'api_host.dart';

/// 把应答里的媒体地址补成绝对地址。
///
/// **服务端会回相对地址**:平台的独立音轨是我们自己抽的,那条地址由解析服务签出来
/// (见 /api/audio),它只知道自己那一段路径(/api/audio?token=…),写死域名反而会把
/// 「服务端下发新域名」这条退路堵死(见 api_host.dart)。所以补域名这一步在客户端做,
/// 而且必须做 —— 拿相对地址去播放或下载,播放器会当成相对本地路径(报 Cannot open
/// file),下载器则直接报「地址解析失败」。
///
/// 只补「以 / 开头」的:绝对地址(平台 CDN、上游那些)原样返回。
String? absoluteMediaUrl(String? url) {
  if (url == null || url.isEmpty || !url.startsWith('/')) return url;
  return apiUrl(url);
}

/// 把应答里所有明文地址升成 https。
///
/// **为什么非升不可**:Android 9 起、targetSdk ≥ 28 的 App 默认禁明文流量,而清单里
/// 没有放开(也不该放开)。原生下载器走 `HttpURLConnection`、预览播放器走 ExoPlayer,
/// 都在 Java 网络栈上,受这条策略管 —— 拿到明文地址直接抛
/// `java.io.IOException: Cleartext HTTP traffic to … not permitted`。
/// 那句异常里带 "IOException",于是落进 notifications.dart 里按 IOException 兜的
/// 「网络中断,请重试」那一档:用户看到的是「能解析、一点下载就报错」。
///
/// 实测(2026-09-30,vivo 真机 + 模拟器):快手一条图集帖,上游给的 17 张图 + 1 条 m4a
/// **全是 `http://`**,原生下载器对每一条都抛上面那句;同一批地址换成 https 之后
/// 逐个都能下(3961 / 177408 / 727697 字节)。当时预览看着正常,是因为图片走 Flutter
/// 的 `dart:io`(裸 socket,不受那条策略管)—— 但同一个地址交给 ExoPlayer 就放不了。
///
/// **递归整份应答,而不是逐个字段**:图集、实况图、独立音轨、备选清晰度分散在
/// `images` / `live_photo` / `music` / `video_backup` 好几处,漏掉任何一处都会留下
/// 一个下不动的地址。非地址的字符串(标题、描述)原样返回 —— 判据只是 `http://` 前缀。
Object? secureMediaUrls(Object? node) {
  if (node is String) {
    return node.startsWith('http://') ? 'https://${node.substring(7)}' : node;
  }
  if (node is List) return [for (final item in node) secureMediaUrls(item)];
  // 键类型写死 `Map<String, dynamic>`(JSON 解出来就是这个),**不能只写 `is Map`**:
  // 那样会被提升成 `Map<dynamic, dynamic>`,`{for …}` 或 `map` 出来的键类型是
  // `dynamic`,回到调用点的 `as Map<String, dynamic>` 就炸「不是子类型」——实测踩过。
  if (node is Map<String, dynamic>) {
    return node.map<String, dynamic>(
      (key, value) => MapEntry(key, secureMediaUrls(value)),
    );
  }
  return node;
}

/// 解析失败。message 已经是可以直接给用户看的中文句子。
class ParseException implements Exception {
  ParseException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 视频的一档清晰度。
///
/// 只有上游(见 [ParseService.upstreamPaths])会给这个东西:它把同一条
/// 视频的多个码流都列出来(`video_backup[]`),让用户自己挑。media-parser 只给
/// 一条地址,所以那条路上的 [VideoItem.qualities] 是空的,下载弹窗也就不该出现。
class VideoQuality {
  const VideoQuality({
    required this.url,
    this.label = '',
    this.bitrate = 0,
    this.size = 0,
  });

  /// 这一档的播放地址。下载用的就是它。
  final String url;

  /// 分辨率档位,已经归一化成 `720P` 这种写法(见 [normalizeQualityLabel])。
  /// 认不出来(比如「原画」)就保留上游给的中文名,好过显示空。
  final String label;

  /// 码率,单位 bps。接口没给就是 0。
  ///
  /// 它有两个用处:同分辨率去重时比大小(见 [dedupeQualities]),以及弹窗里
  /// 给用户看一眼「这一档多大码流」。
  final int bitrate;

  /// 文件大小,单位字节。接口没给就是 0。
  final int size;

  /// 弹窗右侧那行说明。
  ///
  /// 码率和体积都给的话写成「2.5 Mbps · 18.3 MB」;都没给就返回空串,弹窗
  /// 只显示分辨率。数字不认识就整块不显示 —— 宁可少一行,也不写 0 Mbps。
  String get detail {
    final parts = <String>[
      if (_looksLikeBitrate(bitrate)) '${_mbps(bitrate)} Mbps',
      if (size > 0) '${_megabytes(size)} MB',
    ];
    return parts.join(' · ');
  }

  static bool _looksLikeBitrate(int value) => value >= 1000;

  static String _mbps(int bps) {
    final mbps = bps / 1000000;
    // 码率小于 10 Mbps 时留一位小数(2.5 Mbps 比 3 Mbps 有信息量),
    // 再大就取整 —— 42.0 Mbps 那种写法没有意义。
    return mbps >= 10 ? mbps.round().toString() : mbps.toStringAsFixed(1);
  }

  static String _megabytes(int bytes) {
    final mb = bytes / (1024 * 1024);
    return mb >= 100 ? mb.round().toString() : mb.toStringAsFixed(1);
  }
}

/// 分辨率标签归一化:`1080p` / `1080P` / `超清 1080` / `1920x1080` 都变成 `1080P`。
///
/// 归一化只为**去重**:同一档分辨率上游可能给好几个码流,写法却不一样
/// (`1080p` 和 `1080P`)。认不出来就原样返回,不硬猜 —— 猜错会让两档不同的
/// 分辨率被并成一档,用户就没得选了。
String normalizeQualityLabel(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return '';

  // `1920x1080` / `1080*1920`:取短边(竖屏视频的高就是短边)。
  final cross = RegExp(r'(\d{3,4})\s*[xX*]\s*(\d{3,4})').firstMatch(text);
  if (cross != null) {
    final a = int.tryParse(cross.group(1)!);
    final b = int.tryParse(cross.group(2)!);
    if (a != null && b != null) return '${a < b ? a : b}P';
  }

  // 上游的档位名后面缀着画质词(`720P高清`、`1080P超清`),而那些词在每一档上
  // 都不一样 —— 不削掉的话同一个 720 会出现「720P高清」「720P超清」两个格子。
  // 只在数字后面削:纯名字(`蓝光`)不能动。
  text = text.replaceFirst(
    RegExp(r'(?<=\d)\s*(高清|超清|蓝光|标清|流畅|原画|高码率|高清版)\s*$'),
    '',
  );

  // `1080P` / `1080p60` / `超清1080` / `1080` 都归到同一个档位。
  final height = RegExp(r'(\d{3,4})').firstMatch(text);
  if (height != null) return '${height.group(1)}P';

  // 认不出数字:`蓝光` / `超清` / `原画` 这类纯名字,保留原样当标签(仍然能去重)。
  return text;
}

/// 档位排序用的分量:数字越大越高。
///
/// 纯数字的(`1080P`)直接用数字;没有数字的超高画质标签给一个排在 4K 之上的值 ——
/// 上游把「原画」这种档位放在首位,排序时也该在首位。认不出的返回 1(排最后)。
int _qualityRank(String label) {
  // K 档先认:`4K` / `8K` / `2K`。_heightOf 的正则只抓数字,会把 `4K` 读成 4 ——
  // 排在 720P 下面,去重和排序时上游写 K 的档位就成了最低档。
  final k = RegExp(r'(\d+(?:\.\d+)?)\s*K', caseSensitive: false).firstMatch(label);
  if (k != null) {
    final value = double.tryParse(k.group(1)!) ?? 0;
    if (value > 0) return (value * 1000).round();
  }
  final height = _heightOf(label);
  if (height > 0) return height;
  if (label.isEmpty) return 0;
  const named = <String, int>{'原画': 3000, '蓝光': 2000, '超清': 1500, '高清': 1000};
  return named[label] ?? 1;
}

/// 同上,但输入是数字:1080 → `1080P`。
String qualityLabelOfNumber(num value) {
  final n = value.toInt();
  return n > 0 ? '${n}P' : '';
}

/// 同分辨率的多个码流只留**码率最高**的那一条。
///
/// 上游实测会给同一种分辨率列好几档(`1080p` 两种码率),照单全收弹窗里就会出现
/// 两个一模一样的「1080P」,用户没法选。判据只有两项,顺序是:
///   1. 码率大的赢;
///   2. 码率一样(或都没给)时,文件大的赢 —— 同码率下一个文件更大,画面一般更好;
///   3. 还一样就保留先出现的那条,顺序稳定(用户看到的第一条不会因为刷新而换人)。
///
/// [VideoQuality.label] 为空(认不出分辨率)的档位**不参与去重**,原样留着:
/// 那多半是「未知画质」的一条备用地址,合并掉反而可能把能下的地址丢了。
///
/// 最后再按**资源**去一次重(见 [_resourceId]),但**只在同一档位内**算:
/// 快手实测同一条 720P 会在 `video_backup` 里出现两遍,地址只差 query 里的签名,
/// 路径完全一样。不同档位共用同一路径是另一回事(CDN 用 query 区分清晰度),
/// 那种必须各留一条,否则 720P 会被原画当成重复吃掉。
List<VideoQuality> dedupeQualities(List<VideoQuality> qualities) {
  final best = <String, VideoQuality>{};
  final unknown = <VideoQuality>[];
  for (final q in qualities) {
    if (q.label.isEmpty) {
      unknown.add(q);
      continue;
    }
    final current = best[q.label];
    if (current == null || _betterThan(q, current)) best[q.label] = q;
  }
  // 按档位从高到低排:弹窗第一行应该是用户最可能想要的那一档。
  final known = best.values.toList()
    ..sort((a, b) {
      final byRank = _qualityRank(b.label).compareTo(_qualityRank(a.label));
      return byRank != 0 ? byRank : a.label.compareTo(b.label);
    });

  // 同一条资源**只在同一档位里**才算重复。
  //
  // 上游的 CDN 会用同一个 host+path、只改 query 里的 `br` 来发不同清晰度
  // (抖音实测)。按资源一刀切会把「720P」当成「原画」的重复直接丢掉 —— 用户
  // 看到的就是「少了 720P,只剩原画和 540P/576P」。所以 key 里带上档位:
  // 档位不同就是两档,即使落在同一个路径上。
  final seen = <String>{};
  final out = <VideoQuality>[];
  for (final q in [...known, ...unknown]) {
    if (seen.add('${q.label}\u0000${_resourceId(q.url)}')) out.add(q);
  }
  return out;
}

/// 同一个资源的判据:**去掉 query,只比 scheme + host + path**。
///
/// 平台的 CDN 给同一份文件的不同签名,差别只在 query 上(快手实测两条 720P
/// 就是这种)。媒体卡那边也有一份同样的判据(见 [ParseResult._identityOf]),
/// 两边都必须做 —— 那边比的是路径,这边还要认 host,因为这里比的是"同一档
/// 清晰度有没有重复给"。
String _resourceId(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  return '${uri.scheme}://${uri.host}${uri.path}';
}

bool _betterThan(VideoQuality candidate, VideoQuality current) {
  if (candidate.bitrate != current.bitrate) {
    return candidate.bitrate > current.bitrate;
  }
  return candidate.size > current.size;
}

int _heightOf(String label) {
  final match = RegExp(r'\d+').firstMatch(label);
  return match == null ? 0 : int.parse(match.group(0)!);
}

/// 这是不是上游那套结构。
///
/// 认的字段都是实测确认存在的:`type` / `cover` / `label` / `video_backup` /
/// `live_photo` —— media-parser 那套一个都没有(它用 `cover_url`、`video_url`)。
/// `url` 单独一条不算数:media-parser 的 `video_list[]` 里也有 `url`,不排除的话
/// 会把 `{"url": ...}` 这种残缺应答也当成上游格式。
bool _isUpstreamFormat(Map<String, dynamic> data) {
  const markers = <String>[
    'type',
    'cover',
    'label',
    'video_backup',
    'live_photo',
    'quality',
  ];
  for (final key in markers) {
    if (data.containsKey(key)) return true;
  }
  return false;
}

/// 从 media-parser 的应答里挑出可以给用户选的清晰度。
///
/// 它只有一条地址 + 一个 `bit_rate`,所以最多一档 —— 而一档不弹窗
/// (见 [VideoItem.hasQualityChoice]),等于 media-parser 的结果永远直接下载。
/// 存历史读回来时走 `qualities`(见 [ParseResult.toJson]),那是另一条路。
List<VideoQuality> _primaryQualities(Map<String, dynamic> json) {
  final stored = _qualityList(json);
  if (stored.isNotEmpty) return stored;
  final single = ParseResult._strOrNull(json['video_url']);
  if (single == null) return const [];
  final bitrate = ParseResult._intOrZero(json['bit_rate'] ?? json['bitrate']);
  if (bitrate <= 0) return const [];
  return dedupeQualities([VideoQuality(url: single, bitrate: bitrate)]);
}

/// 读 `qualities` / `quality_list` 里的清晰度列表(存历史时写的就是这个形状)。
List<VideoQuality> _qualityList(Object? item) {
  if (item is! Map) return const [];
  final raw = item['qualities'] ?? item['quality_list'];
  if (raw is! List) return const [];
  final out = <VideoQuality>[];
  for (final entry in raw) {
    final q = _qualityFromEntry(entry);
    if (q != null && !out.contains(q)) out.add(q);
  }
  return dedupeQualities(out);
}

/// 一个清晰度条目 → [VideoQuality]。
///
/// 上游给的对象长这样(实测 `video_backup[]`):
/// `{"label":"720P高清","quality":"720p","url":"…","bit_rate":1678555,
///   "size":377687084,"width":1722,"height":720,"format":"mp4","codec":"h264"}`
///
/// `label` 是给人看的档位名,`quality` 是机器名 —— 两个都能当标签,`label` 优先
/// (它带「高清」这类后缀,归一化时会削掉)。`size` 单位是字节。
///
/// **HLS 播放列表直接丢掉**:下载器是一条 Range 一条连接地收字节,不做 HLS 分片
/// 拼接。实测快手一条 85MB 的视频,`video_backup[]` 里 4 条全是 `.m3u8`
/// (`size` 字段是 0,标签是「高清 720P」/「fhd15」),只有根上的 `url` 是真 mp4 ——
/// 把这些列给用户,用户一选「720P」下回来的就是 11KB 的播放列表文本。
VideoQuality? _qualityFromEntry(Object? entry) {
  switch (entry) {
    case String text:
      final url = ParseResult._strOrNull(text);
      if (url == null || _isHlsPlaylist(url)) return null;
      return VideoQuality(url: url);
    case Map map:
      final url = ParseResult._strOrNull(
        map['url'] ?? map['play_url'] ?? map['video_url'],
      );
      if (url == null || _isHlsPlaylist(url)) return null;
      return VideoQuality(
        url: url,
        label: _labelFromMap(map),
        bitrate: ParseResult._intOrZero(
          map['bit_rate'] ?? map['real_bit_rate'] ?? map['bitrate'],
        ),
        size: ParseResult._intOrZero(map['size'] ?? map['file_size']),
      );
    default:
      return null;
  }
}

/// 从对象里读分辨率标签。
///
/// **数字档位优先**:上游各平台给法不一样,快手的 `video_backup[]` 是
/// `label=高清` + `quality=720p`(实测),抖音是 `label=720P高清` + `quality=720p`。
/// 只认 `label` 的话,同一份列表在快手上会出现「高清 / 540P」这种混搭,而且
/// 「高清」在别的平台上可能指的是另一档 —— 数字档位才跨平台一致、也才去得掉重。
///
/// 所以顺序是:`label`/`quality` 里**带数字的那个**先要;两个都没数字时,只要有
/// 宽高就用宽高算出来的档位(`原画` + 7680x3210 → `8K`);连宽高都没有才退回
/// 纯名字(`原画`)。
String _labelFromMap(Map map) {
  String? named;
  for (final key in const ['label', 'quality', 'definition', 'gear_name']) {
    final value = map[key];
    if (value is num) {
      final label = qualityLabelOfNumber(value);
      if (label.isNotEmpty) return label;
    }
    if (value is String) {
      final label = normalizeQualityLabel(value);
      if (label.isEmpty || _looksLikeUrl(label)) continue;
      // 归一化后带数字(720P)就是它;纯名字(高清/原画)先记着,后面没有更好的再用。
      if (RegExp(r'\d').hasMatch(label)) return label;
      named ??= label;
    }
  }
  // 「原画」这类名字里没有分辨率,但上游把真实宽高放在同一层 —— 用它算出来的档位
  // 替掉名字,用户才知道自己下的是 1080P 还是 8K(见 [_resolutionLabelOf])。
  if (named == null || _isOriginalName(named)) {
    final resolution = _resolutionLabelOf(
      map['width'] ?? map['w'],
      map['height'] ?? map['h'],
    );
    if (resolution.isNotEmpty) return resolution;
  }
  if (named != null) return named;
  return '';
}

/// 这一档名字是不是「原画」那类**不含分辨率**的最高档名。
///
/// 上游各平台写法不一:抖音根上是 `label`=`原画` + `quality`=`original`,
/// 快手根上只有 `quality`=`原画`(实测 2026-09-19)。名字里看不出是多少 P,
/// 所以只要同一层给了宽高就换成算出来的档位(见 [_resolutionLabelOf])。
const _kOriginalNames = <String>{'原画', '原片', '原视频', 'original', 'orig'};

bool _isOriginalName(String label) =>
    _kOriginalNames.contains(label.toLowerCase());

/// 宽高 → 档位名:`1920x1080` → `1080P`,`7680x4320` → `8K`。
///
/// 「多少 P」说的是**短边**:竖屏视频是 1080x1920,大家一样叫它 1080P
/// (和 [normalizeQualityLabel] 认交叉写法时的取法一致)。4K 及以上改按 K 叫 ——
/// 抖音那条 8K 原画的宽高是 7680x3210,短边 3210 写成「3210P」没有意义。
///
/// 认不出来(两边都没有,或短边超出常规档)返回空串,调用方退回原来的名字。
String _resolutionLabelOf(Object? width, Object? height) {
  final w = ParseResult._intOrZero(width);
  final h = ParseResult._intOrZero(height);
  final short = w > 0 && h > 0 ? (w < h ? w : h) : (w > 0 ? w : h);
  final long = w > h ? w : h;
  if (short <= 0) return '';
  if (long >= 3840) return '${(long / 960).round()}K';
  return short <= 2160 ? '${short}P' : '';
}

bool _looksLikeUrl(String value) {
  final lower = value.toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

/// 这是不是一条 HLS 播放列表地址(`.m3u8`)。
///
/// 只看路径后缀,不看 query —— 快手的地址形如
/// `…/xxx_hlsob.m3u8?x-kcdn-pid=…&pkey=…`,格式的判据在路径上。
bool _isHlsPlaylist(String url) {
  final path = Uri.tryParse(url)?.path ?? url;
  return path.toLowerCase().endsWith('.m3u8');
}

/// 一条视频。合集(`video_list`)里每一项一条。
class VideoItem {
  const VideoItem({
    required this.url,
    this.coverUrl,
    this.qualities = const [],
  });

  final String url;

  /// 这一条视频自己的封面(接口给的,不是播出来的首帧)。拿不到就是 null。
  final String? coverUrl;

  /// 这一条视频可选的清晰度档位,已经去过重、排好序(见 [dedupeQualities])。
  ///
  /// **只有第二个上游给得出**,media-parser 永远是空列表。空或只有一档时不该弹
  /// 分辨率选择窗 —— 没有第二个选项的弹窗只是多一次点击(见 lib/ui/popup.dart
  /// 的 showQualityPicker)。
  final List<VideoQuality> qualities;

  /// 能不能让用户选分辨率。两档以上才有得选。
  bool get hasQualityChoice => qualities.length > 1;
}

/// 一张实况图。
///
/// 抖音这类平台的实况图在 `image_list` 里是一对地址:静态图(`url`)+ 动态那段的
/// 视频(`live_photo_url`,下载下来是 MP4)。它**不是图片**,所以不归图集:
/// 下载地址是 MP4,就按视频算。静态图留着当缩略图用。
class LivePhoto {
  const LivePhoto({required this.videoUrl, this.thumbUrl});

  final String videoUrl;
  final String? thumbUrl;
}

/// 一条解析结果。
///
/// 取 MVP 需要的字段:视频(`video_url` 单条 + `video_list` 合集)、音频、文案,
/// 外加图集(`image_list`)。
class ParseResult {
  const ParseResult({
    required this.title,
    required this.desc,
    required this.platform,
    required this.authorName,
    this.videoUrl,
    this.coverUrl,
    this.audioUrl,
    this.imageUrls = const [],
    this.videos = const [],
    this.livePhotos = const [],
    this.primaryQualities = const [],
    this.lyrics = '',
  });

  factory ParseResult.fromJson(Map<String, dynamic> json) {
    // 接口字段可能缺、可能是 null,也可能类型不符(上游是第三方解析站),
    // 所以一律走 _str 兜底,别让一个意外类型把整个页面搞崩。
    final author = json['author'];
    final media = _mediaList(json['image_list']);
    final videoUrl = _strOrNull(json['video_url']);
    final coverUrl = _strOrNull(json['cover_url']);
    final videos = _videoList(json['video_list']);
    final livePhotos = <LivePhoto>[
      ...media.livePhotos,
      ..._liveList(json['live_photo_list']),
    ];
    return ParseResult(
      title: cleanCopyText(_str(json['title'])),
      desc: cleanCopyText(_str(json['desc'])),
      platform: _str(json['platform']),
      authorName: author is Map ? _str(author['nickname']) : '',
      videoUrl: videoUrl,
      coverUrl: coverUrl,
      audioUrl: absoluteMediaUrl(_strOrNull(json['audio_url'])),
      // 有没有视频决定 image_list 里那些"图"算不算图集,见 [_cleanImages]
      // 实况图不算 —— 它自带静态帧,帖子封面往往就是图集里的第一张真图,
      // 拿它当"视频封面"剔掉会平白少一张图(最右实况帖实测)。
      imageUrls: _cleanImages(
        media.images,
        coverUrl: coverUrl,
        hasVideo: videoUrl != null || videos.isNotEmpty,
      ),
      videos: videos,
      livePhotos: livePhotos,
      primaryQualities: _primaryQualities(json),
      lyrics: _lyricsOf(json),
    );
  }

  /// 上游应答 → 模型。字段名是实测出来的,和 media-parser 那套完全不一样。
  ///
  /// 实测抖音一条(2026-09 抓的真实应答,只留结构):
  /// ```json
  /// {"code":200,"data":{
  ///   "type":"video", "title":"…", "desc":"…",
  ///   "author":{"name":"作者名","id":"…","avatar":"…"},
  ///   "cover":"…", "url":"主视频地址", "label":"原画", "quality":"original",
  ///   "size":7807454953, "bit_rate":34698694, "width":7680, "height":3210,
  ///   "video_backup":[{"label":"720P高清","quality":"720p","url":"…",
  ///                    "bit_rate":1678555,"size":377687084,"width":1722,"height":720}, …],
  ///   "images":["图集地址", …],
  ///   "live_photo":[{"image":"静态帧","video":"动态那段 mp4"}, …]
  /// }}
  /// ```
  ///
  /// 三个要点:
  /// - 主地址在 `url` + `label` + `bit_rate`,**备选清晰度在 `video_backup`** ——
  ///   两处都要收进清晰度列表:主地址往往是最高档(实测「原画」34.7 Mbps),
  ///   只列 backup 的话用户就选不到它了。
  /// - 图集帖(`type` = `live`/`image`)的 `url` 是空的,媒体全在 `images` 和
  ///   `live_photo` 里。
  /// - 音频在 `music.url` 里(实测 2026-09-20:快手图集帖给 `.m4a`,抖音实况帖给
  ///   `.mp3`)。那个文件就是这条帖子的原声,收进 `audio_url` —— 不收的话音频卡
  ///   只能退回视频自带的那条音轨,用户拿不到上游已经给好的独立音频。
  ///
  /// 认得出是上游那套结构才按上游读,**不认就退回 [ParseResult.fromJson] 的读法**
  /// (见 [_isUpstreamFormat])。兜的是这种情况:反代或上游把 media-parser 那套应答
  /// 原样透传过来。不兜的话会映射出一个空结果,而空结果会被 [ParseService.parse]
  /// 判成「上游没解析出东西」再打一次兜底 —— 用户白等一个来回,还多花一次调用。
  factory ParseResult.fromUpstream(
    Map<String, dynamic> data, {
    String platform = '',
  }) {
    if (!_isUpstreamFormat(data)) return ParseResult.fromJson(data);

    final videoUrl = _strOrNull(data['url']);
    final coverUrl = _strOrNull(data['cover']);
    final author = data['author'];

    final backup = <VideoQuality>[];
    final rawBackup = data['video_backup'];
    if (rawBackup is List) {
      for (final item in rawBackup) {
        final q = _qualityFromEntry(item);
        if (q != null) backup.add(q);
      }
    }
    // 主地址自己也算一档。档位名和码率也在根上(`label` / `quality` / `bit_rate`;
    // 抖音给 label,快手只给 quality=`原画`)。走 [_labelFromMap] 是为了让根上
    // 这一档和 video_backup 用同一套读法 —— 包括「原画 + 宽高 → 1080P/8K」。
    final qualities = <VideoQuality>[
      if (videoUrl != null)
        VideoQuality(
          url: videoUrl,
          label: _labelFromMap(data),
          bitrate: _intOrZero(data['bit_rate'] ?? data['real_bit_rate']),
          size: _intOrZero(data['size']),
        ),
      ...backup,
    ];
    final deduped = dedupeQualities(qualities);

    final videos = <VideoItem>[
      if (videoUrl != null)
        VideoItem(url: videoUrl, coverUrl: coverUrl, qualities: deduped),
    ];

    // 图集:`images` 是纯地址字符串数组。上游用 `null` 占位(实测一条 9 张图的帖子
    // 里夹了一个 null),所以逐个过一遍 _strOrNull 把空值剔掉。
    final images = <String>[];
    final rawImages = data['images'];
    if (rawImages is List) {
      for (final item in rawImages) {
        final url = _strOrNull(item);
        if (url != null) images.add(url);
      }
    }

    // 实况图:`live_photo[]` 是一条静态帧 + 一段 mp4,正好对上 [LivePhoto] 的
    // 「下载这个 mp4、拿那个静态帧当缩略图」。
    final livePhotos = <LivePhoto>[];
    final rawLive = data['live_photo'];
    if (rawLive is List) {
      for (final item in rawLive) {
        if (item is! Map) continue;
        final video = _strOrNull(item['video']) ?? _strOrNull(item['url']);
        if (video == null) continue;
        livePhotos.add(
          LivePhoto(
            videoUrl: video,
            thumbUrl: _strOrNull(item['image']) ?? _strOrNull(item['cover']),
          ),
        );
      }
    }

    return ParseResult(
      title: cleanCopyText(_str(data['title'])),
      desc: cleanCopyText(_str(data['desc'])),
      // 上游自己会给一个 `platform` 字段(实测是 `douyin` 这种英文名)—— 那个
      // 直接给用户看不合适,所以优先用调用方传进来的中文名(见 ParseService.parse),
      // 没传才退回上游那个值。
      platform: platform.isNotEmpty ? platform : _str(data['platform']),
      authorName: _str(author is Map ? author['name'] : data['author_name']),
      videoUrl: videoUrl,
      coverUrl: coverUrl,
      audioUrl: absoluteMediaUrl(_upstreamAudioUrl(data)),
      imageUrls: _cleanImages(
        images,
        coverUrl: coverUrl,
        hasVideo: videoUrl != null,
      ),
      videos: videos,
      livePhotos: livePhotos,
      primaryQualities: deduped,
      lyrics: _lyricsOf(data),
    );
  }

  final String title;
  final String desc;
  final String platform;
  final String authorName;
  final String? videoUrl;
  final String? coverUrl;

  /// 独立的音频地址。两个上游都往这里映射:media-parser 的 `audio_url`、
  /// 上游的 `music`(见 [_upstreamAudioUrl])。空了音频卡才退回视频音轨。
  final String? audioUrl;

  /// 图集图片地址。顺序按上游给的原样保留(顺序就是用户在平台里看到的顺序)。
  final List<String> imageUrls;

  /// 合集视频。`video_list` 为空时是空列表。顺序同上,原样保留。
  final List<VideoItem> videos;

  /// 实况图。它们不是图片 —— 下载下来是 MP4,所以归到视频那一类,不进图集卡。
  final List<LivePhoto> livePhotos;

  /// 主视频(`video_url` 那一条)的可选清晰度。
  ///
  /// [videos] 里每一条自己也可能带 [VideoItem.qualities];这里是**单条
  /// `video_url`** 的那份。历史记录读回来也靠它 —— 存档时写的是
  /// `video_list`,见 [toJson]。
  final List<VideoQuality> primaryQualities;

  /// 歌词原文(LRC 或纯文本)。没有就是空串。
  ///
  /// **两个上游都不保证给**。实测(2026-09-27)汽水音乐那条链接两边都不回歌词,
  /// 应答里连字段都没有 —— 所以内嵌歌词这件事得先让服务端把 `lyrics` 加上
  /// (见 [_lyricsOf] 收的那几个键名)。收不到就是空,内嵌那一步会跳过歌词,
  /// 不影响封面/作者/标题。
  final String lyrics;

  /// 多视频:媒体卡列出两条以上视频就要走缩略图网格、取消播放器。
  ///
  /// 判据是 [_orderedVideos] 的条数,不是 `video_list` 的长度 —— 普通单视频链接
  /// 外挂一堆实况图时 `video_list` 是空的,但媒体卡该列出来的确实是三条。
  bool get hasMultiVideo => _orderedVideos.length > 1;

  /// 媒体卡该列出来的视频条目:主视频在前,`video_list` 合集其次,实况图最后。
  ///
  /// 普通单条链接只有 `video_url`,直接包一条;有多条时主视频也留着 —— 合集链接
  /// 里它是第一条,实况图链接里它是那条真视频。
  /// 实况图自带静态封面,拿它当缩略图 —— 那是这张实况图的第一帧。
  ///
  /// **按资源去重**,见 [_identityOf]:上游对合集/多视频会把主视频再放进 `video_list`
  /// 一次(接口文档写的是"首项与 video_url 相同",QQ 音乐实测两条一模一样),
  /// 照单全收媒体卡里第一条就会重复出现。
  List<VideoItem> get videoItems =>
      List<VideoItem>.unmodifiable(_orderedVideos);

  List<VideoItem> get _orderedVideos {
    final seen = <String>{};
    final ordered = <VideoItem>[];
    void add(VideoItem item) {
      if (seen.add(_identityOf(item.url))) ordered.add(item);
    }

    if (videoUrl != null) {
      // 主视频带上面那份清晰度:它是下载弹窗要用的东西(见 [primaryQualities])。
      add(
        VideoItem(
          url: videoUrl!,
          coverUrl: coverUrl,
          qualities: _qualitiesFor(videoUrl!),
        ),
      );
    }
    for (final v in videos) {
      add(v);
    }
    for (final p in livePhotos) {
      add(VideoItem(url: p.videoUrl, coverUrl: p.thumbUrl));
    }
    return ordered;
  }

  /// 地址为 [url] 的那一条该配哪份清晰度。
  ///
  /// `video_list` 里已经带了同一条地址时用它的 —— 那是上游自己挂在视频对象上的,
  /// 比根上的 `primaryQualities` 更贴切。没带才退回根上那份。
  List<VideoQuality> _qualitiesFor(String url) {
    final id = _identityOf(url);
    for (final v in videos) {
      if (_identityOf(v.url) == id && v.qualities.isNotEmpty) {
        return v.qualities;
      }
    }
    return primaryQualities;
  }

  bool get hasVideo =>
      videoUrl != null || videos.isNotEmpty || livePhotos.isNotEmpty;
  bool get hasAudio => audioUrl != null;

  /// 有没有图集可看。实况图不算 —— 它是视频,只有下载下来是图片的才算图集。
  bool get hasImages => imageUrls.isNotEmpty;

  /// 有没有文案可看。
  ///
  /// 只看描述 —— 标题和作者在文案卡上不显示,不算「有文案」。
  /// 描述为空时整张文案卡都不该出现。
  bool get hasCopy => desc.isNotEmpty;

  /// 主视频:播放器和「单条下载」都只认这一个入口。
  ///
  /// 不能直接读 `video_url` 字段 —— 实况帖那个字段是 **null**,视频只存在于
  /// `image_list[].live_photo_url` 里(实测 https://v.douyin.com/87q9bOkq0bs/:
  /// cover_url 有、audio_url 有、video_url 为 null,image_list 是一条实况)。
  /// 早先播放器与下载各自读 `videoUrl`,那条链接的表现就是:有封面、点不播放、
  /// 不显示时长(播放器拿到空地址)、下载按钮点了没反应。
  ///
  /// 只有一条 `video_list`、没有 `video_url` 的链接同理 —— 也走这里。
  VideoItem? get primaryVideo =>
      _orderedVideos.isEmpty ? null : _orderedVideos.first;

  /// 主视频地址。没有可播的视频时是 null。
  ///
  /// 下载用这个(或者用户在清晰度弹窗里选的那一档)。**预览不该用它** —— 见
  /// [previewVideoUrl]。
  String? get primaryVideoUrl => primaryVideo?.url;

  /// 预览该播哪一条。多档清晰度时给**最低码率**那一档。
  ///
  /// 为什么不让预览播主地址:上游给的主地址往往是最高档。实测那条抖音是
  /// **8K / 34.7 Mbps / 7.27GB**,而预览用的 ExoPlayer 是按「秒数」缓冲的 ——
  /// 34 Mbps 缓冲几十秒就是 200MB 上下,真机上直接把 256MB 的 Java 堆吃光,
  /// 报 `java.lang.OutOfMemoryError` 然后闪退(tombstone 实测:
  /// target footprint 268435456)。低码率那档是 1.7 Mbps,同样几十秒只要 10MB。
  ///
  /// 用户下载时仍然可以在弹窗里选原画 —— 只是"看"和"存"用不同的档,这也是
  /// 各家播放器的常规做法。
  ///
  /// 只有一档(media-parser 的结果)时就是那一档本身,行为跟以前一致。
  String? get previewVideoUrl {
    final video = primaryVideo;
    if (video == null) return null;
    if (video.qualities.isEmpty) return video.url;
    // qualities 是按档位从高到低排的(见 [dedupeQualities]),所以最后一条最低。
    return video.qualities.last.url;
  }

  /// 主视频的封面。实况图用它自己的静态帧,其余用接口给的 `cover_url`。
  String? get primaryVideoCoverUrl => primaryVideo?.coverUrl ?? coverUrl;

  /// 接口给了**独立的**音轨。
  ///
  /// 两个条件都要:`audio_url` 有值,而且它不能**就是视频地址** —— 上游有平台在拿不到
  /// 纯音频时把视频地址回填进 `audio_url`(汽水音乐拿 `main_url`、豆包同款),那种
  /// 「音频」下下来是一段有画面有声音的 MP4。
  ///
  /// **APP 的音频卡就是按它出现的**(见 lib/pages/preview.dart 的 `PreviewKind.forResult`):
  /// 没有独立音轨就只呈现视频卡。这样「点下载音频」永远不会落下一个视频文件 ——
  /// 面板呈现什么,完全由接口返回的东西决定。
  ///
  /// 拿 [primaryVideoUrl] 而不是 `videoUrl` 比:实况帖那个字段是 null(视频只在实况
  /// 里),只有 `video_list` 的链接同理。
  bool get hasStandaloneAudio =>
      audioUrl != null && audioUrl != primaryVideoUrl;

  /// 文案卡显示的内容,也是「复制文案」复制的东西。
  ///
  /// 只取描述:标题和作者不上卡片,复制时也不带 —— 用户要的就是那段文案。
  String get copyText => desc;

  /// 换一个平台名,其余原样。上游没给 `platform` 时用它补(见 [_request])。
  ParseResult withPlatform(String value) => ParseResult(
    title: title,
    desc: desc,
    platform: value,
    authorName: authorName,
    videoUrl: videoUrl,
    coverUrl: coverUrl,
    audioUrl: audioUrl,
    imageUrls: imageUrls,
    videos: videos,
    livePhotos: livePhotos,
    primaryQualities: primaryQualities,
  );

  /// 存历史用。字段名和 [ParseResult.fromJson] 对齐,能原样读回来 ——
  /// 包括 `image_list`、`video_list` 和实况图,漏了历史里就会变成空。
  ///
  /// 清晰度列表跟着 `video_list` 走(见 [_qualityList] 的读法)。没有清晰度的
  /// 视频不带这个键 —— 老记录读回来也是空列表,不会变成「有分辨率可选的旧记录」。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'title': title,
    'desc': desc,
    'platform': platform,
    'author': <String, dynamic>{'nickname': authorName},
    'video_url': videoUrl,
    'cover_url': coverUrl,
    'audio_url': audioUrl,
    'lyrics': lyrics,
    'image_list': imageUrls,
    // 根上那份(单条 `video_url` 的清晰度)单独存:它可能不在 `video_list` 里,
    // 只存 video_list 的话历史记录读回来就没有分辨率可选了。
    'qualities': <Map<String, dynamic>>[
      for (final q in primaryQualities)
        <String, dynamic>{
          'url': q.url,
          'quality': q.label,
          'bit_rate': q.bitrate,
          'size': q.size,
        },
    ],
    'video_list': <Map<String, dynamic>>[
      for (final v in videos)
        <String, dynamic>{
          'url': v.url,
          'cover_url': v.coverUrl,
          if (v.qualities.isNotEmpty)
            'qualities': <Map<String, dynamic>>[
              for (final q in v.qualities)
                <String, dynamic>{
                  'url': q.url,
                  'quality': q.label,
                  'bit_rate': q.bitrate,
                  'size': q.size,
                },
            ],
        },
    ],
    'live_photo_list': <Map<String, dynamic>>[
      for (final p in livePhotos)
        <String, dynamic>{'live_photo_url': p.videoUrl, 'url': p.thumbUrl},
    ],
  };

  /// 去掉上游回填的「伪图片」,顺手按资源去重。
  ///
  /// 快手纯视频链接实测:`image_list` 是 `[封面, 封面]` —— 两条一模一样,就是
  /// `cover_url`。照单全收就会判成「又有视频又有图」,卡片变成混合预览,网格里
  /// 两格还是同一张封面(点哪格都是封面)。
  ///
  /// 规则:先按资源去重(见 [_identityOf]);有视频时再把与封面同一个资源的那些
  /// 去掉 —— 那是视频的封面,不是一张能单独下载的图。纯图集(没有视频)不动:
  /// 图集的封面本来就等于第一张图。
  ///
  /// 这里的"有视频"只算真能播的视频(`video_url` / `video_list`),**不含实况图**:
  /// 实况图的静态帧在 `image_list` 里是带 `live_photo_url` 的对象,本来就进不了
  /// `images`;而帖子封面常常就是图集第一张真图(最右实测),把实况算成"有视频"
  /// 会把那张真图当封面剔掉。
  static List<String> _cleanImages(
    List<String> images, {
    required String? coverUrl,
    required bool hasVideo,
  }) {
    final cover = coverUrl == null ? '' : _identityOf(coverUrl);
    final seen = <String>{};
    final cleaned = <String>[];
    for (final url in images) {
      final id = _identityOf(url);
      if (!seen.add(id)) continue;
      if (hasVideo && id == cover) continue;
      cleaned.add(url);
    }
    return cleaned;
  }

  /// 同一个资源的判据:**去掉 scheme / host / query,只比路径**。
  ///
  /// 平台给同一张图的不同尺寸、不同签名,差别只在 host 或 query 上 —— 实测遇到过
  /// 同一张图:封面挂在一台 CDN、`image_list` 里那条挂在另一台,路径完全相同,
  /// HEAD 回来字节数也一样。只比整串就会漏掉,于是视频封面被当成一张可下载的图,
  /// 卡片又变回混合预览。
  static String _identityOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    return uri.path.isEmpty ? url : uri.path;
  }

  static String _str(Object? value) => _strOrNull(value) ?? '';

  /// 从 `image_list` 里分出来的两堆东西:真图片和实况图。
  static ({List<String> images, List<LivePhoto> livePhotos}) _mediaList(
    Object? value,
  ) {
    if (value is! List) {
      return (images: const <String>[], livePhotos: const <LivePhoto>[]);
    }
    final images = <String>[];
    final livePhotos = <LivePhoto>[];
    for (final item in value) {
      switch (item) {
        case String text:
          final url = _strOrNull(text);
          if (url != null) images.add(url);
        case Map map:
          final url = _strOrNull(map['url']);
          // 有 live_photo_url 就是实况图:主地址是静态图(留着当缩略图),
          // 真用来下载的是那个 MP4。
          final live = _strOrNull(map['live_photo_url']);
          if (live != null) {
            livePhotos.add(LivePhoto(videoUrl: live, thumbUrl: url));
          } else if (url != null) {
            images.add(url);
          }
        default:
          break;
      }
    }
    return (images: images, livePhotos: livePhotos);
  }

  /// 上游应答里那条**独立音频**的地址。
  ///
  /// 实测(2026-09-20)上游把音频放在 `music` 里:快手图集帖是 `.m4a`、抖音实况帖
  /// 是 `.mp3`,两个都是这条帖子的原声。字段形态不止一种,所以三道都收:
  ///   1. 直接给地址的字段(`audio_url` / `audio` / `sound_url` …);
  ///   2. `music` —— 对象 `{title, author, url, cover}` 或一个纯地址字符串;
  ///   3. 都没有(`music` 是空对象 `{}`,豆包 AI 音乐分享实测就是这样)→ null,
  ///      没有独立音轨,音频卡不出现(只呈现视频卡)。
  static String? _upstreamAudioUrl(Map<String, dynamic> data) {
    for (final key in const <String>[
      'audio_url',
      'audio',
      'music_url',
      'sound_url',
      'music',
    ]) {
      final url = _audioUrlOf(data[key]);
      if (url != null) return url;
    }
    return null;
  }

  /// 一个音频字段的值 → 地址。字符串直接用;对象里找那几个常见的地址键。
  static String? _audioUrlOf(Object? value) {
    switch (value) {
      case String text:
        return _strOrNull(text);
      case Map map:
        for (final key in const <String>['url', 'play_url', 'audio_url']) {
          final url = _strOrNull(map[key]);
          if (url != null) return url;
        }
        return null;
      default:
        return null;
    }
  }

  /// 应答里的歌词原文(LRC 或纯文本)。没有就是空串。
  ///
  /// 键名各家叫法不一,常见的几个都收 —— 服务端加歌词时叫什么名字就不用再来改
  /// 客户端。**单个键名可能是数组**(有的接口给 `["第一行","第二行"]`),那种也
  /// 按行拼起来,总比整条丢掉强。
  ///
  /// 这里**不洗文本**(不走 `cleanCopyText`):歌词里的标点连打、表情、换行都是
  /// 原文的一部分,压一遍就不是用户看到的那首歌词了。
  static String _lyricsOf(Map<String, dynamic> data) {
    for (final key in const <String>[
      'lyrics',
      'lyric',
      'lrc',
      'lyric_text',
      'lyricText',
    ]) {
      final value = data[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is List) {
        final lines = [
          for (final line in value)
            if (line is String && line.trim().isNotEmpty) line.trim(),
        ];
        if (lines.isNotEmpty) return lines.join('\n');
      }
    }
    return '';
  }

  /// 独立的实况图字段。万一上游把实况图单独列一份(而不是塞在 `image_list` 里),
  /// 这里也收得下。
  static List<LivePhoto> _liveList(Object? value) {
    if (value is! List) return const [];
    final photos = <LivePhoto>[];
    for (final item in value) {
      switch (item) {
        case String text:
          final url = _strOrNull(text);
          if (url != null) photos.add(LivePhoto(videoUrl: url));
        case Map map:
          final live =
              _strOrNull(map['live_photo_url']) ??
              _strOrNull(map['video_url']) ??
              _strOrNull(map['play_url']);
          if (live != null) {
            photos.add(
              LivePhoto(
                videoUrl: live,
                thumbUrl:
                    _strOrNull(map['url']) ?? _strOrNull(map['cover_url']),
              ),
            );
          }
        default:
          break;
      }
    }
    return photos;
  }

  /// 合集视频列表。元素和 `image_list` 一样脏:可能是地址字符串,也可能是对象。
  /// 对象里的地址字段各家叫法不一(`url` / `play_url` / `video_url`),都收;
  /// 没有可用地址的元素跳过,不让它变成一格点不动的空缩略图。
  ///
  /// 第二个上游在这里多给一份清晰度列表(见 [_qualityList]),归到
  /// [VideoItem.qualities] 上 —— 那是下载前弹分辨率选择窗的唯一依据。
  static List<VideoItem> _videoList(Object? value) {
    if (value is! List) return const [];
    final videos = <VideoItem>[];
    for (final item in value) {
      final (url: url, cover: cover) = switch (item) {
        String text => (url: _strOrNull(text), cover: null),
        Map map => (
          url:
              _strOrNull(map['url']) ??
              _strOrNull(map['play_url']) ??
              _strOrNull(map['video_url']),
          cover: _strOrNull(map['cover_url']) ?? _strOrNull(map['cover']),
        ),
        _ => (url: null, cover: null),
      };
      final qualities = dedupeQualities(_qualityList(item));
      // 主地址缺失时用最高那档顶上:单独给了一份清晰度列表、却没给 `url` 的
      // 应答不该被整条丢掉。
      final primary = url ?? (qualities.isEmpty ? null : qualities.first.url);
      if (primary == null) continue;
      videos.add(
        VideoItem(url: primary, coverUrl: cover, qualities: qualities),
      );
    }
    return videos;
  }

  static String? _strOrNull(Object? value) {
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return null;
  }

  /// 数字字段的兜底读法。上游可能是 int、double,也可能是字符串("1080"),
  /// 读不出来一律当 0 —— 码率/体积这些字段缺失只是少一行说明,不该让页面崩。
  static int _intOrZero(Object? value) {
    switch (value) {
      case int n:
        return n;
      case double n:
        return n.isFinite ? n.toInt() : 0;
      case String text:
        return int.tryParse(text.trim()) ?? 0;
      default:
        return 0;
    }
  }
}

/// 平台拿「还没加载出来」的占位文案当正文回填时,这些话不是文案。
///
/// 今日头条实测:`desc` = `视频加载中...`,文案窗口和「复制文案」都会给出一句废话。
/// 命中就当没有文案(见 [ParseResult.hasCopy])。
const Set<String> _kPlaceholderCopies = <String>{
  '视频加载中',
  '视频加载中...',
  '视频加载中…',
  '分享视频',
  '网页链接',
  '暂无文案',
  '暂无简介',
};

/// 清掉平台回填在文案里的噪声,并把双重转义的换行还原成真的换行。
///
/// 快手实测的 `desc`(jsonDecode 之后):
/// `#媒体原创\n云南一名00后女孩…索赔15万元。（yn）\n#国红山泉 #农夫山泉`
/// 原样显示出来就是文案里夹着 `（yn）` 和成串空行。
///
/// 有些链接上游是双重转义的 —— `\n` 是两个字符(反斜杠 + n),那种也要还原,
/// 否则文案窗口里会明晃晃地打出 `\n`。这一条是**防御性**的:实测这几批真实应答
/// (抖音/快手/微博/头条…)上游给的都是真换行,但中文文案里出现字面 `\n`
/// 基本不可能是本意,顺手还原没有副作用。
String cleanCopyText(String raw) {
  var text = raw
      // 双重转义先还原
      .replaceAll(r'\r\n', '\n')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\t', '\t')
      // 平台自己的标记:快手会在句尾塞一个「(yn)」
      .replaceAll(RegExp(r'[（(]\s*yn\s*[)）]', caseSensitive: false), '')
      // 统一换行
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  // 行尾空格清掉,连续空行压成一行
  text = text.split('\n').map((line) => line.trimRight()).join('\n');
  text = text.replaceAll(RegExp(r'\n{2,}'), '\n').trim();
  // 占位文案当成没有文案
  return _kPlaceholderCopies.contains(text) ? '' : text;
}
