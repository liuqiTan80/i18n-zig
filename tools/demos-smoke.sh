#!/usr/bin/env bash
# 第 297 轮 D156 · demo 示例编译/运行冒烟（Linux/CI 通道）
#
# 为何存在：`tools/check-demos.ps1`（1265 行）是本仓 demo↔eject 的端到端基线，但它只在
# Windows PowerShell 跑——本机 NO_PWSH（D98/D104 判例）、GitCode CI（Euler Linux）亦无
# pwsh 步，即**全仓没有任何通道执行过这份基线**。t2 探针实锤：把 `demo/hello` 的 `常数`
# 漂成不存在的词（活体 `zzc run` RC=1、书稿 quickstart 实地塌方），`zig fmt`／`zig build`／
# `zig build test`／`check-machine-matcher` 四通道一律零信号。本脚本把其中最硬核的
# 「六枚 demo 全量可编可跑、输出逐字节对拍」落成 bash 可跑、CI 可挂的常驻防线；
# ps1 的 eject 逐字节对比臂仍留 Windows 侧（在册候选）。
#
# 用法（仓根）：zig build 之后 `bash tools/demos-smoke.sh`；退出码 0 = 全过。
#
# 期望表是**独立手抄**（不从 demo 源程序化抽取——判据不取自被校文本，避自证循环，
# 承 294/295 轮 T0 形制）；`EXPECT_CHECKS` 为退坡闸：削一条断言即条数分道转红
# （承 D140「断言条数无锚即空转防线」判例），且与 `zzc_paths.demo_count_floor` 由
# 守卫对面三十三三处互锁。
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
zzc="$root/zig-out/bin/zzc"
if [ ! -x "$zzc" ]; then
  echo "FAIL: $zzc 不存在——先跑 zig build"
  exit 1
fi

EXPECT_CHECKS=23
checks=0
fails=0

tmp_out="$(mktemp)"
tmp_exp="$(mktemp)"
trap 'rm -f "$tmp_out" "$tmp_exp"' EXIT

# 正形：`zzc run <入口>` 退 0，且 stdout+stderr 合流逐字节等于期望（printf %s\n 补尾换行）。
assert_run() { # $1=入口相对路径  $2=期望输出（含中文逐字）
  checks=$((checks + 1))
  printf '%s\n' "$2" > "$tmp_exp"
  (cd "$root" && "$zzc" run "$1") > "$tmp_out" 2>&1
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "  [FAIL] $1 运行退码 $rc（期望 0）"
    sed 's/^/    | /' "$tmp_out"
    fails=$((fails + 1))
    return
  fi
  if ! cmp -s "$tmp_out" "$tmp_exp"; then
    echo "  [FAIL] $1 输出与期望逐字节不符"
    echo "    期望: $(cat "$tmp_exp")"
    echo "    实得: $(cat "$tmp_out")"
    fails=$((fails + 1))
  else
    echo "  [ok] $1 → $2"
  fi
}

# 报错示现形：退码非 0，且合流输出包含指定诊断片段（文案族由 hub 治理，此处只钉诊断核）。
assert_diag() { # $1=入口相对路径  $2=诊断片段
  checks=$((checks + 1))
  (cd "$root" && "$zzc" run "$1") > "$tmp_out" 2>&1
  local rc=$?
  if [ $rc -eq 0 ]; then
    echo "  [FAIL] $1 期望报错却被放行（退码 0）"
    fails=$((fails + 1))
    return
  fi
  if ! grep -qF -- "$2" "$tmp_out"; then
    echo "  [FAIL] $1 输出未含诊断片段「$2」"
    sed 's/^/    | /' "$tmp_out"
    fails=$((fails + 1))
  else
    echo "  [ok] $1 报错示现（含「$2」）"
  fi
}

assert_run demo/hello/src/main.zz "数量是：11"
assert_run demo/multi/src/main.zz "结果=42"
assert_run demo/nested/src/main.zz "结果=42"
assert_run demo/syntax/src/main.zz "计数=3 分类=非零 可选=7 取反=5"
assert_diag demo/errors/src/main.zz "不可变常量被重新赋值"
assert_diag demo/fullwidth/src/main.zz "全角分号"

# 第七臂（第 307 轮 D166）·纯母语行为面真跑：AGENTS.md 铁律「混写英文关键词必拦并给改词
# 候选」此前无任何通道验证——探针实锤拆去 main.zig 强制臂后五通道全绿而混写源报错错位成
# 后端假语法错。两枚手抄话术词形与模板真值由守卫对面四十三胶合（`cli.pure_native_smoke_face`），
# 方言词形首行复用 demo/hello 现行真值形（漂词即正形不持、本臂现红）。
checks=$((checks + 1))
d_pn="$(mktemp -d)"
mkdir -p "$d_pn/src"
printf '常数 标准库 = 导入("std");\n\nconst 泄漏 = 1;\n' > "$d_pn/src/main.zz"
(cd "$d_pn" && "$zzc" check --machine src/main.zz) > "$tmp_out" 2>&1
rc=$?
rm -rf "$d_pn"
if [ $rc -eq 0 ]; then
  echo "  [FAIL] 纯母语反形被放行（混写 const 却退 0）——强制臂被拆即 AGENTS.md 铁律成虚假广告"
  fails=$((fails + 1))
elif ! grep -qF -- "纯母语" "$tmp_out" || ! grep -qF -- "请改用" "$tmp_out"; then
  echo "  [FAIL] 纯母语反形被拦但话术不全（须含「纯母语」与「请改用」）——AI 无从自修即闭环断"
  sed 's/^/    | /' "$tmp_out"
  fails=$((fails + 1))
else
  echo "  [ok] 纯母语反形拦截且给改词话术"
fi

# 第八臂（第 308 轮 D167）·指定语言行为面三形互验：选包链（--lang-file → 外部包装载 → 选表）
# 的端到端行为此前只在 ps1 r9g 节断言，而 ps1 本机/CI 从不跑（D156 判例）——探针实锤：吞掉
# --lang-file 恒落默认包，763 门禁全绿。三形：指定包必过／不指定必拦（反证非默认包巧合）／
# 包文件缺失必显式报错。两枚手抄路径与 hub 单源由守卫对面四十四胶合（paths.lang_smoke_face）。
checks=$((checks + 1))
d_ja="$(mktemp -d)"
mkdir -p "$d_ja/src"
cp "$root/tools/fixtures/proj-ja/src/main.zz" "$d_ja/src/"
(cd "$d_ja" && "$zzc" check --lang-file "$root/tools/fixtures/external-min.txt" src) >/dev/null 2>&1
rc_spec=$?
(cd "$d_ja" && "$zzc" check src) >/dev/null 2>&1
rc_plain=$?
(cd "$d_ja" && "$zzc" check --lang-file /nonexistent-zz-pack.txt src) >/dev/null 2>&1
rc_missing=$?
rm -rf "$d_ja"
if [ $rc_spec -ne 0 ]; then
  echo "  [FAIL] 指定包正形不过（RC=$rc_spec）——选包链静默落回默认包即 --lang-file 失效，AGENTS.md 指定语言全谱成虚假广告"
  fails=$((fails + 1))
elif [ $rc_plain -eq 0 ]; then
  echo "  [FAIL] 日语形源无指定竟被默认包放行——选包逻辑倒挂（默认包认得日语词形？）"
  fails=$((fails + 1))
elif [ $rc_missing -eq 0 ]; then
  echo "  [FAIL] 不存在的包文件竟被放行——装载失败必显式报错，静默回退即半失效语言包温床"
  fails=$((fails + 1))
else
  echo "  [ok] 指定语言三形互验：指定过/无指定拦/缺包报错"
fi

# 第九臂（第 309 轮 D168）·CLI 叠加轴行为面四形互验：`--lang-overlay` 消费链有 lsp-live hover
# 一臂（267 轮）但 CLI 侧失败形无防线——探针实锤拆去缺包报错臂（静默回退基包）后五通道
# 全绿而缺包命令 RC 1→0。四形：overlay 正形（eject 产物含包映射值形）／无 overlay 反形（不含，
# 证非巧合）／缺包必报错带话术／坏包必报错带话术。手抄四枚词形与 hub 模板/叠加包活线由
# 守卫对面四十五胶合（cli.overlay_smoke_face，包映射另经 embedFile 编译期自守）。
checks=$((checks + 1))
d_ov="$(mktemp -d)"
mkdir -p "$d_ov/src"
printf '常数 网络服务 = 导入("httpz");\n\n常数 X = 网络服务.服务器;\n\n公开 函数 主函数() 空 { }\n' > "$d_ov/src/main.zz"
ov_pack="$root/contrib/packs/httpz-中文.txt"
ov_fail=0
(cd "$d_ov" && "$zzc" eject out --lang-overlay "$ov_pack") >/dev/null 2>&1 || ov_fail=1
[ -f "$d_ov/out/src/main.zig" ] && grep -qF -- "httpz.Server" "$d_ov/out/src/main.zig" || ov_fail=2
(cd "$d_ov" && "$zzc" eject out2) >/dev/null 2>&1
if grep -qF -- "httpz.Server" "$d_ov/out2/src/main.zig" 2>/dev/null; then ov_fail=3; fi
(cd "$d_ov" && "$zzc" eject out3 --lang-overlay /nonexistent-zz-overlay.txt) > "$tmp_out" 2>&1
rc_missing=$?
if [ $rc_missing -eq 0 ] || ! grep -qF -- "叠加语言包文件不存在" "$tmp_out"; then ov_fail=4; fi
printf '不是包格式 !!!\n' > "$d_ov/bad.txt"
(cd "$d_ov" && "$zzc" eject out4 --lang-overlay "$d_ov/bad.txt") > "$tmp_out" 2>&1
rc_bad=$?
if [ $rc_bad -eq 0 ] || ! grep -qF -- "解析失败" "$tmp_out"; then ov_fail=5; fi
rm -rf "$d_ov"
if [ $ov_fail -ne 0 ]; then
  echo "  [FAIL] 叠加轴行为面第 ${ov_fail} 形未符（1=eject拒/2=产物缺映射形/3=无overlay竟含/4=缺包形/5=坏包形）——静默回退基包即半失效叠加温床"
  fails=$((fails + 1))
else
  echo "  [ok] CLI 叠加轴四形互验：正形并入/反形不含/缺包报错/坏包报错"
fi

# 第十臂 · --lang 内置选包轴三形互验（第 310 轮 D169）：AI 用 zzc 选包链的注册名轴
# 行为面——308 轮探针实测未知包名报错 RC=2 与互斥 RC=2 皆零验证通道（探针：互斥臂
# 拆除后七门禁全绿，双源同指塌成误用外部包 RC=1）。三形互验锁两静默形：显式 `--lang zh`
# 正形 RC=0（注册名可用）；未知包名 RC=usage 码且报错含「未知语言包」（吞臂即静默
# 落默认 RC=0）；双源同指 RC=usage 码且含「互斥」（拆臂即误载外部包）。退码数锚
# EXPECT_USAGE_RC 由 hub usage_exit_code 派生（310 T0＋对面四十六）。临时工程入盘。
checks=$((checks + 1))
EXPECT_USAGE_RC=2
# EXPECT_FAIL_RC 由 hub failure_exit_code 派生（317 T0＋对面四十九）：一般失败退 1（POSIX）。
EXPECT_FAIL_RC=1
lang_axis_ok=0
tmp_out="$(mktemp)"
d_lc="$(mktemp -d)"; mkdir -p "$d_lc/src"
cp "$root/demo/hello/src/main.zz" "$d_lc/src/"
(cd "$d_lc" && "$zzc" check --lang zh src) >/dev/null 2>&1
rc_zh=$?
(cd "$d_lc" && "$zzc" check --lang nosuchpack-zz src > "$tmp_out" 2>&1)
rc_unk=$?
if [ $rc_zh -ne 0 ]; then
  echo "  [FAIL] --lang 正形——显式 zh 注册名应可用（RC=$rc_zh；选包链漂）"; lang_axis_ok=1
elif [ $rc_unk -ne $EXPECT_USAGE_RC ] || ! grep -qF -- "未知语言包" "$tmp_out"; then
  echo "  [FAIL] --lang 未知包名应报用法错并含话术（RC=$rc_unk 期望 $EXPECT_USAGE_RC；静默落默认即 AI 误以为选包生效）"; lang_axis_ok=1
else
  (cd "$d_lc" && "$zzc" check --lang zh --lang-file "$root/tools/fixtures/external-min.txt" src > "$tmp_out" 2>&1)
  rc_mux=$?
  if [ $rc_mux -ne $EXPECT_USAGE_RC ] || ! grep -qF -- "互斥" "$tmp_out"; then
    echo "  [FAIL] --lang 与 --lang-file 同指应互斥拒绝（RC=$rc_mux 期望 $EXPECT_USAGE_RC；塌成误用其一即静默错包）"; lang_axis_ok=1
  fi
fi
rm -f "$tmp_out"; rm -rf "$d_lc"
if [ $lang_axis_ok -eq 0 ]; then
  echo "  [ok] --lang 选包轴三形互验：注册名可用/未知名报错/双源互斥"
else
  fails=$((fails + 1))
fi

# 第十一臂 · 叠加轴版本闸 TooNew 行为形（第 311 轮 D170）：$format 高于支持值的叠加包
# 须报专错话术「过新…请升级」且不得塌进「解析失败」误导形——探针（TooNew 臂改指语法错
# 模板）实测六通道全绿而 AI 会去修没坏的包。极性三断：RC≠0／含「过新」与「请升级」／
# 不含「解析失败」。话术两枚入 overlay_smoke_face（对面四十五胶合，311 T0 关系钉）。
checks=$((checks + 1))
tv_ok=0
tmp_out="$(mktemp)"
d_tv="$(mktemp -d)"; mkdir -p "$d_tv/src"
cp "$root/demo/hello/src/main.zz" "$d_tv/src/"
printf '$format = 999\n\n[aliases]\n网络服务 = httpz\n' > "$d_tv/newer.txt"
(cd "$d_tv" && "$zzc" eject out --lang-overlay "$d_tv/newer.txt") > "$tmp_out" 2>&1
rc_tv=$?
if [ $rc_tv -eq 0 ]; then
  echo "  [FAIL] 版本闸失守——\$format=999 叠加包竟被接受（未来格式静默并入即半解翻译温床）"; tv_ok=1
elif ! grep -qF -- "过新" "$tmp_out" || ! grep -qF -- "请升级" "$tmp_out"; then
  echo "  [FAIL] 过新专错话术缺席（应含「过新」「请升级」——AI 无从知须升级工具而非改包）"; tv_ok=1
elif grep -qF -- "解析失败" "$tmp_out"; then
  echo "  [FAIL] 版本闸塌进语法错误导话术（指路修包而非升级，读者永修不好）"; tv_ok=1
fi
rm -f "$tmp_out"; rm -rf "$d_tv"
if [ $tv_ok -eq 0 ]; then
  echo "  [ok] 叠加轴版本闸：过新专错含升级指引且不塌误导话术"
else
  fails=$((fails + 1))
fi

# 第十二臂 · 选包文件轴版本闸 TooNew 行为形（第 312 轮 D171）：msg_fmt_too_new 模板
# hub 化后消费两臂（overlay 十一臂／选包文件本臂）——探针：loadExternalPack 的 TooNew
# 臂改指语法错模板后六通道全绿且 RC 仍 1，唯话术分流消失（RC 极性判对此形不敏，
# 话术断言是唯一捕手）。极性三断同十一臂形；「选包轴」标识词入 overlay_smoke_face。
checks=$((checks + 1))
lf_ok=0
tmp_out="$(mktemp)"
d_lf="$(mktemp -d)"; mkdir -p "$d_lf/src"
cp "$root/demo/hello/src/main.zz" "$d_lf/src/"
printf '$format = 999\n\n[keywords]\n常数 = const\n' > "$d_lf/pack-newer.txt"
(cd "$d_lf" && "$zzc" eject out --lang-file "$d_lf/pack-newer.txt") > "$tmp_out" 2>&1
rc_lf=$?
if [ $rc_lf -eq 0 ]; then
  echo "  [FAIL] 选包轴版本闸失守——\$format=999 基包形竟被接受"; lf_ok=1
elif ! grep -qF -- "过新" "$tmp_out" || ! grep -qF -- "请升级" "$tmp_out"; then
  echo "  [FAIL] 选包轴专错话术分流缺席（--lang-file 用户被剥掉升级指引）"; lf_ok=1
elif grep -qF -- "解析失败" "$tmp_out"; then
  echo "  [FAIL] 选包轴版本闸塌进误导话术形（指路修包而非升级）"; lf_ok=1
fi
rm -f "$tmp_out"; rm -rf "$d_lf"
if [ $lf_ok -eq 0 ]; then
  echo "  [ok] 选包轴版本闸：过新专错含升级指引且不塌误导话术"
else
  fails=$((fails + 1))
fi

# 第十三臂 · `zzc lang` 列播轴三形（第 313 轮 D172）：列播是无参只读出口，探针
# （registry for 体掏空）实测六通道全绿且 RC 仍 0——可注册段变空行，选包用户无从
# 所指。三形：正形 RC=0 且三截皆在（「当前语言包」头/「可注册包」头/「zh(」内容）；
# 未知动词形 RC=2 且含「不是有效」（拒绝臂拆形捕）；话术四枚入 lang_list_face
# （两 header 派生＋⊂模板＋内容针对 registry 交叉，313 T0/对面四十七）。
checks=$((checks + 1))
lg_ok=0
tmp_out="$(mktemp)"
"$zzc" lang > "$tmp_out" 2>&1
rc_lang=$?
if [ $rc_lang -ne 0 ]; then
  echo "  [FAIL] zzc lang 正形应退 0（RC=$rc_lang；只读列播出口坏即选包链全盲）"; lg_ok=1
elif ! grep -qF -- "当前语言包" "$tmp_out" || ! grep -qF -- "可注册包" "$tmp_out" || ! grep -qF -- "zh(" "$tmp_out"; then
  echo "  [FAIL] 列播三截缺一（详情头/可注册段头/注册名内容——掏空列体即空列表静默形）"; lg_ok=1
else
  "$zzc" lang nosuch-verb-zz > "$tmp_out" 2>&1
  rc_verb=$?
  if [ $rc_verb -ne $EXPECT_USAGE_RC ] || ! grep -qF -- "不是有效" "$tmp_out"; then
    echo "  [FAIL] lang 未知动词应退 2 并含拒绝话术（RC=$rc_verb；静默吞动词即 140 轮旧病复发）"; lg_ok=1
  fi
fi
rm -f "$tmp_out"
if [ $lg_ok -eq 0 ]; then
  echo "  [ok] lang 列播轴三形互验：正形三截皆在/未知动词拒绝"
else
  fails=$((fails + 1))
fi

# 第十四臂 · `zzc lang add` 注册链四形闭环（第 314 轮 D173）：既有防线仅 237 T2
# 静态源形计数（探针摘整臂回执 pack_ext 2→1 接住——静态面有闸），但 DUP 臂退码改花
# 招/回执漂字/新键不可选皆零通道。四形：A 成功回执（RC=0 三锚＋--as 键名）；
# B 同键重跑防覆盖（RC=usage 码＋拒绝词）；C 新键免重编译直接可用；
# D 缺省注册名与包内 $code 同源（tst-ja 形键可选举）。话术五枚入 lang_add_face（对面四十九）。
checks=$((checks + 1))
ad_ok=0
tmp_out="$(mktemp)"
d_ad="$(mktemp -d)"; mkdir -p "$d_ad/src"
cp "$root/tools/fixtures/proj-ja/src/main.zz" "$d_ad/src/"
(cd "$d_ad" && "$zzc" lang add "$root/tools/fixtures/external-min.txt" --as kk-zz14) > "$tmp_out" 2>&1
rc_ad=$?
if [ $rc_ad -ne 0 ]; then
  echo "  [FAIL] lang add 合格包应成功退 0（RC=$rc_ad）"; ad_ok=1
elif ! grep -qF -- "已装入" "$tmp_out" || ! grep -qF -- ".zzc/lang/" "$tmp_out" || ! grep -qF -- "kk-zz14" "$tmp_out"; then
  echo "  [FAIL] lang add 成功回执三锚缺一（回执词/落位目录/注册名——静默安装即 AI 拿不到指路）"; ad_ok=1
else
  (cd "$d_ad" && "$zzc" lang add "$root/tools/fixtures/external-min.txt" --as kk-zz14) > "$tmp_out" 2>&1
  rc_dup=$?
  if [ $rc_dup -ne $EXPECT_USAGE_RC ] || ! grep -qF -- "本工程内已装有" "$tmp_out"; then
    echo "  [FAIL] 同键重跑应退 usage 码并含防覆盖拒绝词（RC=$rc_dup）"; ad_ok=1
  elif ! (cd "$d_ad" && "$zzc" eject out --lang kk-zz14) >/dev/null 2>&1; then
    echo "  [FAIL] 新装注册名 --lang 不可选（装得上选不中——注册链闭环断在第三步）"; ad_ok=1
  else
    ad_d_out="$(cd "$d_ad" && "$zzc" lang add "$root/tools/fixtures/external-min.txt" 2>&1)"
    ad_d_rc=$?
    if [ $ad_d_rc -ne 0 ] || ! printf '%s' "$ad_d_out" | grep -qF -- "「テスト日本語(tst-ja)」" || ! printf '%s' "$ad_d_out" | grep -qF -- "--lang tst-ja"; then
      echo "  [FAIL] 缺省注册名与包内 \$code 同源形破（回执未指 tst-ja 可选）"; ad_ok=1
    fi
  fi
fi
rm -f "$tmp_out"; rm -rf "$d_ad"
if [ $ad_ok -eq 0 ]; then
  echo "  [ok] 注册链四形闭环：回执/防覆盖/新键可用/缺省同源"
else
  fails=$((fails + 1))
fi

# 第十五臂 · 已装用户包收录列播（第 315 轮 D174 消缺）：旧行为 add 成功而列播不列
# 新键——导航输出落后于真实能力（314 在册坐实）。三形：前后对照（add 前列播不含注册名、
# add 后必含——收录闭环兼捕反向退化）；同名去重（--as zh 装内置同名，列播 "zh(" 恰一枚，
# 锁去重策略不锁沉默双行）。标识词「收录列播」入 lang_list_face 第五枚。
checks=$((checks + 1))
li_ok=0
tmp_out="$(mktemp)"
# 第 335 行的括号形（承第 343 轮 D202）：此处原写 `{ …; cd "$d_li" && …; }` 是**当前 shell 的花括号组**，
# cd 会漏出来——下一行 `rm -rf "$d_li"` 随即把 cwd 删成悬空目录，此后所有臂都在 getcwd 失败的目录里跑。
# 它静默了四轮（第 15～22 臂皆不依赖 cwd），到第 23 臂要 `bash` 一个内部会 `cd "$root"` 的脚本时才现形：
# 那条臂整条走偏（基线回放 rc=1、构建版本号打空）。规矩：**臂内 cd 一律裹子 shell**，花括号组不得含 cd。
d_li="$(mktemp -d)"; mkdir -p "$d_li/src"
cp "$root/tools/fixtures/proj-ja/src/main.zz" "$d_li/src/"
if (cd "$d_li" && "$zzc" lang) 2>&1 | grep -qF -- "kk-zz15a("; then
  echo "  [FAIL] 未装包名竟在列播（幽灵条目形）"; li_ok=1
else
  (cd "$d_li" && "$zzc" lang add "$root/tools/fixtures/external-min.txt" --as kk-zz15a) >/dev/null 2>&1
  (cd "$d_li" && "$zzc" lang) > "$tmp_out" 2>&1
  if ! grep -qF -- "kk-zz15a(" "$tmp_out"; then
    echo "  [FAIL] add 成功后列播不收录新键（装得上看不见——314 边界旧病）"; li_ok=1
  # 第 319 轮 D178 随动：`lang add --as zh` 现已被装前拦截臂拒掉，改用手工 cp 造同名态
  # （列播去重闸仍须有被测物，否则该支空转成伪锚）。
  elif ( mkdir -p "$d_li/.zzc/lang"; cp "$root/tools/fixtures/external-min.txt" "$d_li/.zzc/lang/zh.txt"; cd "$d_li" && "$zzc" lang; ) >/dev/null 2>&1 && [ "$( (cd "$d_li" && "$zzc" lang) 2>&1 | grep -o "zh(" | wc -l )" -ne 1 ]; then
    echo "  [FAIL] 内置同名去重破（--as zh 后列播 'zh(' 不恰一枚——双行歧义或收录失效）"; li_ok=1
  fi
fi
rm -f "$tmp_out"; rm -rf "$d_li"
if [ $li_ok -eq 0 ]; then
  echo "  [ok] 已装包收录列播：前后对照/同名去重"
else
  fails=$((fails + 1))
fi

# 第十六臂 · `lang add` 坏注册名拦截行为面（第 316 轮 D175）：main 的拦截臂不入测试图，
# 落码前探针整摘该臂实测退码 2→134（panic 英文栈帧 attempt to unwrap error: BadKey），
# 本地通道唯 236 T0 静态退码形计数红、话术与写盘侧零信号（ps1 langadd E 属双盲臂本机不跑）。
# 三形：前导点 `.bad`／非 ASCII `中文包`／穿越 `../evil16`；每形断 RC=usage 码＋母语拒绝话术
# 全开引号到「不可用」逐字在场＋**越界零写盘**（工程 .zzc 下不产出任何包文件——白名单被绕过
# 即静默落在他处）。标识词「越界零写盘」入 lang_add_face（echo/注释双址）。
checks=$((checks + 1))
kb_ok=0
d_kb="$(mktemp -d)"; mkdir -p "$d_kb/src"
cp "$root/tools/fixtures/proj-ja/src/main.zz" "$d_kb/src/"
for bad in ".bad" "中文包" "../evil16"; do
  kb_out="$(cd "$d_kb" && "$zzc" lang add "$root/tools/fixtures/external-min.txt" --as "$bad" 2>&1)"
  kb_rc=$?
  if [ $kb_rc -ne $EXPECT_USAGE_RC ]; then
    echo "  [FAIL] 坏注册名「$bad」应退 usage 码（实得 RC=$kb_rc——拦截臂退化即 panic 134 或静默落盘）"; kb_ok=1
  elif ! printf '%s' "$kb_out" | grep -qF -- "注册名「$bad」不可用"; then
    echo "  [FAIL] 坏注册名「$bad」母语拒绝话术缺失（只剩 error 名泄出即 AI 无从改往何处）"; kb_ok=1
  fi
done
if [ -n "$(cd "$d_kb" && find .zzc -name '*.txt' 2>/dev/null)" ]; then
  echo "  [FAIL] 坏名被拒后仍写出包文件（越界零写盘破：穿越键落在 .zzc 别处即污染工程）"; kb_ok=1
fi
rm -rf "$d_kb"
if [ $kb_ok -eq 0 ]; then
  echo "  [ok] 坏名拦截越界零写盘：三形退码/话术/零写盘"
else
  fails=$((fails + 1))
fi

# 第十七臂 · `lang add` 坏包族零落盘（第 317 轮 D176）：落码前探针摘掉 B6 契约硬门后，
# 不合格包**装成功**（RC 1→0、`mis.txt` 落盘、回执照打）而 test/matcher/smoke 三通道全绿
# ——定时炸弹形静默入库（该包缺映射，等 `--lang` 选中才在流程深处报缺）。四形：文件不存在／
# `$format` 过新／B6 契约缺／空文件；逐形断 RC=`$EXPECT_FAIL_RC`＋母语话术针（不存在/过新/
# 不完整）＋**坏包族零落盘**反断（工程 .zzc 下不产出任何包文件）。标识词入 lang_add_face。
checks=$((checks + 1))
bp_ok=0
d_bp="$(mktemp -d)"; mkdir -p "$d_bp/src"
cp "$root/tools/fixtures/proj-ja/src/main.zz" "$d_bp/src/"
: > "$d_bp/empty.txt"
for spec in "不存在:$d_bp/nope.txt|外部语言包文件不存在" "过新:$root/tools/fixtures/external-toofmt.txt|过新" "契约缺:$root/tools/fixtures/external-partial.txt|不完整" "空文件:$d_bp/empty.txt|不完整"; do
  bp_n="${spec%%|*}"; bp_f="${bp_n#*:}"; bp_needle="${spec##*|}"; bp_n="${bp_n%%:*}"
  bp_out="$(cd "$d_bp" && "$zzc" lang add "$bp_f" 2>&1)"
  bp_rc=$?
  if [ $bp_rc -ne $EXPECT_FAIL_RC ]; then
    echo "  [FAIL] 坏包「$bp_n」应报失败退码（实得 RC=$bp_rc 期望 $EXPECT_FAIL_RC——硬门退化即坏包装成功入库）"; bp_ok=1
  elif ! printf '%s' "$bp_out" | grep -qF -- "$bp_needle"; then
    echo "  [FAIL] 坏包「$bp_n」母语话术缺针「$bp_needle」（只剩 error 名或静默即用户与 AI 无从修包）"; bp_ok=1
  fi
done
if [ -n "$(cd "$d_bp" && find .zzc -name '*.txt' 2>/dev/null)" ]; then
  echo "  [FAIL] 坏包族零落盘破：被拒的包仍在 .zzc 下留档（定时炸弹已埋进本工程）"; bp_ok=1
fi
rm -rf "$d_bp"
if [ $bp_ok -eq 0 ]; then
  echo "  [ok] 坏包族零落盘：四形退码/话术/零落盘"
else
  fails=$((fails + 1))
fi

# 第十八臂 · 已装坏包点名路径（第 318 轮 D177）：落码前探针把 validate 第二道门的
# `else if (installed_src) |ip|` 换成 `|_|` 并改派裸形模板 → 话术退化成「语言包不完整：缺少…」
# （**不再点名是哪个文件被改坏**）而 RC 仍 1，test/matcher/smoke 三通道全绿。三步链真跑：
# ①装好包 ②手工改坏落盘文件（模拟装后被编辑/截断）③再选用——断 RC=`$EXPECT_FAIL_RC`＋疑形
# 提示词「装后又被改坏了？」＋**路径点名**（输出须含实际落盘路径 `.zzc/lang/注册名.txt`，本机
# 可装多包，不点名即无从下手）。标识词「已装坏包点名路径」入 lang_add_face。
checks=$((checks + 1))
ic_ok=0
d_ic="$(mktemp -d)"; mkdir -p "$d_ic/src"
cp "$root/tools/fixtures/proj-ja/src/main.zz" "$d_ic/src/"
ic_key="kk-zz18k"
if ! (cd "$d_ic" && "$zzc" lang add "$root/tools/fixtures/external-min.txt" --as "$ic_key" >/dev/null 2>&1); then
  echo "  [FAIL] 第十八臂前置步失效：好包装不进（后续两步无从演）"; ic_ok=1
else
  cp "$root/tools/fixtures/external-partial.txt" "$d_ic/.zzc/lang/$ic_key.txt"
  ic_out="$(cd "$d_ic" && "$zzc" version --lang "$ic_key" 2>&1)"
  ic_rc=$?
  if [ $ic_rc -ne $EXPECT_FAIL_RC ]; then
    echo "  [FAIL] 已装坏包应报失败退码（实得 RC=$ic_rc 期望 $EXPECT_FAIL_RC——第二道门退化即坏包继续供编译）"; ic_ok=1
  elif ! printf '%s' "$ic_out" | grep -qF -- "装后又被改坏了？"; then
    echo "  [FAIL] 已装坏包话术缺疑形提示词「装后又被改坏了？」（漂成外部/裸形即两种成因指引混床）"; ic_ok=1
  elif ! printf '%s' "$ic_out" | grep -qF -- ".zzc/lang/$ic_key.txt"; then
    echo "  [FAIL] 已装坏包话术未点名路径（本机可装多包，不点名即用户与 AI 无从下手）"; ic_ok=1
  fi
fi
rm -rf "$d_ic"
if [ $ic_ok -eq 0 ]; then
  echo "  [ok] 已装坏包点名路径：三步链退码/疑形/点名"
else
  fails=$((fails + 1))
fi

# 第十九臂 · 同名遮蔽真相（第 319 轮 D178）：落码前探针把选包序整个反转（内置先查 →
# 已装先查），`--lang zh` 的真实输出从「语言包：中文」变成「语言包：テスト日本語」——语义
# 天翻地覆而 test/matcher/smoke 三通道全绿；且旧行为 `lang add --as zh` 退 0 并回执
# 「用 `--lang zh` 选用」，而该包永远选不中（幽灵文件＋假指引）。两形各钉一侧：
# 形一 装前即拒（RC=`$EXPECT_USAGE_RC`＋遮蔽话术＋**零落盘**）；形二 手工同名态下选用侧
# 真相（`--lang zh` 须仍报内置名，且**不得**出现已装包名——内置优先序被反转即红）。
checks=$((checks + 1))
sh_ok=0
d_sh="$(mktemp -d)"; mkdir -p "$d_sh/src"
cp "$root/tools/fixtures/proj-ja/src/main.zz" "$d_sh/src/"
sh_out="$(cd "$d_sh" && "$zzc" lang add "$root/tools/fixtures/external-min.txt" --as zh 2>&1)"
sh_rc=$?
if [ $sh_rc -ne $EXPECT_USAGE_RC ]; then
  echo "  [FAIL] 撞内置名应装前即拒（实得 RC=$sh_rc 期望 $EXPECT_USAGE_RC——放行即落幽灵文件、回执承诺成假）"; sh_ok=1
elif ! printf '%s' "$sh_out" | grep -qF -- "遮蔽"; then
  echo "  [FAIL] 撞内置名话术缺词核「遮蔽」（不点明被谁挡、为何挡即用户只会反复重装）"; sh_ok=1
elif [ -f "$d_sh/.zzc/lang/zh.txt" ]; then
  echo "  [FAIL] 撞内置名竟落盘（.zzc/lang/zh.txt 存在——选不中的幽灵态埋进工程）"; sh_ok=1
else
  mkdir -p "$d_sh/.zzc/lang"
  cp "$root/tools/fixtures/external-min.txt" "$d_sh/.zzc/lang/zh.txt"
  sh_sel="$(cd "$d_sh" && "$zzc" version --lang zh 2>&1)"
  if ! printf '%s' "$sh_sel" | grep -qF -- "中文"; then
    echo "  [FAIL] 同名态下选用侧未落内置包（内置优先序被改动即遮蔽失效/反客为主）"; sh_ok=1
  elif printf '%s' "$sh_sel" | grep -qF -- "テスト日本語"; then
    echo "  [FAIL] 同名态下已装包反客为主选中（选包序反转形，探针实锤形）"; sh_ok=1
  fi
fi
rm -rf "$d_sh"
if [ $sh_ok -eq 0 ]; then
  echo "  [ok] 同名遮蔽真相：装前拒/零落盘/内置优先"
else
  fails=$((fails + 1))
fi

# 第二十臂 · 旗标笔误装前即拒（第 321 轮 D180）：活体真值实测 `--langx zh`／`--language zh`／
# `-lang zh`／`--machin` 一律**静默吞**（RC=0 按默认包跑），而错**包名**早在 314 轮设闸退 2——错旗标名
# 比错包名更隐蔽（用户与 AI 皆以为旗标生效，反复重装/重编译皆无用）。判据住 hub `nearZzcFlag`（纯函数），
# 本臂只真跑：正形两桩（超集形退码＋点名最近合法名、破折数不符形同拦）＋反形六桩（合法旗标/等号形/
# 透传区/zig 原生长短旗/帮助旗皆不得误拦——拦错真命令即伤「zzc 旗标剔离、余者透传 zig」的既有契约）。
checks=$((checks + 1))
tp_ok=0
d_tp="$(mktemp -d)"; mkdir -p "$d_tp/src"
cp "$root/tools/fixtures/proj-ja/src/main.zz" "$d_tp/src/"
tp_out="$(cd "$d_tp" && "$zzc" version --langx zh 2>&1)"; tp_rc=$?
if [ $tp_rc -ne $EXPECT_USAGE_RC ]; then
  echo "  [FAIL] 旗标笔误装前即拒未生效（--langx 实得 RC=$tp_rc 期望 $EXPECT_USAGE_RC——静默吞即人以为选包生效）"; tp_ok=1
elif ! printf '%s' "$tp_out" | grep -qF -- "笔误"; then
  echo "  [FAIL] 笔误话术缺词核「笔误」（只退码不点明性质，AI 无从自修）"; tp_ok=1
elif ! printf '%s' "$tp_out" | grep -qF -- "「--lang」"; then
  echo "  [FAIL] 笔误话术未点名最近合法名「--lang」（错建议比无建议更害人——须指到那一枚）"; tp_ok=1
else
  tp2="$(cd "$d_tp" && "$zzc" version -lang zh 2>&1)"; tp2_rc=$?
  if [ $tp2_rc -ne $EXPECT_USAGE_RC ]; then
    echo "  [FAIL] 破折数不符形 -lang 未被拦（实得 RC=$tp2_rc——单/双破折混写是最高频笔误形）"; tp_ok=1
  fi
  for spec in "合法旗标:--lang zh" "等号形:--lang=zh" "透传区:-- --langx" "zig短旗:-Doptimize=ReleaseSafe" "zig长旗:--summary all" "帮助旗:--help"; do
    lbl="${spec%%:*}"; fl="${spec#*:}"
    nout="$(cd "$d_tp" && "$zzc" version $fl 2>&1)"; nrc=$?
    if [ $nrc -ne 0 ] || printf '%s' "$nout" | grep -qF -- "笔误"; then
      echo "  [FAIL] $lbl（$fl）被误拦或话术串味（RC=$nrc）——透传契约被新闸咬穿"; tp_ok=1
    fi
  done
fi
rm -rf "$d_tp"
if [ $tp_ok -eq 0 ]; then
  echo "  [ok] 旗标笔误装前即拒：超集拦/破折混写拦/透传六桩不误拦"
else
  fails=$((fails + 1))
fi

# 第二十一臂 · relocalize 双向道回程真跑（第 331 轮 D190）：正向 translate 有前二十臂护着，
# 回程 `relocalize` 此前零真跑——探针（把 render 改成恒等复制）下 test/matcher 全绿，唯本臂可捕。
# 四断：正形（ja 源 → zh 孪生，产出词形真换、注释原样、且由**同一条正向链**自检判绿）＋缺 `--to`
# （用法错非失败码）＋`--to` 串台（非 relocalize 子命令上出现即拒，静默剔离即人以为生效）＋
# 防毁源（落点撞源码树即拒且源文件仍在——清空 `dest/src` 前的那道闸被拆即删源码）。
checks=$((checks + 1))
rl_ok=0
d_rl="$(mktemp -d)"; mkdir -p "$d_rl/src"
cp "$root/tools/fixtures/proj-ja/src/main.zz" "$d_rl/src/"
rl_out="$(cd "$d_rl" && "$zzc" relocalize --lang-file "$root/tools/fixtures/external-min.txt" --to zh 2>&1)"; rl_rc=$?
if [ $rl_rc -ne 0 ]; then
  echo "  [FAIL] relocalize 正形未过（实得 RC=$rl_rc 期望 0）；输出：$rl_out"; rl_ok=1
elif [ ! -f "$d_rl/relocalized/zh/src/main.zz" ]; then
  echo "  [FAIL] relocalize 未落产出树（期望 relocalized/zh/src/main.zz）"; rl_ok=1
elif ! grep -qF -- "主函数" "$d_rl/relocalized/zh/src/main.zz"; then
  echo "  [FAIL] 产出未换成目标包词形（缺「主函数」——render 退化恒等复制即此形）"; rl_ok=1
elif ! grep -qF -- "// R9g" "$d_rl/relocalized/zh/src/main.zz"; then
  echo "  [FAIL] 注释未原样搬（渲染越界改写了非词元面）"; rl_ok=1
elif ! (cd "$d_rl" && "$zzc" check --lang zh relocalized/zh/src/main.zz) >/dev/null 2>&1; then
  echo "  [FAIL] 产出未过正向链自检（判据与被检物须同源：`check --lang <目标包>` 必绿）"; rl_ok=1
else
  nd_out="$(cd "$d_rl" && "$zzc" relocalize --lang-file "$root/tools/fixtures/external-min.txt" 2>&1)"; nd_rc=$?
  if [ $nd_rc -ne $EXPECT_USAGE_RC ]; then
    echo "  [FAIL] 缺 --to 未按用法错拦（实得 RC=$nd_rc 期望 $EXPECT_USAGE_RC——落默认包即静默产出错语言树）"; rl_ok=1
  elif ! printf '%s' "$nd_out" | grep -qF -- "缺少目标语言包"; then
    echo "  [FAIL] 缺 --to 话术缺词核「缺少目标语言包」"; rl_ok=1
  fi
  cs_out="$(cd "$d_rl" && "$zzc" check --to zh src/main.zz 2>&1)"; cs_rc=$?
  if [ $cs_rc -ne $EXPECT_USAGE_RC ]; then
    echo "  [FAIL] --to 串台未被拦（check 上实得 RC=$cs_rc——静默剔离即人以为换包生效）"; rl_ok=1
  elif ! printf '%s' "$cs_out" | grep -qF -- "只属于"; then
    echo "  [FAIL] 串台话术缺词核「只属于」"; rl_ok=1
  fi
  ov_out="$(cd "$d_rl" && "$zzc" relocalize --lang-file "$root/tools/fixtures/external-min.txt" --to zh src 2>&1)"; ov_rc=$?
  if [ $ov_rc -ne $EXPECT_FAIL_RC ]; then
    echo "  [FAIL] 落点撞源码树未拒（实得 RC=$ov_rc 期望 $EXPECT_FAIL_RC——清空 dest/src 前那道闸被拆即删源码）"; rl_ok=1
  elif [ ! -f "$d_rl/src/main.zz" ]; then
    echo "  [FAIL] 防毁源闸失效：源 src/main.zz 已不在（源码被产出清理吃掉）"; rl_ok=1
  fi
fi
rm -rf "$d_rl"
if [ $rl_ok -eq 0 ]; then
  echo "  [ok] relocalize 回程：正形落树/词形真换/注释原样/正向链自检绿 + 缺 --to/串台/防毁源三反形"
else
  fails=$((fails + 1))
fi

# 第二十二臂 · 上游周检判据三态离线真跑（第 342 轮 D201）：339 轮的周检四面针全是**声明面**（版本源/
# 标记/回放器/钉版来源），判据表达式本身全仓零钉，且旧形须触网才走得到方向臂——落码前实跑坐实：伪造钉版
# 0.99.0 竟报「DRIFT：上游已出 0.17.0，本仓仍钉 0.99.0」并去下载一枚**更旧**的工具链再退 1，即「不等
# 即漂移」的二元旧形把领先态吞进了漂移臂（方向反了的红）。本臂走快照入口离线跑五断：eq 判绿／lt 判漂（并
# 验 --verdict-only 未落入装工具链通道）／gt 判领先且**免跑退 0**（本轮缺陷定谳形，另不带旗标跑一次完整
# 周检以证零下载）／未知旗标装前即拒／--print-pinned 仍从 ci 面取出三段版本号（钉版提取正则的**消费点**
# 活着——旧脚本里那枚从未被消费的同域死正则由此形不再复现）。全程不触网，故 CI 冒烟网内可跑。
checks=$((checks + 1))
uw_ok=0
d_uw="$(mktemp -d)"
printf '%s' '{"master":{},"0.15.1":{},"0.16.1":{},"0.17.0":{}}' > "$d_uw/idx_eq.json"
printf '%s' '{"master":{},"0.17.0":{},"0.99.0":{}}' > "$d_uw/idx_new.json"
uw_watch="$root/tools/upstream-watch.sh"
uw_eq="$(UPSTREAM_PINNED_OVERRIDE=0.17.0 UPSTREAM_INDEX_FIXTURE="$d_uw/idx_eq.json" bash "$uw_watch" --verdict-only 2>&1)"; uw_eq_rc=$?
if [ $uw_eq_rc -ne 0 ] || ! printf '%s' "$uw_eq" | grep -qF -- "PASS：无上游漂移"; then
  echo "  [FAIL] 周检 eq 态未判绿（实得 RC=$uw_eq_rc／判据=RC 须 0 且输出含「PASS：无上游漂移」，二者其一不合即红）——相等判定被翻成不等、或取版断供（正则消费点坏）皆落此形"; uw_ok=1
fi
uw_lt="$(UPSTREAM_PINNED_OVERRIDE=0.17.0 UPSTREAM_INDEX_FIXTURE="$d_uw/idx_new.json" bash "$uw_watch" --verdict-only 2>&1)"; uw_lt_rc=$?
if [ $uw_lt_rc -ne 1 ] || ! printf '%s' "$uw_lt" | grep -qF -- "DRIFT(上游漂移)"; then
  echo "  [FAIL] 周检落后态未判漂（实得 RC=$uw_lt_rc／判据=RC 须 1 且输出含漂移标记，二者其一不合即红）——上游真出新版却恒绿即周检整周空转"; uw_ok=1
elif ! printf '%s' "$uw_lt" | grep -qF -- "--verdict-only 已生效"; then
  echo "  [FAIL] --verdict-only 未生效（判漂后仍往下走装工具链、复跑语料的通道）"; uw_ok=1
fi
uw_gt="$(UPSTREAM_PINNED_OVERRIDE=0.99.0 UPSTREAM_INDEX_FIXTURE="$d_uw/idx_eq.json" bash "$uw_watch" --verdict-only 2>&1)"; uw_gt_rc=$?
uw_full="$(UPSTREAM_PINNED_OVERRIDE=0.99.0 UPSTREAM_INDEX_FIXTURE="$d_uw/idx_eq.json" bash "$uw_watch" 2>&1)"; uw_full_rc=$?
if [ $uw_gt_rc -ne 0 ] || ! printf '%s' "$uw_gt" | grep -qF -- "AHEAD(上游钉版领先)"; then
  echo "  [FAIL] 周检领先态未判「免跑退 0」（实得 RC=$uw_gt_rc／判据=RC 须 0 且输出含领先态标记，二者其一不合即红）——第三态被吞回漂移臂即本轮缺陷复活"; uw_ok=1
elif [ $uw_full_rc -ne 0 ] || printf '%s' "$uw_full" | grep -qF -- "已装上游工具链"; then
  echo "  [FAIL] 领先态走完整周检仍在装更旧的工具链（RC=$uw_full_rc 期望 0）——方向判据机器（两版取较旧者）被删即此形红"; uw_ok=1
fi
uw_unk="$(bash "$uw_watch" --verdict-onlly 2>&1)"; uw_unk_rc=$?
if [ $uw_unk_rc -ne 2 ] || ! printf '%s' "$uw_unk" | grep -qF -- "未知旗标"; then
  echo "  [FAIL] 周检未知旗标未装前即拒（实得 RC=$uw_unk_rc／判据=RC 须 2 且输出含「未知旗标」）——笔误被静默吞即按完整周检白跑一遍"; uw_ok=1
fi
uw_pin="$(bash "$uw_watch" --print-pinned 2>&1)"; uw_pin_rc=$?
if [ $uw_pin_rc -ne 0 ] || ! printf '%s' "$uw_pin" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "  [FAIL] --print-pinned 未从 ci 面取出三段版本号（实得 RC=$uw_pin_rc 输出「${uw_pin}」／判据=RC 须 0 且整行为三段号）——取版正则的消费点漂了，workflow 装工具链那步跟着塌"; uw_ok=1
fi
rm -rf "$d_uw"
if [ $uw_ok -eq 0 ]; then
  echo "  [ok] 周检判据三态离线真跑：eq 判绿／lt 判漂不触下载／gt 免跑退 0（本轮缺陷形）＋未知旗标即拒＋取版单源活"
else
  fails=$((fails + 1))
fi

# 第二十三臂 · 上游周检装版臂离线真跑（第 343 轮 D202）：342 轮把判据方向臂离线化之后，装版臂（下载发行包
# →用上游版构建→两版语料回放对比→写 GITHUB_STEP_SUMMARY）整条臂仍是本地零通道——它要一枚真发行包，于是
# 只能等下周 CI。落码前用临时注入的离线入口把它真跑了一遍，坐实其中一句话术在说谎：两版 rc 同为非零且输出
# 逐字相同时，脚本打「语料回放逐字同构（报文文本未漂）」并把「同构」写进 summary——那是个**正向**读数，而
# 事实是两边一样地坏（同构只蕴含「两边一样」，不蕴含「未漂」）。本臂走两枚新入口（上游侧 UPSTREAM_ZIG_BIN、
# 基线侧 UPSTREAM_BASE_EXE）离线跑四断：合法同构／基线自身即红（本轮缺陷形，退 2 属前置错族）／输出分道／
# 入口非可执行即前置错。极性闸排在分道对比之前，承第 340 轮 D199「速度闸前先过极性闸」同族形制；全程不下载。
checks=$((checks + 1))
ua_ok=0
d_ua="$(mktemp -d)"
ua_watch="$root/tools/upstream-watch.sh"
printf '%s' '{"master":{},"0.16.1":{},"0.17.0":{}}' > "$d_ua/idx.json"
cat > "$d_ua/bad-zzc" <<'UAEOF'
#!/usr/bin/env bash
echo "（桩产物）故意失败：模拟本仓语料表在当前钉版上已不对齐" >&2
exit 3
UAEOF
cat > "$d_ua/fake-zig" <<'UAEOF'
#!/usr/bin/env bash
# 上游工具链桩：version 返一枚版号即可；build 只把 FAKE_ZZC_SRC 那枚产物搬进 --prefix/bin/zzc——搬基线
# 本体即「两版逐字同」，搬坏桩即「两版分道」，两条对比臂由此可在本地构造出来。
case "$1" in
  version) echo "0.17.0-offline-probe" ;;
  build)
    prefix=""
    while [ $# -gt 0 ]; do
      if [ "$1" = "--prefix" ]; then prefix="$2"; shift 2; else shift; fi
    done
    [ -n "$prefix" ] || exit 7
    mkdir -p "$prefix/bin"
    cp "$FAKE_ZZC_SRC" "$prefix/bin/zzc" || exit 8 ;;
  *) exit 0 ;;
esac
UAEOF
chmod +x "$d_ua/bad-zzc" "$d_ua/fake-zig"
: > "$d_ua/sum_parity.md"
ua_p="$(GITHUB_STEP_SUMMARY="$d_ua/sum_parity.md" UPSTREAM_PINNED_OVERRIDE=0.16.1 UPSTREAM_INDEX_FIXTURE="$d_ua/idx.json" UPSTREAM_ZIG_BIN="$d_ua/fake-zig" UPSTREAM_BASE_EXE="$zzc" FAKE_ZZC_SRC="$zzc" bash "$ua_watch" 2>&1)"; ua_p_rc=$?
if [ $ua_p_rc -ne 1 ] || ! printf '%s' "$ua_p" | grep -qF -- "语料回放逐字同构（报文文本未漂）" || printf '%s' "$ua_p" | grep -qF -- "基线自身即红" || ! printf '%s' "$ua_p" | grep -qF -- "离线注入，未下载发行包" || ! grep -qF -- "同构（rc 一致且输出逐字相同）" "$d_ua/sum_parity.md"; then
  echo "  [FAIL] 装版臂合法同构形未走通（实得 RC=$ua_p_rc／判据=RC 须 1 且输出含同构判词与「离线注入，未下载发行包」、不含基线自红、summary 含同构行，五者其一不合即红）——同构判词漂了或极性闸错位即此形红"; ua_ok=1
fi
: > "$d_ua/sum_base.md"
ua_b="$(GITHUB_STEP_SUMMARY="$d_ua/sum_base.md" UPSTREAM_PINNED_OVERRIDE=0.16.1 UPSTREAM_INDEX_FIXTURE="$d_ua/idx.json" UPSTREAM_ZIG_BIN="$d_ua/fake-zig" UPSTREAM_BASE_EXE="$d_ua/bad-zzc" FAKE_ZZC_SRC="$d_ua/bad-zzc" bash "$ua_watch" 2>&1)"; ua_b_rc=$?
if [ $ua_b_rc -ne 2 ] || ! printf '%s' "$ua_b" | grep -qF -- "基线自身即红" || printf '%s' "$ua_b" | grep -qF -- "逐字同构" || ! grep -qF -- "基线自红" "$d_ua/sum_base.md"; then
  echo "  [FAIL] 两版一样地坏未被报成前置错（实得 RC=$ua_b_rc／判据=RC 须 2 且输出含「基线自身即红」且不含「逐字同构」、summary 含基线自红行，四者其一不合即红）——本轮缺陷形复活：基线自红被报成「报文文本未漂」的正向读数"; ua_ok=1
fi
: > "$d_ua/sum_div.md"
ua_d="$(GITHUB_STEP_SUMMARY="$d_ua/sum_div.md" UPSTREAM_PINNED_OVERRIDE=0.16.1 UPSTREAM_INDEX_FIXTURE="$d_ua/idx.json" UPSTREAM_ZIG_BIN="$d_ua/fake-zig" UPSTREAM_BASE_EXE="$zzc" FAKE_ZZC_SRC="$d_ua/bad-zzc" bash "$ua_watch" 2>&1)"; ua_d_rc=$?
if [ $ua_d_rc -ne 1 ] || ! printf '%s' "$ua_d" | grep -qF -- "输出分道" || ! grep -qF -- "分道" "$d_ua/sum_div.md"; then
  echo "  [FAIL] 两版输出不同未被判成分道（实得 RC=$ua_d_rc／判据=RC 须 1 且输出含「输出分道」、summary 含分道行，三者其一不合即红）——分道是周检存在的动因，它不红即上游改了报文文本也无人知"; ua_ok=1
fi
ua_x="$(UPSTREAM_PINNED_OVERRIDE=0.16.1 UPSTREAM_INDEX_FIXTURE="$d_ua/idx.json" UPSTREAM_ZIG_BIN="$d_ua/no-such-zig" bash "$ua_watch" 2>&1)"; ua_x_rc=$?
if [ $ua_x_rc -ne 2 ] || ! printf '%s' "$ua_x" | grep -qF -- "不是可执行文件"; then
  echo "  [FAIL] 离线入口指向非可执行文件未即拒（实得 RC=$ua_x_rc／判据=RC 须 2 且输出含「不是可执行文件」）——入口值被静默吞即转而走真下载通道"; ua_ok=1
fi
rm -rf "$d_ua"
if [ $ua_ok -eq 0 ]; then
  echo "  [ok] 周检装版臂离线真跑：合法同构判绿／基线自红判前置错（本轮缺陷形）／分道判红／坏入口即拒，全程零下载"
else
  fails=$((fails + 1))
fi

if [ "$checks" -ne "$EXPECT_CHECKS" ]; then
  echo "FAIL: 断言条数 $checks ≠ 锚 $EXPECT_CHECKS（削臂/加臂须两处同动并随动 hub 下限）"
  exit 1
fi
if [ "$fails" -ne 0 ]; then
  echo "FAIL: demos-smoke $fails/$checks 条未过"
  exit 1
fi
echo "PASS：${checks} 项断言全过（六枚 demo 全量编译/运行对拍＋纯母语/指定语言/叠加轴行为面真跑＋relocalize 回程孪生工程＋上游周检判据三态离线真跑）"
