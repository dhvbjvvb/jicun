import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jicun/ui/glass.dart';

/// 卡片滚到顶边要淡出,不能是被视口切出来的一条硬边。
///
/// 曾经 `shaderCallback: _fadeShader` 用的是实例方法 tear-off:同一个对象、同一个
/// 方法的两次 tear-off 在 Dart 里 `==`,而 RenderShaderMask 的 setter 见「相等」就
/// 提前 return、不 markNeedsPaint —— 遮罩只在首帧按 offset=0 画过一次,之后列表
/// 怎么滚都不再重算,顶边一直是硬切。
///
/// 这里直接盯住那条回归线:滚动一次之后 ShaderMask 必须拿到一个新的回调身份。
/// 回调每次都是新闭包,遮罩才会跟着滚动重画。
void main() {
  testWidgets('滚动后顶边遮罩换新回调(会重画)', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      CupertinoApp(
        home: BoardScrollView(
          header: const BoardHeader(title: '解析'),
          children: [
            for (var i = 0; i < 14; i++) const SizedBox(height: 100),
          ],
        ),
      ),
    );
    await tester.pump();

    final ShaderMask before = tester.widget<ShaderMask>(find.byType(ShaderMask));
    await tester.drag(find.byType(Scrollable), const Offset(0, -120));
    await tester.pumpAndSettle();
    final ShaderMask after = tester.widget<ShaderMask>(find.byType(ShaderMask));

    expect(
      before.shaderCallback != after.shaderCallback,
      isTrue,
      reason: '回调身份必须每次重建都不同,否则 RenderShaderMask 不会重画顶边遮罩',
    );
  });

  testWidgets('板块内容自带一层 RepaintBoundary(转场缓存,别删)', (tester) async {
    // 二级页返回时,下面那页要跟着转场动画平移回原位。板子内容外面没有紧贴的缓存层时,
    // 引擎只能每帧把整块板子(超椭圆裁剪的半透明卡 + SVG 图标 + 文字 + 整块 ShaderMask)
    // 重新光栅化 —— 真机上的表现就是「一按返回就卡」。这条用例只钉住「那层边界还在」,
    // 光栅收益本身在无头测试里量不到(见 glass.dart 里 BoardScrollView 那段注释)。
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      CupertinoApp(
        home: BoardScrollView(
          header: const BoardHeader(title: '解析'),
          children: [for (var i = 0; i < 3; i++) const SizedBox(height: 100)],
        ),
      ),
    );
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(BoardScrollView),
        matching: find.byType(RepaintBoundary),
      ),
      findsWidgets,
      reason: '板子里面必须自带一层 RepaintBoundary:转场平移时靠它复用缓存纹理',
    );
  });

  testWidgets('二级设置页的主题对象按亮度缓存(不每次现算调色板)', (tester) async {
    // ColorScheme.fromSeed 要在主 isolate 上现算一整套 HCT 调色板(种子色 → tone 表
    // → 十几个颜色槽),是纯 CPU 的活。二级设置页每次进入都会重建 GoogleSurface,
    // 现算就等于在转场第一帧上多压一段主线程占用。
    //
    // 这条钉住「同亮度两次构建拿到的是同一个 ThemeData 实例」—— 现算的话每次都是新对象。
    ThemeData themeOf() => tester
        .widget<Theme>(
          find
              .descendant(
                of: find.byType(GoogleSurface),
                matching: find.byType(Theme),
              )
              .first,
        )
        .data;

    // 注意每次的 child 都不同:传同一个 const widget 会被框架判定为「没变」而整棵跳过,
    // 那样量到的是「没重建」,证明不了缓存。
    await tester.pumpWidget(
      const CupertinoApp(
        home: GoogleSurface(brightness: Brightness.dark, child: Text('一')),
      ),
    );
    final ThemeData dark1 = themeOf();
    await tester.pumpWidget(
      const CupertinoApp(
        home: GoogleSurface(brightness: Brightness.dark, child: Text('二')),
      ),
    );
    final ThemeData dark2 = themeOf();
    expect(identical(dark1, dark2), isTrue, reason: '同亮度必须复用同一份 ThemeData');

    await tester.pumpWidget(
      const CupertinoApp(
        home: GoogleSurface(brightness: Brightness.light, child: Text('三')),
      ),
    );
    final ThemeData light = themeOf();
    expect(identical(light, dark1), isFalse, reason: '深浅两档不能是同一份对象');
    expect(light.colorScheme.brightness, Brightness.light);
  });
}
