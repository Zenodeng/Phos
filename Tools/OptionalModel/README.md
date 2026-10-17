# Phos 可选本地 AI 模型

主应用与模型分开提供。此小包只有安装脚本、固定版本依赖清单和校验清单，不含3GB权重或用户照片。

- 模型：mlx-community/Qwen3-VL-4B-Instruct-4bit
- 固定版本：2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b
- 权重及配置约3.1GB，此外还需Python和MLX依赖；建议至少预留8GB磁盘空间。
- 运行平台：Apple Silicon Mac，Phos要求macOS26以上；16GB统一内存为本机已测试配置，8GB未验证。
- 模型上游许可证：Apache-2.0。Phos“仅供学术研究”的定位不改变模型原始许可。
- 来源：https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit

## 新用户安装

1. 安装arm64 Python3.11（https://www.python.org/downloads/macos/）。
2. 解压本包，双击“安装模型.command”。首次需联网，脚本从Python软件源安装固定运行依赖，从Hugging Face拉取固定模型版本，校验17个文件SHA256。
3. 默认安装到 `~/Library/Application Support/Phos/MLX`。Phos会使用默认位置；自定义目录在“AI修图 → 选择模型环境”选择包含 `.venv` 和 `model` 的外层文件夹。
4. 安装完毕后推理使用本机服务，无需把照片发送到云端。

脚本不会覆盖已有环境；安装中断后保留现场。需要重新安装时，可通过 `python3.11 install_model.py --environment /绝对路径/新的Phos-MLX` 安装到另一个空目录，然后在应用内选择。不要移动已建好的venv；它包含绝对解释器路径。

## 已有模型

无需重复下载。运行 `python3 install_model.py --verify-only` 校验默认位置的文件和MLX导入；也可加 `--environment` 指定位置。直接下载Hugging Face文件只有权重，不会自动获得MLX Python运行环境。

本次已通过：默认环境17文件哈希、运行依赖导入、安装脚本语法、本机模型图片API实测。尚未在全新Mac或全新venv上完整走完安装，不能宣传“所有Mac一键安装”。网络受限时应显示失败原因，由用户自行选择可信网络；脚本不自动切换未审核镜像。

## 发布者

推荐提供 `Phos.app` 主程序下载 + 本安装小包两个入口。主程序不要嵌入开发者 `.venv`、大模型、训练集、缓存或个人照片。需要离线镜像时，仅另打包校验后的model目录及上游LICENSE/NOTICE，模型原始授权与Phos自身用途声明分开保留。

## Phos 4.0.0 补充

用户已选择使用轻量微调版。此安装包仍下载固定原版底模；Phos 4.0.0 应用内另附约1.3MB的LoRA适配器并在推理时加载。两者共同构成此次微调模型，无需重新下载合并的3GB权重。不会将原版模型误称为已经微调的权重。
