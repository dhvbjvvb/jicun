import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:jicun/parse_service.dart';
import 'package:jicun/ui/geometry.dart';
import 'package:jicun/ui/icons.dart';
import 'package:jicun/ui/motion.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/ui/popup.dart';

/// 横排缩略图那一条、它的一格、以及点眼睛弹出的大图窗口,从 lib/pages/preview.dart
/// 拆出来。
///
/// 图集卡、多视频卡、混合卡共用这一套排版;而「混合卡里第几格对应要下的哪一条」
/// 那两组函数([galleryEntries] / [mixedMedia])必须跟着一起走 —— 选中状态是按同一
/// 套下标存的,分开就又要对着两份顺序看。

/// 缩略图网格里的一格:一条地址 + 它是不是视频。
///
/// 视频那几格的封面用接口给的首帧,右下角压一个播放标识和图片区分开。
typedef MediaThumb = ({String url, bool isVideo});

/// 混合卡的缩略图条目:视频在前、图片在后。
///
/// 顺序和 [PreviewCardState._items] 必须一致 —— 选中状态是按这里的下标存的,
/// 两边错了就会「点第一格选中第三格」。
List<MediaThumb> galleryEntries(ParseResult result) => <MediaThumb>[
  for (final v in result.videoItems) (url: v.coverUrl ?? '', isVideo: true),
  for (final url in result.imageUrls) (url: url, isVideo: false),
];

/// 混合卡里真正要下载的东西。顺序与 [galleryEntries] 一一对应(选中按同一个下标
/// 存),但视频那一格给的是**视频地址**,不是封面。
///
/// 封面是给网格显示的 jpg。拿它当视频下,文件名会按地址取到 `.jpg`、MIME 变成
/// image/jpeg,而 kind 还是 video —— 媒体库直接拒收:
/// `publish_failed: MIME type image/jpeg cannot be inserted into
/// content://media/external_primary/video/media`。
List<({String url, bool isVideo})> mixedMedia(ParseResult result) => [
  for (final v in result.videoItems) (url: v.url, isVideo: true),
  for (final url in result.imageUrls) (url: url, isVideo: false),
];

/// 预览区的缩略图条:一条横向缩略图,底下一行数量。
///
/// 图集用图片,两个以上视频用视频封面 —— 需求就是这两种走同一套排版。
/// 高度写死 96:横向列表在竖向列表里必须有确定高度;竖向滚动与横向滚动各管各的,
/// 手势不会互相抢。
///
/// [selectable] 为真(两条以上媒体)时点一下缩略图切换选中,选中的角标是
/// 中心一个圆圈加勾;单选一条的链接不带到选中逻辑,点图也不选中。
class GalleryStage extends StatelessWidget {
  const GalleryStage({
    super.key,
    required this.isDark,
    required this.entries,
    required this.selected,
    required this.onTapTile,
    required this.emptyHint,
    required this.unit,
  });

  static const double _tileWidth = 72;
  static const double _tileHeight = 96;

  final bool isDark;
  final List<MediaThumb> entries;
  final Set<int> selected;
  final ValueChanged<int> onTapTile;

  /// 没有内容时显示的那句话。
  final String emptyHint;

  /// 数量后面那个量词:「张」/「个」/「项」。
  final String unit;

  /// 两条以上才有「选中」这回事:一条链接只有一条媒体时,点图不选中,
  /// 底部也直接给一颗能按的「下载媒体」。
  bool get _selectable => entries.length > 1;

  @override
  Widget build(BuildContext context) {
    final secondary = settingsPalette(isDark).secondary;
    final fill = Palette.of(isDark).surface;

    if (entries.isEmpty) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(kStageRadius),
        ),
        child: SizedBox(
          height: _tileHeight,
          child: Center(
            child: Text(
              emptyHint,
              style: TextStyle(color: secondary, fontSize: 13),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: _tileHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const ShortBounceScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) => GalleryTile(
              isDark: isDark,
              thumb: entries[index],
              width: _tileWidth,
              height: _tileHeight,
              selectable: _selectable,
              selected: selected.contains(index),
              onTap: () => onTapTile(index),
              // 视频封面不是一张能看的图,不给眼睛(它自己那格已经有播放标识)。
              onPreview: entries[index].isVideo
                  ? null
                  : () => _openPreview(context, entries[index].url),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '共 ${entries.length} $unit',
          style: TextStyle(color: secondary, fontSize: 12.5),
        ),
      ],
    );
  }

  /// 点缩略图右下角那只眼睛:开一个窗口看这张图的原片。
  ///
  /// 传进去的就是这一格自己那条地址 —— 上游给的图集地址本来就是原图,没有另给一条
  /// 缩略图地址。窗口里按图片自己的分辨率解码(`Image.network` 不传 cacheWidth),
  /// 不是把 72 宽的缩略图拉大。
  void _openPreview(BuildContext context, String url) {
    unawaited(
      showGlassLayer<void>(
        context,
        builder: (_) => ImageViewerDialog(url: url),
      ),
    );
  }
}

/// 缩略图条里的一格。
///
/// 静态展示时就是一个圆角图;可选中时整格可点,选中后中央压一层圆圈加勾,
/// 并给整格描一圈强调色边 —— 缩略图横条在深色玻璃上,单靠中心圈不够显眼。
class GalleryTile extends StatelessWidget {
  const GalleryTile({
    super.key,
    required this.isDark,
    required this.thumb,
    required this.width,
    required this.height,
    required this.selectable,
    required this.selected,
    required this.onTap,
    required this.onPreview,
  });

  final bool isDark;
  final MediaThumb thumb;
  final double width;
  final double height;
  final bool selectable;
  final bool selected;
  final VoidCallback onTap;

  /// 点右下角那只眼睛的回调。null = 这格不是图片(视频封面),不给眼睛。
  final VoidCallback? onPreview;

  @override
  Widget build(BuildContext context) {
    final secondary = settingsPalette(isDark).secondary;
    final accent = Palette.of(isDark).accent;
    final fill = Palette.of(isDark).surface;

    // 尺寸写死:横向列表里 Stack 的 fit 是 expand,不给死宽度它就问父级要,
    // 而父级给的是无限宽 —— 直接崩在 layout 上。
    final tile = SizedBox(
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ColoredBox(
              color: fill,
              // 单张挂了不影响整条:退回一块占位图标(图和视频用不同的)
              child: Image.network(
                thumb.url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Center(
                  child: Icon(
                    thumb.isVideo
                        ? CupertinoIcons.play_circle_fill
                        : CupertinoIcons.photo,
                    size: 22,
                    color: secondary.withValues(alpha: 0.45),
                  ),
                ),
              ),
            ),
          ),
          // 视频那几格右下角压一个播放标识,一眼分得出哪格是视频、哪格是图片。
          if (thumb.isVideo)
            const Positioned(
              right: 4,
              bottom: 4,
              child: _Badge(CupertinoIcons.play_fill),
            ),
          // 图片那几格右下角压一只眼睛,和视频的播放标识同一处、同一套底,一眼分得出
          // 这格是图片、点它能看大图。
          //
          // 触摸区比标识本身大一圈(标识 17,这里 29):11 像素的图形手指按不准。
          // 这层在 Stack 里排在后面,命中最先落到它身上,外层那颗「点图选中」不会
          // 被一起触发。
          if (onPreview != null)
            Positioned(
              right: 0,
              bottom: 0,
              child: Semantics(
                button: true,
                label: '查看大图',
                child: GestureDetector(
                  onTap: onPreview,
                  behavior: HitTestBehavior.opaque,
                  child: const Padding(
                    padding: EdgeInsets.fromLTRB(8, 8, 4, 4),
                    child: _Badge(CupertinoIcons.eye_fill),
                  ),
                ),
              ),
            ),
          if (selected)
            DecoratedBox(
              decoration: BoxDecoration(
                // 边框压在圆角图上会被裁掉一角,半径比图大 2:角上刚好露满
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: accent, width: 2),
              ),
            ),
          if (selected)
            Center(
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent,
                  border: Border.all(
                    color: const Color(0xFFFFFFFF),
                    width: 1.6,
                  ),
                ),
                child: const Icon(
                  CupertinoIcons.check_mark,
                  size: 16,
                  color: Color(0xFFFFFFFF),
                ),
              ),
            ),
        ],
      ),
    );

    if (!selectable) return tile;
    return GestureDetector(
      onTap: onTap,
      // 缩略图是缩略图,不是按钮:点击反馈给在选中角标上,不铺水波纹
      behavior: HitTestBehavior.opaque,
      child: tile,
    );
  }
}

/// 压在缩略图右下角的小圆标:半透明黑底 + 白色图形。
///
/// 视频格用播放标识、图片格用眼睛 —— 位置和底只留这一份,两格的观感才一致。
class _Badge extends StatelessWidget {
  const _Badge(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      color: Color(0x8C000000),
    ),
    child: Padding(
      padding: const EdgeInsets.all(3),
      child: Icon(icon, size: 11, color: const Color(0xFFFFFFFF)),
    ),
  );
}

/// 点缩略图右下角那只眼睛弹出来的大图预览。
///
/// 窗口里是**这张图的原片**:`Image.network` 不传 cacheWidth,解码器按图片自己的
/// 分辨率解,不是把 72 宽的缩略图拉大。加载中、加载失败时窗口一样高 —— 高度按
/// 屏幕算死,面板不给大图撑得上下跳。
///
/// 图下面那颗「关闭」是需求里指定的出口;头部右上角那颗叉是这套弹窗本来就有的,
/// 两条路都关得掉。
class ImageViewerDialog extends StatelessWidget {
  const ImageViewerDialog({super.key, required this.url});

  /// 原片地址。
  final String url;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final secondary = settingsPalette(isDark).secondary;
    final fill = Palette.of(isDark).surface;
    final screenHeight = MediaQuery.sizeOf(context).height;
    // 图片占屏幕的 58%,再留 200 给头部、关闭按钮和面板内边距 —— 横屏或小屏上
    // 面板(Column,不滚动)会装不下那么多行,撑破就是一条黄黑警告带。
    final imageHeight = math.min(screenHeight * 0.58, screenHeight - 200);

    return PopupShell(
      title: '图片预览',
      icon: homeIcon(context, '图集预览.svg'),
      // 比普通提示卡宽:300 宽的面板里那张图只剩 272,看不出"大图"
      maxWidth: 380,
      onClose: () => Navigator.of(context).pop(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ColoredBox(
              color: fill,
              child: SizedBox(
                width: double.infinity,
                height: imageHeight,
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child
                      : const Center(child: CupertinoActivityIndicator()),
                  // 地址多半带签名、会过期,下来就退回一个占位图,别让窗口空着
                  errorBuilder: (_, _, _) => Center(
                    child: Icon(
                      CupertinoIcons.photo,
                      size: 34,
                      color: secondary.withValues(alpha: 0.45),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          PopupPrimaryButton(
            label: '关闭',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}
