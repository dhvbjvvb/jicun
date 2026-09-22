import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'parse_service.dart';

/// 一条解析记录。
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.parsedAt,
    required this.result,
    this.sourceUrl = '',
  });

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
    id: json['id'] as String,
    parsedAt: DateTime.fromMillisecondsSinceEpoch(json['parsedAt'] as int),
    result: ParseResult.fromJson(json['result'] as Map<String, dynamic>),
    // 加这个字段之前存的记录没有它。读成空串、而不是崩 ——
    // 只是那些老记录点进去没法重新解析。
    sourceUrl: json['sourceUrl'] as String? ?? '',
  );

  /// 记录 id。
  ///
  /// 用解析时刻的微秒数,不用接口的 video_id:图集和一些平台没有 video_id,
  /// 而且同一条链接重复解析本来就该各记一条。
  final String id;
  final DateTime parsedAt;
  final ParseResult result;

  /// 解析时用的原始分享链接。历史卡单击后要拿它回解析页重新解析。
  final String sourceUrl;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'parsedAt': parsedAt.millisecondsSinceEpoch,
    'result': result.toJson(),
    'sourceUrl': sourceUrl,
  };
}

/// 解析历史。**只记解析成功的记录**,调用方负责只在这时调 [add]。
///
/// 存 SharedPreferences:几十人的用量、上限 200 条,整块读写完全够用。
/// ponytail: SharedPreferences 每次都是全量读写,几千条以后会明显变慢,
/// 到那时再换 sqlite,现在不值得引一个数据库。
class HistoryStore {
  static const String _key = 'history.entries';

  /// 保留条数上限。超了从最旧的开始丢。
  static const int maxEntries = 200;

  /// id 去重用的自增序号,见 [add]。
  static int _seq = 0;

  /// 新的在前。
  Future<List<HistoryEntry>> load() async {
    final prefs = await _prefs();
    if (prefs == null) return const <HistoryEntry>[];

    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const <HistoryEntry>[];

    try {
      final list = jsonDecode(raw);
      if (list is! List) return const <HistoryEntry>[];
      return <HistoryEntry>[
        for (final item in list)
          if (item is Map<String, dynamic>) HistoryEntry.fromJson(item),
      ];
    } catch (_) {
      // 存坏了就当没有。历史读不出来是小事,不能让它把整个页面拖崩。
      return const <HistoryEntry>[];
    }
  }

  /// 加一条记录,返回加完之后的完整列表(新的在前)。
  ///
  /// 返回列表而不是 void:调用方(根 State)要把结果直接拿去做下一次渲染,
  /// 不必再读一遍存储 —— 那又是一次平台通道往返。
  Future<List<HistoryEntry>> add(ParseResult result, String sourceUrl) async {
    final entries = await load();
    final now = DateTime.now();
    final next = <HistoryEntry>[
      HistoryEntry(
        // 带上自增序号:Windows 上 DateTime.now() 的实际分辨率只有毫秒级,
        // 同一毫秒里连着加两条会撞出同一个 id,删除时就会多删一条。
        id: '${now.microsecondsSinceEpoch}-${_seq++}',
        parsedAt: now,
        result: result,
        sourceUrl: sourceUrl,
      ),
      // 同一条链接只留最新的一条:重复解析一条链接不该在历史里堆成一摞。
      // 新记录已经在上面了,这里把旧的同链接记录剔掉 —— 位置也跟着提到最前。
      for (final entry in entries)
        if (sourceUrl.isEmpty || entry.sourceUrl != sourceUrl) entry,
    ];
    final kept = next.take(maxEntries).toList();
    await _save(kept);
    return kept;
  }

  /// 删掉这几条,返回删完之后的列表。
  Future<List<HistoryEntry>> remove(Set<String> ids) async {
    final entries = await load();
    final kept = <HistoryEntry>[
      for (final entry in entries)
        if (!ids.contains(entry.id)) entry,
    ];
    await _save(kept);
    return kept;
  }

  Future<void> clear() async {
    final prefs = await _prefs();
    await prefs?.remove(_key);
  }

  Future<void> _save(List<HistoryEntry> entries) async {
    final prefs = await _prefs();
    if (prefs == null) return;
    await prefs.setString(
      _key,
      jsonEncode(<Map<String, dynamic>>[
        for (final entry in entries) entry.toJson(),
      ]),
    );
  }

  /// 存储不可用(测试环境、平台异常)时返回 null,调用方退化成「没有历史」,
  /// 而不是抛异常。历史页不该因为存储问题白屏。
  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }
}
