# zzc-dialect (VS Code Extension)

母语 Zig 方言编译器 (zzc) 的编辑器集成 MVP。

## 功能

- `.zz` 文件自动关联 `source.zz` 语法
- 中文方言关键词、内建函数、类型名、标准库别名语法高亮
- **补全**：方言关键词/别名作为 snippet 补全候选（按前缀召回，附「→ 标准 Zig 形」说明）
- `zzc check --machine` 问题匹配器（单行诊断 → Problems 面板）
- **LSP 服务器**（第 156 轮）：`zzc lsp` 走 JSON-RPC over stdio，提供悬停（方言词/点链别名反查标准形）、
  快路诊断（全角/词法 + 纯母语强制，推送 publishDiagnostics）与文档同步；服务器本体可直接供任何 LSP
  客户端（neovim/emacs/helix）使用
- **LSP 客户端接线**（第 157 轮）：`extension.js` + `client_frames.js` 零 npm 依赖扩展宿主——自行
  spawn `zzc lsp` 并按基座协议（`Content-Length` 字节计长、头名大小写不敏感、10MB 上限与服务端同源）
  收发帧，把 publishDiagnostics 落到 Problems 面板、把悬停接到 hover provider，stderr 转「zzc lsp」输出面板。
  补全与高亮仍保持声明式（不注册 completion provider）；高亮仍以声明式 tmLanguage（静态 ASCII 模式）为基底，
  第 161 轮服务端另开 `semanticTokens/full` **语义 token 供给**面（补方言母语词汇、与 tmLanguage 叠加），
  客户端渲染已于第 162 轮接线（`DocumentSemanticTokensProvider`，见下条）；语义级编译诊断的**服务端 on-save 供给**已于第 159 轮接入
  （见下条），**客户端 `didSave` 端到端触发已于第 160 轮接线**（见下下条）——编辑器内保存即触发服务端语义诊断
- **语义级编译诊断接入 LSP·服务端 on-save**（第 159 轮）：`zzc lsp` 现声明 `textDocumentSync` 的 `save` 能力，
  并在 `didSave` 时按需 spawn 一个短命 `zzc check --machine` 子进程（自带干净 arena、退出即回收，不触服务端长活
  arena 无界增长），把回译后的**母语**语义诊断（复用第 154 轮 `--machine` 链、坐标已回映 `.zz` 源、级别经 LSP
  `severity` 表达）并入 `publishDiagnostics` 发布；语义**仅在保存触发**——didOpen/didChange 只跑快路（全角/词法 +
  纯母语强制），刻意避免每键击真编译。服务器侧行为由 `check-demos.ps1` 的「lsp on-save semantic guard」e2e 节钉住
  （didOpen 发空、didSave 发原生语义项；缺 zig 走 `[SKIP]`）
- **语义诊断客户端端到端触发**（第 160 轮）：客户端能力翻 `textDocument.synchronization.didSave:true`，注册
  `onDidSaveTextDocument` 回调、保存时按 `includeText:false` 契约只发 uri 的 `textDocument/didSave`（不发内联文本，
  文档表已由每次 didChange 保最新），据此驱动第 159 轮服务端 on-save 语义诊断在编辑器内端到端落到 Problems 面板；
  快路诊断仍逐键击、语义仅保存时跑。客户端接线由 `check-demos.ps1`「lsp client guard」节以文本契约钉住
  （能力翻转、保存回调、uri-only didSave 发出各一面，反证撤任一行即转红）
- **客户端提示全母语化**（第 158 轮）：扩展自身面向用户的文案——启动失败弹窗、输出面板帧错误/就绪两行、
  `client_frames.js` 帧格式非法 throw、`package.json` 的 `zzc.lspPath` 设置项描述——均为中文（标识符 `zzc`/`PATH`/`Content-Length` 保留原文）；母语 UI 契约由 `check-demos.ps1` 客户端节守卫逐串钉住
- **语义 token 高亮供给·服务端**（第 161 轮）：`zzc lsp` 按 LSP 标准实现 `textDocument/semanticTokens/full`，把「方言母语词汇」（tmLanguage 静态 ASCII 模式看不见的那部分）的语义 token 流供给任意 LSP 客户端。图例 `keyword/type/function/variable/string/comment/number`（index 即类型）、`full` 供给；发 token 规则复用真相源（`lexer.scan` 切词 + `snippets.classify`/`lang.keywords` 分组，不硬编码词表、语言无关）：注释→comment、串/字符/多行/符号→string、数字字面量→number、命中 keywords 的母语词按词类→keyword/type/function/variable；**跳过策略**——未命中 keywords 的母语标识符/标准库别名段/非数字 ASCII 词/punct 一律不发，保 tmLanguage 既有着色不被降级。语义 token 仅「被请求才返回」，VS Code 扩展未注册 provider 前不应用（无 tmLanguage 降级风险），非 VSCode 客户端（neovim/emacs）即时受益。服务器侧由 `check-demos.ps1`「lsp handshake guard」节以裸 JSON-RPC e2e 帧钉住（能力钉 + `data` 元组断言）；客户端渲染已于第 162 轮接线（见下条）
- **语义 token 高亮客户端渲染**（第 162 轮）：`extension.js` 声明 `semanticTokens`（`requests:{full:true}`、`formats:'relative'`）能力并注册 `DocumentSemanticTokensProvider`——`provideDocumentSemanticTokens` 发 `textDocument/semanticTokens/full` 请求、把服务端已产的相对 5 元组直接投 `new vscode.SemanticTokens(res.data)`（无需客户端重编码）。**图例与服务端同序为共享真相源承重**：`SEMANTIC_TOKEN_TYPES = keyword/type/function/variable/string/comment/number` 须与服务端 initialize 图例逐字对齐（每个 token 的 type 索引即指向此序、错序即静默错色），由客户端节以文本契约钉住；高亮仅在声明式 tmLanguage 基底上**叠加**、不替换。provider 无 delta/无 refresh，依赖 VS Code 文档变更后自动重取全量（MVP）。渲染属 `require('vscode')` 不可进 node 行为测，故本轮以文本契约守卫（provider 注册/full 能力//full 请求/SemanticTokens 构造/图例同序各钉一面）
- **多语言包·方言切换（客户端）**（第 163 轮）：`extension.js` 读取 `zzc.lang` 设置，非空时向 `zzc lsp` 拉起参数追加 `--lang <方言>`（服务端本就依 main 分发前的统一选包 honoring `--lang`，见第 52/103/140 轮），于是**悬停/母语诊断/语义 token 词汇**随所选方言供词——复用第 161/162 轮「语义 token 承载方言词汇」面，切换方言即重绘编辑器内母语词汇着色，**无需为每门方言生成独立 tmLanguage**。改 `zzc.lang`（或 `zzc.lspPath`）经 `onDidChangeConfiguration` 自动重启服务器（`restartServer`；`bootGen` 世代号令被取代的旧 `initialize` 握手回灌失效）。**设计边界**：`scopeName`/tmLanguage 静态基座仍为默认方言（一门 `zig-dialect`/一个 grammar，`.zz` 文件自身不声明方言），非默认方言词汇着色依赖语义 token（服务端供）、默认包关键字正则不随之变——此为对路线图字面「切换 scopeName」的有意收敛。接线由 `check-demos.ps1` 客户端节以文本契约钉住（`zzc.lang` 属性+母语描述、`--lang` 织入 `lspSpawnArgs` spawn、`onDidChangeConfiguration`→`restartServer` 各一面）

## LSP 客户端配置

- `zzc.lspPath`：指向 `zzc` 可执行文件的路径（留空则用 PATH 上的 `zzc`）。装到非默认位置或开发态未装入
  PATH 时，此项是扩展能否拉起服务器的唯一开关；拉起失败会有明确错误提示指向此项。
- `zzc.lang`（第 163 轮）：方言包名（同 `zzc --lang`，如 `繁体`；留空＝内置默认包中文）。修改后经
  `onDidChangeConfiguration` 自动重启语言服务器，悬停/诊断/语义 token 词汇随即按该方言供词。非法值由
  服务端既有报错处理（stderr 落「zzc lsp」输出面板），客户端不重复校验。

## 安装（开发态）

1. 确保 `zzc` 在 PATH 中（`zig build install` 后取 `zig-out/bin`）
2. 按 F5 启动扩展开发宿主，或 `code --install-extension` VSIX

## 生成语法高亮与补全

```sh
zig build gen-editor-syntax      # 从语言包重新生成 syntaxes/zz.tmLanguage.json
zig build check-editor-syntax    # CI 守卫：校验文件与包同步
zig build gen-editor-snippets    # 从语言包重新生成 snippets/zz.json
zig build check-editor-snippets  # CI 守卫：校验 snippets 与包同步
```

## 任务配置

见 `examples/tasks.json`：将 `zzc check --machine` 设为默认构建任务，
`$zzc-machine` problemMatcher 自动解析输出行并填充 Problems 面板。

## 路线图（后续轮次）

- ~~补全（completion provider）~~ 已于第 155 轮以声明式 snippet 落地（从语言包同源取词）
- ~~LSP 协议集成~~ 服务器核已于第 156 轮落地（`zzc lsp`：悬停/快路诊断/文档同步），VS Code 客户端接线
  已于第 157 轮落地（零依赖扩展宿主 spawn `zzc lsp`、接诊断推送与悬停）
- ~~待办：语义级编译诊断接入 LSP~~ 服务端 on-save 已于第 159 轮落地；客户端翻 `didSave:true`、保存端到端触发
  已于第 160 轮落地（保存只发 uri、服务端按需 spawn `zzc check --machine` 发母语语义诊断，`check-demos` 客户端节文本契约钉住）
- 语义 token 高亮（`semanticTokens/full`）：服务端供给已于第 161 轮落地（方言母语词汇语义 token 流、复用 lexer/classify/keywords、
  任意 LSP 客户端可用，`check-demos` 握手节裸 JSON-RPC e2e 钉住）；客户端渲染已于第 162 轮接线（`extension.js` 注册 `DocumentSemanticTokensProvider`、
  data 相对 5 元组直投 `vscode.SemanticTokens`、图例与服务端同序为共享真相源承重，`check-demos` 客户端节文本契约钉住）——编辑器内方言母语词汇真正上色
- ~~多语言包支持（切换 scopeName 对应方言）~~ 客户端方言切换已于第 163 轮落地（`zzc.lang` 设置 → 向 `zzc lsp` 追加
  `--lang`、配置变更自动重启；经第 161/162 轮语义 token 承载方言词汇，无需独立 tmLanguage；scopeName/tmLanguage 保持默认方言基座为设计边界，`check-demos` 客户端节文本契约钉住）
