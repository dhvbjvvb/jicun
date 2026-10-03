// 两张下载进度卡(媒体下载 / 更新包下载)与更新包下载的控制器。
//
// 从 popup.dart 拆出来:两块加起来占了原文件四分之一,而它们和弹层外壳之间只有
// 「用一下」的关系 —— 外壳和进度环都由 popup.dart 转出来(见那里的 export)。

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:jicun/downloader.dart';
import 'package:jicun/ui/icons.dart';
import 'package:jicun/ui/notifications.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/ui/progress_ring.dart';
import 'package:jicun/ui/popup.dart';
import 'package:jicun/update_service.dart';

/// 下载进度卡片的干活方式:跑起来,往里推进度,并给一个「用户按了取消没」的查询。
typedef DownloadRun = Future<void> Function(
  void Function(DownloadProgress) onProgress,
  bool Function() cancelled,
);

/// 弹出下载进度卡片,把这一批媒体下完。返回时下载已经结束(或被取消)。
Future<void> showDownloadProgressCard(
  BuildContext context, {
  required String title,
  required int total,
  required DownloadRun run,
}) {
  return showCupertinoModalPopup<void>(
    context: context,
    // 卡片自己就是全部交互(取消 / 完成),点外面关掉会让人不知道下载还在不在
    barrierDismissible: false,
    // 遮罩只留很淡的一层:卡片是半透明玻璃底,遮罩一重就会把它衬得发灰、显得
    // 比预览卡"透"得多。真正的层次交给卡片背后那层模糊。
    barrierColor: const Color(0x14000000),
    builder: (context) =>
        DownloadProgressCard(title: title, total: total, run: run),
  );
}

/// 下载进度卡片。
///
/// 右上角是「下载进度」(没有关闭按钮:窗口只靠下面的按钮收),
/// 中间是波浪进度环(见 [ProgressRing]),下面是「取消下载」—— 下完就变成「完成」。
class DownloadProgressCard extends StatefulWidget {
  const DownloadProgressCard({
    super.key,
    required this.title,
    required this.total,
    required this.run,
  });

  final String title;
  final int total;
  final DownloadRun run;

  @override
  State<DownloadProgressCard> createState() => DownloadProgressCardState();
}

class DownloadProgressCardState extends State<DownloadProgressCard> {
  /// 用户按了「取消下载」。下载循环每一段都会问一次。
  bool _cancelled = false;
  bool _cancelling = false;

  /// 取消发出后,原生还没收完尾就先到了出口时限(见 [_cancelEscapeAfter])。
  bool _cancelTimedOut = false;

  /// 取消到「给出出口」之间的宽限。
  ///
  /// 原来这一段时间里按钮是**按不动的死按钮**:文案变成「正在取消」,但 onPressed 还是
  /// 那个一进来就 return 的 [_cancel],而窗口又不可点外部关闭 —— 网络卡住或媒体库搬运
  /// 慢的时候,用户既关不掉也取消不了,只能干等下载器自己的超时。
  /// 到点就给一个「关闭」:下载器那一趟仍在后台收尾(它自己会删掉半截文件),
  /// 关窗口只是不再看它,不是把收尾丢掉。
  static const Duration _cancelEscapeAfter = Duration(seconds: 8);
  Timer? _cancelEscape;

  /// 下载这一趟的 Future。取消时要等它真收完尾(删掉半个文件)才关窗口 ——
  /// 先关窗口再让下载继续跑,相册里就可能留下半个文件。
  Future<void>? _running;

  double _fraction = 0;
  bool _failed = false;

  /// 失败原因。原因就写在卡里,不再另弹一个提示窗:另弹的那个是另一套长相
  /// (检查更新图标 + 「知道了」),和成功态摆在一起就是两张卡两个样。
  String _error = '';

  /// 这次下载收了多少字节,以及从开始到现在过了多久。用来算实时速度。
  ///
  /// 两个都要:**只有字节数看不出快慢**,要除时间才是 MB/s。这也让"调分段数到底
  /// 有没有用"变成屏幕上能看懂的一个数字(见 Downloader.maxSegments 的注释)。
  int _received = 0;
  final Stopwatch clock = Stopwatch();

  @override
  void initState() {
    super.initState();
    clock.start();
    _running = widget.run(_onProgress, () => _cancelled);
    // 错误在这里处理,不往上抛:整趟下载在这张卡里闭环
    _running!.then<void>((_) {
      // 极小概率下用户点取消时下载恰好已经完成,也应该按用户意图关掉卡片。
      if (_cancelled) _close();
    }, onError: _onError);
  }

  /// 进度按字节报,条数只用来在副标题里说「一共几条」。
  void _onProgress(DownloadProgress p) {
    if (!mounted) return;
    _received = p.received;
    // 每个百分点刷一次 setState(一秒几十次的原始回调太密)。速度那一行跟着
    // 这个节奏走就够了 —— 它要的是"大概多快",不是每一帧都精确。
    if ((p.fraction * 100).floor() == (_fraction * 100).floor()) return;
    setState(() => _fraction = p.fraction);
  }

  /// 「3.2 MB/s」这类实时速度。还没收到数据、或者刚起步不到半秒时是空串 ——
  /// 那时候算出来的数字是抖的,显示出来只会让人以为卡了。
  String get _speedText {
    final seconds = clock.elapsedMilliseconds / 1000;
    if (_received <= 0 || seconds < 0.5) return '';
    final mbps = _received / seconds / (1024 * 1024);
    return '${mbps.toStringAsFixed(1)} MB/s';
  }

  /// 还要多久。速度太低(不到 64 KB/s)时不给,那种估算只会吓人。
  String get _etaText {
    final seconds = clock.elapsedMilliseconds / 1000;
    final total = _totalBytes;
    if (_received <= 0 || total <= 0 || seconds < 1) return '';
    final speed = _received / seconds;
    if (speed < 64 * 1024) return '';
    final remain = (total - _received) / speed;
    if (remain <= 0) return '';
    // 先取整再拆分秒:直接对秒取余会打出「约 5 分60 秒」那种(359.5 秒)。
    final left = remain.round();
    final minutes = left ~/ 60;
    final secs = left % 60;
    return minutes > 0 ? '约 $minutes 分$secs 秒' : '约 $secs 秒';
  }

  /// 这趟下载的总字节数。进度是分数,反推出来的 —— 这一层拿不到原始总量。
  int get _totalBytes => _fraction <= 0 ? 0 : (_received / _fraction).round();

  void _onError(Object error) {
    if (!mounted) return;
    // 取消不是错误:取消是用户自己按的,窗口直接关掉
    if (error is DownloadCancelled) {
      _close();
      return;
    }
    setState(() {
      _failed = true;
      _error = downloadErrorMessage(error);
    });
  }

  bool get _done => _fraction >= 1 && !_failed;

  void _close() {
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  /// 发出取消后由下载器断开连接并清理文件;收到完成回调后再关窗口。
  void _cancel() {
    if (_cancelling) return;
    setState(() {
      _cancelled = true;
      _cancelling = true;
    });
    _cancelEscape = Timer(_cancelEscapeAfter, () {
      if (!mounted) return;
      setState(() => _cancelTimedOut = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final secondary = settingsPalette(isDark).secondary;
    return PopupShell(
      title: '下载进度',
      icon: popupIcon(context, '下载进度.svg'),
      // 不给关闭叉:窗口只能靠下面的「取消下载 / 完成」收,
      // 免得下载中手一滑把窗口关掉、以为下载也停了。
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _title(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: secondary, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          Center(
            child: ProgressRing(
              progress: _fraction,
              failed: _failed,
              isDark: isDark,
            ),
          ),
          // 速度 + 预计还要多久。大文件(这条抖音的原画 7.27GB)没有这两个数字,
          // 用户只能盯着一个百分比猜;而且它也是调分段数的依据。
          if (!_failed)
            Builder(
              builder: (context) {
                final parts = <String>[
                  if (_speedText.isNotEmpty) _speedText,
                  if (_etaText.isNotEmpty) _etaText,
                ];
                if (parts.isEmpty) return const SizedBox(height: 2);
                return Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Center(
                    child: Text(
                      parts.join(' · '),
                      style: TextStyle(color: secondary, fontSize: 12.5),
                    ),
                  ),
                );
              },
            ),
          if (_failed) ...[
            const SizedBox(height: 10),
            Text(
              _error,
              textAlign: TextAlign.center,
              style: TextStyle(color: secondary, fontSize: 12.5),
            ),
          ],
          const SizedBox(height: 14),
          PopupPrimaryButton(
            label: _failed || _cancelTimedOut
                ? '关闭'
                : (_done ? '完成' : (_cancelling ? '正在取消…' : '取消下载')),
            // 失败之后下载循环早就结束了,再按「取消下载」没人接 —— 窗口会永远
            // 卡在那儿。这时按钮就是关窗口。
            //
            // 取消已经下发、还没收尾时:按钮**明确置灰**(onPressed 为 null),而不是
            // 留一颗按不动却看着能按的按钮;超过 [_cancelEscapeAfter] 就换成「关闭」这个
            // 出口(见那个常量的说明)。
            onPressed: _failed || _done || _cancelTimedOut
                ? _close
                : (_cancelling ? null : _cancel),
          ),
        ],
      ),
    );
  }

  /// 窗口收掉时把那个出口计时器一起收:留着就是"测试里报 Timer is still pending"
  /// (widget 测试会在销毁后判它),真机上则是一个没人管的 8 秒回调。
  @override
  void dispose() {
    _cancelEscape?.cancel();
    _cancelEscape = null;
    super.dispose();
  }

  String _title() {
    if (_failed) return '${widget.title} · 下载中断';
    if (_done) return '${widget.title} · 已存到 JICUN';
    // 网络收完 ≠ 已经入库:后面还有一步"把文件搬进媒体库"。进度口径是**搬两遍字节**
    // (先下到缓存、再写进相册),所以网络收完那一刻正好是 50% —— 从这里到 100% 就是
    // 那一段,环在这一段也一直在走(见 lib/downloader.dart 的 reportProgress)。
    if (_fraction >= 0.5) return '${widget.title} · 正在保存到相册';
    // 并发下载时没法说「第几个」——几条在同时下,说条数只会有误导
    if (widget.total > 1) return '${widget.title} · 共 ${widget.total} 个';
    return widget.title;
  }
}

// ────────────────────────── 更新包下载 ──────────────────────────

/// 更新包下载进度窗口。
///
/// 和媒体下载那张卡同一套骨架,区别只有三处:进度按**百分比**报(需求要的)、
/// 失败时在卡里留一句原因、下完之后不是"已存到相册"而是交给系统安装器。
Future<void> showApkDownloadCard(
  BuildContext context, {
  required String title,
  required String subtitle,
  required ApkDownloadController controller,
}) {
  return showCupertinoModalPopup<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: const Color(0x14000000),
    builder: (context) => ApkDownloadCard(
      title: title,
      subtitle: subtitle,
      controller: controller,
    ),
  );
}

/// 更新下载的控制权。
///
/// 下载不是这张卡发起的(卡只负责显示),所以进度、取消、失败都由外面推进来 ——
/// 用一个小对象当"遥控器",比把整条下载逻辑塞进卡里清楚。
class ApkDownloadController extends ChangeNotifier {
  ApkProgress _progress = const ApkProgress(received: 0, total: 0);
  bool _cancelled = false;
  bool _closed = false;
  String? _error;

  ApkProgress get progress => _progress;
  bool get cancelled => _cancelled;
  bool get closed => _closed;
  String? get error => _error;
  bool get failed => _error != null;

  void report(ApkProgress value) {
    _progress = value;
    notifyListeners();
  }

  /// 用户点了「取消更新」。下载循环会看到 [cancelled]。
  void cancel() {
    _cancelled = true;
    notifyListeners();
  }

  void fail(String message) {
    _error = message;
    notifyListeners();
  }

  /// 收窗口(取消收尾完成 / 安装器已经拉起)。
  void close() {
    _closed = true;
    notifyListeners();
  }
}

class ApkDownloadCard extends StatefulWidget {
  const ApkDownloadCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.controller,
  });

  final String title;
  final String subtitle;
  final ApkDownloadController controller;

  @override
  State<ApkDownloadCard> createState() => ApkDownloadCardState();
}

class ApkDownloadCardState extends State<ApkDownloadCard> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    super.dispose();
  }

  void _onController() {
    if (!mounted) return;
    // 外面说"收窗口"(取消收尾完成 / 安装器已拉起)就关掉自己
    if (widget.controller.closed) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {});
  }

  void _close() {
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final (foreground: foreground, secondary: secondary) = settingsPalette(
      isDark,
    );
    final controller = widget.controller;
    final failed = controller.failed;
    final done = controller.progress.fraction >= 1 && !failed;
    final percent = (controller.progress.fraction * 100).floor();

    return PopupShell(
      title: widget.title,
      icon: popupIcon(context, '下载进度.svg'),
      onClose: _close,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            failed
                ? '下载没完成'
                : done
                ? '下载完成,正在安装'
                : widget.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: secondary, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          Center(
            child: ProgressRing(
              progress: controller.progress.fraction,
              failed: failed,
              isDark: isDark,
              diameter: 112,
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              failed ? '—' : '$percent%',
              style: TextStyle(
                color: foreground,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (failed) ...[
            const SizedBox(height: 6),
            Text(
              controller.error ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(color: secondary, fontSize: 12),
            ),
          ],
          const SizedBox(height: 14),
          PopupPrimaryButton(
            label: failed
                ? '关闭'
                : done
                ? '完成'
                : '取消更新',
            onPressed: failed || done ? _close : controller.cancel,
          ),
        ],
      ),
    );
  }
}
