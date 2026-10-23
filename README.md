<p align="center">
  <img src="assets/brand/app_icon_256.png" width="120" height="120" alt="Tugi">
</p>

<h1 align="center">Tugi 图叽</h1>

<p align="center"><b>一个完全离线的 Android 图片 / 动图 / 视频小工具台。</b></p>

<p align="center">
12 个功能，全部在本机用 ffmpeg 完成：不上传、不注册、不需要网络就能处理媒体。<br>
Flutter 实现，GPL-3.0-or-later。
</p>

<p align="center">
  <a href="https://github.com/mikuqwh/tugi/releases/latest"><img alt="download" src="https://img.shields.io/badge/%E4%B8%8B%E8%BD%BD-APK-2ea44f?logo=android&logoColor=white"></a>
  <img alt="platform" src="https://img.shields.io/badge/Android-7.0%2B-3DDC84?logo=android&logoColor=white">
  <img alt="flutter" src="https://img.shields.io/badge/Flutter-3.35%2B-02569B?logo=flutter&logoColor=white">
  <img alt="license" src="https://img.shields.io/badge/license-GPL--3.0--or--later-blue">
  <img alt="tests" src="https://img.shields.io/badge/host%20tests-510%20passed-brightgreen">
  <img alt="network" src="https://img.shields.io/badge/network-none-black">
</p>

<p align="center"><a href="README.en.md">English</a> · <b>中文</b></p>

---

<a id="toc"></a>
## 目录

- [下载安装](#download)
- [它能做什么](#features)
- [为什么是"离线"](#why-offline)
- [设计原则](#principles)
- [架构](#architecture)
- [技术栈](#stack)
- [目录结构](#layout)
- [构建](#build)
- [测试](#testing)
- [性能与体积](#performance)
- [常见问题](#faq)
- [路线图](#roadmap)
- [参与贡献](#contributing)
- [安全](#security)
- [授权与第三方](#license)
- [制作](#credits)

---

<a id="download"></a>
## 下载安装

👉 **[最新 Release](https://github.com/mikuqwh/tugi/releases/latest)**

| 文件 | 适用 | 大小 |
|---|---|---|
| `app-arm64-v8a-release.apk` | 绝大多数现代手机 | 70.8 MB |
| `app-armeabi-v7a-release.apk` | 老旧 32 位设备 | 104.6 MB |
| `app-x86_64-release.apk` | 模拟器 | 78.5 MB |

安装步骤：

1. 按架构下载 APK（不确定就选 arm64，2017 年后的手机基本都是）；
2. 点开安装，系统提示「未知来源」时允许；
3. 打开即用，没有引导页、没有登录、没有首次下载。

> 当前包用**调试密钥**签名：能装能用，但不能覆盖安装其他来源的同包名版本，也不能上架商店。
> 想自己发版，按 [`android/key.properties.example`](android/key.properties.example) 配一个 keystore 重新构建。

要求 **Android 7.0（API 24）** 及以上。

---

<a id="features"></a>
## 它能做什么

首页按四组横向分页，长按任意功能可收藏。

### 转换

| 功能 | 说明 | 细节 |
|---|---|---|
| **Format Convert** | 图片 / 动图 / 视频 / 音频互转 | 15 种图片、7 种音频、6 种视频容器，能力运行时探测，写不了的置灰并说明原因 |
| **Extract Audio** | 从视频里取音轨 | 编码一致时直接 `-c copy`，无损且瞬间完成；不一致才转码 |
| **Images to Video** | 多张图片合成视频 | 每张时长、输出宽度、容器（MP4 / WebM / MKV / MOV）可调 |
| **Scramble 混淆** | 把图片打乱，用密码还原 | 四种可逆模式：马赛克色块 / 逐像素 / 强混淆 / 希尔伯特；四者都逐字节还原 |

### GIF

| 功能 | 说明 | 细节 |
|---|---|---|
| **Video to GIF** | 截取视频转 GIF / APNG | 时间轴剪切、帧率、宽度、去重；速度质量三档 |
| **Images to GIF** | 多张图片合成动图 | 每张停留时长、输出宽度；支持 APNG |
| **Edit GIF** | 改 GIF | 变速、倒放、剪切；同样有速度质量三档 |
| **GIF to Video** | GIF 转视频 | MP4 / WebM / MKV，可指定帧率与宽度 |
| **GIFs to Images** | 拆帧 | 抽帧步长、输出格式、质量；可批量保存 |
| **Compress GIFs** | 压缩 GIF | 缩放 / 抽帧两种路径，带体积预估 |

### 图片

| 功能 | 说明 | 细节 |
|---|---|---|
| **Add watermark** | 加水印 | 文字 / 图片 / GIF 水印，最多 6 层，可批量；位置可拖动，越界会夹回画面内 |
| **Edit Image** | 图片编辑 | 裁剪、旋转、翻转、调色、预设滤镜、按目标体积压缩；双指缩放预览 |

### 作品

每次导出的文件和原图一起索引：按时间 / 大小排序、检索、全屏预览（缩放、左右滑动）、
分享、用系统应用打开、容量统计与「保留最近 N 个」清理。

### 其他

搜索（中英文关键词）、收藏、「上次使用」胶囊；背景可选纯色 / 网格渐变流动 / 图片（含透明度）；
主题色用色盘自选并持久化；中文文本选择菜单；音频导出走系统保存对话框。

---

<a id="why-offline"></a>
## 为什么是"离线"

不是宣传语，是权限表里的硬事实：应用**没有声明 `INTERNET` 权限**，代码里也没有任何 HTTP 客户端。
这意味着：

- 你的照片不会离开手机，连"可能上传"的可能性都不存在；
- 没有账号、没有埋点、没有崩溃上报（符号表在 `build/symbols/`，需要你手动取）；
- 换来的代价是包大：ffmpeg（full-gpl）全部塞进 APK。

媒体处理全部交给 ffmpeg 的 Android 构建（libx264 / libx265 / libvpx / libwebp / libass …），
UI 只负责参数和编排。

---

<a id="principles"></a>
## 设计原则

1. **命令是纯函数。** 每个 ffmpeg 调用都由 `lib/ffmpeg/commands.dart` 里的纯函数产出
   `List<String>`，不依赖运行时，因此可以脱离设备做 argv 级单测。这是整个项目最重要的可测性设计。
2. **能力决定 UI。** 启动时读 ffmpeg 的 `-encoders` / `-muxers`，不是写死格式清单；
   不支持的格式置灰，并告诉用户为什么。
3. **进度是算出来的。** 异步任务读 ffmpeg 自己的 statistics（已处理时长 / 总时长）；
   长度未知时显示不确定进度，不假装 0% 也不假装 100%。
4. **失败说人话。** stderr 会被摘要成一句可读原因，而不是整段日志。
5. **不为"看起来能用"妥协。** 按钮未就绪就是浅色；做不到的功能置灰并写清原因。

---

<a id="architecture"></a>
## 架构

```
┌─────────────────────────────────────────────────────────────┐
│ screens/          界面与状态：读取输入、调服务、渲染、报错     │
│                   首页 · 12 个功能 · 作品 · 全屏预览           │
└──────────────────────────┬──────────────────────────────────┘
                           │ 调用（不直接碰 ffmpeg）
┌──────────────────────────▼──────────────────────────────────┐
│ services/         业务编排                                   │
│   ffmpeg_progress.dart   async + statistics + cancel         │
│   *_service.dart         每个功能一条流水线                   │
│   export_service.dart    相册 / 系统保存对话框的路由           │
│   works_service.dart     作品索引与清理                       │
└──────────────────────────┬──────────────────────────────────┘
                           │ 纯函数
┌──────────────────────────▼──────────────────────────────────┐
│ ffmpeg/commands.dart       参数 → List<String>（可单测）      │
│ utils/                     纯算法：混淆、体积估算、时间格式化  │
└──────────────────────────┬──────────────────────────────────┘
                           │ executeAsync
┌──────────────────────────▼──────────────────────────────────┐
│ ffmpeg-kit full-gpl                                          │
└─────────────────────────────────────────────────────────────┘
```

**一条真实链路（Video → GIF）**

```
用户拖动时间轴
  └─ TrimRange(start, duration)                 归一化剪切区间
      └─ VideoToGifService.convertVideoToGif(args)
          ├─ ffmpeg.videoToGif(...)             → List<String>（纯函数，有单测）
          ├─ runWithProgress(args, totalMs)     → FfmpegJob
          │     ├─ onProgress: statistics.time / totalMs  → 进度条
          │     └─ cancel(): session.cancel()             → FfmpegCancelled
          └─ ExportService.save(path)           → 相册（失败回退到保存对话框）
              └─ WorksService.record(...)       → 作品区索引
```

**几个关键实现**

- **异步进度与取消**：`runWithProgress()` 在 complete 回调里结算 `ReturnCode`
  （直接 `session.getReturnCode()` 会拿到 null，这是 ffmpeg-kit 的坑），
  取消统一抛 `FfmpegCancelled`，调用方清理半成品文件。
- **裁剪**：裁剪框存 0..1 的四边，导出时才换算成偶数像素的 `crop=w:h:x:y`，
  并放在 filter 链最前面——编码器看不到被裁掉的像素，不浪费码率。
- **剪切**：视频走 `-ss/-t`；GIF 走 `trim` + 重定基准 `setpts`（否则保留段会带前段空白）。
- **混淆**：密码 → FNV-1a 64 位种子 → xorshift64 驱动置换。马赛克按整块搬运（可调 8–40 px），
  逐像素模式是 Fisher–Yates + RGB keystream；alpha 不参与异或；大图在 isolate 里算。
  边缘不足一块的条带保持原样，这既是视觉习惯，也是往返无损的前提。
- **保存路由**：图片 / 视频进相册（`gal`），音频走系统 `ACTION_CREATE_DOCUMENT`，
  相册被拒时自动回退。

---

<a id="stack"></a>
## 技术栈

| 层 | 选型 |
|---|---|
| 框架 | Flutter 3.47 / Dart 3.13（Material 3） |
| 媒体 | [ffmpeg-kit](https://github.com/arthenica/ffmpeg-kit) `ffmpeg_kit_flutter_new` 8.0.0（full-gpl） |
| 相册 | `gal` |
| 选图 | `image_picker` |
| 分享 | `share_plus` |
| 路径 | `path_provider` |
| 字体 | Noto Sans SC / Noto Serif SC（watermark 的 `drawtext` 需要实体字体文件） |
| 唯一原生代码 | 一个 MethodChannel：`ACTION_CREATE_DOCUMENT` 保存 + FileProvider 打开文件 |

---

<a id="layout"></a>
## 目录结构

```
lib/
  screens/          14 个界面：首页、12 个功能、作品、预览
  services/         编排层：转换、水印、压缩、导出路由、作品区、设置持久化
  ffmpeg/           argv 纯函数构建器（commands / convert / audio / pipeline）
  models/           数据模型、编码档位、裁剪矩形、格式描述
  ui/               设计系统：tokens、配色、时间轴、裁剪框、进度条、动效组件
  utils/            纯算法：图片混淆、体积估算、时间格式化
packages/format_core/   纯 Dart 格式注册表（无 Flutter 依赖，可单独 dart test）
test/               宿主测试：命令形状 / 服务 / 界面 / 算法
integration_test/   真机测试：ffmpeg 实跑、格式矩阵、手势回归
tool/               构建脚本、图标与背景生成、格式探测
docs/               设计文档（按时间顺序，记录"为什么"）
```

---

<a id="build"></a>
## 构建

需要 Flutter 3.35+（本项目在 3.47 / Dart 3.13 验证）与 Android SDK 35+。

```bash
git clone https://github.com/mikuqwh/tugi.git
cd tugi
flutter pub get

# 单包（约 230 MB）
flutter build apk --release

# 或按 ABI 拆分（推荐，发布用）
flutter build apk --release --split-per-abi
```

- 首次构建会拉取 full-gpl 的 ffmpeg 依赖，产物较大属正常。
- `build/symbols/` 是崩溃符号表：发布时与 APK 一起归档，**不要提交**，也不要打进 APK。
- 正式签名：复制 [`android/key.properties.example`](android/key.properties.example) 为
  `android/key.properties` 并填好，构建脚本会自动使用；没有它则回退到调试密钥。
- 想减小体积可换 `min-gpl` 变体，代价是部分格式消失（应用会自动置灰）。

---

<a id="testing"></a>
## 测试

```bash
# 纯 Dart 的格式注册表
cd packages/format_core && dart test

# 宿主测试：510 个
flutter test test/ffmpeg test/convert test/services test/ui test/utils

# 真机：28 个格式逐个转换并校验 codec
flutter test integration_test/ffmpeg/convert_matrix_device_test.dart
```

| 套件 | 覆盖什么 |
|---|---|
| `test/ffmpeg` | argv 形状：每个命令的参数顺序与取值（纯函数，最快） |
| `test/convert` | 格式能力探测、注册表一致性 |
| `test/services` | 导出路由、作品区、设置迁移与损坏数据、压缩算术 |
| `test/ui` | 界面状态：进度条、按钮就绪态、裁剪框、时间轴、混淆往返、空态 |
| `test/utils` | 体积估算、时间格式化、混淆算法（含逐字节还原） |
| `integration_test` | 真机实跑：格式矩阵、水印到边缘、保存、手势冲突 |

CI 在每次 push 上跑 `analyze + 510 个宿主测试 + debug APK 构建`；
Release 工作流按 ABI 构建并自动附到 tag。

---

<a id="performance"></a>
## 性能与体积

- **速度 / 质量三档**（30 秒 720p 素材实测）：快速档 746 KB、均衡 966 KB、高质量 972 KB；
  快速档耗时约为均衡的 2/3。
- **GIF 压缩**：缩放与抽帧两条路径，体积预估有损给区间、无损给像素算术。
- **APK 体积**：arm64 70.8 MB（其中 ffmpeg 约 55 MB），按 ABI 拆分后不会再翻倍。
- **启动**：首页无网络请求，冷启动只做一次 ffmpeg 能力探测（约 200 ms）。

---

<a id="faq"></a>
## 常见问题

**为什么 APK 这么大？**
ffmpeg full-gpl（x264 / x265 / vpx / webp / ass…）本身就占 50 MB 以上。换 `min-gpl` 能小一半，
但会丢掉一批格式。

**为什么提示"未知来源"？**
没有上架商店，APK 直装。系统对直装包都会提示，允许即可。

**为什么签名是调试密钥？**
仓库不包含发布证书（证书不该进公开仓库）。自己发版按 `key.properties.example` 配一个。

**混淆安全吗？**
它是**可逆打乱，不是加密**：安全性取决于密码强度，没有认证，也挡不住针对性攻击。
适合"防止被随手转发观看"，不适合保护机密。

**支持 iOS / 桌面吗？**
只有 Android 经过验证。仓库里的 iOS/桌面目录是 Flutter 脚手架，未适配。

**会联网吗？**
不会。没有 `INTERNET` 权限，装上之后连 DNS 都发不出去。

---

<a id="roadmap"></a>
## 路线图

- [ ] 视频压缩档位（x264 CRF / preset）的耗时-体积对照表
- [ ] GIF 逐帧编辑（删帧 / 换序 / 单帧时长）
- [ ] 批量重命名与导出模板
- [ ] 可选的本地 OCR / 去水印实验分支（保持离线）

---

<a id="contributing"></a>
## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。最重要的一条：**不要引入联网依赖**。

Bug 与需求请走 [Issues](https://github.com/mikuqwh/tugi/issues)；
安全相关问题请按 [SECURITY.md](SECURITY.md) 私下报告。

---

<a id="security"></a>
## 安全

- 无 `INTERNET` 权限，无遥测；
- 混淆功能是打乱不是加密，界面里也这么写；
- 文件只读用户主动选择的、只写到相册 / 系统保存对话框 / 自己的缓存；
- 详细威胁模型见 [SECURITY.md](SECURITY.md)。

---

<a id="license"></a>
## 授权与第三方

- **GPL-3.0-or-later**，见 [LICENSE](LICENSE)。
- 第三方组件清单 [THIRD_PARTY.md](THIRD_PARTY.md)，署名 [NOTICE](NOTICE)，源码文件带 SPDX 标识。
- 依赖 ffmpeg-kit 的 full-gpl 变体；GPL 组件使整个应用必须以 GPL 发布。
- 字体：Noto Sans SC / Noto Serif SC（SIL OFL 1.1）。
- 图标与背景插画由本项目自绘 / 生成（`tool/brand/`）。

---

<a id="credits"></a>
## 制作

**本项目完全由 DeepSeek（大肥鱼）设计与实现。**

界面、算法、测试、文档与发布脚本均由该 AI 在人工指导下完成；
没有沿用任何第三方应用的代码或资源。

如果它对你有用，点个 ⭐ 就是最好的支持。
