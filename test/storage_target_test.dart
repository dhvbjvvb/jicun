import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jicun/downloader.dart';

/// 自定义存储目录要真的传到原生 publish 那一步 —— 只存在偏好里、没传给原生,
/// 下载照样落回默认媒体库。反过来,没自定义就不能带 treeUri。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('jicun/downloader');

  List<MethodCall> capture() {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'publish' ? 'content://doc/1' : null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    return calls;
  }

  final item = DownloadItem(
    url: 'https://example.invalid/a.mp4',
    fileName: 'a.mp4',
    kind: MediaKind.video,
  );

  tearDown(Downloader.customStorage.clear);

  test('没自定义:publish 不带 treeUri(照旧走媒体库)', () async {
    final calls = capture();
    final uri = await Downloader.publishImpl(item, File('a.mp4'));
    expect(uri, 'content://doc/1');
    expect(calls.single.arguments['treeUri'], isNull);
  });

  test('自定义了:treeUri 原样传给 publish', () async {
    Downloader.customStorage[MediaKind.video] = const StorageTarget(
      treeUri: 'content://com.android.externalstorage.documents/tree/primary%3AMovies%2F我的视频',
      label: '内部存储/Movies/我的视频',
    );
    final calls = capture();
    await Downloader.publishImpl(item, File('a.mp4'));
    expect(
      calls.single.arguments['treeUri'],
      'content://com.android.externalstorage.documents/tree/primary%3AMovies%2F我的视频',
    );
  });
}
