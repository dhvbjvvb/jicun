import 'dart:async';

import 'package:flutter/cupertino.dart';
// material 是**选择性**转出 foundation 的,defaultTargetPlatform 不在里面,得自己引。
import 'package:flutter/material.dart';
import 'package:jicun/shell_controller.dart';
import 'package:jicun/ui/glass.dart';
import 'package:jicun/ui/icons.dart';
import 'package:jicun/ui/motion.dart';
import 'package:jicun/ui/notifications.dart';
import 'package:jicun/ui/popup.dart';
import 'package:jicun/ui/storage_location_card.dart';

/// 「通知管理与下载」二级页,从 lib/pages/settings.dart 拆出来。
///
/// 这一页有自己的状态(两个开关 + 一次通知自测),和索引页那张只负责跳转的列表
/// 不是一类东西,所以单独一个文件。

class NotificationManagementPage extends StatefulWidget {
  const NotificationManagementPage({super.key, required this.app});

  /// 这两个开关下载流程要用,所以和「主题与外观」一样直接持有根 State。
  final ShellController app;

  @override
  State<NotificationManagementPage> createState() =>
      NotificationManagementPageState();
}

class NotificationManagementPageState
    extends State<NotificationManagementPage> {
  bool _isSending = false;

  ShellController get app => widget.app;

  /// 要一次通知权限。和首次授权卡走同一个实现,免得两处判断分家。
  Future<bool> _requestPermission() => requestNotificationPermission();

  /// 拨一个下载通知开关。
  ///
  /// 打开前先要系统通知权限:没权限就别把开关点亮 —— 点亮了却弹不出通知,
  /// 用户只会以为是我们没做。关闭不需要权限,直接写。
  Future<void> _setNotify({required bool onDone, required bool value}) async {
    if (value) {
      final granted = await _requestPermission();
      if (!mounted) return;
      if (!granted) {
        showInfo(
          context,
          '通知权限未开启',
          '请在系统设置中允许即存发送通知。',
          icon: settingsIcon(context, '通知管理.svg'),
        );
        return;
      }
    }
    app.applySetting(() {
      if (onDone) {
        app.notifyDownloadDone = value;
      } else {
        app.notifyDownloadFailed = value;
      }
    });
  }

  Future<void> _sendTestNotification() async {
    setState(() => _isSending = true);
    try {
      final granted = await _requestPermission();
      if (!mounted) return;
      if (!granted) {
        showInfo(
          context,
          '通知权限未开启',
          '请在系统设置中允许即存发送通知。',
          icon: settingsIcon(context, '通知管理.svg'),
        );
        return;
      }
      final ready = notificationsReady;
      if (ready != null) await ready;
      await notifications.show(
        id: DateTime.now().millisecondsSinceEpoch.remainder(1000000),
        title: '即存通知测试',
        body: '通知功能运行正常。',
        notificationDetails: kNotificationDetails,
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    // 给顶栏图让出的高度。图按屏宽等比缩,所以这里也按屏宽算,
    // 两边同一个 kHeaderArtAspect,界面缩放下不会错位。
    final headerHeight = MediaQuery.sizeOf(context).width / kHeaderArtAspect;
    // 画面底边在画布 564/605 处(实测 bbox;画布下方那段是透明的),
    // 第一张卡从图底边往下 5dp 起。
    final headerBottom = headerHeight * 564 / 605;

    return SubPage(
      title: '通知管理与下载',
      // 抠好的插画带一圈白描边:深色模式下靠它把角色从背景里拎出来,
      // 浅色模式下描边和背景同色等于隐形,所以深浅两模式共用这一张。
      headerImage: 'assets/theme-header/theme_top_2.webp',
      child: GoogleSurface(
        brightness: isDark ? Brightness.dark : Brightness.light,
        child: SafeArea(
          child: ListView(
            physics: const ShortBounceScrollPhysics(),
            padding: EdgeInsets.fromLTRB(20, headerBottom + 5, 20, 32),
            children: [
              GlassPanel(
                isDark: isDark,
                child: GoogleSwitchRow(
                  isDark: isDark,
                  title: '下载完成通知',
                  subtitle: '下载成功后,在系统状态栏提醒一声',
                  value: app.notifyDownloadDone,
                  onChanged: (value) => _setNotify(onDone: true, value: value),
                ),
              ),
              const SizedBox(height: 12),
              GlassPanel(
                isDark: isDark,
                child: GoogleSwitchRow(
                  isDark: isDark,
                  title: '下载失败通知',
                  subtitle: '下载中断或出错时提醒,免得白等',
                  value: app.notifyDownloadFailed,
                  onChanged: (value) => _setNotify(onDone: false, value: value),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _isSending ? null : _sendTestNotification,
                child: Text(_isSending ? '发送中…' : '测试通知'),
              ),
              const SizedBox(height: 24),
              StorageLocationCard(isDark: isDark, app: app),
            ],
          ),
        ),
      ),
    );
  }
}
