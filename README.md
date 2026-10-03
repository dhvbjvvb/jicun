<div align="center">
  <img src="图标.png" width="140" alt="即存">
  <h1>📦 即存</h1>
  <p><b>粘贴一条分享链接，预览、挑清晰度、存进相册。</b></p>

  <p>
    <a href="https://github.com/dhvbjvvb/jicun/actions/workflows/ci.yml"><img src="https://github.com/dhvbjvvb/jicun/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
    <img src="https://img.shields.io/badge/version-3.2.7-success" alt="版本">
    <img src="https://img.shields.io/badge/platform-Android-3DDC84?logo=android&logoColor=white" alt="平台">
    <img src="https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white" alt="Flutter">
    <img src="https://img.shields.io/badge/Dart-%5E3.13.3-0175C2?logo=dart&logoColor=white" alt="Dart">
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="许可证"></a>
  </p>
</div>

一个 Android 端的视频 / 图文解析与下载 App。Flutter 写界面，下载这一段走 Kotlin 原生实现。

> 本仓库只发布 Android 端源码。

---

## ✨ 功能

### 🔍 解析与预览

- 粘贴分享链接直接解析，整段分享文案也行，链接会自动挑出来
- 支持视频、图片（图集）、实况、音频、纯文案；有什么才显示什么，不会出现空卡片
- 解析结果就地预览：视频 / 音频播放器、图集缩略图与全屏看图、可复制的文案卡片
- 多个清晰度时弹窗选档（原画 / 720P / 540P 等），选定后开始下载

### ⬇️ 下载

- 大文件按 Range 分段并行下载，段级重试，连接被重置不会整条重来
- 小文件不分段：几 MB 的图多开连接，省下的时间还不够一次 TLS 握手
- 批量下载时按文件数摊薄每个文件的并发额度，避免把 CDN 的并发上限撞满
- 实时速度与整体进度；可随时取消，取消不留半截文件
- 退到后台接着下：下载期间挂一条前台服务 + 唤醒锁，切走或锁屏不会被系统清掉
- 下次启动清扫上次被系统杀掉时留下的分片
- 落盘前按响应头 + 文件头嗅探真实格式再定后缀，动图不会被存成静态图的名字
- 下载完登记进系统媒体库，相册里直接能看到

### 🕘 历史与通知

- 解析历史本地留存，支持多选批量删除
- 下载完成 / 失败通知，可分别开关；带一次通知自测

### 🎨 外观

- 浅色 / 深色 / 跟随系统，顶栏样式与界面缩放可调
- 图标、顶栏图、弹窗素材都备了深浅两套

### 🧩 其他

- 检查更新与 APK 内下载安装
- 内置使用帮助（按平台列出可解析的内容类型与操作步骤）
- 关于页里藏了一个彩蛋 🥚

---

## 🌐 支持平台

| 平台 | 可解析内容 |
|---|---|
| 抖音 | 视频、图片、实况、文案 |
| 快手 | 视频、图片、实况、文案 |
| 小红书 | 视频、图片、实况、文案 |
| 哔哩哔哩 | 有水印视频 |
| 微博 | 图文、视频、实况 |
| 微信公众号 | 视频、图片、文章 |
| 微信视频号 | 视频 |
| 今日头条 | 视频、图片、文章 |
| 西瓜视频 | 视频 |
| 好看视频 | 视频 |
| 豆包 | 无水印图片、无水印视频 |
| 汽水音乐 | 仅免费音乐、MV |
| 皮皮虾 | 视频、图片、文案 |
| 皮皮搞笑 | 视频、图片、文案 |
| 最右 | 视频、图片、实况、文案 |

上面这份就是**全部支持范围**。粘进不在名单里的链接，会在本地直接提示「暂不支持该平台」，不会白跑一趟解析。

「可解析内容」按各平台实际能拿到的写，没有往好里凑数 —— 比如哔哩哔哩拿到的视频带水印，就照实说。

---

## 📂 项目结构

```
lib/                         42 个 Dart 文件、约 15.3 千行
  main.dart             入口与根壳
  bootstrap.dart        启动编排：首帧前要办的事，与之后的后台活
  shell_controller.dart 板块页要用的应用状态接口（切断 import 环）
  pages/                三个板块 parse.dart / history.dart / preview.dart，以及设置各级页 settings.dart
  ui/                   共享界面件：
                        glass.dart         面板 / 二级页外壳
                        popup.dart         弹层外壳与共用件
                        download_progress_card.dart 下载进度卡
                        progress_ring.dart 进度环与波环
                        update_card.dart   更新卡与说明预览
                        quality_picker.dart 清晰度选择弹层
                        markdown.dart      release 说明解析
                        motion.dart / palette.dart / icons.dart / widgets.dart
                        playback.dart / clipboard.dart / clipboard_reader.dart
                        notifications.dart / prefs.dart / permissions_gate.dart
                        app_background.dart
  widgets/              animated_tab_icon.dart、tap_easter_egg.dart
  parse_service.dart    链接识别、上游路由与请求重试
  upstream_mapping.dart 各家平台应答转统一模型（不碰网络，可脱网单测）
  downloader.dart       下载调度、落盘、后缀嗅探与媒体库登记
  download_logic.dart   下载器纯逻辑的跨端规格（只在测试里用）
  update_service.dart   检查更新与 APK 下载、sha256 校验
  update_coordinator.dart 检查 / 忽略版本 / 装包的编排
  media_date.dart       文件时间改成下载当天
  history_store.dart    解析历史持久化
  sponsor_store.dart    赞助名单：本地缓存 + 联网刷新，拿不到就用内置那份
  cover_cache.dart      封面磁盘缓存
  preferred_ip.dart     多候选连接竞速与备用线路
  audio_tags.dart       往音频文件里写标题/封面/歌词
  api_host.dart         接口域名与优选 IP 的下发/落盘
  bench.dart            真机基准参数（排障用）
android/                原生侧（Kotlin）：通道转发、媒体库登记、装包、后台选择器、剪贴板；NativeDownloader 是分段并行下载器
assets/                 顶栏图、平台图标、彩蛋素材
tool/                   生成 / 转换脚本（gen_logic_vectors、make_header_art…），run_tests.ps1 逐文件跑测试
test/                   36 个文件、约 410 条用例：单元测试与 widget 测试
integration_test/       真机基准测试（下载测速）
```

---

## 🛠️ 构建

需要 Flutter stable、Android SDK、JDK 17。

**最低 Android 10(API 29)**:文件存进相册那一步走的是分区存储(`RELATIVE_PATH` /
`IS_PENDING` / 按卷取集合),29 以下没有这套 API —— 那些机器上文件能下下来却存不进相册。
要支持更老的系统,得先补一条 pre-Q 的发布路径(见 `android/app/build.gradle.kts` 里的说明)。

```bash
git clone https://github.com/dhvbjvvb/jicun.git
cd jicun

flutter pub get

# 接口凭据不入库，先按模板建一份本地文件
cp lib/secrets.example.dart lib/secrets.dart   # Windows: copy lib\secrets.example.dart lib\secrets.dart

flutter build apk --release
```

`lib/secrets.dart` 已被 gitignore。文件缺失时无法编译；填成空串也能编译运行，只是部分平台的解析会退化到兜底通道。

发布签名需要 `android/key.properties` 与对应的 keystore（同样不入库）：

```properties
storePassword=...
keyPassword=...
keyAlias=jicun
storeFile=app/jicun-release.jks   # 相对 android/
```

**缺这两个文件时，release 产物直接失败**：以前是静默退回 debug 签名 —— 那种包装得上，却因为
签名不对既不能上架也不能覆盖安装，而且一句提示都没有。本机只想用 debug 签名跑一次 release，
显式加一条：

```bash
flutter build apk --release -PallowDebugSigning=true   # 这个包的签名是 debug 的，别拿去分发
```

release 走 R8（`isMinifyEnabled` / `isShrinkResources`，规则在 `android/app/proguard-rules.pro`）。
真遇到"某个类被削掉了"，先看那份规则文件的说明：app 与插件的类都是直接引用、清单里的组件由
AGP 自动保，所以正常不需要再补 keep 规则。

---

## 🧪 测试

```bash
flutter analyze
.\tool\run_tests.ps1                 # 逐文件跑 test/,每个文件失败重试一次
flutter test integration_test        # 需要真机或模拟器
python tool/check_comment_refs.py    # 注释里点名的标识符必须还在(判据保守,见脚本说明)
```

原生侧：

```bash
cd android && ./gradlew :app:testDebugUnitTest    # Kotlin：下载器纯逻辑、启动入口、媒体库命名、落盘规矩
```

直接调 gradle 打 release 也能用：`cd android && ./gradlew :app:assembleRelease`（不带 `-Ptarget-platform`
就是三 ABI 的通用包，比 `flutter build apk --release --target-platform=android-arm64` 大一倍多）。
它会先按 release 语义把插件注册器里的 dev 依赖行去掉 —— Flutter 只在 `flutter build` / `run` 时
重写那份文件，而注册器是 debug / release **共用同一个路径**：先在 gradle 里跑过一次 debug
（单测、`assembleDebug`），再直接打 release，原本会编译到一份点名 `integration_test` 的残留文件，
而 release 的编译类路径上没有它，于是 `javac` 报 `package dev.flutter.plugins.integration_test does
not exist`。为什么会这样、为什么修在这里，见 `android/app/build.gradle.kts` 末尾那段说明。

`test/` 覆盖解析路由、下载分段与重试、历史存储、更新检查（含 sha256 校验）、资源引用、彩蛋与启动图资源等；`integration_test/` 里的基准用例用来单独量一台机器连某条 CDN 的下载速度，把「下载慢」定位到链路还是下载实现。

原生侧那 52 条里有 4 条（`MediaPublisherTest.kt`）专门盯**落盘的规矩**：按块搬、失败必撤、
可见性没生效就当失败、100% 一定等于已在相册。这些规矩错了不会崩，只会安静地丢一个文件，
所以切出接缝（`PublishSink.kt`）脱网锁住；真正碰 `MediaStore` / SAF 的两小段只能真机验，
验收清单见 `交付说明.md` 第十节。

同一类"错了不报、只是悄悄不一样"的还有相册里那条**查重名**的查询（`MainActivityNameTest.kt`）：
`LIKE` 不写 `ESCAPE` 时，模式里的 `\_` 只是个普通反斜杠，对 `标题_1` 这种名字**永远查不到**，
补号静默失效。所以拼模式、拼查询条件那两个函数拎进了 `DownloadNames.kt`（一行 Android API
都不碰），用纯函数用例锁住。

### 🔬 下载器纯逻辑的跨端规格

分段切分、续传偏移、连接轮换判据、重试账本这几个函数**错了不会崩**，只会安静地下出一个坏文件（少一段、写重一段）或者在 80% 处误报失败。两端各有一份实现（Android Kotlin、Dart 兜底），所以用同一份测试向量锁住：

| 文件 | 角色 |
|---|---|
| `lib/download_logic.dart` | 规格的 Dart 写法:**Dart 兜底引擎直接调用它**;native 走自己的 Kotlin 判据 |
| `tool/download_logic_vectors.json` | 生成的向量，两端共用 |
| `tool/gen_logic_vectors.py` | 生成/校验；`--write` 重新生成 |

两边都在读它：`test/download_logic_vectors_test.dart` 与 `android/app/src/test/kotlin/.../DownloadLogicVectorsTest.kt`。改了实现就重跑 `python tool/gen_logic_vectors.py --write`，CI 会校验生成物和实现一致。

---

## 🔒 隐私

App 不要求登录，不采集个人信息。解析结果与历史只存在本机；下载的文件直接写入相册对应目录（或在设置里指定的目录，那一档不进系统媒体库）。

「自动粘贴并解析」默认**开启**：回到前台时会读一次剪贴板里的首条链接，挑出其中的分享链接去解析，读到的内容不出本机；不需要可以在设置里关掉。

---

## ⚠️ 免责声明

本项目仅供学习与技术交流使用，请勿用于商业用途。解析与下载的内容版权归原作者所有，请自行确认拥有相应权利后再保存或传播，因使用本工具产生的一切后果由使用者自行承担。

---

## 📄 许可证

[MIT](LICENSE) © 2026 DIOT
