# zzc · 用母语编写真正的 Zig

> **zzc** 是一个母语 Zig 方言编译器（transpiler + 工具链驱动）：你用**中文（或其它母语）关键字**写代码，zzc 把它翻译成**标准 Zig**，再交给真正的 `zig` 去编译、运行、测试。语法骨架 `()` `{}` `[]` ; = `@` `?` 等保持英文半角，其余词汇由语言包映射为 Zig 关键字/内建/标准库路径。

一句话：**这不是玩具语言，方言背后就是 Zig 本身**——写进去的是母语，跑出来的是真 Zig，报错也翻回母语。

- 当前版本：`zzc 0.1.0`
- 工具链基线：**Zig `0.17.0`**（`build.zig.zon` 声明 `minimum_zig_version = "0.17.0"`）
- 依赖：**零第三方依赖**，纯 Zig 标准库（`std`）

---

## 📖 教程快速入口

配套中文参考书 **[《母语编写 Zig》](docs/母语编写zig-中文版.md#目录)**——零基础到工程实战，每条经验都有工单号可查。按你的需要直接跳读：

| 你是谁 / 想要什么 | 从这里进 |
| --- | --- |
| 🚀 **零基础起步** | [第 0 章 把工具装好](docs/母语编写zig-中文版.md#第-0-章-把工具装好，端上第一盘菜) → [第 1 章 基本比喻](docs/母语编写zig-中文版.md#第-1-章-编程世界的几个基本比喻) → [第 2 章 语法骨架](docs/母语编写zig-中文版.md#第-2-章-语法骨架：哪些还是「英文符号」) |
| 🧩 **核心语法** | [控制流](docs/母语编写zig-中文版.md#第-4-章-让程序学会「看情况办事」（控制流）) · [循环](docs/母语编写zig-中文版.md#第-5-章-重复的力量（循环）) · [函数](docs/母语编写zig-中文版.md#第-6-章-函数：把一段活打包起来反复叫) · [错误与可选](docs/母语编写zig-中文版.md#第-7-章-会出错怎么办：错误与可选) · [结构 / 枚举 / 联合](docs/母语编写zig-中文版.md#第-8-章-把数据打包：结构--枚举--联合) · [标准库地图](docs/母语编写zig-中文版.md#第-9-章-标准库地图：那些带点号的长名字) |
| 🌊 **进阶深潜** | [内存的本质](docs/母语编写zig-中文版.md#第-12-章-内存的本质：从盒子到地址) · [分配器工程](docs/母语编写zig-中文版.md#第-13-章-分配器工程：谁付桌费) · [comptime](docs/母语编写zig-中文版.md#第-15-章-comptime：编译时也是运行时) · [互操作与发布档位](docs/母语编写zig-中文版.md#第-17-章-互操作与发布档位：怎么和世界共处) |
| 🏗️ **工程实战** | [工具链与交叉编译](docs/母语编写zig-中文版.md#第-18-章-工具链与交叉编译：一台机器给别的架构出货) · [模块设计](docs/母语编写zig-中文版.md#第-19-章-模块设计与「散在字面量」的教训) · [质量三层网](docs/母语编写zig-中文版.md#第-20-章-质量三层网：测试即工程) · [性能工程](docs/母语编写zig-中文版.md#第-22-章-性能工程：先测量，再动手) |
| 🔎 **字典速查** | [《字典篇》逐词查询](docs/母语编写zig-中文版.md#《字典篇》像查字典一样查每个中文词) · [附录 A 新手最易踩的坑](docs/母语编写zig-中文版.md#附录-a：新手最容易踩的坑) · [附录 B 术语小词典](docs/母语编写zig-中文版.md#附录-b：术语小词典) |

> 想先弄懂「为什么中文也能写程序」，读 [序](docs/母语编写zig-中文版.md#序：为什么能用中文写程序？)；想知道 zzc 内部怎么转码，读 [第 10 章 幕后](docs/母语编写zig-中文版.md#第-10-章-幕后：zzc-到底怎么把你写的中文变成-zig)。

---

## 它是怎么工作的

```
   你的 .zz 方言源码            zzc 翻译            标准 Zig             zig 编译/运行
  ┌───────────────────┐      ┌───────────┐    ┌──────────────┐     ┌──────────────┐
   常数 标准库 = 导入("std");      →   const std = @import("std");  →   zig build-exe / run
   公開 函数 主函数() !空 { ... }   →   pub fn main() !void { ... }
  └───────────────────┘      └───────────┘    └──────────────┘     └──────────────┘
```

zzc 做三件事：

1. **翻译（转码）**：按语言包把母语关键字 / 内建 / 标准库路径映射为 Zig 词法，产出的标准 Zig 与你的方言逐字节可对照。
2. **驱动工具链**：调用 `zig build-exe` / `zig test` 等完成真正的编译与运行，参数原样透传。
3. **报错回译**：把 `zig` 抛出的英文诊断**翻回母语**（可选 `--machine` 压成编辑器友好的单行机读形制），坐标回映到 `.zz` 源文件。

一个真实可跑的方言程序（就是 `zzc init` 生成的模板）：

```zz
常数 标准库 = 导入("std");

公開 函数 主函数() !空 {
    变量 数: 整数 = 10;
    数 = 数 + 1;
    标准库.调试.打印("结果是 {d}\n", .{数});
}
```

`zzc run` 的输出：

```
结果是 11
```

---

## 特性

- **多语言包**：内置中文（`zh`，简繁字形同包；`繁体.txt` 为叠加层、非独立可选包）；`# @` 头指令声明式注册，新增/改包由构建系统自动刷新。
- **外部包免重编译**：`zzc lang add <文件>` 把第三方语言包装入当前工程，运行期选包。
- **母语报错**：错误消息与提示本地化，`--machine` 输出供编辑器 / CI 逐行正则消费。
- **编辑器集成**：VS Code 扩展提供语法高亮、补全、问题匹配、LSP 悬停（含第三方库叠加包）/ 跳转定义 / 查找引用 / 同名高亮 / 重命名（含预检） / 工作区符号 / 参数提示 / 智能扩选 / 上下文补全 / 全角标点快速修复（含保存时批量）/ 文档大纲 / 代码折叠（含注释块） / 语义诊断 / 语义 token 着色 / 方言切换。
- **导出毕业**：`zzc eject` 把方言工程导出为一份可独立 `zig build` 的标准 Zig 工程。
- **双向道（跨语言共享）**：`zzc relocalize --to <包>` 把同一工程重生为另一方言词形的孪生工程——母语面出、母语面入，源树不改；产出再由正向链 `zzc check --lang <包>` 自检判绿。
- **工程化**：上万行 Zig、数百个测试、跨文件同步守卫、以「消缺工单 + 演进轮次」记账的持续治理（详见下文与 `docs/`）。

---

## 环境要求

| 依赖 | 版本 | 说明 |
| --- | --- | --- |
| [Zig](https://ziglang.org/download/) | **0.17.0** | zzc 用 `zig build` 编译，运行期也需 `zig` 在 PATH 上（转码后由它编译/运行） |

确认：

```sh
zig version   # 应输出 0.17.0
```

---

## 编译 zzc

在本仓库根目录执行（以下命令与产物均经本机 Zig 0.17 实测）：

```sh
# 调试档（默认），产物：zig-out/bin/zzc
zig build

# 发布档（更快、更小；三档任选）
zig build -Doptimize=ReleaseSafe    # 发布推荐：保留运行时安全检查
zig build -Doptimize=ReleaseFast    # 追求性能
zig build -Doptimize=ReleaseSmall   # 体积优先（如 MCU）
```

产物落在 `zig-out/bin/zzc`。验证一下：

```sh
$ zig-out/bin/zzc version
zzc 0.1.0（语言包：中文）
```

**安装到 PATH**（让 `zzc` 全局可用，也便于 VS Code 扩展拉起）：

```sh
zig build install                                  # 同上，产物在 zig-out/bin
cp zig-out/bin/zzc ~/.local/bin/                   # 或任意 PATH 目录
#  Windows 下改成拷贝 zzc.exe，例如： copy zig-out\bin\zzc.exe <PATH目录>
```

### 跑测试与守卫

```sh
zig build test
```

`zig build test` 会跑**双测试图**（`zzc_core` 模块图 + `main` 入口图）的单元/快照测试，并联动以下跨文件同步守卫（`Build Summary: 17/17 steps`）：

| 守卫步 | 作用 |
| --- | --- |
| `check-editor-syntax` | 校验 committed `zz.tmLanguage.json` 与语言包同步 |
| `check-editor-snippets` | 校验 committed `snippets/zz.json` 与语言包同步 |
| `check-ignore-coverage` | 校验仓根 `.gitignore` 覆盖我方落盘族 |
| `check-machine-matcher` | 校验编辑器对面（`package.json` / `extension.js` / `tasks.json` 等）与机读契约同源 |
| `check-toolchain-baseline` | 校验 `build.zig.zon` 与 CI 安装版本同源于工具链族真值 |

其它常用构建步：

```sh
zig build run -- check demo/hello.zz   # 用 zig build run 直接跑 zzc（-- 之后透传）
zig build gen-editor-syntax            # 从语言包重新生成语法高亮文件
zig build gen-editor-snippets          # 从语言包重新生成补全片段
zig build gen-pack-registry            # 重新生成语言包注册表（通常随包内容自动刷新，无需手跑）
```

### 发布与双推

本仓有两枚远端（`origin` 主仓 + `github` 镜像），CI 也分两面。日常同步与发版各有一条既定路径：

```sh
bash tools/push-both.sh                    # 推 main 到两枚远端，并逐仓回读 sha 对本地 HEAD
bash tools/push-both.sh 某分支              # 可选：推指定分支

git tag v0.1.0                             # 打 tag 即进入发版流程（先改版本常量，再打同名 tag）
git push origin v0.1.0                     # tag 推到任一远端都会触发 `.github/workflows/ci.yml` 的发布 job
```

- 双推脚本拒跑脏工作区，不带强制推与跳钩子的旗标；推完两仓 sha 不一致会点名是哪一侧。
- 发版 job 先跑一遍 `fmt` / `build` / `test`（发行件必须出自已验证的树），再把 tag 与 `zzc version`
  对账，随后产出三平台产物与 `zzc-dialect-<版本>.vsix` 挂到 Release 上。
- 这四件事（tag 触发、写权限、`gh` 出口、打包器路径）由 `check-machine-matcher` 的发布面针在
  本地钉住：改 CI 忘改针、或改造脚本不同动，`zig build test` 当场转红，不必推到远端才发现。

---

## 快速上手（10 秒）

```sh
zzc init myproj     # 生成母语工程骨架：myproj/src/main.zz
cd myproj
zzc run             # 翻译 → zig 编译 → 运行，打印：结果是 11
```

其它入口：

```sh
zzc check           # 只做翻译 + 词法/编译检查（母语报错，不产出可执行文件）
zzc build           # 翻译 → zig build-exe，其余参数透传给 zig
zzc test            # 翻译 → zig test
zzc eject           # 导出为可独立 zig build 的标准 Zig 工程（默认 standard/ 目录）
zzc relocalize --to ja   # 把本工程重生为 ja 方言词形的孪生工程（默认 relocalized/ja/ 目录）
```

---

## CLI 命令一览（`zzc help`）

| 命令 | 说明 |
| --- | --- |
| `zzc init <项目名>` | 创建母语工程（`src/main.zz` 模板） |
| `zzc check [文件.zz]` | 翻译 + 词法/编译检查（母语报错） |
| `zzc build [文件.zz]` | 翻译 → `zig build-exe`（其余参数透传 zig） |
| `zzc run [文件.zz]` | 编译并运行；`--` 之后传给程序 |
| `zzc test [文件.zz]` | 翻译 → `zig test` |
| `zzc eject [目录]` | 导出标准 Zig 工程（默认 `standard/`） |
| `zzc relocalize --to <包> [目录]` | 把本工程重生为另一语言包词形的孪生工程（默认 `relocalized/<包>/`；源树不改，产出自检走 `zzc check --lang <包>`） |
| `zzc lsp` | 启动 LSP 服务器（JSON-RPC over stdio：悬停 / 跳转定义 / 查找引用 / 同名高亮 / 重命名（含预检） / 工作区符号 / 参数提示 / 智能扩选 / 全角快速修复（含 source.fixAll 批量）/ 文档大纲 / 代码折叠（含注释块） / 快路诊断 / 文档同步）；配 `--lang-overlay` 时悬停可反查第三方库叠加包别名 |
| `zzc lang` | 列出当前语言包与可注册包 |
| `zzc lang add <文件>` | 装入外部语言包到本工程（可选 `--as <注册名>`；免重编译） |
| `zzc version` | 版本与当前语言包 |

| 选项 | 说明 |
| --- | --- |
| `--lang <名>` | 选择语言包（如 `zh` / `中文`；缺省为中文；不透传 zig） |
| `--lang-file <路径>` | 从外部文件加载语言包（第三方发行包、免重编译；与 `--lang` 互斥） |
| `--lang-overlay <路径>` | 把第三方库叠加层（如 `contrib/packs/httpz-中文.txt`）累积并入所选基包；所有子命令均生效，不透传 zig |
| `--machine` | 把母语报错压成单行机读形制 `路径:行:列: 种类: 消息（提示：…）`（编辑器/CI 消费；不透传 zig） |
| `--to <包>` | `zzc relocalize` 的目标语言包：`--lang` 始终是**源**包、`--to` 才是**产出**包（其它子命令上出现即拒） |

> 方言文件默认取 `src/main.zz`；错误标签与 std 错误名保持 ASCII 原样。

---

## VS Code 插件

扩展位于 [`editors/vscode/`](editors/vscode/)，包名 `zzc-dialect`（`v0.5.0`）。**零 npm 依赖**——扩展宿主（`extension.js` + `client_frames.js`）自行 spawn `zzc lsp` 并按 LSP 基座协议收发帧，无需 `npm install`。

提供：`.zz` 语法高亮、方言关键词/别名补全、`zzc check --machine` 问题匹配器、LSP 悬停（含第三方库叠加包）/ 跳转定义 / 查找引用 / 同名高亮 / 重命名（含预检） / 工作区符号 / 参数提示 / 智能扩选 / 上下文补全 / 全角快速修复（含保存时 source.fixAll）/ 文档大纲 / 代码折叠（含注释块） / 快路诊断 / 保存触发的语义级编译诊断 /  语义 token 着色 / 多方言切换。

### 前置条件

1. 已安装 [VS Code](https://code.visualstudio.com/) `1.85+`。
2. **`zzc` 可执行文件可达**——要么放进 PATH，要么在扩展设置里指定 `zzc.lspPath`（见下）。`zzc` 运行期又需 `zig`（0.17）在 PATH 上。

### 方式一 · 开发态直接运行（最简单）

```sh
# 先按上文编译 zzc，并让它进入 PATH（或稍后用 zzc.lspPath 指定）
zig build install            # 产物在 zig-out/bin/zzc

code editors/vscode          # 用 VS Code 打开扩展目录
```

打开后按 **F5**（Run Extension）启动「扩展开发宿主」窗口，在其中打开任意 `.zz` 文件即可体验高亮、补全与 LSP。

### 方式二 · 打包成 VSIX 安装

```sh
cd editors/vscode
npx @vscode/vsce package                 # 生成 zzc-dialect-0.5.0.vsix
code --install-extension zzc-dialect-0.5.0.vsix
```

> `@vscode/vsce` 是官方扩展打包工具，首次运行会经 npm 拉取（需联网）。

无 npm 环境可用仓库自带的确定性打包器：从 `package.json` 单源生成清单、固定时间戳并按名排序，同内容 sha256 可复现：

```sh
python3 tools/build-vsix.py                # → editors/vscode/zzc-dialect-0.5.0.vsix
```

打包后可用 `tools/extension-smoke.js` 做客户端 e2e（加载真实 `extension.js`、真起 `zzc lsp`，89 项断言覆盖诊断与 13 个 provider；条数由套件内 `EXPECT_CHECKS` 锚与 `check-machine-matcher` 守卫跨侧对账硬钉——少一条断言即红，绝不允许「少验而绿」）：

```sh
node tools/extension-smoke.js
ZZC_EXT_DIR=<扩展安装目录> node tools/extension-smoke.js   # 对已安装副本复测
```

### 扩展设置

| 设置项 | 说明 |
| --- | --- |
| `zzc.lspPath` | 供 `zzc lsp` 使用的 `zzc` 可执行文件路径；留空表示用 PATH 上的 `zzc` |
| `zzc.lang` | 方言包名（同 `zzc --lang`，如 `zh` 或第三方包名）；留空 = 内置默认包（中文，含繁体字形）。修改后自动重启语言服务器 |
| `zzc.langOverlay` | 第三方库叠加层文件路径（同 `zzc --lang-overlay`，如 `contrib/packs/httpz-中文.txt`；建议绝对路径）；留空 = 不叠加。修改后自动重启语言服务器 |

### 把 `zzc check` 接成构建任务（可选）

[`editors/vscode/examples/tasks.json`](editors/vscode/examples/tasks.json) 演示将 `zzc check --machine` 设为默认构建任务，配合 `zzc-machine` 问题匹配器把母语报错自动填进 Problems 面板：

```jsonc
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "zzc check",
      "type": "shell",
      "command": "zzc",
      "args": ["check", "--machine"],
      "group": { "kind": "build", "isDefault": true },
      "problemMatcher": "$zzc-machine"
    }
  ]
}
```

更多细节见扩展自带说明 [`editors/vscode/README.md`](editors/vscode/README.md)。

---

## 仓库结构

```
src/                编译器与工具链（Zig）
  main.zig          CLI 入口与命令分派
  root.zig          zzc_core 模块汇总（供测试与嵌入）
  transpiler/       方言 → 标准 Zig 转码（lexer / translate / mangle / column_map）
  lang/             语言包与注册表（packs/ 内置中文与繁体叠加层、pack_discover 发现内核、userpack 外部包）
  diag/             报错回译与母语诊断（含全角检测、纯母语过滤）
  check/            五枚跨文件同步守卫的驱动
  editor/           编辑器资产生成器（tmLanguage / snippets / LSP 配置）
  lsp/              zzc lsp 语言服务器（JSON-RPC over stdio）
editors/vscode/     VS Code 扩展（零依赖宿主 + 客户端帧层）
docs/               中文教程《母语编写 Zig》与方案书 / 关键字对照表 / 消缺台账等
tools/              e2e 演示校验脚本、双推助手与 fixture
demo/               可直接试的方言示例（hello / multi / nested / errors / fullwidth ...）
build.zig           构建脚本（编译 + 测试 + 守卫 + 资产生成步）
```

---

## 延伸阅读

- 中文教程 / 参考书：[`docs/母语编写zig-中文版.md`](docs/母语编写zig-中文版.md)（零基础到工程实战，含可点击目录）
- 语言包写法与扩展：[`docs/contributing-lang-pack.md`](docs/contributing-lang-pack.md)
- 关键字对照表：[`docs/关键字对照表.md`](docs/关键字对照表.md)
- 变更历史：[`CHANGELOG.md`](CHANGELOG.md)　·　消缺治理记账：[`docs/消缺台账.md`](docs/消缺台账.md)
