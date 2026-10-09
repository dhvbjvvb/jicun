import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'cover_cache.dart';

/// 要写进音频文件里的东西。
///
/// 空字段就是"没有",不会写成空标签 —— 播放器看到空标题反而会显示成一片空白。
class AudioTagInfo {
  const AudioTagInfo({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.lyrics = '',
    this.coverUrl = '',
  });

  final String title;
  final String artist;

  /// 专辑名。解析出来的结果里暂时没有这个字段,留着是为了以后上游给了不用再改结构。
  final String album;

  /// 要内嵌的歌词原文(LRC 或纯文本),**带着时间轴**写进去。MP4 里写**两份**
  /// (`©lyr` 与 `©des`),两份放的是同一份文本。
  ///
  /// **为什么两个字段都写、而且都留时间轴**(2026-10-06 在用户手机上逐条验的):
  /// 播放器读哪个字段、认不认没有时间轴的歌词,各家不一样,同一个播放器对不同
  /// 来源的文件也不一样 ——
  ///   - NeriPlayer 读**同一个文件的两份拷贝**,一份拿到 `©des`(带时间轴)、
  ///     一份只拿到 `©lyr`(无时间轴);而它能滚动显示歌词的那种情况,歌词是
  ///     带时间轴的。我们把时间轴剥掉的那些文件,它的歌词页就是一片空白。
  ///   - 只写 `©des` 也救不了只读 `©lyr` 的那条路。
  /// 所以:同一份**带时间轴**的歌词同时写进 `©lyr` 与 `©des`。ID3 那条路只有
  /// 一个 `USLT`,同样写这一份(见 [_id3Lyrics])。
  ///
  /// 代价:不解析 LRC、把标签原样显示出来的播放器会把 `[00:02.63]` 当正文一起
  /// 显示。那种播放器本来也显示不出歌词,两害相权取其轻。
  final String lyrics;

  /// 封面地址。抓下来的是原图字节,直接内嵌。
  final String coverUrl;

  bool get isEmpty =>
      title.isEmpty &&
      artist.isEmpty &&
      album.isEmpty &&
      lyrics.isEmpty &&
      coverUrl.isEmpty;
}

/// 封面超过这个大小就不内嵌。
///
/// 封面是拿来做缩略图的,正常几百 KB 顶天(汽水那条 375x375 的 jpg 只有几十 KB)。
/// 几 MB 的"封面"要么是选错了文件,要么是把整张海报塞进来了 —— 那会让音频文件
/// 白白胖一大截,而播放器多半还是不显示。
const int _maxCoverBytes = 4 << 20;

/// 超过这个大小的音频不写标签。
///
/// MP4 那条路要把整个文件读进内存、再拼一份新的出来(见 [writeMp4Tag]),峰值是
/// 文件大小的两倍。歌曲都是几 MB,但上游给的"音频"也可能是整场录音 —— 那种情况
/// 下为了几个标签把堆吃爆不值当,直接跳过。
/// 16MB 而不是 64MB:这个上限就是**堆峰值的一半**,而写标签发生在"刚下完、预览
/// 播放器还活着"的时刻,那时候堆里本来就有下载缓冲和播放器缓冲。64MB 意味着峰值
/// 128MB,在一台已经开着 8K 预览的手机上正好是压垮的那一下。真要根治得让
/// [writeMp4Tag] 改成按块搬运(只动 moov),那之前先把天花板压下来。
const int _maxTagFileBytes = 16 << 20;

/// 给一条已经落盘的音频写标签。返回是否真的写了。
///
/// **只碰音频,只认 MP4 系和 MP3**,别的容器一个字节都不改 —— 写坏一个用户刚下好
/// 的文件,比没有标签糟得多。
///
/// **不抛异常**:标签是装饰,下载本身不能因为它失败。封面抓不到、文件头认不出、
/// 磁盘写不动,一律记一条 debug 日志然后原样返回 false,让调用方照常把没标签的
/// 文件登记进媒体库。
Future<bool> embedAudioTags(
  File file,
  AudioTagInfo tags, {
  required String ext,
}) async {
  if (tags.isEmpty) return false;
  try {
    if (file.lengthSync() > _maxTagFileBytes) return false;
    final cover = await _coverBytes(tags.coverUrl);
    final source = await file.readAsBytes();
    final tagged = switch (ext.toLowerCase()) {
      '.mp3' => writeId3Tag(source, tags, cover),
      '.m4a' || '.mp4' || '.mov' => writeMp4Tag(source, tags, cover),
      _ => null,
    };
    if (tagged == null || identical(tagged, source)) return false;
    // 先写临时文件再改名:中途失败(磁盘满、进程被杀)留下的最坏是一个 .tagging
    // 垃圾文件,已经下好的那份还在原地。
    final temp = File('${file.path}.tagging');
    await temp.writeAsBytes(tagged, flush: true);
    await temp.rename(file.path);
    return true;
  } catch (error, stack) {
    if (kDebugMode) {
      debugPrint('[tag] 写标签失败,保留原文件:${file.path}\n$error\n$stack');
    }
    return false;
  }
}

/// 封面图字节。没有就算了,不阻断其余标签。
///
/// 走 [CoverCache] —— 预览卡片早就把这张封面抓下来存好了,这里多半只是读一次
/// 本地文件,不额外发请求。
Future<List<int>?> _coverBytes(String url) async {
  if (url.isEmpty) return null;
  var cached = CoverCache.fileFor(url);
  if (cached == null) {
    await CoverCache.store(url);
    cached = CoverCache.fileFor(url);
  }
  if (cached == null) return null;
  try {
    final bytes = await cached.readAsBytes();
    if (bytes.isEmpty || bytes.length > _maxCoverBytes) return null;
    return _imageKind(bytes) == null ? null : bytes;
  } catch (_) {
    return null;
  }
}

/// 认得出的图片类型。认不出返回 null —— 认不出就不写 `covr`/`APIC`,写一个
/// 类型标错的封面比不写更糟。
enum _ImageKind { jpeg, png }

_ImageKind? _imageKind(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return _ImageKind.jpeg;
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return _ImageKind.png;
  }
  return null;
}

// ---------------------------------------------------------------------------
// MP4 / M4A
// ---------------------------------------------------------------------------

/// 标签盒子的名字。`©` 在盒子里就是字节 0xA9,这里靠 Dart 把 0xA9 当成码位
/// 原样映射,所以写出来正好是那四个字节。
const String _kNam = '\u00A9nam';
const String _kArt = '\u00A9ART';
const String _kAlb = '\u00A9alb';
const String _kLyr = '\u00A9lyr';
const String _kDes = '\u00A9des';
const String _kCovr = 'covr';

/// 往 MP4 / M4A 里写 `moov.udta.meta.ilst`。写不了返回 null。
///
/// **麻烦在偏移**:moov 通常排在 mdat 前面(faststart —— 汽水音乐那条实测
/// `ftyp@0`、`moov@28`、`mdat@22794`),而 `stbl.stco` 里存的是每个 chunk 在文件
/// 里的**绝对偏移**。ilst 一长大,mdat 整体后移,这些偏移全部失效 —— 不补的话
/// 文件头还认得、时长也读得出来,声音却是错位的。
///
/// 所以这个函数做三件事:重建 moov(往 ilst 里追加盒子)、把新 moov 拼回文件、
/// 按 moov 长了多少去改 stco / co64。mdat 排在 moov 前面时不用改(那种排布下
/// moov 长大影响不到 mdat 的位置)。
///
/// 分片 MP4(`moof`)不支持:那种结构下偏移是相对的,得另写一套。认不出原样返回。
@visibleForTesting
List<int>? writeMp4Tag(List<int> src, AudioTagInfo tags, List<int>? cover) {
  final top = _boxes(src, 0, src.length);
  final moov = _first(top, 'moov');
  final mdat = _first(top, 'mdat');
  if (moov == null || mdat == null) return null;

  final coverKind = cover == null ? null : _imageKind(cover);
  final items = <List<int>>[
    if (tags.title.isNotEmpty) _mp4Text(_kNam, tags.title),
    if (tags.artist.isNotEmpty) _mp4Text(_kArt, tags.artist),
    if (tags.album.isNotEmpty) _mp4Text(_kAlb, tags.album),
    if (tags.lyrics.isNotEmpty) _mp4Text(_kLyr, tags.lyrics),
    if (tags.lyrics.isNotEmpty) _mp4Text(_kDes, tags.lyrics),
    if (cover != null && coverKind != null)
      _mp4Cover(cover, coverKind == _ImageKind.jpeg ? 13 : 14),
  ];
  if (items.isEmpty) return null;
  // 同名的旧项要去掉,不然一个 ilst 里挂着两份标题,播放器读哪份看运气。
  final owned = <String>{
    if (tags.title.isNotEmpty) _kNam,
    if (tags.artist.isNotEmpty) _kArt,
    if (tags.album.isNotEmpty) _kAlb,
    if (tags.lyrics.isNotEmpty) _kLyr,
    if (tags.lyrics.isNotEmpty) _kDes,
    if (cover != null && coverKind != null) _kCovr,
  };

  final moovKids = _boxes(src, moov.bodyStart, moov.end);
  // 分片 MP4(`mvex`,样本装在后面的 `moof` 里):那种结构的偏移是相对的,这套
  // 「把 moov 撑大再补 stco」的改法不适用。认出来就撒手,别把一个能播的文件改坏。
  if (_first(moovKids, 'mvex') != null) return null;
  final udta = _first(moovKids, 'udta');

  // 现成的 meta 直接复用:它里面的 hdlr 是原文件带来的,比我现造的更可能被
  // 这个播放器认。只有完全没有 meta 时才自己拼一个。
  var metaPrefix = _kMetaPrefix;
  var ilstBody = <int>[];
  if (udta != null) {
    for (final meta in _boxes(src, udta.bodyStart, udta.end)) {
      if (meta.type != 'meta') continue;
      final metaKids = _boxes(src, meta.bodyStart + 4, meta.end);
      final ilst = _first(metaKids, 'ilst');
      if (ilst == null) continue;
      for (final item in _boxes(src, ilst.bodyStart, ilst.end)) {
        if (owned.contains(item.type)) continue;
        ilstBody.addAll(src.sublist(item.start, item.end));
      }
      metaPrefix = src.sublist(meta.bodyStart, ilst.start);
      break;
    }
  }
  ilstBody.addAll(<int>[for (final item in items) ...item]);

  final metaBox = _box('meta', <int>[...metaPrefix, ..._box('ilst', ilstBody)]);
  final udtaBody = <int>[];
  var metaPlaced = false;
  if (udta != null) {
    for (final kid in _boxes(src, udta.bodyStart, udta.end)) {
      if (kid.type == 'meta') {
        udtaBody.addAll(metaBox);
        metaPlaced = true;
      } else {
        udtaBody.addAll(src.sublist(kid.start, kid.end));
      }
    }
  }
  if (!metaPlaced) udtaBody.addAll(metaBox);
  final udtaBox = _box('udta', udtaBody);

  final moovBody = <int>[];
  var udtaPlaced = false;
  for (final kid in moovKids) {
    if (kid.type == 'udta') {
      moovBody.addAll(udtaBox);
      udtaPlaced = true;
    } else {
      moovBody.addAll(src.sublist(kid.start, kid.end));
    }
  }
  if (!udtaPlaced) moovBody.addAll(udtaBox);
  final newMoov = _box('moov', moovBody);

  final delta = newMoov.length - moov.size;
  // moov 在 mdat 前面才要补偏移。补之前先看会不会撑破 stco 的 32 位字段 ——
  // 撑破了说明这个文件本来就该用 co64,不冒这个险,原样返回。
  final needsShift = delta != 0 && mdat.start > moov.start;
  if (needsShift && mdat.start + 8 + delta > 0xFFFFFFFF) return null;

  final out = <int>[
    ...src.sublist(0, moov.start),
    ...newMoov,
    ...src.sublist(moov.end),
  ];
  if (needsShift) _shiftChunkOffsets(out, moov.start, newMoov.length, delta);
  return out;
}

/// 把新 moov 里所有 `stco` / `co64` 的 chunk 偏移整体加上 [delta]。
///
/// 按盒子逐层走到 `trak.mdia.minf.stbl` —— 不能按固定偏移去改:udta 排在 trak
/// 前面时,重建之后 stco 在 moov 里的相对位置是会变的,而这里是对**新**的字节
/// 走的,所以顺序和长度怎么变都对得上。
void _shiftChunkOffsets(
  List<int> bytes,
  int moovStart,
  int moovLength,
  int delta,
) {
  final moovEnd = moovStart + moovLength;
  for (final trak in _boxes(bytes, moovStart + 8, moovEnd)) {
    if (trak.type != 'trak') continue;
    for (final mdia in _boxes(bytes, trak.bodyStart, trak.end)) {
      if (mdia.type != 'mdia') continue;
      for (final minf in _boxes(bytes, mdia.bodyStart, mdia.end)) {
        if (minf.type != 'minf') continue;
        for (final stbl in _boxes(bytes, minf.bodyStart, minf.end)) {
          if (stbl.type != 'stbl') continue;
          for (final table in _boxes(bytes, stbl.bodyStart, stbl.end)) {
            // stco / co64 都是 FullBox:4 字节 version/flags + 4 字节条数 + 条目。
            if (table.type == 'stco') {
              final count = _u32(bytes, table.bodyStart + 4);
              for (var i = 0; i < count; i++) {
                final at = table.bodyStart + 8 + i * 4;
                _putU32(bytes, at, _u32(bytes, at) + delta);
              }
            } else if (table.type == 'co64') {
              final count = _u32(bytes, table.bodyStart + 4);
              for (var i = 0; i < count; i++) {
                final at = table.bodyStart + 8 + i * 8;
                _putU64(bytes, at, _u64(bytes, at) + delta);
              }
            }
          }
        }
      }
    }
  }
}

/// 文本项:`©nam` 里套一个 `data`,类型 1 = UTF-8。
List<int> _mp4Text(String name, String text) => _box(name, <int>[
  ..._box('data', <int>[0, 0, 0, 1, 0, 0, 0, 0, ...utf8.encode(text)]),
]);

/// 封面项:类型 13 = JPEG,14 = PNG。
List<int> _mp4Cover(List<int> image, int type) => _box(_kCovr, <int>[
  ..._box('data', <int>[0, 0, 0, type, 0, 0, 0, 0, ...image]),
]);

/// 从头拼一个 `meta` 时用的开头:FullBox 的 4 字节 version/flags + 一个 hdlr。
///
/// hdlr 声明这是 iTunes 那套元数据(`mdir` + `appl`)。少了它,有的播放器会把
/// 整块 ilst 当不认识的东西跳过 —— 标签写了等于没写。
final List<int> _kMetaPrefix = <int>[
  0,
  0,
  0,
  0,
  ..._box('hdlr', <int>[
    0, 0, 0, 0, // version / flags
    0, 0, 0, 0, // pre_defined
    0x6D, 0x64, 0x69, 0x72, // 'mdir'
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // reserved[3]
    0, // 空名字
  ]),
];

/// 一个盒子:4 字节长度 + 4 字节类型 + 内容。
List<int> _box(String type, List<int> body) {
  assert(type.codeUnits.length == 4, '盒子类型必须是 4 个字节:$type');
  final size = 8 + body.length;
  return <int>[
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ...type.codeUnits,
    ...body,
  ];
}

/// 一个盒子在文件里的位置。`type` 是那 4 个字节按码位映射出来的字符串
/// (`©` 会得到 `\u00A9`)。
class _Box {
  const _Box(this.type, this.start, this.size);

  final String type;
  final int start;
  final int size;

  /// 内容起点(跳过 8 字节的盒子头)。
  int get bodyStart => start + 8;

  /// 盒子结尾(不含)。
  int get end => start + size;
}

/// 扫一层盒子。碰到长度不合法的就停下,不接着猜 —— 猜错会顺着垃圾数据一路读下去。
List<_Box> _boxes(List<int> bytes, int start, int end) {
  final out = <_Box>[];
  var pos = start;
  while (pos + 8 <= end) {
    var size = _u32(bytes, pos);
    final type = String.fromCharCodes(bytes.sublist(pos + 4, pos + 8));
    if (size == 1) {
      if (pos + 16 > end) break;
      size = _u64(bytes, pos + 8);
    } else if (size == 0) {
      // 0 表示"一直到文件结尾",只有最后一个盒子能这么写。
      size = end - pos;
    }
    if (size < 8 || pos + size > end) break;
    out.add(_Box(type, pos, size));
    pos += size;
  }
  return out;
}

_Box? _first(List<_Box> boxes, String type) {
  for (final box in boxes) {
    if (box.type == type) return box;
  }
  return null;
}

int _u32(List<int> bytes, int at) =>
    (bytes[at] << 24) |
    (bytes[at + 1] << 16) |
    (bytes[at + 2] << 8) |
    bytes[at + 3];

void _putU32(List<int> bytes, int at, int value) {
  bytes[at] = (value >> 24) & 0xFF;
  bytes[at + 1] = (value >> 16) & 0xFF;
  bytes[at + 2] = (value >> 8) & 0xFF;
  bytes[at + 3] = value & 0xFF;
}

int _u64(List<int> bytes, int at) =>
    (_u32(bytes, at) << 32) | _u32(bytes, at + 4);

void _putU64(List<int> bytes, int at, int value) {
  _putU32(bytes, at, (value >> 32) & 0xFFFFFFFF);
  _putU32(bytes, at + 4, value & 0xFFFFFFFF);
}

// ---------------------------------------------------------------------------
// MP3 / ID3v2.4
// ---------------------------------------------------------------------------

/// 往 MP3 里写 ID3v2.4 标签。没有可写的内容时原样返回。
///
/// 整块旧标签**直接换掉**:ID3v2.3 和 v2.4 的帧长编码不一样(v2.4 才用 syncsafe),
/// 把旧帧原样搬进新标签会把长度读错、整块标签报废。标签里那点编码器信息不值这个
/// 风险 —— 标题、作者、封面、歌词都在这儿重新写一遍。
///
/// 顺带把文件末尾的 ID3v1 删掉:那是固定 128 字节的老格式,很多播放器优先读它,
/// 留着就会显示成旧标题(甚至和 v2.4 里的新标题打架)。
@visibleForTesting
List<int>? writeId3Tag(List<int> src, AudioTagInfo tags, List<int>? cover) {
  final frames = <List<int>>[
    if (tags.title.isNotEmpty) _id3Text('TIT2', tags.title),
    if (tags.artist.isNotEmpty) _id3Text('TPE1', tags.artist),
    if (tags.album.isNotEmpty) _id3Text('TALB', tags.album),
    if (tags.lyrics.isNotEmpty) _id3Lyrics(tags.lyrics),
    if (cover != null && _imageKind(cover) != null) _id3Cover(cover),
  ];
  if (frames.isEmpty) return src;

  var audioStart = 0;
  if (_hasId3v2(src)) {
    // 头里的长度是 syncsafe 的,存不下超过 256MB 的标签。长度不合法(截断了、
    // 或者是个假头)就当没有标签 —— 照着它切会把真音频切掉一段。
    final end = 10 + _syncSafeAt(src, 6) + (((src[5] & 0x10) != 0) ? 10 : 0);
    if (end > 10 && end <= src.length) audioStart = end;
  }
  var audioEnd = src.length;
  if (audioEnd - audioStart >= 128) {
    final at = audioEnd - 128;
    if (src[at] == 0x54 && src[at + 1] == 0x41 && src[at + 2] == 0x47) {
      audioEnd = at;
    }
  }

  final body = <int>[for (final frame in frames) ...frame];
  return <int>[
    0x49, 0x44, 0x33, // 'ID3'
    0x04, 0x00, // v2.4.0
    0x00, // flags:没有扩展头、没有 footer
    ..._syncSafeBytes(body.length),
    ...body,
    ...src.sublist(audioStart, audioEnd),
  ];
}

bool _hasId3v2(List<int> src) =>
    src.length >= 10 && src[0] == 0x49 && src[1] == 0x44 && src[2] == 0x33;

/// 文本帧:`0x03` = UTF-8(v2.4 里是合法的,中文不用绕 UTF-16)。
List<int> _id3Text(String id, String text) =>
    _id3Frame(id, <int>[0x03, ...utf8.encode(text)]);

/// 不带时间轴的歌词。
///
/// **内嵌歌词是没有时间轴的纯文本** —— 大多数手机播放器只把它当一段说明文字,
/// 不会跟着进度滚。要滚动得上同名 `.lrc` 旁挂文件,那是另一件事。
///
/// 帧体:编码 + 3 字节语言(`XXX` = 未定义) + 以 0 结尾的描述 + 正文。
List<int> _id3Lyrics(String text) => _id3Frame('USLT', <int>[
  0x03,
  0x58,
  0x58,
  0x58,
  0x00,
  ...utf8.encode(text),
]);

/// 封面。类型 `0x03` = 正面封面。
List<int> _id3Cover(List<int> image) {
  final mime = utf8.encode(
    _imageKind(image) == _ImageKind.jpeg ? 'image/jpeg' : 'image/png',
  );
  return _id3Frame('APIC', <int>[
    0x03, // 编码
    ...mime,
    0x00, // MIME 以 0 结尾
    0x03, // 图片类型:正面封面
    0x00, // 描述(空)
    ...image,
  ]);
}

/// 一个帧:4 字节 ID + 4 字节 syncsafe 长度(v2.4 的规定)+ 2 字节 flags + 帧体。
List<int> _id3Frame(String id, List<int> body) => <int>[
  ...id.codeUnits,
  ..._syncSafeBytes(body.length),
  0,
  0,
  ...body,
];

/// 32 位 syncsafe:每字节只用低 7 位,最高位恒为 0。
List<int> _syncSafeBytes(int value) => <int>[
  (value >> 21) & 0x7F,
  (value >> 14) & 0x7F,
  (value >> 7) & 0x7F,
  value & 0x7F,
];

int _syncSafeAt(List<int> bytes, int at) =>
    (bytes[at] << 21) |
    (bytes[at + 1] << 14) |
    (bytes[at + 2] << 7) |
    bytes[at + 3];
