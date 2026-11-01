# notice/ —— 公告图

公告正文里写 `![](图片地址)` 就贴 GitHub 链接，App 会自动换成镜像（见 App 端 `ui/GithubMirror.kt`）：

- 贴：`https://github.com/dhvbjvvb/jicun/blob/main/notice/xxx.png`
- App 实际请求：`https://fastly.jsdelivr.net/gh/dhvbjvvb/jicun@main/notice/xxx.png`

竖图、GIF 都行；文件名用日期或用途，别带空格。
