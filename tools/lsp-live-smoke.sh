#!/bin/sh
# LSP 长连接冒烟（D128·第 262 轮）。
#
# 为什么必须单独有这一条：既有 tools/check-demos.ps1 的 LSP e2e 以
# `-RedirectStandardInput <文件>` 驱动，stdin 在进程启动瞬间即 EOF；它只能证明
# 「EOF 后批量处理」正确，不能证明真实客户端（VS Code 保持 stdin 打开）能收到
# initialize 应答。第 262 轮实锤：旧读循环用 readSliceShort（语义=读满 4096 或
# EOF），小帧在管道上永远填不满，真实长连接下 initialize 永不被处理。
#
# 本脚本用 FIFO 保持写端打开，逐帧发送并轮询应答；任何一步超时即失败。
# 退出码：0=通过；1=失败。CI 以 `timeout 30 sh tools/lsp-live-smoke.sh` 包裹。
#
# 第 267 轮：进程以 `--lang-overlay contrib/packs/httpz-中文.txt` 启动——服务端在
# cmdLsp 前把叠加层并入基包，故 hover 能反查第三方库别名（网络服务.服务器 -> httpz.Server）。
# 这一步同时锁住「overlay 路径 -> LSP Pack -> hover」整链，缺任一环断言即红。
set -eu

ZZC=${1:-zig-out/bin/zzc}
if [ ! -x "$ZZC" ]; then
    echo "[FAIL] lsp-live: 找不到可执行文件 $ZZC（先 zig build）" >&2
    exit 1
fi

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$REPO_ROOT/contrib/packs/httpz-中文.txt"
if [ ! -f "$OVERLAY" ]; then
    echo "[FAIL] lsp-live: 找不到叠加语言包 $OVERLAY" >&2
    exit 1
fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/zzc-lsp-live.XXXXXX")
fifo=$tmpdir/in
out=$tmpdir/out
err=$tmpdir/err
mkfifo "$fifo"
pid=""
cleanup() {
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -rf "$tmpdir"
}
trap cleanup EXIT INT TERM

# 先让服务端打开 FIFO 读端，再打开写端；两端配对后 exec 3 保持写端常开。
"$ZZC" lsp --lang-overlay "$OVERLAY" <"$fifo" >"$out" 2>"$err" &
pid=$!
exec 3>"$fifo"

send() {
    len=$(printf %s "$1" | wc -c | tr -d ' ')
    printf 'Content-Length: %s\r\n\r\n%s' "$len" "$1" >&3
}

# 轮询等待输出文件出现指定子串；超时返回 1。
wait_for() {
    needle=$1
    i=0
    while [ "$i" -lt 30 ]; do
        if grep -Fq "$needle" "$out" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

fail() {
    echo "[FAIL] lsp-live: $1" >&2
    echo "--- stdout ---" >&2
    cat "$out" >&2 || true
    echo "--- stderr ---" >&2
    cat "$err" >&2 || true
    exit 1
}

# 1) initialize：stdin 保持打开，必须立即应答。
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
send "$init"
wait_for '"id":1' || fail "initialize 在 3s 内无应答（长连接读循环可能仍阻塞）"
grep -Fq '"hoverProvider":true' "$out" || fail "initialize 应答缺少 hoverProvider"
grep -Fq '"semanticTokensProvider"' "$out" || fail "initialize 应答缺少 semanticTokensProvider"
grep -Fq '"documentSymbolProvider":true' "$out" || fail "initialize 应答缺少 documentSymbolProvider"
grep -Fq '"definitionProvider":true' "$out" || fail "initialize 应答缺少 definitionProvider"
grep -Fq '"referencesProvider":true' "$out" || fail "initialize 应答缺少 referencesProvider"
grep -Fq '"documentHighlightProvider":true' "$out" || fail "initialize 应答缺少 documentHighlightProvider"
grep -Fq '"codeActionProvider":true' "$out" || fail "initialize 应答缺少 codeActionProvider"
grep -Fq '"foldingRangeProvider":true' "$out" || fail "initialize 应答缺少 foldingRangeProvider"
grep -Fq '"renameProvider":{"prepareProvider":true}' "$out" || fail "initialize 应答缺少 renameProvider{prepareProvider:true}"
grep -Fq '"workspaceSymbolProvider":true' "$out" || fail "initialize 应答缺少 workspaceSymbolProvider"
grep -Fq '"signatureHelpProvider":{"triggerCharacters":["(",","]}' "$out" || fail "initialize 应答缺少 signatureHelpProvider 触发字符形"
grep -Fq '"selectionRangeProvider":true' "$out" || fail "initialize 应答缺少 selectionRangeProvider"
grep -Fq '"completionProvider":{"triggerCharacters":["."]}' "$out" || fail "initialize 应答缺少 completionProvider 触发字符形"

send '{"jsonrpc":"2.0","method":"initialized","params":{}}'

# 2) didOpen：全角逗号触发快路诊断，服务端应主动 publishDiagnostics。
didopen='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-live.zz","languageId":"zig-dialect","version":1,"text":"常数 标准库 = 导入(\"std\");\n公开 函数 主函数() !空 {\n    标准库.调试.打印(\"你好，世界\\n\", .{});\n}\n常数 网 = 导入(\"httpz\");\n常数 服 = 网络服务.服务器(空);\n常数 甲 = 1，\n常数 乙 = 2；\n// 注释块第一行\n// 注释块第二行\n"}}}'
send "$didopen"
wait_for 'publishDiagnostics' || fail "didOpen 后未收到 publishDiagnostics"
grep -Fq 'file:///tmp/zzc-lsp-live.zz' "$out" || fail "诊断 URI 与打开的文档不一致"
grep -Fq '"diagnostics":[{' "$out" || fail "didOpen 诊断为空（全角违规未被快路诊断捕获）"

# 3) hover：确认请求/应答链路仍在（不是只读了 initialize）。
send '{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-live.zz"},"position":{"line":0,"character":1}}}'
wait_for '"id":2' || fail "hover 在 3s 内无应答"

# 4) documentSymbol：大纲应含顶层「标准库」常数与「主函数」。
send '{"jsonrpc":"2.0","id":3,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-live.zz"}}}'
wait_for '"id":3' || fail "documentSymbol 在 3s 内无应答"
grep -Fq '"name":"主函数"' "$out" || fail "documentSymbol 缺少主函数"
grep -Fq '"name":"标准库"' "$out" || fail "documentSymbol 缺少标准库"

# 5) definition：引用「标准库」应跳到第 0 行第 3 字符的顶层常数声明。
send '{"jsonrpc":"2.0","id":4,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-live.zz"},"position":{"line":2,"character":4}}}'
wait_for '"id":4' || fail "definition 在 3s 内无应答"
grep -Fq '"line":0,"character":3' "$out" || fail "definition 未指向标准库声明"

# 6) references：从「标准库」声明发起，应同时返回声明（行0字符3）与引用（行2字符4）。
send '{"jsonrpc":"2.0","id":5,"method":"textDocument/references","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-live.zz"},"position":{"line":0,"character":4},"context":{"includeDeclaration":true}}}'
wait_for '"id":5' || fail "references 在 3s 内无应答"
grep -Fq '"line":0,"character":3' "$out" || fail "references 未包含声明位置"
grep -Fq '"line":2,"character":4' "$out" || fail "references 未包含函数体内引用"

# 7) overlay hover：叠加包别名「网络服务.服务器」应反查出 httpz.Server。
#    这是第 267 轮客户端 zzc.langOverlay 接线的服务端同日证据。
send '{"jsonrpc":"2.0","id":6,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-live.zz"},"position":{"line":5,"character":7}}}'
wait_for '"id":6' || fail "overlay hover 在 3s 内无应答"
grep -Fq 'httpz.Server' "$out" || fail "overlay hover 未返回 httpz.Server（--lang-overlay 未并入 LSP 基包）"

# 8) codeAction：第 6 行的全角逗号应给出 quickfix，newText 为半角逗号。
#    这是第 268 轮「能报错 -> 一键改对」的服务端证据；零宽空格等无建议值者不出修复。
send '{"jsonrpc":"2.0","id":7,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-live.zz"},"range":{"start":{"line":6,"character":8},"end":{"line":6,"character":9}},"context":{"diagnostics":[]}}}'
wait_for '"id":7' || fail "codeAction 在 3s 内无应答"
grep -Fq '"kind":"quickfix"' "$out" || fail "codeAction 未返回 quickfix"
grep -Fq '"newText":","' "$out" || fail "codeAction 未把全角逗号换成半角逗号"

# 9) source.fixAll：文档级批量修复，一次覆盖全文两处全角违规（保存时修复的服务端口）。
send '{"jsonrpc":"2.0","id":8,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-live.zz"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"context":{"diagnostics":[],"only":["source.fixAll"]}}}'
wait_for '"id":8' || fail "source.fixAll 在 3s 内无应答"
grep -Fq '"kind":"source.fixAll"' "$out" || fail "codeAction 未返回 source.fixAll"
grep -Fq '修复全文全角标点（2 处）' "$out" || fail "source.fixAll 未覆盖全文两处违规"
grep -Fq '"newText":";"' "$out" || fail "source.fixAll 缺全角分号→半角分号编辑"

# 10) foldingRange：主函数体（行1 `{` → 行3 `}`）应给出一个折叠区；
#     尾部两行行首注释（行8→行9）应给出 `kind:"comment"` 块。
#     字符串/注释中的括号不参与配对，单行 `.{}` 不折叠。
send '{"jsonrpc":"2.0","id":9,"method":"textDocument/foldingRange","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-live.zz"}}}'
wait_for '"id":9' || fail "foldingRange 在 3s 内无应答"
grep -Fq '"result":[{"startLine":1,"endLine":3},{"startLine":8,"endLine":9,"kind":"comment"}]' "$out" || fail "foldingRange 未返回主函数体与注释块折叠区"

# 11) rename：从「标准库」声明处改名 → 声明与函数体引用两处编辑；
#     字符串与注释里的同名不参与（lexer 词元过滤）。
send '{"jsonrpc":"2.0","id":10,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-live.zz"},"position":{"line":0,"character":4},"newName":"工具"}}'
wait_for '"id":10' || fail "rename 在 3s 内无应答"
grep -Fq '"changes":{"file:///tmp/zzc-lsp-live.zz":[{"range":{"start":{"line":0,"character":3},"end":{"line":0,"character":6}},"newText":"工具"},{"range":{"start":{"line":2,"character":4},"end":{"line":2,"character":7}},"newText":"工具"}]}' "$out" || fail "rename 未返回声明+引用两处编辑（或误改了字符串/注释）"

# 12) documentHighlight：从「标准库」声明处高亮 -> 声明位 Write(3)、函数体引用位 Read(2)；
#     字符串与注释里的同名不参与（lexer 词元过滤）。
send '{"jsonrpc":"2.0","id":11,"method":"textDocument/documentHighlight","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-live.zz"},"position":{"line":0,"character":4}}}'
wait_for '"id":11' || fail "documentHighlight 在 3s 内无应答"
grep -Fq '"result":[{"range":{"start":{"line":0,"character":3},"end":{"line":0,"character":6}},"kind":3},{"range":{"start":{"line":2,"character":4},"end":{"line":2,"character":7}},"kind":2}]' "$out" || fail "documentHighlight 未返回声明 Write + 引用 Read 两项（或误收了字符串/注释）"

# 13) prepareRename：从「标准库」声明处预检 → 声明词范围 + 旧名占位符；
#     成员词「调试」不是同文件顶层声明 → null（F2 不弹死输入框）。
send '{"jsonrpc":"2.0","id":12,"method":"textDocument/prepareRename","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-live.zz"},"position":{"line":0,"character":4}}}'
wait_for '"id":12' || fail "prepareRename 在 3s 内无应答"
grep -Fq '"result":{"range":{"start":{"line":0,"character":3},"end":{"line":0,"character":6}},"placeholder":"标准库"}' "$out" || fail "prepareRename 未返回声明词范围与占位符"
send '{"jsonrpc":"2.0","id":13,"method":"textDocument/prepareRename","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-live.zz"},"position":{"line":2,"character":9}}}'
wait_for '"id":13' || fail "prepareRename（成员词）在 3s 内无应答"
grep -Fq '"id":13,"result":null' "$out" || fail "prepareRename 对非顶层声明词应返回 null"

# 14) workspace/symbol：已打开文档的顶层声明按 query 过滤（主函数）；无匹配 → 空数组。
send '{"jsonrpc":"2.0","id":14,"method":"workspace/symbol","params":{"query":"主"}}'
wait_for '"id":14' || fail "workspace/symbol 在 3s 内无应答"
grep -Fq '"result":[{"name":"主函数","kind":12,"location":{"uri":"file:///tmp/zzc-lsp-live.zz","range":{"start":{"line":1,"character":6},"end":{"line":1,"character":9}}}}]' "$out" || fail "workspace/symbol 未按 query 返回主函数的 location"
send '{"jsonrpc":"2.0","id":15,"method":"workspace/symbol","params":{"query":"不存在的符号"}}'
wait_for '"id":15' || fail "workspace/symbol（无匹配）在 3s 内无应答"
grep -Fq '"id":15,"result":[]' "$out" || fail "workspace/symbol 无匹配时应返回空数组"

# 16) signatureHelp：同一文档内的调用按顶层函数声明的参数表提示；
#     三参声明 + 字符串内逗号，使误计不会被 clamp 掩盖；活动参数按顶层逗号计。
sigopen='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-sig.zz","languageId":"zig-dialect","version":1,"text":"函数 打招呼(名字: 文本, 次数: 整数, 结尾: 文本) 文本 {\n    返回 名字;\n}\n函数 调用者() 文本 {\n    返回 打招呼(\"甲,乙\", 2);\n}\n"}}}'
send "$sigopen"
send '{"jsonrpc":"2.0","id":16,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-sig.zz"},"position":{"line":4,"character":12}}}'
wait_for '"id":16' || fail "signatureHelp 在 3s 内无应答"
grep -Fq '"result":{"signatures":[{"label":"函数 打招呼(名字: 文本, 次数: 整数, 结尾: 文本)","parameters":[{"label":"名字: 文本"},{"label":"次数: 整数"},{"label":"结尾: 文本"}]}],"activeSignature":0,"activeParameter":0}' "$out" || fail "signatureHelp 未返回声明参数表与首个活动参数"
send '{"jsonrpc":"2.0","id":17,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-sig.zz"},"position":{"line":4,"character":18}}}'
wait_for '"id":17' || fail "signatureHelp（第二实参）在 3s 内无应答"
grep -Fq '"id":17,"result":{"signatures":[{"label":"函数 打招呼(名字: 文本, 次数: 整数, 结尾: 文本)","parameters":[{"label":"名字: 文本"},{"label":"次数: 整数"},{"label":"结尾: 文本"}]}],"activeSignature":0,"activeParameter":1}' "$out" || fail "signatureHelp 的活动参数未随顶层逗号递增（字符串内逗号被误计）"

# 17) selectionRange：词元→整行→包围块→整文档的嵌套链；parent 逐级外扩，
#     字符串/注释整体成词元，故其内括号不参与块配对。
send '{"jsonrpc":"2.0","id":18,"method":"textDocument/selectionRange","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-sig.zz"},"positions":[{"line":4,"character":8}]}}'
wait_for '"id":18' || fail "selectionRange 在 3s 内无应答"
grep -Fq '"id":18,"result":[{"range":{"start":{"line":4,"character":7},"end":{"line":4,"character":10}},"parent":{"range":{"start":{"line":4,"character":0},"end":{"line":4,"character":21}},"parent":{"range":{"start":{"line":3,"character":12},"end":{"line":5,"character":1}},"parent":{"range":{"start":{"line":0,"character":0},"end":{"line":6,"character":0}}}}}}]' "$out" || fail "selectionRange 未返回 词元→整行→块→整文档 的嵌套链"

# 18) completion：上下文补全三形（第 279 轮）——点链候选带整链 textEdit（缺它则
#     VS Code 只替换末段词，`标准库.调` 插成 `标准库.标准库.调试.打印`）、本文件顶层
#     声明作为候选带 kind/detail、光标前无前缀即空表（字面量与空白处不灌候选）。
send '{"jsonrpc":"2.0","id":20,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-live.zz"},"position":{"line":2,"character":9}}}'
wait_for '"id":20' || fail "completion（点链前缀）在 3s 内无应答"
grep -Fq '"textEdit":{"range":{"start":{"line":2,"character":4},"end":{"line":2,"character":9}},"newText":"标准库.调试.打印"}' "$out" || fail "completion 点链候选缺整链 textEdit（替换区间未覆盖 `标准库.调`）"
send '{"jsonrpc":"2.0","id":21,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-live.zz"},"position":{"line":2,"character":7}}}'
wait_for '"id":21' || fail "completion（声明前缀）在 3s 内无应答"
grep -Fq '"label":"标准库","kind":21,"detail":"本文件声明"' "$out" || fail "completion 未把本文件顶层常数列为候选（kind 21=Constant）"
send '{"jsonrpc":"2.0","id":22,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///tmp/zzc-lsp-live.zz"},"position":{"line":2,"character":0}}}'
wait_for '"id":22' || fail "completion（无前缀）在 3s 内无应答"
grep -Fq '"id":22,"result":{"isIncomplete":false,"items":[]}' "$out" || fail "completion 光标前无前缀时应返回空表"

# 19) shutdown/exit：正常收束，退出码 0。
send '{"jsonrpc":"2.0","id":19,"method":"shutdown","params":null}'
wait_for '"id":19' || fail "shutdown 在 3s 内无应答"
send '{"jsonrpc":"2.0","method":"exit","params":{}}'
exec 3>&-
wait "$pid" || fail "exit 后进程退出码非 0"
pid=""
[ -s "$err" ] && fail "stderr 有非协议输出"

echo "[PASS] lsp-live: 长连接 initialize/didOpen-diagnostics/hover/documentSymbol/definition/references/overlay-hover/codeAction/source-fixAll/foldingRange(comment)/rename/documentHighlight/prepareRename/workspaceSymbol/signatureHelp/selectionRange/completion/shutdown/exit 全通过"
