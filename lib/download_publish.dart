part of 'downloader.dart';

// 落盘那一步:进媒体库、写音频标签、盖下载日期,以及清理上次留下的孤儿分片。
//
// 这几个动作都要过平台通道,所以实现体本身很短,长的是「为什么这么写」的注释。

/// 盖日期的实际调用口。
///
/// **测试里直接跳过**:那批用例开着 [useDartEngine] 走假引擎,而且 testWidgets
/// 用的是假时钟 —— 真实文件 I/O 的 Future 不会被它推进,`await` 下去会让
/// `pumpAndSettle` 直接超时。生产(`useDartEngine == false`)照常盖。
Future<void> _stampDownloadedDate(File file) async {
  if (Downloader.useDartEngine) return;
  await Downloader.dateStampImpl(file);
}

/// 该写标签就写。
///
/// **必须在 `publishImpl` 之前调**:文件一进 MediaStore 就不再是应用能随便改的
/// 普通文件了(Android 10+ 的分区存储),那时候再想改内容得走 ContentResolver。
///
/// **失败一律吞掉**:标签是装饰,用户要的是那个文件。封面抓不到、容器认不出、
/// 磁盘写不动,都只留一条 debug 日志,照常把没标签的文件登记进媒体库。
Future<void> _tagIfNeeded(DownloadItem item, File file) async {
  final tags = item.tags;
  if (tags == null || tags.isEmpty || item.kind != MediaKind.audio) return;
  final dot = file.path.lastIndexOf('.');
  try {
    await Downloader.tagImpl(
      file,
      tags,
      dot < 0 ? '' : file.path.substring(dot),
    );
  } catch (error, stack) {
    if (kDebugMode) {
      debugPrint('[tag] ${item.fileName} 写标签失败,按原文件入库:$error\n$stack');
    }
  }
}

/// 交给原生侧落盘:没自定义就走媒体库,自定义了就把文件写进那个 SAF 目录。
/// 见 MainActivity 的 `publish`。
Future<String?> _publishToMediaStore(DownloadItem item, File file) {
  final target = Downloader.customStorage[item.kind];
  return Downloader._channel.invokeMethod<String>('publish', <String, String>{
    'path': file.path,
    'fileName': item.fileName,
    'kind': item.kind.wireName,
    if (target != null) 'treeUri': target.treeUri,
  });
}

/// 把已经登记进媒体库的一条删掉。见 MainActivity 的 `unpublish`。
Future<void> _unpublishFromMediaStore(String uri) => Downloader._channel
    .invokeMethod<void>('unpublish', <String, String>{'uri': uri});

/// 路径的最后一段。
///
/// 比路径时用它:两边各拼各的绝对路径,分隔符不一定一样 —— 本机(Windows)上
/// `listSync()` 给的是 `…\缓存\jicun_1_0.part`,而原生报回来的是我们传过去的
/// `…/缓存/jicun_1_0.part`,直接比字符串会比不上。
String _leaf(String path) => path.split(RegExp(r'[/\\]')).last;

/// 原生侧此刻正在写的那些临时文件(**文件名**,不是整条路径 —— 理由见 [_leaf])。
///
/// 只有保活(见 android 侧 DownloadKeepAlive)让进程活下来之后才有内容可问:那时用户
/// 重新打开应用会拿到一个新的 Dart 引擎,而下载还挂在旧引擎那个原生实例上。
///
/// 临时名本身唯一(`jicun_<微秒>_<序号>.part`),按文件名比就够。
///
/// 问不到就当没有下载在跑(旧版本原生、测试里没打桩):老行为是"分片一律清掉",退回
/// 那里只是少了一层保护,不会删错别的。
Future<Set<String>> _activeDownloadPaths() async {
  try {
    final list = await Downloader._channel.invokeListMethod<String>(
      'activeDownloads',
    );
    return {for (final path in list ?? const <String>[]) _leaf(path)};
  } catch (_) {
    return const <String>{};
  }
}
