#!/bin/sh
# 一键发布到 GitHub：建仓库 → 推送 → 开 Actions 权限 → 触发首次构建
# 用法：GH_TOKEN=<你的 Personal Access Token> ./Scripts/publish_github.sh
set -e
REPO_NAME="${REPO_NAME:-RawForge}"
[ -n "$GH_TOKEN" ] || { echo "请先：export GH_TOKEN=你的token（classic，勾 repo + workflow）" >&2; exit 1; }

API="https://api.github.com"
AUTH="Authorization: Bearer $GH_TOKEN"
curl_json() { curl -sS -H "$AUTH" -H "Accept: application/vnd.github+json" "$@"; }

# 1) 建仓库（已存在则忽略）
echo "→ 创建仓库 $REPO_NAME"
curl_json -o /tmp/rf_repo.json -w "%{http_code}" -X POST "$API/user/repos" \
  -d "{\"name\":\"$REPO_NAME\",\"description\":\"为本机摄影流程打造的专业向 RAW 修图软件（macOS / Swift / Core Image / Vision）\",\"homepage\":\"\",\"private\":false,\"has_issues\":true,\"has_wiki\":false,\"auto_init\":false}" > /tmp/rf_code.txt || true
CODE="$(cat /tmp/rf_code.txt | tail -c 3)"
echo "  HTTP $CODE"
if [ "$CODE" = "401" ] || [ "$CODE" = "403" ]; then
  echo "token 无效或权限不足（需要 repo + workflow）" >&2; exit 2
fi

OWNER="$(curl_json "$API/user" | sed -n 's/.*"login" *: *"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$OWNER" ] || { echo "取不到用户名" >&2; exit 3; }
echo "  用户: $OWNER"

# 2) 推送
cd "$(dirname "$0")/.."
git branch -M main 2>/dev/null || true
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "https://$GH_TOKEN@github.com/$OWNER/$REPO_NAME.git"
else
  git remote add origin "https://$GH_TOKEN@github.com/$OWNER/$REPO_NAME.git"
fi
echo "→ 推送代码"
git push -u origin main
# 推完立刻把 token 从 remote URL 里抹掉，别留在 .git/config 明文里
git remote set-url origin "https://github.com/$OWNER/$REPO_NAME.git"

# 3) 开 Actions 写权限（不开的话 Release 上传会 403）
echo "→ 开启 Actions 写权限"
curl_json -o /dev/null -w "  HTTP %{http_code}\n" -X PUT \
  "$API/repos/$OWNER/$REPO_NAME/actions/permissions/workflow" \
  -d '{"default_workflow_permissions":"write","can_approve_pull_request_reviews":false}'

# 4) 打标签触发 Release 构建（CI 会在 tag 推送时编译打包并发 Release）
if [ "${SKIP_TAG:-0}" != "1" ]; then
  echo "→ 打标签 v1.0.0 触发构建"
  git tag -f v1.0.0 -m "RawForge 1.0.0" 2>/dev/null || true
  git push -f origin v1.0.0
fi

echo
echo "完成："
echo "  仓库   https://github.com/$OWNER/$REPO_NAME"
echo "  构建   https://github.com/$OWNER/$REPO_NAME/actions"
echo "  发布   https://github.com/$OWNER/$REPO_NAME/releases"
