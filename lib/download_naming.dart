part of 'downloader.dart';

// 文件叫什么、后缀怎么定:扩展名嗅探(认字节也认 Content-Type)、标题清洗、文件名
// 长度控制。
//
// 归到这里的东西都**不碰网络也不碰平台通道** —— 输入是字节和字符串,输出是名字。

/// 原生给的 MIME(`video/mp4; charset=…`)→ 后缀(`.mp4`)。
///
/// 直接读 [_kMimeExt] 那张表,不走 `extensionForContentType` —— 后者要传一个
/// 媒体类型,而这里正是不确定类型的时候(图集里混着视频)。
///
/// **带点返回**:[_retag] 是拿 `stem + ext` 直接拼名字的(和
/// `extensionForContentType` 那条路同一个用法),这里少一个点就会存出
/// `标题mp4` 这种没有扩展名的文件。
String _extFromContentType(String? contentType) {
  if (contentType == null) return '';
  final mime = contentType.split(';').first.trim().toLowerCase();
  return _kMimeExt[mime] ?? '';
}

/// 文件名去掉后缀。`_retag` 拿它当"标题 + 批次序号"那一段,收尾时再按真实内容
/// 补后缀 —— 带着原后缀走会拼成 `X.mp4.mp4`。
String _stemOf(String fileName) {
  final dot = fileName.lastIndexOf('.');
  // dot <= 0 保护的是 `.hidden` 这种(整个名字就是后缀)和没有后缀的名字。
  return dot <= 0 ? fileName : fileName.substring(0, dot);
}

/// 按真实内容给这条媒体定名字,并把临时文件改成同名,返回改名后的文件。
///
/// **为什么必须换**:`item.fileName` 的扩展名是解析期按 URL 猜的(见
/// lib/pages/preview.dart 的 `imageExt`),而头条所有图片直链都过 CDN 变换,路径以
/// `~tplv-tt-large.image`
/// 结尾,没有 `.gif` / `.jpg` 可猜 —— 猜不到就落到兜底值。动图因此被命名成静态图
/// 的后缀,部分看图软件不再播放动画,看起来就像"GIF 变 PNG 了"(实测:同一张
/// 4.23MB 的 GIF89a,只是名字错了)。文件内容一直是原样的,这里只改名字,不重新
/// 编码 —— 一旦解码再编码,动图必然被压成第一帧。
///
/// 改的是 **`item.fileName` 本身**:`publish` 拿它当 MediaStore 的
/// `DISPLAY_NAME`,只改临时文件的话相册里还是错后缀(实测就是这么漏过去的)。
///
/// 名字里那段 `.part` 也在这里掉:临时目录里它防的是"下了一半的文件被当成成品",
/// 收完这一步就不需要了。
///
/// [probeExt] 是下载前那一发探针响应里的 Content-Type,拿不到就是空串。
///
/// [stem] 是这条最终名字里"标题 + 批次序号"那一段,由调用方给 —— 不是从
/// `item.fileName` 里拆的:下载用的临时名和相册要用的名字现在是两回事(见
/// [_tempPath]),拆临时名会拆出临时名的前缀。
File _retag(File file, DownloadItem item, String stem, String probeExt) {
  final sniffed = _sniffExt(file);
  // 后缀三选一:
  //   1. 嗅探结果和这条声明的类型对得上 → 用嗅探值(视频的 `.mp4`、图的 `.webp`…);
  //   2. **声明是音频、容器又是 MP4 家族** → 按 `.m4a` 记。这一条不能少:纯音频的
  //      m4a(B 站 DASH 那条音频流、/api/audio 抽出来的那份)与视频共用同一个 `ftyp`
  //      盒子,嗅探只能给出 `.mp4` —— 那是"视频"的后缀。照它登记的话,一份音频会顶着
  //      `video/mp4` 进 `Music/`,媒体库要么拒收要么归档错。
  //   3. 其余对不上的用 Content-Type 那条:字节和用途不是一回事,不硬按内容改名。
  final String ext;
  if (sniffed == null) {
    ext = probeExt;
  } else if (_kindOfExt(sniffed) == item.kind) {
    ext = sniffed;
  } else if (item.kind == MediaKind.audio && _kIsoBmffExts.contains(sniffed)) {
    ext = '.m4a';
  } else {
    ext = probeExt;
  }
  // 后缀这一下可能比解析期猜的长(`.jpg` → `.webm`),总长由这里收口 ——
  // 解析期扣的是候选后缀里最长的那个,正常不会走到截断。
  final finalStem = _fitStem(stem, ext, _kMaxNameBytes);
  // 临时文件先腾地方:同一条被重新下过就可能占着这个名字
  final scratch = File('${file.parent.path}/${item.fileName}');
  if (scratch.existsSync()) scratch.deleteSync();
  if (ext.isEmpty) {
    // 认不出格式:名字照抄,只摘掉 `.part` 这个临时标记(一个字节的格式信息都给不出,
    // 解析期猜的后缀也就不必留了)。
    final plain = File('${file.parent.path}/$finalStem');
    if (plain.existsSync()) plain.deleteSync();
    return file.renameSync(plain.path);
  }
  final renamed = File('${file.parent.path}/$finalStem$ext');
  if (renamed.existsSync()) renamed.deleteSync();
  final moved = file.renameSync(renamed.path);
  item.fileName = '$finalStem$ext';
  return moved;
}

/// 读文件头几个字节认格式,认不出返回 null。
///
/// 中段文件里 `_retag` 拿到的就是文件开头,所以这里读出来的就是真格式。
String? _sniffExt(File file) {
  RandomAccessFile? handle;
  try {
    handle = file.openSync();
    final head = handle.readSync(16);
    return extensionForBytes(head);
  } catch (_) {
    // 文件不在了/读不动:交给上层按 Content-Type 或原名字处理,不在这里炸
    return null;
  } finally {
    handle?.closeSync();
  }
}

/// 文件头 → 扩展名。认不出返回空串。
@visibleForTesting
String extensionForBytes(List<int> head) {
  final b = head;
  bool at(int i, List<int> magic) {
    if (b.length < i + magic.length) return false;
    for (var k = 0; k < magic.length; k++) {
      if (b[i + k] != magic[k]) return false;
    }
    return true;
  }

  if (at(0, const <int>[0x47, 0x49, 0x46, 0x38])) return '.gif';
  if (at(0, const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return '.png';
  }
  if (at(0, const <int>[0xFF, 0xD8, 0xFF])) return '.jpg';
  if (at(0, const <int>[0x42, 0x4D])) return '.bmp';
  if (at(0, const <int>[0x1A, 0x45, 0xDF, 0xA3])) return '.webm';
  if (at(0, const <int>[0x66, 0x4C, 0x61, 0x43])) return '.flac';
  if (at(0, const <int>[0x4F, 0x67, 0x67, 0x53])) return '.ogg';
  if (at(0, const <int>[0x52, 0x49, 0x46, 0x46]) &&
      at(8, const <int>[0x57, 0x41, 0x56, 0x45])) {
    return '.wav';
  }
  if (at(0, const <int>[0x49, 0x44, 0x33]) ||
      at(0, const <int>[0xFF, 0xFB]) ||
      at(0, const <int>[0xFF, 0xF3])) {
    return '.mp3';
  }
  // RIFF 里还有 WEBP / AVI,两个都要看 offset 8 的 FOURCC
  if (at(0, const <int>[0x52, 0x49, 0x46, 0x46])) {
    if (at(8, const <int>[0x57, 0x45, 0x42, 0x50])) return '.webp';
    if (at(8, const <int>[0x41, 0x56, 0x49, 0x20])) return '.avi';
  }
  // HEIF/AVIF/MP4/MOV/M4A 共用一个盒子:offset 4 是 'ftyp',8 起是 brand
  if (at(4, const <int>[0x66, 0x74, 0x79, 0x70])) {
    final brand = String.fromCharCodes(
      b.sublist(8, b.length < 12 ? b.length : 12),
    );
    if (brand.startsWith('avif') || brand.startsWith('avis')) return '.avif';
    if (brand.startsWith('heic') ||
        brand.startsWith('heix') ||
        brand.startsWith('mif1')) {
      return '.heic';
    }
    if (brand.startsWith('qt')) return '.mov';
    if (brand.startsWith('M4A')) return '.m4a';
    // brand 认不出(CDN 常见):长度够了照样按 MP4 记 —— 猜错了也是所有播放器
    // 都吃的容器,比留着 .part 强
    return b.length >= 16 ? '.mp4' : '';
  }
  return '';
}

/// 认得出的扩展名 → 它是哪一种媒体。表只用来**校验**猜出来的后缀和这条的类型对不对
/// 得上,所以没法全(不在表里的就当"未知",不阻断改名)。
const Map<String, MediaKind> _extKind = <String, MediaKind>{
  'jpg': MediaKind.image,
  'jpeg': MediaKind.image,
  'png': MediaKind.image,
  'gif': MediaKind.image,
  'webp': MediaKind.image,
  'avif': MediaKind.image,
  'heic': MediaKind.image,
  'heif': MediaKind.image,
  'bmp': MediaKind.image,
  'tif': MediaKind.image,
  'tiff': MediaKind.image,
  'mp4': MediaKind.video,
  'm4v': MediaKind.video,
  'mov': MediaKind.video,
  'webm': MediaKind.video,
  'mkv': MediaKind.video,
  'avi': MediaKind.video,
  'flv': MediaKind.video,
  'ts': MediaKind.video,
  'mp3': MediaKind.audio,
  'm4a': MediaKind.audio,
  'aac': MediaKind.audio,
  'wav': MediaKind.audio,
  'flac': MediaKind.audio,
  'ogg': MediaKind.audio,
  'oga': MediaKind.audio,
  'opus': MediaKind.audio,
};

/// ISO-BMFF(MP4 家族)容器的后缀。
///
/// 音频和视频共用这一套盒子,光看文件头分不出谁是谁 —— 纯音频的 m4a 一样以 `ftyp`
/// 开头(实测 B 站那条纯音频流和抽轨出来的 m4a 都是 `ftypiso5`)。所以判类型不能只看
/// 后缀,得结合这条声明的媒体类型(见 [_retag])。
const Set<String> _kIsoBmffExts = <String>{'.mp4', '.m4v', '.mov'};

/// 扩展名属于哪一种媒体,表里没有返回 null(当"未知")。
MediaKind? _kindOfExt(String ext) =>
    _extKind[ext.startsWith('.') ? ext.substring(1) : ext];

/// Content-Type → 扩展名,认不出(包括 `application/octet-stream` 这种没信息的)返回空串。
///
/// 头条动图那条链路的响应头就是 `image/gif`,而 URL 后缀是 `~tplv-tt-large.image`,
/// 这是唯一能拿到正确后缀的地方 —— 所以下载器要拿响应头定名字,不能只信 URL。
@visibleForTesting
String extensionForContentType(String? contentType, MediaKind kind) {
  final mime = (contentType ?? '').split(';').first.trim().toLowerCase();
  final ext = _kMimeExt[mime];
  // 类型对不上就不用:标着 video 却回 image/gif 的地址,按音频/视频登记进媒体库会
  // 被系统拒收(见 MainActivity 的 mimeTypeOf),不如让原名字兜底。
  return ext != null && _kindOfExt(ext) == kind ? ext : '';
}

/// Content-Type → 扩展名(带点)。只认这几个,认不出返回 null。
///
/// 抽成顶层常量是因为有两处要用:上面按媒体类型校验的那条路,以及原生下载回来
/// 定后缀那条路(见 [_extFromContentType])—— 后者拿到的 MIME 不一定
/// 对应已知类型,所以直接查表、不做类型校验。
const Map<String, String> _kMimeExt = <String, String>{
  'image/gif': '.gif',
  'image/jpeg': '.jpg',
  'image/jpg': '.jpg',
  'image/pjpeg': '.jpg',
  'image/png': '.png',
  'image/webp': '.webp',
  'image/avif': '.avif',
  'image/heic': '.heic',
  'image/heif': '.heic',
  'image/bmp': '.bmp',
  'image/tiff': '.tiff',
  'video/mp4': '.mp4',
  'video/quicktime': '.mov',
  'video/webm': '.webm',
  'video/x-matroska': '.mkv',
  'audio/mpeg': '.mp3',
  'audio/mp4': '.m4a',
  'audio/aac': '.aac',
  'audio/wav': '.wav',
  'audio/x-wav': '.wav',
  'audio/flac': '.flac',
  'audio/ogg': '.ogg',
};

/// 把标题末尾的媒体后缀剥掉。
///
/// 有的平台标题就是文件名 —— 抖音这条实测是
/// `【8KHDR素材】…挪威冬日高画.mp4`。下载时落盘名是"标题 + 按地址猜的后缀",
/// 不剥的话会拼成 `…高画mp4.mp4`(实测:文件名里那个重复的 mp4 就是这么来的)。
///
/// 只认自己认得的那些后缀(见 [_extKind] 加几个常见的),别的 `.` 一律不动 ——
/// 标题里带点号太常见了(`1.2 万人点赞`),乱剥会把标题截掉一段。
String stripMediaExtension(String title) {
  final dot = title.lastIndexOf('.');
  if (dot <= 0 || dot == title.length - 1) return title;
  final ext = title.substring(dot + 1).toLowerCase();
  if (ext.length > 5 || !_extKind.containsKey(ext)) return title;
  return title.substring(0, dot);
}

/// 剥掉话题标签。`#冬日 #旅行` → 空,`原神#蒙德` → `原神 蒙德`。
///
/// 话题标签是给平台搜索用的,落进文件名只是白占字节 —— 而字节正是文件名最紧的
/// 资源(见 [safeFileName] 的上限)。字符集取到 64 字节那种 CJK 扩展区,是因为
/// 标签里常混着生僻字和 emoji 变体。
final RegExp _kHashtag = RegExp(r'#[^\s#]{0,32}', unicode: true);

/// emoji 与它们的装饰字符(变体选择符、零宽连接符、肤色修饰符、区域指示符)。
/// 这些在文件名里既不可读又占 3~4 字节,统一清掉。
final RegExp _kEmoji = RegExp(
  '['
  '\u{1F000}-\u{1FAFF}'
  '\u{2600}-\u{27BF}'
  '\u{FE00}-\u{FE0F}'
  '\u{200B}-\u{200D}'
  '\u{20E3}'
  '\u{1F1E6}-\u{1F1FF}'
  ']',
  unicode: true,
);

/// 同一个标点连打三下以上收成一个(`!!!` → `!`)。只收同一字符的连打:
/// `!?` 这种交替是用户真打出来的语气,动了就是改标题。
final RegExp _kPunctRun = RegExp(r'([!！?？~～。，,、])\1{2,}');

/// 压缩标题,让它更短但仍然认得出来是谁。
///
/// 四件事,按这个顺序做:剥话题标签、清 emoji 与非可读控制字符、收标点连打、
/// 折叠空白。**不动文字本身** —— 中文一个字 3 字节,是最贵的那部分,但它正是
/// 用户在相册里认文件的依据,再长也留着(截断交给 [safeFileName])。
String shortenTitle(String title) {
  return title
      .replaceAll(_kHashtag, ' ')
      .replaceAll(_kEmoji, '')
      .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
      // Dart 的 replaceAll 不认 `$1` 这种反向引用(会原样打出来),得走 mapped。
      .replaceAllMapped(_kPunctRun, (m) => m.group(1)!)
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// 字符串按 UTF-8 算多少字节。文件名上限是字节数,不是字符数。
int _utf8Len(String value) => utf8.encode(value).length;

/// 把解析出来的标题变成能落盘的文件名。
///
/// 保留中文(用户要靠它认文件),只清掉文件系统不接受的字符和控制字符。
///
/// **按字节截断,不按字符** —— 这里踩过坑:DownloadManager 限的是字节数,
/// 中文一个字 3 字节,而一个 52 字的标题就是 126 字节。当时按字符截到 60,
/// 结果系统从尾部继续砍,正好把 `.mp4` 扩展名切掉,存出来是个没有扩展名的文件
/// (实测:vivo + Android 17 上 130 字节的路径被截到 81 字节,扩展名没了)。
///
/// 66 字节 ≈ 22 个汉字,离已知会被截断的 81 字节还有余量。
///
/// [ext] 和 [index] 是**这次要拼在后面的后缀和序号**:上限量的是整个文件名,而
/// 调用方是在这个返回值后面再拼 `.mp4` 和 `_2` 的。不先扣掉的话,66 的上限形同虚设
/// (66 字节的标题 + `.mp4` 就是 70,离 81 那个已知会被砍的点只剩 11 字节余量)。
/// [ext] 传的是**候选后缀里最长的那个**:真实后缀要等下载器嗅探文件头才知道,
/// 现在多扣几字节,好过下载完发现总长超了没得改。
///
/// [index] 大于 0 时这里会**把它拼在末尾**(`标题_2`)并把它的字节算进上限 ——
/// 序号是名字的一部分,截断必须把它一起算,但它是"第几张"而不是标题里的话,
/// 不该被截掉。
String safeFileName(
  String raw, {
  String ext = '',
  int index = 0,
  String fallback = '即存媒体',
  int maxBytes = 66,
}) {
  final rawCleaned = raw
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .trim();
  // 先剥话题标签、清 emoji,再清非法字符 —— 顺序反了的话 `#` 已被换成 `_`,
  // 标签就剥不掉了。
  //
  // 只有压出来还有点东西才用:整个标题都是 emoji 时会被清成空串,那种情况宁可把
  // 它留着(`🎬🔥.mp4` 总比 `即存媒体.mp4` 认得出来),但一个字的残渣("警")也不如
  // 原名,所以门槛定在 2 字节。
  final stripped = shortenTitle(rawCleaned);
  final cleaned = (_utf8Len(stripped) >= 2 ? stripped : rawCleaned)
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      // 剥标签、清 emoji 都会留下连着好几个的下划线,收一收
      .replaceAll(RegExp(r'_{2,}'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final tail = index > 0 ? '_$index' : '';
  if (cleaned.isEmpty) return '$fallback$tail';

  // 后缀按 5 字节封顶:解析期猜出来的最长是 `.jpeg`,而 CDN 那种
  // `~tplv-tt-large.image` 会猜出 6 个字符的 `.image` —— 那是个错后缀,不值得为它
  // 多扣一个字节的标题。真按 6 字节存下来时,由 [_retag] 收口。
  final extBytes = math.min(utf8.encode(ext).length, _kMaxExtBytes);
  final suffix = extBytes + _indexBytes(index);
  final budget = maxBytes > suffix ? maxBytes - suffix : maxBytes;
  final bytes = utf8.encode(cleaned);
  if (bytes.length <= budget) return '$cleaned$tail';

  // 按字节切可能把一个多字节字符劈成两半,allowMalformed 会把残片换成 U+FFFD,
  // 再把它去掉 —— 否则文件名里会留一个乱码方块。
  final cut = utf8
      .decode(bytes.sublist(0, budget), allowMalformed: true)
      .replaceAll('\uFFFD', '')
      .trim();
  return cut.isEmpty ? '$fallback$tail' : '$cut$tail';
}

/// 解析期给后缀留的字节上限。见 [safeFileName] 里为什么封顶。
const int _kMaxExtBytes = 5;

/// 序号 `_12` 占几字节。0 号(不编号)不占。
int _indexBytes(int index) => index <= 0 ? 0 : '_$index'.length;

/// 一个文件名的字节上限。见 [safeFileName] 里那段实测说明。
const int _kMaxNameBytes = 66;

/// 把标题那段收到 `[maxBytes] - 后缀` 之内,返回截好的标题。
///
/// 收尾改后缀时用(真实后缀只有下载完才知道),保证"标题 + 后缀"永远不超上限。
/// 解析期已经按最长的候选后缀扣过一次,所以这里只有猜错后缀(比如猜 `.jpeg`
/// 真来 `.webm`,或者 CDN 那种 `.image` 猜不出真格式)时才会真截到东西。
String _fitStem(String stem, String ext, int maxBytes) {
  final budget = maxBytes - utf8.encode(ext).length;
  final bytes = utf8.encode(stem);
  if (bytes.length <= budget) return stem;
  // 按字节切可能把一个多字节字符劈成两半,allowMalformed 会把残片换成 U+FFFD,
  // 再把它去掉 —— 否则文件名里会留一个乱码方块。
  return utf8
      .decode(bytes.sublist(0, budget), allowMalformed: true)
      .replaceAll('\uFFFD', '')
      .trim();
}
