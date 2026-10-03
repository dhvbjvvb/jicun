part of 'downloader.dart';

// 收流那一段:HTTP 分段下载、连接预算、分片拼接,以及 Dart 兜底引擎的调度。
//
// 生产路径走原生(nativeDownload,还在 downloader.dart 里);这里是它的参照实现,
// 也是 useDartEngine 时真正干活的那条。

/// 这一批里第 [index] 条用的临时文件路径。
///
/// 名字只为**唯一**服务:下载任务之间、同一任务内的分片之间都不能撞。相册里叫
/// 什么是 `item.fileName` 的事,和这里无关(见 [_retag])。
String _tempPath(Directory temp, int index) =>
    '${temp.path}/jicun_${DateTime.now().microsecondsSinceEpoch}_$index.part';

/// Dart 侧的下载实现,只当原生的兜底(慢一倍以上)。逻辑与原来一致。
Future<void> _saveAllInDart(
  List<DownloadItem> items, {
  required void Function(DownloadProgress) onProgress,
  bool Function()? cancelled,
}) async {
  final temp = await getTemporaryDirectory();
  final bytes = List<int>.filled(items.length, 0);
  final sizes = List<int>.filled(items.length, 0);
  var finished = 0;

  /// 已经进相册的字节合计(和原生那条路同一个口径,见 [report])。
  var publishedBytes = 0;

  // 不知道大小的条目按一个保守值先估进总量,下完再按实际字节修正 ——
  // 这样进度条只会往前走,不会先冲到 100% 再倒退。
  var expected = Downloader._unknownSizeGuess * items.length;

  // 下载速度日志。给排障用:进度卡上也有实时 MB/s,但那是给用户看的,而
  // 「分段数该调多少」要靠一条能回看、带配置信息的数字。
  //
  // 节流到每 3 秒一行 —— 每个数据块都打会刷爆 logcat,噪声里也看不出趋势。
  // 只在 debug 构建里打:release 上 kDebugMode 编译期就是 false。
  final watch = Stopwatch()..start();
  var lastLogAt = 0;
  var lastLoggedBytes = 0;
  void logSpeed(int received) {
    if (!kDebugMode) return;
    final ms = watch.elapsedMilliseconds;
    if (ms - lastLogAt < 3000) return;
    lastLogAt = ms;
    final delta = received - lastLoggedBytes;
    lastLoggedBytes = received;
    debugPrint(
      '[dl] ${items.length} 个文件 · 每文件最多 $Downloader.maxSegments 段 '
      '× ${(Downloader.segmentBytes ~/ (1024 * 1024))}MB · 并发 $Downloader.concurrency'
      ' | 已收 ${(received / (1024 * 1024)).toStringAsFixed(1)}MB'
      ' | 近 3 秒 ${(delta / 3 / (1024 * 1024)).toStringAsFixed(2)} MB/s'
      ' | 全程均值 ${(received / (ms / 1000) / (1024 * 1024)).toStringAsFixed(2)} MB/s',
    );
  }

  void report() {
    // 与原生那条路同一个口径:**一个任务要搬两遍字节**(先下到缓存、再写进相册),
    // 所以分母是网络总量的两倍:网络收完时是 50%,之后每进相册一条都往前走,
    // 100% 由下面的收尾给 —— 那一刻全部条目都已经在位。
    final network = bytes.fold<int>(0, (a, b) => a + b);
    logSpeed(network);
    final work = (expected > 0 ? expected : 1) * 2;
    final done = (network + publishedBytes).clamp(0, work);
    onProgress(DownloadProgress(received: done, total: work));
  }

  report();

  void noteSize(int index, int size) {
    if (size <= 0 || size == sizes[index]) return;
    expected += size - sizes[index];
    sizes[index] = size;
    report();
  }

  // 并发下。CDN 单连接只有 0.32 MB/s 左右,串行下 30 条要等上一分钟;
  // 开 4 条并行实测能快 5 倍。
  final client = HttpClient();
  // 分段并行会把单文件的连接数顶到 maxSegments,而 HttpClient 默认卡 6 条 ——
  // 不放开的话第 7 段就在池子里排队,并行变成假并行。
  //
  // 批量下大文件时按文件数摊薄每条的额度(判据在规格里,见 [lanesPerItem]):
  // 4 个 100MB 的视频各开满 32 条就是 128 条,那是拿去撞 CDN 并发上限的。
  Downloader._batchItems = items.length;
  final lanesEach = math.max(
    1,
    lanesPerItem(Downloader.maxSegments, items.length),
  );
  client.maxConnectionsPerHost =
      math.min(Downloader.concurrency, items.length) * lanesEach;
  var next = 0;
  try {
    Future<void> worker() async {
      while (true) {
        if (cancelled?.call() ?? false) throw const DownloadCancelled();
        final index = next++;
        if (index >= items.length) return;
        final item = items[index];
        final file = await _fetch(
          item,
          temp,
          onFraction: (f) {
            // 单条这一秒的进度按它自己的大小折算成字节;总量未知时按估值算
            final size = sizes[index] > 0
                ? sizes[index]
                : Downloader._unknownSizeGuess;
            bytes[index] = (size * f).round();
            report();
          },
          cancelled: cancelled,
          onSize: (size) => noteSize(index, size),
          client: client,
        );
        await _tagIfNeeded(item, file);
        await _stampDownloadedDate(file);
        await Downloader.publishImpl(item, file);
        // 这条已经进相册了:算进"已就位"的字节(见 [report])。
        publishedBytes += sizes[index] > 0 ? sizes[index] : bytes[index];
        finished++;
        bytes[index] = sizes[index] > 0 ? sizes[index] : bytes[index];
        // 这条的实际大小比估值大/小都要修正,进度条才准
        noteSize(index, bytes[index]);
        report();
      }
    }

    await Future.wait([
      for (var i = 0; i < Downloader.concurrency; i++) worker(),
    ]);
  } finally {
    client.close();
  }
  if (finished < items.length) throw const DownloadCancelled();
  // 收尾:不管估算准不准,最后一定是满的,而且这一刻全部条目都已经在相册里了。
  onProgress(DownloadProgress(received: expected * 2, total: expected * 2));
}

/// 收一条到临时目录,返回落盘的文件。取消时删掉半个文件再抛 [DownloadCancelled]。
///
/// 转发到 [fetchImpl],生产代码不碰它。
Future<File> _fetch(
  DownloadItem item,
  Directory temp, {
  required void Function(double) onFraction,
  bool Function()? cancelled,
  void Function(int size)? onSize,
  HttpClient? client,
}) => Downloader.fetchImpl(item, temp, onFraction, cancelled, onSize, client);

Future<File> _fetchOverHttp(
  DownloadItem item,
  Directory temp,
  void Function(double) onFraction,
  bool Function()? cancelled,
  void Function(int size)? onSize,
  HttpClient? client,
) async {
  // 走 dart:io 的 HttpClient 而不是 package:http —— 前者能复用连接池,
  // package:http 的 IOClient 每次 send 都可能另起一条连接。
  final http = client ?? HttpClient();
  // 落盘的临时名唯一即可(见 [_tempPath]);相册里的名字由收尾的 [_retag] 按
  // `item.fileName` 定,两者解耦,下载途中不会互相覆盖。
  var target = File(_tempPath(temp, 0));
  final stem = _stemOf(item.fileName);
  final segments = <String, File>{};
  try {
    final probe = await _probe(item.url, http, cancelled);
    if (probe.statusCode != 200 && probe.statusCode != 206) {
      unawaited(probe.drain<void>().catchError((Object _) {}));
      throw HttpException('HTTP ${probe.statusCode}', uri: Uri.parse(item.url));
    }
    // 整条大小:206 得从 Content-Range 里读,`contentLength` 只是那 1 字节。
    final total = _sizeOf(probe);
    onSize?.call(total > 0 ? total : 0);
    // 探针那一发就带着响应头,顺手把这条的真扩展名定下来 —— 见 [_extensionFor]。
    final probeExt = extensionForContentType(
      probe.headers.contentType?.mimeType,
      item.kind,
    );
    // 服务端认 Range(回 206 就算认,不要求有 Accept-Ranges)、文件又够大,
    // 才分段并行。认不出大小或不支持就退回单连接老路 —— 慢总比下不动强。
    if (probe.statusCode == 206 &&
        total >= Downloader.segmentedFromBytes &&
        _acceptsRanges(probe)) {
      // 探针那 1 字节扔掉,连接强制关掉,别让脏连接回池子。
      unawaited(probe.drain<void>().catchError((Object _) {}));
      await _fetchSegments(
        item,
        http,
        target,
        segments,
        temp,
        total,
        onFraction,
        cancelled,
        // 分片的临时名挂在目标文件名上(`X.<序号>.part`),末尾那个 `.part` 不能少 ——
        // 启动清扫就按它认"下载留下的临时物"(见 [sweepLeftovers]);传别的前缀会留下
        // 一堆清扫认不出的孤儿分片。
        target.uri.pathSegments.last,
      );
      target = _retag(target, item, stem, probeExt);
      return target;
    }
    if (probe.statusCode == 206) {
      // 探针只拿到那 1 字节,整条重新要一次。复用探针那条连接反而是错的 ——
      // 服务端可能只发它承诺的那一段。
      unawaited(probe.drain<void>().catchError((Object _) {}));
      final fresh = await (await http.getUrl(Uri.parse(item.url))).close();
      if (fresh.statusCode != 200) {
        unawaited(fresh.drain<void>().catchError((Object _) {}));
        throw HttpException(
          'HTTP ${fresh.statusCode}',
          uri: Uri.parse(item.url),
        );
      }
      await _fetchSingle(
        fresh,
        target,
        fresh.contentLength,
        onFraction,
        cancelled,
      );
    } else {
      // 服务端对 Range 不理(回了 200),那这条连接上就是整个文件。
      await _fetchSingle(probe, target, total, onFraction, cancelled);
    }
    // 文件头比响应头可信(有些 CDN 的 Content-Type 是错的),所以最终以嗅探为准,
    // 嗅不出来才用探针那发的 Content-Type。
    target = _retag(target, item, stem, probeExt);
    return target;
  } catch (_) {
    // 失败或取消都不留半个文件
    if (target.existsSync()) target.deleteSync();
    for (final part in segments.values) {
      if (part.existsSync()) part.deleteSync();
    }
    rethrow;
  } finally {
    if (client == null) http.close(force: true);
  }
}

/// 探针:先要 1 个字节,把大小和服不服 Range 问清楚。
///
/// 用的是 `Range: bytes=0-0` 的 GET,不是 HEAD —— HEAD 看着更省,但它的
/// 响应流是另一种东西:在 Dart 里对 HEAD 响应 `await for` 一个字节都收不到
/// (实测),拿它当兜底那条路的内容源会写出一个 0 字节的文件,而且不报错。
/// 探出来的这个字节直接扔掉,连接也强制关掉,别把脏连接塞回池子。
Future<HttpClientResponse> _probe(
  String url,
  HttpClient http,
  bool Function()? cancelled,
) async {
  final request = await http.getUrl(Uri.parse(url));
  request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
  final response = await request.close();
  if (cancelled?.call() ?? false) {
    unawaited(response.drain<void>().catchError((Object _) {}));
    throw const DownloadCancelled();
  }
  return response;
}

/// 整条文件多大。200 用 `Content-Length`;206 得从 `Content-Range` 的
/// `bytes 0-0/12345` 里读 —— 206 的 `contentLength` 只是那一段的长度。
int _sizeOf(HttpClientResponse response) {
  if (response.statusCode == 206) {
    final value = response.headers.value(HttpHeaders.contentRangeHeader);
    final match = value == null
        ? null
        : RegExp(r'/(\d+)\s*$').firstMatch(value);
    if (match != null) return int.parse(match.group(1)!);
  }
  return response.contentLength;
}

/// 单连接收完一条。原来那条路,留着当兜底。
Future<void> _fetchSingle(
  HttpClientResponse response,
  File target,
  int total,
  void Function(double) onFraction,
  bool Function()? cancelled,
) async {
  var received = 0;
  final sink = target.openWrite();
  try {
    await for (final chunk in response.timeout(Downloader._idleTimeout)) {
      if (cancelled?.call() ?? false) throw const DownloadCancelled();
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onFraction((received / total).clamp(0.0, 1.0));
    }
    await sink.flush();
    await sink.close();
  } catch (_) {
    await sink.close();
    // 失败或取消都不留半个文件
    if (target.existsSync()) target.deleteSync();
    rethrow;
  }
}

/// 按 Range 把一条大文件切成几段并行收,收完按顺序拼成一个文件。
///
/// [stem] 只拿来给分片临时文件起名,和相册里的名字无关。
/// 按 Range 把一条大文件切成几段并行收,收完按顺序拼成一个文件。
///
/// **判据全部来自 [download_logic]**(跨端规格,和原生侧共用同一份测试向量):
/// 认领哪一段([claimedChunkWithTail])、续传从哪一跳([resumeOffset])、这条连接该不
/// 该掐掉换一条([shouldRotateConnection])、这一段还要不要接着试([ChunkAttempts])、
/// 200 的响应算不算"我们要的那一段"([wholeFileAsRange])。这里只负责把字节搬进分片
/// 文件和拼装 —— 那几条判据错了不会崩,只会安静地下出坏文件(少一段、写重一段),所以
/// 不许在这个文件里再写一遍。
///
/// [stem] 只拿来给分片临时文件起名,和相册里的名字无关。
Future<void> _fetchSegments(
  DownloadItem item,
  HttpClient http,
  File target,
  Map<String, File> segments,
  Directory temp,
  int total,
  void Function(double) onFraction,
  bool Function()? cancelled,
  String stem,
) async {
  var received = 0;
  // 排障用的分片埋点:同时在飞的段数到底是多少。真机上聚合速度只有 PC 的一半时,先看
  // 这里:maxInFlight 上不去是连接池/调度的事,上得去就是链路额度。
  var inFlight = 0;
  var maxInFlight = 0;
  var rotations = 0;
  final segWatch = Stopwatch()..start();
  // 进度按整条文件算:每个段收到多少都加进同一个计数,圆环才是一条直线
  void bump(int delta) {
    received += delta;
    onFraction((received / total).clamp(0.0, 1.0));
  }

  // 认领是**共享游标**:谁空谁领下一段,领完(返回 null)就收工。区间怎么切、尾巴怎么
  // 切小都在规格里(见 [claimedChunkWithTail])。认领号就是分片序号,拼装按它排序。
  var claims = 0;
  Chunk? claimNext() {
    final chunk = claimedChunkWithTail(
      claims,
      total,
      Downloader.segmentBytes,
      Downloader._tailBytes,
      Downloader._tailChunkBytes,
    );
    if (chunk != null) claims++;
    return chunk;
  }

  // 分片名:目标名摘掉 `.part` 再拼 `.<认领号>.part`。
  //
  // 末尾那个 `.part` **必须留着**:启动清扫按"文件名以 .part 结尾"认下载留下的临时物
  // (见 [sweepLeftovers])。原来写的是 `$stem.part$index`(=`…_0.part.part0`),结尾既不
  // 是 `.part` 又多了一层后缀 —— 进程半路被杀时那些分片清扫永远扫不到,一直占着缓存。
  String partNameOf(int index) {
    const marker = '.part';
    final base = stem.endsWith(marker)
        ? stem.substring(0, stem.length - marker.length)
        : stem;
    return '$base.$index$marker';
  }

  Future<void> one() async {
    while (true) {
      if (cancelled?.call() ?? false) throw const DownloadCancelled();
      final index = claims;
      final chunk = claimNext();
      if (chunk == null) return; // 领完了
      final name = partNameOf(index);
      final part = File('${temp.path}/$name');
      segments[name] = part;
      if (part.existsSync()) part.deleteSync();
      final ledger = ChunkAttempts(
        stallLimit: Downloader._stallLimit,
        attemptLimit: Downloader._chunkAttemptLimit,
      );
      while (true) {
        // 这一段已经落在盘上的那部分不再重下(见 [resumeOffset])。
        final written = part.existsSync() ? part.lengthSync() : 0;
        final from = resumeOffset(written, chunk.start, chunk.end);
        if (from > chunk.end) break; // 这一段满了
        if (cancelled?.call() ?? false) throw const DownloadCancelled();
        final request = await http.getUrl(Uri.parse(item.url));
        request.headers.set(
          HttpHeaders.rangeHeader,
          'bytes=$from-${chunk.end}',
        );
        final response = await request.close();
        // 服务端可以忽略 Range 回 200 + 整条(RFC 7233),那种响应按偏移写会写坏 ——
        // 除非**区间本来就等于整条**(起点 0、长度也对得上),那时 200 的内容正是要的
        // 那一段(实测微信视频号就是回 200 而不是 206)。判据在规格里。
        final usable =
            response.statusCode == 206 ||
            wholeFileAsRange(
              response.statusCode,
              from,
              chunk.end,
              response.contentLength,
            );
        if (!usable) {
          unawaited(response.drain<void>().catchError((Object _) {}));
          // 接着试还是判死,交给账本:没有进展才算停摆(见 [ChunkAttempts])。
          if (!ledger.noteFailure(0)) {
            throw HttpException(
              '分段下载被拒:HTTP ${response.statusCode}',
              uri: Uri.parse(item.url),
            );
          }
          await Future<void>.delayed(Duration(milliseconds: ledger.delayMs));
          continue;
        }
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        final startedAt = segWatch.elapsedMilliseconds;
        var got = 0;
        var rotated = false;
        final sink = part.openWrite(mode: FileMode.append);
        try {
          await for (final block in response.timeout(Downloader._idleTimeout)) {
            if (cancelled?.call() ?? false) throw const DownloadCancelled();
            sink.add(block);
            got += block.length;
            bump(block.length);
            // 慢连接:收了半天还没把这一段收完就掐掉换一条(判据在规格里)。跳出循环
            // 会取消这条订阅,HttpClient 随即丢掉这条连接,不会塞回池子。
            if (shouldRotateConnection(
              chunk.start,
              written + got,
              chunk.length,
              segWatch.elapsedMilliseconds - startedAt,
              Downloader.connectionBudgetMs,
            )) {
              rotated = true;
              break;
            }
          }
          await sink.flush();
          await sink.close();
        } catch (e) {
          await sink.close();
          if (e is DownloadCancelled) rethrow;
          // 半段留在盘上:下一次尝试从 [resumeOffset] 接着收,别删。
          if (!ledger.noteFailure(got)) rethrow;
          inFlight--;
          await Future<void>.delayed(Duration(milliseconds: ledger.delayMs));
          continue;
        }
        inFlight--;
        if (!rotated) break; // 这一段收完了 → 去领下一段
        rotations++;
        if (!ledger.noteFailure(got)) {
          throw HttpException(
            '这一段换了 ${ledger.attempts} 条连接还没收完:${chunk.start}-${chunk.end}',
            uri: Uri.parse(item.url),
          );
        }
        await Future<void>.delayed(Duration(milliseconds: ledger.delayMs));
      }
    }
  }

  // 开几条 worker:批量下大文件时按文件数摊薄(判据在规格里)。
  final lanes = math.max(
    1,
    math.min(
      Downloader.maxSegments,
      lanesPerItem(Downloader.maxSegments, Downloader._batchItems),
    ),
  );
  try {
    await Future.wait([for (var i = 0; i < lanes; i++) one()]);
    if (kDebugMode) {
      debugPrint(
        '[dl-seg] 分片数=$claims 同时在飞最多=$maxInFlight 掐掉的连接=$rotations '
        '总用时=${(segWatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s',
      );
    }
  } catch (_) {
    for (final part in segments.values) {
      if (part.existsSync()) part.deleteSync();
    }
    rethrow;
  }

  // 按认领号顺序拼:认领号就是文件里的先后顺序(head 段从小到大,尾巴段接在后面)。
  final sink = target.openWrite();
  try {
    for (var i = 0; i < claims; i++) {
      await _append(sink, segments[partNameOf(i)]!);
    }
    await sink.flush();
    await sink.close();
  } catch (_) {
    await sink.close();
    rethrow;
  }
  for (final part in segments.values) {
    if (part.existsSync()) part.deleteSync();
  }
  // 少收了字节就是残件 —— 宁可报错也别把半个视频交给相册
  if (target.lengthSync() != total) {
    throw HttpException(
      '分段下载不完整:${target.lengthSync()}/$total',
      uri: Uri.parse(item.url),
    );
  }
}

Future<void> _append(IOSink sink, File source) async {
  await for (final chunk in source.openRead()) {
    sink.add(chunk);
  }
}

/// 服务端认不认范围请求。
///
/// **不能只看 `Accept-Ranges`** —— 抖音视频 CDN 就不回这个头,但它对
/// `Range: bytes=0-0` 明确回了 206,这就是认。实测真机:只看这个头会把
/// 360MB 的视频判成"不分段",退回单连接,白等。
bool _acceptsRanges(HttpClientResponse response) =>
    response.statusCode == 206 ||
    (response.headers.value(HttpHeaders.acceptRangesHeader) ?? '')
        .toLowerCase()
        .contains('bytes');
