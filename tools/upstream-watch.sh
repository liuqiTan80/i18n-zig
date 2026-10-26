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
#   bash tools/upstream-watch.sh --print-target  # 只打印本机平台位（零网络；第 344 轮 D203 加，供臂对账派生）
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
# 环境变量 UPSTREAM_HOST_TUPLE_OVERRIDE=<arch>-<os> 时，用它当「本机平台位」而不调 uname 派生（第 344 轮
# D203：装版臂的包位按平台分键，「上游索引无本平台条目」这形须能在任意一台机器上构造出来，否则本轮
# 新加的自检闸只有一形可测。CI 一律不设）。
#
# 判定三态（第 342 轮 D201 补第三态）：钉版 == 上游最新稳定 → 无漂移；钉版 < 上游最新稳定 → 上游漂移
# （须人来评估并升钉）；钉版 > 上游最新稳定 → 本仓钉的那一版还没进上游稳定索引，既无更新可跟，也不该
# 去装一枚**更旧**的工具链「在旧版上重跑」。改前只有「相等 / 不等」两臂，领先态被吞进不等臂，于是实跑
# 报出「DRIFT：上游已出 0.17.0，本仓仍钉 0.99.0」这种方向反了的红，还白拉一次发行包再退 1。
#
# 退出码：0 = 无漂移（含领先态）；1 = 有漂移（不论语料是否分道，皆须人来评估并升钉）；2 = 用法/前置错
# （含第 343 轮 D202 新立的「基线自身即红」——那是观测失效而非上游漂，报 1 会让人去评估升代，而真正
# 该修的是本仓语料表）。
#
# 装版臂的自检闸（第 344 轮 D203）：改前脚本对本机平台位**一字硬编**（`zig-x86_64-linux-$latest`），对下到
# 的 57 MB 发行包**零校验**（上游索引明明给了 `shasum`），对解出来的二进制能否运行**不问**（`version` 打空
# 也照样放行）。落码前实锤三形，全部把「自身观测通道坏了」写成「关于上游的结论」：①错包（内容非上游那枚）
# → `FAIL: 上游 0.99.0 编不过本仓源码` 退 1；②包位取不到 → `FAIL: 上游发行包下载失败：<tar>` 退 2，话术里
# 连平台位都不出现；③本平台跑不了这枚包（异平台的真实后果）→ `已装上游工具链：` 打空后同样退 1 报「编不过」。
# 退 1 的语义是「有漂移、人来评估升代」，于是三形都在建议人去做一件与事实无关的事。本轮把包位改成本机
# 派生、把 URL 与校验和改成从**同一份上游索引**取，并加三道自检闸（校验和相符／二进制能跑／版本自证），
# 自检不过诸形一律 **`FAIL: 上游工具链自检不过` 退 2**（前置错族：校验和不符／无 sha 工具／包形制不是
# .tar.xz／本平台跑不了／版本自证不符），不再产出关于上游的结论；索引无本平台条目则单独成标记。
set -uo pipefail

# 旗标先验后动（承 D180「装前即拒」）：笔误旗标直接退 2，不静默吞掉旁参再按完整周检跑一遍。
print_pinned=0
print_target=0
verdict_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --print-pinned) print_pinned=1 ;;
    --print-target) print_target=1 ;;
    --verdict-only) verdict_only=1 ;;
    *) echo "FAIL: 未知旗标「$1」——本脚本只认 --print-pinned、--print-target 与 --verdict-only"; exit 2 ;;
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
# 装版臂的**平台位**离线入口（第 344 轮 D203，CI 一律不设）：把「本机是哪枚平台」换成别枚 tuple，使
# 「上游索引无本平台条目」这形在任意一台机器上都能构造出来——改前平台位是脚本内唯一一枚硬编字面。
host_tuple_override="${UPSTREAM_HOST_TUPLE_OVERRIDE:-}"
# 上游索引里指向发行包的两枚字段名（第 344 轮 D203 收编单源）：包 URL 与校验和都从**同一份索引文本**取，
# 不再手抄 `zig-x86_64-linux-$latest` 形制——那是本脚本相对上游契约的第二处猜测（第一处是版本本身，已由
# ci.yml 单源）。
tarball_field="tarball"
shasum_field="shasum"
# 自检不过的态标记（第 344 轮 D203）：校验和不符 / 解包后跑不起来 / 版本自证不符 / 本机无 sha 工具，
# 四形皆**前置错族（退 2）而不是漂移族（退 1）**——退 1 会让人去评估升代，而那四形里上游什么都没做。
selfcheck_fail_marker="FAIL: 上游工具链自检不过"
# 索引里无本平台条目时的态标记（同轮）：改前异平台机器上要么 x86_64 包拿到却跑不了（照样被报成
# 「上游编不过本仓」），要么 404 被报成泛泛的「下载失败」——两种病因共用一句话术且都不提平台位。
no_platform_marker="FAIL: 上游索引无本平台发行包条目"
# 钉版提取正则全脚本只此一枚且**必被消费**（第 342 轮 D201 消「一死一活同域两形」：改前本行位置躺着
# 一枚从未被引用的 BRE 形探针，而真正在用的是 grep 行内的 ERE 字面量——升钉时若有人改的是死的那枚，
# 活的仍按旧形取版，全部门禁零信号）。
pin_re='download/[0-9]+\.[0-9]+\.[0-9]+'

# 本机平台位派生（第 344 轮 D203）：上游索引按 `<arch>-<os>` 分键给包（实测 0.17.0 有 29 枚带 tarball 的
# 平台键：aarch64-linux、x86_64-macos、riscv64-linux…），而改前只猜一枚 x86_64-linux。本机恰好是它，于是
# 本仓自 339 轮落地以来从未现形；两台 uname 返值需改名（arm64→aarch64、Darwin→macos）靠下面两个 case。
host_arch="$(uname -m)"
case "$host_arch" in
  arm64) host_arch="aarch64" ;;
esac
host_os="$(uname -s)"
case "$host_os" in
  Linux) host_os="linux" ;;
  Darwin) host_os="macos" ;;
  *) host_os="$(printf '%s' "$host_os" | tr '[:upper:]' '[:lower:]')" ;;
esac
host_tuple="$host_arch-$host_os"
if [ -n "$host_tuple_override" ]; then
  echo "NOTE: 本机平台位被 UPSTREAM_HOST_TUPLE_OVERRIDE 改写为 $host_tuple_override（仅本地演练用）"
  host_tuple="$host_tuple_override"
fi

pinned="$(grep -oE "$pin_re" "$gh_ci" | head -1 | cut -d/ -f2)"
if [ -z "$pinned" ]; then
  echo "FAIL: 无法从 $gh_ci 取钉死版本（该面的 download/<ver>/ 形制漂了）"
  exit 2
fi

if [ "$print_pinned" = 1 ]; then
  printf '%s\n' "$pinned"
  exit 0
fi
if [ "$print_target" = 1 ]; then
  printf '%s\n' "$host_tuple"
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
  index_txt="$(cat "$index_fixture")" || { echo "FAIL: 版本索引快照读取失败：$index_fixture"; exit 2; }
  latest="$(printf '%s\n' "$index_txt" | python3 -c "$index_py")" || { echo "FAIL: 快照里取不到稳定版（$index_fixture 形制变或无合法版本键）"; exit 2; }
else
  index_txt="$(curl -sfL "$index_url")" || { echo "FAIL: 取不到上游版本（$index_url 不可达或形制变）"; exit 2; }
  latest="$(printf '%s\n' "$index_txt" | python3 -c "$index_py")" || { echo "FAIL: 上游索引里取不到稳定版（$index_url 形制变或无合法版本键）"; exit 2; }
fi

# 从**同一份索引文本**里取「本机上 $latest 那枚发行包」的指定字段（第 344 轮 D203）：索引是三层结构
# `<版本> → <平台位> → <字段>`，取不到即本机与上游发布面错配（无本平台条目 / 字段形制变），而这不是上游漂
# ——旧形下这里不单独成闸，拉不到包只落进一枚泛泛的「下载失败」。
field_py='
import json, sys
d = json.load(sys.stdin)
v = d.get(sys.argv[1])
p = v.get(sys.argv[2]) if isinstance(v, dict) else None
x = p.get(sys.argv[3]) if isinstance(p, dict) else None
if not isinstance(x, str) or not x:
    sys.exit(1)
print(x)
'

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
# 解包目录：注入通道无包，给一枚不存在的目录即可（它进 PATH 不影响查找，承改前形制）。
pack_dir="$tmp/injected"
if [ -n "$upstream_zig_bin" ]; then
  new_bin="$upstream_zig_bin"
  [ -x "$new_bin" ] || { echo "FAIL: UPSTREAM_ZIG_BIN 指向的不是可执行文件：$new_bin"; rm -rf "$tmp"; exit 2; }
  echo "已装上游工具链（离线注入，未下载发行包）：$("$new_bin" version)"
else
  # 包位与校验和**皆从上游索引取**（第 344 轮 D203）：改前此处自己拼 `zig-x86_64-linux-$latest`，即对上游
  # 发布面的第二次猜测；而索引本就按平台分键给了 tarball 与 shasum。
  tar_url="$(printf '%s\n' "$index_txt" | python3 -c "$field_py" "$latest" "$host_tuple" "$tarball_field")" || {
    echo "$no_platform_marker：$latest 下无平台位 $host_tuple 的 $tarball_field 条目——本机与上游发布面错配，"
    echo "  不是上游漂（改前此形落进一枚泛泛的「下载失败」，话术里连平台位都不出现）"
    [ -n "$summary" ] && printf -- '- 工具链：**无本平台条目**（平台位 `%s`／版本 `%s`）\n' "$host_tuple" "$latest" >>"$summary"
    rm -rf "$tmp"; exit 2
  }
  want_sum="$(printf '%s\n' "$index_txt" | python3 -c "$field_py" "$latest" "$host_tuple" "$shasum_field")" || {
    echo "$selfcheck_fail_marker：索引给了 $tarball_field 却取不到 $shasum_field（$latest／平台位 $host_tuple）——校验闸无法成立，宁可不装"
    rm -rf "$tmp"; exit 2
  }
  tar_base="$(basename "$tar_url")"
  tar_name="${tar_base%.tar.xz}"
  pack_dir="$tmp/$tar_name"
  if [ "$tar_name" = "$tar_base" ]; then
    echo "$selfcheck_fail_marker：本平台发行包形制不是 .tar.xz（$tar_base）——本脚本只解 xz tar，别的形制须人来接"
    rm -rf "$tmp"; exit 2
  fi
  echo "本机平台位：$host_tuple　要装的上游包：$tar_url"
  if ! curl -sfLo "$tmp/$tar_base" "$tar_url"; then
    echo "FAIL: 上游发行包下载失败：$tar_url（平台位 $host_tuple／版本 $latest——网络不通与该包位不存在皆是此形）"
    rm -rf "$tmp"; exit 2
  fi
  # 校验和闸（第 344 轮 D203 新立）：改前 57 MB 包一句 `tar -xf` 就收下，从不对上游给的 shasum——镜像
  # 站/CDN 上同名但内容不同的包，在那形下会一路走到「上游编不过本仓源码」退 1（落码前实锤形①）。
  if command -v sha256sum >/dev/null 2>&1; then
    got_sum="$(sha256sum "$tmp/$tar_base" | cut -d' ' -f1)"
  elif command -v shasum >/dev/null 2>&1; then
    got_sum="$(shasum -a 256 "$tmp/$tar_base" | cut -d' ' -f1)"
  else
    echo "$selfcheck_fail_marker：本机无 sha256sum/shasum——校验闸无法成立，宁可不装（上游已给 $shasum_field）"
    got_sum=""
  fi
  if [ -z "$got_sum" ]; then rm -rf "$tmp"; exit 2; fi
  if [ "$got_sum" != "$want_sum" ]; then
    echo "$selfcheck_fail_marker：**校验和不符**（索引声明 $want_sum，实到 $got_sum）——下到的是错包/截断包，"
    echo "  不是上游漂；本轮判定不作数（改前两形均径直进入构建段并退 1，把自身通道故障写成了关于上游的结论）"
    [ -n "$summary" ] && printf -- '- 工具链：**校验和不符**（见运行器日志）\n' >>"$summary"
    rm -rf "$tmp"; exit 2
  fi
  echo "校验和相符：$tar_base"
  tar -xf "$tmp/$tar_base" -C "$tmp" || { echo "$selfcheck_fail_marker：解包失败（$tar_base）"; rm -rf "$tmp"; exit 2; }
  new_bin="$pack_dir/zig"
  [ -x "$new_bin" ] || { echo "FAIL: 解包后找不到 $new_bin"; rm -rf "$tmp"; exit 2; }
  # 能跑与版本自证两道闸（同轮）：改前 `$("$new_bin" version)` 的非零退码被命令替换吞掉，本平台跑不了
  # 这枚包时“已装上游工具链：”打空照样放行（落码前实锤形③，即异平台机器上的真实后果）。
  new_ver="$("$new_bin" version 2>/dev/null)" || {
    echo "$selfcheck_fail_marker：**本平台跑不了这枚包**（$new_bin 连 version 都退非零，平台位 $host_tuple）——"
    echo "  改前此处把非零输出吞成空串照常放行，随后径直进入构建段并退 1（把跑不了的包写成上游结论）"
    rm -rf "$tmp"; exit 2
  }
  case "$new_ver" in
    *"$latest"*) : ;;
    *) echo "$selfcheck_fail_marker：版本自证不符（期望含 $latest，实得 $new_ver）——解出来的不是要装的那一枚"; rm -rf "$tmp"; exit 2 ;;
  esac
  echo "已装上游工具链：$new_ver"
fi

echo "—— 用上游版构建 zzc（本仓源码是否还能编过，第一条信号）"
if ! (cd "$root" && PATH="$pack_dir:$PATH" "$new_bin" build --cache-dir "$tmp/cache" --prefix "$tmp/out" >"$tmp/build.log" 2>&1); then
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
