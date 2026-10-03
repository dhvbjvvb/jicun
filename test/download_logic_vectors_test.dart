import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jicun/download_logic.dart';

/// 下载器纯逻辑的**跨端规格**:向量来自 tool/download_logic_vectors.json,
/// 由 tool/gen_logic_vectors.py 生成;Kotlin(android/app/src/test/...)读的是同一份
/// 数据。
///
/// 为什么要有这个文件:那几个函数错了**不会崩**,只会下出一个坏文件(少一段、
/// 写重一段)或者在 80% 处误报失败。两端各写一份实现,靠这份向量对齐。
void main() {
  final raw = File('tool/download_logic_vectors.json').readAsStringSync();
  final data = jsonDecode(raw) as Map<String, dynamic>;

  test('向量文件在,且几张表都不是空的', () {
    for (final key in <String>[
      'chunkCases',
      'tailCases',
      'resumeCases',
      'rotateCases',
      'rangeCases',
      'laneCases',
      'attemptCases',
    ]) {
      expect(data[key], isA<List<dynamic>>(), reason: '向量里缺 $key');
      expect((data[key] as List<dynamic>), isNotEmpty, reason: '$key 是空的');
    }
  });

  test('认领切分:给定行就逐行对,没给行也要严丝合缝铺满', () {
    for (final rawCase in data['chunkCases'] as List<dynamic>) {
      final c = rawCase as Map<String, dynamic>;
      final size = c['size'] as int;
      final chunk = c['chunk'] as int;
      final claims = c['claims'] as int;
      final rows = c['rows'] as List<dynamic>?;

      if (rows != null) {
        expect(rows, hasLength(claims), reason: '${c['name']}:行数和 claims 对不上');
        var claim = 0;
        for (final rawRow in rows) {
          final row = rawRow as List<dynamic>;
          final got = claimedChunk(claim, size, chunk);
          expect(got, isNotNull, reason: '${c['name']}:第 $claim 次认领不该为空');
          expect(got!.start, row[0], reason: '${c['name']}:第 $claim 段的起点');
          expect(got.end, row[1], reason: '${c['name']}:第 $claim 段的终点');
          claim++;
        }
        expect(claimedChunk(claims, size, chunk), isNull,
            reason: '${c['name']}:认领完之后应该是 null');
      } else {
        // 没给行的(认领次数太多):迭代验证每一段接上一段,总覆盖等于 size。
        final flat = tiledChunks(size, (claim) => claimedChunk(claim, size, chunk));
        expect(flat, claims, reason: '${c['name']}:认领次数');
      }
      expect(c['covers'], isTrue, reason: '${c['name']}:覆盖不完整');
    }
  });

  test('带尾巴的切分:尾巴要变小,但不能切出洞', () {
    for (final rawCase in data['tailCases'] as List<dynamic>) {
      final c = rawCase as Map<String, dynamic>;
      final size = c['size'] as int;
      final chunk = c['chunk'] as int;
      final tail = c['tail'] as int;
      final tailChunk = c['tailChunk'] as int;
      final rows = c['rows'] as List<dynamic>;

      var claim = 0;
      for (final rawRow in rows) {
        final row = rawRow as List<dynamic>;
        final got = claimedChunkWithTail(claim, size, chunk, tail, tailChunk);
        expect(got, isNotNull, reason: '${c['name']}:第 $claim 次认领不该为空');
        expect(got!.start, row[0], reason: '${c['name']}:第 $claim 段的起点');
        expect(got.end, row[1], reason: '${c['name']}:第 $claim 段的终点');
        claim++;
      }
      expect(claim, c['claims'], reason: '${c['name']}:认领次数');
      expect(claimedChunkWithTail(claim, size, chunk, tail, tailChunk), isNull);
      expect(c['covers'], isTrue, reason: '${c['name']}:覆盖不完整');
    }
  });

  test('文件不到尾巴两倍时,带尾巴那版退化成普通切分', () {
    const size = 20 << 20; // < 2 x 32MB
    var plain = 0;
    tiledChunks(size, (claim) {
      plain++;
      return claimedChunk(claim, size, 4 << 20);
    });
    var tailed = 0;
    tiledChunks(size, (claim) {
      tailed++;
      return claimedChunkWithTail(claim, size, 4 << 20, 32 << 20, 1 << 20);
    });
    expect(tailed, plain, reason: '小文件被尾巴逻辑切出了多余的段');
  });

  test('断点续传的下一跳夹在段尾 + 1', () {
    for (final rawCase in data['resumeCases'] as List<dynamic>) {
      final c = rawCase as Map<String, dynamic>;
      expect(
        resumeOffset(c['written'] as int, c['offset'] as int, c['end'] as int),
        c['expected'],
        reason: '$c',
      );
    }
  });

  test('连接轮换判据', () {
    for (final rawCase in data['rotateCases'] as List<dynamic>) {
      final c = rawCase as Map<String, dynamic>;
      expect(
        shouldRotateConnection(
          c['start'] as int,
          c['written'] as int,
          c['wanted'] as int,
          c['elapsed'] as int,
          c['budget'] as int,
        ),
        c['expected'],
        reason: '$c',
      );
    }
  });

  test('200 什么时候能当「就是这一段」', () {
    for (final rawCase in data['rangeCases'] as List<dynamic>) {
      final c = rawCase as Map<String, dynamic>;
      expect(
        wholeFileAsRange(
          c['code'] as int,
          c['start'] as int,
          c['end'] as int,
          c['contentLength'] as int,
        ),
        c['expected'],
        reason: '$c',
      );
    }
  });

  test('批量下载时按文件数摊薄连接额度', () {
    for (final rawCase in data['laneCases'] as List<dynamic>) {
      final c = rawCase as Map<String, dynamic>;
      expect(
        lanesPerItem(c['lanes'] as int, c['items'] as int),
        c['expected'],
        reason: '$c',
      );
    }
  });

  test('段级重试账本:有进展清零、连续空手才放弃、退避封顶', () {
    for (final rawCase in data['attemptCases'] as List<dynamic>) {
      final c = rawCase as Map<String, dynamic>;
      final expected = c['expected'] as Map<String, dynamic>;
      final book = ChunkAttempts(
        stallLimit: c['stallLimit'] as int,
        attemptLimit: c['attemptLimit'] as int,
      );

      var i = 0;
      for (final rawStep in expected['steps'] as List<dynamic>) {
        final step = rawStep as Map<String, dynamic>;
        expect(book.noteFailure(step['progress'] as int), step['retry'],
            reason: '${c['name']}:第 $i 步的 retry');
        expect(book.delayMs, step['delayMs'],
            reason: '${c['name']}:第 $i 步的退避');
        i++;
      }
      expect(book.attempts, expected['attempts'],
          reason: '${c['name']}:attempts');
      expect(book.stalls, expected['stalls'], reason: '${c['name']}:stalls');
      expect(book.delayMs, expected['finalDelayMs'],
          reason: '${c['name']}:收尾时的退避');
    }
  });
}

/// 一直认领到 null,顺便断言每一段都接在上一段后面。返回认领次数。
int tiledChunks(int size, Chunk? Function(int claim) next) {
  var expectStart = 0;
  var claims = 0;
  while (true) {
    final chunk = next(claims);
    if (chunk == null) break;
    expect(chunk.start, expectStart,
        reason: '第 $claims 段起点是 ${chunk.start},应该接在 $expectStart');
    expectStart = chunk.end + 1;
    claims++;
    if (claims > 1000000) fail('认领不收敛,疑似死循环');
  }
  expect(expectStart, size, reason: '铺到 $expectStart,文件是 $size —— 有洞');
  return claims;
}
