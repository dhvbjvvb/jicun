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

part 'download_naming.dart';
part 'download_publish.dart';
part 'download_transport.dart';

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
  /// 响应头/文件头之后由 `_retag` 改成真实格式,`publishImpl` 再拿它当
  /// MediaStore 的 `DISPLAY_NAME` —— 所以这里必须可变,只改临时文件的名字等于没改。
  String fileName;

  /// 这条按哪一种媒体归档。
  ///
  /// 解析期就定死了(见 lib/pages/preview.dart 的 `asVideo`),**收尾时不再按文件头
  /// 改它** —— 纯音频的 m4a 和视频共用同一个 `ftyp` 盒子,光看字节分不出这两种,
  /// 改过去只会把一份音频登记成视频(见 [_retag] 里那段注释)。
  final MediaKind kind;

  /// 落盘后要写进音频文件的标签(标题 / 作者 / 封面 / 歌词)。
  ///
  /// 只有 [MediaKind.audio] 用得到,别的类型一律 null —— 视频里内嵌一层音频标签
  /// 没有任何播放器会读。写失败不影响下载,见 [_tagIfNeeded]。
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

  /// 写音频标签这一步的实现。同上,测试里换成不碰文件的假实现。
  ///
  /// 默认就是 [embedAudioTags] —— 它自己吞异常,所以这里不需要再包一层。
  static Future<bool> Function(File file, AudioTagInfo tags, String ext)
  tagImpl = (file, tags, ext) => embedAudioTags(file, tags, ext: ext);

  /// 撤销那一步的实现。同上,测试里可替换。
  static Future<void> Function(String uri) unpublishImpl =
      _unpublishFromMediaStore;

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
}
