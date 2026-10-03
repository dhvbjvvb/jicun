import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jicun/media_date.dart';

Uint8List _box(String type, List<int> body) {
  final size = 8 + body.length;
  return Uint8List.fromList(<int>[
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ...type.codeUnits,
    ...body,
  ]);
}

int _be32(List<int> b, int at) =>
    (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];

int _seconds(DateTime when) =>
    when.toUtc().difference(DateTime.utc(1904, 1, 1)).inSeconds;

int _findType(List<int> b, String type) {
  final needle = type.codeUnits;
  for (var i = 0; i + needle.length <= b.length; i++) {
    if (b[i] == needle[0] &&
        b[i + 1] == needle[1] &&
        b[i + 2] == needle[2] &&
        b[i + 3] == needle[3]) {
      return i;
    }
  }
  return -1;
}

List<int> _buildMp4() {
  final mvhdBody = <int>[
    0, 0, 0, 0, // version 0 + flags
    0x11, 0x22, 0x33, 0x44, // creation(旧)
    0x11, 0x22, 0x33, 0x44, // modification(旧)
    0x00, 0x00, 0x03, 0xE8, // timescale 1000
    0, 0, 0, 0,
    ...List<int>.filled(80, 0),
  ];
  final ftyp = _box('ftyp', <int>[...'isom'.codeUnits, 0, 0, 0, 0]);
  final moov = _box('moov', _box('mvhd', mvhdBody));
  final mdat = _box('mdat', List<int>.filled(32, 7));
  return <int>[...ftyp, ...moov, ...mdat];
}

List<int> _buildExifJpeg() {
  final tiff = <int>[
    0x49, 0x49, 0x2A, 0x00, // II + 42
    0x08, 0x00, 0x00, 0x00, // IFD0 offset 8
    0x01, 0x00, // 1 entry
    0x32, 0x01, 0x02, 0x00, // tag 0x0132 DateTime, type ASCII
    0x14, 0x00, 0x00, 0x00, // count 20
    0x1A, 0x00, 0x00, 0x00, // value offset 26
    0x00, 0x00, 0x00, 0x00, // next IFD
    ...'2020:07:26 10:00:00'.codeUnits, 0x00,
  ];
  final app1 = <int>[0x45, 0x78, 0x69, 0x66, 0x00, 0x00, ...tiff];
  final len = app1.length + 2;
  return <int>[
    0xFF,
    0xD8,
    0xFF,
    0xE1,
    (len >> 8) & 0xFF,
    len & 0xFF,
    ...app1,
    0xFF,
    0xD9,
  ];
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('jicun_date'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('MP4: mvhd 的创建与修改时间都改成下载时间', () async {
    final file = File('${dir.path}/v.mp4')..writeAsBytesSync(_buildMp4());
    final when = DateTime.utc(2026, 9, 26, 12, 0, 0);
    expect(await stampMp4(file, when), isTrue);
    final bytes = file.readAsBytesSync();
    final at = _findType(bytes, 'mvhd');
    expect(at, greaterThan(0));
    // type(4) 后面是 version/flags(4),再往后是 creation(4)、modification(4)
    expect(_be32(bytes, at + 8), _seconds(when));
    expect(_be32(bytes, at + 12), _seconds(when));
    // 盒子长度没变:文件大小一致
    expect(bytes.length, _buildMp4().length);
  });

  test('JPEG: EXIF 的 DateTime 原地覆写成下载时间', () async {
    final file = File('${dir.path}/p.jpg')..writeAsBytesSync(_buildExifJpeg());
    final when = DateTime(2026, 9, 26, 12, 0, 0);
    await stampDownloadDate(file, now: when);
    final bytes = file.readAsBytesSync();
    // SOI(2) + APP1 marker(2) + len(2) + Exif\0\0(6) + tiff 内偏移 26
    const at = 2 + 2 + 2 + 6 + 26;
    final text = String.fromCharCodes(bytes.sublist(at, at + 19));
    expect(text, '2026:09:26 12:00:00');
    expect(bytes[at + 19], 0);
    expect(bytes.length, _buildExifJpeg().length);
  });

  test('JPEG: 没有 EXIF 时不改动文件', () async {
    final plain = <int>[0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x04, 1, 2, 0xFF, 0xD9];
    final file = File('${dir.path}/plain.jpg')..writeAsBytesSync(plain);
    await stampDownloadDate(file, now: DateTime(2026, 9, 26));
    expect(file.readAsBytesSync(), plain);
  });
}
