#!/usr/bin/env bash
# 双远端同步（第 335 轮 D194）：把当前分支同时推到 origin（gitcode 主仓）与 github（镜像仓），
# 推完逐仓回读 refs/heads/<分支> 的 sha 并与本地 HEAD 比对——漏推一侧或某侧被拒，立即点名，
# 不再靠「我记得推过两个」。
#
# 用法：bash tools/push-both.sh [分支]        （默认 main；不接其它旗标）
#
# 设计约束（改脚本前请连注释一起看）：
#   1. 工作区不干净就拒跑——未提交的改动不会被推，「推了却不同」正是本脚本要消灭的形态；
#   2. 不带 --force、不带 --no-verify——强制推与跳钩子不该出现在日常同步里；
#   3. 只推分支、不推 tag——发版由 `.github/workflows/ci.yml` 的 release job 负责（tag 即触发）；
#   4. 只用 git 原语（push / ls-remote），不联网取任何外部件。
set -euo pipefail

cd "$(dirname "$0")/.."
branch="${1:-main}"
remotes=(origin github)

dirty="$(git status --porcelain)"
if [ -n "$dirty" ]; then
  printf '%s\n' "拒绝：工作区有未提交改动，先提交再双推：" "$dirty"
  exit 1
fi

head="$(git rev-parse HEAD)"
printf '本地 HEAD  %s（%s）\n' "${head:0:12}" "$branch"

for r in "${remotes[@]}"; do
  if ! git remote get-url "$r" >/dev/null 2>&1; then
    printf '拒绝：缺远端 %s——先 git remote add 再跑。\n' "$r"
    exit 1
  fi
done

for r in "${remotes[@]}"; do
  printf '推送 → %s\n' "$r"
  git push "$r" "$branch"
done

# 回读：两仓 sha 必须等于本地 HEAD，不一致就点名是哪一侧（这才是「同步」的判据）
fail=0
for r in "${remotes[@]}"; do
  got="$(git ls-remote --heads "$r" "refs/heads/$branch" | cut -f1)"
  if [ "$got" = "$head" ]; then
    printf 'OK   %-6s %s\n' "$r" "${got:0:12}"
  else
    printf 'FAIL %-6s %s ≠ 本地 %s\n' "$r" "${got:0:12}" "${head:0:12}"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  printf '%s\n' "两侧不一致：查上面 FAIL 那侧的分支保护与权限，修好后重跑本脚本。"
fi
exit "$fail"
