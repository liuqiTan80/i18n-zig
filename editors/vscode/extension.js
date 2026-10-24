// zzc dialect VS Code client (round 157). Zero npm dependencies: it spawns
// `zzc lsp` and speaks the LSP base protocol directly through client_frames.js,
// wiring the server surfaces that exist today -- publishDiagnostics (fast
// checks: fullwidth / lexical / pure-native), textDocument/hover,
// textDocument/documentSymbol (round 263) for the outline/breadcrumb view,
// same-file textDocument/definition (round 264) for go-to-definition on
// top-level declarations, textDocument/references (round 266) for
// find-all-references over the same file, textDocument/documentHighlight
// (round 273) for same-file symbol occurrence highlighting, and
// textDocument/codeAction
// (round 268) for one-click fullwidth-punctuation quick fixes (round 269 adds
// the document-wide source.fixAll kind for editor.codeActionsOnSave), and
// textDocument/foldingRange (round 270) for brace-based structural folding.
// Round 274: the RenameProvider also answers textDocument/prepareRename, so F2
// pre-fills the current name and refuses non-declaration words before an edit
// box ever opens; the server advertises renameProvider{prepareProvider:true}.
// Round 275: WorkspaceSymbolProvider answers workspace/symbol by filtering the
// server's open-document table (top-level declarations, name substring match),
// which lights up "Go to Symbol in Workspace" without any disk scan.
// Round 276: SignatureHelpProvider answers textDocument/signatureHelp inside a
// call paren -- the server matches the callee against same-file top-level
// function declarations and reports the parameter labels plus the comma-counted
// active parameter; member calls and unknown callees return null (no popup).
// Round 277: SelectionRangeProvider answers textDocument/selectionRange so
// Expand Selection walks token -> line -> enclosing brace blocks (inner to
// outer) -> whole document; the server returns the full range/parent chain and
// the client rebuilds it recursively as vscode.SelectionRange.
// Round 279: CompletionItemProvider answers textDocument/completion with four
// server-side candidate sources (same-file declarations, keywords/types, stdlib
// alias roots, dotted chains); dotted candidates carry a TextEdit replacing the
// whole chain prefix. Snippets stay the declarative baseline -- completion is
// additive, not a replacement. Highlighting remains declarative too (round 155).
// Round 160: the client now declares didSave and fires textDocument/didSave on
// editor save, which drives the round-159 server-side on-save semantic
// diagnostics end-to-end (previously reachable only via the declarative
// task/problemMatcher).
// Round 162: the client registers a DocumentSemanticTokensProvider and declares
// the semanticTokens capability, so the round-161 server's semantic-token stream
// for dialect vocabulary actually paints in-editor. The server returns the LSP
// relative 5-tuples directly, so we hand them straight to vscode.SemanticTokens;
// the client legend order must match the server legend verbatim (the type index
// in each tuple points into it -- a reorder silently mis-colors). Highlighting
// stays additive over the declarative tmLanguage base. Rendering lives only in
// the extension host (require('vscode')), so it is not node-behavior testable --
// pinned by text-contract asserts in the check-demos client guard.
// Round 163: multi-dialect selection. The client reads a zzc.lang setting and,
// when set, appends `--lang <dialect>` to the `zzc lsp` spawn so the server picks
// that pack for hover / native diagnostics / semantic tokens (the server already
// honors --lang; rounds 161/162 make semantic tokens carry the dialect vocabulary,
// so switching repaints in-editor without a second tmLanguage). Changing zzc.lang
// (or zzc.lspPath) auto-restarts the server. tmLanguage stays the default-dialect
// static base -- a deliberate scope decision recorded in the ledger.
// Round 267: runtime third-party overlay packs. The client reads zzc.langOverlay
// and appends `--lang-overlay <file>` to the same spawn; the server merges the
// overlay into the selected base pack before LSP starts (round 265 CLI seam), so
// overlay aliases/docs (e.g. contrib/packs/httpz-中文.txt) reach hover without a
// rebuild. Changing zzc.langOverlay also restarts the server.
'use strict';

const vscode = require('vscode');
const cp = require('child_process');
const { encodeFrame, FrameDecoder } = require('./client_frames.js');

const LANGUAGE_ID = 'zig-dialect'; // must equal contributes.languages[0].id (guard-pinned)
const OUTPUT_CHANNEL = 'zzc lsp';

// Round 162: semantic-token legend. Order/type names must match the round-161
// server initialize legend verbatim -- the `type` index in each data 5-tuple
// points into this array, so any reorder silently mis-colors (guard-pinned).
const SEMANTIC_TOKEN_TYPES = ['keyword', 'type', 'function', 'variable', 'string', 'comment', 'number'];
const SEMANTIC_TOKEN_MODIFIERS = [];

let child = null;
let decoder = null;
let seq = 0;
const pending = new Map(); // request id -> resolve callback
const diagnosticStore = new Map(); // uri string -> vscode.Diagnostic[]
let diags = null;
let ready = false;
let bootGen = 0; // restart generation: a superseded initialize resolve must not repaint

function zzcBinary() {
  const cfg = vscode.workspace.getConfiguration('zzc');
  const p = cfg.get('lspPath');
  return p && p.trim() ? p.trim() : 'zzc';
}

// Round 163: dialect selection -> `--lang` on the lsp spawn. Empty means the
// built-in default pack; any other value is passed straight to `zzc lsp --lang`
// (registry key/alias, e.g. zh; 繁体.txt is an overlay merged into zh, not a
// selectable pack). Invalid values are handled server-side (the
// existing stderr -> output channel path), so the client does not re-validate.
function zzLang() {
  const cfg = vscode.workspace.getConfiguration('zzc');
  const l = cfg.get('lang');
  return l && l.trim() ? l.trim() : '';
}

// Round 267: optional overlay pack path -> `--lang-overlay <file>`. Empty keeps
// the built-in packs only; an unreadable/invalid file is reported server-side via
// the existing stderr -> output-channel path (same policy as zzc.lang).
function zzLangOverlay() {
  const cfg = vscode.workspace.getConfiguration('zzc');
  const p = cfg.get('langOverlay');
  return p && p.trim() ? p.trim() : '';
}

function lspSpawnArgs() {
  const args = ['lsp'];
  const l = zzLang();
  if (l) args.push('--lang', l);
  const o = zzLangOverlay();
  if (o) args.push('--lang-overlay', o);
  return args;
}

function startServer() {
  const bin = zzcBinary();
  const args = lspSpawnArgs();
  // Round 278: a spawn failure or an immediate exit used to leave the "zzc lsp"
  // channel empty (only a transient popup), making a real client impossible to
  // diagnose. Announce the command line and every failure on the channel.
  channel.appendLine('启动语言服务器：' + bin + ' ' + args.join(' '));
  child = cp.spawn(bin, args, { stdio: ['pipe', 'pipe', 'pipe'] });
  child.on('error', (err) => {
    ready = false;
    channel.appendLine('启动失败：' + err.message);
    vscode.window.showErrorMessage(
      'zzc 语言服务器启动失败（' + err.message + '）。请把 zzc 装入 PATH，或将 zzc.lspPath 设置为其可执行文件路径。');
  });
  child.on('exit', (code, signal) => {
    ready = false;
    channel.appendLine('语言服务器退出（code=' + code + '，signal=' + signal + '）');
  });
  if (child.stderr) {
    child.stderr.on('data', (b) => { channel.append(Buffer.from(b).toString('utf8')); });
  }
  // Round 278: capture this generation's decoder locally. deactivate() nulls the
  // module-level `decoder` while the killed pipe may still deliver buffered bytes
  // (crash: null.append), and a restart installs a fresh decoder that stale bytes
  // from the previous child would corrupt (frame desync).
  const dec = new FrameDecoder();
  decoder = dec;
  child.stdout.on('data', (chunk) => {
    if (decoder !== dec) return;
    dec.append(Buffer.from(chunk));
    for (;;) {
      let frame;
      try {
        frame = dec.take();
      } catch (e) {
        channel.appendLine('lsp 帧解析错误：' + e.message);
        channel.appendLine('残留缓冲（前 200 字节）：' + JSON.stringify(dec.buf.subarray(0, 200).toString('utf8')));
        break;
      }
      if (frame === null) break;
      dispatch(frame.json);
    }
  });
}

const channel = vscode.window.createOutputChannel(OUTPUT_CHANNEL);

// Round 278: QoderCN's extension host exposes the code-action registration as
// `registerCodeActionsProvider` (plural) while stock VS Code uses the singular
// name. A host missing any provider API must not abort activation wholesale --
// it did: one TypeError here left every provider and the LSP itself dead, with
// only a stack trace in the extension-host log. Register defensively instead.
function registerOptional(name, ...args) {
  const langs = vscode.languages;
  let fn = langs[name];
  if (typeof fn !== 'function' && name === 'registerCodeActionProvider') {
    fn = langs.registerCodeActionsProvider;
  }
  if (typeof fn !== 'function') {
    channel.appendLine('当前扩展宿主不支持 ' + name + '，该功能已跳过');
    return { dispose() {} };
  }
  try {
    return fn.apply(langs, args);
  } catch (e) {
    channel.appendLine('注册 ' + name + ' 失败：' + e.message);
    return { dispose() {} };
  }
}

function send(msg) {
  if (child && child.stdin && child.stdin.writable) {
    child.stdin.write(encodeFrame(JSON.stringify(msg)));
  }
}

function request(method, params) {
  const id = ++seq;
  send({ jsonrpc: '2.0', id, method, params });
  return new Promise((resolve) => pending.set(id, resolve));
}

function dispatch(msg) {
  // Round 278: notifications carry no id. The old entry guard
  // `msg.method && (msg.id !== undefined || pending.has(msg.id))` therefore
  // dropped textDocument/publishDiagnostics wholesale -- the diagnostics panel
  // stayed empty in a real client. Handle the notification before the id test.
  if (msg.method === 'textDocument/publishDiagnostics') {
    applyDiagnostics(msg.params);
    return;
  }
  if (msg.id !== undefined && !msg.method && pending.has(msg.id)) {
    const resolve = pending.get(msg.id);
    pending.delete(msg.id);
    resolve(msg.result === undefined ? null : msg.result);
    return;
  }
  // server-initiated requests (window/*, client/registerCapability) are not
  // used by zzc-lsp today; unknown notifications are ignored per LSP spec.
  if (msg.id !== undefined && msg.method && msg.method.startsWith('window/')) {
    send({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'unsupported' } });
  }
}

function applyDiagnostics(params) {
  if (!params || !params.uri) return;
  const sev = (s) => (s === 1 ? vscode.DiagnosticSeverity.Error
    : s === 2 ? vscode.DiagnosticSeverity.Warning
      : s === 3 ? vscode.DiagnosticSeverity.Information
        : vscode.DiagnosticSeverity.Hint);
  const list = (params.diagnostics || []).map((d) => {
    const r = d.range;
    const diag = new vscode.Diagnostic(
      new vscode.Range(r.start.line, r.start.character, r.end.line, r.end.character),
      d.message, sev(d.severity));
    diag.source = 'zzc';
    if (d.code !== undefined && d.code !== null) diag.code = String(d.code);
    return diag;
  });
  diagnosticStore.set(params.uri, list);
  diags.set(vscode.Uri.parse(params.uri), list);
}

// Round 290 (D149): LSP enumerates CompletionItemKind/SymbolKind from 1 (Text/File = 1) while
// the vscode enums of the same names start from 0 (vscode.d.ts: SymbolKind.Function = 11,
// CompletionItemKind.Function = 2). The server speaks LSP numbers, so handing them straight to
// `new vscode.DocumentSymbol(...)`/`new vscode.CompletionItem(...)` shifts every icon one slot
// (functions render as variables/constructors, constants as strings, keywords as snippets).
// sev() and the DocumentHighlightKind mapping in this file already do that conversion; the kind
// family was the hole. Values come from the shared hub contract (src/lsp/server.zig lsp_kind_base).
function toVscodeKind(k) { return Math.max(k - 1, 0); }
function toVscodeSymbolKind(k) { return k ? toVscodeKind(k) : vscode.SymbolKind.Variable; }

// Round 263: document symbols -> outline/breadcrumbs. The server returns plain
// LSP DocumentSymbol objects (kind/range/selectionRange); map them straight to
// vscode.DocumentSymbol so nested children keep working if the server adds them.
function toDocumentSymbol(s) {
  const r = s.range;
  const sr = s.selectionRange || r;
  const sym = new vscode.DocumentSymbol(
    s.name || '',
    s.detail || '',
    toVscodeSymbolKind(s.kind),
    new vscode.Range(r.start.line, r.start.character, r.end.line, r.end.character),
    new vscode.Range(sr.start.line, sr.start.character, sr.end.line, sr.end.character));
  if (s.children && s.children.length) sym.children = s.children.map(toDocumentSymbol);
  return sym;
}

// Round 277: selection ranges -> expand-selection chain. The server nests the
// larger ranges under `parent` (token -> line -> blocks -> document), so map the
// chain recursively; a node without parent is the whole-document terminus.
function toSelectionRange(r) {
  const rg = r.range;
  return new vscode.SelectionRange(
    new vscode.Range(rg.start.line, rg.start.character, rg.end.line, rg.end.character),
    r.parent ? toSelectionRange(r.parent) : undefined);
}

function docText(doc) { return doc.getText(); }

// Round 269: VS Code filters code actions by CodeActionKind (e.g. on save it asks
// only for source.fixAll). Forward that as LSP context.only; undefined keeps the
// server's round-268 default (quickfix at the cursor).
function codeActionOnly(kind) {
  return kind ? [kind.value] : undefined;
}

function onOpened(doc) {
  if (doc.languageId !== LANGUAGE_ID) return;
  send({
    jsonrpc: '2.0', method: 'textDocument/didOpen',
    params: { textDocument: { uri: doc.uri.toString(), languageId: doc.languageId, version: doc.version, text: docText(doc) } },
  });
}

function fullChange(doc) {
  if (doc.languageId !== LANGUAGE_ID) return;
  send({
    jsonrpc: '2.0', method: 'textDocument/didChange',
    params: {
      textDocument: { uri: doc.uri.toString(), version: doc.version },
      contentChanges: [{ text: docText(doc) }], // server takes the last entry as full text (sync kind 1)
    },
  });
}

function onClose(doc) {
  if (doc.languageId !== LANGUAGE_ID) return;
  send({ jsonrpc: '2.0', method: 'textDocument/didClose', params: { textDocument: { uri: doc.uri.toString() } } });
  diagnosticStore.delete(doc.uri.toString());
  diags.delete(doc.uri);
}

function boot() {
  const myGen = ++bootGen;
  startServer();

  const initialize = {
    processId: process.pid,
    clientInfo: { name: 'zzc-vscode-client' },
    capabilities: {
      textDocument: {
        synchronization: { didSave: true }, // round 160: server declares save{includeText:false}; we drive it on save
        hover: { contentFormat: ['markdown', 'plaintext'] },
        documentSymbol: {},
        definition: {},
        references: {},
        documentHighlight: {},
        codeAction: {},
        foldingRange: {},
        rename: {},
        signatureHelp: {},
        selectionRange: {},
        // round 162: declare full semantic-tokens consumption over the shared legend.
        semanticTokens: {
          requests: { full: true },
          tokenTypes: SEMANTIC_TOKEN_TYPES,
          tokenModifiers: SEMANTIC_TOKEN_MODIFIERS,
          formats: 'relative',
        },
      },
      window: {},
      workspace: { symbol: {} },
    },
    rootUri: null,
  };
  request('initialize', initialize).then((res) => {
    if (myGen !== bootGen) return; // a newer restart superseded this handshake
    ready = true;
    send({ jsonrpc: '2.0', method: 'initialized', params: {} });
    channel.appendLine('zzc lsp 就绪（能力：' + JSON.stringify(res && res.capabilities) + '）');
    for (const doc of vscode.workspace.textDocuments) onOpened(doc);
  });
}

function activate(context) {
  diags = vscode.languages.createDiagnosticCollection('zzc');
  context.subscriptions.push(diags, channel);
  // Round 278: identify the loaded build in the output channel -- a stale
  // installed copy used to be indistinguishable from a fresh one.
  const version = context.extension && context.extension.packageJSON
    ? context.extension.packageJSON.version : '未知';
  channel.appendLine('zzc 扩展已激活（v' + version + '）');
  boot();

  context.subscriptions.push(
    // round 163/267: switching dialect, lsp path or overlay pack restarts the
    // server so --lang / --lang-overlay take effect without a window reload.
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('zzc.lang') || e.affectsConfiguration('zzc.lspPath')
        || e.affectsConfiguration('zzc.langOverlay')) restartServer();
    }),
    vscode.workspace.onDidOpenTextDocument(onOpened),
    vscode.workspace.onDidChangeTextDocument((e) => fullChange(e.document)),
    vscode.workspace.onDidCloseTextDocument(onClose),
    vscode.workspace.onDidSaveTextDocument((doc) => {
      if (doc.languageId !== LANGUAGE_ID) return;
      // includeText:false -> uri only; server reads its own doc table (kept current by didChange).
      send({ jsonrpc: '2.0', method: 'textDocument/didSave', params: { textDocument: { uri: doc.uri.toString() } } });
    }),
    // Round 279: context completion -- the server returns four candidate sources for
    // the prefix before the cursor (same-file top-level declarations, keywords/types,
    // stdlib alias roots, dotted chains). Dotted-chain items carry a textEdit: VS Code
    // only replaces the word under the cursor by default, which would paste the whole
    // chain in front of the last segment (`标准库.调` -> `标准库.标准库.调试.打印`).
    registerOptional('registerCompletionItemProvider', { language: LANGUAGE_ID }, {
      provideCompletionItems: async (doc, pos) => {
        if (!ready) return null;
        const res = await request('textDocument/completion', {
          textDocument: { uri: doc.uri.toString() },
          position: { line: pos.line, character: pos.character },
        });
        if (!res || !Array.isArray(res.items)) return null;
        const list = new vscode.CompletionList();
        list.isIncomplete = !!res.isIncomplete;
        list.items = res.items.map((c) => {
          const item = new vscode.CompletionItem(String(c.label === undefined ? '' : c.label), toVscodeKind(c.kind || 1));
          if (c.detail) item.detail = String(c.detail);
          if (c.documentation) item.documentation = String(c.documentation);
          const te = c.textEdit;
          if (te && te.range && te.range.start && te.range.end) {
            item.textEdit = new vscode.TextEdit(
              new vscode.Range(te.range.start.line, te.range.start.character, te.range.end.line, te.range.end.character),
              String(te.newText === undefined ? '' : te.newText),
            );
          }
          return item;
        });
        return list;
      },
    }, '.'),
    registerOptional('registerHoverProvider', { language: LANGUAGE_ID }, {
      provideHover: async (doc, pos) => {
        if (!ready) return null;
        const res = await request('textDocument/hover', {
          textDocument: { uri: doc.uri.toString() },
          position: { line: pos.line, character: pos.character },
        });
        if (!res || !res.contents) return null;
        return new vscode.Hover(new vscode.MarkdownString(res.contents.value || String(res.contents)));
      },
    }),
    // round 276: signature help -- inside a call paren the server resolves the
    // callee to a same-file top-level function declaration and returns its
    // parameter labels plus the active parameter; anything else yields null so
    // the popup stays closed instead of guessing.
    registerOptional('registerSignatureHelpProvider', { language: LANGUAGE_ID }, {
      provideSignatureHelp: async (doc, pos) => {
        if (!ready) return null;
        const res = await request('textDocument/signatureHelp', {
          textDocument: { uri: doc.uri.toString() },
          position: { line: pos.line, character: pos.character },
        });
        if (!res || !Array.isArray(res.signatures) || !res.signatures.length) return null;
        const help = new vscode.SignatureHelp();
        help.signatures = res.signatures.map((s) => new vscode.SignatureInformation(
          s.label || '',
          undefined,
          (s.parameters || []).map((p) => new vscode.ParameterInformation(p.label || ''))));
        help.activeSignature = res.activeSignature || 0;
        help.activeParameter = res.activeParameter || 0;
        return help;
      },
    }, '(', ','),
    // round 277: selection ranges -- the server walks token -> line -> enclosing
    // brace block (inner to outer) -> whole document and returns one chain per
    // requested position; map every chain recursively into vscode.SelectionRange.
    registerOptional('registerSelectionRangeProvider', { language: LANGUAGE_ID }, {
      provideSelectionRanges: async (doc, positions) => {
        if (!ready) return [];
        const res = await request('textDocument/selectionRange', {
          textDocument: { uri: doc.uri.toString() },
          positions: positions.map((p) => ({ line: p.line, character: p.character })),
        });
        if (!Array.isArray(res)) return [];
        return res.map((r) => toSelectionRange(r));
      },
    }),
    // round 263: outline/breadcrumb surface -- the server scans top-level dialect
    // declarations through the active pack's keyword map (no hardcoded dialect words).
    registerOptional('registerDocumentSymbolProvider', { language: LANGUAGE_ID }, {
      provideDocumentSymbols: async (doc) => {
        if (!ready) return [];
        const res = await request('textDocument/documentSymbol', {
          textDocument: { uri: doc.uri.toString() },
        });
        return Array.isArray(res) ? res.map(toDocumentSymbol) : [];
      },
    }),
    // round 275: workspace symbols -- the server filters top-level declarations
    // across every document it currently holds (no disk scan), so "Go to Symbol
    // in Workspace" and quick-open work across the open .zz files.
    registerOptional('registerWorkspaceSymbolProvider', {
      provideWorkspaceSymbols: async (query) => {
        if (!ready) return [];
        const res = await request('workspace/symbol', { query });
        return Array.isArray(res) ? res.map((s) => new vscode.SymbolInformation(
          s.name || '',
          toVscodeSymbolKind(s.kind),
          '',
          new vscode.Location(vscode.Uri.parse(s.location.uri), new vscode.Range(s.location.range.start.line, s.location.range.start.character, s.location.range.end.line, s.location.range.end.character)))) : [];
      },
    }),
    // round 264: same-file go-to-definition -- the server resolves the token under
    // the cursor against top-level declaration names; lexer token kinds keep
    // comments and strings out, and no scope/cross-file resolution is claimed.
    registerOptional('registerDefinitionProvider', { language: LANGUAGE_ID }, {
      provideDefinition: async (doc, pos) => {
        if (!ready) return null;
        const res = await request('textDocument/definition', {
          textDocument: { uri: doc.uri.toString() },
          position: { line: pos.line, character: pos.character },
        });
        if (!res) return null;
        const locs = Array.isArray(res) ? res : [res];
        return locs.map((loc) => new vscode.Location(
          vscode.Uri.parse(loc.uri),
          new vscode.Range(
            loc.range.start.line, loc.range.start.character,
            loc.range.end.line, loc.range.end.character)));
      },
    }),
    // round 266: same-file find-all-references -- the server resolves the cursor
    // token to a top-level declaration, then returns every matching code token;
    // comments/strings stay out, while scope shadowing is not disambiguated.
    registerOptional('registerReferenceProvider', { language: LANGUAGE_ID }, {
      provideReferences: async (doc, pos, context) => {
        if (!ready) return [];
        const res = await request('textDocument/references', {
          textDocument: { uri: doc.uri.toString() },
          position: { line: pos.line, character: pos.character },
          context: { includeDeclaration: context.includeDeclaration },
        });
        if (!Array.isArray(res)) return [];
        return res.map((loc) => new vscode.Location(
          vscode.Uri.parse(loc.uri),
          new vscode.Range(
            loc.range.start.line, loc.range.start.character,
            loc.range.end.line, loc.range.end.character)));
      },
    }),
    // round 273: same-file symbol highlights -- the server resolves the cursor token
    // to a top-level declaration and returns every matching code token, marking the
    // declaration occurrence Write and the rest Read; unresolved words yield [].
    registerOptional('registerDocumentHighlightProvider', { language: LANGUAGE_ID }, {
      provideDocumentHighlights: async (doc, pos) => {
        if (!ready) return [];
        const res = await request('textDocument/documentHighlight', {
          textDocument: { uri: doc.uri.toString() },
          position: { line: pos.line, character: pos.character },
        });
        if (!Array.isArray(res)) return [];
        return res.map((h) => new vscode.DocumentHighlight(
          new vscode.Range(h.range.start.line, h.range.start.character, h.range.end.line, h.range.end.character),
          h.kind === 3 ? vscode.DocumentHighlightKind.Write : vscode.DocumentHighlightKind.Read));
      },
    }),
    // round 268: quick fixes for fullwidth punctuation -- the server reuses the
    // same danger table as the fast diagnostics and returns CodeAction literals
    // carrying edit.changes{uri:[{range,newText}]}. Only violations with an ASCII
    // replacement get a lightbulb (zero-width-space deletions stay out of scope),
    // and the range is honored: selection intersects, cursor includes the right
    // boundary so a caret just past the char still offers the fix.
    // round 269: the same provider also serves document-wide source.fixAll (the
    // server returns one bulk action when context.only asks for it), which makes
    // editor.codeActionsOnSave: { "source.fixAll": true } fix every fullwidth
    // punctuation on save without a separate command.
    registerOptional('registerCodeActionProvider', { language: LANGUAGE_ID }, {
      provideCodeActions: async (doc, range, context) => {
        if (!ready) return [];
        const res = await request('textDocument/codeAction', {
          textDocument: { uri: doc.uri.toString() },
          range: {
            start: { line: range.start.line, character: range.start.character },
            end: { line: range.end.line, character: range.end.character },
          },
          context: {
            diagnostics: [],
            only: codeActionOnly(context.only),
          },
        });
        if (!Array.isArray(res)) return [];
        return res.map((item) => {
          const kind = item.kind === 'source.fixAll'
            ? vscode.CodeActionKind.SourceFixAll
            : vscode.CodeActionKind.QuickFix;
          const action = new vscode.CodeAction(item.title, kind);
          action.edit = new vscode.WorkspaceEdit();
          const changes = (item.edit && item.edit.changes) || {};
          for (const uri of Object.keys(changes)) {
            for (const c of changes[uri]) {
              action.edit.replace(
                vscode.Uri.parse(uri),
                new vscode.Range(
                  c.range.start.line, c.range.start.character,
                  c.range.end.line, c.range.end.character),
                c.newText);
            }
          }
          return action;
        });
      },
    }, {
      providedCodeActionKinds: [vscode.CodeActionKind.QuickFix, vscode.CodeActionKind.SourceFixAll],
    }),
    // round 270: structural folding -- the server pairs `{`/`}` lexer tokens, so
    // braces inside strings/comments never open a fold; single-line blocks and
    // unmatched braces are skipped. round 271 adds consecutive own-line comment
    // blocks (`kind: 'comment'`) mapped to FoldingRangeKind.Comment. `// #region`
    // markers stay with language-configuration.json (the provider is additive).
    registerOptional('registerFoldingRangeProvider', { language: LANGUAGE_ID }, {
      provideFoldingRanges: async (doc) => {
        if (!ready) return [];
        const res = await request('textDocument/foldingRange', {
          textDocument: { uri: doc.uri.toString() },
        });
        if (!Array.isArray(res)) return [];
        return res.map((r) => new vscode.FoldingRange(r.startLine, r.endLine, r.kind === 'comment' ? vscode.FoldingRangeKind.Comment : undefined));
      },
    }),
    // round 272: rename -- the server renames same-file top-level declarations and
    // returns a WorkspaceEdit-shaped `changes` map (strings/comments are excluded
    // by its lexer scan). A null answer means "cannot rename" and applies nothing.
    // round 274: prepareRename pre-checks the cursor -- non-declaration words and
    // strings/comments return null, so F2 does not open a dead input box; a hit
    // returns the word range and the old name as the placeholder.
    registerOptional('registerRenameProvider', { language: LANGUAGE_ID }, {
      prepareRename: async (doc, pos) => {
        if (!ready) return null;
        const res = await request('textDocument/prepareRename', {
          textDocument: { uri: doc.uri.toString() },
          position: { line: pos.line, character: pos.character },
        });
        if (!res || !res.range) return null;
        return {
          range: new vscode.Range(
            res.range.start.line, res.range.start.character,
            res.range.end.line, res.range.end.character),
          placeholder: res.placeholder,
        };
      },
      provideRenameEdits: async (doc, pos, newName) => {
        if (!ready) return null;
        const res = await request('textDocument/rename', {
          textDocument: { uri: doc.uri.toString() },
          position: { line: pos.line, character: pos.character },
          newName,
        });
        if (!res || !res.changes) return null;
        const edit = new vscode.WorkspaceEdit();
        for (const [uri, changes] of Object.entries(res.changes)) {
          for (const c of changes) {
            edit.replace(
              vscode.Uri.parse(uri),
              new vscode.Range(
                c.range.start.line, c.range.start.character,
                c.range.end.line, c.range.end.character),
              c.newText);
          }
        }
        return edit;
      },
    }),
    // round 162: semantic tokens -- request the server's full stream and hand the
    // relative 5-tuples straight to vscode.SemanticTokens (server data is already
    // [deltaLine, deltaStart, length, type, modifiers] over the shared legend).
    registerOptional('registerDocumentSemanticTokensProvider',
      { language: LANGUAGE_ID },
      {
        provideDocumentSemanticTokens: async (doc) => {
          if (!ready) return new vscode.SemanticTokens([], null);
          const res = await request('textDocument/semanticTokens/full', {
            textDocument: { uri: doc.uri.toString() },
          });
          return new vscode.SemanticTokens((res && res.data) ? res.data : [], null);
        },
      },
      new vscode.SemanticTokensLegend(SEMANTIC_TOKEN_TYPES, SEMANTIC_TOKEN_MODIFIERS),
    ),
  );
}

function shutdownChild() {
  if (child && child.stdin && child.stdin.writable) {
    send({ jsonrpc: '2.0', id: ++seq, method: 'shutdown' });
    send({ jsonrpc: '2.0', method: 'exit' });
    child.stdin.end();
  }
  if (child) child.kill();
  child = null;
  decoder = null;
  ready = false;
}

// round 163: re-spawn with the current zzc.lang / zzc.lspPath. bootGen (bumped in
// boot) makes any superseded initialize resolve a no-op, so rapid double changes
// converge on the last spawn without stale repaints.
function restartServer() {
  shutdownChild();
  pending.clear();
  diagnosticStore.clear();
  if (diags) diags.clear();
  boot();
}

function deactivate() {
  shutdownChild();
}

module.exports = { activate, deactivate };
