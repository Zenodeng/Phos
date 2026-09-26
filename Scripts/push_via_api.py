#!/usr/bin/env python3
"""github.com 被代理拦截时，用 Git Data API 把当前工作树推成一个新 commit（走 api.github.com）。
保留远端已有历史：新 commit 的 parent = 远端 main 的 HEAD。
"""
import base64, json, os, subprocess, sys, tempfile

TOKEN = os.environ["GH_TOKEN"]
OWNER, REPO = os.environ.get("GH_OWNER", "Zenodeng"), os.environ.get("GH_REPO", "RawForge")
MSG = os.environ["GH_MSG"]
API = "https://api.github.com"
ROOT = os.path.dirname(os.path.abspath(__file__)) + "/.."
ROOT = os.path.abspath(ROOT)

def api(method, path, payload=None, quiet=False):
    cmd = ["curl", "-sS", "--max-time", "60", "-X", method,
           "-H", f"Authorization: Bearer {TOKEN}",
           "-H", "Accept: application/vnd.github+json", f"{API}{path}"]
    tmp = None
    if payload is not None:
        tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(payload, tmp); tmp.close()
        cmd += ["--data-binary", "@" + tmp.name]
    r = subprocess.run(cmd, capture_output=True, text=True)
    try:
        return json.loads(r.stdout or "{}")
    except json.JSONDecodeError:
        return {"_raw": r.stdout[:300]}

# 1) 远端当前 HEAD
ref = api("GET", f"/repos/{OWNER}/{REPO}/git/ref/heads/main")
parent = ref.get("object", {}).get("sha")
if not parent:
    print("取远端 HEAD 失败:", str(ref)[:200]); sys.exit(1)
base_tree = api("GET", f"/repos/{OWNER}/{REPO}/git/commits/{parent}").get("tree", {}).get("sha")
print("远端 HEAD:", parent[:10], "base_tree:", (base_tree or "?")[:10])

# 2) 逐个文件建 blob
files = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True).stdout.split()
print(f"上传 {len(files)} 个文件")
tree = []
for rel in files:
    p = os.path.join(ROOT, rel)
    data = open(p, "rb").read()
    b = api("POST", f"/repos/{OWNER}/{REPO}/git/blobs",
            {"content": base64.b64encode(data).decode(), "encoding": "base64"})
    if "sha" not in b:
        print("  blob 失败:", rel, str(b)[:160]); sys.exit(1)
    mode = "100755" if os.access(p, os.X_OK) else "100644"
    tree.append({"path": rel, "mode": mode, "type": "blob", "sha": b["sha"]})
print(f"  {len(tree)} 个 blob 完成")

# 3) tree（带 base_tree：删除/改名也能被正确反映）
t = api("POST", f"/repos/{OWNER}/{REPO}/git/trees", {"base_tree": base_tree, "tree": tree})
if "sha" not in t:
    print("tree 失败:", str(t)[:220]); sys.exit(1)
print("tree:", t["sha"][:10])

# 4) commit
c = api("POST", f"/repos/{OWNER}/{REPO}/git/commits",
        {"message": MSG, "tree": t["sha"], "parents": [parent]})
if "sha" not in c:
    print("commit 失败:", str(c)[:220]); sys.exit(1)
print("commit:", c["sha"][:10])

# 5) 更新分支
r = api("PATCH", f"/repos/{OWNER}/{REPO}/git/refs/heads/main", {"sha": c["sha"]})
print("更新 main:", "OK" if r.get("object") else str(r)[:200])
print("NEW_SHA=" + c["sha"])
