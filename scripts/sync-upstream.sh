#!/usr/bin/env bash
# 同步上游 JerryZLiu/Dayflow 到本地的 GLM 定制分支，并推送触发 CI 出包。
#
# 用法：
#   scripts/sync-upstream.sh            # fetch + merge + push（push 自动触发构建）
#
# 冲突处理：merge 失败时手动解决冲突后 `git commit`，再重新执行本脚本。
set -euo pipefail

UPSTREAM="${UPSTREAM:-https://github.com/JerryZLiu/Dayflow.git}"
PUSH_REMOTE="${PUSH_REMOTE:-glmrepo}"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

if ! git remote get-url upstream > /dev/null 2>&1; then
  git remote add upstream "$UPSTREAM"
fi

echo "▶ fetch upstream/main …"
git fetch upstream main --tags

echo "▶ merge upstream/main into $BRANCH …"
if git merge upstream/main --no-edit; then
  echo "✓ merge 完成"
else
  echo ""
  echo "✗ 合并存在冲突，请逐个解决后："
  echo "    git add -A && git commit"
  echo "  然后重新运行本脚本完成推送。"
  exit 1
fi

echo "▶ push $BRANCH → $PUSH_REMOTE/main （推送成功会自动触发 CI 构建）"
git push "$PUSH_REMOTE" "$BRANCH:main"
echo "✓ 完成"
