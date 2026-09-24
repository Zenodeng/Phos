# 更新日志 / Changelog

本项目遵循语义化版本。日期为发布日（Asia/Shanghai）。

## [1.1.0] — 2026-09-25

### 新增 / Added

- **多重曝光对齐**：基于 Vision 配准的帧对齐，带质量门（重叠区 NCC 低于 0.7 的帧自动剔除）；
  对齐方式可选「平移」或「透视（homography）」（`Alignment.swift`）。
- **手持降噪模式**：逐像素平均，偏离参考帧超过 *kσ* 的像素按参考值取，压噪同时抑制移动物体鬼影。
- **合成输入扩展**：支持按 ⌘ 多选照片加入合成，并可添加文件夹外的文件。
- **新蒙版类型**：「主体抠图」（前景抠图）与「深度涂绘」（为焦外散景提供深度来源）。
- **焦外散景**：按深度图虚化，深度来源可选人像 disparity 辅助数据或深度涂绘蒙版。
- **导出面板**：格式（JPEG / PNG / TIFF / HEIC）、长边尺寸、质量；支持仅导出已标记照片。
- **透明背景抠图导出**：使用主体抠图蒙版输出带透明通道的图像。
- **预设**：保存与套用调整预设。
- **自适应主题**：界面调色板跟随系统浅色 / 深色外观（`Theme.swift`）。
- **快捷键补全**：⌘O 打开文件夹、⌘E 导出当前照片、⌘R 裁剪、⌘B 前后对比、⇧⌘M 多重曝光、
  ⌘Z / ⇧⌘Z 撤销与重做。

### 变更 / Changed

- 工具条改为图标化，状态与操作提示集中到工具条与状态栏。
- 多重曝光相关操作整合进统一入口，参数与撤销行为对齐其余调整。

### 修复 / Fixed

- 合成分支的边界情况：对齐质量门后有效帧不足时给出明确提示，不再静默失败。

---

## [1.0.0] — 2026-09-24

### 首个公开发布 / Initial public release

- 非破坏性编辑：参数写入 `<原图名>.rawforge.json` 旁档，原文件不改动；200 步撤销。
- 调整管线：白平衡、曝光、对比、高光 / 阴影、白色 / 黑色、纹理、清晰度、去朦胧、鲜艳度、
  饱和度、HDR 模式。
- 色调曲线：自由控制点曲线，合成 / 亮度 / R / G / B 五通道，单调三次插值，Refine Sat 保色。
- 色彩：8 分区 HSL 混色器、Lightroom 式颜色分级色轮、RGB 三原色校准。
- 细节：锐化四件套、亮度与颜色双通道降噪、胶片颗粒、Halation 光晕。
- 蒙版：线性 / 径向渐变、画笔、颜色范围、亮度范围、选择主体、选择人物（本地 Vision 模型）。
- 几何与镜头：交互裁剪与画幅预设、旋转 / 镜像、地平线自动校直、自动与手动透视校正、
  横向色差校正、紫边抑制。
- 多重曝光：平均与曝光融合，全分辨率 16 位 TIFF 输出。
- 输出：单张与批量导出，303 个 HALD 胶片模拟 LUT。

---

## English summary

- **1.1.0 (2026-09-25)** — Vision-based multi-exposure alignment with a quality gate (translation or
  homography), hand-held denoise mode, multi-select compositing input, foreground cut-out and
  depth-painting masks, bokeh, a full export panel (format / long edge / quality), transparent cut-out
  export, presets, an adaptive light/dark theme, and a complete set of keyboard shortcuts.
- **1.0.0 (2026-09-24)** — Initial public release: non-destructive editing pipeline, free-form tone
  curves, HSL mixer, colour grading wheels, calibration, detail tools, seven mask types, interactive
  crop and geometry correction, multi-exposure compositing, and batch export.
