# Phos

**A native RAW photo editor for macOS, built for a personal, professional-grade workflow.**  
**为个人摄影流程打造的原生 macOS RAW 修图软件。**

Phos uses the `com.zeno.phos` application identifier. Existing `.rawforge.json` sidecars and the legacy
`Application Support/RawForge/presets.json` directory remain readable so existing edits are preserved.
Older releases may still use the former application and archive names.

![Build & Release](https://github.com/Zenodeng/Phos/actions/workflows/release.yml/badge.svg)

![Release](https://img.shields.io/github/v/release/Zenodeng/Phos)

![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)

![License](https://img.shields.io/badge/license-MIT-green)

🌐 **Showcase & UI design:** [zenodeng.github.io/Phos](https://zenodeng.github.io/Phos/) · **界面设计展示页**

![Phos — 工作台（深色外观）· Workspace, dark](https://zenodeng.github.io/Phos/images/01-workspace-dark.jpg)

<p align="center">
  <img src="https://zenodeng.github.io/Phos/images/02-workspace-light.jpg" width="32%" alt="Phos — 工作台（浅色外观）· Workspace, light">
  <img src="https://zenodeng.github.io/Phos/images/03-inspector-detail.jpg" width="32%" alt="Phos — 检视器：影调、白平衡、胶片 CLUT、曲线 · Inspector">
  <img src="https://zenodeng.github.io/Phos/images/04-export-dialog.jpg" width="32%" alt="Phos — 导出：格式、位深、色彩空间、水印 · Export">
</p>

> 工作台（深色 / 浅色）· 检视器五分类 · 导出与批量。更多界面见[设计展示页](https://zenodeng.github.io/Phos/)。
> Workspace (dark / light) · five-tab inspector · export & batch. See the [showcase page](https://zenodeng.github.io/Phos/) for more.

---

## English

### Overview

Phos is a non-destructive RAW photo editor written in Swift on top of Core Image, Vision and AppKit. It runs entirely on the local machine: no cloud services, no accounts, no subscription. Every pixel operation is executed on the GPU, and no third-party dependencies are used.

The project deliberately favours a small, complete set of high-frequency editing capabilities over breadth of features. All edits are stored in a sidecar file next to the original image, and the original file is never modified.

### Requirements

| Item             | Requirement                                                         |
| ---------------- | ------------------------------------------------------------------- |
| OS               | macOS 15.0 or later                                                 |
| CPU              | Apple silicon (arm64)                                               |
| Supported inputs | RAW (ARW / CR3 / NEF / …), HEIF / HEIC / HIF, JPEG, PNG, TIFF, AVIF |
| Signing          | Ad-hoc (free); Apple notarisation is **not** available              |

### Installation

1. Download `Phos-macOS-apple-silicon.zip` from [Releases](https://github.com/Zenodeng/Phos/releases).
2. Verify integrity against `SHA256.txt`:
   ```sh
   shasum -a 256 Phos-macOS-apple-silicon.zip
   ```
3. Unzip and move `Phos.app` to `/Applications`.
4. **The first launch is blocked by macOS — this is expected** (the app is not notarised).
   - Either open it once, then go to *System Settings → Privacy & Security*, scroll to the bottom and choose **Open Anyway**;
   - or remove the quarantine attribute:
     ```sh
     xattr -dr com.apple.quarantine /Applications/Phos.app
     ```

> [!IMPORTANT]  
> **App Sandbox is intentionally not enabled.** Under ad-hoc signing, entitlements are not bound correctly; enabling the sandbox would break folder access and sidecar writing. The repository contains no entitlements file, and none should be added.

### Building from source

```sh
git clone https://github.com/Zenodeng/Phos.git
cd Phos
./Scripts/package_app.sh      # builds Phos.app in the repository root
./build.sh                    # compiles and creates Phos.app in the repository root
```

`Scripts/package_app.sh` compiles the sources with `swiftc` directly, and retries with an older SDK if the default SDK is newer than the installed compiler. A `Package.swift` is provided for use with SwiftPM-aware editors; the release pipeline does not depend on it.

### Performance regression tests

Run `bash Scripts/test_performance.sh` on macOS with access to system graphics services.
Set `RF_SDK` if your SDK is in a different location. The tests use generated images in temporary
directories, check bounded caches and coalesced work scheduling, and exercise photo switching,
thumbnail orientation, final preview pixels, undo/redo, resolution changes and asynchronous export.
The render suite checks for nonblank output; pass a baseline pixel directory as the script's first
argument to require byte-identical rendering and curve LUT data. RAW camera samples and Vision
subject/person segmentation still require separate real-photo testing.

Workflow tests need two real photos (a normal shot and a flat print/scan copy):

```sh
bash Scripts/test_workflow.sh <photo> <flat-copy> [more photos...]
```

They copy everything into a temporary directory and assert that the originals are unchanged.

### Features

**2.0 workflow additions** — Select thumbnails for grouped adjustment synchronization (geometry
and masks are excluded by default), copy adjustments, sample a neutral point for white balance,
display/refine masks with additive and erasing brushes, save named per-photo snapshots, and export
8/16-bit TIFF in sRGB, Display P3 or Adobe RGB. Each batch target receives a pre-sync recovery snapshot.
New sidecars include the original file extension; legacy sidecars remain readable and are not deleted.

**Performance rework** — Preview rendering is coalesced into a single task (expired results are discarded when switching photos or precision), mask sliders write to the sidecar once on release, folder scanning / full-image decoding / before-after comparison / single-photo export moved off the main thread, and every cache (source image, curves, film LUTs, HSL, range masks, AI and depth masks) is bounded and concurrency-safe. The 2200px default preview, full-pixel/1:1 mode, 64³ curve LUT and full-resolution export pipeline are unchanged.

**Editing pipeline** — White balance, exposure, contrast, highlights/shadows, whites/blacks, texture, clarity, dehaze, vibrance, saturation, and an HDR mode with a limit control.

**Tone curves** — Free-form point curves (any number of control points, draggable in both axes) across five independent channels: composite, luminance, and R / G / B. Monotone cubic interpolation (Fritsch–Carlson) guarantees that the curve passes through every control point without overshoot. A *Refine Sat* control restores saturation after tonal changes. All five curves are baked into a single 64³ LUT.

**Colour tools** — HSL mixer across eight hue bands; colour grading with Lightroom-style wheels for shadows, midtones and highlights (hue, saturation, luminance, blend and balance); camera calibration via RGB primary adjustments, implemented as a row-normalised 3×3 matrix.

**Detail** — Sharpening with amount, radius, detail and masking; dual-channel luminance and colour noise reduction; film grain; halation (highlight extraction, wide-radius blur, warm tint, screen blend).

**Local adjustments / masking** — Linear and radial gradients, brush, colour range, luminance range, subject selection, person segmentation, foreground cut-out, and a depth-painting mask for bokeh. Vision-based masks run entirely on-device and are cached per mask and canvas size.

**Geometry** — Interactive crop overlay with eight handles, aspect-ratio presets, 90° rotation, mirroring, horizon auto-straightening (Vision horizon detection plus maximum-inscribed-rectangle cropping), automatic perspective correction from a detected quadrilateral, manual vertical and horizontal perspective, lateral chromatic aberration correction, and purple-fringe suppression.

**Multi-exposure** — Frame alignment via Vision registration with a quality gate (frames whose overlap NCC scores below 0.7 are dropped), selectable translation or homography alignment, and three modes: average, fusion, and hand-held denoise (pixel-wise averaging that rejects pixels deviating from the reference frame by more than *kσ*). Results are produced at full resolution as 16-bit TIFF and can be edited further.

**Workflow** — Sidecar-based non-destructive editing (`<image>.rawforge.json`), 200-step undo, presets, an export panel with format (JPEG / PNG / TIFF / HEIC), long-edge sizing, quality controls and an optional watermark (text or logo image with 9-grid placement, size, opacity, rotation and margin), batch export applying each image's own sidecar, cut-out export with a transparent background, 303 built-in HALD film-emulation LUTs, and an adaptive light/dark interface theme.

### Keyboard shortcuts

| Action                     | Shortcut |
| -------------------------- | -------- |
| Open folder                | ⌘O       |
| Crop and geometry          | ⌘R       |
| Export current photo       | ⌘E       |
| Before / after comparison  | ⌘B       |
| Multi-exposure compositing | ⇧⌘M      |
| Undo / Redo                | ⌘Z / ⇧⌘Z |

### Architecture

| File                               | Responsibility                                                                            |
| ---------------------------------- | ----------------------------------------------------------------------------------------- |
| `Sources/Phos/Engine.swift`    | Decoding, the full adjustment pipeline, LUT construction, masking, Vision-backed analysis |
| `Sources/Phos/Alignment.swift` | Frame registration, quality gating, canvas normalisation for compositing                  |
| `Sources/Phos/Models.swift`    | Parameter model and tolerant decoding for forward compatibility                           |
| `Sources/Phos/AppMain.swift`   | Application state, render scheduling, undo stack, export and batch processing             |
| `Sources/Phos/Performance.swift` | Bounded thread-safe caches and latest-request background scheduling                    |
| `Sources/Phos/Workflow.swift`    | Batch synchronisation, snapshots, grey-point sampling, sidecar migration               |
| `Sources/Phos/WorkflowViews.swift` | Workflow panels: sync targets, snapshots, bit-depth and colour-space controls        |
| `Sources/Phos/Views.swift`     | Browser, canvas, crop overlay, toolbars                                                   |
| `Sources/Phos/Inspector.swift` | Adjustment panels, curve editor, colour wheels                                            |
| `Sources/Phos/Theme.swift`     | Adaptive colour palette                                                                   |
| `Sources/Phos/CLUT.swift`      | Film LUT loading and baking                                                               |

The application is non-destructive by design: all parameters are serialised to a sidecar file, and rendering is a pure function of (source image, parameters).

### Release pipeline

`.github/workflows/release.yml` builds, packages and publishes on GitHub Actions macOS runners. Pushing a `v*` tag produces a release containing the zip and its SHA256, and the workflow can also be dispatched manually from the Actions tab.

> Before the first run, make sure *Settings → Actions → General → Workflow permissions* is set to **Read and write permissions**; otherwise uploading release assets returns 403.

### License

Released under the [MIT License](LICENSE).

---

## 中文

### 概述

Phos 是一款用 Swift 编写、基于 Core Image、Vision 与 AppKit 的**非破坏性 RAW 修图软件**。它完全在本机运行：不联网、无账号、无订阅。全部像素处理在 GPU 上完成，不依赖任何第三方库。

项目刻意选择「把高频能力做全做透」而非堆砌功能。所有调整写入原图旁边的副档，**原始文件一个字节都不会被修改**。

### 运行要求

| 项目   | 要求                                                          |
| ---- | ----------------------------------------------------------- |
| 系统   | macOS 15.0 及以上                                              |
| 芯片   | Apple silicon（arm64）                                        |
| 支持格式 | RAW（ARW / CR3 / NEF 等）、HEIF / HEIC / HIF、JPEG、PNG、TIFF、AVIF |
| 签名   | ad-hoc 本地签名（免费），**未做 Apple 公证**                             |

### 安装

1. 从 [Releases](https://github.com/Zenodeng/Phos/releases) 下载 `Phos-macOS-apple-silicon.zip`。
2. 校验完整性：
   ```sh
   shasum -a 256 Phos-macOS-apple-silicon.zip
   ```
   与 Release 中的 `SHA256.txt` 比对。
3. 解压后把 `Phos.app` 拖进 `/Applications`。
4. **首次打开会被 macOS 拦截，这是正常现象**（应用未公证）：
   - 双击打开一次 → 系统设置 → 隐私与安全性 → 滚到底 → 点「仍要打开」；
   - 或直接去除隔离标记：
     ```sh
     xattr -dr com.apple.quarantine /Applications/Phos.app
     ```

> [!IMPORTANT]  
> **本项目不启用 App Sandbox。** 免费 ad-hoc 签名下 entitlements 不会正确 bind，一旦 sandbox 生效，读取照片文件夹与写入 `.rawforge.json` 旁挂会全部失效。仓库中没有任何 entitlements 文件，也请不要添加。

### 从源码构建

```sh
git clone https://github.com/Zenodeng/Phos.git
cd Phos
./Scripts/package_app.sh      # 在仓库根目录打出 Phos.app
./build.sh                    # 编译并在仓库根目录生成 Phos.app
```

`Scripts/package_app.sh` 直接用 `swiftc` 编译，并在默认 SDK 比编译器新时自动回退到较旧 SDK。仓库同时提供 `Package.swift` 供支持 SwiftPM 的编辑器使用，但发布流程不依赖它。

### 性能回归测试

运行 `bash Scripts/test_performance.sh`，需要 macOS 系统图形服务权限，可通过 `RF_SDK` 指定 SDK。
测试仅在临时目录生成图片，覆盖缓存容量/并发、任务合并、快速切图、缩略图方向、最终预览像素、
撤销重做、精度切换和后台导出。可将基准像素目录作为第一个参数，逐字节比较渲染结果及曲线 LUT。
测试会拒绝空白渲染结果；真实相机 RAW 和 Vision 主体/人物识别还需要单独用实拍照片验证。

### Studio 完整回归

运行：

```sh
bash Scripts/test_studio.sh <fixture-image> <output-directory> [render-baseline-directory]
```

脚本覆盖 Studio 深浅色布局、1100/1680 窗口尺寸、五个检视器分类、导出弹窗、性能回归和
14 组渲染用例。传入基准目录时会逐字节比较 `.rgba` / `.cube` 输出；图片路径不是基准目录。

### 实拍照片与图库压力测试

运行：

```sh
bash Scripts/test_real_photos.sh <output-directory> <soak-seconds> <photo> [more-photos...]
```

测试真实照片解码、方向、导出、Vision 蒙版、原片 SHA256 完整性，并将代理图扩展为 1000 张
图库执行切图、编辑、撤销和重做压力测试。Vision 返回结果需要结合实际照片目视判断，代理图库
压力测试不等同于全尺寸 RAW 图库的长时间 endurance 测试。

### 功能

**2.0 工作流增强** — 缩略图勾选、Command/Shift 多选、分组同步与复制调整（默认不复制裁剪/蒙版）；
灰点白平衡吸管；实际蒙版覆盖、添加/擦除画笔；命名快照的保存/重命名/恢复；8/16 位 TIFF 与
sRGB / Display P3 / Adobe RGB 输出。批量同步自动保存目标照片的恢复快照，新副档保留原扩展名，
旧副档继续兼容读取且不删除。

实图测试：`bash Scripts/test_workflow.sh <实拍照片路径> <实拍纸面照片路径> [其他照片...]`。
测试仅在临时目录生成副本和结果，并检查原照片没有被修改。

**性能重做** — 预览合并为单任务（切图、切换精度时丢弃过期结果），蒙版滑块仅在松手时写一次副档，文件夹扫描 / 原图解码 / 前后对比 / 单张导出均移到后台线程，全部缓存（原图、曲线、胶片 LUT、HSL、范围蒙版、AI / 深度蒙版）都有容量上限与并发保护。2200px 默认预览、全像素 / 1:1 模式、64³ 曲线 LUT 与全分辨率导出管线保持不变。

**调整管线** — 白平衡、曝光、对比、高光 / 阴影、白色 / 黑色、纹理、清晰度、去朦胧、鲜艳度、饱和度、HDR 模式（含强度上限）。

**色调曲线** — 自由控制点曲线（点数任意、横竖均可拖），五个独立通道：合成、亮度、R / G / B。控制点之间采用单调三次插值（Fritsch–Carlson），**严格过点且不过冲**。*Refine Sat* 在改变调子后把饱和度拉回。五条曲线一次烘进 64³ LUT。

**色彩工具** — 8 个色相分区的 HSL 混色器；Lightroom 式颜色分级色轮（阴影 / 中间调 / 高光，含色相、饱和、明亮度、混合与平衡）；校准面板通过 RGB 三原色调整实现（行归一化 3×3 矩阵，保证白点不变形）。

**细节** — 锐化（数量 / 半径 / 细节 / 蒙版）；亮度与颜色双通道降噪；胶片颗粒；Halation 光晕（高光提取 → 大半径模糊 → 暖色染色 → 屏幕混合）。

**局部调整（蒙版）** — 线性渐变、径向渐变、画笔、颜色范围、亮度范围、选择主体、选择人物、主体抠图，以及用于焦外散景的深度涂绘。基于系统视觉模型的蒙版全部在本机计算，并按「蒙版 + 画幅尺寸」缓存。

**几何与镜头** — 画布交互裁剪（八向手柄、画幅预设）、90° 旋转、镜像、地平线自动校直（Vision 检测倾角 + 最大内接矩形裁切）、自动透视校正（检测四边形后交给透视校正）、手动垂直 / 水平透视、横向色差校正、紫边抑制。

**多重曝光** — Vision 配准的帧对齐与质量门（重叠区 NCC 低于 0.7 的帧自动剔除），对齐方式可选平移或透视（homography），三种模式：平均、曝光融合、手持降噪（逐像素平均，偏离参考帧超过 *kσ* 的像素按参考值取，压噪同时去鬼影）。合成结果按全分辨率输出 16 位 TIFF，并可继续调整。

**工作流** — 副档非破坏编辑（`<原图名>.rawforge.json`）、200 步撤销、预设、导出面板（格式 JPEG / PNG / TIFF / HEIC、长边尺寸、质量、可选水印：文字或 logo 图片，九宫格定位 + 大小 / 不透明度 / 旋转 / 边距）、批量导出（套用每张照片各自的调整）、透明背景抠图导出、内置 303 个 HALD 胶片模拟 LUT、浅色 / 深色自适应界面主题。

### 快捷键

| 操作      | 快捷键      |
| ------- | -------- |
| 打开文件夹   | ⌘O       |
| 裁剪与几何   | ⌘R       |
| 导出当前照片  | ⌘E       |
| 前后对比    | ⌘B       |
| 多重曝光合成  | ⇧⌘M      |
| 撤销 / 重做 | ⌘Z / ⇧⌘Z |

### 架构

| 文件                                 | 职责                       |
| ---------------------------------- | ------------------------ |
| `Sources/Phos/Engine.swift`    | 解码、完整调整管线、LUT 构建、蒙版、视觉分析 |
| `Sources/Phos/Alignment.swift` | 帧配准、质量门、合成画幅归一化          |
| `Sources/Phos/Models.swift`    | 参数模型与宽容解码（向前兼容旧副档）       |
| `Sources/Phos/AppMain.swift`   | 应用状态、渲染调度、撤销栈、导出与批处理     |
| `Sources/Phos/Performance.swift` | 有界线程安全缓存、最新请求后台调度       |
| `Sources/Phos/Workflow.swift`    | 批量同步、快照、灰点取样、副档迁移          |
| `Sources/Phos/WorkflowViews.swift` | 工作流面板：同步目标、快照、位深与色彩空间控件  |
| `Sources/Phos/Views.swift`     | 浏览器、画布、裁剪叠加层、工具条         |
| `Sources/Phos/Inspector.swift` | 调整面板、曲线编辑器、色轮            |
| `Sources/Phos/Theme.swift`     | 自适应调色板                   |
| `Sources/Phos/CLUT.swift`      | 胶片 LUT 读取与烘焙             |

设计上不可变：所有参数序列化到副档，渲染是关于「源图 + 参数」的纯函数。

### 发布流程


`.github/workflows/release.yml` 在 GitHub Actions 的 macOS 运行器上编译、打包并发布。推送 `v*` 标签会生成 Release（含 zip 与 SHA256），也可在 Actions 页面手动触发。

> 首次使用前请确认仓库 Settings → Actions → General → Workflow permissions 已设为 **Read and write permissions**，否则 Release 上传会返回 403。

### 许可证

以 [MIT 许可证](LICENSE) 发布。
