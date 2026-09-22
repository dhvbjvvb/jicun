# jicun

Android 视频解析与下载 App(Flutter + 原生下载器)。

支持抖音、快手、微信视频号、豆包、B 站、小红书等平台的链接解析,原画/720P/540P
多档下载,历史记录与批量管理。

## 目录

| 路径 | 内容 |
|---|---|
| `lib/` | Dart 界面、解析服务、下载调度、更新服务 |
| `android/` | 原生侧:下载器、通知、启动页 |
| `deploy/` | 解析反代(nginx)的服务器配置与部署脚本 |
| `assets/` | 界面图片、平台图标、彩蛋素材 |
| `tool/` | 开发期探针与美术生成脚本 |
| `test/`, `integration_test/` | 单元测试与集成测试 |

## 构建

```
cp lib/secrets.example.dart lib/secrets.dart   # 填入上游密钥,文件已被 gitignore
flutter pub get
flutter build apk --release
```

没有 `lib/secrets.dart` 时编译会失败;填成空串也能编译,只是抖音 / 快手 /
视频号 / 豆包 四个平台不再走上游直连,全部走自建反代兜底。

签名用的 `android/key.properties` 与 `*.jks` 同样不入版本库,发布构建需要自行
补齐。

## 服务端

`deploy/` 里的 nginx 配置与部署脚本负责 media-parser 反代;密钥由
`deploy/deploy-jicun.ps1 -BugpkKey` 在部署时注入服务器,不落仓库。
