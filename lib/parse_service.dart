import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'api_host.dart';
import 'preferred_ip.dart';
import 'secrets.dart';

/// 解析失败。message 已经是可以直接给用户看的中文句子。
class ParseException implements Exception {
  ParseException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 视频的一档清晰度。
///
/// 只有上游(BugPk,见 [ParseService.upstreamPaths])会给这个东西:它把同一条
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
/// 最后再按**资源**去一次重(见 [_resourceId]):快手实测同一条 720P 会在
/// `video_backup` 里出现两遍,地址只差 query 里的签名,路径完全一样。这种两条
/// 并排摆出来,用户看到的是两行一模一样的「720P」。
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

  final seen = <String>{};
  final out = <VideoQuality>[];
  for (final q in [...known, ...unknown]) {
    if (seen.add(_resourceId(q.url))) out.add(q);
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

/// 这是不是上游(BugPk)那套结构。
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
VideoQuality? _qualityFromEntry(Object? entry) {
  switch (entry) {
    case String text:
      final url = ParseResult._strOrNull(text);
      return url == null ? null : VideoQuality(url: url);
    case Map map:
      final url = ParseResult._strOrNull(
        map['url'] ?? map['play_url'] ?? map['video_url'],
      );
      if (url == null) return null;
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
/// 所以顺序是:`label`/`quality` 里**带数字的那个**先要;两个都没数字才退回
/// 纯名字(`原画`);连名字都没有才看 `height`。
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
  if (named != null) return named;
  // 都没有才看高度。上限卡 2160:再大是竖屏/超宽屏的宽边被当成高了。
  final height = ParseResult._intOrZero(map['height'] ?? map['h']);
  if (height > 0 && height <= 2160) return '${height}P';
  return '';
}

bool _looksLikeUrl(String value) {
  final lower = value.toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
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
  /// 分辨率选择窗 —— 没有第二个选项的弹窗只是多一次点击(见 main.dart)。
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
      audioUrl: _strOrNull(json['audio_url']),
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
    );
  }

  /// 上游(BugPk)应答 → 模型。字段名是实测出来的,和 media-parser 那套完全不一样。
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
    // 主地址自己也算一档。标签和码率也在根上(`label` / `bit_rate`)。
    final qualities = <VideoQuality>[
      if (videoUrl != null)
        VideoQuality(
          url: videoUrl,
          label: normalizeQualityLabel(_str(data['label'])),
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
      audioUrl: _upstreamAudioUrl(data),
      imageUrls: _cleanImages(
        images,
        coverUrl: coverUrl,
        hasVideo: videoUrl != null,
      ),
      videos: videos,
      livePhotos: livePhotos,
      primaryQualities: deduped,
    );
  }

  final String title;
  final String desc;
  final String platform;
  final String authorName;
  final String? videoUrl;
  final String? coverUrl;

  /// 独立的音频地址。两个上游都往这里映射:media-parser 的 `audio_url`、
  /// 上游(BugPk)的 `music`(见 [_upstreamAudioUrl])。空了音频卡才退回视频音轨。
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

  /// 音频预览该放什么。
  ///
  /// 优先用接口给的 `audio_url` —— 那是一份独立的音频文件。实测这条抖音链接:
  /// 视频 360MB / URL 里标着 1.6Mbps → 约 30.7 分钟;音频 27.5MB 的 mp3 →
  /// 约 28.7 分钟。两者对得上,audio_url 就是这段视频完整的音轨。
  ///
  /// 早先这里优先返回 videoUrl,理由是「audio_url 只是背景音乐」——那个判断是错的:
  /// 当时看到的「音频只有 17 秒」其实是**换链接后播放器没重载**残留的上一条数据
  /// (见 _AudioStage.didUpdateWidget),不是 audio_url 的真实时长。
  ///
  /// 只有接口确实没给 audio_url 时才退回视频本身(视频自带音轨,一样能听)。
  ///
  /// 注意这里退回的是 `videoUrl` 字段,不是 [primaryVideoUrl] —— 实况帖**没有**
  /// audio_url 时就没有音频卡(媒体卡那个播放器本身带声音)。改成 primaryVideoUrl
  /// 会给「只有 video_list 的多视频合集」也凭空加出一张音频卡,那是另一件事。
  String? get audioSource => audioUrl ?? videoUrl;

  /// 音频卡放的是不是接口给的独立音频文件。不是的话就是退回视频了。
  bool get hasStandaloneAudio => audioUrl != null;

  /// 有没有可听的东西。视频自带音轨,所以有视频就算有音频。
  bool get hasPlayableAudio => audioSource != null;

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
  /// 平台给同一张图的不同尺寸、不同签名,差别只在 host 或 query 上 —— 得物实测:
  /// 封面在 `image-cdn.dewu.com`,而 `image_list` 里那条在 `image-cdn.poizon.com`,
  /// 路径完全相同,HEAD 回来字节数也一样(181450)。只比整串就会漏掉,于是
  /// 视频封面被当成一张可下载的图,卡片又变回混合预览。
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
  ///      音频卡退回视频自带的那条音轨(见 [ParseResult.audioSource])。
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
  /// 第二个上游(BugPk)在这里多给一份清晰度列表(见 [_qualityList]),归到
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
/// (抖音/快手/微博/得物/头条…)上游给的都是真换行,但中文文案里出现字面 `\n`
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

/// 解析服务。
///
/// 两条路:
/// - **上游聚合接口(BugPk 国内站点)**:抖音 / 快手 / 微信视频号 / 豆包 先走这里。
///   APP **直连**它,不经我们自己的服务器 —— 中间那跳只会加一个来回,而它并不
///   参与下载(下载是手机直连 CDN),所以去掉它只有好处。
///   代价是密钥必须编译进客户端(见 [upstreamApiKey]),反编译能拿到。
/// - **media-parser**:我们自建的那个,什么链接都吃。四个平台上游失败时兜底,
///   其余平台直接走它。
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
  /// 由 nginx 提供,配置见 deploy/nginx-mxper.cc.cd.conf。这条**仍然经过我们自己
  /// 的服务器**:media-parser 是我们自建的服务,密钥由 nginx 注入,不下发客户端。
  ///
  /// 域名不写死:用 [apiHost] —— 它可能已经被服务端下发的新域名换掉了(域名被
  /// 运营商阻断时,换域名是唯一的出路,见 api_host.dart)。
  static String get endpoint => apiUrl('/parse');

  /// 上游聚合接口的站点(BugPk)。**APP 直连,不经我们的服务器。**
  ///
  /// 两个站点都实测过,差别**不在解析快慢,而在签出来的下载 CDN**:
  ///
  /// | 站点 | 原画 | 720P / 540P |
  /// |---|---|---|
  /// | 国内 `api-new.ifphp.com` | ixigua | **volcautovod.com(火山,国内 CDN)** |
  /// | 国外 `api-new.bugpk.com` | ixigua | ixigua |
  ///
  /// ixigua 那批地址在**移动数据上不可用**(运营商按域名掐):表现是预览播放器
  /// 初始化不了(卡片上没有时长)、点下载进度不动。所以只要用户在移动数据上,
  /// 就必须用国内站点 —— 它把非原画那几档换成了国内 CDN。
  ///
  /// 原画那档两个站点都只从 ixigua 签,移动数据下仍然不可用 —— 这是上游的取流
  /// 策略,我们改不了。要根治得让上游给原画也签国内 CDN。
  ///
  /// 换站点只改这一行 + [upstreamApiKey],APP 逻辑不动。
  static const String upstreamBase = 'https://api-new.ifphp.com';

  /// 上游的密钥。
  ///
  /// **编译进客户端了** —— 这是刻意的取舍:直连省掉中间那一跳(少一个来回),
  /// 代价是反编译 APK 能拿到这个 key。换 key 需要重新发版(以前是改服务器上的
  /// 文件就行)。上游站点按 key 计费,别把它贴到公开地方。
  ///
  /// 真值在本地私有的 `lib/secrets.dart`(已 gitignore),模板见
  /// `lib/secrets.example.dart`。缺这个文件时是空串,四个平台自动落到
  /// media-parser 兜底,不影响编译。
  static const String upstreamApiKey = bugpkApiKey;

  /// 平台 → 上游那条接口的完整地址。
  ///
  /// 上游**每个平台一条独立接口**,拿错平台的链接去问会回 422「解析参数与该平台
  /// 不匹配」,所以一条路对一个平台。
  ///
  /// **这张表就是「先走上游」的名单**:在表里的先打上游,失败(或表里没有)才走
  /// media-parser。加一个平台 = 这里加一行。
  static const Map<ParsePlatform, String> upstreamPaths =
      <ParsePlatform, String>{
        ParsePlatform.douyin: '$upstreamBase/api/dyjx',
        ParsePlatform.kuaishou: '$upstreamBase/api/ksjx',
        ParsePlatform.wechatChannels: '$upstreamBase/api/wxsph',
        ParsePlatform.doubao: '$upstreamBase/api/doubao',
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
  /// - 在 [upstreamPaths] 里的平台(抖音 / 快手 / 微信视频号 / 豆包)→ 先打上游
  ///   对应平台那条路;
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
    final upstream = upstreamPaths[platform];
    if (upstream != null) {
      ParseException? upstreamError;
      try {
        final result = await _request(
          upstream,
          shareUrl,
          _upstreamTimeout,
          fromUpstream: true,
          platformHint: platform.label,
        );
        if (result.hasVideo || result.hasImages || result.hasAudio) {
          lastRoute = 'upstream:${platform.name}';
          return result;
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

  /// 打一个上游,把应答翻成 [ParseResult]。
  ///
  /// [fromUpstream] 为真表示这是 BugPk 那条路,它的应答结构是另一套(见
  /// [ParseResult.fromUpstream]),而且要带上密钥头。
  Future<ParseResult> _request(
    String endpoint,
    String shareUrl,
    Duration timeout, {
    bool fromUpstream = false,
    String? platformHint,
  }) async {
    final uri = Uri.parse(endpoint).replace(queryParameters: {'url': shareUrl});
    // 只有上游那条路要密钥:media-parser 的密钥由我们自己在 nginx 上注入,
    // 客户端手里没有(也不该有)。
    final headers = fromUpstream
        ? const <String, String>{'X-API-Key': upstreamApiKey}
        : null;
    Future<http.Response> retryWithSystemClient() async {
      final fallback = http.Client();
      try {
        return await fallback.get(uri).timeout(timeout);
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
      if (headers == null && _client is IOClient) {
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
      // 兜底接口只重试一次标准连接;上游接口保持原有行为,不重复请求。
      if (headers == null && _client is IOClient) {
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
      final data = _dataOf(body) as Map<String, dynamic>;
      return fromUpstream
          ? ParseResult.fromUpstream(data, platform: platformHint ?? '')
          : ParseResult.fromJson(data);
    }

    // 关键:上游解析失败时用的是 HTTP 400 + retdesc,不是 200 + succ:false。
    // 所以不能拿状态码当结论 —— 那样只会弹出一句没用的「服务器异常(400)」,
    // 把 retdesc 里真正的原因(版权限制、链接失效、平台不支持)全丢掉。
    //
    // BugPk 那套用 `error` / `message`(实测:422「解析参数与该平台不匹配」),
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
/// media-parser 那边还认一堆别的平台(微博、得物、头条…),它们都归到
/// [ParsePlatform.unknown]。
enum ParsePlatform {
  douyin('抖音'),
  kuaishou('快手'),
  doubao('豆包'),
  wechatChannels('微信视频号'),

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
  final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
  if (host.isEmpty) return ParsePlatform.unknown;
  for (final entry in _kPlatformHosts.entries) {
    if (host == entry.key || host.endsWith('.${entry.key}')) {
      return entry.value;
    }
  }
  return ParsePlatform.unknown;
}

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
  final match = RegExp(r'https?://\S+', caseSensitive: false).firstMatch(raw);
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
