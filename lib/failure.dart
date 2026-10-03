import 'package:flutter/foundation.dart';

/// 记一条「这里**故意**吞掉了异常」。
///
/// 为什么要有它:这类点以前写的是 `catch (_) {}`,读代码时分不清是**想清楚了要
/// 吞**还是**漏处理**——两者长得一模一样。现在每处都必须给出 [tag](用点分段,
/// 例如 `cover.trim`),静态读一遍就能把「已知可吞」和「待查」分开,日志里也能按
/// tag 过滤。
///
/// 行为不变:release 下是空函数(只留一次 debug 判断),debug 下才进日志 ——
/// 和 [bench.dart] 里 `if (kDebugMode) debugPrint(...)` 同一个路数。
///
/// 用法:
/// ```dart
/// try {
///   await file.delete();
/// } catch (error, stack) {
///   swallow('cover.trim', error, stack);
/// }
/// ```
///
/// 反过来:**不希望被吞的异常不要用它**。写进这里等于对外声明「这条失败的后果我
/// 认了」,所以吞之前先想清楚后果是什么、写进上面那行注释。
void swallow(String tag, Object error, [StackTrace? stack]) {
  if (!kDebugMode) return;
  debugPrint('[swallow:$tag] $error${stack == null ? '' : '\n$stack'}');
}
