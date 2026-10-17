# 正式工作区 Host 接入合同

R2 正式入口为 `PhosApp → WorkspaceWindow → WorkspaceHost / WorkspaceRootView`，使用已有唯一 AppState。每个窗口有稳定的 UI session、Environment、PhotoSelectionController 和 SheetRouter。WorkspaceCanvas、WorkspaceBrowser、完整 Inspector 和状态栏各自只创建一次 Host；Inspector 的旧控件在 R3 继续迁移。

## 持久对象

每个 WorkspaceHost 持有一个 WorkspaceEnvironment；窗口外观继续由唯一 `rf.appearance` 偏好控制。ApplicationAppearanceController 在启动时设置 NSApplication.appearance，system 模式为 nil，由系统初始外观与后续切换驱动；SystemAppIcon 观察同一应用有效外观。窗口/参数内容不得为了切主题重新创建。

普通大面板保持 matte，小工具组使用 NSGlassEffectView.regular。`WorkspaceSurfaceSlot` 让内容与材料载体成为稳定槽位中的兄弟视图，换材料不重挂内容。正式壳暂不使用覆盖全窗的 glass grouping，避免空白截获输入。最低系统26，无15–25界面分支或27专属交互属性依赖。应急开关改为 matte；减少透明度移除相应 effect。隐藏面板使用 alpha 与命中控制，保留 firstResponder 与草稿。

所有框架坐标来自 WorkspaceLayout.resolve：顶部工具容器36pt，按钮命中框28pt；系统交通灯与工具共享 y=30pt 中线。A列表默认212pt，可选196–260pt，行高46pt；B胶片容器122pt，内部74×50pt缩略图。检查器默认330pt，可选300–364pt，完整保留旧控件，R3再迁移密度。小窗口约束实际宽度，放大恢复偏好，安全编辑区至少560×420pt。窗口级 Router 串行呈现导出/批量/合成/同步/快照/错误/更新，旧业务标志由该 Router 兼容接入。

## R2 帧与选片合同

唯一 PreviewFrame 按 photoID、请求 revision、参数 fingerprint 和用途整体发布 image、mask、histogram、extent 与 bitmap尺寸。旧照片、旧请求结果被拒绝；edited、cropReference、beforeOriginal 分别使用自己的输出域。DisplayTransform 保留非零 extent 原点和 y 方向，只负责当前输出到视图的映射；1:1 按实际完整输出像素除以 backingScale 显示。

A自动铺满同一画布到窗口边缘，B自动fit于不被面板和胶片遮挡的区域。精准工具临时fit，退出恢复会话视口。手动观看时切A/B保留编辑图像中心和物理像素缩放；布局切换不调用select、decode、render或save。工作区、显隐、偏好宽度与每种布局的自动观看方式只保存在UI偏好。

PhotoSelectionController 统一处理列表、胶片、工具栏和键盘。合法数值草稿在旧照片同步结束，再选新照片；迟到blur按photoID拒绝跨照片回写。文本输入和等待焦点的草稿不被方向键、评级快捷键截走。Command多选独立于当前照片，Shift按筛选后的可见范围选择。

NSTableView复用46pt行，胶片按可见区复用PhotoCell；两个原生滚动容器持久保留，进入布局时跟随当前照片。缩略图最多2个并发任务，192项LRU缓存、96项最大需求；取消过期排队需求，旧响应不能覆盖新身份。切文件夹后，正在运行的ImageIO任务仍占用并发名额。

A/B快捷键为Control-Command-A/B，避免与QA平台检查的Command-Option-B冲突。低频命令、宽度和外观入口统一放入更多菜单。

## 窗口通知

观察者必须以当前 NSWindow 为 object，绑定 Host 生命周期并在拆除时取消。至少接入：

| 通知 | Host 响应 |
| --- | --- |
| didResize / didMove | 布局重新解算；仅显式标题区允许系统 performDrag，不由照片空白拖动窗口 |
| will/didEnterFullScreen、will/didExitFullScreen | 过渡中不手动移动交通灯；完成后重取 safeAreaInsets、重新布局 |
| didBecomeKey / didResignKey | 更新选择、工具与面板状态；matte 使用 followsWindowActiveState |
| didChangeScreen / didChangeBackingProperties | 重新获取 backingScale、屏幕与安全区；精准画布更新坐标，不重复解码 |
| willClose | 结束订阅、清理 Host；不得借 onDisappear 自动提交旧参数草稿 |

系统 close/miniaturize/zoom/full-screen 按钮必须继续使用 standardWindowButton。WorkspaceTitlebarDragView 首先调用 NSWindow.performDrag，保留系统拖动行为；如果事件源仍继续派发 mouseDragged，按同一屏幕指针映射保持窗口移动。窗口背景不设 isMovableByWindowBackground。透明玻璃组的空白必须命中底下照片/标题区，工具内容仍命中自身。

QA 的原生检查窗口记录对象数量、内容身份、草稿、应用/窗口外观、图标变体、命中计数、真实窗口通知和安全区；这些字段只写 QA workspace/reports，不进入产品正常用户流程。离屏图像检查只用于回归，不能证明真实玻璃和窗口行为。

## 兼容性边界

按用户2026-10-15的新要求，取消 macOS26 实机/虚拟机兼容测试及其 DG2 必需条件；不宣称做过26运行验证。继续最低26、SDK/链接/签名门禁，实际运行在当前电脑验收。每次开发完成重新构建并替换 `/Applications/Phos.app`，旧包留回退；独立QA包用于保护素材的验证。
