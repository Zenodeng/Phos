#!/usr/bin/env python3
"""github.com 被代理拦截时，用 Git Data API 把当前工作树推成一个新 commit（走 api.github.com）。
保留远端已有历史：新 commit 的 parent = 远端 main 的 HEAD。
"""
import base64, json, os, subprocess, sys, tempfile, time

TOKEN = os.environ["GH_TOKEN"]
OWNER, REPO = os.environ.get("GH_OWNER", "Zenodeng"), os.environ.get("GH_REPO", "Phos")
MSG = os.environ["GH_MSG"]
API = "https://api.github.com"
ROOT = os.path.dirname(os.path.abspath(__file__)) + "/.."
ROOT = os.path.abspath(ROOT)

def api(method, path, payload=None, quiet=False, retry_key=None, retries=5):
    """retry_key：返回值里出现该键才算成功，否则重试。

    本机代理不稳，blob 上传会随机返回空响应体（形如 {}）——
    失败的文件每次都不一样，属瞬时故障。不加重试的话整批推送会中途失败。
    """
    last = {}
    for attempt in range(retries):
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
            last = json.loads(r.stdout or "{}")
        except json.JSONDecodeError:
            last = {"_raw": r.stdout[:300]}
        if retry_key is None or retry_key in last:
            return last
        if attempt < retries - 1:
            print(f"    重试 {attempt + 1}/{retries - 1}: {path.split('/')[-1]}")
            time.sleep(1.2 * (attempt + 1))
    return last

# 1) 远端当前 HEAD
ref = api("GET", f"/repos/{OWNER}/{REPO}/git/ref/heads/main", retry_key="object")
parent = ref.get("object", {}).get("sha")
if not parent:
    print("取远端 HEAD 失败:", str(ref)[:200]); sys.exit(1)
base_tree = api("GET", f"/repos/{OWNER}/{REPO}/git/commits/{parent}").get("tree", {}).get("sha")
print("远端 HEAD:", parent[:10], "base_tree:", (base_tree or "?")[:10])

# 2) 逐个文件建 blob
# core.quotepath=false：否则中文等路径会被 git 转义成 "\347\272\205..." 的形式，后面 open() 会失败
files = subprocess.run(["git", "-c", "core.quotepath=false", "ls-files"],
                       cwd=ROOT, capture_output=True, text=True).stdout.split("\n")
files = [f for f in files if f]
print(f"上传 {len(files)} 个文件")
tree = []
for rel in files:
    p = os.path.join(ROOT, rel)
    data = open(p, "rb").read()
    b = api("POST", f"/repos/{OWNER}/{REPO}/git/blobs",
            {"content": base64.b64encode(data).decode(), "encoding": "base64"},
            retry_key="sha")
    if "sha" not in b:
        print("  blob 失败:", rel, str(b)[:160]); sys.exit(1)
    mode = "100755" if os.access(p, os.X_OK) else "100644"
    tree.append({"path": rel, "mode": mode, "type": "blob", "sha": b["sha"]})
print(f"  {len(tree)} 个 blob 完成")

# 3) tree（带 base_tree：删除/改名也能被正确反映）
t = api("POST", f"/repos/{OWNER}/{REPO}/git/trees", {"base_tree": base_tree, "tree": tree}, retry_key="sha")
if "sha" not in t:
    print("tree 失败:", str(t)[:220]); sys.exit(1)
print("tree:", t["sha"][:10])

# 4) commit
c = api("POST", f"/repos/{OWNER}/{REPO}/git/commits",
        {"message": MSG, "tree": t["sha"], "parents": [parent]}, retry_key="sha")
if "sha" not in c:
    print("commit 失败:", str(c)[:220]); sys.exit(1)
print("commit:", c["sha"][:10])

# 5) 更新分支
r = api("PATCH", f"/repos/{OWNER}/{REPO}/git/refs/heads/main", {"sha": c["sha"]}, retry_key="object")
print("更新 main:", "OK" if r.get("object") else str(r)[:200])
print("NEW_SHA=" + c["sha"])

# 6) 可选：打附注标签（GH_TAG=v3.1.0）。标签已存在时强制更新 —— 这是触发 Release 构建的关键，
#    只更新 main 不会触发 .github/workflows/release.yml（它监听 push 的 tags: v*）。
TAG = os.environ.get("GH_TAG")
if TAG:
    t = api("POST", f"/repos/{OWNER}/{REPO}/git/tags",
            {"tag": TAG, "message": os.environ.get("GH_TAG_MSG", TAG),
             "object": c["sha"], "type": "commit"}, retry_key="sha")
    if "sha" not in t:
        print("建标签对象失败:", str(t)[:220]); sys.exit(1)
    ref = api("POST", f"/repos/{OWNER}/{REPO}/git/refs",
              {"ref": f"refs/tags/{TAG}", "sha": t["sha"]})
    if not ref.get("object"):
        # 标签已存在：走强制更新（普通 POST 会 422 Reference already exists）
        ref = api("PATCH", f"/repos/{OWNER}/{REPO}/git/refs/tags/{TAG}",
                  {"sha": t["sha"], "force": True})
    print("标签", TAG, "->", c["sha"], "OK" if ref.get("object") else str(ref)[:200])
