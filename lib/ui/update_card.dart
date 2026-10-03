// 「版本更新」卡片:标题 + 版本号 + 说明预览(markdown)+ 底部左更新右忽略,
// 外加说明预览窗口自己那套排版(固定 [kNotesLines] 行高、超了才挂滚动条)。
//
// 从 popup.dart 拆出来:它和下载卡一样只用弹层外壳(popup.dart),不掺别的弹层。

import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:jicun/ui/icons.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/ui/markdown.dart';
import 'package:jicun/ui/popup.dart';
import 'package:jicun/update_service.dart';

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

  /// 链接色。和设置页、历史页那些可点文字同一档。
  Color get _linkColor =>
      Palette.of(isDark).accent;

  /// 一行的完整 span。渲染和量高度共用同一份,样式不会跑偏。
  TextSpan _spanFor(MdLine line) {
    final base = _styleFor(line.kind, empty: line.text.isEmpty);
    // 空行还是一颗空 span:它只负责撑出一行的高度。
    if (line.runs.isEmpty && line.prefix.isEmpty) {
      return TextSpan(text: '', style: base);
    }
    return TextSpan(
      style: base,
      children: <InlineSpan>[
        if (line.prefix.isNotEmpty) TextSpan(text: line.prefix),
        for (final run in line.runs)
          TextSpan(text: run.text, style: _runStyle(base, run)),
      ],
    );
  }

  /// 行内样式叠在整行样式上面:粗体 / 斜体 / 删除线 / 下划线 / 行内代码 / 链接。
  TextStyle _runStyle(TextStyle base, MdRun run) {
    var style = base;
    if (run.code) {
      style = style.copyWith(
        fontFamily: 'monospace',
        // 等宽字比正文看着大一号,压掉 1px 才和左右的行对齐。
        fontSize: (base.fontSize ?? _baseFontSize) - 1,
        color: secondary,
      );
    }
    if (run.link) style = style.copyWith(color: _linkColor);
    final decorations = <TextDecoration>[
      if (run.underline || run.link) TextDecoration.underline,
      if (run.strike) TextDecoration.lineThrough,
    ];
    if (decorations.isNotEmpty) {
      style = style.copyWith(decoration: TextDecoration.combine(decorations));
    }
    if (run.bold) style = style.copyWith(fontWeight: FontWeight.w700);
    if (run.italic) style = style.copyWith(fontStyle: FontStyle.italic);
    return style;
  }

  /// 一行文字。居中 / 居右靠 textAlign,所以内容列在横向是撑满的。
  Widget _lineWidget(MdLine line) {
    final text = Text.rich(
      _spanFor(line),
      textAlign: switch (line.align) {
        MdAlign.center => TextAlign.center,
        MdAlign.right => TextAlign.right,
        MdAlign.left => TextAlign.left,
      },
    );
    if (line.indent == 0) return text;
    return Padding(
      padding: EdgeInsets.only(left: line.indent * 14),
      child: text,
    );
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

    // 宽度取**布局引擎真给这块的**宽度([LayoutBuilder] 的 constraints),不再从屏幕宽度
    // 一层层减掉内边距去"倒推"面板宽度 —— 倒推少减一层就量宽了,行数算少,于是滚动条
    // 不挂、多出来的字直接画到下面的更新/忽略按钮上。这条路径以前就是这么错的。
    return LayoutBuilder(
      builder: (context, constraints) => _body(context, lines, constraints),
    );
  }

  /// 排出版式:高度锁死 [kNotesLines] 行,内容超了才挂滚动条。
  ///
  /// [constraints] 出自上面那个 [LayoutBuilder] —— 面板实际能给的宽度就是它,
  /// 量行数必须按这个算。
  Widget _body(
    BuildContext context,
    List<MdLine> lines,
    BoxConstraints constraints,
  ) {
    const maxHeight = _lineHeight * kNotesLines;
    // 半像素余量:行高是算出来的,和布局引擎里的实际值差一点点;刚好 12 行时
    // 不该被判成"超了"而多出一条滚动条。
    final scrollable =
        _measure(
          lines,
          constraints.maxWidth - _horizontalPadding * 2 - kScrollbarGutter,
          MediaQuery.textScalerOf(context),
        ) >
        maxHeight + 0.5;

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _horizontalPadding),
      child: Column(
        // 横向撑满:居中 / 居右的行要有整条宽度才能对齐,只按自身宽度排版的话
        // textAlign 是看不出来的。
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final line in lines) _lineWidget(line),
        ],
      ),
    );

    return Container(
      height: maxHeight,
      decoration: BoxDecoration(
        // 比卡片底色再压一层:预览窗口和卡片本体的边界就出来了,不用画线。
        // 这两个黑(深 10% / 浅 5%)不在 Palette 里:surfaceClear 是白色系那一对,
        // 套上去浅色档反而会变亮,边界就没了。
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

  /// 把每一行按 [textWidth] 量一遍,加起来就是整块内容的高度。
  ///
  /// 不能用 `maxLines: 12` 糊弄过去:那样量不出"到底超没超",而滚动条要按这个
  /// 判断挂不挂。
  ///
  /// [textWidth] 由调用方从 [LayoutBuilder] 的约束里减出来。以前这里是拿**屏幕**宽度
  /// 减掉几层内边距去倒推面板宽度:面板被 [kPopupPanelMaxWidth] 卡住而屏幕可以更宽,
  /// 412dp 的机器上按屏幕算出来是 306、内容实际只有 242 —— 行数少算四分之一,
  /// 13~16 行的说明被判成"不超 12 行"。
  double _measure(List<MdLine> lines, double textWidth, TextScaler scaler) {
    var total = 0.0;
    for (final line in lines) {
      // 缩进的行排版宽度少一截,不减的话量出来的比实际窄,行数会多算
      final available = textWidth - line.indent * 14;
      final painter = TextPainter(
        text: _spanFor(line),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(maxWidth: math.max(available, 1.0));
      total += painter.height;
    }
    return total;
  }
}
