#!/bin/zsh
# 国内网络安装：把两个下载源换成国内镜像，其余流程与「安装模型.command」完全一致。
# 镜像只影响从哪里下载，模型文件仍按 model-manifest.json 逐个校验 SHA256。
set -eu
TASK_DIR="${0:A:h}"
if ! command -v python3.11 >/dev/null 2>&1; then
  print '请先安装 Apple Silicon Python 3.11，再重新运行。下载：https://www.python.org/downloads/macos/'
  print '（国内下载慢可以用镜像：https://mirrors.huaweicloud.com/python/ ，选 3.11.x 的 macOS universal2 安装包）'
  read '?按回车关闭…'
  exit 1
fi

export HF_ENDPOINT=https://hf-mirror.com
export PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
export PIP_TRUSTED_HOST=pypi.tuna.tsinghua.edu.cn

print '使用国内镜像下载：'
print "  模型  $HF_ENDPOINT"
print "  依赖  $PIP_INDEX_URL"
print ''
print '模型文件仍会逐个校验 SHA256，镜像内容不对会直接报错停下。'
print ''

python3.11 "$TASK_DIR/install_model.py" "$@"
read '?按回车关闭…'
