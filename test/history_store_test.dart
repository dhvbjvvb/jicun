import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:untitled/history_store.dart';
import 'package:untitled/parse_service.dart';

const String _link = 'https://v.douyin.com/abcd/';

ParseResult _sample({
  String title = '示例标题',
  String? videoUrl = 'https://cdn.example/v.mp4',
  String? audioUrl,
  List<String> images = const [],
}) => ParseResult(
  title: title,
  desc: '示例文案',
  platform: '抖音',
  authorName: '作者',
  videoUrl: videoUrl,
  coverUrl: 'https://cdn.example/c.jpg',
  audioUrl: audioUrl,
  imageUrls: images,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('存进去再读回来,字段一个不丢', () async {
    final store = HistoryStore();
    await store.add(
      _sample(
        audioUrl: 'https://cdn.example/a.mp3',
        images: ['https://cdn.example/1.jpg'],
      ),
      _link,
    );

    final entries = await store.load();
    expect(entries, hasLength(1));

    final result = entries.single.result;
    expect(result.title, '示例标题');
    expect(result.desc, '示例文案');
    expect(result.platform, '抖音');
    expect(result.authorName, '作者');
    expect(result.videoUrl, 'https://cdn.example/v.mp4');
    expect(result.audioUrl, 'https://cdn.example/a.mp3');
    expect(result.coverUrl, 'https://cdn.example/c.jpg');
    // 图集最容易在序列化时漏掉,单独盯一条
    expect(result.imageUrls, ['https://cdn.example/1.jpg']);
    expect(result.hasImages, isTrue);
    // 源链接也要活着 —— 历史卡单击后要靠它重新解析
    expect(entries.single.sourceUrl, _link);
  });

  test('加 sourceUrl 之前存的旧记录读成空串,不抛异常', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'history.entries':
          '[{"id":"1","parsedAt":1700000000000,'
          '"result":{"title":"老记录","desc":"","platform":"抖音"}}]',
    });

    final entries = await HistoryStore().load();
    expect(entries, hasLength(1));
    expect(entries.single.result.title, '老记录');
    expect(entries.single.sourceUrl, '');
  });

  test('同一条链接重复解析,只留最新的一条', () async {
    final store = HistoryStore();
    await store.add(_sample(title: '旧标题'), _link);
    await store.add(_sample(title: '新标题'), _link);

    final entries = await store.load();
    expect(entries, hasLength(1));
    expect(entries.single.result.title, '新标题');
  });

  test('重复解析后,那条记录排到最前', () async {
    final store = HistoryStore();
    await store.add(_sample(title: 'A'), 'https://v.douyin.com/aaa/');
    await store.add(_sample(title: 'B'), 'https://v.douyin.com/bbb/');
    await store.add(_sample(title: 'A 又解析了一次'), 'https://v.douyin.com/aaa/');

    final entries = await store.load();
    expect(entries.map((e) => e.result.title), ['A 又解析了一次', 'B']);
  });

  test('不同链接各留一条', () async {
    final store = HistoryStore();
    await store.add(_sample(title: '第一条'), 'https://v.douyin.com/aaa/');
    await store.add(_sample(title: '第二条'), 'https://v.douyin.com/bbb/');

    expect(await store.load(), hasLength(2));
  });

  test('新的排在前面', () async {
    final store = HistoryStore();
    await store.add(_sample(title: '第一条'), 'https://v.douyin.com/1/');
    await store.add(_sample(title: '第二条'), 'https://v.douyin.com/2/');

    final entries = await store.load();
    expect(entries.map((e) => e.result.title), ['第二条', '第一条']);
  });

  test('同一毫秒内连着加两条,id 不撞,删一条只掉一条', () async {
    // Windows 上 DateTime.now() 分辨率是毫秒级,只靠时间戳会撞 id。
    final store = HistoryStore();
    await store.add(_sample(title: '留着'), 'https://v.douyin.com/1/');
    await store.add(_sample(title: '删掉'), 'https://v.douyin.com/2/');

    final before = await store.load();
    expect(before.map((e) => e.id).toSet(), hasLength(2));

    final target = before.firstWhere((e) => e.result.title == '删掉');
    await store.remove({target.id});

    final after = await store.load();
    expect(after.map((e) => e.result.title), ['留着']);
  });

  test('超过上限丢最旧的', () async {
    final store = HistoryStore();
    final total = HistoryStore.maxEntries + 5;
    for (var i = 0; i < total; i++) {
      await store.add(_sample(title: '第 $i 条'), 'https://v.douyin.com/$i/');
    }

    final entries = await store.load();
    expect(entries, hasLength(HistoryStore.maxEntries));
    expect(entries.first.result.title, '第 ${total - 1} 条');
    expect(entries.last.result.title, '第 5 条');
  });

  test('存的内容坏了不抛异常,退化成空历史', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'history.entries': '这不是 JSON',
    });
    expect(await HistoryStore().load(), isEmpty);
  });

  test('清空', () async {
    final store = HistoryStore();
    await store.add(_sample(), _link);
    await store.clear();
    expect(await store.load(), isEmpty);
  });
}
