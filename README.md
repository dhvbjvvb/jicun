<p align="center">
  <img src="图标.png" alt="即存" width="112">
</p>

<h1 align="center">即存 for Android</h1>

<p align="center">
  <strong>粘贴分享链接，视频 / 图片 / 音频 / 文案一次拿到手。</strong>
</p>

<h3 align="center"><a href="https://github.com/dhvbjvvb/jicun/releases/latest">一键下载 APK，装完即用。</a></h3>

<p align="center">
  Flutter 写界面，收流、写入相册、装包这几段走 Kotlin 原生。一个 APK 就是全部，不用另装任何运行库。
</p>

<p align="center"><sub>本程序只做「把你自己的链接解析成直链再下载」：不提供任何内容、不绕过付费或权限。请遵守各内容平台的服务条款与当地法律，使用风险自负。<br>本仓库与任何内容平台均无隶属、合作、授权或背书关系。</sub></p>

<p align="center">
  <a href="https://github.com/dhvbjvvb/jicun/releases/latest"><img src="https://img.shields.io/github/v/release/dhvbjvvb/jicun?style=flat&label=release&color=4D6BFE" alt="最新版本"></a>
  <a href="https://github.com/dhvbjvvb/jicun/releases"><img src="https://img.shields.io/github/downloads/dhvbjvvb/jicun/total?style=flat&label=downloads&color=4D6BFE" alt="总下载量"></a>
  <a href="https://github.com/dhvbjvvb/jicun"><img src="https://img.shields.io/github/stars/dhvbjvvb/jicun?style=flat&label=%E2%98%85&color=08C" alt="GitHub stars"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2EA44F?style=flat" alt="MIT License"></a>
  <a href="https://github.com/dhvbjvvb/jicun/actions/workflows/ci.yml"><img src="https://github.com/dhvbjvvb/jicun/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Android%2010%2B-API%2029-3DDC84?style=flat-square" alt="支持 Android 10 及以上">
</p>

> 本仓库只发布 Android 端源码。Windows 桌面端见 [jicun-desktop](https://github.com/dhvbjvvb/jicun-desktop)。

## 下载与安装

| 版本 | 下载 | 装法 |
| --- | --- | --- |
| **APK**（推荐） | [最新发布页](https://github.com/dhvbjvvb/jicun/releases/latest) | 手机上下载后点开安装；**支持应用内自动更新** |

- **系统要求**：Android 10（API 29）或更高。
- **不用装别的**：没有要额外下载的运行库或框架，一个 APK 装完就能用。
- **体积**：约 24 MB（arm64）。
- 发布页同时挂了通用包和按 CPU 架构拆分的包，**应用内更新会按你手机的架构自己挑**，手动下载的话随便挑一个装也行。
- 第一次装的时候系统会要求你允许「安装未知应用」—— 从浏览器或聊天软件里点开 APK 都会走这一步，允许之后才能装。

> **为什么最低 Android 10**：文件写进相册那一步用的是分区存储那一套 API（`RELATIVE_PATH` / `IS_PENDING` / 按卷取集合），Android 10 以下没有它们 —— 那些机器上文件能下下来，却存不进相册。所以没往更老的系统上凑。

## 主要功能

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>链接解析</h3>
      <p>整段分享文案粘进来会自动挑出链接，也可以点「粘贴」读剪贴板。不在名单里的链接会在本地直接提示「暂不支持该平台」，不白跑一趟解析。</p>
    </td>
    <td width="50%" valign="top">
      <h3>预览与清晰度</h3>
      <p>解析结果就地预览：视频 / 音频播放器、图集缩略图与全屏看图、可复制的文案卡片；有多个清晰度时弹窗选档（原画 / 720P / 540P…）再下。</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>下载够稳</h3>
      <p>8 MB 以上的文件按 Range 切段并行收，段级重试 + 断点续传 —— 连接被重置不会整条重来；几 MB 的小文件不分段，省下的时间还不够一次 TLS 握手。批量下大文件时按文件数摊薄并发，不去撞 CDN 的上限。</p>
    </td>
    <td width="50%" valign="top">
      <h3>退到后台接着下</h3>
      <p>下载期间挂着一条前台服务 + 唤醒锁：切到别的 App、锁屏都不会被系统清掉。下载一结束就停，通知栏不留常驻通知。</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>落盘进相册</h3>
      <p>落盘前按响应头 + 文件头嗅探真实格式再定后缀（动图不会被存成静态图的名字），重名自动补号。下完登记进系统媒体库：视频进 <code>Movies</code>、图片进 <code>Pictures</code>、音频进 <code>Music</code> 下的「即存」目录，相册 / 音乐 App 里直接能看到。</p>
    </td>
    <td width="50%" valign="top">
      <h3>取消 / 失败不留垃圾</h3>
      <p>随时可取消，取消不留半截文件；失败的那条删掉、同一批里已经下好的照常进相册。上次被系统杀掉留下的分片，下次启动顺手清掉。</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>历史与通知</h3>
      <p>解析历史最多留 200 条，本地留存、支持多选批量删除；「下载完成 / 失败」通知可分别开关，带一次通知自测。</p>
    </td>
    <td width="50%" valign="top">
      <h3>外观</h3>
      <p>浅色 / 深色 / 跟随系统，顶栏样式与界面缩放可调；图标、顶栏图、弹窗素材都备了深浅两套。</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>检查更新</h3>
      <p>启动时后台查一次，设置页也能手动查。新版弹窗写清这次改了什么（就是 Release 正文），可「忽略」这一个版本；点更新则 APK 内下载 + sha256 校验，再交给系统安装器。</p>
    </td>
    <td width="50%" valign="top">
      <h3>使用帮助</h3>
      <p>内置按平台列出的「能解析什么、怎么操作」，不用先去翻文档。关于页里还藏了一个彩蛋 🥚。</p>
    </td>
  </tr>
</table>

## 支持的平台与内容

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

## 权限说明

| 权限 | 用来干什么 |
| --- | --- |
| `INTERNET` | 解析与下载 —— 全部联网行为只有这一件事 |
| `POST_NOTIFICATIONS` | 「下载完成 / 失败」通知；不想看可以在设置里分别关掉 |
| `REQUEST_INSTALL_PACKAGES` | 应用内更新：把下好的 APK 交给系统安装器 |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC` | 下载期间的前台服务，让下载在后台接着跑 |
| `WAKE_LOCK` | 上一条的配套：别让 CPU 睡过去，把下载拖成涓流 |

> **没有存储权限**：写进相册走的是系统媒体库（MediaStore），不需要「读取 / 写入手机存储」那种全家桶权限。选「任意文件夹」保存时用的是系统目录选择器给的授权，只对那一个目录有效。

## 自动更新

程序启动时在后台查一次最新版，设置页也有「检查更新」手动查。

- **有新版本就弹一个公告窗口**：上面写这次改了什么（就是 GitHub 上那条 Release 的正文），底下「忽略」/「更新」。
- **「忽略」只忽略这一个版本**：以后出了更高的版本照样提示。
- **点「更新」**：APK 内下载（有进度）→ 核对 sha256 → 交给系统安装器装上。
- **没给「安装未知应用」的权限时**会明说一句，并给一个直接跳去系统设置的入口 —— 不让你以为是更新坏了。
- **连不上时**会写清原因，也可以自己去发布页下载 APK 覆盖安装。

## 你的数据放在哪

全部在本机，不上传：

| 东西 | 位置 |
| --- | --- |
| 设置与开关 | 应用私有存储（随卸载一起删） |
| 解析历史（最多 200 条） | 应用私有存储 |
| 下载成品 | 系统相册 / 音乐目录：`Movies/Jicun/Video`、`Pictures/Jicun/Picture`、`Music/Jicun/Music`；也可以在设置里改成任意目录（那一档不进系统媒体库） |
| 下载中的分片、封面缓存 | 应用缓存目录（上次被系统杀掉留下的分片，下次启动会清掉） |

程序不要求登录，不采集个人信息；只有解析、下载、检查更新、拉取赞助名单这几件事会联网。

## 常见问题

**解析失败？**
多半是链接所在平台改了接口，或者当前网络到上游不通。可以把链接和界面上的报错发到 [Issues](https://github.com/dhvbjvvb/jicun/issues)。

**下载慢？**
同一条 CDN 的速率受运营商和 CDN 侧限速影响很大，跟「下载实现」是两件事：`integration_test/` 里有一个基准用例，专门量一台机器连某条 CDN 能拿多少 —— 先分清是链路还是实现，再谈调参。

**相册里找不到刚下好的文件？**
看两处：一是设置里的「存储保存位置」如果被改成了某个自定义目录，那批文件不进系统媒体库，要用文件管理器去那个目录看；二是系统媒体库刷新有延迟，退出相册再进一次。

**通知栏那条「正在下载」是什么？**
前台服务的通知，下载期间挂着它是为了不被系统清掉，下完自动消失。不想看到它的话，可以在系统设置里把这类通知设为静默。

**更新装不上？**
先在系统里允许「安装未知应用」（App 里点更新时会直接给你跳转入口）。国内网络连 GitHub 时常通时不通，弹窗里也会说明。

**为什么最低要 Android 10？**
见上面「下载与安装」里那段说明：写进相册用的是分区存储那套 API，更老的系统上文件下得下来但存不进相册。

## 构建与开发

需要 Flutter stable、Android SDK、JDK 17。

### 构建

```bash
git clone https://github.com/dhvbjvvb/jicun.git
cd jicun

flutter pub get

# 接口凭据不入库，先按模板建一份本地文件
cp lib/secrets.example.dart lib/secrets.dart   # Windows: copy lib\secrets.example.dart lib\secrets.dart

flutter build apk --release
```

`lib/secrets.dart` 已被 gitignore。文件缺失时无法编译；填成空串也能编译运行，只是部分平台的解析会退化到兜底通道。

发布签名需要 `android/key.properties` 与对应的 keystore（同样不入库）。**缺这两个文件时，产出 release 产物的任务会直接失败** —— 以前是静默退回 debug 签名，那种包能装上、却既不能上架也不能覆盖安装，而且一句提示都没有。本机只想用 debug 签名跑一次 release：

```bash
flutter build apk --release -PallowDebugSigning=true   # 这个包的签名是 debug 的，别拿去分发
```

### 测试

```bash
flutter analyze
.\tool\run_tests.ps1                 # 逐文件跑 test/，每个文件失败重试一次
cd android && ./gradlew :app:testDebugUnitTest    # Kotlin：下载器纯逻辑、启动入口、媒体库命名、落盘规矩
python tool/gen_logic_vectors.py     # 校验跨端测试向量与实现一致
python tool/check_comment_refs.py    # 注释里点名的标识符必须还在
flutter test integration_test        # 需要真机或模拟器
```

**为什么要逐文件跑、还重试一次**：Windows 上的 `flutter_tester` 有一条引擎级缺陷 —— `ShaderMask` + 滚动列表在软件渲染下会以 `0xc0000005` 静默杀掉整个测试进程，一次带走同一文件里剩下的几十条用例。触发是概率性的（约 0.1%/用例），和具体用例无关。逐文件跑把爆炸半径限制在一个文件里，重试一次就把那点概率抹掉；本机与 CI 用同一套跑法，才不会出现「本地红、CI 绿」这种没法归因的情况。

### 项目结构

```
lib/                   55 个 Dart 文件
  main.dart            入口与根壳
  bootstrap.dart       启动编排：首帧前要办的事，与之后的后台活
  pages/               四个板块页：parse / history / preview / settings
  ui/                  共享界面件（面板、弹层、进度环、通知、偏好…），
                       以及预览与设置拆出来的各分片（见下面那段）
  parse_service.dart   链接识别、上游路由与请求重试
  upstream_mapping.dart 各家平台应答转统一模型（不碰网络，可脱网单测）
  downloader.dart      下载调度、落盘、后缀嗅探与媒体库登记
  download_logic.dart  下载器纯逻辑的跨端规格
  update_service.dart  检查更新与 APK 下载、sha256 校验
  preferred_ip.dart    多候选连接竞速与备用线路
  sponsor_store.dart   赞助名单：本地缓存 + 联网刷新，拿不到就用内置那份
android/               原生侧（Kotlin）：通道转发、媒体库登记、装包、后台选择器、剪贴板、下载保活
tool/                  生成 / 转换脚本，run_tests.ps1 逐文件跑测试
test/                  Dart 用例：单元测试与 widget 测试
integration_test/      真机基准测试（下载测速）
```

`pages/` 里只放四个板块页本身。原来挤在它们里面的东西按“一个东西一个文件”搬进了
`lib/ui/`，找二级页面时不用再去翻两千行：

| 原来住在哪 | 现在住在哪 |
| --- | --- |
| `pages/preview.dart`（2125 行） | `ui/player_ui.dart`（播放控件那一层）、`ui/video_stage.dart`、`ui/audio_stage.dart`、`ui/gallery_stage.dart`（缩略图条 + 大图）、`ui/copy_stage.dart`；`playbackHeaders` 并进了 `ui/playback.dart` |
| `pages/settings.dart`（1737 行） | `ui/theme_appearance_page.dart`、`ui/storage_location_card.dart`、`ui/help_feedback_page.dart`、`ui/about_page.dart`、`ui/sponsor_page.dart`、`ui/notification_management_page.dart`、`ui/auto_paste_page.dart`；`pages/settings.dart` 只剩索引页那三块 |

### 下载器纯逻辑的跨端规格

分段切分、续传偏移、连接轮换判据、重试账本这几个函数**错了不会崩**，只会安静地下出一个坏文件（少一段、写重一段）或者在 80% 处误报失败。两端各有一份实现（Android Kotlin、Dart 兜底），所以用同一份测试向量锁住：

| 文件 | 角色 |
|---|---|
| `lib/download_logic.dart` | 规格的 Dart 写法：**Dart 兜底引擎直接调用它**；native 走自己的 Kotlin 判据 |
| `tool/download_logic_vectors.json` | 生成的向量，两端共用 |
| `tool/gen_logic_vectors.py` | 生成 / 校验；`--write` 重新生成 |

两边都在读它：`test/download_logic_vectors_test.dart` 与 `android/app/src/test/kotlin/.../DownloadLogicVectorsTest.kt`。改了实现就重跑 `python tool/gen_logic_vectors.py --write`，CI 会校验生成物和实现一致。

## 隐私

App 不要求登录，不采集个人信息。解析结果与历史只存在本机；下载的文件直接写入相册对应目录（或在设置里指定的目录，那一档不进系统媒体库）。

「自动粘贴并解析」默认**开启**：回到前台时会读一次剪贴板里的首条链接，挑出其中的分享链接去解析，读到的内容不出本机；不需要可以在设置里关掉。

## 免责声明

本项目仅供学习与技术交流使用，请勿用于商业用途。解析与下载的内容版权归原作者所有，请自行确认拥有相应权利后再保存或传播，因使用本工具产生的一切后果由使用者自行承担。

## License

本项目遵循 [MIT License](LICENSE) © 2026 DIOT。

> 本项目完全免费开源。如果有人向你收费出售此软件，请拒绝。
>
> 本程序只提供「解析你自己有权访问的链接并下载」这一技术能力，不提供任何内容、不破解任何权限或付费墙；请遵守各内容平台的服务条款与当地法律，使用风险自负。
>
> 本仓库与任何内容平台不存在隶属、合作、授权或背书关系。
