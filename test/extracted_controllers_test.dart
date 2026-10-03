import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jicun/ui/clipboard_reader.dart';
import 'package:jicun/ui/permissions_gate.dart';
import 'package:jicun/ui/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('ClipboardReader', () {
    test('平台侧一直不回话时,到点按"读不到"收场,不吊死', () async {
      final reader = ClipboardReader(
        deadline: const Duration(milliseconds: 20),
      );
      // 永不完成 —— 模拟系统剪贴板服务卡住
      reader.platformRead = () => Completer<String?>().future;

      expect(await reader.read(), isNull);
      reader.dispose();
    });

    test('平台侧回得快就用它的结果', () async {
      final reader = ClipboardReader();
      reader.platformRead = () async => 'https://v.douyin.com/abcd/';
      expect(await reader.read(), 'https://v.douyin.com/abcd/');
      reader.dispose();
    });

    test('dispose 之后不再读,并且把等待中的那次就地收场', () async {
      final reader = ClipboardReader();
      final never = Completer<String?>();
      reader.platformRead = () => never.future;

      final pending = reader.read();
      reader.dispose();

      // 收场而不是一直挂着:await 能回来,值是 null
      expect(await pending, isNull);
      expect(await reader.read(), isNull);
    });

    test('两次读撞在一起时,先起的那次被后来的收掉,后面的照常回', () async {
      final reader = ClipboardReader(
        deadline: const Duration(milliseconds: 5000),
      );
      var calls = 0;
      reader.platformRead = () async {
        calls++;
        return calls == 1 ? null : 'second';
      };

      final first = reader.read();
      final second = reader.read();
      expect(await first, isNull);
      expect(await second, 'second');
      reader.dispose();
    });

    test('两次读撞在一起、平台侧都卡住:到点两个都要收场,不能只收后一个', () async {
      final reader = ClipboardReader(
        deadline: const Duration(milliseconds: 20),
      );
      // 永不回话 —— 模拟系统剪贴板服务卡住
      reader.platformRead = () => Completer<String?>().future;

      final first = reader.read();
      final second = reader.read();
      // **两次都要在截止时间收到 null**:原来的实现里第二次读会把第一次的计时器取消并
      // 顶掉那个等待者,于是先来的那次 await 再也没人能收 —— 而"平台侧卡住"正是这个截止
      // 时间存在的理由。只收最后一个 = 先把用户那次粘贴永远吊在那里。
      expect(await first, isNull);
      expect(await second, isNull);
      reader.dispose();
    });
  });

  group('PermissionsGate', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('偏好里已经问过:不再问,也不发请求', () async {
      final store = await SharedPreferences.getInstance();
      await store.setBool(kPrefsPermissionsAsked, true);
      var requested = 0;

      final gate = PermissionsGate(prefs: store);
      gate.load(cached: store.getBool(kPrefsPermissionsAsked));
      gate.enabled = () async => false;
      gate.request = () async {
        requested++;
        return true;
      };

      expect(await gate.askOnFirstLaunch(), isFalse);
      expect(requested, 0);
    });

    test('没问过且系统没开通知:发一次请求并落盘', () async {
      final store = await SharedPreferences.getInstance();
      var requested = 0;

      final gate = PermissionsGate(prefs: store);
      gate.load(cached: null); // 偏好里没有 → 异步补读
      gate.enabled = () async => false;
      gate.request = () async {
        requested++;
        return true;
      };

      expect(await gate.askOnFirstLaunch(), isTrue);
      expect(requested, 1);
      expect(store.getBool(kPrefsPermissionsAsked), isTrue);
    });

    test('系统已经开着通知权限:不打扰,但记下"问过了"', () async {
      final store = await SharedPreferences.getInstance();
      var requested = 0;

      final gate = PermissionsGate(prefs: store);
      gate.load(cached: null);
      gate.enabled = () async => true;
      gate.request = () async {
        requested++;
        return true;
      };

      expect(await gate.askOnFirstLaunch(), isTrue);
      expect(requested, 0);
      expect(store.getBool(kPrefsPermissionsAsked), isTrue);
    });

    test('平台侧问不出来(测试/非 Android):也只在第一次走一遍', () async {
      final gate = PermissionsGate(prefs: null);
      gate.load(cached: null);
      gate.enabled = () async => null;

      expect(await gate.askOnFirstLaunch(), isTrue);
      expect(await gate.askOnFirstLaunch(), isFalse);
    });
  });
}
