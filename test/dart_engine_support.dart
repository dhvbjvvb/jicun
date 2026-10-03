// Dart 引擎那几条下载用例的共用夹具。
//
// 只要 dart:io,不碰控件树 —— 所以和 widget_support.dart 分开:那个文件一进来
// 就把手势/控件那一大堆都拖上了。

import 'dart:io';

import 'package:jicun/downloader.dart';

/// 这一趟用例用哪套可调项(见 [DownloadTuning])。
///
/// 这些数字原来是 [Downloader] 上的静态可变量:用例开头改小、末尾拿存下来的原值
/// 还回去,漏还一次就漏给下一条用例。现在它们走构造注入,要别的一套就整份换掉
/// —— [setUp] 里回到出厂值,下面谁都不用管还回去这回事。
DownloadTuning tuning = const DownloadTuning();

/// 跑真实现的「收流」那一步(见 [DownloadDeps.fetch])。
///
/// 位置参数照抄从前那版收流接口的顺序(`item`、临时目录、进度、取消、报大小、
/// HTTP 客户端),换过来只是把 `Downloader.` 换成 `fetchWith(`:可调项不在参数
/// 里,走 [tuning]、[FetchContext.batchItems] 按单文件算。
Future<File> fetchWith(
  DownloadItem item,
  Directory temp,
  void Function(double) onFraction,
  bool Function()? cancelled,
  void Function(int size)? onSize,
  HttpClient client,
) => const DownloadDeps().fetch(
  item,
  FetchContext(
    temp: temp,
    tuning: tuning,
    batchItems: 1,
    onFraction: onFraction,
    cancelled: cancelled,
    onSize: onSize,
    client: client,
  ),
);
