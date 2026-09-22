import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/widgets/tap_easter_egg.dart';

void main() {
  group('TapRally', () {
    final t0 = DateTime(2026, 1, 1);

    /// 相对于 t0 的第 ms 毫秒。
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

    test('窗口内凑满三次才触发', () {
      final rally = TapRally();
      expect(rally.register(at(0)), isFalse);
      expect(rally.register(at(300)), isFalse);
      expect(rally.register(at(600)), isTrue);
    });

    test('窗口是滑动的:第三下离第一下不超过窗口就算', () {
      final rally = TapRally();
      expect(rally.register(at(0)), isFalse);
      expect(rally.register(at(850)), isFalse);
      // 900 正好等于窗口,按 difference(t) > window 的判法仍算在内
      expect(rally.register(at(900)), isTrue);
    });

    test('间隔超过窗口的连点永远不算连击', () {
      final rally = TapRally();
      var fired = false;
      for (var i = 0; i < 10; i++) {
        fired |= rally.register(at(i * 1000));
      }
      expect(fired, isFalse, reason: '每下间隔 1s > 900ms 窗口,不该凑成连击');
    });

    test('触发之后重新从零计数', () {
      final rally = TapRally(taps: 2, window: const Duration(seconds: 1));
      expect(rally.register(at(0)), isFalse);
      expect(rally.register(at(10)), isTrue);
      expect(rally.register(at(20)), isFalse, reason: '上一次已清零');
      expect(rally.register(at(30)), isTrue);
    });
  });
}
