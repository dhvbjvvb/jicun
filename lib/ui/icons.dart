import 'package:flutter/cupertino.dart';

/// 板块图标目录:每个板块一套浅色、一套深色,按当前主题取。
String boardIcon(BuildContext context, String board, String file) {
  final mode = CupertinoTheme.of(context).brightness == Brightness.dark
      ? '深色模式'
      : '浅色模式';
  return '$mode$board/$file';
}

/// 首页板块(解析页)的图标。
String homeIcon(BuildContext context, String file) =>
    boardIcon(context, '首页板块22x22-SVG', file);

/// 历史板块的图标。
String historyIcon(BuildContext context, String file) =>
    boardIcon(context, '历史板块', file);

/// 下载进度弹窗的图标。
///
/// 这套目录的名字是「下载二次弹窗**浅色模式**」—— 模式在后缀,与其它板块
/// (「浅色模式首页板块…」)正好相反,所以不能走 [boardIcon],得单独拼。
String popupIcon(BuildContext context, String file) {
  final mode = CupertinoTheme.of(context).brightness == Brightness.dark
      ? '深色模式'
      : '浅色模式';
  return '下载二次弹窗$mode/$file';
}

/// 设置板块图标目录里的图标。
///
/// 弹窗也用这一套:为一句提示再单独画一张图不值当,而且这些图标本来就只有浅深
/// 两份,和弹窗的取色规则完全一样。
String settingsIcon(BuildContext context, String file) {
  final mode = CupertinoTheme.of(context).brightness == Brightness.dark
      ? '深色主题'
      : '浅色主题';
  return '$mode（设置板块选项图标）/$file';
}

