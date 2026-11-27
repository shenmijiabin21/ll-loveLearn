# 每日听写

给小学二年级、三年级上册使用的 Flutter 听写练习。App 使用设备本地记录和识别，不需要自建服务器、登录或广告服务。

## 开始使用

1. 在「设置」查看当前字库和已学起点。内置字库是自编示例，正式练习前请导入核验过的教材字库。
2. 在「设置」联网下载简体中文手写模型，再试播普通话。在 iPhone 或 iPad 的系统设置中搜索「朗读内容」或「朗读与语音」，确认普通话声音可用。Android 需在系统文字转语音设置中安装离线普通话语音。
3. 在「今日」打开每日一练。点「播放题目」先听一句例句，再听到「请写这句话里的词语：××」，然后按词的每个字依次写进对应的田字格，格子上方显示该字的拼音，可随时隐藏。可撤销、清空、跳过或点题号回看。完成的笔划和题号会保存，退出后可以继续。
4. 到最后一题提交整组。结果显示正确、错字、空白或待确认；逐字判定，整词全部写对才算正确。家长可放大原笔迹、订正，或恢复自动批改。
5. 「重点」可复习错词、空白和待确认词语，「统计」可查看历史。通过「设置」导出或恢复 JSON 备份。备份包含原笔迹，建议保存在自己控制的位置。

默认顺序是三上 → 二下 → 二上，每册按课号倒序。同一课的字沿用导入顺序。**每次练习的新词数量由家长在「练习设置」里选**（3/4/5/6/8/10，默认 5）；到期的复习词**不占**这个名额，是额外加上的，但一次最多 5 个，避免攒了十几天的错词一次性压给孩子。一天只生成一组每日任务。「重点复习」按最多 10 个到期词出题，与这个设置无关。未提交的草稿跨天保留，计入开始那天。重点字默认次日复习，到期答对后间隔 3 天、7 天，第 3 次到期答对后移出待复习列表。提前复习可以重练，提前答对不会缩短间隔。

## 教材字库

JSON 结构面向可替换的人教部编版教材数据。导入时按实际教材的版次和课号录入，标明核验来源。项目没有附带正式教材字表。

- [assets/demo.json](assets/demo.json) 提供可导入的结构示例，`sample` 为 `true`，册次和课号仅展示排序。
- `schema` 当前为 `1`。每个版本使用独立的 `edition`，允许字母、数字、点、下划线和连字符。同一版本沿用已经完成的课程字进度。
- `title` 写教材版本名称，`source` 写核验来源、版次或印次。核验后才将 `sample` 设为 `false`。
- `volume` 支持 `3a`（三上）、`2b`（二下）、`2a`（二上）。每册 `number` 不重复，每课目标字不重复。
- 每个 `words` 项填写 `character`、`phrase` 和从 1 起算的 `position`。例如用「大门」的第二个字提示「门」。词语须包含 2 至 8 个汉字。默写单位是整个 `phrase`：每个字一个田字格，`position` 只用于校验数据一致性。
- 拼音来自 [assets/pinyin.json](assets/pinyin.json)（词级读法，含「重叠」chóng dié、「放假」fàng jià 这类多音字；查不到时按单字兜底，再查不到就不显示，避免显示错误拼音）。
- 例句来自 [assets/sentences.json](assets/sentences.json)：预置字库 564 个词语每个一条，读题时「先读例句，再指定例句里要默写的词语」。表里没有的词（例如自导入字库）退回「请默写词语：××。××。」；批改结果页也会显示例句供家长核对。

## 技术说明

- Flutter 3.50.1、Riverpod。手机和平板使用同一套界面，大屏使用侧栏导航，练习页面并排显示题目和田字格。
- MVP 使用轻量本地 JSON 保存，双文件轮换写入并保留上一份有效快照。笔迹以归一化坐标和时间戳保存，字库更换后仍能查看既有记录。网页预览使用浏览器本地存储，仅适用于短期验证。
- iOS 与 Android 通过 ML Kit Digital Ink 使用 `zh-Hani-CN`。首次下载模型需联网。下载后在设备上处理笔迹。没有可用模型或分数缺失、候选不明确时，已写题进入待确认。
- 判定使用候选字与相邻分数的保守规则。分差阈值仍需用目标设备上的学生手写样本校准。识字结果只能辅助判断写的是哪个字，无法验证笔顺、笔画完整性或书写规范。
- 网页端的服务端识别按「格」提交：一个词语的每个字单独一条 `/grade` 请求项，逐格回填判定，整词规则是「全对才正确，任一格判错即错，有空格或不确定交给家长」。
- **家长端实时监控走 WebSocket**（`/api/ws/live`）：学生端把心跳（是否可见、距上次落笔多少秒、累计笔数/时长）和每次保存的进度上报给服务端，服务端立刻推给家长的连接，并在每 10 秒补推一次状态，让「正在练习 → 空闲 → 离线」随时间自然过渡。原来的 5 秒轮询只在 WebSocket 断开时作为兜底（15 秒一次）。状态一律由服务端按时间差推导，客户端自报的结论不作数——孩子关掉页面、断网、强杀浏览器都不需要任何「结束」消息。
- iOS 使用系统 AVSpeech，Android 筛选已安装且无需联网的普通话声音。实际发音及离线可用性取决于设备语音包。浏览器预览和无声设备可用「家长读题」。

## 运行与开发

```sh
flutter --version
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
flutter run -d chrome
```

手机功能请用 iOS 或 Android 真机验证。iOS 最低 15.5，原生依赖通过 CocoaPods 安装。建议用飞行模式复验普通话播放和手写识别，并在 iPhone、iPad 上检查写字、切后台恢复、放大原笔迹、备份分享和恢复。Windows 可跑 Flutter 测试及网页预览。

## iPhone / iPad 构建与安装

### GitHub Actions

提交代码到已授权的 GitHub 仓库后，`main` 分支上的推送或 PR 会触发「iOS Build」，也可以从 Actions 手动运行。工作流使用 macOS 和 Xcode，成功后可下载 `daily-dictation-ios-unsigned`，其中包含未签名的 `.xcarchive` 和 SHA-256 校验文件。它用于确认 iOS 构建通过，无法直接装到 iPhone 或 iPad。

在受信任的 Mac 上可执行同样的构建：

```sh
flutter pub get --enforce-lockfile
flutter build ipa --release --no-codesign --no-pub
```

### 签名与真机安装

- **有 Mac，可以用 Xcode 直接装机。** 在 Xcode 打开 `ios/Runner.xcworkspace`，选择 Runner 的 Signing & Capabilities，登录自己的 Apple Account，选择 Team 并启用自动签名。免费 Apple Account 的 Personal Team 可以用于个人装机，描述文件有效期为 7 天。若默认标识符 `com.lilijie.llLoveLearn` 不属于你的 Team，改成该 Team 可注册的标识符。连接设备，按系统要求启用开发者模式，然后在 Xcode 运行。
- **用 TestFlight 分发。** 需要 Apple Developer Program 与 App Store Connect 权限。注册 Bundle ID 和 App，使用有签名权限的 macOS 环境构建签名归档，上传 App Store Connect，再把测试人员添加到 TestFlight。签名信息由仓库或 Apple 团队所有者在受控环境中配置。
- **用 Ad Hoc 分发。** 需要 Apple Developer Program、分发证书、匹配的描述文件及已注册的目标设备。将签名后的 IPA 通过受支持的 Apple 设备管理工具安装。证书和私钥放到受控的构建密钥管理中，勿发送到聊天或提交到仓库。

[ML Kit 手写识别指南](https://developers.google.com/ml-kit/vision/digital-ink-recognition) · [支持的语言模型](https://developers.google.com/ml-kit/vision/digital-ink-recognition/base-models) · [Flutter iOS 发布文档](https://docs.flutter.dev/deployment/ios) · [Apple TestFlight](https://developer.apple.com/testflight/)

## 网页版（云端 + 数据库）

在保留手机端本地存储不变的前提下，网页版使用「Flutter Web 前端 + FastAPI 后端 + PostgreSQL + 服务端手写识别」，部署到云服务器。

- **前端**：复用现有 Flutter 代码；网页端登录/注册、多孩子档案、孩子各自的听写进度存云端数据库。
- **后端**：`server/`（FastAPI）。数据模型见 `server/README.md`。
- **识别**：网页端把笔迹上传到 `POST /grade`，服务端栅格化后用 RapidOCR（onnxruntime 版 PP-OCR）识别；不确定时回退「待确认 + 家长订正」。
- **语音**：网页端使用浏览器 SpeechSynthesis 读题（依赖系统中文语音）。
- **部署**：见 `deploy/README.md`（Docker Compose + Caddy + HTTPS）。

### 构建网页版
```sh
flutter pub get --enforce-lockfile
flutter build web --release --no-pub   # 产物在 build/web
```

开发联调：`flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000`

