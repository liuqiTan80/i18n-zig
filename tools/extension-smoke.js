#!/usr/bin/env node
'use strict';
// 客户端 e2e（第 278 轮）：用最小 vscode 桩加载 editors/vscode/extension.js，
// 真起 `zzc lsp` 子进程，逐 provider 断言「客户端重建后的返回值」——覆盖
// 第 263–277 轮全部 LSP 面与第 157–163 轮的接线面。
//
// 与 tools/check-demos.ps1 的分工：ps1 走 Windows PowerShell + 文件重定向，
// 本脚本走 node + 长连接，本机（Linux 无 pwsh）与 CI 都能跑；它消费的是
// 「安装到编辑器里的那一份 extension.js」，因此也验证 VSIX 打包内容。
//
// 用法：
//   node tools/extension-smoke.js                        # 测仓库内 clients
//   ZZC_EXT_DIR=~/.qoder-cn-server/extensions/zzc.zzc-dialect-0.5.0 \
//     node tools/extension-smoke.js                      # 测已安装的扩展
// 退出码：0=全过；1=断言失败；2=环境缺失。

const fs = require('fs');
const os = require('os');
const path = require('path');
const Module = require('module');

const ROOT = path.dirname(__dirname);
const EXT_DIR = process.env.ZZC_EXT_DIR || path.join(ROOT, 'editors', 'vscode');
const ZZC = process.env.ZZC_BIN || path.join(ROOT, 'zig-out', 'bin', 'zzc');

if (!fs.existsSync(path.join(EXT_DIR, 'extension.js'))) {
  console.error('[FAIL] extension-smoke: 找不到 ' + path.join(EXT_DIR, 'extension.js'));
  process.exit(2);
}
if (!fs.existsSync(ZZC)) {
  console.error('[FAIL] extension-smoke: 找不到 ' + ZZC + '（先 zig build）');
  process.exit(2);
}

// 1) 把 vscode 桩挂进 NODE_PATH，让 extension.js 的 require('vscode') 解析到它。
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'zzc-ext-smoke-'));
const stub = path.join(work, 'node_modules', 'vscode');
fs.mkdirSync(stub, { recursive: true });
fs.writeFileSync(path.join(stub, 'package.json'), JSON.stringify({ name: 'vscode', version: '1.85.0', main: 'index.js' }));
fs.writeFileSync(path.join(stub, 'index.js'),
  'module.exports = require(' + JSON.stringify(path.join(ROOT, 'tools', 'vscode-mock.js')) + ');\n');
process.env.NODE_PATH = path.join(work, 'node_modules') +
  (process.env.NODE_PATH ? path.delimiter + process.env.NODE_PATH : '');
Module._initPaths();

const vscode = require('vscode');
const state = vscode.__state;
state.config = { lspPath: ZZC, lang: '', langOverlay: '' };
const ext = require(path.join(EXT_DIR, 'extension.js'));

// 2) 测试文档：覆盖声明 / 调用 / 块 / 字面量 / 关键字 / 全角违规。
const TEXT = [
  '常数 标准库 = 导入("std");',
  '',
  '公开 函数 求和(甲: 整数, 乙: 整数) 整数 {',
  '    返回 甲 + 乙;',
  '}',
  '',
  '公开 函数 主函数() !空 {',
  '    变量 合计: 整数 = 求和(1, 2);',
  '    标准库.调试.打印("合计={d}\\n", .{合计});',
  '}',
  '',
].join('\n');
const FULLWIDTH = '常数 甲 = 1，\n';
const docPath = path.join(work, 'main.zz');
fs.writeFileSync(docPath, TEXT);

const doc1 = {
  uri: vscode.Uri.file(docPath),
  languageId: 'zig-dialect',
  version: 1,
  fileName: docPath,
  getText: () => TEXT,
};
let doc2Text = FULLWIDTH;
const doc2 = {
  uri: vscode.Uri.parse('file://' + path.join(work, 'full.zz')),
  languageId: 'zig-dialect',
  version: 1,
  getText: () => doc2Text,
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// 断言条数锚（第 282 轮 D140）：本套件的断言条数**就是覆盖面本身**——删掉一条 `ok(...)` 不会让失败变多，
// 只会让 PASS 里的数字变小而仍退 0（第 282 轮探针实锤：删一枚 capability 键名 + 一条断言后仍
// `PASS：87 项断言全过` 退 0，且 `zig build test` 17/17 全绿——运行时与构建链双静默）。
// 故把「应有条数」钉成精确等号：条数退坡即红，新增断言亦须同数上调，绝不允许「少验但绿」。
// 数值真值另由 `src/cli/args.zig` 的 `smoke_js_floor` 独立手设，守卫对面二十四跨侧对账
// （判例：护栏数量下限不可从被测侧抽取，否则自成空转伪锚）——三处任一分道皆红。
const EXPECT_CHECKS = 96;
let checks = 0;
function ok(cond, label) {
  if (!cond) throw new Error('断言失败：' + label);
  checks += 1;
  console.log('  [ok] ' + label);
}
function eq(actual, expected, label) {
  ok(actual === expected, label + '（实得 ' + JSON.stringify(actual) + '，期望 ' + JSON.stringify(expected) + '）');
}
function posOf(text, needle, nth = 0) {
  let idx = -1;
  for (let i = 0; i <= (nth || 0); i += 1) {
    idx = text.indexOf(needle, idx + 1);
    if (idx < 0) throw new Error('文档里找不到第 ' + nth + ' 个「' + needle + '」');
  }
  const before = text.slice(0, idx);
  const line = before.split('\n').length - 1;
  const lineStart = before.lastIndexOf('\n') + 1;
  return { line, character: idx - lineStart };
}
function rangeOf(text, needle, nth = 0) {
  const p = posOf(text, needle, nth);
  return new vscode.Range(p.line, p.character, p.line, p.character + needle.length);
}
async function waitFor(fn, ms, label) {
  const deadline = Date.now() + ms;
  for (;;) {
    const got = fn();
    if (got) return got;
    if (Date.now() > deadline) throw new Error('超时：' + label);
    await sleep(50);
  }
}
function readyCount() {
  return (state.output.join('').match(/就绪（能力：/g) || []).length;
}

const hard = setTimeout(() => {
  console.error('[FAIL] extension-smoke: 90s 总超时');
  console.error('--- 输出面板 ---\n' + state.output.join('').slice(-2000));
  process.exit(1);
}, 90000);
hard.unref();

async function main() {
  console.log('扩展目录：' + EXT_DIR);
  console.log('服务端：' + ZZC);

  const pkg = require(path.join(EXT_DIR, 'package.json'));
  ext.activate({ subscriptions: [], extension: { packageJSON: pkg } });
  await waitFor(() => readyCount() >= 1, 15000, 'initialize 完成');
  ok(readyCount() >= 1, 'initialize 应答并打日志（客户端握手）');
  ok(!state.output.join('').includes('lsp 帧解析错误'), '帧解析无错误');

  // 握手能力串：客户端把服务端 capabilities 原样打日志，全族应在此可见。
  const log = state.output.join('');
  ok(log.includes('zzc 扩展已激活（v' + pkg.version + '）'), '激活日志带扩展版本');
  ok(log.includes('启动语言服务器：'), '输出通道记录启动命令');
  for (const cap of ['hoverProvider', 'completionProvider', 'selectionRangeProvider', 'signatureHelpProvider',
    'workspaceSymbolProvider', 'documentSymbolProvider', 'definitionProvider',
    'referencesProvider', 'documentHighlightProvider', 'codeActionProvider',
    'foldingRangeProvider', 'renameProvider', 'semanticTokensProvider']) {
    ok(log.includes('"' + cap + '"'), '握手日志含 ' + cap);
  }

  // 3) didOpen → publishDiagnostics（快路诊断）
  state.workspaceTextDocuments.push(doc1, doc2);
  state.handlers.open(doc1);
  await waitFor(() => state.diagnostics.has(doc1.uri.toString()), 8000, 'doc1 诊断发布');
  eq(state.diagnostics.get(doc1.uri.toString()).length, 0, '合法文档快路诊断为 0 条');

  state.handlers.open(doc2);
  const bad = await waitFor(() => {
    const list = state.diagnostics.get(doc2.uri.toString());
    return list && list.length ? list : null;
  }, 8000, 'doc2 全角诊断发布');
  ok(bad.length >= 1, '全角逗号产出诊断');
  eq(bad[0].source, 'zzc', '诊断来源标注为 zzc');
  ok(typeof bad[0].message === 'string' && bad[0].message.length > 0, '诊断消息非空');

  const P = state.providers;
  for (const name of ['hover', 'completion', 'signatureHelp', 'selectionRange', 'documentSymbol',
    'workspaceSymbol', 'definition', 'references', 'documentHighlight', 'codeAction',
    'foldingRange', 'rename', 'semanticTokens']) {
    ok(!!P[name], '已注册 provider：' + name);
  }

  // 4) hover：包内别名反查标准形（含 docs 用法行）
  const hover = await P.hover.provideHover(doc1, posOf(TEXT, '标准库'));
  ok(hover && hover.contents && typeof hover.contents.value === 'string', 'hover 返回 MarkdownString');
  ok(hover.contents.value.includes('标准库') && hover.contents.value.includes('std'), 'hover 正文含方言词与标准形 std');

  // 4b) 宿主枚举值域地基（第 290 轮 D149）：vscode 的 SymbolKind／CompletionItemKind 以 0 起编，
  //     LSP 同名枚举以 1 起编。桩若漂回 1 基，下面的图标断言就全成自照，故先把两侧差值钉死。
  eq(vscode.SymbolKind.Function, 11, '宿主 SymbolKind 为 0 基（Function=11，即 LSP 12 − 基址 1）');
  eq(vscode.CompletionItemKind.Function, 2, '宿主 CompletionItemKind 为 0 基（Function=2，即 LSP 3 − 基址 1）');

  // 5) documentSymbol / definition / references / highlight
  const syms = await P.documentSymbol.provideDocumentSymbols(doc1);
  const names = syms.map((s) => s.name);
  ok(names.includes('标准库') && names.includes('求和') && names.includes('主函数'), '大纲含三个顶层声明');
  ok(syms.every((s) => s.range instanceof vscode.Range && s.selectionRange instanceof vscode.Range), '大纲项 range/selectionRange 均为 Range');
  { const sym = syms.find((s) => s.name === '求和'); ok(sym.selectionRange.start.character !== sym.range.start.character, '大纲 selectionRange 窄于 range（非回退）'); eq(sym.kind, vscode.SymbolKind.Function, '大纲函数项取宿主 Function 图标（换算生效·D149）'); }

  const def = await P.definition.provideDefinition(doc1, posOf(TEXT, '求和', 1));
  ok(Array.isArray(def) && def.length === 1, '定义跳转返回单个 Location');
  eq(def[0].range.start.line, 2, '定义指向第 2 行声明');
  ok(def[0].uri.toString() === doc1.uri.toString(), '定义 Location.uri 等于请求文档');

  const refs = await P.references.provideReferences(doc1, posOf(TEXT, '求和'), { includeDeclaration: true });
  ok(refs.length >= 2, '引用含声明与调用');
  ok(refs.some((r) => r.range.start.line === 7), '引用含函数体内调用行');

  const his = await P.documentHighlight.provideDocumentHighlights(doc1, posOf(TEXT, '求和'));
  ok(his.length >= 2, '同名高亮两项以上');
  ok(his.some((h) => h.kind === vscode.DocumentHighlightKind.Write), '声明位映射为 Write');
  ok(his.some((h) => h.kind === vscode.DocumentHighlightKind.Read), '引用位映射为 Read');

  // 6) selectionRange：词元 → 行 → 块（内→外）→ 整文档
  const srs = await P.selectionRange.provideSelectionRanges(doc1, [posOf(TEXT, '合计')]);
  ok(Array.isArray(srs) && srs.length === 1, '每个位置返回一条扩选链');
  let node = srs[0];
  let depth = 1;
  let outer = node;
  while (node.parent) {
    node = node.parent;
    outer = node;
    depth += 1;
  }
  eq(depth, 4, '链深 4（词元→整行→包围块→整文档）');
  eq(outer.range.start.line, 0, '链根从文档首行起');
  eq(outer.range.end.line, TEXT.split('\n').length - 1, '链根到文档末尾');

  // 6b) completion：前缀候选（本文件声明 / 关键字）与点链 textEdit 替换整链
  ok(state.triggerChars.completion && state.triggerChars.completion[0] === '.', '补全注册带 `.` 触发字符尾参');
  {
    const p = posOf(TEXT, '求和');
    const list = await P.completion.provideCompletionItems(doc1, { line: p.line, character: p.character + 1 });
    ok(list && Array.isArray(list.items) && list.items.length >= 1, '补全返回 CompletionList.items');
    eq(list.isIncomplete, false, '补全表标注为完整');
    const decl = list.items.find((i) => i.label === '求和');
    ok(decl instanceof vscode.CompletionItem, '候选项重建为 CompletionItem');
    eq(decl.detail, '本文件声明', '声明候选带来源 detail');
    eq(decl.kind, vscode.CompletionItemKind.Function, '函数声明候选映射为宿主 CompletionItemKind.Function（换算生效·D149）');
    eq(decl.textEdit, undefined, '非点链候选不带 textEdit');

    const q = posOf(TEXT, '公开');
    const klist = await P.completion.provideCompletionItems(doc1, { line: q.line, character: q.character + 1 });
    const kw = klist.items.find((i) => i.label === '公开');
    ok(kw && kw.detail === 'pub' && kw.kind === vscode.CompletionItemKind.Keyword, '关键字候选带标准形与宿主 Keyword 码');

    const c = posOf(TEXT, '标准库.调');
    const clist = await P.completion.provideCompletionItems(doc1, { line: c.line, character: c.character + 5 });
    const chain = clist.items.find((i) => i.label === '标准库.调试.打印');
    ok(!!chain, '点链候选命中完整链');
    ok(chain.textEdit instanceof vscode.TextEdit, '点链候选带 TextEdit');
    ok(chain.textEdit.range instanceof vscode.Range, 'TextEdit 范围为 Range');
    eq(chain.textEdit.range.start.character, c.character, '替换范围从链首起');
    eq(chain.textEdit.range.end.character, c.character + 5, '替换范围到光标止');
    eq(chain.textEdit.newText, '标准库.调试.打印', 'newText 为整链（不致重复前缀）');
    ok(typeof chain.documentation === 'string' && chain.documentation.length > 0, '点链候选带大白话用法文档');
  }

  // 7) foldingRange：花括号块折叠
  const folds = await P.foldingRange.provideFoldingRanges(doc1);
  ok(folds.some((f) => f.startLine === 2 && f.endLine === 4), '求和 函数体折叠 2→4');
  ok(folds.some((f) => f.startLine === 6 && f.endLine === 9), '主函数 体折叠 6→9');

  // 8) signatureHelp：首参/次参活动参数
  const sh0 = await P.signatureHelp.provideSignatureHelp(doc1, posOf(TEXT, '1, 2'));
  ok(sh0 && sh0.signatures.length === 1, '参数提示返回一条签名');
  ok(sh0.signatures[0].label.includes('求和'), '签名标签含被调名');
  eq(sh0.activeParameter, 0, '首参活动参数为 0');
  const sh1 = await P.signatureHelp.provideSignatureHelp(doc1, posOf(TEXT, '2);'));
  eq(sh1.activeParameter, 1, '次参活动参数为 1');

  // 9) workspaceSymbol：跨文档按 query 过滤
  const wss = await P.workspaceSymbol.provideWorkspaceSymbols('求');
  ok(wss.some((s) => s.name === '求和'), '工作区符号命中 求和');
  const ws = wss.find((s) => s.name === '求和');
  eq(ws.kind, vscode.SymbolKind.Function, '工作区符号取宿主 Function 图标（换算生效·D149）');
  eq(wss.find((s) => s.name === '求和').location.uri.toString(), doc1.uri.toString(), '符号 location 指向打开文档');

  // 10) rename：预检 + 全量编辑
  const prep = await P.rename.prepareRename(doc1, posOf(TEXT, '求和'));
  ok(prep && prep.placeholder === '求和', '重命名预检回填旧名');
  eq(prep.range.start.line, 2, '预检范围落在声明行');
  const edit = await P.rename.provideRenameEdits(doc1, posOf(TEXT, '求和'), '加和');
  ok(edit && edit.entries.length >= 2, '重命名产出多处编辑');
  ok(edit.entries.every((e) => e.newText === '加和'), '每处编辑都用新名');

  // 11) semanticTokens：相对 5 元组与图例同序
  const st = await P.semanticTokens.provideDocumentSemanticTokens(doc1);
  ok(st.data.length > 0 && st.data.length % 5 === 0, '语义 token 流为 5 元组整数倍');
  eq(state.legends.semanticTokens.tokenTypes.join(','),
    'keyword,type,function,variable,string,comment,number', '图例顺序与服务端约定同序');

  // 12) codeAction：光标 quickfix + source.fixAll 批量臂
  const actions = await P.codeAction.provideCodeActions(doc2, rangeOf(FULLWIDTH, '，'), { diagnostics: [], only: undefined });
  eq(actions.length, 1, '单点全角违规一条 quickfix');
  eq(actions[0].kind.value, 'quickfix', '单点动作 kind=quickfix');
  eq(actions[0].edit.entries.length, 1, '单点动作一处编辑');
  eq(actions[0].edit.entries[0].newText, ',', '单点动作替换为半角逗号');
  const fixes = await P.codeAction.provideCodeActions(doc2, rangeOf(FULLWIDTH, '，'),
    { diagnostics: [], only: vscode.CodeActionKind.SourceFixAll });
  eq(fixes.length, 1, 'source.fixAll 返回单条批量动作');
  eq(fixes[0].kind.value, 'source.fixAll', '批量动作 kind=source.fixAll');
  ok(typeof actions[0].title === 'string' && actions[0].title.length > 0, '单点动作 title 非空串');

  // 13) didChange：全量同步后诊断归零（客户端发 contentChanges 末项全文）
  doc2Text = '常数 甲 = 1;\n';
  doc2.version += 1;
  state.handlers.change({ document: doc2 });
  await waitFor(() => {
    const list = state.diagnostics.get(doc2.uri.toString());
    return list && list.length === 0;
  }, 8000, 'didChange 后诊断清空');
  ok((state.diagnostics.get(doc2.uri.toString()) || []).length === 0, 'didChange 全文同步生效（诊断清空）');

  // 14) didSave：保存门控触发服务端语义检查（只验链路不炸、客户端无错误提示）
  state.handlers.save(doc1);
  await sleep(1500);
  eq(state.errors.length, 0, 'didSave 后客户端无错误提示');

  // 15) 切换方言 → 自动重启，文档表由 textDocuments 重建
  state.config.lang = 'zh';
  state.handlers.config({ affectsConfiguration: () => true });
  await waitFor(() => readyCount() >= 2, 15000, '重启后 initialize 完成');
  ok(readyCount() >= 2, '改 zzc.lang 后服务器重启并完成握手');
  const def2 = await P.definition.provideDefinition(doc1, posOf(TEXT, '求和', 1));
  ok(Array.isArray(def2) && def2.length === 1, '重启后文档表重建、provider 仍可应答');

  // 16) 停用：ready 复位，provider 不再回包
  ext.deactivate();
  await sleep(300);
  const after = await P.hover.provideHover(doc1, posOf(TEXT, '函数'));
  eq(after, null, 'deactivate 后 provider 短路');

  if (checks !== EXPECT_CHECKS) {
    throw new Error('断言条数退坡/增坡：实收 ' + checks + ' 条，锚定 ' + EXPECT_CHECKS + ' 条——须恢复被删断言，或三处同数上调（本文件 EXPECT_CHECKS／src/cli/args.zig smoke_js_floor／实跑条数）');
  }
  fs.rmSync(work, { recursive: true, force: true });
  console.log('\nPASS：' + checks + ' 项断言全过（扩展目录 ' + EXT_DIR + '）');
}

main().then(() => {
  clearTimeout(hard);
  process.exit(0);
}).catch((e) => {
  console.error('\n[FAIL] ' + (e && e.stack ? e.stack : e));
  console.error('--- 输出面板尾部 ---\n' + state.output.join('').slice(-2000));
  if (state.errors.length) console.error('--- 客户端错误提示 ---\n' + state.errors.join('\n'));
  process.exit(1);
});
