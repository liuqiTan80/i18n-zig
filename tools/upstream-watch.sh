#!/usr/bin/env bash
# 上游漂移周检（第 339 轮 D198）：对拍「本仓钉死的 Zig」与「ziglang.org 最新稳定版」；有漂移就在
# 最新版上重装工具链、复跑诊断语料回放，并把「哪条报文文本变了」写成报告。
#
# 存在动因：母语回译是按上游报文**逐条对齐**的，上游改文案 → 译文命中不了 → 用户看到裸英文
# （回译静默退化）。而 CI 两面都装钉死版，等于永远只测「已知会绿」的那一侧，下一版会不会坏无人知晓。
# 本脚本把这件事变成每周一次的有信号通道。
#
# 用法：
#   bash tools/upstream-watch.sh                 # 完整周检（漂移则装新版并复跑语料）
#   bash tools/upstream-watch.sh --print-pinned  # 只打印钉死版本（CI 据此拼下载 URL，避免第三处手抄）
# 环境变量 UPSTREAM_PINNED_OVERRIDE=<ver> 临时伪造钉死版本（本地演练漂移通道；CI 一律不设）。
#
# 退出码：0 = 无漂移；1 = 有漂移（不论语料是否分道，皆须人来评估并升钉）；2 = 用法/前置错。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gh_ci="$root/.github/workflows/ci.yml"
index_url="https://ziglang.org/download/index.json"
drift_marker="DRIFT(上游漂移)"
corpus_sh="$root/tools/diag-corpus.sh"
pin_probe='download/[0-9]\+\.[0-9]\+\.[0-9]\+'

pinned="$(grep -oE 'download/[0-9]+\.[0-9]+\.[0-9]+' "$gh_ci" | head -1 | cut -d/ -f2)"
if [ -z "$pinned" ]; then
  echo "FAIL: 无法从 $gh_ci 取钉死版本（该面的 download/<ver>/ 形制漂了）"
  exit 2
fi

if [ "${1:-}" = "--print-pinned" ]; then
  printf '%s\n' "$pinned"
  exit 0
fi
if [ -n "${UPSTREAM_PINNED_OVERRIDE:-}" ]; then
  echo "NOTE: 钉死版本被 UPSTREAM_PINNED_OVERRIDE 改写为 ${UPSTREAM_PINNED_OVERRIDE}（仅本地演练用）"
  pinned="$UPSTREAM_PINNED_OVERRIDE"
fi

latest="$(curl -sfL "$index_url" | python3 -c '
import json, re, sys
d = json.load(sys.stdin)
vs = [k for k in d if k != "master" and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", k)]
if not vs:
    sys.exit(1)
print(sorted(vs, key=lambda s: [int(x) for x in s.split(".")])[-1])
')" || { echo "FAIL: 取不到上游版本（$index_url 不可达或形制变）"; exit 2; }

echo "钉死版本：$pinned　上游最新稳定：$latest"
if [ "$pinned" = "$latest" ]; then
  echo "PASS：无上游漂移（钉死版即最新稳定版），语料周检免跑"
  exit 0
fi

echo "$drift_marker：上游已出 $latest，本仓仍钉 $pinned——以下为「在 $latest 上重跑」的结果"
summary="${GITHUB_STEP_SUMMARY:-}"
[ -n "$summary" ] && { printf '## 上游漂移周检\n\n- %s：`%s` → `%s`\n\n' "$drift_marker" "$pinned" "$latest" >>"$summary"; }

old_exe="$root/zig-out/bin/zzc"
[ -x "$old_exe" ] || { echo "FAIL: 基线产物不存在（先跑 zig build 再周检）：$old_exe"; exit 2; }

tmp="$(mktemp -d)"
tar_name="zig-x86_64-linux-$latest"
if ! curl -sfLo "$tmp/$tar_name.tar.xz" "https://ziglang.org/download/$latest/$tar_name.tar.xz"; then
  echo "FAIL: 上游发行包下载失败：$tar_name.tar.xz"
  rm -rf "$tmp"; exit 2
fi
tar -xf "$tmp/$tar_name.tar.xz" -C "$tmp" || { echo "FAIL: 解包失败"; rm -rf "$tmp"; exit 2; }
new_bin="$tmp/$tar_name/zig"
[ -x "$new_bin" ] || { echo "FAIL: 解包后找不到 $new_bin"; rm -rf "$tmp"; exit 2; }
echo "已装上游工具链：$("$new_bin" version)"

echo "—— 用上游版构建 zzc（本仓源码是否还能编过，第一条信号）"
if ! (cd "$root" && PATH="$tmp/$tar_name:$PATH" "$new_bin" build --cache-dir "$tmp/cache" --prefix "$tmp/out" >"$tmp/build.log" 2>&1); then
  echo "FAIL: 上游 $latest 编不过本仓源码——升代须先过编译关，日志首 20 行："
  head -20 "$tmp/build.log"
  [ -n "$summary" ] && printf -- '- 构建：**上游编不过**（日志首 20 行见运行器输出）\n' >>"$summary"
  rm -rf "$tmp"; exit 1
fi
new_exe="$tmp/out/bin/zzc"
echo "构建通过：$("$new_exe" version | head -1)"

echo "—— 诊断语料回放：钉死版 vs 上游版"
bash "$corpus_sh" "$old_exe" >"$tmp/corpus_old.txt" 2>&1; rc_old=$?
bash "$corpus_sh" "$new_exe" >"$tmp/corpus_new.txt" 2>&1; rc_new=$?
echo "钉死版回放 rc=$rc_old／上游版回放 rc=$rc_new"
if [ "$rc_old" -ne "$rc_new" ] || ! diff -q "$tmp/corpus_old.txt" "$tmp/corpus_new.txt" >/dev/null; then
  echo "FAIL: 同一批触发源码在两版上游下**输出分道**——回译表须按新文案重对齐。差异："
  diff -u "$tmp/corpus_old.txt" "$tmp/corpus_new.txt" | head -40
  [ -n "$summary" ] && printf -- '- 语料回放：**分道**（rc %d → %d）\n' "$rc_old" "$rc_new" >>"$summary"
  rm -rf "$tmp"; exit 1
fi
echo "语料回放逐字同构（报文文本未漂）"
[ -n "$summary" ] && printf -- '- 语料回放：同构（rc 一致且输出逐字相同）\n- 结论：仍须人来评估升代\n' >>"$summary"
rm -rf "$tmp"
exit 1
