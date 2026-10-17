#!/usr/bin/env python3
"""Separate runtime/model installation; never includes personal photos or LoRA."""
import argparse,hashlib,json,os,platform,subprocess,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent

def digest(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for chunk in iter(lambda:f.read(8*1024*1024),b''):h.update(chunk)
 return h.hexdigest()

def verify(root,manifest):
 errors=[n for n,v in manifest['files'].items() if not (root/n).is_file() or digest(root/n)!=v]
 if errors:raise RuntimeError('缺失或校验失败：'+', '.join(errors))

p=argparse.ArgumentParser();p.add_argument('--environment',type=Path,default=Path.home()/'Library/Application Support/Phos/MLX');p.add_argument('--verify-only',action='store_true');a=p.parse_args();dest=a.environment.expanduser().resolve();manifest=json.loads((HERE/'model-manifest.json').read_text())
if a.verify_only:
 verify(dest/'model',manifest)
 python=dest/'.venv/bin/python'
 if not python.is_file():raise RuntimeError('模型权重完整，但缺少 MLX 运行环境')
 subprocess.run([str(python),'-c','import mlx.core,mlx_vlm,transformers;print("MLX runtime imports passed")'],check=True)
 print('模型文件和运行环境检查通过：',dest);sys.exit(0)
if platform.system()!='Darwin' or platform.machine()!='arm64':raise RuntimeError('此安装包用于 Apple Silicon Mac')
if sys.version_info[:2]!=(3,11):raise RuntimeError('请使用 Python 3.11 运行安装脚本')
# Existing environment is verified and kept; partial custom installs need manual repair.
if (dest/'.venv').exists() or (dest/'model').exists():
 raise RuntimeError('目标已有模型或运行环境。请先用 --verify-only 检查；脚本不会覆盖已有环境。新装可用 --environment 另选空文件夹。')
dest.mkdir(parents=True,exist_ok=True)
subprocess.run([sys.executable,'-m','venv',str(dest/'.venv')],check=True)
python=dest/'.venv/bin/python'
subprocess.run([str(python),'-m','pip','install','-r',str(HERE/'requirements.lock.txt')],check=True)
stage=dest/'model.download';env=dict(os.environ,HF_HUB_DISABLE_XET='1');env.pop('HF_HUB_OFFLINE',None);env.pop('TRANSFORMERS_OFFLINE',None)
subprocess.run([str(python),'-c','from huggingface_hub import snapshot_download; import sys; snapshot_download(sys.argv[1],revision=sys.argv[2],local_dir=sys.argv[3])',manifest['repo'],manifest['revision'],str(stage)],env=env,check=True)
verify(stage,manifest);stage.rename(dest/'model')
(dest/'model-installation.json').write_text(json.dumps({'repo':manifest['repo'],'revision':manifest['revision'],'verifiedFiles':len(manifest['files']),'status':'passed'},indent=2))
print('安装并校验完成：',dest)
print('Phos → AI 修图 → 选择模型环境，选择上面的文件夹。')
