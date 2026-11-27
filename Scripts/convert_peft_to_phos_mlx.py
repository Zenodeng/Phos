#!/usr/bin/env python3
"""将 Colab / HuggingFace PEFT 训练产出的 Qwen3-VL-4B LoRA 权重转换为 Phos 兼容的 MLX 适配器包。

核心转换契约（严格匹配 mlx-vlm 0.7.8 + LocalPhotoAI.swift + photo_ai_server.py）：
1. 键名重映射：
   base_model.model.model.language_model.layers.{i}.{mod}.{proj}.lora_A.weight
   -> language_model.model.layers.{i}.{mod}.{proj}.lora_a
2. 矩阵转置（极其关键）：
   PyTorch nn.Linear: lora_A (r, in_dim) -> MLX LoRALinear: lora_a (in_dim, r)
   PyTorch nn.Linear: lora_B (out_dim, r) -> MLX LoRALinear: lora_b (r, out_dim)
3. 生成完整 adapter_config.json（保留 4-bit base_quantization 映射、scale = lora_alpha / r）
4. 生成通过 LocalPhotoAI.swift / photo_ai_server.py 全部 SHA-256 与协议指纹校验的 manifest.json。
"""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

from photo_ai_protocol import FINGERPRINT, VERSION

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LOCK = REPO_ROOT / "Tools/OptionalModel/model-manifest.json"
DEFAULT_REF_CONFIG = Path.home() / "Library/Application Support/Phos/MLX/adapter/adapter_config.json"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def map_peft_key_to_mlx(key: str) -> tuple[str, str, str]:
    """返回 (mlx_tensor_key, mlx_module_key, ab_kind['a'|'b'])。"""
    if ".visual." in key or "vision_tower" in key:
        raise ValueError(
            f"检测到视觉塔 LoRA 权重 ({key})。Phos 当前 4-bit 适配器模式仅支持 language_model 侧热插拔；"
            "若微调了视觉塔，请走方案中的「路线 B」：在 Colab merge 到 BF16 后用 mlx_vlm.convert 重导出整包 4-bit 模型。"
        )
    # 兼容常见 PEFT 前缀：
    # base_model.model.model.language_model.layers.12.self_attn.q_proj.lora_A.weight
    # base_model.model.language_model.model.layers.12.mlp.gate_proj.lora_B.default.weight
    m = re.search(
        r"(?:language_model\.(?:model\.)?)?layers\.(\d+)\.(self_attn|mlp)\.([a-z_]+)\.lora_([AB])(?:\.default)?\.weight$",
        key,
    )
    if not m:
        raise ValueError(f"无法识别的 PEFT 张量键名：{key}")
    layer_idx, block, proj, ab = m.groups()
    module_key = f"language_model.model.layers.{layer_idx}.{block}.{proj}"
    ab_low = ab.lower()
    return f"{module_key}.lora_{ab_low}", module_key, ab_low


def build_base_quantization(num_layers: int = 36, bits: int = 4, group_size: int = 64) -> dict:
    q = {"bits": bits, "group_size": group_size, "mode": "affine"}
    out = {"language_model.model.embed_tokens": dict(q)}
    for i in range(num_layers):
        for blk, projs in (
            ("mlp", ("down_proj", "gate_proj", "up_proj")),
            ("self_attn", ("k_proj", "o_proj", "q_proj", "v_proj")),
        ):
            for p in projs:
                out[f"language_model.model.layers.{i}.{blk}.{p}"] = dict(q)
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description="Convert HuggingFace PEFT Qwen3-VL-4B LoRA to Phos MLX adapter")
    parser.add_argument("--peft-dir", type=Path, required=True, help="Colab 导出的 PEFT 目录（含 adapter_model.safetensors 与 adapter_config.json）")
    parser.add_argument("--out-dir", type=Path, required=True, help="输出 Phos MLX adapter 目录")
    parser.add_argument("--name", default="Phos Qwen3-VL-4B Full-Layer LoRA", help="写入 manifest.json 的适配器名称")
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK, help="model-manifest.json 路径")
    parser.add_argument("--ref-adapter-config", type=Path, default=DEFAULT_REF_CONFIG, help="用于复用 base_quantization 的参考 adapter_config.json")
    parser.add_argument("--production", action="store_true", help="标记 productionEligible=true, experimental=false")
    parser.add_argument("--verify-mlx", action="store_true", help="在本机调用 mlx_vlm.load 实测加载校验")
    parser.add_argument("--mlx-model", type=Path, default=Path.home() / "Library/Application Support/Phos/MLX/model")
    args = parser.parse_args()

    try:
        import numpy as np
        from safetensors.numpy import load_file, save_file
    except ImportError as exc:
        raise SystemExit("缺少依赖，请先安装 safetensors 与 numpy（可直接使用 Phos MLX 的 .venv/bin/python）") from exc

    peft_weights_path = args.peft_dir / "adapter_model.safetensors"
    peft_cfg_path = args.peft_dir / "adapter_config.json"
    if not peft_weights_path.is_file() or not peft_cfg_path.is_file():
        raise SystemExit(f"目录缺少 adapter_model.safetensors 或 adapter_config.json：{args.peft_dir}")

    peft_cfg = json.loads(peft_cfg_path.read_text(encoding="utf-8"))
    rank = int(peft_cfg["r"])
    lora_alpha = float(peft_cfg["lora_alpha"])
    scale = lora_alpha / float(rank)

    src_tensors = load_file(str(peft_weights_path))
    mlx_tensors: dict[str, "np.ndarray"] = {}
    module_keys: set[str] = set()

    for k, arr in src_tensors.items():
        mlx_key, mod_key, ab = map_peft_key_to_mlx(k)
        # 转置并转为 float32，确保与 mlx_vlm LoRALinear 形状完全一致
        t = np.ascontiguousarray(arr.astype(np.float32).T)
        if ab == "a" and t.shape[1] != rank:
            raise ValueError(f"{mlx_key} 转置后形状异常 {t.shape}，预期第二维 == rank({rank})")
        if ab == "b" and t.shape[0] != rank:
            raise ValueError(f"{mlx_key} 转置后形状异常 {t.shape}，预期第一维 == rank({rank})")
        mlx_tensors[mlx_key] = t
        module_keys.add(mod_key)

    if not mlx_tensors:
        raise SystemExit("未在 PEFT 权重中找到任何有效的 language_model LoRA 张量。")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    out_weights = args.out_dir / "adapters.safetensors"
    save_file(mlx_tensors, str(out_weights))

    if args.ref_adapter_config.is_file():
        ref_cfg = json.loads(args.ref_adapter_config.read_text(encoding="utf-8"))
        base_quant = ref_cfg.get("base_quantization") or build_base_quantization()
    else:
        base_quant = build_base_quantization()

    out_cfg_data = {
        "base_quantization": base_quant,
        "fine_tune_type": "lora",
        "lora_parameters": {
            "dropout": 0,
            "keys": sorted(module_keys, reverse=True),
            "rank": rank,
            "scale": scale,
        },
        "num_layers": -1,
    }
    out_cfg = args.out_dir / "adapter_config.json"
    out_cfg.write_text(json.dumps(out_cfg_data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    lock = json.loads(args.lock.read_text(encoding="utf-8"))
    manifest = {
        "name": args.name,
        "baseRepo": lock["repo"],
        "baseRevision": lock["revision"],
        "baseConfigSHA256": lock["files"]["config.json"],
        "adapterSHA256": sha256_file(out_weights),
        "adapterConfigSHA256": sha256_file(out_cfg),
        "serializationVersion": VERSION,
        "decoderFingerprint": FINGERPRINT,
        "schemaVersion": "phos-parameter-plan-v2",
        "productionEligible": True,
        "experimental": not args.production,
        "convertedFrom": "huggingface-peft",
        "loraRank": rank,
        "loraScale": scale,
        "adaptedModules": len(module_keys),
    }
    out_manifest = args.out_dir / "manifest.json"
    out_manifest.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(
        f"✓ 转换完成：{len(mlx_tensors)} 个张量（{len(module_keys)} 个模块，rank={rank}, scale={scale}）\n"
        f"  weights:  {out_weights} ({out_weights.stat().st_size / 1e6:.2f} MB)\n"
        f"  config:   {out_cfg}\n"
        f"  manifest: {out_manifest}"
    )

    if args.verify_mlx:
        from mlx_vlm import load
        print(f"正在使用 mlx_vlm.load 实测加载：{args.mlx_model} + {args.out_dir} …")
        _model, _proc = load(str(args.mlx_model), adapter_path=str(args.out_dir))
        print("✓ MLX 实机加载验证通过！可直接复制到 ~/Library/Application Support/Phos/MLX/adapter")


if __name__ == "__main__":
    main()
