import 'dart:async';

import 'package:flutter/cupertino.dart';
// material 是**选择性**转出 foundation 的,defaultTargetPlatform 不在里面,得自己引。
import 'package:jicun/sponsor_store.dart';
import 'package:jicun/ui/glass.dart';
import 'package:jicun/ui/motion.dart';
import 'package:jicun/ui/palette.dart';

/// 「赞助名单」二级页,从 lib/pages/settings.dart 拆出来。
///
/// 数据来自服务端下发的 /sponsors.json(见 lib/sponsor_store.dart),这一页只管
/// 呈现和刷新,所以和设置索引页没有共用状态。

/// 「设置 → 赞助名单」的二级页。
///
/// 一张表:昵称 / 时间 / 金额。后两列定宽、昵称列弹性 —— 昵称是最长也最杂的一列
/// (半角星号、全角括号、emoji 都有),把它放成 Expanded,后两列各自定宽,整张表
/// 才有一致的右边界。表头下面一条淡线代替竖线,和 APP 里卡片之间不加边框的做法一致。
///
/// 原来那张提示卡和底部两个角色底图已经删掉(需求点名)。
///
/// 数据不再是编译进包里的常量:服务端把飞书多维表格导成 /sponsors.json,这里读
/// [sponsorStore](缓存 + 内置兜底,见 lib/sponsor_store.dart)。所以服务端改表之后
/// 不用发版,APP 下次打开这一页就是新的。
class SponsorPage extends StatefulWidget {
  const SponsorPage({super.key});

  @override
  State<SponsorPage> createState() => _SponsorPageState();
}

class _SponsorPageState extends State<SponsorPage> {
  /// 时间列宽:'9月30日' 差不多就占这么宽。
  static const double _dateWidth = 64;

  /// 金额列宽:最长那条再加一点余量。
  static const double _amountWidth = 74;

  @override
  void initState() {
    super.initState();
    // 这一句只负责「把最新那份拿回来」,不负责「先把表画出来」:表在 build 里
    // 立刻就读了 sponsorStore.list(bootstrap 在第一帧之前已经读过缓存,没缓存
    // 就是内置兜底),网络回来时 notifyListeners 自己重画。
    //
    // 所以打开这一页永远不等网络 —— 别把它改成 await 之后再 setState。
    unawaited(sponsorStore.ensureLoaded());
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final palette = Palette.of(isDark);
    return SubPage(
      title: '赞助名单',
      child: GoogleSurface(
        brightness: isDark ? Brightness.dark : Brightness.light,
        child: SafeArea(
          child: ListenableBuilder(
            listenable: sponsorStore,
            builder: (context, _) {
              final List<Sponsor> sponsors = sponsorStore.list;
              return ListView(
                physics: const ShortBounceScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
                children: [
                  GlassPanel(
                    isDark: isDark,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                      child: Column(
                        children: [
                          _row(
                            palette: palette,
                            name: '微信昵称',
                            date: '赞助时间',
                            amount: '赞助金额',
                            header: true,
                          ),
                          // 表头下面一条淡线代替竖线,别把表格画成 Excel。
                          Container(
                            height: 1,
                            margin: const EdgeInsets.only(bottom: 2),
                            color: palette.secondary.withValues(alpha: 0.18),
                          ),
                          for (final (name, date, amount) in sponsors)
                            _row(
                              palette: palette,
                              name: name,
                              date: date,
                              amount: amount,
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _row({
    required Palette palette,
    required String name,
    required String date,
    required String amount,
    bool header = false,
  }) {
    final Color color = header ? palette.secondary : palette.foreground;
    final FontWeight weight = header ? FontWeight.w600 : FontWeight.w400;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: weight,
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: _dateWidth,
            child: Text(
              date,
              textAlign: TextAlign.right,
              maxLines: 1,
              style: TextStyle(
                color: header ? color : palette.secondary,
                fontSize: 14,
                fontWeight: weight,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: _amountWidth,
            child: Text(
              amount,
              textAlign: TextAlign.right,
              maxLines: 1,
              style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: weight,
                // 金额用等宽:小数点上下对齐,一列数字才整齐。
                fontFamily: header ? null : 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
