// zzc dialect VS Code client (round 157). Zero npm dependencies: it spawns
// `zzc lsp` and speaks the LSP base protocol directly through client_frames.js,
// wiring only the two server surfaces that exist today -- publishDiagnostics
// (fast checks: fullwidth / lexical / pure-native) and textDocument/hover.
// Completions and highlighting stay declarative (rounds 154/155), so this
// file deliberately registers NO completion provider.
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
// (registry key/alias, e.g. 繁体). Invalid values are handled server-side (the
// existing stderr -> output channel path), so the client does not re-validate.
function zzLang() {
  const cfg = vscode.workspace.getConfiguration('zzc');
  const l = cfg.get('lang');
  return l && l.trim() ? l.trim() : '';
}

function lspSpawnArgs() {
  const args = ['lsp'];
  const l = zzLang();
  if (l) args.push('--lang', l);
  return args;
}

function startServer() {
  child = cp.spawn(zzcBinary(), lspSpawnArgs(), { stdio: ['pipe', 'pipe', 'pipe'] });
  child.on('error', (err) => {
    ready = false;
    vscode.window.showErrorMessage(
      'zzc 语言服务器启动失败（' + err.message + '）。请把 zzc 装入 PATH，或将 zzc.lspPath 设置为其可执行文件路径。');
  });
  child.on('exit', () => { ready = false; });
  if (child.stderr) {
    child.stderr.on('data', (b) => { channel.append(Buffer.from(b).toString('utf8')); });
  }
  decoder = new FrameDecoder();
  child.stdout.on('data', (chunk) => {
    decoder.append(Buffer.from(chunk));
    for (;;) {
      let frame;
      try {
        frame = decoder.take();
      } catch (e) {
        channel.appendLine('lsp 帧解析错误：' + e.message);
        break;
      }
      if (frame === null) break;
      dispatch(frame.json);
    }
  });
}

const channel = vscode.window.createOutputChannel(OUTPUT_CHANNEL);

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
  if (msg.method && (msg.id !== undefined || pending.has(msg.id))) {
    if (msg.method === 'textDocument/publishDiagnostics') {
      applyDiagnostics(msg.params);
      return;
    }
    if (msg.id !== undefined && pending.has(msg.id)) {
      const resolve = pending.get(msg.id);
      pending.delete(msg.id);
      resolve(msg.result === undefined ? null : msg.result);
      return;
    }
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

function docText(doc) { return doc.getText(); }

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
        // round 162: declare full semantic-tokens consumption over the shared legend.
        semanticTokens: {
          requests: { full: true },
          tokenTypes: SEMANTIC_TOKEN_TYPES,
          tokenModifiers: SEMANTIC_TOKEN_MODIFIERS,
          formats: 'relative',
        },
      },
      window: {},
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
  boot();

  context.subscriptions.push(
    // round 163: switching dialect (or lsp path) restarts the server so --lang takes effect.
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('zzc.lang') || e.affectsConfiguration('zzc.lspPath')) restartServer();
    }),
    vscode.workspace.onDidOpenTextDocument(onOpened),
    vscode.workspace.onDidChangeTextDocument((e) => fullChange(e.document)),
    vscode.workspace.onDidCloseTextDocument(onClose),
    vscode.workspace.onDidSaveTextDocument((doc) => {
      if (doc.languageId !== LANGUAGE_ID) return;
      // includeText:false -> uri only; server reads its own doc table (kept current by didChange).
      send({ jsonrpc: '2.0', method: 'textDocument/didSave', params: { textDocument: { uri: doc.uri.toString() } } });
    }),
    vscode.languages.registerHoverProvider({ language: LANGUAGE_ID }, {
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
    // round 162: semantic tokens -- request the server's full stream and hand the
    // relative 5-tuples straight to vscode.SemanticTokens (server data is already
    // [deltaLine, deltaStart, length, type, modifiers] over the shared legend).
    vscode.languages.registerDocumentSemanticTokensProvider(
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
