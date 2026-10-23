# Tugi 图叽

**一个完全离线的 Android 图片 / 动图 / 视频小工具台。**

12 个功能，全部在本机用 ffmpeg 完成：不上传、不注册、不需要网络就能处理媒体。
Flutter 实现，GPL-3.0-or-later。

<p align="left">
  <img alt="platform" src="https://img.shields.io/badge/platform-Android-3DDC84?logo=android&logoColor=white">
  <img alt="flutter" src="https://img.shields.io/badge/Flutter-3.35%2B-02569B?logo=flutter&logoColor=white">
  <img alt="license" src="https://img.shields.io/badge/license-GPL--3.0--or--later-blue">
  <img alt="offline" src="https://img.shields.io/badge/network-none-black">
</p>

> 英文简介见文末 [English](#english)。

---

## 目录

- [功能](#功能)
- [设计原则](#设计原则)
- [架构](#架构)
- [目录结构](#目录结构)
- [构建](#构建)
- [测试](#测试)
- [已知限制](#已知限制)
- [制作](#制作)
- [授权与第三方](#授权与第三方)

## 功能

首页按四组横向分页：

| 分组 | 功能 |
|---|---|
| **转换** | Format Convert（图片 / 动图 / 视频 / 音频互转）、Extract Audio（视频取音轨）、Images to Video（多图合成视频）、**Scramble 混淆**（马赛克色块 / 逐像素 / 强混淆 / 希尔伯特，四种可逆打乱，同一密码无损还原） |
| **GIF** | Video to GIF、Images to GIF、Edit GIF（变速 / 倒放 / 剪切）、GIF to Video、GIFs to Images（拆帧）、Compress GIFs（缩放 / 抽帧 + 体积预估） |
| **图片** | Add watermark（文字 / 图片 / GIF 水印，可叠多层、批量）、Edit Image（裁剪、旋转、调色、压缩、双指缩放预览） |
| **作品** | 每次导出 + 原图索引；按时间 / 大小排序、检索；全屏预览（缩放、左右滑动）、分享、用系统应用打开；容量统计与「保留最近 N 个」清理 |

其他：全文搜索、收藏、「上次使用」胶囊；背景可选纯色 / 网格渐变流动 / 图片（含透明度）；
主题色可用色盘自选并保存；音频导出走系统保存对话框；中文文本选择菜单。

### 支持的格式

由本机 ffmpeg 能力**运行时探测**，写不了的格式置灰并说明原因：

| 类型 | 容器 / 编码 |
|---|---|
| 图片 | PNG、JPEG、WebP、AVIF、GIF、APNG、BMP、TIFF、JPEG 2000、QOI、ICO、TGA、EXR、PAM、PPM |
| 动图 | GIF、APNG |
| 视频 | MP4（H.264 / H.265）、WebM（VP9）、MKV、MOV、AVI |
| 音频 | M4A/AAC、MP3、FLAC、OGG（Vorbis）、Opus、WAV |

## 设计原则

1. **离线是硬约束**，不是卖点：代码里没有网络调用，权限表里没有 `INTERNET`。
2. **不写死格式清单**：启动时读 ffmpeg 的 `-encoders` / `-muxers`，能力决定 UI。
3. **命令是纯函数**：每个 ffmpeg 调用都由 `lib/ffmpeg/commands.dart` 里的纯函数产出
   `List<String>`，可以脱离运行时做 argv 级单测——这是整个项目最重要的可测性设计。
4. **进度是算出来的，不是猜的**：异步任务拿 ffmpeg 自己的 statistics（已处理时长 / 总时长），
   长度未知时显示不确定进度，不假装 0% 或 100%。
5. **失败要说人话**：ffmpeg 的 stderr 会被摘要成可读原因，而不是整段贴给用户。

## 架构

```
screens/    界面与状态：读取输入、调用服务、渲染、错误提示
   │
services/   业务编排：IO、导出路由、进度与取消、失败归一化
   │
ffmpeg/     argv 纯函数构建器（无运行时依赖，可单测）
   │
ffmpeg_kit  full-gpl 运行时
```

**几个关键实现**

- **异步 + 进度 + 取消**：`runWithProgress(args, totalMs:, onProgress:)` 返回一个 `FfmpegJob`，
  内部在 complete 回调里结算 `ReturnCode`（直接 `session.getReturnCode()` 会拿到 null），
  `cancel()` 走 ffmpeg-kit 的 `session.cancel()`，取消后统一抛 `FfmpegCancelled`，
  调用方不留下半成品文件。
- **裁剪是归一化坐标**：裁剪框存 0..1 的四边，导出时才换算成偶数像素的 `crop=w:h:x:y`，
  并且放在 filter 链最前面——编码器看不到被裁掉的像素，所以不会浪费码率。
- **剪切**：视频走 `-ss/-t` 快速定位；GIF 走 `trim` + 重定基准 `setpts`（否则保留段会带前段空白）。
- **混淆（Scramble）**：密码经 FNV-1a 得 64 位种子，xorshift64 驱动置换。
  马赛克模式按块搬运（可调 8–40 px 块），其余模式逐像素 Fisher–Yates + RGB keystream；
  alpha 不参与异或；大图在 isolate 里算。四种模式都可逆且**逐字节还原**。
- **保存路由**：图片 / 视频进相册（`gal`），音频走系统 `ACTION_CREATE_DOCUMENT`
  （相册装不下音频），相册被拒时自动回退到保存对话框。

## 目录结构

```
lib/
  screens/          界面：首页 + 12 个功能 + 作品 + 预览
  services/         编排层：转换、水印、压缩、导出路由、作品区、设置
  ffmpeg/           argv 纯函数构建器
  models/           数据模型与预设
  ui/               设计系统：tokens、配色、时间轴、裁剪框、进度、动效
  utils/            纯算法（图片混淆、体积估算、时间格式化）
packages/format_core/   纯 Dart 格式注册表，可单独 dart test
test/               宿主测试（命令形状 / 服务 / 界面 / 算法）
integration_test/   真机集成测试（ffmpeg 实跑）
tool/               构建脚本、图标生成、格式探测
docs/               设计文档
```

## 构建

需要 Flutter 3.35+（本项目在 3.47 / Dart 3.13 验证）与 Android SDK 35+。

```bash
flutter pub get
bash tool/build_release.sh      # 混淆 + 符号分离，产物在 build/app/outputs/flutter-apk/
```

- `build/symbols/` 是崩溃符号表：发布时与 APK 一起归档，**不要提交**，也不要打进 APK。
- 首次构建会拉取 ffmpeg-kit **full-gpl**（libx264 / libx265 / libvpx / libwebp / …），
  APK 约 230 MB。想减小体积可换 `min-gpl` 或自行裁剪，代价是部分格式消失（应用会自动置灰）。
- 默认只发 arm64-v8a / armeabi-v7a；需要在模拟器上跑时自行打开 ABI 过滤。

## 测试

```bash
# 纯 Dart 的格式注册表
cd packages/format_core && dart test

# 宿主测试：argv 形状、服务、界面、算法
flutter test test/ffmpeg test/convert test/services test/ui test/utils

# 真机：28 个格式逐个转换并校验 codec
flutter test integration_test/ffmpeg/convert_matrix_device_test.dart
```

覆盖重点：argv 形状（纯函数）、格式矩阵、保存路由、设置迁移与损坏数据、
手势冲突（滑块 / 画布 / 选择手柄）、作品区排序与检索、混淆往返、
「未就绪按钮必须是浅色」这条视觉规则。

## 已知限制

- **仅 Android**。工程里有 iOS 目录但未验证，也没做相应适配。
- 混淆是**可逆打乱，不是加密**：安全性取决于密码强度，别拿它保护真正机密的东西。
- 视频压缩档位（x264 CRF / preset）只做了相对比较，没有公开的耗时 - 体积对照表。
- 中文界面是主要的，英文只覆盖了 README。

## 制作

**本项目完全由 DeepSeek（大肥鱼）设计与实现。**

界面、算法、测试、文档与发布脚本均由该 AI 在人工指导下完成；
没有沿用任何第三方应用的代码或资源，图标与背景插画为本项目自绘 / 生成。

如果它对你有用，点个 Star 就是最好的支持。

## 授权与第三方

- **GPL-3.0-or-later**，见 [LICENSE](LICENSE)。
- 第三方组件清单见 [THIRD_PARTY.md](THIRD_PARTY.md)，署名见 [NOTICE](NOTICE)，
  源码文件带 SPDX 标识。
- 依赖 [ffmpeg-kit](https://github.com/arthenica/ffmpeg-kit) 的 full-gpl 变体；
  GPL 组件使整个应用必须以 GPL 发布。
- 字体：Noto Sans SC / Noto Serif SC（SIL OFL 1.1）。
- 安全策略与漏洞报告方式见 [SECURITY.md](SECURITY.md)。

---

## English

**Tugi** is a fully offline Android toolbox for images, GIFs and video, written in
Flutter. Every operation runs on-device through ffmpeg — no uploads, no account, and
no network permission at all.

Twelve tools: format conversion across 15 image / 7 audio / 6 video containers,
audio extraction, video ↔ GIF/APNG, frame extraction, GIF compression with size
estimates, layered watermarks, an image editor with a pinch-zoom viewport, a
reversible image scrambler (mosaic tiles or per-pixel shuffling, restored with a
password), and a "works" shelf indexing every export together with its source file.

Design in one line: screens call services, services call pure argv builders, and
ffmpeg-kit executes them — so every command shape is unit-testable and every export
reports real progress with a working cancel.

The UI is Chinese-first; code, tests and commit messages are English.

```bash
flutter pub get
bash tool/build_release.sh
flutter test test/ffmpeg test/convert test/services test/ui test/utils
```

Licensed **GPL-3.0-or-later**; the bundled ffmpeg-kit full-gpl is the reason.

Made entirely by **DeepSeek (大肥鱼)**.
