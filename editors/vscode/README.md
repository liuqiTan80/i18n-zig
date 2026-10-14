# zzc-dialect (VS Code Extension)

母语 Zig 方言编译器 (zzc) 的编辑器集成 MVP。

## 功能

- `.zz` 文件自动关联 `source.zz` 语法
- 中文方言关键词、内建函数、类型名、标准库别名语法高亮
- `zzc check --machine` 问题匹配器（单行诊断 → Problems 面板）

## 安装（开发态）

1. 确保 `zzc` 在 PATH 中（`zig build install` 后取 `zig-out/bin`）
2. 按 F5 启动扩展开发宿主，或 `code --install-extension` VSIX

## 生成语法高亮

```sh
zig build gen-editor-syntax      # 从语言包重新生成 syntaxes/zz.tmLanguage.json
zig build check-editor-syntax    # CI 守卫：校验文件与包同步
```

## 任务配置

见 `examples/tasks.json`：将 `zzc check --machine` 设为默认构建任务，
`$zzc-machine` problemMatcher 自动解析输出行并填充 Problems 面板。

## 路线图（后续轮次）

- 补全（completion provider）
- LSP 协议集成
- 多语言包支持（切换 scopeName 对应方言）
