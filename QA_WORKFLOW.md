# Phos 独立 QA 工作区

QA 使用正式 `PhosApp` / `WorkspaceWindow` / `AppState`，额外定义 `PHOS_QA`。最低 macOS26；核心玻璃探针、SDK/链接一致性、二进制和签名门禁与正式构建相同。

```sh
sh Scripts/build_qa.sh --out ../outputs/Phos-V4.1-QA/run-001 \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
```

输出目录必须是新目录，且在源码与 `/Applications` 之外；构建不会安装或自动打开 App。默认从既有 `outputs/Phos-V3-evidence/S1-A/fixtures/pristine` 复制素材；可用 `--fixtures <素材目录>` 指定其他只读输入。`--app-baseline` 默认读取已安装 `/Applications/Phos.app` 作为回退基线。

- `PhosQA.app`：独立标识 `com.zeno.phos.qa`，独立偏好域，应用名 Phos QA。
- `workspace/photos/fixtures`：起始素材副本。QA 中选择其他目录时，先复制其中支持的图像及已有旁档，再打开副本；复制失败不会转而打开原目录。
- QA 的旁档写入必须在本次 workspace/photos 内，符号链接和路径越界被拒绝；损坏旁档仍按原有逻辑保留。
- `workspace/settings` / `workspace/exports`：预设与默认导出，不读取正式预设和旧版导出偏好。QA 默认关闭自动更新检查。
- `baseline`：所有 tracked 和未忽略 untracked 源码/配置/资源、原有工作树补丁、Git 历史 bundle、已安装 App 的完整 zip 和 SHA 清单。忽略的构建缓存不归档。
- `qa-build.json`、`fixture-manifest.json`、`ui-capabilities.json`、`binary-verification.json`、`bundle-verification.json`：可追踪构建输入、素材、编译器、SDK、minOS、签名和真实二进制。

运行时 workspace 路径写入 QA Info.plist；移动整个交付目录后应在新位置重新构建。R2已接入正式新壳、版本化唯一预览帧、A紧凑列表和B横向胶片；全部高级检查器继续保留，R3迁移参数控件。

## 验证与回退

```sh
python3 Scripts/qa_workspace.py restore \
  --snapshot ../outputs/Phos-V4.1-QA/run-001/baseline \
  --out ../outputs/Phos-V4.1-QA/restored-001
```

回退默认恢复到全新目录，校验归档、逐文件 SHA 和 App 基线，不覆盖当前工作树或正式安装；目录已存在会停止。恢复后的 `source` 带原提交和完整本地修改，`app-baseline` 留存原 App。`restore-verification.json` 记录核验结果。用户已授权每次开发完成重编译并替换正式安装；QA 构建本身仍不安装，完成验证后使用正式构建交付。

构建通过不代替实际启动、窗口、材料、外观和工作流验证。按用户2026-10-15要求，不再安排或要求 macOS26实机/虚拟机运行验证，不作为关口阻塞。

## R1-B 原生检查窗口

启动独立 QA App 后，“QA → 平台基线检查…”（Command-Option-B）仍可打开原生材料检查窗口。正式编辑器现为 WorkspaceWindow；QA菜单另有工作区应急材料开关与错误路由测试，均不进入正式包。

状态变化自动写入本次 workspace/reports。重启前将这次报告复制到独立证据目录，避免从1重新编号的状态文件覆盖前次会话；R1-B 验收记录已分别归档各次会话。窗口接入合同见 [WINDOW_INTEGRATION.md](./WINDOW_INTEGRATION.md)。

正式编辑器状态自动写入 `workspace/reports/workspace-current.json`，每次启动另建带 UUID 的历史报告目录，避免覆盖。记录真实 Host 身份、Canvas 数量、帧、材料、焦点草稿、参数与历史摘要及窗口状态；正式包不含这些记录器。

本机系统设置用于验证后恢复原值。当前电脑的窗口和最终工作区验收按相应 R2/R5 关口记录；26实机测试已按用户要求取消。

## R2 主屏验收

`bash Scripts/test_workspace_r2.sh <新输出目录>` 使用统一SDK门禁并编译不可变源码副本。覆盖R2-A结构检查、帧身份与非零origin、裁剪和原图域、20次A/B零业务工作、过滤/多选/草稿收尾、损坏旁档与1000项可见缩略图调度。

真实QA还需完成开图、选片、数值编辑和undo、切A/B、显隐、缩放与全屏。同照片同尺寸保存A/B×深浅四张截图。记录器额外输出framePhotoID/revision/purpose/fingerprint/extent/bitmap、工作计数及缩略图缓存和并发数。处理计数记录真实source解码、渲染和旁档写入，缩略图另计；视图更新次数不能冒充处理次数。
