import 'dart:async';

/// 读剪贴板的那点事从根 State 里搬出来。
///
/// 它原本是 [HomeShellState] 上的一对字段(一个 700ms 的兜底计时器 + 一个等待中的
/// Completer)加一个方法。搬出来的理由不是行数,是**它有一套自己的生命周期**:
/// 计时器必须随宿主销毁一起收掉,否则测试里直接报 "A Timer is still pending",
/// 真机上就是白等一趟。这种"必须成对收尾"的东西放在某个大 State 的字段里,
/// 早晚会有人忘了收。
class ClipboardReader {
  /// 平台侧卡住(系统剪贴板服务抽风)时不能把「粘贴」晾在那儿 —— 到这个点就按
  /// "读不到"收场,给用户一句明确的话,而不是点下去毫无反应。
  ///
  /// 不能就地用 \`Future.timeout\`:那个计时器没人能取消,页面切走/销毁之后它还挂着。
  ClipboardReader({this.deadline = const Duration(milliseconds: 700)});

  final Duration deadline;

  Timer? _timer;

  /// 还在等回话的那几次读。**是列表,不是单个字段** —— 理由见 [read]。
  final List<Completer<String?>> _waiters = <Completer<String?>>[];
  bool _disposed = false;

  /// 读剪贴板里的一段文字(走平台的 `getClipboardText` 通道,读不到返回 null)。
  ///
  /// 做成可注入的,是为了能单测超时那条路 —— 真平台通道在测试环境里没有实现。
  Future<String?> Function() platformRead = _noPlatform;

  static Future<String?> _noPlatform() async => null;

  /// 读一次。超时/平台卡住都返回 null,不抛异常。
  ///
  /// 两个入口(冷启动的自动粘贴、用户点「粘贴」)可能撞在一起,撞上时它们**共用同一个
  /// 截止时间**:计时器到点把正在等着的每一个都收掉。
  ///
  /// 原来是每次读各起一个计时器、只记最后一个等待者。那样第二次读会把第一次那个计时器
  /// 取消掉,而第一次的 `Future.any` 就再也没人能收 —— 平台侧真卡住时(正是这个截止
  /// 时间存在的理由),先来的那次 `await` 会永远挂在那儿,和类文档说的恰好相反。
  Future<String?> read() async {
    if (_disposed) return null;
    final wait = Completer<String?>();
    _waiters.add(wait);
    _timer ??= Timer(deadline, _finish);
    try {
      return await Future.any([platformRead(), wait.future]);
    } finally {
      _waiters.remove(wait);
      // 最后走的那个人收计时器:还有人等着就留着(那是他们的截止时间)。
      if (_waiters.isEmpty) {
        _timer?.cancel();
        _timer = null;
      }
    }
  }

  /// 把等待中的读就地收场(超时到点、或宿主销毁)。
  ///
  /// 必须把等待也结束掉:只取消计时器的话,`Future.any` 永远不返回,那些 await
  /// 就挂在那儿不放了。
  void _finish() {
    _timer = null;
    for (final wait in List<Completer<String?>>.of(_waiters)) {
      if (!wait.isCompleted) wait.complete(null);
    }
  }

  /// 宿主销毁时收掉。收掉之后再读一律返回 null。
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _finish();
  }
}
