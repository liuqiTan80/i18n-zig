#!/usr/bin/env bash
# 诊断语料回放（第 336 轮 D195）
#
# 为何存在：AstGen/Sema 的报文族没有可枚举的 shipped 源码，只能逐族真跑造形；而每轮探针用完
# 即删（`_probe/` 已清），下一轮补族又要重新摸「什么源码能触发它」——这是最贵的效率漏损。
# 本脚本把「触发源码 + 期望译文」落成可复跑的数据：语料在 tools/diag-corpus/<族-名>/，
# 每个目录两个文件——src/main.zz（触发源码）与 expect.txt（期望输出子串，首条非注释行生效）。
#
# 判据分四层（缺一层就会退化成空转防线）：
#   1. 结构：每个 case 必须两个文件齐全；有目录没 expect.txt 即红；
#   2. 极性：zzc check 必须报错退非零——语料若是「其实能编过」，回放就永远抓不到东西；
#   3. 内容：合并输出必须逐字含期望子串（期望表独立手抄，不从 packs 回抄，避免改译文自证通过）；
#   4. 条数：case 数必须等于 EXPECT_CASES 自锚（承 D140「断言条数无锚即空转」判例）——
#      删掉一个 case 而不动锚点即红，锚点由 hub 的 diag_corpus_floor 经守卫面针双侧夹逼。
#
# 用法（仓根）：bash tools/diag-corpus.sh [zzc 可执行文件]；退出码 0 = 全过。
# build.zig 的 check-diag-corpus 步把刚构建的 zzc 作为唯一实参传入（故本地/CI 跑同一份）。
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
zzc="${1:-$root/zig-out/bin/zzc}"
cases_dir="$root/tools/diag-corpus"

if [ ! -x "$zzc" ]; then
  echo "FAIL: $zzc 不存在——先跑 zig build"
  exit 1
fi
if [ ! -d "$cases_dir" ]; then
  echo "FAIL: 语料目录 $cases_dir 不存在"
  exit 1
fi

EXPECT_CASES=3
checks=0
fails=0

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for d in "$cases_dir"/*/; do
  [ -d "$d" ] || continue
  id="$(basename "$d")"
  src="$d/src/main.zz"
  exp_file="$d/expect.txt"
  checks=$((checks + 1))

  if [ ! -f "$src" ]; then
    echo "FAIL[$id]: 缺 src/main.zz（语料目录必须自带触发源码）"
    fails=$((fails + 1))
    continue
  fi
  if [ ! -f "$exp_file" ]; then
    echo "FAIL[$id]: 缺 expect.txt（没声明期望译文，回放无从判定对错）"
    fails=$((fails + 1))
    continue
  fi
  want="$(grep -m1 -v '^[[:space:]]*#' "$exp_file" || true)"
  if [ -z "$want" ]; then
    echo "FAIL[$id]: expect.txt 无非注释行（期望译文不能为空）"
    fails=$((fails + 1))
    continue
  fi

  "$zzc" check "$src" >"$tmp" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL[$id]: 期望报错，实际退 0——语料已不再触发该族诊断（源码或编译器行为漂了）"
    fails=$((fails + 1))
    continue
  fi
  if ! grep -qF -- "$want" "$tmp"; then
    echo "FAIL[$id]: 输出未含期望译文「$want」"
    sed -n '1,4p' "$tmp" | sed 's/^/    实际: /'
    fails=$((fails + 1))
    continue
  fi
  echo "  [ok] $id"
done

if [ "$checks" -ne "$EXPECT_CASES" ]; then
  echo "FAIL: 语料实计 $checks 条 ≠ 自锚 EXPECT_CASES=$EXPECT_CASES（增删 case 须同动锚点与 hub diag_corpus_floor）"
  fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL：$fails/$checks 条语料未过"
  exit 1
fi
echo "PASS：$checks 条诊断语料全部回放通过（触发源码 + 期望译文 + 报错极性 + 条数锚）"
