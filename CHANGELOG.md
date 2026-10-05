# 更新日志 / Changelog

本项目遵循语义化版本。日期为发布日（Asia/Shanghai）。

## [3.2.1] — 2026-10-05

修复 DMG 安装窗口里「首次打开必读.txt」挡住标题的问题。
Fixes the read-me file overlapping the title in the DMG install window.

### 2026-10-05 DMG 窗口布局修复 / DMG Window Layout Fix

- **`.DS_Store` 里图标位置的 y 是从窗口顶部往下算的**，此前按 CoreGraphics 的习惯
  （从底部往上）计算，把「首次打开必读.txt」放到了标题位置上，正好压住 Phos 标题与副标题。
- 窗口从 660×420 改为 **660×460**，必读文件移到两个图标下方的独立一行。
- 背景图版面重排：标题、副标题、拖拽提示统一上移，下方整块留给必读文件；
  箭头位置不变，仍与两个图标对齐。
- `Scripts/dmg/settings.py` 与 `Tools/DMGBackground.swift` 都补了坐标系注释。
- **应用本身没有任何改动**，只是安装包外观修正。

## [3.2.0] — 2026-10-05

新增启动时的更新提示；安装包从 zip 改为 DMG（zip 仍然一并发布）。
Adds a launch-time update check, and switches the download from zip to DMG (the zip is still published).

### 2026-10-05 安装包改为 DMG / DMG Distribution

- **发布物从 zip 改为 DMG**：带背景图、指向「应用程序」的箭头，以及一份说明 Gatekeeper
  步骤的 `首次打开必读.txt`。zip 仍然一并发布，留给习惯解压或要脚本化下载的人。
- 窗口布局用 [`dmgbuild`](https://github.com/dmgbuild/dmgbuild) 写 `.DS_Store`，
  **不用 Finder AppleScript** —— 后者需要图形会话与「自动化」权限，无头环境与 CI 上不可靠。
- 背景图是**多分辨率 TIFF**（660×420@72dpi + 1320×840@144dpi），由 `tiffutil -cathidpicheck`
  合成，Finder 在 Retina 上会自动挑 2x 那一档，不会发虚。
- 新增 `Scripts/make_dmg.sh`、`Scripts/dmg/`（布局配置、说明文件、背景图）、
  `Tools/DMGBackground.swift`（背景图生成器）。
- CI：新增 dmgbuild 安装步骤，同时产出 `.dmg` 与 `.zip`，SHA256 覆盖两者。
- **注意**：DMG 不会减轻 Gatekeeper 拦截。未公证的 DMG 能正常打开挂载，但拖出来的 app
  首次启动仍会被拦，那一步只有公证能消掉。

### 2026-10-05 更新提示 / Update Check

- **启动时检查新版本**：向官网取一次 `update.json`，只比较版本号。有新版时工具栏应用名旁边
  出现一个小徽标（图标 + 版本号），点击打开下载页；没有新版则完全不显示，不占位置。
- 工具栏「更多」菜单里新增手动「检查更新…」，无论有没有新版都会给出结果。
- 版本号按段做**数字**比较，保证 `3.10.0 > 3.9.0` —— 直接比字符串会得出相反结论，
  那样真实的新版本永远不会被提示。
- 清单地址按顺序尝试，主地址不通会自动降级到备用地址；网络不通时静默失败，不打扰用户。
- 这是 Phos 唯一的联网行为：不带任何用户标识，不发送照片或本机信息。
  想关掉：`defaults write com.zeno.phos updateCheckDisabled -bool true`。
- 新增 `Tools/UpdateTest.swift` 与 `Scripts/test_update.sh`（纯逻辑，不联网，12 项）。

## [3.1.1] — 2026-10-05

修复径向蒙版旋转柄方向反了的问题。

### 2026-10-04 径向蒙版旋转方向修复 / Radial Mask Rotation Direction Fix

- **修复径向蒙版旋转柄方向反了的问题**：鼠标手势使用画布坐标（Y 轴向下），而蒙版的 `radialAngle`
  使用图像坐标（Y 轴向上）；原先直接相减会把径向旋转方向翻转。现在径向旋转使用反向角度增量，
  线性蒙版保持原有行为不变。
- 回归测试新增径向旋转方向断言：从右侧控制点向左上拖 90° 时，内部角度为 `-90°`，
  与画布上看到的旋转方向一致。

> 说明：该修复的源码提交（2026-10-04）晚于 v3.1.0 的二进制构建（2026-10-03），
> 因此 v3.1.0 的发布包并不包含它，从 v3.1.1 起才真正随包发布。

## [3.1.0] — 2026-10-03

品牌改名后的首个发布版本：RawForge 正式以 **Phos** 之名发布，并修复蒙版控制点拖动时参考线漂移的问题。
First release under the new name: RawForge ships as **Phos**, plus a fix for mask guide drift while dragging handles.

### 2026-10-03 蒙版控制点拖动修复 / Mask Handle Drag Fix

- **修复拖动蒙版控制点时三条参考线「飘走」**：控制点原先上报 `position + v.translation`，
  但 `translation` 是**从按下那一刻算起的累计位移**，而 `position` 又会随蒙版更新每帧重算，
  于是同一个位移被反复叠加。实测拖 120px 时控制点跑出 240px，且鼠标事件越密偏得越多
  （细粒度下可达 30 倍），参考线因此整体漂移。
- 改为以「按下点 + 按下那一刻的蒙版」为基准（新增 `MaskDragSession`），每次移动都用绝对坐标
  重新计算，结果不再随鼠标事件密度变化。线性起/终点、中心移动、旋转柄、径向三手柄一并受益。
- 新增 `Tools/MaskDragTest.swift` 与 `Scripts/test_mask_drag.sh`：纯几何回归测试，不需要照片素材。

### 2026-10-03 蒙版交互完善 / Mask Interaction Refinements

- **蒙版参考线显示逻辑优化**：选中线性或径向渐变蒙版时自动切换到位置调整模式（`.position`），确保控制点、参考线和旋转柄立即可见。
  - 应用于选择已有蒙版、创建新蒙版、复制蒙版和完成渐变绘制四个交互入口。
  - 用户仍可手动切换到画笔或擦除工具，但重新选中蒙版时会自动回到位置模式。
- 清理蒙版叠加层的调试输出，发布版本不再向 stdout 打印诊断信息。

### 2026-10-03 构建修复 / Build Fix

- **修复 CI 构建失败**：蒙版参数一律是 `Double`，而 `CGPoint` / `CGSize` 是 `CGFloat`，
  两者混算时 `cos` / `sin` / `atan2` 会同时匹配 `CoreGraphics` 的 `CGFloat` 版与 `_math` 的
  `Double` 版，在完整 Xcode SDK 上报 `ambiguous use of 'cos'`
  （本机 CommandLineTools SDK 不报，所以只在 CI 暴露）。
- `MaskGeometry` 内部与 `MaskOverlay` 的手柄位置计算统一按 `Double` 计算，
  只在进出 `CG*` 的边界转回 `CGFloat`；`.pi` 一律写 `Double.pi`。几何语义不变，
  `Scripts/test_mask_drag.sh` 6 项结果与修改前逐位一致。

### 2026-10-01 品牌改名 / Rebrand

- RawForge 更名为 **Phos**，更新界面、应用元数据、默认水印、构建产物和发布文件名。
- Phos 使用新的 `com.zeno.phos` 应用标识；仍兼容读取旧 `com.zeno.rawforge` 设置、`.rawforge.json` 旁档和旧预设目录。
- 新建旁档的 `app` 字段为 `Phos`，旧旁档中的 `RawForge` 标记仅作为兼容数据保留。
- 历史标签与 v3.0.1 及更早的发布记录保持不变；从 **v3.1.0** 起使用 Phos 名称发布。

### 验证 / Verification

- `./build.sh` 0 error；`codesign --verify --deep --strict Phos.app` 通过。
- `bash Scripts/test_mask_drag.sh` 6 项全通过，关键判据「结果不随鼠标事件数漂移」（5 / 61 / 1200 次事件结果一致）。

### 已知限制 / Known limitations

- 1:1 像素视图（`s.oneToOne`）未挂载 `MaskOverlay`，该模式下看不到渐变参考线。
- 线性蒙版参考线沿法线只延伸画面高度，极宽幅照片下可能画不到边缘。
- 既有 `-D PHOS_TESTING` 全量测试脚本在本机会卡在 `Inspector.swift:845` 的类型检查，新回归脚本已绕开。

## [3.0.1] — 2026-09-30

v3.0.0 收尾版本：测试体系修复与实拍压力测试，渲染与应用行为无变化。
Wrap-up release for 3.0.0: test infrastructure fixes and real-photo stress testing. No rendering or behavioural changes.

### English

- **Fixed `Scripts/test_studio.sh`**: the fixture image was mistakenly passed as the render baseline directory; now takes an optional baseline-directory argument with path validation.
- **Fixed `Tools/RenderRegression.swift`**: strictly separates output vs baseline directories, validates the case set, and compares `.rgba` / `.cube` byte-exact.
- **Added `Tools/RealPhotoTest.swift` and `Scripts/test_real_photos.sh`**: real-photo decode / orientation / export / Vision-mask checks, original-file SHA256 integrity, plus a 1000-image proxy-library soak (120 s: 734 switch/edit/undo/redo cycles, ~172 MiB peak RSS).
- README documents the Studio regression and real-photo stress-test usage.

### 中文

- **修复 `Scripts/test_studio.sh`**：不再把 fixture 图片误传为渲染基准目录，新增可选基准目录参数与路径校验。
- **修复 `Tools/RenderRegression.swift`**：严格区分输出目录与基准目录，校验用例集合，`.rgba` / `.cube` 逐字节比较。
- **新增 `Tools/RealPhotoTest.swift` 与 `Scripts/test_real_photos.sh`**：真实照片解码 / 方向 / 导出 / Vision 蒙版检查、原片 SHA256 完整性校验，外加 1000 张代理图库 120 秒压测（734 次切图 / 编辑 / 撤销 / 重做，峰值常驻内存约 172 MiB）。
- README 补充 Studio 回归与实拍压测用法。

### 验证 / Verification

- Studio 布局、性能回归全部通过；14 组渲染用例与 v3.0.0 基准**逐字节一致**。
- 实拍验证：Sony HIF、同场景 JPEG；原片 SHA256 校验通过；1000 张代理图全部扫描加载。
- 已知限制：未穷举所有相机 RAW 格式；Vision 蒙版只验证了调用与输出有效性，待人物 / 主体照片做目视确认。

---

## [3.0.0] — 2026-09-29

全新 Studio 界面：参照内部界面设计稿重做主窗口外壳与检视器结构，界面语言全面升级（大版本号变更）。

### 新增 / Added

- **Studio 界面外壳 `StudioUI`**：应用入口切换为 `StudioMainWindow`。视觉语言采用中性面板 + 金色点缀
  （金色只用于选中与编辑态），面板 / 表面 / 画布三层明暗自适应（跟随浅色 / 深色外观）。
- **检视器改五分类**：明暗（sun.max）/ 色彩（slider）/ 细节（circle.lefthalf.filled）/ 变换（crop）/ 蒙版
  （circle.dashed），每类一个 SF Symbol 图标页；分组自动归类（如白平衡、基本归「明暗」，曲线、HSL、
  胶片 CLUT 归「色彩」）。
- 外观选择器（系统 / 浅色 / 深色）随应用持久化。
- 新增 `Tools/StudioLayoutTest.swift` 布局自测与 `Scripts/test_studio.sh` 测试脚本。

### 变更 / Changed

- **三栏布局**：素材浏览器（250–360px）+ 画布（440px 起，自适应）+ 检视器（330–440px），`HSplitView` 可拖动。
- **工具栏重排**：品牌 + 打开文件夹 / 裁剪 / 撤销重做 / 文件名（居中截断）/ 原图·调整对比 / 预设菜单 /
  命名快照 / 复制调整 / 同步调整 / 导出菜单（批量导出、多重曝光合成）。
- **检视器分组卡改平铺行**：统一 16px 内边距、38px 标题行、行间细分隔线，去掉厚重卡片外壳；
  「恢复所有默认参数」带确认弹窗。
- 最小窗口降至 1100×700（原 1280×820），小屏更友好。

### 修复 / Fixed

- **切图后状态残留**：切换照片时自动退出裁剪、1:1、前后对比与白平衡吸管，画布视图重置。
- **上一张 / 下一张尊重筛选**：导航只在筛选结果内移动（星级 ≥ N / 已标记），不再跳到被过滤的照片；
  状态栏显示筛选集内的位置。
- **批量导出防重入**：批量导出进行中不再触发新的导出；空选集给出提示而不是空跑。
- **撤销栈分支去重**：`History.push` 改为比较当前位置而非栈顶，撤销后再编辑不会产生冗余步骤。
- **数值输入尾零**：清除尾随 0 与孤立小数点（原来会误删 "0" 有效位）；非有限值不再入参。
- 滑块行加高到 28px、数值列加宽，值在悬停时改用主题色提示可编辑。

### 验证 / Verification

- `swiftc` 直接编译通过（arm64），无新增编译错误；布局自测脚本通过。
- 依据界面参考稿核对：中性面板、金色选中、五分类检视器、工具栏分组、三栏边界。

---

## [2.1.1] — 2026-09-28

2.1.0 界面外壳的工作台细化：三栏边界、顶部工具栏与素材浏览的第二轮打磨。

### 变更 / Changed

- **三栏边界定宽**：左素材栏固定约 320px、右调整栏固定约 360px，中央画布 `maxWidth: .infinity`
  吃掉剩余空间；窗口放大时画布优先获得空间，变窄时两侧不再无限挤压缩略图和参数控件。
- **顶部工具栏去品牌卡片**：改用轻量编辑工作栏——品牌与素材文件夹、打开 / 对比 / 裁剪、
  文件名与原图 / 调整预览状态、撤销 / 重做 / 预设、快照 / 复制调整 / 同步调整、导出主操作、
  编辑状态与全像素 / 1:1 开关；按钮统一小尺寸 SF Symbols、克制圆角、系统强调色。
- **素材浏览标题层级**：标题与数量分两行，独立四向留白，与缩略图区之间加细分隔线，筛选菜单居右。

### 修复 / Fixed

- **缩略图网格改自适应**：列宽 `adaptive(minimum: 116, maximum: 166)`、间距 12px、左右内边距 16px、
  上下 14px；图片区保持 1.35 宽高比不再变形——解决放大后贴边、小窗比例不稳定的问题。
- 缩略图单元结构固定为「图片 → 底部星级 → 右上角选择钮 → 下方文件名」，文件名不再压图、选择钮不漂移。

### 保留 / Unchanged

- 仅重做窗口外层：RAW 解码、全部调整、蒙版与画笔、前后对比、撤销重做、快照预设、
  复制同步、单张 / 批量导出、多重曝光等功能不受影响。

### 验证 / Verification

- `swiftc` 直接编译通过（arm64），无新增编译错误；仅项目原有的弃用 API 与未使用变量警告。
- 依据截图反馈核对：三栏边界、工具栏降噪、缩略图比例与贴边。

---

## [2.1.0] — 2026-09-28

以界面重构为主的版本：新增高级界面外壳、三栏改可伸缩布局，外加两处编辑交互修复和一处胶片渲染修复。

### 新增 / Added

- **高级界面外壳 `PremiumUI`**：应用入口由 `MainWindow` 切换为 `PremiumMainWindow`，
  统一品牌区与工作区信息；工具（打开 / 对比 / 裁剪）、历史与同步（撤销、重做、预设、快照、
  复制调整、同步调整、导出）分组排布；顶部显示当前照片文件名与原图 / 调整后状态，
  提供全像素与 1:1 预览开关；画布叠加实时预览状态浮层（预览质量、图像尺寸、直方图）；
  底部状态栏含文件格式、星级与标记操作。
- 画布新增自适应 `rfCanvas` 底色与 `rfDivider` 分隔线，浏览器 / 预览 / 检视器视觉分区更清晰，
  颜色随系统浅色 / 深色外观。

### 变更 / Changed

- **三栏主窗口改为 `HSplitView`**：左素材浏览器、中画布与直方图、右检视器，
  可拖动分隔线调整各栏宽度，窗口尺寸变化时内容不再互相挤压。
- 视觉风格统一：小连续圆角、更克制的材质背景、系统强调色、SF Symbols 图标、
  更清晰的标题 / 辅助 / 状态层级，减少厚重卡片与大面积装饰。

### 修复 / Fixed

- **缩略图重叠**：素材浏览器最小宽度提高到约 278px，缩略图定为 112×142、网格列宽 112、
  间距 12、左右安全内边距 16；文件名移到图片下方，选择圆钮固定右上角、星级固定图片底部。
- **“素材浏览”贴边**：标题区增加水平 18px、垂直 16px 内边距，不再贴窗口边缘。
- **数值输入重复提交**：`SliderRow` 的 `onSubmit` 与失焦 `onChange` 可能连续触发，
  同一次输入重复写入撤销记录；增加 `didCommitInput` 幂等锁，每个输入周期只提交一次。
- **撤销栈空步骤**：`History.push` 原先无条件追加参数，按撤销可能看不到变化；
  现与上一条历史相同则跳过，抑制无意义的历史膨胀。
- **胶片 CLUT 域不匹配（“灰片”问题）**：渲染管线为线性域，而胶片 LUT（HALD/.cube）是
  sRGB 感知域数据，step 8 直接套 `CIColorCube` 导致索引与输出两头错域——黑场被抬到约 18% 灰、
  整段灰阶压扁，观感如 log 素材。现进 LUT 前 `CILinearToSRGBToneCurve` 编码、
  出来 `CISRGBToneCurveToLinear` 解码（与 CurveCube 同一处理）；实测黑场显示值由 0.181 回到 0.027。

### 验证 / Verification

- `swiftc` 直接编译通过（arm64，独立 module cache），无新增编译错误。
- 界面改动依据截图反馈逐项核对：缩略图重叠、标题留白、三栏伸缩。
- 胶片 LUT 修复经灰阶数值推演验证：修复后灰阶与 `.cube` 感知域参考逐点一致。

---

## [2.0.0] — 2026-09-26

这是 1.1.0 之后的第一个正式发布版本，合并了此前只在本地流转的 1.2 / 1.3 未发布内容
（导出水印、固定导出目录、工作流增强与性能重做），因此跳过 1.2 / 1.3 版本号直接进 2.0.0。

### 新增 / Added

- 批量同步：缩略图勾选、Command/Shift 多选、按八类参数同步、复制调整；默认不复制裁剪与蒙版。
- 批量同步前为每张目标照片保存恢复快照，保留星级、标记与已有快照；损坏的副档跳过并报告。
- 白平衡灰点吸管：取样原始图像，支持旋转/裁剪后的坐标，过曝和极暗取样会拒绝；支持一键重置。
- 蒙版覆盖：显示实际计算的选区；支持在任意类型蒙版上添加或擦除选区，并保留软边、撤销和保存。
- 8/16 位 TIFF 导出，可选 sRGB、Display P3、Adobe RGB；位深与色域控件同时用于单张与批量导出。
- 命名快照：创建、重命名、删除、恢复；随照片副档保存，恢复操作可撤销/重做。
- **导出水印**：导出 / 批量导出可叠加水印——文字（可选白字 / 黑字，带柔和投影）或图片（PNG 透明 logo），
  九宫格定位、大小（占长边比例）、不透明度、旋转、边距均可调。只叠在导出文件上，不进预览与副档。
- **固定导出目录**：导出默认落到本机配置的文件夹，可在导出面板查看与更改；
  配置存在本机 `UserDefaults`（`defaults write com.zeno.phos exportDirectory <路径>`），首次改名时兼容读取旧 `com.zeno.rawforge` 设置。

### 性能 / Performance

- 预览改为单任务执行并合并待处理参数，连续拖动不再堆积并发渲染；切图、切换精度时丢弃过期结果。
- 蒙版滑块拖动中只更新预览，结束时保存一次并记录一次撤销，避免连续写盘和历史栈膨胀。
- 文件夹扫描、原图解码、前后对比和单张导出移至后台；缩略图优先使用 ImageIO 内嵌预览，并合并列表更新。
- 原图、曲线、胶片、HSL、范围蒙版和 AI/深度蒙版缓存增加容量上限及并发保护。
- 曲线 LUT 预先计算与单通道有关的重复运算；胶片强度调整复用已解码的 HALD，直方图复用已渲染的预览像素。
- 保留 2200px 默认预览、全像素/1:1 模式、64³ 曲线 LUT 和原有全分辨率导出管线。

### 修复 / Fixed

- **颜色分级色轮整体偏色 90°**：`AngularGradient` 的 0° 默认在 3 点钟方向且顺时针递增，而拖拽取值用的是
  「0° 朝上、顺时针」（同 LR / HSL 惯例），两者差 90°——看到的红色位置实际取到黄绿，因而几乎全部偏绿。
  现已把渐变起点设成 -90°，并用离屏渲染取样校准。
- **色轮中间色相最多偏 10°**：色标只有 13 个时相邻色标在 RGB 空间线性插值会把中间色相拉偏，
  现改为每 3° 一个色标（121 个），实测平均偏差由 2.0° 降到 0.3°。
- 全像素/1:1 开关立即触发渲染；前后对比快捷键及切图后刷新对应的原图。
- 异步切图、导出和合成缩略图更新按照片身份核对，避免更新到其他照片；空文件夹评分/标记不再越界。
- **长边缩放被缩两次**：`Engine.write` 先线性缩放又跑了一次 Lanczos（系数相同），实际输出长边是设定值的
  平方倍；现在只做一次 Lanczos 高质量缩放，长边严格等于设定值。
- **旋转 / 贴边水印撑大画布**：水印越出图边时合成会扩大输出幅面导致整图错位，现裁回原幅面（越界部分裁掉）。

### 兼容与修复 / Compatibility

- 新副档使用完整文件名（例如 `photo.HIF.rawforge.json`），隔离同名 RAW/JPEG；旧副档保留并兼容读取。
- 保存失败会提示，不静默覆盖损坏的编辑记录。
- 修正画布放大/平移后的画笔与取样坐标，以及 AI 蒙版重算时 ID 更新不到原蒙版的问题。

### 验证 / Verification

- 使用本机 Sony HIF、实拍 JPEG 和纸面照片副本进行测试；原照片校验未变。
- 检查白平衡中性色校正、蒙版擦除/重绘、快照恢复、批量同步保护、旧副档迁移、损坏副档保护。
- 三种色彩空间的 8/16 位 TIFF 位深与配置验证通过，16 位样本超过 256 级，透明通道保留。
- 色轮以离屏渲染 + 参考色标逐点比对校准（圆点所指方位与底色一致）。
- 原有性能回归通过；界面实测导出 4128×6192 的 16 位 TIFF。
- 未做所有相机 RAW 格式、所有 Vision 模型场景或长时间大型图库的穷举测试。

---

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

- **2.0.0 (2026-09-26)** — Grouped batch synchronisation with recovery snapshots, white-balance grey-point
  picker, mask overlays with additive/erasing brushes, named snapshots, 8/16-bit TIFF export in three
  colour spaces, an export watermark, and a configurable default export folder, plus a performance
  rework (coalesced previews, bounded caches, background decoding/export). Also fixes the colour grading
  wheels: the wheel background was rotated 90° against the drag mapping (almost every pick looked green)
  and sparse gradient stops shifted mid-hues by up to 10°. Skips 1.2 / 1.3, which were never published.
  homography), hand-held denoise mode, multi-select compositing input, foreground cut-out and
  depth-painting masks, bokeh, a full export panel (format / long edge / quality), transparent cut-out
  export, presets, an adaptive light/dark theme, and a complete set of keyboard shortcuts.
- **1.0.0 (2026-09-24)** — Initial public release: non-destructive editing pipeline, free-form tone
  curves, HSL mixer, colour grading wheels, calibration, detail tools, seven mask types, interactive
  crop and geometry correction, multi-exposure compositing, and batch export.
