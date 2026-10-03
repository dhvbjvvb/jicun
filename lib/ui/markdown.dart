/// release 说明的 markdown:解析成「一行一行 + 行内样式片段」。
///
/// **为什么单独一个文件**:这三百来行是纯字符串解析(不碰网络、不碰插件),但它的
/// 错误后果和"取 release"完全不是一类 —— 取不到是"没有新版",这里错了是"更新说明
/// 排版乱掉、表格串行"。分出来之后 update_service.dart 只剩"问接口、下包、装包",
/// 这一层可以单独测(见 test/update_service_test.dart 里那组 markdown 用例)。
///
/// 对外仍从 `package:jicun/update_service.dart` 取(那边 `export` 了这一份),
/// 所以现有调用点一行都不用改。
library;

import 'dart:convert';

// ───────────────────────── release 说明的 markdown ─────────────────────────

/// 预览窗口里一行字的档次。只分三档:标题、正文、代码。
enum MdLineKind { heading, body, code }

/// 整行的水平对齐。来自 HTML 容器(div / p 的 align 属性、center 标签)。
enum MdAlign { left, center, right }

/// 行内一段样式相同的文字。
///
/// 只留「这段字长什么样」,不留原始标记:渲染那边照这几个开关拼 TextStyle,
/// 不用再认一遍 markdown。
class MdRun {
  const MdRun(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.code = false,
    this.strike = false,
    this.link = false,
    this.underline = false,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool code;
  final bool strike;
  final bool link;
  final bool underline;

  MdRun copyWith({
    bool? bold,
    bool? italic,
    bool? code,
    bool? strike,
    bool? link,
    bool? underline,
  }) => MdRun(
    text,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    code: code ?? this.code,
    strike: strike ?? this.strike,
    link: link ?? this.link,
    underline: underline ?? this.underline,
  );
}

/// 解析完的一行:[runs] 是内容(带行内样式),[prefix] 是列表符号那种前缀
/// (没有就是空),[indent] 是列表缩进层级,[align] 是整行的对齐。
class MdLine {
  const MdLine(
    this.runs,
    this.kind, {
    this.prefix = '',
    this.indent = 0,
    this.align = MdAlign.left,
  });

  final List<MdRun> runs;
  final MdLineKind kind;
  final String prefix;
  final int indent;
  final MdAlign align;

  /// 纯文本(标记已经清掉)。量高度、判空、老用例都靠它。
  String get text => runs.map((run) => run.text).join();

  bool get isEmpty => text.isEmpty && prefix.isEmpty;
}

/// 行内 markdown / HTML → 若干段同样式的文字。
///
/// 认:粗体(**/__/b/strong)、斜体(*/_/i/em)、删除线(~~/del)、行内代码
/// (反引号/code/kbd)、链接([文字](url)/a,只上样式不跳转)、图片(只留 alt)、
/// 下划线(u)、换行(br)、反斜杠转义。
///
/// 不引完整的 markdown 引擎:release 说明这点体量不值一个包,而预览窗口是每帧
/// 重排版的滚动区,包进来的开销是实打实的。
List<MdRun> mdRuns(String raw, {bool code = false}) {
  final out = <MdRun>[];
  _scanInline(_unescapeEntities(raw), out, _MdStyle(code: code));
  return out;
}

/// 扫描时那一套「当前样式」。[_scanInline] 靠它记住进出标签的开关。
class _MdStyle {
  const _MdStyle({
    this.bold = false,
    this.italic = false,
    this.code = false,
    this.strike = false,
    this.link = false,
    this.underline = false,
  });

  final bool bold;
  final bool italic;
  final bool code;
  final bool strike;
  final bool link;
  final bool underline;

  _MdStyle copyWith({
    bool? bold,
    bool? italic,
    bool? code,
    bool? strike,
    bool? link,
    bool? underline,
  }) => _MdStyle(
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    code: code ?? this.code,
    strike: strike ?? this.strike,
    link: link ?? this.link,
    underline: underline ?? this.underline,
  );
}

/// 块级 HTML 容器:只认对齐这件事,标签本身不显示。
final RegExp _blockOpen = RegExp(
  '^<(div|p|center)(?=[ >/])([^>]*)>',
  caseSensitive: false,
);
final RegExp _blockClose = RegExp('</(div|p|center) *>', caseSensitive: false);

/// align 属性。值外面那对引号交给 .? 吃,省得在字符串里跟引号较劲。
final RegExp _alignAttr = RegExp(
  'align *= *.? *(left|center|right)',
  caseSensitive: false,
);

/// 反斜杠能转义的字符。
const String _escapable = r'\`*_{}[]()#+-.!~<>&';

/// HTML 实体里最常见的那几个。&amp; 放最后,免得把 &amp;lt; 解成 <。
String _unescapeEntities(String raw) => raw
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&');

/// 行内扫描。一个可变的样式状态 + 成对的开关标签,不建 AST —— 这点体量不值。
void _scanInline(String s, List<MdRun> out, _MdStyle style) {
  final buf = StringBuffer();
  var cur = style;

  void flush() {
    if (buf.isEmpty) return;
    out.add(
      MdRun(
        buf.toString(),
        bold: cur.bold,
        italic: cur.italic,
        code: cur.code,
        strike: cur.strike,
        link: cur.link,
        underline: cur.underline,
      ),
    );
    buf.clear();
  }

  var i = 0;
  while (i < s.length) {
    final c = s[i];
    // 反斜杠转义:星号就是星号,不当标记
    if (c == '\\' && i + 1 < s.length && _escapable.contains(s[i + 1])) {
      buf.write(s[i + 1]);
      i += 2;
      continue;
    }
    // 行内代码:里面的标记一律不解析
    if (c == '`') {
      final end = s.indexOf('`', i + 1);
      if (end > i) {
        flush();
        _scanInline(s.substring(i + 1, end), out, cur.copyWith(code: true));
        i = end + 1;
        continue;
      }
    }
    if (s.startsWith('**', i) || s.startsWith('__', i)) {
      flush();
      cur = cur.copyWith(bold: !cur.bold);
      i += 2;
      continue;
    }
    if (s.startsWith('~~', i)) {
      flush();
      cur = cur.copyWith(strike: !cur.strike);
      i += 2;
      continue;
    }
    // 图片在预览窗口里没有落脚点:只留 alt
    if (c == '!' && i + 1 < s.length && s[i + 1] == '[') {
      final image = _bracket(s, i + 1);
      if (image != null) {
        // 先冲掉缓冲区,不然 alt 会插到前一段文字前面去
        flush();
        _scanInline(image.label, out, cur);
        i = image.end;
        continue;
      }
    }
    if (c == '[') {
      final link = _bracket(s, i);
      if (link != null) {
        flush();
        _scanInline(link.label, out, cur.copyWith(link: true, underline: true));
        i = link.end;
        continue;
      }
    }
    if (c == '<') {
      final tag = _readTag(s, i);
      if (tag != null) {
        flush();
        i = tag.end;
        switch (tag.name) {
          case 'br':
            buf.write('\n');
          case 'b' || 'strong':
            cur = cur.copyWith(bold: !cur.bold);
          case 'i' || 'em':
            cur = cur.copyWith(italic: !cur.italic);
          case 'del' || 's' || 'strike':
            cur = cur.copyWith(strike: !cur.strike);
          case 'code' || 'tt' || 'kbd':
            cur = cur.copyWith(code: !cur.code);
          case 'u':
            cur = cur.copyWith(underline: !cur.underline);
          case 'a':
            cur = cur.copyWith(link: !cur.link, underline: !cur.underline);
          default:
            break;
        }
        continue;
      }
      // 认不出来就当普通的小于号(比如 3 < 5)
    }
    if (c == '*') {
      flush();
      cur = cur.copyWith(italic: !cur.italic);
      i += 1;
      continue;
    }
    // 词中的下划线不算斜体,不然 snake_case 会被拆成两段
    if (c == '_') {
      final inWord =
          i > 0 && i + 1 < s.length && _isWord(s[i - 1]) && _isWord(s[i + 1]);
      if (!inWord) {
        flush();
        cur = cur.copyWith(italic: !cur.italic);
        i += 1;
        continue;
      }
    }
    buf.write(c);
    i += 1;
  }
  flush();
}

/// [文字](url) / [文字]:返回标签文字和这一段的结束位置。
({String label, int end})? _bracket(String s, int start) {
  final close = s.indexOf(']', start + 1);
  if (close < 0) return null;
  var end = close + 1;
  if (end < s.length && s[end] == '(') {
    final paren = s.indexOf(')', end + 1);
    if (paren > 0) end = paren + 1;
  }
  return (label: s.substring(start + 1, close), end: end);
}

/// 读一个 HTML 标签。不是标签就返回 null。
({String name, int end})? _readTag(String s, int start) {
  final close = s.indexOf('>', start + 1);
  if (close < 0) return null;
  var body = s.substring(start + 1, close).trim();
  if (body.startsWith('/')) body = body.substring(1);
  var name = body;
  for (final stop in const [' ', '/']) {
    final at = name.indexOf(stop);
    if (at >= 0) name = name.substring(0, at);
  }
  if (name.isEmpty) return null;
  for (final unit in name.codeUnits) {
    final ok =
        (unit >= 65 && unit <= 90) ||
        (unit >= 97 && unit <= 122) ||
        (unit >= 48 && unit <= 57);
    if (!ok) return null;
  }
  return (name: name.toLowerCase(), end: close + 1);
}

bool _isWord(String c) {
  final code = c.codeUnitAt(0);
  return (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122);
}

/// 分割线:同一个字符(中间可以夹空格)至少三个。
bool _isRule(String text) {
  final compact = text.replaceAll(' ', '');
  if (compact.length < 3) return false;
  final ch = compact[0];
  if (ch != '-' && ch != '*' && ch != '_') return false;
  return compact.codeUnits.every((unit) => unit == ch.codeUnitAt(0));
}

/// 表格的分隔行,例如 | --- | :--: |。
bool _isTableSeparator(String text) =>
    text.contains('-') && RegExp(r'^[| :_-]+$').hasMatch(text);

/// 表格行 → 一格格的文字,中间用竖线隔开。表头那行整体加粗。
List<MdRun> _tableRuns(String row, {required bool header}) {
  var text = row.trim();
  if (text.startsWith('|')) text = text.substring(1);
  if (text.endsWith('|')) text = text.substring(0, text.length - 1);
  final runs = <MdRun>[];
  final cells = text.split('|');
  for (var i = 0; i < cells.length; i++) {
    if (i > 0) runs.add(const MdRun(' │ '));
    final cell = mdRuns(cells[i].trim());
    runs.addAll(header ? cell.map((run) => run.copyWith(bold: true)) : cell);
  }
  return runs;
}

/// release 说明(markdown + 常见 HTML)→ 逐行。
///
/// 块级认:标题(#)、无序列表(- * +)、有序列表(1.)、任务列表(- [x])、引用(>)、
/// 表格(| a | b |)、代码块(三个反引号围起来)、分割线(丢掉)、空行(保留,
/// 当段落间距);HTML 的 div / p / center 只取它的 align。
List<MdLine> parseMarkdown(String source) {
  final lines = <MdLine>[];
  final rows = const LineSplitter().convert(source);
  var inCode = false;
  var align = MdAlign.left;
  var alignDepth = 0;

  for (var index = 0; index < rows.length; index++) {
    final trimmed = rows[index].trimRight();
    if (trimmed.trimLeft().startsWith('```')) {
      inCode = !inCode;
      continue;
    }
    if (inCode) {
      lines.add(MdLine(<MdRun>[MdRun(trimmed)], MdLineKind.code, align: align));
      continue;
    }

    final lead = trimmed.length - trimmed.trimLeft().length;
    final indent = (lead ~/ 2).clamp(0, 3);
    var text = trimmed.trimLeft();
    var sawTag = false;

    // 开闭标签都可以和内容同行,所以反复剥到这一行不再以开标签开头、
    // 也不含闭标签为止。容器只用来管对齐。
    while (true) {
      final open = _blockOpen.firstMatch(text);
      if (open == null || open.start != 0) break;
      final name = open.group(1)!.toLowerCase();
      final attr = _alignAttr.firstMatch(open.group(2) ?? '')?.group(1);
      final parsed = name == 'center'
          ? MdAlign.center
          : switch ((attr ?? '').toLowerCase()) {
              'center' => MdAlign.center,
              'right' => MdAlign.right,
              'left' => MdAlign.left,
              _ => null,
            };
      if (parsed != null) align = parsed;
      alignDepth++;
      text = text.substring(open.end);
      sawTag = true;
    }
    // 这一行内容用的对齐:开标签已经生效,闭标签只管它后面的行 —— 不然
    // 「<div align=center>标题</div>」这种一行写完的会先居中再被还原成左对齐。
    final lineAlign = align;
    while (true) {
      final close = _blockClose.firstMatch(text);
      if (close == null) break;
      text = text.replaceRange(close.start, close.end, '');
      sawTag = true;
      if (alignDepth > 0) alignDepth--;
      if (alignDepth == 0) align = MdAlign.left;
    }
    // 只剩标签的行不产生空行
    if (text.trim().isEmpty) {
      if (sawTag) continue;
      lines.add(MdLine(const <MdRun>[], MdLineKind.body, align: lineAlign));
      continue;
    }
    if (_isRule(text)) continue;

    final heading = RegExp(r'^(#{1,6}) +(.*)$').firstMatch(text);
    if (heading != null) {
      lines.add(
        MdLine(
          mdRuns(heading.group(2)!),
          MdLineKind.heading,
          indent: indent,
          align: lineAlign,
        ),
      );
      continue;
    }

    final quote = RegExp(r'^> ?(.*)$').firstMatch(text);
    if (quote != null) {
      lines.add(
        MdLine(
          mdRuns(quote.group(1)!),
          MdLineKind.body,
          prefix: '│ ',
          indent: indent,
          align: lineAlign,
        ),
      );
      continue;
    }

    // 表格:分隔行本身不显示;紧跟着分隔行的那一行是表头,整行加粗。
    if (text.startsWith('|')) {
      if (_isTableSeparator(text)) continue;
      final header =
          index + 1 < rows.length && _isTableSeparator(rows[index + 1].trim());
      lines.add(
        MdLine(
          _tableRuns(text, header: header),
          MdLineKind.body,
          indent: indent,
          align: lineAlign,
        ),
      );
      continue;
    }

    final bullet = RegExp(r'^[-*+] +(.*)$').firstMatch(text);
    if (bullet != null) {
      var body = bullet.group(1)!;
      var prefix = '• ';
      if (body.startsWith('[ ]')) {
        prefix = '[ ] ';
        body = body.substring(3);
      } else if (body.length > 3 &&
          (body.startsWith('[x]') || body.startsWith('[X]'))) {
        prefix = '[x] ';
        body = body.substring(3);
      }
      lines.add(
        MdLine(
          mdRuns(body.trimLeft()),
          MdLineKind.body,
          prefix: prefix,
          indent: indent,
          align: lineAlign,
        ),
      );
      continue;
    }

    final ordered = RegExp(r'^([0-9]{1,3})[.)] +(.*)$').firstMatch(text);
    if (ordered != null) {
      lines.add(
        MdLine(
          mdRuns(ordered.group(2)!),
          MdLineKind.body,
          prefix: '${ordered.group(1)}. ',
          indent: indent,
          align: lineAlign,
        ),
      );
      continue;
    }

    lines.add(
      MdLine(mdRuns(text), MdLineKind.body, indent: indent, align: lineAlign),
    );
  }

  // 头尾的空行去掉,免得预览窗口顶上先空一行
  while (lines.isNotEmpty && lines.first.text.isEmpty) {
    lines.removeAt(0);
  }
  while (lines.isNotEmpty && lines.last.text.isEmpty) {
    lines.removeLast();
  }
  return lines;
}
