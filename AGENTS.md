# AGENTS.md — AI 编码助手在本仓库写 `.zz` 方言的操作手册

本仓库是 **zzc**：母语方言 Zig 前端（翻译器 + 语言服务器 + VS Code 扩展）。
你用母语词形编写 `.zz` 源码，zzc 翻译为真实 Zig 后交给本机 `zig` 工具链编译测试。

**铁律：写出的方言代码必须全是使用者母语的词形。** 英文 Zig 关键词（`const`/`fn`/`try`/
`struct` 等）不允许出现在 `.zz` 源码里——纯母语过滤器会在 `zzc check` 时拦截并给出改词
候选，无需你记忆词表。ASCII 标识符（如 `std.io.getStdOut()` 的库路径）是名称而非关键词，
技术合法；但命名应优先母语词（如 `标准库.调试.打印`）。

## 闭环工作流（每一步都机读可验）

1. **scaffold**：`zzc init <目录>` 建工程骨架（布局约定：方言源码放 `<目录>/src/main.zz`）。
2. **写码**：只用母语关键词词形。查词不用猜——三处真值源：
   - `src/lang/packs/中文.txt`（默认包全词表，含注释）
   - `docs/关键字对照表.md`（英文 Zig 关键词 ↔ 母语词形对照）
   - 或直接跑 `zzc check` 读报错里的改词候选（如 `请改用 常数/常數`）。
3. **自检闭环**：写完必跑——
   ```sh
   zzc check --machine src   # 单行机读形制：路径:行:列: 种类: 消息（提示：…）
   ```
   退出码非 0 或有任何输出即未纯；按报错改词重跑，直到 `✔ 检查通过` 且退出码 0。
   `--machine` 专为工具逐行正则消费设计，人读可去掉该旗标。
4. **编译与测试**：`zzc build`（翻译 → 调本机 zig 编译）；`zzc run` 直接跑；
   `zzc test` 跑方言测试。翻译产物在 `.zzc/gen/`——**只读**，改码改 `src/` 下的 `.zz`。
5. **交付 Zig 上游前**：`zzc eject` 剥词形还原标准 Zig 源码。

## 指定语言（写作者语言 ≠ 默认包时）

- 默认包为中文（zh）。选择语言包：`zzc check --lang <注册名> src`（该旗标不透传 zig）。
- 查看当前可用包：`zzc lang`（列出注册名与描述）；`zzc version` 亦显示当前包。
- 装入外部包：`zzc lang add <文件.txt>`（可配 `--as <注册名>` 指定注册名，免重编译）。
- 从文件直接加载（不落注册）：`--lang-file <路径>`（与 `--lang` 互斥）。
- 第三方库母语翻译叠加：`--lang-overlay <路径>`（累积并入所选基包之上，可与
  `--lang`/`--lang-file` 合用）。
- 写完一个包切换语言时，同一份源码用不同包分别 `zzc check` 验纯。

## 禁止事项（真实防线，不是建议）

- 禁止在 `.zz` 里混写英文 Zig 关键词——`zzc check` 直接报错并指路改词。
- 禁止使用未注册的包名于 `--lang`——会报「未知语言包」并列出可用集。
- 禁止手改 `.zzc/gen/` 与 vsix 包内产物——皆为生成面，重编译即覆盖。
- 文档/示例里的命令词与旗标名受机读守卫对账（`check-machine-matcher`），漂词形即红；
  改 CLI 词面须同步 `docs/` 与本文件，判据单源在 `src/cli/args.zig`。

## 环境事实

- 需本机 `zig`（项目基线 0.17.0）在 PATH；zzc 可执行文件在 `zig-out/bin/zzc`
  （或已安装为 `zzc`）。
- LSP 服务器：`zzc lsp`（stdio JSON-RPC），供任何 LSP 客户端；VS Code 扩展装
  `zig-out` 产出的 vsix。
- 全仓门禁：`zig build` / `zig build test` / `zig build check-machine-matcher` /
  `bash tools/demos-smoke.sh`。
