import 'package:flutter/widgets.dart';

import 'history_store.dart';
import 'parse_service.dart';
import 'ui/prefs.dart';

/// 板块页要用的那部分应用状态。
///
/// 之前页面直接持有 `HomeShellState`(在 lib/main.dart 里),于是
/// `main.dart → pages/ → main.dart` 互相 import。这里把页面**真正用到**的那些
/// 成员抽成接口:页面只依赖这个文件,main.dart 单向依赖 pages/,环就断了。
///
/// 只放页面用到的 24 个成员,不做成「整个根壳的公开 API」—— 那不叫解耦,
/// 只是把 main.dart 换个地方放。以后某个页面要碰新状态,就在这儿加一行。
///
/// 实现方是 main.dart 里的 HomeShellState。
abstract interface class ShellController {
  // ────────────────── 主题与外观 ──────────────────

  /// 系统主题三档。改它要包在 [applySetting] 里(那样才落盘)。
  AppThemeMode get themeMode;
  set themeMode(AppThemeMode value);

  /// 底栏是否隐藏文字,只剩图标。
  bool get hideTabLabels;
  set hideTabLabels(bool value);

  /// 底栏是否走玻璃效果。
  bool get glassBottomBar;
  set glassBottomBar(bool value);

  /// 已生效的界面缩放。
  double get uiScale;
  set uiScale(double value);

  /// 二级设置页统一入口:改状态 + 落盘。
  ///
  /// `State.setState` 是 protected,外部 State 调不到,所以根壳开这个口子。
  void applySetting(VoidCallback change);

  /// 把主题档位同步给原生侧(启动图按这个走)。
  void syncNightModeToNative(AppThemeMode mode);

  // ────────────────── 解析 ──────────────────

  /// 解析服务。页面拿它读 `lastRoute` 之类的排障信息。
  ParseService get parseService;

  /// 首页那个粘贴输入框的控制器。
  TextEditingController get linkController;

  /// 这次解析的结果。
  ParseResult? get parseResult;

  /// 这次解析的失败文案(给用户看的那一句)。
  String? get parseError;

  /// 正在解析中。
  bool get parsing;

  /// 解析被锁住(输入框、按钮不可点)。
  bool get parseLocked;

  /// 开始解析一条链接。
  Future<void> startParse(String link);

  /// 解开解析锁(解析结束/被取消时)。
  void unlockParse();

  /// 读剪贴板首条文字,读不到给 null。
  Future<String?> readClipboard();

  // ────────────────── 历史 ──────────────────

  /// 解析历史,新的在前。启动时预读好,页面只读不写。
  List<HistoryEntry>? get historyEntries;

  /// 删掉这几条记录,由根壳落盘并刷新。
  Future<void> deleteHistory(Set<String> ids);

  /// 从一条历史记录回解析页重新解析。
  Future<void> reparseFromHistory(HistoryEntry entry);

  // ────────────────── 通知与更新 ──────────────────

  /// 下载完成后要不要发通知。
  bool get notifyDownloadDone;
  set notifyDownloadDone(bool value);

  /// 下载失败后要不要发通知。
  bool get notifyDownloadFailed;
  set notifyDownloadFailed(bool value);

  /// 进 APP 自动粘贴并解析剪贴板首条链接。
  bool get autoPasteParse;
  set autoPasteParse(bool value);

  /// 下载结束后发一条系统通知(表格里的开关决定发不发)。
  Future<void> notifyDownloadFinished({
    required bool ok,
    required String title,
    String? error,
  });

  /// 正在检查更新。
  bool get checkingUpdate;

  /// 检查更新。[manual] 为真表示用户手动点的(会回一句「已是最新」)。
  Future<void> checkForUpdate({bool manual});
}
