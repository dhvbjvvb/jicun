import 'package:flutter/material.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/widgets/animated_tab_icon.dart';

/// 卡片左侧那个圆角图标块。一级设置卡与首页卡片共用同一规格,两级观感才一致。
class GlassIconChip extends StatelessWidget {
  const GlassIconChip({super.key, required this.isDark, required this.asset});

  final bool isDark;
  final String asset;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isDark ? const Color(0x2EFFFFFF) : const Color(0x80FFFFFF),
        borderRadius: BorderRadius.circular(13),
      ),
      // 20 而非资源的 22:图形在 22x22 画布里顶满,按原尺寸画会贴住圆角块。
      child: TintedSvgIcon(
        asset,
        size: 20,
        color: settingsPalette(isDark).foreground,
      ),
    );
  }
}

/// 卡片里的标题 + 副标题。首页与设置页共用,字号字重只有这一份。
class CardHeadline extends StatelessWidget {
  const CardHeadline({
    super.key,
    required this.isDark,
    required this.title,
    required this.subtitle,
    this.subtitleMaxLines = 1,
  });

  // 字号与行高只写这一遍:历史卡要靠它们算出「四行」到底多高。
  static const double _titleSize = 17;
  static const double _titleLineHeight = 1.2;
  static const double _subtitleSize = 13;
  static const double _subtitleLineHeight = 1.25;
  static const double _gap = 3;

  /// 标题两行 + 间隔 + 副标题两行的总高。
  ///
  /// 历史卡把右侧文字区锁成这个高度:标题长短差一行,卡片就会一张高一张矮,
  /// 列表看着参差不齐。
  static const double fourLineHeight =
      _titleSize * _titleLineHeight * 2 +
      _gap +
      _subtitleSize * _subtitleLineHeight * 2;

  final bool isDark;
  final String title;
  final String subtitle;

  /// 副标题行数。默认一行 —— 设置页那一列卡片的高度是量过的,不能自己长高。
  /// 历史卡例外:那里要放下「时间 · 平台 · 类型」,一行只有约 15 个字。
  final int subtitleMaxLines;

  @override
  Widget build(BuildContext context) {
    final (foreground: foreground, secondary: secondary) = settingsPalette(
      isDark,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: foreground,
            fontSize: _titleSize,
            fontWeight: FontWeight.w600,
            height: _titleLineHeight,
          ),
        ),
        const SizedBox(height: _gap),
        Text(
          subtitle,
          maxLines: subtitleMaxLines,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: secondary,
            fontSize: _subtitleSize,
            height: _subtitleLineHeight,
          ),
        ),
      ],
    );
  }
}

