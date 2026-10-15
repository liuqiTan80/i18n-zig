// zzc dialect VS Code client (round 157). Zero npm dependencies: it spawns
// `zzc lsp` and speaks the LSP base protocol directly through client_frames.js,
// wiring only the two server surfaces that exist today -- publishDiagnostics
// (fast checks: fullwidth / lexical / pure-native) and textDocument/hover.
// Completions and highlighting stay declarative (rounds 154/155), so this
// file deliberately registers NO completion provider.
'use strict';

const vscode = require('vscode');
const cp = require('child_process');
const { encodeFrame, FrameDecoder } = require('./client_frames.js');

const LANGUAGE_ID = 'zig-dialect'; // must equal contributes.languages[0].id (guard-pinned)
const OUTPUT_CHANNEL = 'zzc lsp';

let child = null;
let decoder = null;
let seq = 0;
const pending = new Map(); // request id -> resolve callback
const diagnosticStore = new Map(); // uri string -> vscode.Diagnostic[]
let diags = null;
let ready = false;

function zzcBinary() {
  const cfg = vscode.workspace.getConfiguration('zzc');
  const p = cfg.get('lspPath');
  return p && p.trim() ? p.trim() : 'zzc';
}

function startServer(context) {
  child = cp.spawn(zzcBinary(), ['lsp'], { stdio: ['pipe', 'pipe', 'pipe'] });
  child.on('error', (err) => {
    ready = false;
    vscode.window.showErrorMessage(
      'zzc lsp failed to start (' + err.message + '). Install zzc on PATH or set zzc.lspPath.');
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
        channel.appendLine('lsp frame error: ' + e.message);
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

function activate(context) {
  diags = vscode.languages.createDiagnosticCollection('zzc');
  context.subscriptions.push(diags, channel);
  startServer(context);

  const initialize = {
    processId: process.pid,
    clientInfo: { name: 'zzc-vscode-client' },
    capabilities: {
      textDocument: {
        synchronization: { didSave: false },
        hover: { contentFormat: ['markdown', 'plaintext'] },
      },
      window: {},
    },
    rootUri: null,
  };
  request('initialize', initialize).then((res) => {
    ready = true;
    send({ jsonrpc: '2.0', method: 'initialized', params: {} });
    channel.appendLine('zzc lsp ready (capabilities: ' + JSON.stringify(res && res.capabilities) + ')');
    for (const doc of vscode.workspace.textDocuments) onOpened(doc);
  });

  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument(onOpened),
    vscode.workspace.onDidChangeTextDocument((e) => fullChange(e.document)),
    vscode.workspace.onDidCloseTextDocument(onClose),
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
  );
}

function deactivate() {
  if (child && child.stdin && child.stdin.writable) {
    send({ jsonrpc: '2.0', id: ++seq, method: 'shutdown' });
    send({ jsonrpc: '2.0', method: 'exit' });
    child.stdin.end();
  }
  if (child) child.kill();
}

module.exports = { activate, deactivate };
