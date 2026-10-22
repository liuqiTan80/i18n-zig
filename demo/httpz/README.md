# demo/httpz —— httpz 第三方库母语翻译的真依赖验证工程

本目录是 `contrib/packs/httpz-中文.txt`（httpz 叠加层语言包）的**存在性证明**：把网络/服务端库
[`httpz`](https://github.com/karlseguin/http.zig) 作为**真实依赖**拉入本机编译，逐条坐实叠加层里每个
`键 = httpz.路径` 都编得过——承项目铁律「**扩展翻译须经编译器存在性验证**」，任一 API 路径写错即此处
编译红，绝不入库臆造死路径。

> 本工程**独立于 zzc 编译器本体测试图**：zzc 自身零第三方依赖，此处 `zig build` 只是存在性证据、
> 不进 CI 测图。它需要**外网 `zig fetch`** 拉 httpz，故在离线沙箱里会失败（`NO_NETWORK` 公认态，
> 与 `NO_NODE`/`NO_PWSH` 同理，属环境缺失、非代码缺陷）。

## 两阶段验证

### 阶段 1：纯 Zig 存在性钉（`check_api.zig`）

顶层类型别名 + handler 实引用（`query/param/formData/body/content_type/json/writer/arena`）+ `main`
里的 `Server(void).init/router/get/post/listen/writeMetrics`，每条待入库路径都被真实引用一次：

```sh
cd demo/httpz
zig fetch --save 'git+https://github.com/karlseguin/http.zig?ref=dev'   # 首次拉依赖（写进 build.zig.zon 的 URL+hash）
zig build                                                               # 编得过 = 所有引用路径存在
```

`build.zig.zon` 已 pin 到具体 commit + hash，`zig build` 会据此从 `zig-cache`/`zig-pkg` 命中或重新 fetch。
`zig-pkg/`（fetch 缓存）与 `.zig-cache/`、`zig-out/`、`.zzc/` 均在根 `.gitignore` 内、不入库。

### 阶段 2：方言端到端（`src/main.zz`）

用拟定母语别名写的最小可跑 HTTP 服务，经叠加层译成纯 Zig 再挂真依赖编译：

```sh
# 1) 只在 zzc 源码树根执行：把方言源译出纯 Zig（eject 仅转译，不涉 httpz）
zzc eject standard --lang-overlay contrib/packs/httpz-中文.txt

# 2) 译出的 standard/src/main.zig 里 网络服务.* → httpz.*、方法名保留 ASCII、!空 → !void。
#    把它放进挂了真 httpz 依赖的工程（本目录 build.zig.zon 即那份依赖清单）再 zig build 坐实语义正确。
```

> **边界·eject 毕业工程需手工补 httpz 依赖**：`zzc eject` 生成的 `standard/` 只含译出的 `.zig` 源码，
> 其 `build.zig.zon` **不带** httpz 依赖（eject 不知你引了哪个第三方库）。所以要复验阶段 2 时，需把
> 译出的 `main.zig` 移到本目录（或给 `standard/` 手工补上本 `build.zig.zon` 里的 httpz 依赖 + `build.zig`
> 的 `addModule("httpz")`）再 `zig build`。本 README 记录的正是这条已验证路径。

### 阶段 3：编辑器悬停（VS Code，可选）

VS Code 扩展的 `zzc.langOverlay` 设置（第 267 轮）填本包绝对路径后，扩展会自动以
`zzc lsp --lang-overlay <本包>` 重启语言服务器；于是下表别名在悬停中直接反查标准形与 `[docs]` 用法，
无需重编译、也无需改动内置语言包：

```text
网络服务.服务器  →  httpz.Server
```

命令行等价物：`zzc lsp --lang-overlay contrib/packs/httpz-中文.txt`（任意 LSP 客户端通用）。

## httpz API → 中文母语对照（叠加层 11 条，一一对应 `[docs]`）

| 中文母语 | httpz 实际路径 | 译面类型 |
|---|---|---|
| `网络服务` | `httpz` | 模块根别名 |
| `网络服务.服务器` | `httpz.Server` | 类型（按 Handler 参数化） |
| `网络服务.请求` | `httpz.Request` | 类型 |
| `网络服务.响应` | `httpz.Response` | 类型 |
| `网络服务.路由器` | `httpz.Router` | 类型 |
| `网络服务.网址` | `httpz.Url` | 类型 |
| `网络服务.配置` | `httpz.Config` | 类型 |
| `网络服务.内容类型` | `httpz.ContentType` | 枚举类型 |
| `网络服务.方法` | `httpz.Method` | 枚举类型 |
| `网络服务.协议` | `httpz.Protocol` | 枚举类型 |
| `网络服务.写指标` | `httpz.writeMetrics` | 静态函数 |

### 翻译边界（刻意保守·与标准库一致）

点分路径别名链按**贪心最长匹配**、未列段逐段回退、ASCII 成员原样透传。故只译**模块根 / 类型限定路径 /
静态函数 / 枚举类型**；挂在实例或局部变量上的**方法与字段**（`.init/.router/.get/.post/.listen/.stop/
.deinit/.query/.param/.json/.writer/.body/.content_type/.arena` 等）**保留 ASCII 透传**，绝不建裸词别名
（否则劫持同名用户变量）。见 `src/main.zz`：`网络服务.服务器(空).init(...)`、`应.json(...)`——限定名译出、
方法名仍是英文，正是这条边界。
