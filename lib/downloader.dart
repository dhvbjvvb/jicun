import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'audio_tags.dart';
import 'download_logic.dart';
import 'failure.dart';
import 'media_date.dart';

/// 下载内容的类型。决定文件落到哪个公共媒体目录。
///
/// 顶层目录是 Android 按媒体类型锁死的(图片只能 DCIM/Pictures,视频 DCIM/Movies,
/// 音频 Music),所以三条路径必须和设置页「存储保存位置」显示的一字不差 —— 那页是
/// 给用户的承诺,改了这里必须同步改 MainActivity 的 `kindOf` 和设置页那张卡。
enum MediaKind {
  /// 视频 → `Movies/Jicun/Video/`
  video('video', 'Movies/Jicun/Video'),

  /// 音频 → `Music/Jicun/Music/`
  audio('audio', 'Music/Jicun/Music'),

  /// 图集 → `Pictures/Jicun/Picture/`
  image('image', 'Pictures/Jicun/Picture');

  const MediaKind(this.wireName, this.folder);

  /// 传给原生侧的标识。
  final String wireName;

  /// 展示用的目录名,拼提示文案时用。
  final String folder;
}

/// 用户给某个分类选的系统目录(SAF 目录选择器给的 tree uri)。
///
/// 有它就走这个目录,文件直接写进去;没有(或没选过)就沿用 [MediaKind] 那套
/// 媒体库路径。**代价**:写进 SAF 目录的文件不登记进系统媒体库,相册/音乐 App
/// 未必收录 —— 这是选「任意文件夹」时用户接受的取舍。
class StorageTarget {
  const StorageTarget({required this.treeUri, required this.label});

  /// `content://…` 的 tree uri,原生侧已经 takePersistableUriPermission。
  final String treeUri;

  /// 给界面看的可读路径,由原生侧从 documentId 拼出来。
  final String label;
}

/// 一条待下载的媒体。
class DownloadItem {
  DownloadItem({
    required this.url,
    required this.fileName,
    required this.kind,
    this.tags,
  });

  final String url;

  /// 落盘用的文件名。
  ///
  /// **下载途中会被改**:解析期只能按 URL 猜后缀(见 lib/pages/preview.dart 的
  /// `imageExt`),
  /// 而头条的直链以 `~tplv-tt-large.image` 结尾,猜出来的后缀和真实格式无关。收到
  /// 响应头/文件头之后由 `Downloader._retag` 改成真实格式,`publishImpl` 再拿它当
  /// MediaStore 的 `DISPLAY_NAME` —— 所以这里必须可变,只改临时文件的名字等于没改。
  String fileName;

  /// 这条按哪一种媒体归档。
  ///
  /// 解析期就定死了(见 lib/pages/preview.dart 的 `asVideo`),**收尾时不再按文件头
  /// 改它** —— 纯音频的 m4a 和视频共用同一个 `ftyp` 盒子,光看字节分不出这两种,
  /// 改过去只会把一份音频登记成视频(见 [Downloader._retag] 里那段注释)。
  final MediaKind kind;

  /// 落盘后要写进音频文件的标签(标题 / 作者 / 封面 / 歌词)。
  ///
  /// 只有 [MediaKind.audio] 用得到,别的类型一律 null —— 视频里内嵌一层音频标签
  /// 没有任何播放器会读。写失败不影响下载,见 [Downloader._tagIfNeeded]。
  final AudioTagInfo? tags;
}

/// 进度回调的参数。
///
/// 按**字节**算而不是按条数:并发下载时「下完几条」和「下了多少」不是一回事,
/// 而且一条 360MB 的视频和一条 500KB 的实况图按条数平均会让进度条乱跳。
class DownloadProgress {
  const DownloadProgress({required this.received, required this.total});

  /// 已经收下的字节数(所有条目加起来)。
  final int received;

  /// 预计总共要收的字节数。
  final int total;

  /// 整体进度(0~1)。不知道总量时按 0 报,由调用方决定怎么显示。
  double get fraction =>
      total <= 0 ? 0 : (received / total).clamp(0.0, 1.0).toDouble();
}

/// 用户点了「取消下载」。
///
/// 结果是"这一趟没下完":取消那一刻还没进相册的一律丢掉(原生把这一批临时文件
/// 全删了),分片也清干净。相册里留不留看几条:只下一条时撤回(相册里不该出现),
/// 多条时取消前已经写进相册的那几张留着。
class DownloadCancelled implements Exception {
  const DownloadCancelled();

  @override
  String toString() => '下载已取消';
}

/// 下载器。
///
/// **不用系统 DownloadManager** —— 那条路拿不到实时进度,卡片上那个转圈就只能
/// 假装在转。改成自己收流:每收一段就回调一次进度,百分比和圆环都是真的;
/// 用户点取消也能当场把 `.part` 删掉,不会在相册里留半个文件。
///
/// 一趟多条的规则(和 [saveAll] 一样):
/// - 全部下成 → 全部进相册,分片全清;
/// - 某一条失败 → 失败那条不留、其余照常进相册,报失败;
/// - 中途取消 → 相册里只留"取消那一刻已经写进去的"(单条时一条不留),
///   其余连同分片全部丢掉,报取消。
///
/// 多文件复用连接并有限并发;大文件由原生侧做 Range 并发。具体吞吐取决于
/// 当前设备、网络和 CDN,以同一链接的真机对比为准。
///
/// 代价是**没有跨进程续传**:APP 退到后台被系统杀掉,这一趟就断(需求要的就是能在
/// App 里取消,所以这一条可以接受)。
///
/// 别把这条读成"断了就得从头下":同一次任务**内部**的段级续传是有的 —— 连接被重置、
/// 或某条连接太慢时从断点接回去,见 NativeDownloader 的 ChunkAttempts / resumeOffset。
/// 两条不是一回事:一条说的是进程被杀了以后,一条说的是这一趟还在跑的时候。
class Downloader {
  static const MethodChannel _channel = MethodChannel('jicun/downloader');

  /// 平台通道。下载器自己用,应用内更新(APK 安装)也借它 —— 同一个通道上多挂
  /// 一个方法比再开一条通道省事,原生侧的 handler 本来就在一起。
  static const MethodChannel channel = _channel;

  /// 一条最多等多久没有任何数据。卡住的连接靠它超时,不然圆环会永远停在那里。
  static const Duration _idleTimeout = Duration(seconds: 30);

  /// 是否有原生下载任务在跑。
  ///
  /// [nativeDownload] 的进度回调是**通道级全局**的(dnProgress / dnDone 都不带任务
  /// id —— 理由见 handler 里那段说明),所以同一时刻只能有一个任务在飞。生产代码
  /// 目前也只有一个入口,但那是"调用点的自觉",不是约束:这里把它变成约束,第二个
  /// 任务当场失败,而不是安静地把两条下载的进度算到一起。
  ///
  /// **不是 `assert`**:带上它的那版只在调试构建里成立,release 上这个约束等于没
  /// 有 —— 而进度串了不会崩,只会让用户看到一个往回跳的百分比,那是最难查的一类
  /// 问题。代价只有一次 bool 判断。
  static bool _inFlight = false;

  /// 每个分类自定义的目录。空 = 走默认的媒体库路径(见 [MediaKind.folder])。
  ///
  /// 由设置页写入、启动时从偏好读回;真正用它的是 [_publishToMediaStore]。
  static final Map<MediaKind, StorageTarget> customStorage =
      <MediaKind, StorageTarget>{};

  /// 弹系统目录选择器让用户挑一个目录。用户取消返回 null。
  ///
  /// 原生侧见 MainActivity 的 `pickFolder`:返回 `{uri, label}`,并把
  /// takePersistableUriPermission 做掉(重启后还能写)。
  static Future<StorageTarget?> pickFolder() async {
    final res = await _channel.invokeMapMethod<String, Object?>('pickFolder');
    if (res == null) return null;
    final uri = res['uri'] as String?;
    if (uri == null || uri.isEmpty) return null;
    final label = (res['label'] as String?)?.trim() ?? '';
    return StorageTarget(treeUri: uri, label: label.isEmpty ? uri : label);
  }

  /// 同时下载的文件数。单个大文件内部的 Range 并发由 [maxSegments] 控制。
  static const int concurrency = 4;

  /// 大文件按 Range 分段并行,避免单连接吞吐成为瓶颈。
  ///
  /// 代价是每条新连接要付一次 TLS 握手(实测约 0.4s)。所以小文件不分段:
  /// 几 MB 的实况图多开几条,省下的时间还不够握手。超过 [segmentedFromBytes]
  /// 才分段,那时握手的开销在几分钟的传输面前可以忽略。
  ///
  /// 三个参数留成可改的静态字段只为了测试(不然一个用例要真下 8MB)。
  static int segmentedFromBytes = 8 << 20;

  /// 一段多大。
  ///
  /// 4MB 在请求次数与取消响应速度之间取平衡。
  ///
  /// 注意它同时是**内存峰值**的乘数:一个 worker 在内存里攒够一段才落盘,
  /// 并发 [maxSegments] 条时峰值约 `maxSegments × segmentBytes`
  /// (16 × 4MB = 64MB)。AndroidManifest 里开了 largeHeap 兜这个。
  static int segmentBytes = 4 << 20;

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
  static int maxSegments = 32;

  /// 不知道某条多大时,按这个字节数估进总量,免得进度条先冲到 100% 再倒退。
  static const int _unknownSizeGuess = 1024 * 1024;

  /// 尾巴阈值与尾巴粒度,**与原生侧同一套**(见 NativeDownloader 的 TAIL_BYTES)。
  ///
  /// 收尾那 32MB 按 1MB 切:大段在收尾时是灾难 —— 真机实测 153MB、32 路时,最后一条
  /// 慢连接把 4MB 拖了 8.5 秒;切成 1/4 大小,同一条慢连接的拖累就按 1/4 计。
  /// 文件不到尾巴的两倍就整条按大段走,免得小文件平白多出一串握手。
  static const int _tailBytes = 32 << 20;
  static const int _tailChunkBytes = 1 << 20;

  /// 一条连接最多收多久还没把当前这一段收完,就掐掉换一条(判据见
  /// [shouldRotateConnection])。与原生侧同一个量(10 秒):正常连接收一段 4MB 只要
  /// 2~5 秒,10 秒还没完的基本就是被限速那种。
  ///
  /// 留成可改的静态字段只为测试 —— 不然验"慢连接会被掐掉换一条"要真等 10 秒。
  static int connectionBudgetMs = 10000;

  /// 这一批下几条。分段时按它把每条的并行路数摊薄(见 [lanesPerItem]):4 个视频各开
  /// 32 条就是 128 条连接,那是拿去撞 CDN 并发上限的。由 [_saveAllInDart] 开工前设定。
  static int _batchItems = 1;

  /// 一段的「还要不要接着试」的账本参数,与原生侧一致:连着 4 次一个字节都没收到才算
  /// 这一段废了;[_chunkAttemptLimit] 是兜底,防止"每次都收到一点点"把重试拖成死循环。
  static const int _stallLimit = 4;
  static const int _chunkAttemptLimit = 40;

  /// 一条一条地下。[onProgress] 每收到一段数据回调一次,[cancelled] 为真时中止。
  ///
  /// 取消只保留**取消那一刻已经写进相册的**:单条时连它一起撤回,多条时留着;
  /// 其余(含已经下完、还没轮到登记的)和分片全部丢掉。某一条**失败**则是另一回事
  /// —— 失败那条不留,同一批里已经下完存好的照常进相册,最后再把失败报上去。
  ///
  /// 收流交给原生做(见 [nativeDownload]);Dart 只负责调度、定后缀和登记媒体库。
  static Future<void> saveAll(
    List<DownloadItem> items, {
    required void Function(DownloadProgress) onProgress,
    bool Function()? cancelled,
  }) async {
    final temp = await getTemporaryDirectory();
    if (useDartEngine) {
      // 测试专用:没有原生端时(或者要精确控制字节流时)走 Dart 实现。
      await _saveAllInDart(items, onProgress: onProgress, cancelled: cancelled);
      return;
    }
    await nativeDownload(
      items,
      temp: temp,
      onProgress: onProgress,
      cancelled: cancelled,
    );
  }

  /// 是否强制用 Dart 实现收流。**只给测试用**,生产代码不碰。
  ///
  /// 页面的 widget 测试不能真发网络请求,它们靠替换 [fetchImpl] 造数据 —— 而原生
  /// 那条路是走平台通道的,根本到不了 [fetchImpl]。所以测试开头把它设成 true,
  /// 让下载走 Dart 实现,替身才生效。
  @visibleForTesting
  static bool useDartEngine = false;

  /// 走原生并行下载,拿回落盘好的文件,再逐条定后缀、登记媒体库。
  ///
  /// 原生那边:一条连接一个 Range,每拉 4MB 换下一条,直接用 `seek` 写到目标文件的
  /// 对应偏移(不分片、不拼接)。返回的是 `{path, ext}` —— `ext` 是它从 Content-Type
  /// 猜的,`_retag` 拿它兜底(文件头嗅探优先)。
  static Future<void> nativeDownload(
    List<DownloadItem> items, {
    required Directory temp,
    required void Function(DownloadProgress) onProgress,
    bool Function()? cancelled,
  }) async {
    // 路径自己拼:原生按绝对路径写文件,不需要它去问 path_provider。
    //
    // 临时名**不带标题也不带后缀**:原生那头只负责收字节,名字由收尾的 `_retag`
    // 按真实内容定(文件头嗅探优先)。带标题会有两个后果 —— 带上原后缀会拼成
    // `X.mp4.mp4`(实测:原生版第一跑就撞上),而同标题的两条会落到同一个临时
    // 路径上互相覆盖(两次下载同一个视频就是这种情况)。临时名唯一,相册里叫
    // 什么只由 `item.fileName` 决定,两件事互不影响。
    final paths = [for (var i = 0; i < items.length; i++) _tempPath(temp, i)];
    final ownedPaths = paths.toSet();
    // 这一趟已经进相册的那些 uri:取消时按它撤回。
    //
    // 「取消 = 这一批什么都不要」是类文档给用户的承诺(见文件头)。原来是下完一条
    // 就登记一条,于是下 30 张图的图集下到第 3 张取消时,前两张已经躺在相册里了 ——
    // 用户看到的就是"取消了还留下东西"。
    //
    // **只有取消才回滚**:真失败(某一条下坏了、媒体库拒收)时,前面已经下完存好的
    // 那几条留着 —— 用户要的是"失败的那条不留",不是把成功的也一起收走。
    final publishedUris = <String>[];

    final completer = Completer<Map<Object?, Object?>>();
    var taskId = 0;
    // 进度按**搬运的字节**算,而一个任务要搬两遍同样的字节:先下到缓存,再写进相册。
    // 所以分母是网络总字节的两倍 —— 网络收完时是 50%,之后每写进相册一块都往前走,
    // 100% 只在最后一条真的进了相册那一刻出现。这样环全程都在动,也不会出现
    // "显示 100% 了、相册里还看不见"那一下。
    var networkTotal = 0;
    var networkBytes = 0;

    /// 正在写进相册的这一条,已经写了多少字节。
    var copyingBytes = 0;

    /// 前面几条已经进相册的字节合计。
    var publishedBytes = 0;

    void reportProgress() {
      // 还没问到总量:先不报(卡上本来就是 0%)。
      if (networkTotal <= 0) return;
      final work = networkTotal * 2;
      final done = math.min(networkBytes + publishedBytes + copyingBytes, work);
      onProgress(DownloadProgress(received: done, total: work));
    }

    Future<Object?> handler(MethodCall call) async {
      final args = (call.arguments as Map?) ?? const {};
      // 不按 id 过滤:`downloadMany` 的返回值(Dart 侧的 await)和原生第一条进度
      // 哪个先到是竞态的 —— 探针很快时进度可能先到,那时 taskId 还是 0,过滤就把
      // 第一条丢了。这个 handler 只在这次调用期间挂着,同一时刻只有一个下载任务,
      // 所以不过滤是安全的(dnDone 同样只有一个)。
      switch (call.method) {
        case 'dnProgress':
          // 网络那一段。
          networkBytes = (args['received'] as num?)?.toInt() ?? 0;
          final total = (args['total'] as num?)?.toInt() ?? 0;
          if (total > 0) networkTotal = total;
          reportProgress();
        case 'dnCopyProgress':
          // "搬进相册"那一段:原生每写一块报一次,环在这一段也一直在走
          // (见 MediaPublisher 的 handlePublish)。
          copyingBytes = (args['copied'] as num?)?.toInt() ?? 0;
          reportProgress();
        case 'dnDone':
          if (!completer.isCompleted) {
            completer.complete(
              (args['result'] as Map?)?.cast<Object?, Object?>() ?? const {},
            );
          }
      }
      return null;
    }

    if (_inFlight) {
      throw StateError(
        '同一时刻只能有一个原生下载任务:dnProgress / dnDone 不按任务 id 过滤,'
        '两个任务同时在跑,进度会互相串(见 handler 里的说明)。',
      );
    }
    _inFlight = true;
    _channel.setMethodCallHandler(handler);
    try {
      final started = await _channel.invokeMethod<Object?>('downloadMany', {
        'items': [
          for (var i = 0; i < items.length; i++)
            <String, Object?>{
              'url': items[i].url,
              'path': paths[i],
              'fileName': items[i].fileName,
              'kind': items[i].kind.wireName,
            },
        ],
        'segments': maxSegments,
      });
      if (started is! int) throw StateError('原生没有返回任务 id');

      taskId = started;
      // 取消:用户按了取消就通知原生停一次。原生的取消是"下一次检查点生效",所以
      // 仍要等它的 dnDone(它会带着 error=cancelled 回来)。
      //
      // **只发一次**:原来每 150ms 重发一遍,原生收到第一次就够了,重发的是几十次
      // 平台通道往返。这里改成下发失败(通道抖了一下)才在下一个 tick 补发 —— 那次
      // 丢了就再也没人告诉原生取消了,所以补发这条退路要留着。
      var cancelSent = false;
      final poll = Timer.periodic(const Duration(milliseconds: 150), (_) async {
        if (cancelSent || !(cancelled?.call() ?? false)) return;
        cancelSent = true;
        try {
          await _channel.invokeMethod<void>('cancelDownload', {'id': taskId});
        } catch (_) {
          cancelSent = false;
        }
      });

      Map<Object?, Object?> result;
      try {
        result = await completer.future;
      } finally {
        poll.cancel();
      }

      // 取消:这一趟**不再登记任何东西** —— 相册里只保留取消那一刻已经写进去的
      // (那是循环跑到一半时登记成功的,由下面的 catch 按条数决定撤不撤:单条撤回,
      // 多条留着);已经下完但还没轮到登记的那几条一起丢掉,它们只是缓存里的文件。
      //
      // 失败**不等于**整批不要:图集里第 29 张下砸了,前面 28 张照样要进相册,
      // 只有砸掉的那条不留(原生已经把它的文件删了)。所以失败不提前抛,先按
      // 「原生 files 列表 = 下成的那些」逐条登记,最后再把失败报上去。
      final error = result['error'];
      if (error == 'cancelled') throw const DownloadCancelled();
      var failure = error == null ? null : '$error';
      final failedNames = <String>[];

      // 收尾:定后缀(文件头嗅探优先,内容类型兜底)、改名、登记媒体库。
      //
      // **每一条都要先核对落地字节**:原生承诺了 size,这里再量一遍磁盘上的实际
      // 长度。不核的话,只要原生那层校验有洞(比如曾经用 setLength 预分配把文件
      // 撑到目标大小,"长度不足"这个判据就永远不成立),用户就会看到"下载完成"
      // 的通知、相册里却是一个前面有数据、后面全是空洞的坏文件 —— 实测就是这么
      // 漏出去的。两道校验都在,才谈得上"失败就是失败"。
      //
      // **按路径认领,不能按序号**:原生那边是几条并发跑完的,谁先下完谁先进
      // `files`,顺序和 `items` 对不上。混合卡(视频 + 图片)一整批下的时候按序号取
      // 就会把这条的 Content-Type 用到另一条上,后缀整个对调 —— 实测:图片存成
      // `.mp4`、视频存成 `.jpg`。单条下载只有一条,看不出问题。
      final files = (result['files'] as List?) ?? const [];
      final byPath = <String, Map<Object?, Object?>>{};
      for (final entry in files) {
        final info = (entry as Map?)?.cast<Object?, Object?>();
        final path = info?['path'] as String?;
        if (info != null && path != null) byPath[path] = info;
      }
      for (var i = 0; i < items.length; i++) {
        // 每登记一条之前先看一次取消:取消一旦生效就不再往相册里放新的东西。
        // 已经放进去的那些由 catch 决定(多条留着,单条撤回)。
        if (cancelled?.call() ?? false) throw const DownloadCancelled();
        final info = byPath[paths[i]];
        if (info == null) {
          // 原生没把它放进 files = 这一条没下成。留着的半个文件也删掉,别的照常。
          final stray = File(paths[i]);
          if (stray.existsSync()) stray.deleteSync();
          failedNames.add(items[i].fileName);
          continue;
        }
        final path = (info['path'] as String?) ?? paths[i];
        final probeExt = _extFromContentType(info['ext'] as String?);
        final raw = File(path);
        if (!raw.existsSync()) {
          failedNames.add(items[i].fileName);
          continue;
        }
        final expected = (info['size'] as num?)?.toInt() ?? 0;
        final actual = raw.lengthSync();
        if (expected > 0 && actual != expected) {
          // 这一条坏了:清掉它自己,其余已经下好的不受影响
          raw.deleteSync();
          failedNames.add(items[i].fileName);
          failure ??= '文件不完整:$actual/$expected 字节';
          continue;
        }
        // 这条的**后缀**按真实字节定而**类型**不动:解析期已经定了归档类型,字节只能
        // 区分容器、分不出'音频还是视频共用 ftyp 的 m4a'(见 [_retag] 里的三选一)。
        // 顺序上它必须赶在 `_tagIfNeeded` 之前 —— 那一步按 `item.kind` 决定要不要
        // 内嵌音频标签。
        final retagged = _retag(
          raw,
          items[i],
          // 解析期已经把序号拼进 `item.fileName`(见 lib/pages/preview.dart 的
          // _itemsToDownload),
          // 所以这里拆出来的 stem 就带着 `_1`、`_2`。
          _stemOf(items[i].fileName),
          probeExt,
        );
        ownedPaths.add(retagged.path);
        await _tagIfNeeded(items[i], retagged);
        // 登记进媒体库之前盖日期:相册扫元数据会读走创建 / 拍摄时间,
        // 盖晚了(入相册之后再改文件)就来不及了。
        await _stampDownloadedDate(retagged);
        final uri = await publishImpl(items[i], retagged);
        if (uri != null) publishedUris.add(uri);
        ownedPaths.remove(retagged.path);
        // 这一条已经进相册了:把它算进"已就位"的字节,并清掉"当前这条"的计数
        // (见上面的 reportProgress)。**放在 publish 之后**:没进相册就不算数。
        publishedBytes += expected > 0 ? expected : actual;
        copyingBytes = 0;
        reportProgress();
      }
      // 最后一条登记完到进度报满之间还有一个缝:这里取消同样不再往下登记。
      if (cancelled?.call() ?? false) throw const DownloadCancelled();
      if (failedNames.isNotEmpty) {
        throw HttpException(failure ?? '有 ${failedNames.length} 条没能下完');
      }
      // 收尾报满:这一刻所有条目都已经在相册里了(100% 与"已就位"是同一件事)。
      if (networkTotal > 0) {
        onProgress(
          DownloadProgress(received: networkTotal * 2, total: networkTotal * 2),
        );
      }
    } catch (error) {
      // 单文件取消:把这一条撤回 —— 用户按取消就是不要它,相册里不该出现。
      //
      // 多文件取消**不回滚**:前面那几条已经是完整的媒体文件了,取消只该停后面的,
      // 不该把已经下好的收走。分片清理在下面,两条路共用。
      if (error is DownloadCancelled && items.length == 1) {
        for (final uri in publishedUris) {
          try {
            await unpublishImpl(uri);
          } catch (error, stack) {
            // 撤不回来(个别 ROM 拒删)也不能挡住下面的清理和异常上报
            swallow('dl.unpublish-rollback', error, stack);
          }
        }
      }
      // 原生端会先删一次;这里再按本次任务掌握的路径兜底,覆盖通道异常、
      // 完整性校验失败和媒体库发布失败。删除是幂等的,不碰其他缓存文件。
      for (final path in ownedPaths) {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      }
      rethrow;
    } finally {
      _channel.setMethodCallHandler(null);
      _inFlight = false;
    }
  }

  /// 原生给的 MIME(`video/mp4; charset=…`)→ 后缀(`.mp4`)。
  ///
  /// 直接读 [_kMimeExt] 那张表,不走 `extensionForContentType` —— 后者要传一个
  /// 媒体类型,而这里正是不确定类型的时候(图集里混着视频)。
  ///
  /// **带点返回**:[_retag] 是拿 `stem + ext` 直接拼名字的(和
  /// `extensionForContentType` 那条路同一个用法),这里少一个点就会存出
  /// `标题mp4` 这种没有扩展名的文件。
  static String _extFromContentType(String? contentType) {
    if (contentType == null) return '';
    final mime = contentType.split(';').first.trim().toLowerCase();
    return _kMimeExt[mime] ?? '';
  }

  /// 文件名去掉后缀。`_retag` 拿它当"标题 + 批次序号"那一段,收尾时再按真实内容
  /// 补后缀 —— 带着原后缀走会拼成 `X.mp4.mp4`。
  static String _stemOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    // dot <= 0 保护的是 `.hidden` 这种(整个名字就是后缀)和没有后缀的名字。
    return dot <= 0 ? fileName : fileName.substring(0, dot);
  }

  /// 这一批里第 [index] 条用的临时文件路径。
  ///
  /// 名字只为**唯一**服务:下载任务之间、同一任务内的分片之间都不能撞。相册里叫
  /// 什么是 `item.fileName` 的事,和这里无关(见 [_retag])。
  static String _tempPath(Directory temp, int index) =>
      '${temp.path}/jicun_${DateTime.now().microsecondsSinceEpoch}_$index.part';

  /// Dart 侧的下载实现,只当原生的兜底(慢一倍以上)。逻辑与原来一致。
  static Future<void> _saveAllInDart(
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
    var expected = _unknownSizeGuess * items.length;

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
        '[dl] ${items.length} 个文件 · 每文件最多 $maxSegments 段 '
        '× ${(segmentBytes ~/ (1024 * 1024))}MB · 并发 $concurrency'
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
    _batchItems = items.length;
    final lanesEach = math.max(1, lanesPerItem(maxSegments, items.length));
    client.maxConnectionsPerHost =
        math.min(concurrency, items.length) * lanesEach;
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
              final size = sizes[index] > 0 ? sizes[index] : _unknownSizeGuess;
              bytes[index] = (size * f).round();
              report();
            },
            cancelled: cancelled,
            onSize: (size) => noteSize(index, size),
            client: client,
          );
          await _tagIfNeeded(item, file);
          await _stampDownloadedDate(file);
          await publishImpl(item, file);
          // 这条已经进相册了:算进"已就位"的字节(见 [report])。
          publishedBytes += sizes[index] > 0 ? sizes[index] : bytes[index];
          finished++;
          bytes[index] = sizes[index] > 0 ? sizes[index] : bytes[index];
          // 这条的实际大小比估值大/小都要修正,进度条才准
          noteSize(index, bytes[index]);
          report();
        }
      }

      await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
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
  static Future<File> _fetch(
    DownloadItem item,
    Directory temp, {
    required void Function(double) onFraction,
    bool Function()? cancelled,
    void Function(int size)? onSize,
    HttpClient? client,
  }) => fetchImpl(item, temp, onFraction, cancelled, onSize, client);

  /// 收流这一步的实现。
  ///
  /// 留成可替换的静态字段**只为了测试**:widget 测试里换成「立刻下完」或
  /// 「一直等着」的假实现,不然一次真网络请求会把用例拖成碰运气。生产代码不碰它。
  static Future<File> Function(
    DownloadItem item,
    Directory temp,
    void Function(double) onFraction,
    bool Function()? cancelled,
    void Function(int size)? onSize,
    HttpClient? client,
  )
  fetchImpl = _fetchOverHttp;

  /// 落盘这一步的实现。同上,测试里换成不发平台调用的假实现。
  ///
  /// 返回媒体库给的 uri(拿不到就是 null);取消/失败时靠它把已经登记进去的撤回。
  static Future<String?> Function(DownloadItem item, File file) publishImpl =
      _publishToMediaStore;

  /// 落盘前把文件里的创建 / 拍摄时间改成下载时间(见 [stampDownloadDate])。
  ///
  /// 留成可替换的静态字段只为了测试。
  static Future<void> Function(File file) dateStampImpl = stampDownloadDate;

  /// 盖日期的实际调用口。
  ///
  /// **测试里直接跳过**:那批用例开着 [useDartEngine] 走假引擎,而且 testWidgets
  /// 用的是假时钟 —— 真实文件 I/O 的 Future 不会被它推进,`await` 下去会让
  /// `pumpAndSettle` 直接超时。生产(`useDartEngine == false`)照常盖。
  static Future<void> _stampDownloadedDate(File file) async {
    if (useDartEngine) return;
    await dateStampImpl(file);
  }

  /// 写音频标签这一步的实现。同上,测试里换成不碰文件的假实现。
  ///
  /// 默认就是 [embedAudioTags] —— 它自己吞异常,所以这里不需要再包一层。
  static Future<bool> Function(File file, AudioTagInfo tags, String ext)
  tagImpl = (file, tags, ext) => embedAudioTags(file, tags, ext: ext);

  /// 该写标签就写。
  ///
  /// **必须在 `publishImpl` 之前调**:文件一进 MediaStore 就不再是应用能随便改的
  /// 普通文件了(Android 10+ 的分区存储),那时候再想改内容得走 ContentResolver。
  ///
  /// **失败一律吞掉**:标签是装饰,用户要的是那个文件。封面抓不到、容器认不出、
  /// 磁盘写不动,都只留一条 debug 日志,照常把没标签的文件登记进媒体库。
  static Future<void> _tagIfNeeded(DownloadItem item, File file) async {
    final tags = item.tags;
    if (tags == null || tags.isEmpty || item.kind != MediaKind.audio) return;
    final dot = file.path.lastIndexOf('.');
    try {
      await tagImpl(file, tags, dot < 0 ? '' : file.path.substring(dot));
    } catch (error, stack) {
      if (kDebugMode) {
        debugPrint('[tag] ${item.fileName} 写标签失败,按原文件入库:$error\n$stack');
      }
    }
  }

  /// 交给原生侧落盘:没自定义就走媒体库,自定义了就把文件写进那个 SAF 目录。
  /// 见 MainActivity 的 `publish`。
  static Future<String?> _publishToMediaStore(DownloadItem item, File file) {
    final target = customStorage[item.kind];
    return _channel.invokeMethod<String>('publish', <String, String>{
      'path': file.path,
      'fileName': item.fileName,
      'kind': item.kind.wireName,
      if (target != null) 'treeUri': target.treeUri,
    });
  }

  /// 撤销那一步的实现。同上,测试里可替换。
  static Future<void> Function(String uri) unpublishImpl =
      _unpublishFromMediaStore;

  /// 把已经登记进媒体库的一条删掉。见 MainActivity 的 `unpublish`。
  static Future<void> _unpublishFromMediaStore(String uri) =>
      _channel.invokeMethod<void>('unpublish', <String, String>{'uri': uri});

  /// 路径的最后一段。
  ///
  /// 比路径时用它:两边各拼各的绝对路径,分隔符不一定一样 —— 本机(Windows)上
  /// `listSync()` 给的是 `…\缓存\jicun_1_0.part`,而原生报回来的是我们传过去的
  /// `…/缓存/jicun_1_0.part`,直接比字符串会比不上。
  static String _leaf(String path) => path.split(RegExp(r'[/\\]')).last;

  /// 原生侧此刻正在写的那些临时文件(**文件名**,不是整条路径 —— 理由见 [_leaf])。
  ///
  /// 只有保活(见 android 侧 DownloadKeepAlive)让进程活下来之后才有内容可问:那时用户
  /// 重新打开应用会拿到一个新的 Dart 引擎,而下载还挂在旧引擎那个原生实例上。
  ///
  /// 临时名本身唯一(`jicun_<微秒>_<序号>.part`),按文件名比就够。
  ///
  /// 问不到就当没有下载在跑(旧版本原生、测试里没打桩):老行为是"分片一律清掉",退回
  /// 那里只是少了一层保护,不会删错别的。
  static Future<Set<String>> _activeDownloadPaths() async {
    try {
      final list = await _channel.invokeListMethod<String>('activeDownloads');
      return {for (final path in list ?? const <String>[]) _leaf(path)};
    } catch (_) {
      return const <String>{};
    }
  }

  /// 清掉上一次留下的孤儿分片。
  ///
  /// 正常路径上取消/失败都会当场删干净(见 [nativeDownload] 的兜底),这里兜的是
  /// **进程没了**那一条:下载中原生把目标文件预分配到全尺寸,APP 被系统杀掉(OOM、
  /// 用户上划清掉)时 finally 不会执行,缓存里就留下一个和视频一样大的 `.part`。
  /// 下一次启动扫一遍,把它们清掉 —— 这是"不管下没下成都不留分片"那条承诺的兜底。
  ///
  /// 唯独原生**正在写**的那几份跳过:保活之后进程可能活着、Dart 引擎却是新起来的一轮,
  /// 它们看着就像"上次留下的孤儿"(见 [_activeDownloadPaths])。
  ///
  /// [temp] 只给测试用;不传就取应用缓存目录。
  static Future<int> sweepLeftovers({Directory? temp}) async {
    final dir = temp ?? await getTemporaryDirectory();
    var removed = 0;
    // 原生正在写的那几份不能删:删了它还在往那个已经不在目录里的 inode 写,下完的文件
    // 找不到,收尾登记失败 —— 用户白等一场。
    final active = await _activeDownloadPaths();
    try {
      for (final entry in dir.listSync()) {
        // 只扫这一层:封面缓存是子目录,归 CoverCache 自己管
        if (entry is! File) continue;
        if (!entry.path.endsWith('.part')) continue;
        if (active.contains(_leaf(entry.path))) continue;
        try {
          entry.deleteSync();
          removed++;
        } catch (error, stack) {
          // 删不掉(被占用)就留着,下次启动再试
          swallow('dl.sweep-part', error, stack);
        }
      }
    } catch (error, stack) {
      // 目录读不动:不值得让启动失败
      swallow('dl.sweep-dir', error, stack);
    }
    if (removed > 0 && kDebugMode) {
      debugPrint('[dl] 清掉 $removed 个上次遗留的分片');
    }
    return removed;
  }

  static Future<File> _fetchOverHttp(
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
        throw HttpException(
          'HTTP ${probe.statusCode}',
          uri: Uri.parse(item.url),
        );
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
          total >= segmentedFromBytes &&
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
  static Future<HttpClientResponse> _probe(
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
  static int _sizeOf(HttpClientResponse response) {
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
  static Future<void> _fetchSingle(
    HttpClientResponse response,
    File target,
    int total,
    void Function(double) onFraction,
    bool Function()? cancelled,
  ) async {
    var received = 0;
    final sink = target.openWrite();
    try {
      await for (final chunk in response.timeout(_idleTimeout)) {
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
  static Future<void> _fetchSegments(
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
        segmentBytes,
        _tailBytes,
        _tailChunkBytes,
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
          stallLimit: _stallLimit,
          attemptLimit: _chunkAttemptLimit,
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
            await for (final block in response.timeout(_idleTimeout)) {
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
                connectionBudgetMs,
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
      math.min(maxSegments, lanesPerItem(maxSegments, _batchItems)),
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

  static Future<void> _append(IOSink sink, File source) async {
    await for (final chunk in source.openRead()) {
      sink.add(chunk);
    }
  }

  /// 服务端认不认范围请求。
  ///
  /// **不能只看 `Accept-Ranges`** —— 抖音视频 CDN 就不回这个头,但它对
  /// `Range: bytes=0-0` 明确回了 206,这就是认。实测真机:只看这个头会把
  /// 360MB 的视频判成"不分段",退回单连接,白等。
  static bool _acceptsRanges(HttpClientResponse response) =>
      response.statusCode == 206 ||
      (response.headers.value(HttpHeaders.acceptRangesHeader) ?? '')
          .toLowerCase()
          .contains('bytes');

  /// 按真实内容给这条媒体定名字,并把临时文件改成同名,返回改名后的文件。
  ///
  /// **为什么必须换**:`item.fileName` 的扩展名是解析期按 URL 猜的(见
  /// lib/pages/preview.dart 的 `imageExt`),而头条所有图片直链都过 CDN 变换,路径以
  /// `~tplv-tt-large.image`
  /// 结尾,没有 `.gif` / `.jpg` 可猜 —— 猜不到就落到兜底值。动图因此被命名成静态图
  /// 的后缀,部分看图软件不再播放动画,看起来就像"GIF 变 PNG 了"(实测:同一张
  /// 4.23MB 的 GIF89a,只是名字错了)。文件内容一直是原样的,这里只改名字,不重新
  /// 编码 —— 一旦解码再编码,动图必然被压成第一帧。
  ///
  /// 改的是 **`item.fileName` 本身**:`publishImpl` 拿它当 MediaStore 的
  /// `DISPLAY_NAME`,只改临时文件的话相册里还是错后缀(实测就是这么漏过去的)。
  ///
  /// 名字里那段 `.part` 也在这里掉:临时目录里它防的是"下了一半的文件被当成成品",
  /// 收完这一步就不需要了。
  ///
  /// [probeExt] 是下载前那一发探针响应里的 Content-Type,拿不到就是空串。
  ///
  /// [stem] 是这条最终名字里"标题 + 批次序号"那一段,由调用方给 —— 不是从
  /// `item.fileName` 里拆的:下载用的临时名和相册要用的名字现在是两回事(见
  /// [_tempPath]),拆临时名会拆出临时名的前缀。
  static File _retag(
    File file,
    DownloadItem item,
    String stem,
    String probeExt,
  ) {
    final sniffed = _sniffExt(file);
    // 后缀三选一:
    //   1. 嗅探结果和这条声明的类型对得上 → 用嗅探值(视频的 `.mp4`、图的 `.webp`…);
    //   2. **声明是音频、容器又是 MP4 家族** → 按 `.m4a` 记。这一条不能少:纯音频的
    //      m4a(B 站 DASH 那条音频流、/api/audio 抽出来的那份)与视频共用同一个 `ftyp`
    //      盒子,嗅探只能给出 `.mp4` —— 那是"视频"的后缀。照它登记的话,一份音频会顶着
    //      `video/mp4` 进 `Music/`,媒体库要么拒收要么归档错。
    //   3. 其余对不上的用 Content-Type 那条:字节和用途不是一回事,不硬按内容改名。
    final String ext;
    if (sniffed == null) {
      ext = probeExt;
    } else if (_kindOfExt(sniffed) == item.kind) {
      ext = sniffed;
    } else if (item.kind == MediaKind.audio &&
        _kIsoBmffExts.contains(sniffed)) {
      ext = '.m4a';
    } else {
      ext = probeExt;
    }
    // 后缀这一下可能比解析期猜的长(`.jpg` → `.webm`),总长由这里收口 ——
    // 解析期扣的是候选后缀里最长的那个,正常不会走到截断。
    final finalStem = _fitStem(stem, ext, _kMaxNameBytes);
    // 临时文件先腾地方:同一条被重新下过就可能占着这个名字
    final scratch = File('${file.parent.path}/${item.fileName}');
    if (scratch.existsSync()) scratch.deleteSync();
    if (ext.isEmpty) {
      // 认不出格式:名字照抄,只摘掉 `.part` 这个临时标记(一个字节的格式信息都给不出,
      // 解析期猜的后缀也就不必留了)。
      final plain = File('${file.parent.path}/$finalStem');
      if (plain.existsSync()) plain.deleteSync();
      return file.renameSync(plain.path);
    }
    final renamed = File('${file.parent.path}/$finalStem$ext');
    if (renamed.existsSync()) renamed.deleteSync();
    final moved = file.renameSync(renamed.path);
    item.fileName = '$finalStem$ext';
    return moved;
  }

  /// 读文件头几个字节认格式,认不出返回 null。
  ///
  /// 中段文件里 `_retag` 拿到的就是文件开头,所以这里读出来的就是真格式。
  static String? _sniffExt(File file) {
    RandomAccessFile? handle;
    try {
      handle = file.openSync();
      final head = handle.readSync(16);
      return extensionForBytes(head);
    } catch (_) {
      // 文件不在了/读不动:交给上层按 Content-Type 或原名字处理,不在这里炸
      return null;
    } finally {
      handle?.closeSync();
    }
  }
}

/// 文件头 → 扩展名。认不出返回空串。
@visibleForTesting
String extensionForBytes(List<int> head) {
  final b = head;
  bool at(int i, List<int> magic) {
    if (b.length < i + magic.length) return false;
    for (var k = 0; k < magic.length; k++) {
      if (b[i + k] != magic[k]) return false;
    }
    return true;
  }

  if (at(0, const <int>[0x47, 0x49, 0x46, 0x38])) return '.gif';
  if (at(0, const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return '.png';
  }
  if (at(0, const <int>[0xFF, 0xD8, 0xFF])) return '.jpg';
  if (at(0, const <int>[0x42, 0x4D])) return '.bmp';
  if (at(0, const <int>[0x1A, 0x45, 0xDF, 0xA3])) return '.webm';
  if (at(0, const <int>[0x66, 0x4C, 0x61, 0x43])) return '.flac';
  if (at(0, const <int>[0x4F, 0x67, 0x67, 0x53])) return '.ogg';
  if (at(0, const <int>[0x52, 0x49, 0x46, 0x46]) &&
      at(8, const <int>[0x57, 0x41, 0x56, 0x45])) {
    return '.wav';
  }
  if (at(0, const <int>[0x49, 0x44, 0x33]) ||
      at(0, const <int>[0xFF, 0xFB]) ||
      at(0, const <int>[0xFF, 0xF3])) {
    return '.mp3';
  }
  // RIFF 里还有 WEBP / AVI,两个都要看 offset 8 的 FOURCC
  if (at(0, const <int>[0x52, 0x49, 0x46, 0x46])) {
    if (at(8, const <int>[0x57, 0x45, 0x42, 0x50])) return '.webp';
    if (at(8, const <int>[0x41, 0x56, 0x49, 0x20])) return '.avi';
  }
  // HEIF/AVIF/MP4/MOV/M4A 共用一个盒子:offset 4 是 'ftyp',8 起是 brand
  if (at(4, const <int>[0x66, 0x74, 0x79, 0x70])) {
    final brand = String.fromCharCodes(
      b.sublist(8, b.length < 12 ? b.length : 12),
    );
    if (brand.startsWith('avif') || brand.startsWith('avis')) return '.avif';
    if (brand.startsWith('heic') ||
        brand.startsWith('heix') ||
        brand.startsWith('mif1')) {
      return '.heic';
    }
    if (brand.startsWith('qt')) return '.mov';
    if (brand.startsWith('M4A')) return '.m4a';
    // brand 认不出(CDN 常见):长度够了照样按 MP4 记 —— 猜错了也是所有播放器
    // 都吃的容器,比留着 .part 强
    return b.length >= 16 ? '.mp4' : '';
  }
  return '';
}

/// 认得出的扩展名 → 它是哪一种媒体。表只用来**校验**猜出来的后缀和这条的类型对不对
/// 得上,所以没法全(不在表里的就当"未知",不阻断改名)。
const Map<String, MediaKind> _extKind = <String, MediaKind>{
  'jpg': MediaKind.image,
  'jpeg': MediaKind.image,
  'png': MediaKind.image,
  'gif': MediaKind.image,
  'webp': MediaKind.image,
  'avif': MediaKind.image,
  'heic': MediaKind.image,
  'heif': MediaKind.image,
  'bmp': MediaKind.image,
  'tif': MediaKind.image,
  'tiff': MediaKind.image,
  'mp4': MediaKind.video,
  'm4v': MediaKind.video,
  'mov': MediaKind.video,
  'webm': MediaKind.video,
  'mkv': MediaKind.video,
  'avi': MediaKind.video,
  'flv': MediaKind.video,
  'ts': MediaKind.video,
  'mp3': MediaKind.audio,
  'm4a': MediaKind.audio,
  'aac': MediaKind.audio,
  'wav': MediaKind.audio,
  'flac': MediaKind.audio,
  'ogg': MediaKind.audio,
  'oga': MediaKind.audio,
  'opus': MediaKind.audio,
};

/// ISO-BMFF(MP4 家族)容器的后缀。
///
/// 音频和视频共用这一套盒子,光看文件头分不出谁是谁 —— 纯音频的 m4a 一样以 `ftyp`
/// 开头(实测 B 站那条纯音频流和抽轨出来的 m4a 都是 `ftypiso5`)。所以判类型不能只看
/// 后缀,得结合这条声明的媒体类型(见 [Downloader._retag])。
const Set<String> _kIsoBmffExts = <String>{'.mp4', '.m4v', '.mov'};

/// 扩展名属于哪一种媒体,表里没有返回 null(当"未知")。
MediaKind? _kindOfExt(String ext) =>
    _extKind[ext.startsWith('.') ? ext.substring(1) : ext];

/// Content-Type → 扩展名,认不出(包括 `application/octet-stream` 这种没信息的)返回空串。
///
/// 头条动图那条链路的响应头就是 `image/gif`,而 URL 后缀是 `~tplv-tt-large.image`,
/// 这是唯一能拿到正确后缀的地方 —— 所以下载器要拿响应头定名字,不能只信 URL。
@visibleForTesting
String extensionForContentType(String? contentType, MediaKind kind) {
  final mime = (contentType ?? '').split(';').first.trim().toLowerCase();
  final ext = _kMimeExt[mime];
  // 类型对不上就不用:标着 video 却回 image/gif 的地址,按音频/视频登记进媒体库会
  // 被系统拒收(见 MainActivity 的 mimeTypeOf),不如让原名字兜底。
  return ext != null && _kindOfExt(ext) == kind ? ext : '';
}

/// Content-Type → 扩展名(带点)。只认这几个,认不出返回 null。
///
/// 抽成顶层常量是因为有两处要用:上面按媒体类型校验的那条路,以及原生下载回来
/// 定后缀那条路(见 [Downloader._extFromContentType])—— 后者拿到的 MIME 不一定
/// 对应已知类型,所以直接查表、不做类型校验。
const Map<String, String> _kMimeExt = <String, String>{
  'image/gif': '.gif',
  'image/jpeg': '.jpg',
  'image/jpg': '.jpg',
  'image/pjpeg': '.jpg',
  'image/png': '.png',
  'image/webp': '.webp',
  'image/avif': '.avif',
  'image/heic': '.heic',
  'image/heif': '.heic',
  'image/bmp': '.bmp',
  'image/tiff': '.tiff',
  'video/mp4': '.mp4',
  'video/quicktime': '.mov',
  'video/webm': '.webm',
  'video/x-matroska': '.mkv',
  'audio/mpeg': '.mp3',
  'audio/mp4': '.m4a',
  'audio/aac': '.aac',
  'audio/wav': '.wav',
  'audio/x-wav': '.wav',
  'audio/flac': '.flac',
  'audio/ogg': '.ogg',
};

/// 把标题末尾的媒体后缀剥掉。
///
/// 有的平台标题就是文件名 —— 抖音这条实测是
/// `【8KHDR素材】…挪威冬日高画.mp4`。下载时落盘名是"标题 + 按地址猜的后缀",
/// 不剥的话会拼成 `…高画mp4.mp4`(实测:文件名里那个重复的 mp4 就是这么来的)。
///
/// 只认自己认得的那些后缀(见 [_extKind] 加几个常见的),别的 `.` 一律不动 ——
/// 标题里带点号太常见了(`1.2 万人点赞`),乱剥会把标题截掉一段。
String stripMediaExtension(String title) {
  final dot = title.lastIndexOf('.');
  if (dot <= 0 || dot == title.length - 1) return title;
  final ext = title.substring(dot + 1).toLowerCase();
  if (ext.length > 5 || !_extKind.containsKey(ext)) return title;
  return title.substring(0, dot);
}

/// 剥掉话题标签。`#冬日 #旅行` → 空,`原神#蒙德` → `原神 蒙德`。
///
/// 话题标签是给平台搜索用的,落进文件名只是白占字节 —— 而字节正是文件名最紧的
/// 资源(见 [safeFileName] 的上限)。字符集取到 64 字节那种 CJK 扩展区,是因为
/// 标签里常混着生僻字和 emoji 变体。
final RegExp _kHashtag = RegExp(r'#[^\s#]{0,32}', unicode: true);

/// emoji 与它们的装饰字符(变体选择符、零宽连接符、肤色修饰符、区域指示符)。
/// 这些在文件名里既不可读又占 3~4 字节,统一清掉。
final RegExp _kEmoji = RegExp(
  '['
  '\u{1F000}-\u{1FAFF}'
  '\u{2600}-\u{27BF}'
  '\u{FE00}-\u{FE0F}'
  '\u{200B}-\u{200D}'
  '\u{20E3}'
  '\u{1F1E6}-\u{1F1FF}'
  ']',
  unicode: true,
);

/// 同一个标点连打三下以上收成一个(`!!!` → `!`)。只收同一字符的连打:
/// `!?` 这种交替是用户真打出来的语气,动了就是改标题。
final RegExp _kPunctRun = RegExp(r'([!！?？~～。，,、])\1{2,}');

/// 压缩标题,让它更短但仍然认得出来是谁。
///
/// 四件事,按这个顺序做:剥话题标签、清 emoji 与非可读控制字符、收标点连打、
/// 折叠空白。**不动文字本身** —— 中文一个字 3 字节,是最贵的那部分,但它正是
/// 用户在相册里认文件的依据,再长也留着(截断交给 [safeFileName])。
String shortenTitle(String title) {
  return title
      .replaceAll(_kHashtag, ' ')
      .replaceAll(_kEmoji, '')
      .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
      // Dart 的 replaceAll 不认 `$1` 这种反向引用(会原样打出来),得走 mapped。
      .replaceAllMapped(_kPunctRun, (m) => m.group(1)!)
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// 字符串按 UTF-8 算多少字节。文件名上限是字节数,不是字符数。
int _utf8Len(String value) => utf8.encode(value).length;

/// 把解析出来的标题变成能落盘的文件名。
///
/// 保留中文(用户要靠它认文件),只清掉文件系统不接受的字符和控制字符。
///
/// **按字节截断,不按字符** —— 这里踩过坑:DownloadManager 限的是字节数,
/// 中文一个字 3 字节,而一个 52 字的标题就是 126 字节。当时按字符截到 60,
/// 结果系统从尾部继续砍,正好把 `.mp4` 扩展名切掉,存出来是个没有扩展名的文件
/// (实测:vivo + Android 17 上 130 字节的路径被截到 81 字节,扩展名没了)。
///
/// 66 字节 ≈ 22 个汉字,离已知会被截断的 81 字节还有余量。
///
/// [ext] 和 [index] 是**这次要拼在后面的后缀和序号**:上限量的是整个文件名,而
/// 调用方是在这个返回值后面再拼 `.mp4` 和 `_2` 的。不先扣掉的话,66 的上限形同虚设
/// (66 字节的标题 + `.mp4` 就是 70,离 81 那个已知会被砍的点只剩 11 字节余量)。
/// [ext] 传的是**候选后缀里最长的那个**:真实后缀要等下载器嗅探文件头才知道,
/// 现在多扣几字节,好过下载完发现总长超了没得改。
///
/// [index] 大于 0 时这里会**把它拼在末尾**(`标题_2`)并把它的字节算进上限 ——
/// 序号是名字的一部分,截断必须把它一起算,但它是"第几张"而不是标题里的话,
/// 不该被截掉。
String safeFileName(
  String raw, {
  String ext = '',
  int index = 0,
  String fallback = '即存媒体',
  int maxBytes = 66,
}) {
  final rawCleaned = raw
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .trim();
  // 先剥话题标签、清 emoji,再清非法字符 —— 顺序反了的话 `#` 已被换成 `_`,
  // 标签就剥不掉了。
  //
  // 只有压出来还有点东西才用:整个标题都是 emoji 时会被清成空串,那种情况宁可把
  // 它留着(`🎬🔥.mp4` 总比 `即存媒体.mp4` 认得出来),但一个字的残渣("警")也不如
  // 原名,所以门槛定在 2 字节。
  final stripped = shortenTitle(rawCleaned);
  final cleaned = (_utf8Len(stripped) >= 2 ? stripped : rawCleaned)
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      // 剥标签、清 emoji 都会留下连着好几个的下划线,收一收
      .replaceAll(RegExp(r'_{2,}'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final tail = index > 0 ? '_$index' : '';
  if (cleaned.isEmpty) return '$fallback$tail';

  // 后缀按 5 字节封顶:解析期猜出来的最长是 `.jpeg`,而 CDN 那种
  // `~tplv-tt-large.image` 会猜出 6 个字符的 `.image` —— 那是个错后缀,不值得为它
  // 多扣一个字节的标题。真按 6 字节存下来时,由 [_retag] 收口。
  final extBytes = math.min(utf8.encode(ext).length, _kMaxExtBytes);
  final suffix = extBytes + _indexBytes(index);
  final budget = maxBytes > suffix ? maxBytes - suffix : maxBytes;
  final bytes = utf8.encode(cleaned);
  if (bytes.length <= budget) return '$cleaned$tail';

  // 按字节切可能把一个多字节字符劈成两半,allowMalformed 会把残片换成 U+FFFD,
  // 再把它去掉 —— 否则文件名里会留一个乱码方块。
  final cut = utf8
      .decode(bytes.sublist(0, budget), allowMalformed: true)
      .replaceAll('\uFFFD', '')
      .trim();
  return cut.isEmpty ? '$fallback$tail' : '$cut$tail';
}

/// 解析期给后缀留的字节上限。见 [safeFileName] 里为什么封顶。
const int _kMaxExtBytes = 5;

/// 序号 `_12` 占几字节。0 号(不编号)不占。
int _indexBytes(int index) => index <= 0 ? 0 : '_$index'.length;

/// 一个文件名的字节上限。见 [safeFileName] 里那段实测说明。
const int _kMaxNameBytes = 66;

/// 把标题那段收到 `[maxBytes] - 后缀` 之内,返回截好的标题。
///
/// 收尾改后缀时用(真实后缀只有下载完才知道),保证"标题 + 后缀"永远不超上限。
/// 解析期已经按最长的候选后缀扣过一次,所以这里只有猜错后缀(比如猜 `.jpeg`
/// 真来 `.webm`,或者 CDN 那种 `.image` 猜不出真格式)时才会真截到东西。
String _fitStem(String stem, String ext, int maxBytes) {
  final budget = maxBytes - utf8.encode(ext).length;
  final bytes = utf8.encode(stem);
  if (bytes.length <= budget) return stem;
  // 按字节切可能把一个多字节字符劈成两半,allowMalformed 会把残片换成 U+FFFD,
  // 再把它去掉 —— 否则文件名里会留一个乱码方块。
  return utf8
      .decode(bytes.sublist(0, budget), allowMalformed: true)
      .replaceAll('\uFFFD', '')
      .trim();
}
