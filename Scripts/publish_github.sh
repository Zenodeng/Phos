#!/bin/sh
# 一键发布到 GitHub：建仓库 → 推送 → 开 Actions 权限 → 触发首次构建
# 用法：GH_TOKEN=<你的 Personal Access Token> ./Scripts/publish_github.sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

REPO_NAME="${REPO_NAME:-Phos}"
: "${GH_TOKEN:?请先设置 GH_TOKEN（需要 repo + workflow 权限）}"
export GH_TOKEN

API="https://api.github.com"
AUTH="Authorization: Bearer $GH_TOKEN"
curl_json() { curl -fsS -H "$AUTH" -H "Accept: application/vnd.github+json" "$@"; }

# 不把 token 写入 .git/config；GitHub 使用 HTTP Basic 的临时 askpass 提供认证。
ASKPASS="$(mktemp "${TMPDIR:-/tmp}/phos-git-askpass.XXXXXX")"
cleanup() {
    /bin/rm -f "$ASKPASS" 2>/dev/null || true
    unset GIT_ASKPASS GIT_TERMINAL_PROMPT
}
trap cleanup EXIT HUP INT TERM
cat > "$ASKPASS" <<'EOF'
#!/bin/sh
case "$1" in
    *Username*) printf '%s\n' "x-access-token" ;;
    *Password*) printf '%s\n' "$GH_TOKEN" ;;
    *) printf '\n' ;;
esac
EOF
chmod 700 "$ASKPASS"
export GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0

# 1) 建仓库（已存在时继续）
echo "→ 创建仓库 $REPO_NAME"
code="$(curl_json -o /tmp/phos_repo.json -w '%{http_code}' -X POST "$API/user/repos" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"$REPO_NAME\",\"description\":\"为本机摄影流程打造的专业向 RAW 修图软件（macOS / Swift / Core Image / Vision）\",\"private\":false,\"has_issues\":true,\"has_wiki\":false,\"auto_init\":false}" || true)"
echo "  HTTP $code"
case "$code" in
    401|403) echo "token 无效或权限不足（需要 repo + workflow）" >&2; exit 2 ;;
    2*) ;;
    422) echo "仓库可能已存在，继续使用" ;;
    *) echo "创建仓库返回异常 HTTP $code" >&2; exit 3 ;;
esac

OWNER="$(curl_json "$API/user" | /usr/bin/sed -n 's/.*"login" *: *"\([^"]*\)".*/\1/p' | /usr/bin/head -1)"
[ -n "$OWNER" ] || { echo "取不到用户名" >&2; exit 4; }
echo "  用户: $OWNER"

# 2) 推送：remote 永远保存无 token 的 URL。
REMOTE="https://github.com/$OWNER/$REPO_NAME.git"
if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$REMOTE"
else
    git remote add origin "$REMOTE"
fi
git branch -M main 2>/dev/null || true
echo "→ 推送代码"
git push -u origin main

# 3) 开 Actions 写权限（不开的话 Release 上传会 403）
echo "→ 开启 Actions 写权限"
curl_json -o /dev/null -w '  HTTP %{http_code}\n' -X PUT \
  "$API/repos/$OWNER/$REPO_NAME/actions/permissions/workflow" \
  -H 'Content-Type: application/json' \
  -d '{"default_workflow_permissions":"write","can_approve_pull_request_reviews":false}'

# 4) 打标签触发 Release 构建
if [ "${SKIP_TAG:-0}" != "1" ]; then
    echo "→ 打标签 v1.0.0 触发构建"
    git tag -f v1.0.0 -m "Phos 1.0.0" 2>/dev/null || true
    git push -f origin v1.0.0
fi

echo
echo "完成："
echo "  仓库   https://github.com/$OWNER/$REPO_NAME"
echo "  构建   https://github.com/$OWNER/$REPO_NAME/actions"
echo "  发布   https://github.com/$OWNER/$REPO_NAME/releases"
