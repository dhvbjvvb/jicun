import 'package:flutter/cupertino.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jicun/main.dart';
import 'package:jicun/widgets/animated_tab_icon.dart';

/// 用真实资源(未选中24x24-SVG/解析.svg)驱动,确保 asset 路径与 pubspec 一致。
const _asset = '未选中24x24-SVG/解析.svg';

Widget _host(Widget child, {bool reduceMotion = false}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reduceMotion),
  child: Directionality(textDirection: TextDirection.ltr, child: child),
);

double _scaleOf(WidgetTester tester) =>
    tester.widget<ScaleTransition>(find.byType(ScaleTransition)).scale.value;

void main() {
  testWidgets('构建即播放:起点小于 1,300ms 后停在 1.0', (tester) async {
    await tester.pumpWidget(_host(const AnimatedTabIcon(_asset)));

    expect(_scaleOf(tester), lessThan(1.0), reason: '首帧应处于动画起点(未选中→选中的收缩态)');

    await tester.pump(const Duration(milliseconds: 300));

    expect(_scaleOf(tester), 1.0, reason: '播完必须停在终态,不能留着过冲值');
  });

  testWidgets('播放一次后停止:再等 5 秒数值不变(没有 repeat)', (tester) async {
    await tester.pumpWidget(_host(const AnimatedTabIcon(_asset)));
    await tester.pump(const Duration(milliseconds: 300));

    final settled = _scaleOf(tester);
    await tester.pump(const Duration(seconds: 5));

    expect(_scaleOf(tester), settled);
    expect(tester.hasRunningAnimations, isFalse, reason: '控制器必须已停止');
  });

  testWidgets('系统开启「减弱动态效果」时直接给终态,不做动画', (tester) async {
    await tester.pumpWidget(
      _host(const AnimatedTabIcon(_asset), reduceMotion: true),
    );

    expect(find.byType(ScaleTransition), findsNothing);
    expect(find.byType(AnimatedTabIcon), findsOneWidget);
  });

  testWidgets('销毁后不报错(切走 tab 的场景)', (tester) async {
    await tester.pumpWidget(_host(const AnimatedTabIcon(_asset)));
    await tester.pumpWidget(_host(const SizedBox.shrink()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('深色模式下底栏每个 SVG 都带上了主题色 colorFilter', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(const LiquidGlassDemo());
    await tester.pump(const Duration(milliseconds: 400));

    final icons = tester.widgetList<SvgPicture>(find.byType(SvgPicture));
    expect(icons.length, greaterThanOrEqualTo(3), reason: '底栏 3 个 tab');

    for (final icon in icons) {
      expect(
        icon.colorFilter,
        isNotNull,
        reason:
            '改动前 _tabIcon 直接返回 SvgPicture.asset(无 colorFilter),'
            '硬编码 fill="#000000" 在深色玻璃上不可见',
      );
    }
  });

  testWidgets('设置页的选项图标同样是染色的(6 个也是硬编码黑)', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(const LiquidGlassDemo(autoCheckUpdate: false));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();

    final icons = tester
        .widgetList<SvgPicture>(find.byType(SvgPicture))
        .toList();
    // 底栏 3 个 + 设置页可见的若干张卡片
    expect(icons.length, greaterThan(3), reason: '设置页卡片图标应已渲染');

    for (final icon in icons) {
      expect(icon.colorFilter, isNotNull);
    }
  });
}
