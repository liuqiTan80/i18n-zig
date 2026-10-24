'use strict';
// 最小 `vscode` API 桩（第 278 轮·本地客户端 e2e 用）。
//
// 目的：让 editors/vscode/extension.js 能在纯 node 下加载并跑通——不是模拟
// 编辑器渲染，而是把 extension.js 真正注册的 provider/事件处理器抓下来，逐条
// 对着真 `zzc lsp` 进程断言。只实现 extension.js 实际用到的面；新增客户端 API
// 时此桩须同步补齐（缺哪个就在 require 时爆 undefined，不会静默假绿）。

const state = {
  config: {}, // 键 -> 值（harness 在 activate 前填）
  providers: {}, // 注册名 -> provider 对象
  handlers: {}, // 事件名 -> 回调
  diagnostics: new Map(), // uri 字符串 -> Diagnostic[]
  output: [], // 输出面板累积行
  errors: [], // showErrorMessage 累积
  legends: {}, // 语义 token 图例
  triggerChars: {}, // 注册名 -> 触发字符尾参（补全的 `.` 等）
  workspaceTextDocuments: [],
};

class Position {
  constructor(line, character) {
    this.line = line;
    this.character = character;
  }
}

class Range {
  constructor(startLine, startCharacter, endLine, endCharacter) {
    this.start = new Position(startLine, startCharacter);
    this.end = new Position(endLine, endCharacter);
  }
}

class Uri {
  constructor(value) {
    this._value = value;
  }
  static parse(value) {
    return new Uri(value);
  }
  static file(p) {
    return new Uri('file://' + p);
  }
  toString() {
    return this._value;
  }
  get fsPath() {
    return this._value.replace(/^file:\/\//, '');
  }
}

class MarkdownString {
  constructor(value) {
    this.value = value || '';
  }
}

class Hover {
  constructor(contents) {
    this.contents = contents;
  }
}

class Location {
  constructor(uri, range) {
    this.uri = uri;
    this.range = range;
  }
}

class Diagnostic {
  constructor(range, message, severity) {
    this.range = range;
    this.message = message;
    this.severity = severity;
    this.source = undefined;
    this.code = undefined;
  }
}

class DocumentSymbol {
  constructor(name, detail, kind, range, selectionRange) {
    this.name = name;
    this.detail = detail;
    this.kind = kind;
    this.range = range;
    this.selectionRange = selectionRange;
    this.children = [];
  }
}

class SymbolInformation {
  constructor(name, kind, containerName, location) {
    this.name = name;
    this.kind = kind;
    this.containerName = containerName;
    this.location = location;
  }
}

class SelectionRange {
  constructor(range, parent) {
    this.range = range;
    this.parent = parent;
  }
}

class CompletionItem {
  constructor(label, kind) {
    this.label = label;
    this.kind = kind;
  }
}

class CompletionList {
  constructor(items, isIncomplete) {
    this.items = items || [];
    this.isIncomplete = !!isIncomplete;
  }
}

class TextEdit {
  constructor(range, newText) {
    this.range = range;
    this.newText = newText;
  }
}

class FoldingRange {
  constructor(startLine, endLine, kind) {
    this.startLine = startLine;
    this.endLine = endLine;
    this.kind = kind;
  }
}

class CodeAction {
  constructor(title, kind) {
    this.title = title;
    this.kind = kind;
    this.edit = undefined;
  }
}

class WorkspaceEdit {
  constructor() {
    this.entries = [];
  }
  replace(uri, range, newText) {
    this.entries.push({ uri, range, newText });
  }
}

class DocumentHighlight {
  constructor(range, kind) {
    this.range = range;
    this.kind = kind;
  }
}

class SignatureHelp {
  constructor() {
    this.signatures = [];
    this.activeSignature = 0;
    this.activeParameter = 0;
  }
}

class SignatureInformation {
  constructor(label, documentation, parameters) {
    this.label = label;
    this.documentation = documentation;
    this.parameters = parameters || [];
  }
}

class ParameterInformation {
  constructor(label) {
    this.label = label;
  }
}

class SemanticTokens {
  constructor(data, resultId) {
    this.data = data;
    this.resultId = resultId;
  }
}

class SemanticTokensLegend {
  constructor(tokenTypes, tokenModifiers) {
    this.tokenTypes = tokenTypes;
    this.tokenModifiers = tokenModifiers;
  }
}

function disposable() {
  return { dispose() {} };
}

function register(name) {
  return (selector, provider, ...rest) => {
    state.providers[name] = provider;
    if (rest.length) state.triggerChars[name] = rest;
    return disposable();
  };
}

const DiagnosticSeverity = { Error: 0, Warning: 1, Information: 2, Hint: 3 };
const SymbolKind = {
  File: 0, Module: 1, Namespace: 2, Package: 3, Class: 4, Method: 5, Property: 6,
  Field: 7, Constructor: 8, Enum: 9, Interface: 10, Function: 11, Variable: 12,
  Constant: 13, String: 14, Number: 15, Boolean: 16, Array: 17, Object: 18,
  Key: 19, Null: 20, EnumMember: 21, Struct: 22, Event: 23, Operator: 24,
  TypeParameter: 25,
};
const FoldingRangeKind = { Comment: 1, Imports: 2, Region: 3 };
const CodeActionKind = {
  QuickFix: { value: 'quickfix' },
  SourceFixAll: { value: 'source.fixAll' },
};
const DocumentHighlightKind = { Text: 0, Read: 1, Write: 2 };
// 第 290 轮 D149：补全项图标枚举——按 vscode.d.ts 真实面暴露（0 基：Text=0／Method=1／
// Function=2／…／Keyword=13／…／Constant=20／Struct=21），此前桩里没有它，扩展把 LSP 的
// 1 基数直传构造器也没人能对账，e2e 断言只能抄写侧原数自照。
const CompletionItemKind = {
  Text: 0, Method: 1, Function: 2, Constructor: 3, Field: 4, Variable: 5, Class: 6,
  Interface: 7, Module: 8, Property: 9, Unit: 10, Value: 11, Enum: 12, Keyword: 13,
  Snippet: 14, Color: 15, File: 16, Reference: 17, Folder: 18, EnumMember: 19,
  Constant: 20, Struct: 21, Event: 22, Operator: 23, TypeParameter: 24,
};

const languages = {
  createDiagnosticCollection() {
    return {
      set(uri, list) {
        state.diagnostics.set(uri.toString(), list);
      },
      delete(uri) {
        state.diagnostics.delete(uri.toString());
      },
      clear() {
        state.diagnostics.clear();
      },
      dispose() {},
    };
  },
  registerHoverProvider: register('hover'),
  registerCompletionItemProvider: register('completion'),
  registerSignatureHelpProvider: register('signatureHelp'),
  registerSelectionRangeProvider: register('selectionRange'),
  registerDocumentSymbolProvider: register('documentSymbol'),
  registerWorkspaceSymbolProvider(provider) {
    // 注意：VS Code 这个注册函数只收 provider 本体，没有 selector（与其它
    // register*Provider(selector, provider) 不同构），桩不能复用 register()。
    state.providers.workspaceSymbol = provider;
    return disposable();
  },
  registerDefinitionProvider: register('definition'),
  registerReferenceProvider: register('references'),
  registerDocumentHighlightProvider: register('documentHighlight'),
  // QoderCN 的宿主只暴露复数名（标准 VS Code 为单数
  // registerCodeActionProvider）；桩按宿主真实面暴露，逼迫扩展走兼容分支。
  registerCodeActionsProvider: register('codeAction'),
  registerFoldingRangeProvider: register('foldingRange'),
  registerRenameProvider: register('rename'),
  registerDocumentSemanticTokensProvider(selector, provider, legend) {
    state.providers.semanticTokens = provider;
    state.legends.semanticTokens = legend;
    return disposable();
  },
};

const workspace = {
  get textDocuments() {
    return state.workspaceTextDocuments;
  },
  getConfiguration() {
    return {
      get(key, fallback) {
        return Object.prototype.hasOwnProperty.call(state.config, key) ? state.config[key] : fallback;
      },
    };
  },
  onDidChangeConfiguration(cb) {
    state.handlers.config = cb;
    return disposable();
  },
  onDidOpenTextDocument(cb) {
    state.handlers.open = cb;
    return disposable();
  },
  onDidChangeTextDocument(cb) {
    state.handlers.change = cb;
    return disposable();
  },
  onDidCloseTextDocument(cb) {
    state.handlers.close = cb;
    return disposable();
  },
  onDidSaveTextDocument(cb) {
    state.handlers.save = cb;
    return disposable();
  },
};

const window = {
  createOutputChannel(name) {
    return {
      name,
      append(s) {
        state.output.push(String(s));
      },
      appendLine(s) {
        state.output.push(String(s) + '\n');
      },
      show() {},
      dispose() {},
    };
  },
  showErrorMessage(msg) {
    state.errors.push(String(msg));
  },
  showWarningMessage() {},
  showInformationMessage() {},
};

module.exports = {
  __state: state,
  version: '1.85.0',
  Position, Range, Uri, MarkdownString, Hover, Location, Diagnostic, DocumentSymbol,
  CompletionItem, CompletionList, TextEdit,
  SymbolInformation, SelectionRange, FoldingRange, CodeAction, WorkspaceEdit,
  DocumentHighlight, SignatureHelp, SignatureInformation, ParameterInformation,
  SemanticTokens, SemanticTokensLegend, DiagnosticSeverity, SymbolKind,
  FoldingRangeKind, CodeActionKind, DocumentHighlightKind, CompletionItemKind,
  languages, workspace, window,
};
