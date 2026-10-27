#!/usr/bin/env bash
# 第 346 轮 D205 · 教程逐块编译/运行闸（Linux/CI 通道）
#
# 为何存在：书稿《母语编写 Zig——中文版》与 README 的 ```zz 代码块是**读者照抄面**，而取证实锤
# 全仓没有任何通道读过 fence（`grep '```zz'` 在 tools/ src/ build.zig 零命中；文档侧既有三面守卫
# 只做文本对拍）：
#   · 4 枚自带 main 的完整程序从未被机器验过「可编＋输出等值」——书稿 11.3 顶着「已实测」三字；
#   · 9 枚声明碎片只走 `zig ast-check` 浅路（`main.zig` cmdCheck：无 main 的模块不 build-exe），
#     类型从未检查；
#   · 10 枚语句/缺依赖碎片连 `zzc check` 都过不了（片段被当整文件喂出的构造性假错）。
# 自动包装器两档皆实测不可用（补 main 使完整程序反报 `duplicate struct member name 'main'`；塞
# 函数体使 19 块红在 `expected statement, found 'pub'`／`local constant shadows declaration`），
# 故块形制必须写在块自己头上：fence 信息串标 `zz+`（真跑程序块）。未标记的整批建账棘轮
# （`ZZ_FLOOR`），新增块即逼作者当场定形制。
#
# 用法（仓根）：zig build 之后 `bash tools/book-blocks-smoke.sh`；退出码 0 = 全过。
#
# 期望输出是**独立手抄**（不从文档正文抽取——判据不取自被校文本，承 294/295 轮 T0 与
# demos-smoke.sh 形制）；真值单源在 `src/zzc_paths.zig` 的 `book_prog_entries`，本脚本手抄侧由
# 守卫**对面五十二**逐枚胶合（表内 `want` 串须能在本文里逐字找到），文档路径/块数锚/认块标记
# 三枚面针同源钉；`EXPECT_BLOCKS` 与 hub `book_prog_floor`、闸内实计三处互锁（承 D140
# 「断言条数无锚即空转防线」判例）。
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
zzc="$root/zig-out/bin/zzc"
if [ ! -x "$zzc" ]; then
  echo "FAIL: $zzc 不存在——先跑 zig build"
  exit 1
fi

# hub 单源的文档路径（改名须三处同动：hub `book_doc_path`/`readme_path`、build.zig 的
# addFileArg、本脚本——守卫对面五十二逐枚点名，分道即红）。
BOOK_DOC="$root/docs/母语编写zig-中文版.md"
README_DOC="$root/README.md"

# 认块标记（逐字取 hub `book_prog_marker`，守卫面针钉死）。
MARKER='```zz+'

EXPECT_BLOCKS=4      # = hub book_prog_floor：4 枚真跑块（书 3 ＋ README 1）
ZZ_FLOOR=23          # = hub book_zz_floor：zz 族块总数下限（棘轮只许升不许降）

fails=0
executed=0
tmp_exp="$(mktemp)"
tmp_out="$(mktemp)"
trap 'rm -f "$tmp_exp" "$tmp_out"' EXIT

# 抽出某文件内第 N 枚 ```zz+ 块正文（1 基）写入 $3。awk 与 hub 的 isZzProgFenceOpen 同判据：
# 行以 MARKER 起头（前置空白先剥），`+` 后须为行尾或空白。落盘一律在别处（$3 由调用方给
# mktemp -d 内的名字）——若以源文档路径加后缀为缓冲，即在仓根造文件并 `rm -f <文档>.*` 删它。
extract_prog_block() { # $1=文档  $2=序号  $3=落盘
  awk -v want="$2" -v out="$3" -v marker="$MARKER" '
    { line = $0; sub(/^[ \t]+/, "", line); }   # 前置空白先剥（列表/引文内缩进的块也要认）
    # 块内优先整段处理并 next——否则闭合栏会被后面的开栏判据再看一遍（文档若嵌了
    # ` ```zz ` 字样即误升 n，序号就会错拿另一块对期望）。（awk 的 pattern-action 里无 `continue`，只能 next）
    ins == 1 {
      if (line ~ /^```/) { ins = 0; done = 1; exit }
      print line >> out
      next
    }
    substr(line, 1, length(marker)) == marker {
      rest = substr(line, length(marker) + 1)
      if (rest == "" || rest ~ /^[ \t]/) {
        n++
        if (n == want) ins = 1
      }
    }
    END { if (!done) exit 3 }
  ' "$1" || return 1
  [ -s "$3" ]
}

# 一枚真跑块：抽块 → 全新工程（`.zzc/` 落在工程内，不 cd 入内即与别块共用符号缓存互毒——
# 第 345 轮 D204 实测教训）→ zzc check 退 0 → zzc run 输出逐字节等于期望。
assert_block() { # $1=人读名  $2=文档  $3=序号  $4=期望输出（逐字，不含尾换行）
  executed=$((executed + 1))
  local d
  d="$(mktemp -d)"
  if ! extract_prog_block "$2" "$3" "$d/body.zz"; then
    echo "  [FAIL] $1 抽块落空（文档第 $3 枚「$MARKER」块不存在或标记被拆）——闸不得把「一块也没抽到」报成全过（第 346 轮 D205）"
    fails=$((fails + 1))
    rm -rf "$d"
    return
  fi
  mkdir -p "$d/src"
  cat "$d/body.zz" > "$d/src/main.zz"
  (cd "$d" && "$zzc" check src/main.zz) > "$tmp_out" 2>&1
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "  [FAIL] $1 浅检未过（RC=$rc）——读者照书抄即失败，第 346 轮 D205"
    sed 's/^/    | /' "$tmp_out" | head -4
    fails=$((fails + 1))
    rm -rf "$d"
    return
  fi
  (cd "$d" && "$zzc" run src/main.zz) > "$tmp_out" 2>&1
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "  [FAIL] $1 运行未过（RC=$rc）——书稿声称可跑而实跑失败"
    sed 's/^/    | /' "$tmp_out" | head -4
    fails=$((fails + 1))
    rm -rf "$d"
    return
  fi
  printf '%s\n' "$4" > "$tmp_exp"
  if ! cmp -s "$tmp_out" "$tmp_exp"; then
    echo "  [FAIL] $1 输出与期望不等值（期望「$4」）："
    sed 's/^/    | 实得 /' "$tmp_out" | head -4
    fails=$((fails + 1))
  else
    echo "  [ok] $1 可编可跑、输出逐字节等值（「$4」）"
  fi
  rm -rf "$d"
}

# —— 四枚真跑块（序号按文档内出现序，与 hub `book_prog_entries` 表序同构；期望输出独立手抄）——
assert_block "书稿 0.2 第一个程序"   "$BOOK_DOC"  1 "数量是：11"
assert_block "书稿 11.3 三条铁律"    "$BOOK_DOC"  2 "5"
assert_block "书稿 13.4 ArrayList"   "$BOOK_DOC"  3 "n=2 首=90"
assert_block "README 快跑示例"       "$README_DOC" 1 "结果是 11"

# —— 棘轮普查：zz 族块总数须全等于 hub 锚（实计取自文档，判据取自 hub，两边分道即红）——
zz_total=$( { grep -cE '^[ \t]*```zz' "$BOOK_DOC"; } 2>/dev/null || echo 0)
r_total=$( { grep -cE '^[ \t]*```zz' "$README_DOC"; } 2>/dev/null || echo 0)
zz_total=$((zz_total + r_total))
if [ "$zz_total" -ne "$ZZ_FLOOR" ]; then
  echo "  [FAIL] zz 族块实计 $zz_total ≠ hub 锚 $ZZ_FLOOR（书 $((zz_total - r_total)) ＋ README $r_total）——新增块须当场定形制（标 $MARKER 或入册 hub book_zz_floor），旧块被删亦须同动锚（第 346 轮 D205）"
  fails=$((fails + 1))
else
  echo "  [ok] zz 族块实计 $zz_total 与 hub 锚全等（棘轮未退坡）"
fi

# —— 真跑块实计与锚对账：标了 zz+ 而表/锚不随动，即「加了块没加账」或「拆了块账还挂着」——
# 正则里的 `+` 必须走字符类 [+]：裸 `+` 在 ERE 里是「zz 的一个或多个」，会把 ` ```zz ` 也算进来。
prog_total=$( { grep -cE '^[ \t]*```zz[+][ \t]*$' "$BOOK_DOC"; } 2>/dev/null || echo 0)
rp_total=$( { grep -cE '^[ \t]*```zz[+][ \t]*$' "$README_DOC"; } 2>/dev/null || echo 0)
prog_total=$((prog_total + rp_total))
if [ "$prog_total" -ne "$EXPECT_BLOCKS" ]; then
  echo "  [FAIL] 真跑块（$MARKER）实计 $prog_total ≠ 锚 $EXPECT_BLOCKS——标记与账分道（第 346 轮 D205）"
  fails=$((fails + 1))
else
  echo "  [ok] 真跑块实计 $prog_total 与锚全等"
fi

# 实执条数与锚对账：账上四枚却只调了三回 assert_block，即接线被拆而闸不自知。
if [ "$executed" -ne "$EXPECT_BLOCKS" ]; then
  echo "  [FAIL] 真跑块实执 $executed ≠ 锚 $EXPECT_BLOCKS——assert_block 接线被削/多加（承 D140 空转防线判例，第 346 轮 D205）"
  fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: 教程逐块闸 $fails 条断言未过"
  exit 1
fi
echo "PASS: 教程逐块闸 $((EXPECT_BLOCKS + 2)) 条断言全过"
