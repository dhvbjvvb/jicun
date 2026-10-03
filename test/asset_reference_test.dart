import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 资源**对不上**的就地体检。
///
/// 这一类错分析器一句都不会说:写错一个目录名,运行期只会得到一个空白盒子
/// (`Image.asset` 找不到资源不抛异常、只画个空 `SizedBox`)。这套图标浅深各一份、
/// 目录名还混着中文和全角括号,是"手滑改错一个字符"最容易漏出去的地方 ——
/// 所以拿真实目录对着查一遍。
///
/// 和第 0 周的素材改造配套:那一次把顶栏图/彩蛋提示图/启动图从 PNG 换成了 WebP,
/// 这个用例就是换完之后的兜底(以后换格式、改目录,红了就是真有引用没跟上)。
void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();

  /// 去掉注释之后的 Dart 源码。
  ///
  /// **必须去注释**:`lib/ui/popup.dart` 里明明白白写着一句
  /// "写成 settingsIcon 会去取 深色主题(设置板块选项图标)/下载媒体.svg" —— 那是
  /// 一条反面教材,不是引用。不去注释的话这条用例会一直红在一个不存在的问题上。
  String stripComments(String source) {
    final out = StringBuffer();
    String? quote;
    var block = false;
    for (var i = 0; i < source.length; i++) {
      final c = source[i];
      final next = i + 1 < source.length ? source[i + 1] : '';
      if (block) {
        if (c == '*' && next == '/') {
          block = false;
          i++;
        }
        continue;
      }
      if (quote != null) {
        out.write(c);
        if (c == '\\') {
          if (next.isNotEmpty) out.write(next);
          i++;
        } else if (c == quote) {
          quote = null;
        }
        continue;
      }
      if (c == '/' && next == '/') {
        while (i < source.length && source[i] != '\n') {
          i++;
        }
        out.write('\n');
        continue;
      }
      if (c == '/' && next == '*') {
        block = true;
        i++;
        continue;
      }
      if (c == "'" || c == '"') quote = c;
      out.write(c);
    }
    return out.toString();
  }

  /// lib/ 里所有 Dart 源码(去过注释)。**只算一次** —— 这个用例要扫两遍,
  /// 而每个测试文件在 flutter test 里都是并行跑的,晚一点抢 CPU 都可能让
  /// widget_test 那种带真延时等待的用例踩线。
  String? cachedLib;
  String libSource() => cachedLib ??= Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .map((f) => stripComments(f.readAsStringSync()))
      .join('\n');

  /// 代码里出现的资源文件路径(已去注释)。
  Set<String> referencedAssets() {
    final out = <String>{};
    final pattern = RegExp(
      r"[A-Za-z\u4e00-\u9fff\u3000-\u303f\uff00-\uffef0-9_\-\u2014()\u3001/]*\.(?:png|webp|svg|mp3|jpg|jpeg)",
    );
    for (final match in pattern.allMatches(libSource())) {
      final token = match.group(0)!;
      if (token.startsWith('assets/') ||
          token.startsWith('未选中') ||
          token.startsWith('选中') ||
          token.startsWith('浅色') ||
          token.startsWith('深色') ||
          token.startsWith('下载二次弹窗')) {
        out.add(token);
      }
    }
    return out;
  }

  test('pubspec 声明的整目录资源都在', () {
    // `- assets/xxx/` 这种整目录声明:目录不在,构建期只报一行 "unable to find",
    // 那时候已经晚了。
    final declared = RegExp(r'^\s+-\s+(\S[^\s:]*/)\s*$', multiLine: true)
        .allMatches(pubspec)
        .map((m) => m.group(1)!)
        .toList();
    expect(declared, isNotEmpty, reason: '没从 pubspec 里读出资源目录,正则失效了');
    for (final dir in declared) {
      expect(Directory(dir).existsSync(), isTrue,
          reason: 'pubspec 声明了 $dir,磁盘上却没有这个目录');
    }
  });

  test('代码里出现的每个资源路径都真实存在', () {
    final paths = referencedAssets();
    expect(paths, isNotEmpty, reason: '一个资源路径都没扫出来,正则大概写错了');
    for (final path in paths) {
      expect(File(path).existsSync(), isTrue,
          reason: '代码引用了 $path,磁盘上却没有 —— 界面上只会留个空盒子');
    }
  });

  test('图标目录浅深两套齐全,每一张都被代码引用', () {
    // boardIcon / popupIcon / settingsIcon 拼的是"目录 + 文件名",整条路径在源码里
    // 不是字面量,所以这里按目录查:两份目录的文件名必须一一对应,而且每个文件名
    // 都能在 lib/ 里找到引用。
    const pairs = <String, String>{
      '未选中24x24-SVG': '选中24x24-SVG',
      '浅色主题（设置板块选项图标）': '深色主题（设置板块选项图标）',
      '浅色模式首页板块22x22-SVG': '深色模式首页板块22x22-SVG',
      '浅色模式历史板块': '深色模式历史板块',
      '下载二次弹窗浅色模式': '下载二次弹窗深色模式',
    };

    pairs.forEach((light, dark) {
      Set<String> namesOf(String dir) => Directory(dir)
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .toSet();

      final lightFiles = namesOf(light);
      expect(lightFiles, isNotEmpty, reason: '$light 是空的');
      expect(namesOf(dark), lightFiles,
          reason: '$dark 和 $light 的文件名对不上 —— 少一张,换主题就是一个空盒子');
      for (final name in lightFiles) {
        // 两种引用方式都算:
        //   - 首页/历史/弹窗/底栏那几套:调用点直接写字面量 '全选.svg';
        //   - 设置那套:写的是标题 '主题与外观',后缀由 SettingsOptionCard 的
        //     settingsIcon(context, '$title.svg') 拼上去。
        // 所以整名和去后缀的词干有一个命中就算引用了。
        final stem = name.contains('.')
            ? name.substring(0, name.lastIndexOf('.'))
            : name;
        expect(libSource().contains(name) || libSource().contains(stem), isTrue,
            reason: '$light/$name 没有任何代码引用(改名或删图之后忘了改调用点?)');
      }
    });
  });
}
