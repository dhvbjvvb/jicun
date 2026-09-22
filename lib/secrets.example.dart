/// 上游 BugPk 密钥的模板。
///
/// 真值不入版本库:复制本文件为 `lib/secrets.dart`,把 key 填进去。
/// `lib/secrets.dart` 已在 .gitignore 里,不会被提交。
///
///     cp lib/secrets.example.dart lib/secrets.dart
///
/// 拿不到 key 也能编译和运行 —— 只是抖音 / 快手 / 视频号 / 豆包
/// 这四个平台不再走上游直连,全部落到自建的 media-parser 兜底。
const String bugpkApiKey = '';
