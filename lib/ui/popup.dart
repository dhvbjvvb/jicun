import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:jicun/downloader.dart';
import 'package:jicun/parse_service.dart';
import 'package:jicun/ui/glass.dart';
import 'package:jicun/ui/icons.dart';
import 'package:jicun/ui/notifications.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/update_service.dart';
import 'package:jicun/widgets/animated_tab_icon.dart';

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

  /// 下载这一趟的 Future。取消时要等它真收完尾(删掉半个文件)才关窗口 ——
  /// 先关窗口再让下载继续跑,相册里就可能留下半个文件。
  Future<void>? _running;

  double _fraction = 0;
  bool _failed = false;

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
    final minutes = remain ~/ 60;
    final secs = (remain % 60).round();
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
    setState(() => _failed = true);
    showInfo(context, '下载没能完成', downloadErrorMessage(error));
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
          const SizedBox(height: 14),
          PopupPrimaryButton(
            label: _done ? '完成' : (_cancelling ? '正在取消' : '取消下载'),
            onPressed: _done ? _close : _cancel,
          ),
        ],
      ),
    );
  }

  String _title() {
    if (_failed) return '${widget.title} · 下载中断';
    if (_done) return '${widget.title} · 已存到 JICUN';
    // 网络收完到相册可见之间还有一步:把文件整个搬进媒体库(见 MainActivity.publish,
    // 那一步是本地读写,没有进度可报)。这段时间进度环钉在 99%,不给一句话用户只会
    // 觉得"卡死了"。
    if (_fraction >= 0.99) return '${widget.title} · 正在保存到相册';
    // 并发下载时没法说「第几个」——几条在同时下,说条数只会有误导
    if (widget.total > 1) return '${widget.title} · 共 ${widget.total} 个';
    return widget.title;
  }
}

// ────────────────────────── 版本更新 ──────────────────────────

/// 更新卡的预览窗口固定显示这么多行。多了就在右侧出滚动条。
///
/// 需求定的是"固定 12 行字":所以窗口高度按行高算死,不随内容长短变 —— 换个
/// release 说明就是一屏不一样高,卡片会跳。
const int kNotesLines = 12;

/// 滚动条占的宽度(量文字宽度时要减掉)。
const double kScrollbarGutter = 10;

/// 弹「版本更新」卡片。
///
/// [onUpdate]/[onIgnore] 由调用方决定做什么(下载安装 / 记住忽略的版本),卡片
/// 自己只管显示和把选择报回去。
Future<void> showUpdateCard(
  BuildContext context, {
  required ReleaseInfo release,
  required String currentVersion,
  required VoidCallback onUpdate,
  required VoidCallback onIgnore,
}) {
  return showCupertinoModalPopup<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: const Color(0x14000000),
    builder: (context) => UpdateCard(
      release: release,
      currentVersion: currentVersion,
      onUpdate: onUpdate,
      onIgnore: onIgnore,
    ),
  );
}

/// 「版本更新」卡片:标题 + 版本号 + 说明预览(markdown)+ 底部左更新右忽略。
class UpdateCard extends StatelessWidget {
  const UpdateCard({
    super.key,
    required this.release,
    required this.currentVersion,
    required this.onUpdate,
    required this.onIgnore,
  });

  final ReleaseInfo release;
  final String currentVersion;
  final VoidCallback onUpdate;
  final VoidCallback onIgnore;

  void _close(BuildContext context) => Navigator.of(context).maybePop();

  /// 点「更新」:**先关卡片再办事**。
  ///
  /// 顺序不能反:下载进度窗口是在根 State 上弹的,而这张卡还占着弹层栈顶,反着来
  /// 会出现"进度窗口在更新卡下面"——用户只看到更新卡还在,以为按钮没反应。
  void _update(BuildContext context) {
    _close(context);
    onUpdate();
  }

  /// 点「忽略」:关卡片 + 记住这个版本(记住这件事由调用方做)。
  void _ignore(BuildContext context) {
    _close(context);
    onIgnore();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final (foreground: foreground, secondary: secondary) = settingsPalette(
      isDark,
    );
    return PopupShell(
      title: '版本更新',
      icon: popupIcon(context, '下载进度.svg'),
      onClose: () => _close(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            currentVersion.isEmpty
                ? release.version
                : '$currentVersion → ${release.version}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: secondary, fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          ReleaseNotesPreview(
            notes: release.notes,
            foreground: foreground,
            secondary: secondary,
            isDark: isDark,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              // 需求指定:左边更新、右边忽略
              Expanded(
                child: PopupPrimaryButton(
                  label: '更新',
                  onPressed: () => _update(context),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PopupSecondaryButton(
                  label: '忽略',
                  onPressed: () => _ignore(context),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// release 说明的预览窗口:固定 12 行高,内容超了就出滚动条。
///
/// 高度不是"大概 12 行":按 [TextStyle.height] 把行高算死 × 12,再用 [TextPainter]
/// 量一遍真实高度决定挂不挂滚动条 —— 内容不到 12 行时不挂,挂上去会在右边留一条
/// 没东西可滚的槽。
class ReleaseNotesPreview extends StatelessWidget {
  const ReleaseNotesPreview({
    super.key,
    required this.notes,
    required this.foreground,
    required this.secondary,
    required this.isDark,
  });

  final String notes;
  final Color foreground;
  final Color secondary;
  final bool isDark;

  /// 行高系数。三档样式都用它,行距才一致(标题字大一些,行高按比例跟着大)。
  static const double _heightFactor = 1.55;

  static const double _baseFontSize = 13;

  /// 一行正文的高度。窗口高度和溢出判断都用它。
  static const double _lineHeight = _baseFontSize * _heightFactor;

  /// 内容左右留白:滚动条要占位置,不留就会压在字上。
  static const double _horizontalPadding = 10;

  static const double _verticalPadding = 10;

  TextStyle _styleFor(MdLineKind kind, {required bool empty}) {
    switch (kind) {
      case MdLineKind.heading:
        return TextStyle(
          color: foreground,
          fontSize: 14,
          height: _heightFactor,
          fontWeight: FontWeight.w600,
        );
      case MdLineKind.code:
        return TextStyle(
          color: secondary,
          fontSize: 12,
          height: _heightFactor,
          fontFamily: 'monospace',
        );
      case MdLineKind.body:
        return TextStyle(
          // 空行只是撑高度,颜色无所谓
          color: empty ? secondary : foreground,
          fontSize: _baseFontSize,
          height: _heightFactor,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = parseMarkdown(notes);
    if (lines.isEmpty) {
      // 说明是空的:给一句占位,别给用户看一个空窗口
      return SizedBox(
        height: _lineHeight * kNotesLines,
        child: Align(
          alignment: Alignment.topLeft,
          child: Text(
            '这个版本没有写说明。',
            style: TextStyle(color: secondary, fontSize: _baseFontSize),
          ),
        ),
      );
    }

    final maxHeight = _lineHeight * kNotesLines;
    // 半像素余量:行高是算出来的,和布局引擎里的实际值差一点点;刚好 12 行时
    // 不该被判成"超了"而多出一条滚动条。
    final scrollable =
        _measure(
          lines,
          MediaQuery.sizeOf(context),
          MediaQuery.textScalerOf(context),
        ) >
        maxHeight + 0.5;

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _horizontalPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final line in lines)
            Text(
              line.prefix.isEmpty ? line.text : '${line.prefix}${line.text}',
              style: _styleFor(line.kind, empty: line.text.isEmpty),
            ),
        ],
      ),
    );

    return Container(
      height: maxHeight,
      decoration: BoxDecoration(
        // 比卡片底色再压一层:预览窗口和卡片本体的边界就出来了,不用画线
        color: isDark ? const Color(0x1A000000) : const Color(0x0D000000),
        borderRadius: BorderRadius.circular(12),
      ),
      child: scrollable
          // 滚动条常显:窗口里明明还有内容,不显示的话用户不知道能往上拖
          ? Scrollbar(
              thumbVisibility: true,
              thickness: 3,
              radius: const Radius.circular(2),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: _verticalPadding),
                child: content,
              ),
            )
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: _verticalPadding),
              child: content,
            ),
    );
  }

  /// 把每一行按实际排版宽度量一遍,加起来就是整块内容的高度。
  ///
  /// 不能用 `maxLines: 12` 糊弄过去:那样量不出"到底超没超",而滚动条要按这个
  /// 判断挂不挂。
  double _measure(List<MdLine> lines, Size screen, TextScaler scaler) {
    // 滚动条和左右留白都要减掉,否则量出来的宽度比实际排版宽度大,行数会少算
    final width =
        screen.width -
        24 * 2 - // 弹层左右各 24
        14 * 2 - // 卡片内边距
        _horizontalPadding * 2 -
        kScrollbarGutter;
    var total = 0.0;
    for (final line in lines) {
      final painter = TextPainter(
        text: TextSpan(
          text: line.prefix.isEmpty ? line.text : '${line.prefix}${line.text}',
          style: _styleFor(line.kind, empty: line.text.isEmpty),
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(maxWidth: width > 0 ? width : 200);
      total += painter.height;
    }
    return total;
  }
}

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

/// 下载进度环:谷歌 Play 那种波浪圆环。
///
/// - 整圈浅色底,进度从 12 点整顺时针扫过,弧线是滚动的波浪(见 [RingPainter]);
/// - 圆心是**加粗百分比**,和弧的进度严格同一个值;
/// - 下完(100%)时波浪闭合、不再爬,圆心换成蓝渐变波浪徽章加白勾(见 [ScallopBadge]);
/// - 失败时圆心换成红渐变波浪徽章加白叉。
class ProgressRing extends StatefulWidget {
  const ProgressRing({
    super.key,
    required this.progress,
    required this.failed,
    required this.isDark,
    this.diameter = defaultDiameter,
  });

  /// 0~1。
  final double progress;
  final bool failed;
  final bool isDark;

  /// 圆环外径。整张卡收小之后环也跟着收;更新卡里还要再小一点(卡片更矮)。
  final double diameter;

  static const double defaultDiameter = 128;

  /// 画法的基准直径:[RingPainter] 里的半径/线宽都是按 176 定的,
  /// 实际画的时候整块画布按 `diameter / 176` 缩放,这样只有一处尺寸可调。
  static const double designDiameter = 176;

  /// 波浪徽章盘面的直径(设计基准里)。徽章要**深深压到进度环的笔触下面**:
  /// 环笔触内缘 63、外缘 77(半径 70、半线宽 7),徽章半径取 70、起伏 5.5%,
  /// 浪谷 66、浪峰 74 —— 全程藏在笔触底下 3 个单位以上,抗锯齿也吃不穿,
  /// 缝里不可能露卡片底。相位和环对不对得上都无所谓,反正看不见交界。
  static const double badgeDiameter = 140;

  @override
  State<ProgressRing> createState() => ProgressRingState();
}

class ProgressRingState extends State<ProgressRing>
    with TickerProviderStateMixin {
  /// 显示用的进度。数据一段一段来,直接画会一跳一跳;补间到目标值就顺了。
  late double _shown = widget.progress;

  /// 100% 时对勾那一下弹出来。
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  /// 波浪的相位。走完 1.0 = 浪前进一个波长,所以 1 秒正好是谷歌的
  /// waveSpeed 默认值(每秒一个波长)。再快就显得躁。
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void initState() {
    super.initState();
    if (widget.progress >= 1 || widget.failed) _pop.value = 1;
    _syncWave();
  }

  @override
  void didUpdateWidget(ProgressRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    setState(() => _shown = widget.progress);
    if (widget.progress >= 1 && oldWidget.progress < 1) _pop.forward(from: 0);
    if (widget.failed && !oldWidget.failed) _pop.forward(from: 0);
    if (widget.progress < 1 && oldWidget.progress >= 1) _pop.value = 0;
    _syncWave();
  }

  /// 只有「还在下」的时候波浪才转:下完/失败还转着,看着像没结束。
  void _syncWave() {
    final running = widget.progress < 1 && !widget.failed;
    if (running && !_wave.isAnimating) {
      _wave.repeat();
    } else if (!running && _wave.isAnimating) {
      _wave.stop();
    }
  }

  @override
  void dispose() {
    _pop.dispose();
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final done = _shown >= 1 && !widget.failed;
    final scale = widget.diameter / ProgressRing.designDiameter;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: _shown),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      builder: (context, value, _) => SizedBox(
        width: widget.diameter,
        height: widget.diameter,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 圆心先画、圆环后画:完成/失败的徽章盘面要压进环的笔触底下,
            // 缝里才不露卡片底。下载中圆心只是百分比文字,环盖不盖它都一样。
            _center(value, done, scale),
            CustomPaint(
              size: Size.square(widget.diameter),
              painter: RingPainter(
                scale: scale,
                progress: done ? 1 : value,
                phase: _wave,
                arcColor: widget.failed
                    ? const Color(0xFFE5484D)
                    : const Color(0xFF2F6BFF),
                // 底圈要看得见又不抢戏:太淡了整圈像没画,太重了分不出哪段是进度
                trackColor:
                    (widget.isDark
                            ? const Color(0xFFFFFFFF)
                            : const Color(0xFF1B2430))
                        .withValues(alpha: 0.22),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 圆心:没下完是加粗百分比,下完是蓝渐变波浪徽章加白勾,失败是红渐变徽章加白叉。
  Widget _center(double value, bool done, double scale) {
    final failed = widget.failed;
    final percent = '${(value * 100).round()}%';
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      child: (done || failed)
          ? ScaleTransition(
              key: ValueKey(done ? 'done' : 'failed'),
              scale: CurvedAnimation(parent: _pop, curve: Curves.elasticOut),
              child: ScallopBadge(scale: scale, failed: failed),
            )
          : Text(
              percent,
              key: const ValueKey('percent'),
              style: TextStyle(
                // 卡片底色是磨砂浅色,百分比用深色才看得清;
                // 深色模式的卡片底是深灰,写白色。
                color: widget.isDark
                    ? const Color(0xFFFFFFFF)
                    : const Color(0xFF12203A),
                fontSize: 28 * scale,
                fontWeight: FontWeight.w700,
              ),
            ),
    );
  }
}

/// 完成/失败的波浪徽章:谷歌 Play 下载完成那种边缘起伏的圆盘。
///
/// - 边缘是正弦起伏的闭合圆(14 道浪,和外圈进度环同数,看着是一家人),
///   起伏约半径的 7%,和参考图里那圈圆润的波浪同量级;
/// - 盘面**藏进进度环的笔触底下**(见 [badgeDiameter]),和环叠在一起才是一整块,
///   中间没有任何露底的缝;
/// - 盘面渐变和进度弧**同一配方**(深 → 亮,横向),叠放处色调连得上;
///   完成走品牌蓝,失败走红;
/// - 中央符号是粗白勾 / 粗白叉,和参考图同字重。
class ScallopBadge extends StatelessWidget {
  const ScallopBadge({super.key, required this.scale, required this.failed});

  final double scale;
  final bool failed;

  /// 边缘起伏的瓣数。12 瓣 + 小起伏 = 圆润的花瓣,瓣数越多齿越尖
  /// (斜率 ≈ 瓣数 × 起伏,之前 14 瓣 × 7% 真机上像齿轮)。
  /// 和外圈进度环瓣数不一样没关系:交界藏在环底下,看不见。
  static const int lobes = 12;

  /// 起伏幅度占半径的比例。5.5% 配 12 瓣,圆润和参考图同量级。
  static const double ripple = 0.055;

  @override
  Widget build(BuildContext context) {
    final base = failed
        ? const Color(0xFFE5484D)
        : const Color(0xFF2F6BFF);
    // 和进度弧同一配方(见 RingPainter 的 shader):徽章压在环底下,
    // 配方不一致的话叠放处会断色。
    const deep = Color(0xFF001F6B);
    const light = Color(0xFFFFFFFF);
    final d = ProgressRing.badgeDiameter * scale;
    return SizedBox(
      width: d,
      height: d,
      child: CustomPaint(
        painter: ScallopFill(
          stops: <Color>[
            Color.lerp(base, deep, 0.45)!,
            Color.lerp(base, light, 0.15)!,
          ],
        ),
        foregroundPainter: failed
            ? const CrossPainter(color: Color(0xFFFFFFFF))
            : const CheckPainter(color: Color(0xFFFFFFFF)),
      ),
    );
  }
}

/// 波浪徽章的盘面:起伏圆填渐变。
class ScallopFill extends CustomPainter {
  const ScallopFill({required this.stops});

  /// 对角渐变的上、下两档(见 [ScallopBadge])。
  final List<Color> stops;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final center = Offset(size.width / 2, size.height / 2);
    final path = Path();
    const step = math.pi / 180;
    for (var deg = 0; deg <= 360; deg++) {
      final angle = deg * step;
      final rr =
          r *
          (1 +
              ScallopBadge.ripple *
                  math.sin(ScallopBadge.lobes * angle));
      final point = Offset(
        center.dx + rr * math.sin(angle),
        center.dy - rr * math.cos(angle),
      );
      if (deg == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    // 横向渐变,和进度弧的 shader 同方向同配方:徽章压在环底下,
    // 两边的色调在叠放处连得上,不会断色。
    canvas.drawPath(
      path,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, size.height / 2),
          Offset(size.width, size.height / 2),
          stops,
        ),
    );
  }

  @override
  bool shouldRepaint(ScallopFill old) => old.stops != stops;
}

/// 徽章中央符号的线宽 = 盘子直径的这个比例。勾和叉共用:15% 已经挺粗了,
/// 再粗折角就开始糊在一起。
const double badgeGlyphStrokeRatio = 0.15;

/// 失败徽章里的白叉,和 [CheckPainter] 同字重。
class CrossPainter extends CustomPainter {
  const CrossPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * badgeGlyphStrokeRatio
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawLine(Offset(s * 0.32, s * 0.32), Offset(s * 0.68, s * 0.68), paint);
    canvas.drawLine(Offset(s * 0.68, s * 0.32), Offset(s * 0.32, s * 0.68), paint);
  }

  @override
  bool shouldRepaint(CrossPainter old) => old.color != color;
}

/// 波浪徽章里那个白对勾(见 [ScallopBadge])。
///
/// 不用图标字体:`CupertinoIcons.check_mark` 的字重是定死的,要「又大又粗」
/// 只能自己画。折线按 0~1 的相对坐标定,盘子多大都合用。
class CheckPainter extends CustomPainter {
  const CheckPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 起笔在左下、拐到中下、甩到右上:标准的对勾三段折线
    final path = Path()
      ..moveTo(size.width * 0.24, size.height * 0.52)
      ..lineTo(size.width * 0.42, size.height * 0.70)
      ..lineTo(size.width * 0.76, size.height * 0.32);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.shortestSide * badgeGlyphStrokeRatio
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(CheckPainter old) => old.color != color;
}

/// 波浪进度环的画笔 —— 谷歌 Play 商店下载中围着图标那圈「皱起来的圆环」
/// (Material 3 Expressive 的 wavy circular progress)。
///
/// - **底圈**和**进度**走同一条波浪:半径在 半径 ± 浪高 之间按正弦起伏。
///   波形只跟**角度**有关(`sin(浪数 × 角度 + 相位 × 2π)`),所以任何一段弧
///   的浪都落在同一处 —— 底圈和进度上的浪对得上,进度长出来时波形也不变形;
/// - 浪数取整、按**整圈**定死:波长不会随进度变,100% 时首尾严丝合缝闭合;
/// - 进度和底圈之间留一小段**缺口**(谷歌的 gapSize,默认 4dp),
///   看着是两段线而不是一整条;
/// - 相位一秒走一个波长(谷歌 waveSpeed 的默认值就是「每秒一个波长」)。
///
/// 比例是照参考抄的:细线(约 4dp)、浪高跟线宽同量级、波长约 20dp。
/// 之前那版线宽 20、整圈 20 道浪,浪比线还密,看着像毛毛虫 —— 谷歌不是那么画的。
class RingPainter extends CustomPainter {
  RingPainter({
    required this.scale,
    required this.progress,
    required this.phase,
    required this.arcColor,
    required this.trackColor,
  }) : super(repaint: phase);

  /// 画布缩放:下面的半径/线宽都按 176 的基准定,乘上它才是实际尺寸。
  final double scale;

  final double progress;

  /// 波浪相位(0~1 循环)。挂成 [repaint] 的 listenable:相位往前走不用
  /// 重建 widget,只重画这一层。
  final Animation<double> phase;

  final Color arcColor;
  final Color trackColor;

  /// 圆环中心线半径、线宽、浪高。都按 176 的基准定。
  ///
  /// 浪高 4:浪太高齿就尖了,参考图里是圆润的起伏。斜率 ≈ 浪高 × 浪数 ÷ 半径,
  /// 取 0.8 左右齿形圆,之前 5.5 那版斜率 1.1,真机上看着像齿轮。
  static const double _radius = 70;
  static const double _stroke = 14;
  static const double _amplitude = 4;

  /// 整圈的浪数。整数:整圈才闭得上。14 道 = 176 基准下 31 个单位一个波长,
  /// 换成 dp 约 23dp —— 和谷歌那支波浪进度条的波长同量级。
  static const int _waves = 14;

  /// 进度和底圈之间的缺口(按中心线量)。谷歌默认 4dp,这里取同量级。
  static const double _gapLength = 6.5;

  @override
  void paint(Canvas canvas, Size size) {
    // 半径常量按 176 的基准定:先把画布缩到实际尺寸,圆心要换算回基准坐标系,
    // 否则会按实际尺寸算一半、再被缩放一次,整个环偏到左上。
    canvas.scale(scale);
    final center = Offset(size.width / scale / 2, size.height / scale / 2);

    final clamped = progress.clamp(0.0, 1.0);
    final sweep = 2 * math.pi * clamped;
    // 缺口换算成圆心角:弧长 ÷ 半径
    final gap = _gapLength / _radius;

    Paint strokePaint(Color color) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..color = color;

    Path wave(double from, double to) => waveArcPath(
      center: center,
      radius: _radius,
      amplitude: _amplitude,
      startAngle: from,
      endAngle: to,
      phase: phase.value,
      waves: _waves,
    );

    // 底圈:从进度末端(让出一个缺口)铺到 12 点前(再让出一个缺口)。
    // 进度下满时这段自然为空,整圈都归进度。
    final trackFrom = sweep + gap;
    final trackTo = 2 * math.pi - gap;
    if (trackFrom < trackTo) {
      canvas.drawPath(wave(trackFrom, trackTo), strokePaint(trackColor));
    }

    if (clamped <= 0) return;

    canvas.drawPath(
      wave(0, sweep),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeCap = StrokeCap.round
        ..shader = ui.Gradient.linear(
          Offset(center.dx - _radius, center.dy),
          Offset(center.dx + _radius, center.dy),
          <Color>[
            // 深到浅的蓝:深浅两头都压得住底色,弧才明显
            Color.lerp(arcColor, const Color(0xFF001F6B), 0.45)!,
            Color.lerp(arcColor, const Color(0xFFFFFFFF), 0.15)!,
          ],
        ),
    );
  }

  @override
  bool shouldRepaint(RingPainter old) =>
      old.scale != scale ||
      old.progress != progress ||
      old.arcColor != arcColor ||
      old.trackColor != trackColor;
}

/// 波浪弧的采样点,连成一条折线。
///
/// 角度从 **12 点整**起算、顺时针为正,[startAngle] / [endAngle] 是弧度。
/// 半径 = [radius] + [amplitude] × sin([waves] × 角度 + [phase] × 2π):
/// 波形只跟角度有关,所以同一条圆上任意两段弧在角度重叠处浪的位置一致 ——
/// 底圈和进度的浪才对得上,进度长出来时波形也不会变形。浪数取整时整圈闭合。
///
/// 采样步长 1°:一圈 360 段,每段远小于线宽,看着就是光滑的浪,比推贝塞尔省事。
Path waveArcPath({
  required Offset center,
  required double radius,
  required double amplitude,
  required double startAngle,
  required double endAngle,
  required double phase,
  required int waves,
}) {
  const double step = math.pi / 180;
  final span = endAngle - startAngle;
  final steps = math.max(2, (span / step).ceil());
  final path = Path();
  for (var i = 0; i <= steps; i++) {
    final angle = startAngle + span * i / steps;
    final r =
        radius + amplitude * math.sin(waves * angle + phase * 2 * math.pi);
    // 0 度在 12 点整,角度顺着表针长
    final point = Offset(
      center.dx + r * math.sin(angle),
      center.dy - r * math.cos(angle),
    );
    if (i == 0) {
      path.moveTo(point.dx, point.dy);
    } else {
      path.lineTo(point.dx, point.dy);
    }
  }
  return path;
}

// ────────────────────────── 弹层共用件 ──────────────────────────

/// 所有弹层的统一外壳:糊一层背景 + 玻璃面板 + 头部一行。
///
/// 四张弹层卡(媒体下载进度、版本更新、更新包下载、提示与授权)原来各自抄了一遍这段
/// 骨架,抄着抄着就分了家:提示弹窗没铺底色、标题居中、主按钮自己的配色,
/// 「需要安装权限」更是直接用了 CupertinoAlertDialog(iOS 灰底 + 细分割线),搁在满屏
/// 毛玻璃里像另一个 APP 的弹窗。统一走这里之后,弹层之间不可能再走样。
class PopupShell extends StatelessWidget {
  const PopupShell({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.onClose,
    this.maxWidth = 300,
  });

  final String title;

  /// 完整资源路径(用 [settingsIcon] / [popupIcon] 拼)。
  final String icon;

  /// 头部右侧的关闭叉。null = 不给叉:必须点下面的按钮才能走。
  final VoidCallback? onClose;

  /// 面板最大宽度。普通提示卡 300 够用;大图预览要更宽,见 [ImageViewerDialog]。
  final double maxWidth;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final (foreground: foreground, secondary: secondary) = settingsPalette(
      isDark,
    );
    return Stack(
      children: [
        Positioned.fill(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: const ColoredBox(color: Color(0x00000000)),
          ),
        ),
        Padding(
          // 底部留一点,弹层贴着屏幕边缘不好看
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              // 玻璃面板**不自己铺底**:它直接透过上面那层模糊采样页面本身。
              //
              // 原来这里铺了一整屏 ThemeBackground(为了和页面同色),结果是两件事
              // 一起坏:
              // 1. 割裂 —— 卡片里透出来的是"重新画了一遍、没被糊过"的渐变,而卡片
              //    外面是被模糊+压暗的页面,同一屏两套明度,边上就是一条缝;
              // 2. 白花帧 —— 浅色模式那层是 LightThemeBackgroundPainter:整屏三次
              //    drawRect,带 BlendMode.overlay / screen 和一个径向渐变。它叠在
              //    12 sigma 的整屏模糊底下,弹层每帧都要重算一遍,换来的只是上面
              //    那条缝。
              //
              // 弹层底下本来就只有页面自己,方向键上下滚也不会跑到别的地方去,
              // 所以直接采样即可 —— GlassPanel 本来就没有铺底这个参数,弹层的
              // 调用方也都不自己铺垫。
              child: GlassPanel(
                isDark: isDark,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 11, 14, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          TintedSvgIcon(icon, size: 20, color: foreground),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: foreground,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (onClose != null)
                            CupertinoButton(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(28, 28),
                              onPressed: onClose,
                              child: Icon(
                                CupertinoIcons.xmark,
                                size: 18,
                                color: secondary,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      child,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 弹层淡入的时长。
///
/// 系统那条(`showCupertinoDialog`)是 250ms 起步的弹簧。点一下就开的东西不该等
/// 半拍 —— 尤其点图片缩略图那只眼睛的时候,眼睛是个小目标,点完视线立刻落在弹层上。
const Duration kGlassDialogFade = Duration(milliseconds: 180);

/// 玻璃弹层走的路由。
///
/// 和 `showCupertinoDialog` 用的那条比,只动时间:
///
/// - **遮蔽先到位**。系统那条路由把遮蔽和面板绑在同一条动画上,遮蔽的曲线是
///   `Curves.ease` —— 走到后半程还剩一截,面板已经压上来了、身后那片变暗还在慢慢爬,
///   看着就是"遮蔽慢半拍"。这里让它在前 40% 就铺满(180ms 的动画里约 70ms),
///   面板还在淡入时后面已经黑透了。
/// - 整个入场短一档,见 [kGlassDialogFade]。
class GlassDialogRoute<T> extends RawDialogRoute<T> {
  GlassDialogRoute({required WidgetBuilder builder, required Color barrierColor})
    : super(
        pageBuilder: (context, _, _) => builder(context),
        barrierColor: barrierColor,
        barrierDismissible: true,
        // 点背景也是关掉的一条路,这句是读屏要念的
        barrierLabel: '关闭',
        transitionDuration: kGlassDialogFade,
        transitionBuilder: (context, animation, _, child) => FadeTransition(
          opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
          child: child,
        ),
      );

  /// 遮蔽在动画的前这么多(0~1)铺满,不跟着面板慢慢爬。
  static const double barrierLead = 0.4;

  @override
  Curve get barrierCurve => const Interval(0, barrierLead, curve: Curves.easeOut);
}

/// 开一块玻璃弹层。全 App 的弹层都走这一条 —— 骨架是 [PopupShell],路由见
/// [GlassDialogRoute]。
///
/// 挂 root navigator(和 [showCupertinoDialog] 一样):弹层要盖住玻璃底栏,挂在
/// 当前页的 navigator 上会从底栏底下钻出来。
Future<T?> showGlassLayer<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  return Navigator.of(context, rootNavigator: true).push<T>(
    GlassDialogRoute<T>(
      builder: builder,
      // 系统那条用的同一个遮罩色:浅色 20% 黑、深色 48% 黑,跟着当前主题走
      barrierColor: CupertinoDynamicColor.resolve(
        kCupertinoModalBarrierColor,
        context,
      ),
    ),
  );
}

/// 弹层里的主按钮(确认 / 更新 / 一键授权 / 完成 / 取消)。
///
/// 颜色不取 ColorScheme:弹层挂在 CupertinoApp 那棵树下面,拿不到二级页的种子色,
/// 每个弹窗各写一遍 styleFrom 又必然走样 —— 所以整条配色只留这一份。
class PopupPrimaryButton extends StatelessWidget {
  const PopupPrimaryButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    return FilledButton(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(40),
        backgroundColor: isDark
            ? const Color(0x1FFFFFFF)
            : const Color(0x141257C9),
        foregroundColor: isDark
            ? const Color(0xFF5AA9FF)
            : const Color(0xFF1257C9),
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// 弹层里的次按钮(忽略 / 稍后)。和主按钮并排时放右边。
class PopupSecondaryButton extends StatelessWidget {
  const PopupSecondaryButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final secondary = settingsPalette(isDark).secondary;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(40),
        foregroundColor: secondary,
        side: BorderSide(color: secondary.withValues(alpha: 0.35)),
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// 弹一句提示用的玻璃卡。
///
/// 骨架就是 [PopupShell]:和「版本更新」「下载进度」同一块面板、同一行头部,所以
/// 检查更新的回音和更新卡摆在一起不会像两个 APP。
///
/// 返回值:点了主按钮为真,点了右上角的叉为假。
Future<bool> showGlassDialog(
  BuildContext context, {
  required String title,
  required String body,
  String? icon,
  String primaryLabel = '知道了',
}) async {
  final result = await showGlassLayer<bool>(
    context,
    builder: (context) => AppGlassDialog(
      title: title,
      body: body,
      icon: icon,
      primaryLabel: primaryLabel,
    ),
  );
  return result ?? false;
}

/// 统一的轻提示。内容是 [AppGlassDialog],弹层的路由与遮罩见 [GlassDialogRoute]。
void showInfo(
  BuildContext context,
  String title,
  String body, {
  String? icon,
}) {
  unawaited(showGlassDialog(context, title: title, body: body, icon: icon));
}

class AppGlassDialog extends StatelessWidget {
  const AppGlassDialog({
    super.key,
    required this.title,
    required this.body,
    required this.primaryLabel,
    this.icon,
  });

  final String title;
  final String body;
  final String primaryLabel;
  final String? icon;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final foreground = settingsPalette(isDark).foreground;
    return PopupShell(
      title: title,
      // 没点名要哪张图就用「检查更新」:用上这个弹窗的地方多半和检查更新有关
      icon: icon ?? settingsIcon(context, '检查更新.svg'),
      onClose: () => Navigator.of(context).pop(false),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            body,
            style: TextStyle(color: foreground, fontSize: 13.5, height: 1.45),
          ),
          const SizedBox(height: 14),
          PopupPrimaryButton(
            label: primaryLabel,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
  }
}

/// 下载前先问一句「要哪一档清晰度」。
///
/// **只在第二个上游(有分辨率列表)解析成功时才会出现**:media-parser 的结果里
/// 根本没有 [VideoQuality],传进来就是空列表,调用方也就不该开这个弹窗。
///
/// 返回用户选中的那一档;点右上角的叉返回 null,调用方据此取消这次下载。
///
/// 两个要点:
/// - 列表里同一档分辨率只会出现一次 —— 去重在上游映射那一步就做完了
///   (见 parse_service.dart 的 dedupeQualities),这里只管显示;
/// - 不预选任何一项。默认选中会让用户顺手点「确定」下到一档他没看过的清晰度,
///   而下载是几十上百 MB 的事,值得让他自己点一下。
Future<VideoQuality?> showQualityPicker(
  BuildContext context, {
  required List<VideoQuality> qualities,
}) => showGlassLayer<VideoQuality>(
  context,
  builder: (context) => QualityPickerDialog(qualities: qualities),
);

class QualityPickerDialog extends StatelessWidget {
  const QualityPickerDialog({super.key, required this.qualities});

  final List<VideoQuality> qualities;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final (foreground: foreground, secondary: secondary) = settingsPalette(
      isDark,
    );
    return PopupShell(
      title: '选择清晰度',
      // 用首页板块那套图标:`下载媒体.svg` 只在「浅色/深色模式首页板块22x22-SVG/」
      // 里,设置板块那套没有它。写成 settingsIcon 会抛
      // "Unable to load asset: 深色主题（设置板块选项图标）/下载媒体.svg" ——
      // 弹窗照常显示,但控制台每次刷一屏未捕获异常(真机实测)。
      icon: homeIcon(context, '下载媒体.svg'),
      onClose: () => Navigator.of(context).pop(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 屏小的机器上档位可能占掉大半个屏幕,这里限高并允许滚动。
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: qualities.length,
              separatorBuilder: (_, _) => Container(
                height: 1,
                color: secondary.withValues(alpha: 0.16),
              ),
              itemBuilder: (context, index) {
                final q = qualities[index];
                return QualityOptionRow(
                  quality: q,
                  isDark: isDark,
                  foreground: foreground,
                  secondary: secondary,
                  onPressed: () => Navigator.of(context).pop(q),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 清晰度列表里的一行:左边档位名,右边码率/体积。
class QualityOptionRow extends StatelessWidget {
  const QualityOptionRow({
    super.key,
    required this.quality,
    required this.isDark,
    required this.foreground,
    required this.secondary,
    required this.onPressed,
  });

  final VideoQuality quality;
  final bool isDark;
  final Color foreground;
  final Color secondary;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // 认不出分辨率时给一句「默认画质」,别让这一行左边空着 —— 空标签看着像没加载完。
    final label = quality.label.isEmpty ? '默认画质' : quality.label;
    final detail = quality.detail;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (detail.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(detail, style: TextStyle(color: secondary, fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

