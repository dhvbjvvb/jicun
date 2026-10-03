part of 'downloader.dart';

// 下载器的参数与替身:能调的那几个数字,以及五步可替换的动作。
//
// 单独一个 part 是因为这里只有「配置」—— transport / naming / publish 三个 part
// 各是一段算法,和这两样东西不是一回事。

/// 收一条要用的那一批的上下文。
///
/// 收成一个对象而不是一串位置参数:替身(测试里那些)只关心其中两三样,展开写的话
/// 每个假实现都得把用不上的抄一遍,而且每加一个参数就要改一遍所有替身。
class FetchContext {
  const FetchContext({
    required this.temp,
    required this.tuning,
    required this.batchItems,
    required this.onFraction,
    this.cancelled,
    this.onSize,
    this.client,
  });

  /// 分片临时文件落在哪个目录。
  final Directory temp;

  /// 这一份下载器的参数(见 [DownloadTuning])。
  final DownloadTuning tuning;

  /// 这一批下几条。单文件内部的段数要按它摊薄(见 [lanesPerItem]):4 个视频各开满
  /// 32 条,那是拿去撞 CDN 并发上限的。
  final int batchItems;

  /// 这一条收到了多少(0~1)。
  final void Function(double) onFraction;

  /// 取消开关,为真时中止。
  final bool Function()? cancelled;

  /// 问出整条多大时回调一次。
  final void Function(int size)? onSize;

  /// 复用的连接池。批量下的时候由调用方建好并设过 maxConnectionsPerHost —— 不传就
  /// 自己新建一条(见 [_fetchOverHttp])。
  final HttpClient? client;
}

/// 收一条到临时目录,返回落盘的文件。
typedef DownloadFetcher = Future<File> Function(
  DownloadItem item,
  FetchContext ctx,
);

/// 下载器要用的那几件外部东西。
///
/// 它们原来是 [Downloader] 上的**静态**可替换字段:测试换掉、跑完再换回来,于是
/// 「这是一处测试替身」写在了生产代码里 —— 谁都能在任意时刻改,两个用例之间还会
/// 互相串,`main` 里还得挂一堆 `@visibleForTesting`。改成构造注入之后,生产代码里
/// 不再有测试后门:要替身就在构造时给一份。
class DownloadDeps {
  const DownloadDeps({
    this.fetch = _fetchOverHttp,
    this.publish = _publishToMediaStore,
    this.dateStamp = stampDownloadDate,
    this.tag = _embedAudioTags,
    this.unpublish = _unpublishFromMediaStore,
  });

  /// 收流那一步,默认 [DownloadFetcher] 的真实现 [_fetchOverHttp]。
  final DownloadFetcher fetch;

  /// 落盘那一步:登记进媒体库,返回它给的 uri(拿不到就是 null)。
  final Future<String?> Function(DownloadItem item, File file) publish;

  /// 落盘前把文件里的创建 / 拍摄时间改成下载时间(见 [stampDownloadDate])。
  final Future<void> Function(File file) dateStamp;

  /// 给音频文件写标签(标题 / 作者 / 封面 / 歌词)。
  final Future<bool> Function(File file, AudioTagInfo tags, String ext) tag;

  /// 撤销那一步:把已经登记进媒体库的一条删掉。
  final Future<void> Function(String uri) unpublish;

  /// 只换盖日期那一步。[Downloader] 的假引擎会用到(理由见那边的构造)。
  DownloadDeps withDateStamp(Future<void> Function(File) value) => DownloadDeps(
    fetch: fetch,
    publish: publish,
    dateStamp: value,
    tag: tag,
    unpublish: unpublish,
  );
}

/// 假引擎不盖日期用的空实现。见 [Downloader] 构造里那段。
Future<void> _skipDateStamp(File file) async {}

/// 下载器的可调参数。
///
/// 这几个数字原来是 [Downloader] 上的静态可变量,注释里写着「留成静态字段只为了
/// 测试」。收成一个不可变对象、由构造注入:要别的一套就在构造时给一份,运行期谁也
/// 改不动,两个用例之间也不会互相串。
///
/// 只放**真的调过**的那几个。与原生侧同一套数值的那些([Downloader.tailBytes] 之类)
/// 是协议的一部分,留在 [Downloader] 上不许动。
class DownloadTuning {
  const DownloadTuning({
    this.concurrency = 4,
    this.segmentedFromBytes = 8 << 20,
    this.segmentBytes = 4 << 20,
    this.maxSegments = 32,
    this.connectionBudgetMs = 10000,
  });

  /// 同时下载的文件数。单个大文件内部的 Range 并发由 [maxSegments] 控制。
  final int concurrency;

  /// 大文件按 Range 分段并行,避免单连接吞吐成为瓶颈;超过这个字节数才分段。
  ///
  /// 代价是每条新连接要付一次 TLS 握手(实测约 0.4s)。所以小文件不分段:几 MB 的
  /// 实况图多开几条,省下的时间还不够握手,那时握手的开销在几分钟的传输面前可以忽略。
  ///
  /// 做成参数是为了测试能调小 —— 不然验分段要真下 8MB。
  final int segmentedFromBytes;

  /// 一段多大。
  ///
  /// 4MB 在请求次数与取消响应速度之间取平衡。
  ///
  /// 注意它同时是**内存峰值**的乘数:一个 worker 在内存里攒够一段才落盘,并发
  /// [maxSegments] 条时峰值约 `maxSegments × segmentBytes`
  /// (16 × 4MB = 64MB)。AndroidManifest 里开了 largeHeap 兜这个。
  final int segmentBytes;

  /// 一个大文件最多同时开几条 Range 连接。速度取决于 CDN 和当前网络,界面上的
  /// 实时 MB/s 才是判断依据。
  ///
  /// **32 是真机扫出来的,别凭"少被重置"往下调**:降到 8 时速度几乎腰斩,连 16 都
  /// 只有 32 的一半 —— 这类链路上**单连接吞吐是被限住的**,聚合速度基本和 lane 数
  /// 成正比。同一条 153MB 的地址实测:16 路快段约 13.6MB/s,32 路快段约 25MB/s。
  ///
  /// `Connection reset` / 读超时那件事由**段级重试 + 断点续传**兜住
  /// (NativeDownloader 的 ChunkAttempts),不要拿并行度去换稳定性。
  ///
  /// 批量下大文件时原生侧会按文件数把额度摊薄(`lanesPerItem`),免得 4 个视频各开
  /// 32 条 = 128 条连接去撞 CDN 的并发上限。
  ///
  /// 想重新量,用 debug 构建:先 `--ei dl_segments 32` 定住档位,再照常下载看日志
  /// (见 lib/bench.dart)。
  final int maxSegments;

  /// 一条连接最多收多久还没把当前这一段收完,就掐掉换一条(判据见
  /// [shouldRotateConnection])。与原生侧同一个量(10 秒):正常连接收一段 4MB 只要
  /// 2~5 秒,10 秒还没完的基本就是被限速那种。
  ///
  /// 做成参数是为了测试 —— 不然验"慢连接会被掐掉换一条"要真等 10 秒。
  final int connectionBudgetMs;

  /// 只改其中几项,其余照旧。
  ///
  /// debug 构建里的 `--ei dl_segments N` 靠它把分段数临时换掉(见 lib/bench.dart)。
  /// 别的地方不用它:要另一套数值就在构造下载器时给一份新的。
  DownloadTuning copyWith({
    int? concurrency,
    int? segmentedFromBytes,
    int? segmentBytes,
    int? maxSegments,
    int? connectionBudgetMs,
  }) => DownloadTuning(
    concurrency: concurrency ?? this.concurrency,
    segmentedFromBytes: segmentedFromBytes ?? this.segmentedFromBytes,
    segmentBytes: segmentBytes ?? this.segmentBytes,
    maxSegments: maxSegments ?? this.maxSegments,
    connectionBudgetMs: connectionBudgetMs ?? this.connectionBudgetMs,
  );
}
