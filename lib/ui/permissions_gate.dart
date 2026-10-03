import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../failure.dart';
import 'notifications.dart';
import 'prefs.dart';

/// 首次进入的授权引导:问一次通知权限,问过就记住。
///
/// 从 [HomeShellState] 里搬出来的。它以前是根 State 上的一个 bool 加三个方法,
/// 外加一条容易踩的顺序:偏好里读到"问过了"就不必再异步补读,否则每次启动都会
/// 再弹一次系统授权框。
///
/// 这里只管"通知"这一件事。**「安装未知应用」刻意不在这里问**:系统没有"直接问"
/// 的接口,只能跳到它那一页,而刚装好 APP 就被甩到系统设置里,用户只会觉得莫名其
/// 妙。那道授权挪到更新流程里、包下完之后再跳(见 UpdateCoordinator)。
class PermissionsGate {
  PermissionsGate({required this.prefs});

  /// 偏好存储。可空:测试里不落盘。
  final SharedPreferences? prefs;

  /// 偏好里读到的那份"问过了"。见 [load]。
  bool asked = false;

  /// 那次异步补读。见 [load]。
  Future<void> askedLoaded = Future<void>.value();

  /// 系统当前有没有通知权限。做成可注入的,单测里换掉。
  Future<bool?> Function() enabled = notificationsEnabled;

  /// 请求通知权限。返回是否给。
  Future<bool> Function() request = requestNotificationPermission;

  /// 启动时调一次:偏好里有就直接用,没有(测试里常见)才异步补读。
  ///
  /// 不补读的后果是每次都弹一遍系统授权框 —— 而系统在用户拒过一次之后就不再弹了,
  /// 于是用户什么都看不到,只留下一条"APP 老想弹东西"的印象。
  void load({bool? cached}) {
    // null = 偏好里没有这一项(测试里常见)→ 异步补读一次;
    // 有值(不管 true 还是 false)就是确定的,不用再读。
    asked = cached ?? false;
    if (cached == null) askedLoaded = _read();
  }

  Future<void> _read() async {
    try {
      final store = prefs ?? await SharedPreferences.getInstance();
      asked = store.getBool(kPrefsPermissionsAsked) ?? false;
    } catch (error, stack) {
      // 读不到就当没问过:这次会再问一遍,最多重复一次
      swallow('perm.read', error, stack);
    }
  }

  /// 问一次通知权限(只在没问过的时候)。
  ///
  /// 返回这次有没有真的去问 —— 调用方拿它决定还要不要干别的。
  /// 平台侧问不出来(测试 / 非 Android)就整段跳过,不打扰用户。
  Future<bool> askOnFirstLaunch() async {
    await askedLoaded;
    if (asked) return false;

    final on = await enabled();
    if (on == false) await request();

    asked = true;
    await _remember();
    return true;
  }

  Future<void> _remember() async {
    try {
      final store = prefs ?? await SharedPreferences.getInstance();
      await store.setBool(kPrefsPermissionsAsked, true);
    } catch (error, stack) {
      swallow('perm.remember', error, stack);
    }
  }
}
