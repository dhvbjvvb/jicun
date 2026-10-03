// 下载前的清晰度选择窗。
//
// 从 popup.dart 拆出来:它独有一条「列表 + 不预选」的交互,和提示卡只共用外壳
// ([PopupShell] / [showGlassLayer],都还在 popup.dart)。

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:jicun/parse_service.dart';
import 'package:jicun/ui/icons.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/ui/popup.dart';

/// 下载前先问一句「要哪一档清晰度」。
///
/// **只在第二个上游(有分辨率列表)解析成功时才会出现**:media-parser 的结果里
/// 根本没有 [VideoQuality],传进来就是空列表,调用方也就不该开这个弹窗。
///
/// 返回用户选中的那一档;点右上角的叉返回 null,调用方据此取消这次下载。
///
/// 两个要点:
/// - 列表里同一档分辨率只会出现一次 —— 去重在上游映射那一步就做完了
///   (见 parse_service.dart 的 dedupeQualities),这里只管显示;
/// - 不预选任何一项。默认选中会让用户顺手点「确定」下到一档他没看过的清晰度,
///   而下载是几十上百 MB 的事,值得让他自己点一下。
Future<VideoQuality?> showQualityPicker(
  BuildContext context, {
  required List<VideoQuality> qualities,
}) => showGlassLayer<VideoQuality>(
  context,
  builder: (context) => QualityPickerDialog(qualities: qualities),
);

class QualityPickerDialog extends StatelessWidget {
  const QualityPickerDialog({super.key, required this.qualities});

  final List<VideoQuality> qualities;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final (foreground: foreground, secondary: secondary) = settingsPalette(
      isDark,
    );
    return PopupShell(
      title: '选择清晰度',
      // 用首页板块那套图标:`下载媒体.svg` 只在「浅色/深色模式首页板块22x22-SVG/」
      // 里,设置板块那套没有它。写成 settingsIcon 会抛
      // "Unable to load asset: 深色主题（设置板块选项图标）/下载媒体.svg" ——
      // 弹窗照常显示,但控制台每次刷一屏未捕获异常(真机实测)。
      icon: homeIcon(context, '下载媒体.svg'),
      onClose: () => Navigator.of(context).pop(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 屏小的机器上档位可能占掉大半个屏幕,这里限高并允许滚动。
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: qualities.length,
              separatorBuilder: (_, _) => Container(
                height: 1,
                color: secondary.withValues(alpha: 0.16),
              ),
              itemBuilder: (context, index) {
                final q = qualities[index];
                return QualityOptionRow(
                  quality: q,
                  isDark: isDark,
                  foreground: foreground,
                  secondary: secondary,
                  onPressed: () => Navigator.of(context).pop(q),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 清晰度列表里的一行:左边档位名,右边码率/体积。
class QualityOptionRow extends StatelessWidget {
  const QualityOptionRow({
    super.key,
    required this.quality,
    required this.isDark,
    required this.foreground,
    required this.secondary,
    required this.onPressed,
  });

  final VideoQuality quality;
  final bool isDark;
  final Color foreground;
  final Color secondary;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // 认不出分辨率时给一句「默认画质」,别让这一行左边空着 —— 空标签看着像没加载完。
    final label = quality.label.isEmpty ? '默认画质' : quality.label;
    final detail = quality.detail;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (detail.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(detail, style: TextStyle(color: secondary, fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
