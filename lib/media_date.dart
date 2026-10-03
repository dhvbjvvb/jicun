import 'dart:io';
import 'dart:typed_data';

import 'failure.dart';

/// 把下载文件里的「拍摄 / 创建时间」改成下载时间。
///
/// 相册、文件管理显示和排序用的日期来自文件里的元数据,不是下载时间:
/// - MP4 / M4A / MOV 的 `moov.mvhd`(以及 tkhd / mdhd)带 creation_time,源视频
///   是多少年前的,相册就显示那一天;
/// - JPEG 的 EXIF 里带 DateTimeOriginal / DateTimeDigitized / DateTime。
///
/// 需求是「所有平台、所有分类下载回来的文件都算下载当天」,所以这里统一改成 [now];
/// 文件系统的修改时间也一起设掉,文件管理器按 mtime 排的时候也一致。
///
/// **覆盖范围就这五类**:mp4 / m4v / mov / m4a(容器里的 `mvhd` / `tkhd` / `mdhd`)
/// 和 jpg / jpeg(EXIF)。webm / mkv / mp3 / ogg / png / gif / webp 这些没有对应的
/// 盒子可改(或改起来要动整块帧数据),只改 mtime —— 相册里显示的多半还是源文件的
/// 日期。要扩到这几类,先确认改完还能正常播放,别为了让日期好看去碰二进制结构。
///
/// **认不出结构就原样返回,绝不把文件改坏**;所有异常一律吞掉 —— 日期不对是小事,
/// 把用户刚下好的视频改坏是大事。
Future<void> stampDownloadDate(File file, {DateTime? now}) async {
  final when = now ?? DateTime.now();
  try {
    await file.setLastModified(when);
  } catch (error, stack) {
    // mtime 失败不挡下面:能改二进制里的时间就改,改不了只损失相册排序。
    swallow('date.mtime', error, stack);
  }
  try {
    final lower = file.path.toLowerCase();
    if (lower.endsWith('.mp4') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.m4a')) {
      await stampMp4(file, when);
      return;
    }
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      final bytes = await file.readAsBytes();
      if (_isJpeg(bytes) && _stampJpegExif(bytes, when)) {
        await file.writeAsBytes(bytes, flush: false);
      }
    }
  } catch (error, stack) {
    // 改不动就算了:文件已经是完整的,只是日期可能还是源文件的。
    swallow('date.stamp', error, stack);
  }
}

// ────────────────────────────── MP4 / M4A ──────────────────────────────

/// MP4 的时间基准是 1904-01-01 UTC,不是 1970。
final DateTime _mp4Epoch = DateTime.utc(1904, 1, 1);

/// 把 MP4 / M4A / MOV 里所有 `mvhd` / `tkhd` / `mdhd` 的创建、修改时间改成 [when]。
///
/// 用随机读写只碰这几个盒子的固定字段(版本决定 32 位还是 64 位),**不改动文件
/// 长度、不搬数据**,所以没有 stco 偏移那一类风险。大文件也只 seek,不整读。
Future<bool> stampMp4(File file, DateTime when) async {
  final raf = await file.open(mode: FileMode.append);
  try {
    final length = await raf.length();
    final seconds = when.toUtc().difference(_mp4Epoch).inSeconds;
    var offset = 0;
    while (offset + 8 <= length) {
      await raf.setPosition(offset);
      final header = await raf.read(8);
      if (header.length < 8) return false;
      var size = _be32(header, 0);
      final type = String.fromCharCodes(header.sublist(4, 8));
      var bodyStart = offset + 8;
      if (size == 1) {
        final ext = await raf.read(8);
        if (ext.length < 8) return false;
        size = _be64(ext, 0);
        bodyStart = offset + 16;
      } else if (size == 0) {
        size = length - offset;
      }
      if (size < 8 || offset + size > length) return false;
      if (type == 'moov') {
        // **必须 await**:`return future` 不会等它跑完就执行 finally,close 会撞上
        // 还没写完的随机写(实测报 "An async operation is currently pending")。
        return await _stampMoov(raf, bodyStart, offset + size, seconds);
      }
      offset += size;
    }
    return false;
  } catch (_) {
    return false;
  } finally {
    await raf.close();
  }
}

Future<bool> _stampMoov(
  RandomAccessFile raf,
  int start,
  int end,
  int seconds,
) async {
  var changed = false;
  var p = start;
  while (p + 8 <= end) {
    await raf.setPosition(p);
    final header = await raf.read(8);
    if (header.length < 8) break;
    var size = _be32(header, 0);
    final type = String.fromCharCodes(header.sublist(4, 8));
    var body = p + 8;
    if (size == 1) {
      final ext = await raf.read(8);
      if (ext.length < 8) break;
      size = _be64(ext, 0);
      body = p + 16;
    } else if (size == 0) {
      size = end - p;
    }
    if (size < 8 || p + size > end) break;
    if (type == 'mvhd' || type == 'tkhd' || type == 'mdhd') {
      if (await _patchTime(raf, body, seconds)) changed = true;
    } else if (type == 'trak' || type == 'mdia' || type == 'udta') {
      if (await _stampMoov(raf, body, p + size, seconds)) changed = true;
    } else if (type == 'meta') {
      // meta 是 FullBox:version/flags 占 4 字节,子盒子从 body+4 起。
      if (await _stampMoov(raf, body + 4, p + size, seconds)) changed = true;
    }
    p += size;
  }
  return changed;
}

/// 改一个 FullBox 的 creation_time / modification_time。版本 0 是 32 位,版本 1 是 64 位。
Future<bool> _patchTime(RandomAccessFile raf, int body, int seconds) async {
  await raf.setPosition(body);
  final vf = await raf.read(4);
  if (vf.length < 4) return false;
  final version = vf[0];
  final Uint8List buf;
  if (version == 1) {
    buf = Uint8List(16);
    _putU64(buf, 0, seconds);
    _putU64(buf, 8, seconds);
  } else if (version == 0) {
    final value = seconds > 0xFFFFFFFF
        ? 0xFFFFFFFF
        : (seconds < 0 ? 0 : seconds);
    buf = Uint8List(8);
    _putU32(buf, 0, value);
    _putU32(buf, 4, value);
  } else {
    return false;
  }
  await raf.setPosition(body + 4);
  await raf.writeFrom(buf);
  return true;
}

// ────────────────────────────── JPEG EXIF ──────────────────────────────

bool _isJpeg(List<int> bytes) =>
    bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8;

/// 覆写 JPEG 里 EXIF 的日期字段。没有 EXIF、或字段长度不是标准的 20 字节,就原样返回。
bool _stampJpegExif(List<int> bytes, DateTime when) {
  var p = 2;
  while (p + 4 <= bytes.length) {
    if (bytes[p] != 0xFF) break;
    final marker = bytes[p + 1];
    if (marker == 0xD8 ||
        (marker >= 0xD0 && marker <= 0xD7) ||
        marker == 0x01) {
      p += 2;
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) break;
    final len = (bytes[p + 2] << 8) | bytes[p + 3];
    if (len < 2 || p + 2 + len > bytes.length) break;
    if (marker == 0xE1) {
      final seg = p + 4;
      if (seg + 6 <= bytes.length &&
          bytes[seg] == 0x45 &&
          bytes[seg + 1] == 0x78 &&
          bytes[seg + 2] == 0x69 &&
          bytes[seg + 3] == 0x66 &&
          bytes[seg + 4] == 0 &&
          bytes[seg + 5] == 0) {
        return _patchExif(bytes, seg + 6, when);
      }
    }
    p += 2 + len;
  }
  return false;
}

/// 遍历 IFD0 和 ExifIFD,把日期字段原地覆盖。
bool _patchExif(List<int> bytes, int tiff, DateTime when) {
  if (tiff + 8 > bytes.length) return false;
  final little = bytes[tiff] == 0x49 && bytes[tiff + 1] == 0x49;
  final big = bytes[tiff] == 0x4D && bytes[tiff + 1] == 0x4D;
  if (!little && !big) return false;
  if (_u16(bytes, tiff + 2, little) != 42) return false;
  final stamp = _exifDateBytes(when);
  var changed = false;
  void walk(int ifdOffset, int depth) {
    if (depth > 2 || ifdOffset <= 0) return;
    final base = tiff + ifdOffset;
    if (base + 2 > bytes.length) return;
    final count = _u16(bytes, base, little);
    var entry = base + 2;
    int? exifIfd;
    for (var i = 0; i < count; i++) {
      if (entry + 12 > bytes.length) return;
      final tag = _u16(bytes, entry, little);
      final type = _u16(bytes, entry + 2, little);
      final n = _u32(bytes, entry + 4, little);
      if (tag == 0x8769) {
        exifIfd = _u32(bytes, entry + 8, little);
      } else if ((tag == 0x0132 || tag == 0x9003 || tag == 0x9004) &&
          type == 2 &&
          n == 20) {
        final valueAt = tiff + _u32(bytes, entry + 8, little);
        if (valueAt >= 0 && valueAt + 20 <= bytes.length) {
          for (var k = 0; k < 20; k++) {
            bytes[valueAt + k] = stamp[k];
          }
          changed = true;
        }
      }
      entry += 12;
    }
    if (exifIfd != null) walk(exifIfd, depth + 1);
  }

  walk(_u32(bytes, tiff + 4, little), 0);
  return changed;
}

/// EXIF 的时间格式固定是 `YYYY:MM:DD HH:MM:SS` + NUL,正好 20 字节。
Uint8List _exifDateBytes(DateTime when) {
  String two(int v) => v.toString().padLeft(2, '0');
  final text =
      '${when.year.toString().padLeft(4, '0')}:${two(when.month)}:${two(when.day)} '
      '${two(when.hour)}:${two(when.minute)}:${two(when.second)}';
  final out = Uint8List(20);
  for (var i = 0; i < text.length && i < 19; i++) {
    out[i] = text.codeUnitAt(i);
  }
  return out;
}

// ────────────────────────────── 小工具 ──────────────────────────────

int _u16(List<int> b, int at, bool little) =>
    little ? (b[at] | (b[at + 1] << 8)) : ((b[at] << 8) | b[at + 1]);

int _u32(List<int> b, int at, bool little) => little
    ? (b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24))
    : ((b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]);

int _be32(List<int> b, int at) =>
    ((b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]) &
    0xFFFFFFFF;

int _be64(List<int> b, int at) => (_be32(b, at) << 32) | _be32(b, at + 4);

void _putU32(Uint8List b, int at, int value) {
  b[at] = (value >> 24) & 0xFF;
  b[at + 1] = (value >> 16) & 0xFF;
  b[at + 2] = (value >> 8) & 0xFF;
  b[at + 3] = value & 0xFF;
}

void _putU64(Uint8List b, int at, int value) {
  _putU32(b, at, (value >> 32) & 0xFFFFFFFF);
  _putU32(b, at + 4, value & 0xFFFFFFFF);
}
