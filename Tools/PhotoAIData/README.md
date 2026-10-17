# Phos 训练数据准备工具（阶段 1–3）

本工具固定基座与协议、采集许可明确的小样本、用生产渲染器制作标签与审核预览。没有启动模型权重训练，不自动把模型建议当成标准答案，不改写原照片和已有旁档。

## 本次交付

输出根目录：`../../../outputs/Phos-Training-20261017`（从本目录计算）。本机审核页：<http://127.0.0.1:8766>。

- `baseline/frozen/manifest.json`：工作树源文件快照、模型全部文件 SHA256、推理环境版本、安装 App 身份、worker 身份。
- `baseline/frozen/source/`：当前含未提交修改的源码快照，不用 Git HEAD 冒充实际代码。
- `baseline/frozen/protocol/`：生产编辑 schema、裁切 schema、默认参数。
- `baseline/suite.json`：生成后固定的 12 个探测任务；后续审核或改标签不改变这个基线。
- `baseline/results/`：每任务首次请求的提示词、原始响应、终止原因、渲染、参数、蒙版和检查；不自动重试。
- `sources/manifest.json`、`sources/evidence/`：来源、逐文件许可依据、哈希和下载记录。
- `records/`：指令、输入状态、目标方案、分组、数据划分、审核状态。
- `renders/`：版本化前后图、完整前后参数、黑白蒙版图与渲染检查。
- `reviews/events.jsonl`：审核历史；编辑目标后必须重新审核。

四张 scikit-image 公开照片只用于验证流水线，不是专业修图训练集。12 条任务全部属于测试集，不应迁入训练集。FiveK、PPR10K 图片没有下载；其研究用途限制已经登记。GIER、GAIC 的底层图片使用许可未确认为发布可用，因此暂时隔离。

## 从头复现

从 Phos 源码目录执行，输出必须使用一个新的目录，避免覆盖旧基线：

```sh
bash Scripts/build_photo_ai_data.sh ../outputs/Phos-Training-new/worker
python3 -m venv ../outputs/Phos-Training-new/.venv
../outputs/Phos-Training-new/.venv/bin/python -m pip install -r Tools/PhotoAIData/requirements.txt
```

下文用 `PYTHON` 表示该隔离环境的 Python，`ROOT` 表示新输出路径，`WORKER` 表示刚编译的 `photo-ai-data`；实际命令用对应路径替换，不需要修改正在使用的 MLX 环境。

```text
PYTHON Scripts/photo_ai_workbench.py --root ROOT --worker WORKER freeze
PYTHON Scripts/photo_ai_workbench.py --root ROOT --worker WORKER acquire
PYTHON Scripts/photo_ai_workbench.py --root ROOT --worker WORKER generate
PYTHON Scripts/photo_ai_workbench.py --root ROOT --worker WORKER validate
PYTHON Scripts/photo_ai_workbench.py --root ROOT --worker WORKER baseline
PYTHON Scripts/photo_ai_workbench.py --root ROOT --worker WORKER review
```

`baseline` 需要当前本地 MLX 服务已经在 127.0.0.1:8765 运行（在 Phos 中使用 AI 修图会启动它）。启动前核对服务模型、冻结的权重哈希和 worker 哈希。每任务使用动态生产 schema 和从冻结源码提取的生产提示词，temperature=0，编辑最多1800 token、裁切180 token。当前全参数上下文沿用生产逻辑，省略手绘点串。冻结提示词的最终文本也随请求保存。

## 审核与修正

审核页显示输入、目标、蒙版、实际参数差异及首次模型输出。可以保存认可／拒绝／需要修正和备注，也可以编辑 JSON 后重新渲染。

页面只监听本机，保存接口需要页面内令牌。源码照片、个人文件和模型权重不会通过网页对外开放。照片文本不是操作指令。

认可只表示认可当前方案。审核绑定目标参数、指令、图片哈希、划分与预览哈希；重放或修改后旧认可失效。需要程序规范化或明暗方向校验失败的方案不能直接认可。审核与裁切审美仍由人判断。

更正样本也可以修改对应 record JSON 后运行 `replay ID`。该命令会产生新的渲染目录，保留旧版本，状态回到 pending。基线套件不变。

## 添加后续样本

`add record.json` 接受 `phos-dataset-v1` 记录，字段参考已有 records。必须明确 `id`、`task`（edit/crop）、`sourceId`、`groupId`、`split`（train/validation/test）、`instruction` 和 plan/crop，baseParams 可选（省略表示默认值）。`sourceId` 必须已经在 sources/manifest.json 中登记并下载。新来源必须先保存本地副本、SHA256、许可证据、credit、status=downloaded、path 和 releaseEligible；不确定用途的来源应为 false。

添加前检查同图哈希与同组划分，已有测试图不能改名混入训练。记录必须再经过 schema、真实渲染和人工审核。原图＋成片的个人风格资料在没有确定动作标签前应作为参考资料单独保存，不能编造动作答案。

## 导出与检查

```text
PYTHON Scripts/photo_ai_workbench.py --root ROOT --worker WORKER export --purpose research
PYTHON Scripts/photo_ai_workbench.py --root ROOT --worker WORKER export --purpose release
PYTHON Scripts/test_photo_ai_workbench.py --root ROOT --worker WORKER
```

只导出 split=train、当前审核有效的 approved 样本；release 还必须逐来源明确允许。当前 12 条测试样本导出零条是正确结果。JSONL 是框架无关中间格式，包含图像与用户／助手对话；正式训练前还需针对固定训练器验证图像 token、completion loss mask 和上下文长度。

## 当前基线的界限

首次输出成绩包括 JSON/schema、明确数值、无关全局与高级参数保持、蒙版数量与原始选择/符号、实际局部方向、裁切边界。程序规范化前后的局部方向分别保存。没有把程序重试的成绩计入首次输出。

这 12 条、4 张图仅给出可复现的工程基线，不能推断真实照片总体准确率，也没有自动判定皮肤、构图或 ins 风格是否好看。人物蒙版空选区、错误背景反选及不应裁切的场景都可能失败，应当保留失败而不是改题。

当前 App 拒绝“全部不变”的建议，协议本身可以表示空计划；noop 探测会暴露此产品行为差异。此阶段只记录，不在基线阶段修模型或改变协议。
