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
#   bash tools/upstream-watch.sh --verdict-only  # 只出判定即退（不装工具链、不复跑语料；本地演练与冒烟臂用）
# 环境变量 UPSTREAM_PINNED_OVERRIDE=<ver> 临时伪造钉死版本（本地演练漂移通道；CI 一律不设）。
# 环境变量指向上游版本索引的本机快照文件时，改读该快照而不触网（第 342 轮 D201：判据的三条方向臂
# 必须能在本地离线真跑——否则「落后／领先」两臂在无网机器上永远走不到，判据漂了要等下周 CI 才现形；
# CI 一律不设，周检本体照旧走真索引）。
# 环境变量 UPSTREAM_ZIG_BIN=<可执行文件> 时，把它当「上游工具链」而不下载、不解包（第 343 轮 D202：
# 装版臂此前**整条臂本地零通道**——构建闸／语料分道对比／GITHUB_STEP_SUMMARY 写入三段只能等真发行包，
# 而落码前的实跑坐实了其中一段确实在说谎，见下）。CI 一律不设。
# 环境变量 UPSTREAM_BASE_EXE=<可执行文件> 时，用它当「钉死版产物」而不取 zig-out/bin/zzc（同轮：基线
# 侧也须可注入，否则「基线自身即红」这形在任何本地与 CI 机器上都构造不出来，缺陷只能靠读代码发现）。
#
# 判定三态（第 342 轮 D201 补第三态）：钉版 == 上游最新稳定 → 无漂移；钉版 < 上游最新稳定 → 上游漂移
# （须人来评估并升钉）；钉版 > 上游最新稳定 → 本仓钉的那一版还没进上游稳定索引，既无更新可跟，也不该
# 去装一枚**更旧**的工具链「在旧版上重跑」。改前只有「相等 / 不等」两臂，领先态被吞进不等臂，于是实跑
# 报出「DRIFT：上游已出 0.17.0，本仓仍钉 0.99.0」这种方向反了的红，还白拉一次发行包再退 1。
#
# 退出码：0 = 无漂移（含领先态）；1 = 有漂移（不论语料是否分道，皆须人来评估并升钉）；2 = 用法/前置错
# （含第 343 轮 D202 新立的「基线自身即红」——那是观测失效而非上游漂，报 1 会让人去评估升代，而真正
# 该修的是本仓语料表）。
set -uo pipefail

# 旗标先验后动（承 D180「装前即拒」）：笔误旗标直接退 2，不静默吞掉旁参再按完整周检跑一遍。
print_pinned=0
verdict_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --print-pinned) print_pinned=1 ;;
    --verdict-only) verdict_only=1 ;;
    *) echo "FAIL: 未知旗标「$1」——本脚本只认 --print-pinned 与 --verdict-only"; exit 2 ;;
  esac
  shift
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gh_ci="$root/.github/workflows/ci.yml"
index_url="https://ziglang.org/download/index.json"
drift_marker="DRIFT(上游漂移)"
pass_verdict="PASS：无上游漂移"
ahead_marker="AHEAD(上游钉版领先)"
index_fixture="${UPSTREAM_INDEX_FIXTURE:-}"
corpus_sh="$root/tools/diag-corpus.sh"
# 装版臂的两枚离线入口（第 343 轮 D202，CI 一律不设）：上游侧免下载、基线侧可注入。
upstream_zig_bin="${UPSTREAM_ZIG_BIN:-}"
base_exe="${UPSTREAM_BASE_EXE:-}"
# 基线自红的态标记（与三条方向态标记同样由 hub 单源）：改前两版 rc 同为非零且输出逐字相同时，脚本
# 打「语料回放逐字同构（报文文本未漂）」并把「同构」写进 summary——那是个正向读数，而事实是两边
# 一样地坏。极性闸先于对比闸（承第 340 轮 D199「速度闸前先过极性闸」同族形制）。
base_red_marker="FAIL: 基线自身即红"
# 同构／分道两句话术同样收编为脚本内单源变量（第 343 轮 D202）：冒烟臂按这两枚判据读极性，独改其一即
# 「红了读不出是哪类红」——与 339/342 轮的三态标记一个形制。
parity_verdict="语料回放逐字同构（报文文本未漂）"
diverge_marker="输出分道"
# 钉版提取正则全脚本只此一枚且**必被消费**（第 342 轮 D201 消「一死一活同域两形」：改前本行位置躺着
# 一枚从未被引用的 BRE 形探针，而真正在用的是 grep 行内的 ERE 字面量——升钉时若有人改的是死的那枚，
# 活的仍按旧形取版，全部门禁零信号）。
pin_re='download/[0-9]+\.[0-9]+\.[0-9]+'

pinned="$(grep -oE "$pin_re" "$gh_ci" | head -1 | cut -d/ -f2)"
if [ -z "$pinned" ]; then
  echo "FAIL: 无法从 $gh_ci 取钉死版本（该面的 download/<ver>/ 形制漂了）"
  exit 2
fi

if [ "$print_pinned" = 1 ]; then
  printf '%s\n' "$pinned"
  exit 0
fi
if [ -n "${UPSTREAM_PINNED_OVERRIDE:-}" ]; then
  echo "NOTE: 钉死版本被 UPSTREAM_PINNED_OVERRIDE 改写为 ${UPSTREAM_PINNED_OVERRIDE}（仅本地演练用）"
  pinned="$UPSTREAM_PINNED_OVERRIDE"
fi

# 稳定版号抽取：只认形如 <maj>.<min>.<patch> 的键，排除 master，按三段数值升序取末位
# （不用字符串序——"0.9.0" 字典序大于 "0.17.0"，据此判漂移会常年假红）。
index_py='
import json, re, sys
d = json.load(sys.stdin)
vs = [k for k in d if k != "master" and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", k)]
if not vs:
    sys.exit(1)
print(sorted(vs, key=lambda s: [int(x) for x in s.split(".")])[-1])
'

if [ -n "$index_fixture" ]; then
  if [ ! -r "$index_fixture" ]; then
    echo "FAIL: 版本索引快照不可读：$index_fixture"
    exit 2
  fi
  echo "NOTE: 走上游版本索引快照（离线判定，仅本地演练/冒烟臂用）：$index_fixture"
  latest="$(python3 -c "$index_py" <"$index_fixture")" || { echo "FAIL: 快照里取不到稳定版（$index_fixture 形制变或无合法版本键）"; exit 2; }
else
  latest="$(curl -sfL "$index_url" | python3 -c "$index_py")" || { echo "FAIL: 取不到上游版本（$index_url 不可达或形制变）"; exit 2; }
fi

echo "钉死版本：$pinned　上游最新稳定：$latest"
# 两版中较旧者（数值序，不是字典序）——它是三条方向臂的唯一判据机器。
older="$(printf '%s\n%s\n' "$pinned" "$latest" | sort -V | head -1)"
if [ "$pinned" = "$latest" ]; then
  echo "$pass_verdict（钉死版即最新稳定版），语料周检免跑"
  exit 0
fi
if [ "$older" = "$latest" ]; then
  echo "$ahead_marker：钉死版 $pinned 比上游最新稳定 $latest 还新——上游稳定索引尚未收录本仓钉版，无更新可跟，也无从在更旧的工具链上重跑，本轮免跑"
  exit 0
fi
echo "$drift_marker：上游已出 $latest，本仓仍钉 $pinned——以下为「在 $latest 上重跑」的结果"
if [ "$verdict_only" = 1 ]; then
  echo "NOTE: --verdict-only 已生效——只出判定，不装上游工具链、不复跑语料（退码仍为 1，与完整周检同判）"
  exit 1
fi
summary="${GITHUB_STEP_SUMMARY:-}"
[ -n "$summary" ] && { printf '## 上游漂移周检\n\n- %s：`%s` → `%s`\n\n' "$drift_marker" "$pinned" "$latest" >>"$summary"; }

old_exe="${base_exe:-$root/zig-out/bin/zzc}"
[ -x "$old_exe" ] || { echo "FAIL: 基线产物不存在（先跑 zig build 再周检）：$old_exe"; exit 2; }

tmp="$(mktemp -d)"
tar_name="zig-x86_64-linux-$latest"
tar_dir="$tmp/$tar_name"
if [ -n "$upstream_zig_bin" ]; then
  new_bin="$upstream_zig_bin"
  [ -x "$new_bin" ] || { echo "FAIL: UPSTREAM_ZIG_BIN 指向的不是可执行文件：$new_bin"; rm -rf "$tmp"; exit 2; }
  echo "已装上游工具链（离线注入，未下载发行包）：$("$new_bin" version)"
else
  if ! curl -sfLo "$tmp/$tar_name.tar.xz" "https://ziglang.org/download/$latest/$tar_name.tar.xz"; then
    echo "FAIL: 上游发行包下载失败：$tar_name.tar.xz"
    rm -rf "$tmp"; exit 2
  fi
  tar -xf "$tmp/$tar_name.tar.xz" -C "$tmp" || { echo "FAIL: 解包失败"; rm -rf "$tmp"; exit 2; }
  new_bin="$tar_dir/zig"
  [ -x "$new_bin" ] || { echo "FAIL: 解包后找不到 $new_bin"; rm -rf "$tmp"; exit 2; }
  echo "已装上游工具链：$("$new_bin" version)"
fi

echo "—— 用上游版构建 zzc（本仓源码是否还能编过，第一条信号）"
if ! (cd "$root" && PATH="$tar_dir:$PATH" "$new_bin" build --cache-dir "$tmp/cache" --prefix "$tmp/out" >"$tmp/build.log" 2>&1); then
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
if [ "$rc_old" != 0 ]; then
  echo "$base_red_marker：钉死版 $pinned 的语料回放本就退 $rc_old——此时两版输出相同只说明「两边一样地坏」，"
  echo "  不说明上游报文未漂；分道对比失去参照系，本轮判定不作数（先修本仓语料表再周检）。"
  [ -n "$summary" ] && printf -- '- 语料回放：**基线自红**（rc=%d，同构与否不作数）\n' "$rc_old" >>"$summary"
  rm -rf "$tmp"; exit 2
fi
if [ "$rc_old" -ne "$rc_new" ] || ! diff -q "$tmp/corpus_old.txt" "$tmp/corpus_new.txt" >/dev/null; then
  echo "FAIL: 同一批触发源码在两版上游下**$diverge_marker**——回译表须按新文案重对齐。差异："
  diff -u "$tmp/corpus_old.txt" "$tmp/corpus_new.txt" | head -40
  [ -n "$summary" ] && printf -- '- 语料回放：**分道**（rc %d → %d）\n' "$rc_old" "$rc_new" >>"$summary"
  rm -rf "$tmp"; exit 1
fi
echo "$parity_verdict"
[ -n "$summary" ] && printf -- '- 语料回放：同构（rc 一致且输出逐字相同）\n- 结论：仍须人来评估升代\n' >>"$summary"
rm -rf "$tmp"
exit 1
