import 'package:flutter/cupertino.dart';

import 'package:jicun/ui/glass.dart';
import 'package:jicun/ui/palette.dart';

/// 播放控件那一层,从 lib/pages/preview.dart 拆出来。
///
/// 视频和音频两个播放区共用这几块,外面那层壳不同(音频整块是渐变底,视频上面
/// 还有 16:9 的画面),所以壳和控件放在一起、画面留在各自的 stage 里。
///
/// [PlaybackRow] 被 widget 测试直接引用(见 test/widget_download_test.dart),
/// 拆出来的第二个理由就是让它有个能单独 import 的家。

/// 一秒级的时间文本(mm:ss)。超过一小时会自然变成三位的分,不做特殊处理。
String clock(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final minutes = (total ~/ 60).toString().padLeft(2, '0');
  final seconds = (total % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// 播放控件外面那层渐变底。
///
/// 音频卡整块都是这个渐变;媒体卡的播放行现在也套同一层 —— 两处的播放控件
/// 看起来才是一套东西,而不是一个有底一个光秃秃。
class PlaybackPanel extends StatelessWidget {
  const PlaybackPanel({super.key, required this.isDark, required this.child});

  final bool isDark;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          // 播放器上那一层渐变:深浅两档都在 Palette 里(playerGradient),值一字不差
          colors: Palette.of(isDark).playerGradient,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
        child: child,
      ),
    );
  }
}

/// 播放控件一行:播放/暂停 + 可拖的进度条 + 已播/总时长。
///
/// 音频和视频共用 —— 两边的播放语义完全一样,只有外面那层壳不同
/// (都套 [PlaybackPanel],音频上面没有画面,视频上面是 16:9 画面)。
class PlaybackRow extends StatelessWidget {
  const PlaybackRow({
    super.key,
    required this.isDark,
    required this.playing,
    required this.position,
    required this.duration,
    required this.enabled,
    required this.onToggle,
    required this.onSeek,
  });

  final bool isDark;
  final bool playing;
  final Duration position;

  /// 还没读出时长时为 null(音频要等 setUrl 完成,视频要等 initialize 完成)。
  final Duration? duration;

  /// 播放器可用才亮;没地址或加载失败时整行是灰的。
  final bool enabled;
  final VoidCallback onToggle;

  /// 拖进度条。参数是目标位置。
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    final secondary = settingsPalette(isDark).secondary;
    final accent = Palette.of(isDark).accent;
    final total = duration;

    return Row(
      children: [
        PlainTap(
          onTap: enabled ? onToggle : null,
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: enabled ? accent : secondary.withValues(alpha: 0.35),
              shape: BoxShape.circle,
            ),
            child: Icon(
              playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
              size: 18,
              // 深色模式的强调色是亮蓝,压白图标会糊;那里换成近黑
              color: isDark ? const Color(0xFF10161F) : const Color(0xFFFFFFFF),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            children: [
              ScrubBar(
                position: position,
                duration: total,
                onSeek: onSeek,
                accent: accent,
                track: secondary.withValues(alpha: 0.28),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    clock(position),
                    style: TextStyle(color: secondary, fontSize: 11.5),
                  ),
                  const Spacer(),
                  Text(
                    total == null ? '--:--' : clock(total),
                    style: TextStyle(color: secondary, fontSize: 11.5),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 可拖可点的进度条。
///
/// 触摸区给到 20 高(而不是那 4 个像素),否则手指根本按不准;
/// 位置按整个宽度等比换算成时间。
class ScrubBar extends StatelessWidget {
  const ScrubBar({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
    required this.accent,
    required this.track,
  });

  final Duration position;
  final Duration? duration;
  final ValueChanged<Duration> onSeek;
  final Color accent;
  final Color track;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = duration?.inMilliseconds ?? 0;
        final width = constraints.maxWidth;
        final fraction = total <= 0
            ? 0.0
            : (position.inMilliseconds / total).clamp(0.0, 1.0);

        void seekTo(double dx) {
          if (total <= 0 || width <= 0) return;
          final f = (dx / width).clamp(0.0, 1.0);
          onSeek(Duration(milliseconds: (f * total).round()));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => seekTo(details.localPosition.dx),
          onHorizontalDragUpdate: (details) => seekTo(details.localPosition.dx),
          child: SizedBox(
            height: 20,
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: SizedBox(
                  height: 4,
                  child: Stack(
                    children: [
                      Positioned.fill(child: ColoredBox(color: track)),
                      // 宽度直接算出来,不用 Expanded(flex:):fraction 为 0 时
                      // flex 也是 0,而 flex 0 的子项在 Row 里会退化成「按自身尺寸」,
                      // 进度条会整根跳到满格。
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: width * fraction,
                        child: ColoredBox(color: accent),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
