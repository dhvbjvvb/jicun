/// 下载器的**纯逻辑**。
///
/// 这几个函数不属于任何一层 UI,也不碰网络:给定输入算出区间、下一跳、额度、
/// 重试账本的下一个状态。它们错了不会崩,只会**下出一个坏文件**(少一段、写重
/// 一段、或者 80% 处误报失败)—— 所以两端(Android Kotlin / Dart 兜底实现)各有
/// 一份,靠同一份测试向量锁住。
///
/// 向量在 `tool/download_logic_vectors.json`,两边都读它:
/// - Dart: `test/download_logic_vectors_test.dart`
/// - Kotlin: `android/app/src/test/kotlin/.../DownloadLogicVectorsTest.kt`
///
/// **谁在用**:Android 上跑的是原生实现(NativeDownloader,它有一份等价的 Kotlin
/// 判据);Dart 兜底引擎(`lib/downloader.dart` 的 `_fetchSegments`)直接调用本文件 ——
/// 所以它不是"只给测试看的规格",在那条路上就是真实的判据。两边靠同一份向量锁住。
library;

/// 一段闭区间 [start, end]。下标是**文件里的位置**,和 lane 数无关。
class Chunk {
  const Chunk(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start + 1;

  @override
  String toString() => '$start-$end';
}

/// 共享游标第 [claim] 次认领到的段。越界(认领次数超过段数)返回 null,调用方收工。
///
/// 区间必须严丝合缝地铺满 0..size-1:以前让每条 lane 各守一个固定区间,于是无论
/// 文件多大都只收到前 N 段,稳定报「下载不完整」。
Chunk? claimedChunk(int claim, int size, int chunkBytes) {
  final start = claim * chunkBytes;
  if (start >= size) return null;
  return Chunk(
    start,
    (size < start + chunkBytes ? size : start + chunkBytes) - 1,
  );
}

/// 同一次认领,但**把文件末尾那段切成小段**。
///
/// 大段在收尾时是灾难:真机实测 153MB、32 路时,最后一条慢连接把 4MB 拖了 8.5 秒。
/// 尾巴切成 1/4 大小,同一条慢连接的拖累就按 1/4 计。
///
/// 文件不到尾巴的两倍就整条按大段走,免得小文件平白多出一串握手。
Chunk? claimedChunkWithTail(
  int claim,
  int size,
  int chunkBytes,
  int tailBytes,
  int tailChunkBytes,
) {
  final tailFrom = size > tailBytes * 2 ? size - tailBytes : size;
  final headCount = (tailFrom + chunkBytes - 1) ~/ chunkBytes;
  if (claim < headCount) return claimedChunk(claim, tailFrom, chunkBytes);
  if (tailFrom >= size) return null;
  final tail = claimedChunk(claim - headCount, size - tailFrom, tailChunkBytes);
  if (tail == null) return null;
  return Chunk(tail.start + tailFrom, tail.end + tailFrom);
}

/// 这条连接该不该换掉。判据是「用了多久还没收完这一段」,不是速率 ——
/// 同一批连接之间差 20 倍是常态,拿绝对速率当判据不是误杀就是没反应。
///
/// 整条顺序写(start < 0)没有断点,换连接等于从 0 重来,所以不轮换。
bool shouldRotateConnection(
  int start,
  int written,
  int wanted,
  int elapsedMs,
  int budgetMs,
) => start >= 0 && written < wanted && elapsedMs >= budgetMs;

/// 带 Range 的请求回 200 时,这条响应是不是**就是我们要的那一段**。
///
/// 服务端可以忽略 Range 回 200 + 整条文件(RFC 7233),那种响应按偏移写会写坏;
/// 但区间本来就等于整条文件时(起点 0、长度也对得上),200 的内容正是要的那一段。
/// 实测微信视频号就是回 200 而不是 206。
bool wholeFileAsRange(int code, int start, int end, int contentLength) =>
    code == 200 && start == 0 && end >= 0 && contentLength == end + 1;

/// 断点续传的下一跳。夹在 end + 1 上:「收满整段之后立刻被 RST」会发生,那一跳
/// 必须正好是段尾 + 1,否则会发出 bytes=X-(X-1) 这种非法区间,换回来一个 416。
int resumeOffset(int written, int offset, int end) {
  final next = offset + written;
  return next < end + 1 ? next : end + 1;
}

/// 每个文件分到几路:同时在飞的连接数大致是「文件数 × 每个的路数」,批量下大文件
/// 时必须摊,否则 4 个视频各开满 32 条。小文件本来就不分段,摊不摊都一样。
int lanesPerItem(int lanes, int items) =>
    items <= 1 ? lanes : (lanes ~/ items < 1 ? 1 : lanes ~/ items);

/// 一段的「还要不要接着试」的账本。
class ChunkAttempts {
  ChunkAttempts({required this.stallLimit, required this.attemptLimit});

  final int stallLimit;
  final int attemptLimit;

  int attempts = 0;
  int stalls = 0;

  /// 记一次失败,[progress] 是这一次真正收下的字节数。返回 false = 该放弃了。
  ///
  /// 按**有没有进展**算,不是固定重试 N 次:B 站这类 CDN 每条连接限速、每几 MB
  /// 断一次,固定 3 次必然撞上「连续三次都断在同一位置」,于是 80% 处报错。
  bool noteFailure(int progress) {
    attempts++;
    stalls = progress > 0 ? 0 : stalls + 1;
    return stalls < stallLimit && attempts < attemptLimit;
  }

  /// 下一次尝试前等多久:200ms 起翻倍,封顶 2s。
  int get delayMs {
    final shift = (stalls - 1).clamp(0, 4);
    final value = 200 << shift;
    return value < 2000 ? value : 2000;
  }
}
