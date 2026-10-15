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
  补全与高亮仍保持声明式（不注册 completion provider），语义级编译诊断不接入 LSP（走下方 task/problemMatcher）
- **客户端提示全母语化**（第 158 轮）：扩展自身面向用户的文案——启动失败弹窗、输出面板帧错误/就绪两行、
  `client_frames.js` 帧格式非法 throw、`package.json` 的 `zzc.lspPath` 设置项描述——均为中文（标识符 `zzc`/`PATH`/`Content-Length` 保留原文）；母语 UI 契约由 `check-demos.ps1` 客户端节守卫逐串钉住

## LSP 客户端配置

- `zzc.lspPath`：指向 `zzc` 可执行文件的路径（留空则用 PATH 上的 `zzc`）。装到非默认位置或开发态未装入
  PATH 时，此项是扩展能否拉起服务器的唯一开关；拉起失败会有明确错误提示指向此项。

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
- 待办：语义级编译诊断接入 LSP（每错击编 zig 既慢又与 `symbols.txt` 写竞争，现仍走 task 通道）
- 多语言包支持（切换 scopeName 对应方言）
