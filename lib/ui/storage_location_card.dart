import 'dart:async';

import 'package:flutter/cupertino.dart';
// material 是**选择性**转出 foundation 的,defaultTargetPlatform 不在里面,得自己引。
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:jicun/downloader.dart';
import 'package:jicun/shell_controller.dart';
import 'package:jicun/ui/glass.dart';
import 'package:jicun/ui/palette.dart';
import 'package:jicun/ui/popup.dart';

/// 「存储保存位置」卡,从 lib/pages/settings.dart 拆出来。
///
/// 它要跟系统的目录选择器打交道(拿 tree uri、落盘偏好),是设置里唯一一块会弹
/// 系统界面的控件,单独放着好读。

/// 「存储保存位置」卡。
///
/// 三行分别是视频/实况、图片、音频。默认走媒体库那套路径(见 [MediaKind.folder]),
/// 用户点行尾的箭头就用系统目录选择器挑一个自定义目录,文件直接写进去;选过之后
/// 行尾多一颗「默认」,点它退回原来的媒体库路径。
///
/// **自定义目录的代价**:SAF 目录里的文件不登记进系统媒体库,相册/音乐 App 未必
/// 收录 —— 这是「任意文件夹」这条路本来就有的取舍。默认路径不受影响,和以前一样。
///
/// 默认路径由平台侧归档决定(Android 见 MainActivity 的 `kindOf` 与 `publish`),
/// 这里只负责显示与选择;两边必须一字不差,否则这页就是在骗用户。
class StorageLocationCard extends StatefulWidget {
  const StorageLocationCard({
    super.key,
    required this.isDark,
    required this.app,
  });

  final bool isDark;

  /// 落盘偏好并触发整页重建(见 [ShellController.applySetting])。
  final ShellController app;

  @override
  State<StorageLocationCard> createState() => _StorageLocationCardState();
}

class _StorageLocationCardState extends State<StorageLocationCard> {
  /// 系统选择器开着时不再接第二次点击(它返回前用户可能连点)。
  bool _picking = false;

  bool get isDark => widget.isDark;

  /// 只有视频那一行的顶层目录两边不一样:Android 的媒体库把视频锁死在 `Movies/`,
  /// 而 Windows 没有媒体库这道门,对应的是用户的标准媒体文件夹 `Videos/`。
  /// 图片和音频两边同名,不用分。
  static List<(MediaKind, String, String)> get _rows {
    final videoRoot = defaultTargetPlatform == TargetPlatform.windows
        ? 'Videos'
        : 'Movies';
    return <(MediaKind, String, String)>[
      (MediaKind.video, '视频 / 实况', '$videoRoot/Jicun/Video'),
      (MediaKind.image, '图片', 'Pictures/Jicun/Picture'),
      (MediaKind.audio, '音频', 'Music/Jicun/Music'),
    ];
  }

  Future<void> _pick(MediaKind kind) async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final target = await Downloader.pickFolder();
      // 用户按返回取消:null,保持原样。
      if (!mounted || target == null) return;
      Downloader.customStorage[kind] = target;
      widget.app.applySetting(() {});
    } catch (error) {
      if (!mounted) return;
      showInfo(context, '没能选到这个目录', '系统没把目录交回来:$error');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _reset(MediaKind kind) {
    Downloader.customStorage.remove(kind);
    widget.app.applySetting(() {});
  }

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(isDark);
    return GlassPanel(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: GoogleCardTitle(
              isDark: isDark,
              text: '存储保存位置（点击路径可自定义）',
            ),
          ),
          for (final (kind, label, defaultPath) in _rows)
            _StoragePathRow(
              isDark: isDark,
              label: label,
              path: Downloader.customStorage[kind]?.label ?? defaultPath,
              custom: Downloader.customStorage.containsKey(kind),
              // 目录选择器只有 Android 侧实现了(见 MainActivity.pickFolder),
              // 别的平台不摆这颗箭头,免得点了报错。
              canPick: defaultTargetPlatform == TargetPlatform.android,
              onPick: () => _pick(kind),
              onReset: () => _reset(kind),
            ),
          // 底部说明:什么时候才需要自定义,以及「默认」是干什么的。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
            child: Text(
              '支持自定义保存路径，默认情况下可不修改。'
              '如果说在相册中没有办法显示出视频或者图片的话，才去自定义修改。'
              '修改过后点击行尾「默认」会回归APP初始路径。',
              style: TextStyle(
                color: palette.secondary,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一行「标签 + 路径 + 箭头」。点整行(含箭头)去选目录;自定义过才多一颗「默认」。
class _StoragePathRow extends StatelessWidget {
  const _StoragePathRow({
    required this.isDark,
    required this.label,
    required this.path,
    required this.custom,
    required this.canPick,
    required this.onPick,
    required this.onReset,
  });

  final bool isDark;
  final String label;
  final String path;
  final bool custom;

  /// 这个平台支不支持选目录。不支持就只显示路径,不摆箭头。
  final bool canPick;
  final VoidCallback onPick;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(isDark);
    return PlainTap(
      onTap: canPick ? onPick : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 5, 8, 5),
        child: Row(
          children: [
            Text(
              label,
              style: TextStyle(color: palette.foreground, fontSize: 15),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                path,
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: custom ? palette.accent : palette.secondary,
                  fontSize: 13,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            if (custom) ...[
              const SizedBox(width: 4),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: Size.zero,
                onPressed: onReset,
                child: Text(
                  '默认',
                  style: TextStyle(color: palette.accent, fontSize: 12),
                ),
              ),
            ],
            if (canPick) ...[
              const SizedBox(width: 4),
              Icon(
                CupertinoIcons.chevron_forward,
                size: 15,
                color: palette.secondary,
              ),
            ],
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}
