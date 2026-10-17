#!/bin/zsh
set -eu
TASK_DIR="${0:A:h}"
if ! command -v python3.11 >/dev/null 2>&1; then
  print '请先安装 Apple Silicon Python 3.11，再重新运行。下载：https://www.python.org/downloads/macos/'
  read '?按回车关闭…'
  exit 1
fi
python3.11 "$TASK_DIR/install_model.py" "$@"
read '?按回车关闭…'
