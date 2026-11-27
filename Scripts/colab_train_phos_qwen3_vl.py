#!/usr/bin/env python3
"""Google Colab A100/L4 端到端训练脚本：为 Phos 微调 Qwen3-VL-4B-Instruct（SFT + DPO）。

设计原则：
1. 严格遵循 Phos `phos-json-compact-v1` 键序与协议契约（保证导出到 Mac MLX 后与 llguidance 约束解码逐 token 对齐）。
2. 全 36 层 language_model 7 大线性投影（q/k/v/o/gate/up/down），冻结视觉编码器，支持直接转换热插拔至 Phos 4-bit MLX 底模。
3. Completion-Only Loss Masking：仅对 assistant JSON 回复计算交叉熵损失，彻底屏蔽 prompt 与图像 patch token。
4. 自动断点续训（Google Drive 持久化检查点），避免 Colab 12h 断连浪费积分。

Colab 依赖安装参考：
  pip install -qU "transformers>=4.57.0" "peft>=0.14.0" "trl>=0.15.0" "accelerate>=1.3.0" \
      "datasets>=3.2.0" "qwen-vl-utils>=0.0.10" "safetensors>=0.4.5" "pillow"
"""
import argparse
import json
import os
from pathlib import Path

import torch
from PIL import Image
from datasets import Dataset
from peft import LoraConfig, PeftModel, get_peft_model
from transformers import (
    AutoProcessor,
    Qwen3VLForConditionalGeneration,
    Trainer,
    TrainingArguments,
)


TARGET_MODULES_FULL = [
    "q_proj", "k_proj", "v_proj", "o_proj",
    "gate_proj", "up_proj", "down_proj",
]


def load_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def build_language_only_targets(model, modules=TARGET_MODULES_FULL, last_n_layers: int | None = None) -> list[str]:
    """仅选中 language_model.layers.* 的线性层，严格排除 visual 编码器，以兼容 Phos 4-bit MLX 适配器。"""
    matched = []
    for name, _ in model.named_modules():
        if "visual" in name or "vision_tower" in name:
            continue
        if ".layers." not in name:
            continue
        if any(name.endswith(f".{m}") for m in modules):
            matched.append(name)
    if last_n_layers is not None:
        layer_ids = sorted({int(n.split(".layers.")[1].split(".")[0]) for n in matched})
        keep = set(layer_ids[-last_n_layers:])
        matched = [n for n in matched if int(n.split(".layers.")[1].split(".")[0]) in keep]
    if not matched:
        raise RuntimeError("未找到 language_model 目标层，请检查 transformers / Qwen3-VL 模型结构名称。")
    return sorted(matched)


class PhosVLMCollator:
    """严格实现 Completion-Only Loss Masking：仅监督最后一条 assistant JSON 回复。"""

    def __init__(self, processor, image_root: Path, max_length: int = 3072):
        self.processor = processor
        self.image_root = image_root
        self.max_length = max_length
        self.assistant_marker = "<|im_start|>assistant\n"
        self.marker_ids = processor.tokenizer.encode(self.assistant_marker, add_special_tokens=False)

    def _resolve_image(self, img_path: str) -> Image.Image:
        p = Path(img_path)
        if not p.is_absolute():
            p = self.image_root / p
        with Image.open(p) as im:
            im = im.convert("RGB")
            im.thumbnail((768, 768), Image.Resampling.LANCZOS)
            return im.copy()

    def __call__(self, batch: list[dict]) -> dict[str, torch.Tensor]:
        texts = []
        images = []
        for row in batch:
            imgs = [self._resolve_image(x) for x in row.get("images", [])]
            if not imgs:
                raise ValueError(f"样本缺少图像：{row.get('id')}")
            images.extend(imgs)

            msgs = []
            for m in row["messages"]:
                if m["role"] == "user":
                    content = [{"type": "image"} for _ in imgs] + [{"type": "text", "text": m["content"]}]
                    msgs.append({"role": "user", "content": content})
                else:
                    msgs.append({"role": m["role"], "content": [{"type": "text", "text": m["content"]}]})
            text = self.processor.apply_chat_template(msgs, tokenize=False, add_generation_prompt=False)
            texts.append(text)

        enc = self.processor(
            text=texts,
            images=images,
            padding=True,
            truncation=True,
            max_length=self.max_length,
            return_tensors="pt",
        )
        labels = enc["input_ids"].clone()
        pad_id = self.processor.tokenizer.pad_token_id
        m_len = len(self.marker_ids)

        for i in range(labels.size(0)):
            ids = labels[i].tolist()
            # 找最后一次 "<|im_start|>assistant\n" 出现位置，其之前全部置 -100
            start_pos = -1
            for j in range(len(ids) - m_len, -1, -1):
                if ids[j:j + m_len] == self.marker_ids:
                    start_pos = j + m_len
                    break
            if start_pos < 0:
                raise ValueError("未在对话模板中定位到 assistant 回复起始标记")
            labels[i, :start_pos] = -100
            if pad_id is not None:
                labels[i, enc["input_ids"][i] == pad_id] = -100
        enc["labels"] = labels
        return enc


def run_sft(args) -> None:
    dtype = torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
    processor = AutoProcessor.from_pretrained(args.model, min_pixels=256 * 28 * 28, max_pixels=640 * 28 * 28)
    model = Qwen3VLForConditionalGeneration.from_pretrained(
        args.model,
        torch_dtype=dtype,
        attn_implementation="sdpa",
        device_map="auto",
    )
    model.config.use_cache = False

    if args.init_adapter:
        model = PeftModel.from_pretrained(model, str(args.init_adapter), is_trainable=True)
    else:
        targets = build_language_only_targets(model, last_n_layers=args.last_n_layers)
        lora_cfg = LoraConfig(
            r=args.rank,
            lora_alpha=args.rank * 2,
            lora_dropout=args.dropout,
            bias="none",
            task_type="CAUSAL_LM",
            target_modules=targets,
        )
        model = get_peft_model(model, lora_cfg)
    model.print_trainable_parameters()

    train_rows = load_jsonl(args.data_dir / "train.jsonl")
    val_rows = load_jsonl(args.data_dir / "validation.jsonl")
    train_ds = Dataset.from_list(train_rows)
    val_ds = Dataset.from_list(val_rows)

    collator = PhosVLMCollator(processor, image_root=args.image_root, max_length=args.max_seq_length)
    targs = TrainingArguments(
        output_dir=str(args.out_dir),
        num_train_epochs=args.epochs,
        per_device_train_batch_size=args.batch_size,
        per_device_eval_batch_size=1,
        gradient_accumulation_steps=args.grad_accum,
        learning_rate=args.lr,
        lr_scheduler_type="cosine",
        warmup_ratio=0.06,
        weight_decay=0.01,
        bf16=(dtype == torch.bfloat16),
        fp16=(dtype == torch.float16),
        gradient_checkpointing=True,
        gradient_checkpointing_kwargs={"use_reentrant": False},
        logging_steps=10,
        eval_strategy="steps",
        eval_steps=args.eval_steps,
        save_strategy="steps",
        save_steps=args.save_steps,
        save_total_limit=4,
        load_best_model_at_end=True,
        metric_for_best_model="eval_loss",
        remove_unused_columns=False,
        dataloader_num_workers=4,
        report_to="none",
        seed=1702,
    )

    trainer = Trainer(
        model=model,
        args=targs,
        train_dataset=train_ds,
        eval_dataset=val_ds,
        data_collator=collator,
    )
    resume_ckpt = args.resume if args.resume else None
    trainer.train(resume_from_checkpoint=resume_ckpt)
    final_dir = args.out_dir / "final_peft_adapter"
    model.save_pretrained(str(final_dir))
    processor.save_pretrained(str(final_dir))
    print(f"✓ SFT 完成，PEFT 权重已保存至：{final_dir}")


def run_dpo(args) -> None:
    """阶段 3：使用 TRL DPOTrainer 对「Phos 渲染评分优胜 vs 翻车」成对样本做偏好对齐。"""
    from trl import DPOConfig, DPOTrainer

    dtype = torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
    processor = AutoProcessor.from_pretrained(args.model, min_pixels=256 * 28 * 28, max_pixels=640 * 28 * 28)
    base = Qwen3VLForConditionalGeneration.from_pretrained(
        args.model, torch_dtype=dtype, attn_implementation="sdpa", device_map="auto"
    )
    base.config.use_cache = False
    if not args.init_adapter:
        raise SystemExit("DPO 阶段必须通过 --init-adapter 指定 SFT 产出的 PEFT 目录。")
    model = PeftModel.from_pretrained(base, str(args.init_adapter), is_trainable=True)

    raw_pairs = load_jsonl(args.data_dir / "dpo_train.jsonl")
    val_pairs = load_jsonl(args.data_dir / "dpo_val.jsonl")

    def prep(rows):
        out = []
        for r in rows:
            p = Path(r["image"])
            if not p.is_absolute():
                p = args.image_root / p
            with Image.open(p) as im:
                im = im.convert("RGB")
                im.thumbnail((768, 768), Image.Resampling.LANCZOS)
                pil = im.copy()
            out.append({
                "images": [pil],
                "prompt": [{"role": "user", "content": [{"type": "image"}, {"type": "text", "text": r["prompt"]}]}],
                "chosen": [{"role": "assistant", "content": [{"type": "text", "text": r["chosen"]}]}],
                "rejected": [{"role": "assistant", "content": [{"type": "text", "text": r["rejected"]}]}],
            })
        return Dataset.from_list(out)

    dpo_cfg = DPOConfig(
        output_dir=str(args.out_dir),
        num_train_epochs=args.epochs,
        per_device_train_batch_size=1,
        gradient_accumulation_steps=args.grad_accum,
        learning_rate=args.lr,
        beta=args.dpo_beta,
        lr_scheduler_type="cosine",
        warmup_ratio=0.1,
        bf16=(dtype == torch.bfloat16),
        gradient_checkpointing=True,
        logging_steps=10,
        eval_strategy="steps",
        eval_steps=args.eval_steps,
        save_strategy="steps",
        save_steps=args.save_steps,
        save_total_limit=3,
        max_length=args.max_seq_length,
        max_prompt_length=args.max_seq_length - 640,
        remove_unused_columns=False,
        report_to="none",
        seed=1702,
    )
    trainer = DPOTrainer(
        model=model,
        ref_model=None,  # PEFT 隐式共享冻结底模作 ref，省一半显存！
        args=dpo_cfg,
        train_dataset=prep(raw_pairs),
        eval_dataset=prep(val_pairs),
        processing_class=processor,
    )
    trainer.train(resume_from_checkpoint=args.resume if args.resume else None)
    final_dir = args.out_dir / "final_dpo_peft_adapter"
    model.save_pretrained(str(final_dir))
    print(f"✓ DPO 完成，PEFT 权重已保存至：{final_dir}")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--stage", choices=("sft", "dpo"), required=True)
    p.add_argument("--model", default="Qwen/Qwen3-VL-4B-Instruct")
    p.add_argument("--data-dir", type=Path, required=True)
    p.add_argument("--image-root", type=Path, required=True)
    p.add_argument("--out-dir", type=Path, required=True)
    p.add_argument("--init-adapter", type=Path, default=None)
    p.add_argument("--resume", type=str, default="")
    p.add_argument("--rank", type=int, default=32)
    p.add_argument("--dropout", type=float, default=0.05)
    p.add_argument("--last-n-layers", type=int, default=None, help="留空=全 36 层语言模型；填 12 则只训后 12 层")
    p.add_argument("--epochs", type=float, default=3.0)
    p.add_argument("--batch-size", type=int, default=2)
    p.add_argument("--grad-accum", type=int, default=8)
    p.add_argument("--lr", type=float, default=1.2e-4)
    p.add_argument("--dpo-beta", type=float, default=0.1)
    p.add_argument("--max-seq-length", type=int, default=3072)
    p.add_argument("--eval-steps", type=int, default=150)
    p.add_argument("--save-steps", type=int, default=150)
    args = p.parse_args()
    os.environ["TOKENIZERS_PARALLELISM"] = "false"
    if args.stage == "sft":
        run_sft(args)
    else:
        run_dpo(args)


if __name__ == "__main__":
    main()
