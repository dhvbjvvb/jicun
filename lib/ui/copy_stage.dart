import 'package:flutter/cupertino.dart';

import 'package:jicun/ui/geometry.dart';
import 'package:jicun/ui/palette.dart';

/// 文案卡的文字区,从 lib/pages/preview.dart 拆出来。
///
/// 「不超过 12 行就跟着文字走、超过就锁 12 行并出滚动条」那套判据是它自己的,靠
/// 真实的 TextPainter 量出来(不能用 maxLines + ellipsis 截断,那样会把后面的
/// 文案直接丢掉)。

/// 文案内文字区最多显示多少行。超过就锁这么高,右侧出滚动条。
const int kCopyMaxLines = 12;

/// 文案预览区:整块只放描述文案。
///
/// 两种排法,按真实行数二选一:
/// - **不超过 12 行**:窗口跟着文字走,有几行就几行,不留空白;
/// - **超过 12 行**:窗口锁死在 12 行高,右侧出一根滚动条,上下滑动看全文。
///
/// 这里**不能**用 `maxLines` + ellipsis 截断 —— 那是把后面的文案直接丢掉。
/// 实测一条长文案在 App 上只显示到一半,接口返回的其实是完整的。
class CopyStage extends StatefulWidget {
  const CopyStage({super.key, required this.isDark, required this.text});

  final bool isDark;
  final String text;

  @override
  State<CopyStage> createState() => CopyStageState();
}

class CopyStageState extends State<CopyStage> {
  final ScrollController _scroll = ScrollController();

  static const double _fontSize = 14;
  static const double _lineHeight = 1.5;

  /// 一行占的高度。字号 × 行高倍数。
  static const double _lineBox = _fontSize * _lineHeight;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color foreground = settingsPalette(widget.isDark).foreground;
    final fill = Palette.of(widget.isDark).surface;
    final style = TextStyle(
      color: foreground.withValues(alpha: 0.86),
      fontSize: _fontSize,
      height: _lineHeight,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // 先用同一套样式量一遍,数出真实行数 —— 要不要锁高、要不要出滚动条
        // 全看它。不量的话这两种情况在布局前根本分不出来。
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          textDirection: Directionality.of(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.computeLineMetrics().length > kCopyMaxLines;

        final text = Text(widget.text, style: style);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(kStageRadius),
          ),
          child: ConstrainedBox(
            // 不满 12 行时不设上限,窗口自然收缩到文字高度
            constraints: BoxConstraints(
              maxHeight: overflows ? _lineBox * kCopyMaxLines : double.infinity,
            ),
            child: overflows
                // 用 CupertinoScrollbar 而不是 Material 的 Scrollbar:
                // 这个文件根本不 import material(只用 cupertino 那一套),
                // 而且整个 App 就是 Cupertino 风格,滚动条也跟着一致。
                // 上一版注释写的是「material 导入是 show 白名单,没带 Scrollbar」——
                // 那是它还住在 pages/preview.dart 里时的情形,搬出来就不成立了。
                ? CupertinoScrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      // 右边多留一点,免得滚动条压在字上
                      padding: const EdgeInsets.fromLTRB(14, 16, 10, 16),
                      child: text,
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
                    child: text,
                  ),
          ),
        );
      },
    );
  }
}
