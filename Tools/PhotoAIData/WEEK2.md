# 第二周：公开样本与本机 LoRA 可行性

结果目录：`outputs/Phos-Training-Week2-20261017`（仓库上一级）。这是隔离实验，生产模型和运行环境不替换。

## 数据边界

从 Wikimedia Commons 的逐文件 CC0 元数据获取 48 张候选，保留原始许可证据、作者、页面、下载 URL、SHA256、近重复指纹。人工视觉筛除 16 张绘画、历史单色扫描、卫星图等，保留 32 张彩色照片、25 个作者组。元数据的作者组只能防已知作者泄漏，不能保证上游署名绝对准确。

每张生成 10 个受控操作：全局曝光、亮度范围蒙版两类、曲线、阴影分级、HSL、保留构图、裁掉左右边缘、保持所有编辑、径向局部曝光。目标由真实 Phos 渲染器执行并检查，没有使用生成式成片；总计 320 条。按作者组拆分 train240 / validation50 / test30，第一周测试照片仍排除。

这些是 synthetic_verified 的工具操作标签，全部保留 pending 人工审美审核。它们训练明确指令到参数、局部明暗方向、保留原编辑与裁切协议，不是专业审美、自动构图或摄影师风格标签。显式裁左右边缘不能作为自主构图能力证据。隔离试训不绕过正式数据导出的人审和用途许可规则。

## 可重复运行

以下命令从源码目录运行。模型根路径为 `~/Library/Application Support/Phos/MLX/model`。先复制已有 MLX venv 到结果目录 `.venv`（不要修改生产 venv）；本次克隆环境另安装 jsonschema4.25.1 与 psutil7.1.0。用克隆的 `.venv/bin/python`，避免复制脚本的旧 shebang。

```sh
PY=../outputs/Phos-Training-Week2-20261017/.venv/bin/python
ROOT=../outputs/Phos-Training-Week2-20261017
BASE=../outputs/Phos-Training-20261017
MODEL="$HOME/Library/Application Support/Phos/MLX/model"
"$PY" Scripts/photo_ai_week2_data.py collect --root "$ROOT" --baseline "$BASE" --worker "$BASE/worker/photo-ai-data" --count 48
# 下载清单按逐图视觉检查排除非照片后再 prepare；原始证据不能删除。
"$PY" Scripts/photo_ai_week2_data.py prepare --root "$ROOT" --baseline "$BASE" --worker "$BASE/worker/photo-ai-data"
"$PY" Scripts/test_photo_ai_week2.py --root "$ROOT" --baseline "$BASE"
"$PY" Scripts/photo_ai_train_pilot.py preflight --model "$MODEL" --data "$ROOT/sft-compact" --out "$ROOT/full-preflight"
"$PY" Scripts/photo_ai_train_pilot.py train --model "$MODEL" --data "$ROOT/smoke-compact" --out "$ROOT/pilot-compact" --iters 100
"$PY" Scripts/photo_ai_train_pilot.py verify --model "$MODEL" --data "$ROOT/smoke-compact" --out "$ROOT/pilot-reload" --adapter "$ROOT/pilot-compact/adapter"
"$PY" Scripts/evaluate_photo_ai_pilot.py --root "$ROOT" --model "$MODEL" --worker "$BASE/worker/photo-ai-data" --out "$ROOT/evaluation-base"
"$PY" Scripts/evaluate_photo_ai_pilot.py --root "$ROOT" --model "$MODEL" --worker "$BASE/worker/photo-ai-data" --out "$ROOT/evaluation-adapter" --adapter "$ROOT/pilot-compact/adapter"
```

使用新目录做新实验；不要覆盖历史指标。训练、重载、推理按顺序运行，避免同时加载两个模型。

## 本次训练配置和解释

原4bit底模冻结，视觉编码器冻结，只训练语言末4层 q_proj/v_proj 的 rank8 LoRA，327680参数。batch1、梯度检查点、学习率3e-5、100步。准备好240条训练记录，本次小型可行性试验只使用16条训练、8条验证，验证评估每次4批。不能称为已经完成240条全量训练。

完整生产提示词预处理通过，但第一轮训练在5步后因系统 swap 增量保护停止，保留 failure.json。第二轮保留工具规则和完整答案，仅去掉冗余默认状态 JSON，使用336边长图像；没有截断答案，所有图像 token 都排除在损失外。这种精简提示尚未接入生产，因此评估不能直接和第一周生产提示的7/12比较。

紧凑试训100步完成，MLX峰值5.422GB，验证损失1.3271→0.07982。loss 是已知正确答案上的 teacher-forced token 指标，不能代替自由生成的正确率，也不能证明审美提升。基线与适配器都使用同一 JSON schema 约束、温度0、每题一次；独立测试仅涵盖一张作者隔离照片的10种操作，规模很小。

默认正式 Phos 继续使用原模型。适配器应在扩大不同照片和不同措辞的测试后，才考虑产品加载入口。风格数据应另引入许可明确的原图/成片配对、审美评分、编辑参数或可靠反求的操作标签。

## 本次自由生成结果

作者隔离测试照片10题：原模型6/10，适配器7/10，无新增退步。阴影分级不再额外更改全局阴影值；两类亮度范围蒙版仍错误改动全局曝光、边界也不准确，裁边仍输出 x=0.05,width=1 导致拒绝。参数正确率不评价 summary 文案是否准确。这里只能确认训练与加载链路可用，不能确认生产可用。详细原始方案和真实渲染参数在结果目录的 evaluation-base 与 evaluation-adapter。
