# zzc-dialect (VS Code Extension)

母语 Zig 方言编译器 (zzc) 的编辑器集成 MVP。

## 功能

- `.zz` 文件自动关联 `source.zz` 语法
- 中文方言关键词、内建函数、类型名、标准库别名语法高亮
- **补全**：方言关键词/别名作为 snippet 补全候选（按前缀召回，附「→ 标准 Zig 形」说明）
- `zzc check --machine` 问题匹配器（单行诊断 → Problems 面板）
- **LSP 服务器**（第 156 轮）：`zzc lsp` 走 JSON-RPC over stdio，提供悬停（方言词/点链别名反查标准形）、
  快路诊断（全角/词法 + 纯母语强制，推送 publishDiagnostics）与文档同步；VS Code 客户端接线（需扩展宿主
  拉起服务器进程）留后续轮，现下可直接供任何 LSP 客户端（neovim/emacs/helix）使用

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
- ~~LSP 协议集成~~ 服务器核已于第 156 轮落地（`zzc lsp`：悬停/快路诊断/文档同步）；
  待办：VS Code 客户端接线（扩展宿主拉起 `zzc lsp --stdio`）、语义级编译诊断接入 LSP（现仍走 task 通道）
- 多语言包支持（切换 scopeName 对应方言）
