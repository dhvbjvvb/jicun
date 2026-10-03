import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jicun/audio_tags.dart';

// ---------------------------------------------------------------------------
// 夹具:自己拼一个体积最小但结构合法的 M4A / MP3。
//
// 这里**故意不复用** audio_tags.dart 里的盒子读写函数 —— 用例要能独立地算出
// "mdat 应该在哪、stco 应该指到哪",拿被测代码自己的算法去验被测代码,等于没验。
// ---------------------------------------------------------------------------

int _u32(List<int> b, int at) =>
    (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];

List<int> _box(String type, List<int> body) {
  // 类型那 4 个字节按码位写,不走 UTF-8 —— `©`(0xA9)在盒子里是**一个**字节,
  // utf8 编出来是两个,整个盒子的结构就错位了。
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

List<int> _text(String type, String text) => _box(type, <int>[
  ..._box('data', <int>[0, 0, 0, 1, 0, 0, 0, 0, ...utf8.encode(text)]),
]);

/// 一层的盒子列表:`(类型, 起点, 长度)`。
List<(String, int, int)> _walk(List<int> b, int start, int end) {
  final out = <(String, int, int)>[];
  var pos = start;
  while (pos + 8 <= end) {
    final size = _u32(b, pos);
    final type = String.fromCharCodes(b.sublist(pos + 4, pos + 8));
    out.add((type, pos, size));
    pos += size;
  }
  return out;
}

(String, int, int)? _find(List<int> b, int start, int end, String type) {
  for (final box in _walk(b, start, end)) {
    if (box.$1 == type) return box;
  }
  return null;
}

/// 一个带 `udta.meta.ilst`(里面只有 ©too)的 M4A,moov 排在 mdat 前面 ——
/// 形状照抄汽水音乐那条真链接(faststart)。
List<int> _buildM4a(List<int> payload) {
  List<int> build(int chunkOffset) {
    final stco = _box('stco', <int>[
      0, 0, 0, 0, // version / flags
      0, 0, 0, 1, // 一条
      ...<int>[
        (chunkOffset >> 24) & 0xFF,
        (chunkOffset >> 16) & 0xFF,
        (chunkOffset >> 8) & 0xFF,
        chunkOffset & 0xFF,
      ],
    ]);
    final trak = _box('trak', <int>[
      ..._box('mdia', <int>[
        ..._box('minf', <int>[
          ..._box('stbl', <int>[...stco]),
        ]),
      ]),
    ]);
    final udta = _box('udta', <int>[
      ..._box('meta', <int>[
        0,
        0,
        0,
        0,
        ..._box('hdlr', List<int>.filled(25, 0)),
        ..._box('ilst', <int>[..._text('\u00A9too', 'Lavf60')]),
      ]),
    ]);
    return _box('moov', <int>[
      ..._box('mvhd', List<int>.filled(100, 0)),
      ...trak,
      ...udta,
    ]);
  }

  final ftyp = _box('ftyp', <int>[
    ...utf8.encode('M4A '),
    0,
    0,
    2,
    0,
    ...utf8.encode('M4A '),
    ...utf8.encode('isom'),
    ...utf8.encode('iso2'),
  ]);
  // 先按占位值拼一遍拿到 moov 的长度,再按真实位置拼第二遍 —— stco 里必须是
  // 正确的绝对偏移,夹具本身不合法的话用例验不出东西。
  final moovSize = build(0).length;
  final payloadOffset = ftyp.length + moovSize + 8;
  return <int>[...ftyp, ...build(payloadOffset), ..._box('mdat', payload)];
}

/// 读 moov 里那条 stco 的第一个偏移。
int _firstChunkOffset(List<int> b) {
  final moov = _find(b, 0, b.length, 'moov')!;
  final trak = _find(b, moov.$2 + 8, moov.$2 + moov.$3, 'trak')!;
  final mdia = _find(b, trak.$2 + 8, trak.$2 + trak.$3, 'mdia')!;
  final minf = _find(b, mdia.$2 + 8, mdia.$2 + mdia.$3, 'minf')!;
  final stbl = _find(b, minf.$2 + 8, minf.$2 + minf.$3, 'stbl')!;
  final stco = _find(b, stbl.$2 + 8, stbl.$2 + stbl.$3, 'stco')!;
  return _u32(b, stco.$2 + 16);
}

/// mdat 里数据的起点。stco 就该指到这儿。
int _mdatPayloadOffset(List<int> b) {
  final mdat = _find(b, 0, b.length, 'mdat')!;
  return mdat.$2 + 8;
}

/// ilst 里的项名 → data 盒子的**整个内容**(4 字节类型 + 4 字节 locale + 正文)。
Map<String, List<int>> _ilstItems(List<int> b) {
  final out = <String, List<int>>{};
  final moov = _find(b, 0, b.length, 'moov')!;
  final udta = _find(b, moov.$2 + 8, moov.$2 + moov.$3, 'udta')!;
  final meta = _find(b, udta.$2 + 8, udta.$2 + udta.$3, 'meta')!;
  final ilst = _find(b, meta.$2 + 12, meta.$2 + meta.$3, 'ilst')!;
  for (final item in _walk(b, ilst.$2 + 8, ilst.$2 + ilst.$3)) {
    final data = _find(b, item.$2 + 8, item.$2 + item.$3, 'data')!;
    out[item.$1] = b.sublist(data.$2 + 8, data.$2 + data.$3);
  }
  return out;
}

/// 最小的 JPEG 头(只要够 _imageKind 认出来)。
final List<int> _jpeg = <int>[0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4];

/// 一个只有 ID3v2(带旧标题)+ 音频 + ID3v1 的 MP3。
List<int> _buildMp3(List<int> audio) {
  final title = _id3Frame('TIT2', <int>[0x03, ...utf8.encode('旧标题')]);
  final tag = <int>[
    0x49,
    0x44,
    0x33,
    0x04,
    0x00,
    0x00,
    ..._syncSafe(title.length),
    ...title,
  ];
  return <int>[
    ...tag,
    ...audio,
    // ID3v1:末尾固定 128 字节,以 `TAG` 开头。
    ...utf8.encode('TAG'),
    ...List<int>.filled(125, 0),
  ];
}

List<int> _syncSafe(int v) => <int>[
  (v >> 21) & 0x7F,
  (v >> 14) & 0x7F,
  (v >> 7) & 0x7F,
  v & 0x7F,
];

List<int> _id3Frame(String id, List<int> body) => <int>[
  ...utf8.encode(id),
  ..._syncSafe(body.length),
  0,
  0,
  ...body,
];

/// MP3 里所有 v2.4 帧:`ID → 帧体`。从第一个 `ID3` 头往后走。
Map<String, List<int>> _id3Frames(List<int> b) {
  final size = (b[6] << 21) | (b[7] << 14) | (b[8] << 7) | b[9];
  final out = <String, List<int>>{};
  var pos = 10;
  while (pos + 10 <= 10 + size) {
    final id = String.fromCharCodes(b.sublist(pos, pos + 4));
    final len =
        (b[pos + 4] << 21) |
        (b[pos + 5] << 14) |
        (b[pos + 6] << 7) |
        b[pos + 7];
    out[id] = b.sublist(pos + 10, pos + 10 + len);
    pos += 10 + len;
  }
  return out;
}

void main() {
  group('MP4 / M4A', () {
    test('夹具有效:stco 本来指着 mdat 的数据起点', () {
      final src = _buildM4a(List<int>.filled(64, 7));
      expect(_firstChunkOffset(src), _mdatPayloadOffset(src));
    });

    test('写完标签后 stco 跟着 mdat 一起后移', () {
      final payload = List<int>.generate(64, (i) => i);
      final src = _buildM4a(payload);
      final out = writeMp4Tag(
        src,
        const AudioTagInfo(title: '歌名', artist: '歌手', lyrics: '[00:01]第一句'),
        _jpeg,
      )!;

      // moov 长大 → mdat 整体后移 → stco 每一条都要加上同一段增量。
      final delta = _mdatPayloadOffset(out) - _mdatPayloadOffset(src);
      expect(delta, greaterThan(0), reason: '标签应该让 moov 变大');
      expect(_firstChunkOffset(out), _mdatPayloadOffset(out));

      // 音频本体一个字节都不能动。
      expect(
        out.sublist(
          _mdatPayloadOffset(out),
          _mdatPayloadOffset(out) + payload.length,
        ),
        payload,
      );
    });

    test('标题 / 作者 / 歌词 / 封面都写进去了,旧的 ©too 留着', () {
      final out = writeMp4Tag(
        _buildM4a(List<int>.filled(16, 0)),
        const AudioTagInfo(title: '歌名', artist: '歌手', lyrics: '[00:01]第一句'),
        _jpeg,
      )!;
      final items = _ilstItems(out);

      expect(utf8.decode(items['\u00A9nam']!.sublist(8)), '歌名');
      expect(utf8.decode(items['\u00A9ART']!.sublist(8)), '歌手');
      expect(utf8.decode(items['\u00A9lyr']!.sublist(8)), '[00:01]第一句');
      expect(items['\u00A9too'], isNotNull, reason: '不归我们管的项不该被丢掉');
      // covr 的 data 前面 4 字节是类型:13 = JPEG。
      final covr = items['covr']!;
      expect(covr.sublist(0, 4), <int>[0, 0, 0, 13]);
      expect(covr.sublist(8), _jpeg);
    });

    test('重复写不会攒出两份同名项', () {
      final once = writeMp4Tag(
        _buildM4a(List<int>.filled(16, 0)),
        const AudioTagInfo(title: '第一遍'),
        null,
      )!;
      final twice = writeMp4Tag(once, const AudioTagInfo(title: '第二遍'), null)!;

      expect(utf8.decode(_ilstItems(twice)['\u00A9nam']!.sublist(8)), '第二遍');
      final moov = _find(twice, 0, twice.length, 'moov')!;
      final udta = _find(twice, moov.$2 + 8, moov.$2 + moov.$3, 'udta')!;
      final meta = _find(twice, udta.$2 + 8, udta.$2 + udta.$3, 'meta')!;
      final ilst = _find(twice, meta.$2 + 12, meta.$2 + meta.$3, 'ilst')!;
      final names = [
        for (final item in _walk(twice, ilst.$2 + 8, ilst.$2 + ilst.$3))
          if (item.$1 == '\u00A9nam') item,
      ];
      expect(names.length, 1);
    });

    test('没有 moov 的东西原样返回,不猜', () {
      expect(
        writeMp4Tag(
          List<int>.filled(64, 0),
          const AudioTagInfo(title: 'x'),
          null,
        ),
        isNull,
      );
    });
  });

  group('MP3 / ID3', () {
    test('新标签覆盖旧标题,音频本体和 ID3v1 都清干净', () {
      final audio = List<int>.generate(48, (i) => 200 - i);
      final src = _buildMp3(audio);
      final out = writeId3Tag(
        src,
        const AudioTagInfo(title: '新歌名', artist: '歌手', lyrics: '第一句'),
        _jpeg,
      )!;

      expect(out.sublist(0, 3), <int>[0x49, 0x44, 0x33]);
      expect(out[3], 4, reason: '写的是 v2.4');

      final frames = _id3Frames(out);
      expect(utf8.decode(frames['TIT2']!.sublist(1)), '新歌名');
      expect(utf8.decode(frames['TPE1']!.sublist(1)), '歌手');
      // USLT:编码 + 3 字节语言 + 以 0 结尾的描述 + 正文。
      expect(utf8.decode(frames['USLT']!.sublist(5)), '第一句');
      expect(frames['APIC'], isNotNull);

      // 旧标题不能还留在文件里(整块旧标签被换掉了)。
      expect(utf8.decode(out, allowMalformed: true).contains('旧标题'), isFalse);
      // 音频本体原样,末尾的 ID3v1 没了 —— 音频就是文件最后那一段。
      expect(out.sublist(out.length - audio.length), audio);
    });

    test('没有可写的内容时原样返回', () {
      final src = _buildMp3(List<int>.filled(16, 3));
      expect(writeId3Tag(src, const AudioTagInfo(), null), same(src));
    });
  });

  group('embedAudioTags', () {
    test('认不出的容器不碰文件', () async {
      final dir = Directory.systemTemp.createTempSync('jicun_tag');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/a.flac')
        ..writeAsBytesSync(List<int>.filled(32, 9));

      final wrote = await embedAudioTags(
        file,
        const AudioTagInfo(title: 'x'),
        ext: '.flac',
      );

      expect(wrote, isFalse);
      expect(file.readAsBytesSync(), List<int>.filled(32, 9));
      expect(File('${file.path}.tagging').existsSync(), isFalse);
    });

    test('标签全空时什么都不做', () async {
      final dir = Directory.systemTemp.createTempSync('jicun_tag');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/a.mp3')
        ..writeAsBytesSync(List<int>.filled(32, 9));

      expect(
        await embedAudioTags(file, const AudioTagInfo(), ext: '.mp3'),
        isFalse,
      );
    });

    test('MP3 端到端:落盘的文件带着新标签,没有残留的临时文件', () async {
      final dir = Directory.systemTemp.createTempSync('jicun_tag');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/a.mp3')
        ..writeAsBytesSync(_buildMp3(List<int>.filled(32, 5)));

      final wrote = await embedAudioTags(
        file,
        const AudioTagInfo(title: '端到端', artist: '歌手'),
        ext: '.mp3',
      );

      expect(wrote, isTrue);
      expect(
        utf8.decode(_id3Frames(file.readAsBytesSync())['TIT2']!.sublist(1)),
        '端到端',
      );
      expect(File('${file.path}.tagging').existsSync(), isFalse);
    });
  });

  group('lyricsPlainText', () {
    test('服务端给的 LRC:去掉时间轴,只留正文', () {
      // 形状照抄汽水那条真链接(见 parse_service.dart 的 lyrics 字段)。
      const lrc =
          '[00:00.00]作曲：Nguyễn Văn Mạnh\n'
          '[00:02.63]街上灯火亮起寒意悄然降临\n'
          '[02:04.71]你的目光让一切都亮了起来';

      expect(
        lyricsPlainText(lrc),
        '作曲：Nguyễn Văn Mạnh\n街上灯火亮起寒意悄然降临\n你的目光让一切都亮了起来',
      );
    });

    test('元信息行整行丢掉,一行挂多个时间轴只留一次正文', () {
      expect(
        lyricsPlainText('[ar:歌手]\n[00:01][00:05]重复的一句\n[offset:0]'),
        '重复的一句',
      );
    });

    test('只有时间轴、没有正文的行(间奏)不留空行', () {
      expect(lyricsPlainText('[00:01]第一句\n[00:08]\n[00:12]第二句'), '第一句\n第二句');
    });

    test('没有时间轴的纯文本原样返回,空行不吞', () {
      expect(lyricsPlainText('第一段\n\n第二段\n'), '第一段\n\n第二段');
    });

    test('空串还是空串', () {
      expect(lyricsPlainText(''), '');
    });
  });
}
