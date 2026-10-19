//! zzc_core 模块门面：暴露翻译引擎与报错回译，供测试与第三方嵌入。
pub const lexer = @import("transpiler/lexer.zig");
pub const translate = @import("transpiler/translate.zig");
pub const Mangle = @import("transpiler/mangle.zig");
pub const ColumnMap = @import("transpiler/column_map.zig");
pub const Pack = @import("lang/pack.zig");
pub const registry = @import("lang/registry.zig");
pub const userpack = @import("lang/userpack.zig");
pub const fullwidth = @import("diag/fullwidth.zig");
pub const diag = @import("diag/translate.zig");
pub const kind = @import("diag/kind.zig"); // 第 208 轮 D76：机读 kind 词汇单一真值 hub
pub const cli = @import("cli/args.zig");
pub const file_io = @import("file_io.zig");
pub const tmlang = @import("editor/tmlang.zig");
pub const snippets = @import("editor/snippets.zig");
pub const lsp_jsonrpc = @import("lsp/jsonrpc.zig");
pub const lsp_server = @import("lsp/server.zig");
pub const paths = @import("zzc_paths.zig");
pub const machine = @import("machine_contract.zig");
pub const lsp_legend = @import("lsp/server.zig"); // 第 214 轮 D82：语义 token 图例单一真值（守卫步据此对账 extension.js 对面）
pub const lang_id = @import("editor/lang_identity.zig"); // 第 215 轮 D83：编辑器语言标识族单一真值（守卫步据此对账清单/客户端/示例三面）
pub const lsp_cfg = @import("editor/lsp_config.zig"); // 第 216 轮 D84：LSP 客户端接线族单一真值（守卫步据此对账清单/客户端两面）

pub const zh_pack_bytes = @embedFile(paths.builtin_pack_embed_src); // 第 238 轮 D106：内置默认包文件名由 hub 单源派生（旧硬编 `lang/packs/中文.txt`）

test "第 238 轮 T1 内置默认包一致性锚：按名 embed 的字节 == 按内容 `# @default` 发现的默认包字节" {
    // 这是 D106 的牙：旧形制下 `zh_pack_bytes`（按文件名 embed）导出后零消费、与
    // `registry.defaultEntry().bytes`（按包内 `# @default` 内容指令发现）无任何交叉——
    // t2 探针 P1 实锤将本 embed 目标改 `繁体.txt` 而 fresh 615/615 全绿（静默失联）。
    // 本锚坐实两个出口的默认包字节逐字节相同：一旦移动 `# @default` 或换名，立即转红。
    const std = @import("std");
    std.testing.expectEqualStrings(zh_pack_bytes, registry.defaultEntry().bytes) catch |e| {
        std.debug.print("zh_pack_bytes 与 registry.defaultEntry() 分道（内置默认包名↔内容失联）\\n", .{});
        return e;
    };
}

test {
    _ = lexer;
    _ = translate;
    _ = Mangle;
    _ = ColumnMap;
    _ = Pack;
    _ = registry;
    _ = userpack;
    _ = fullwidth;
    _ = diag;
    _ = kind;
    _ = cli;
    _ = file_io;
    _ = tmlang;
    _ = snippets;
    _ = lsp_jsonrpc;
    _ = lsp_server;
    _ = paths;
    _ = machine;
    _ = lang_id;
    _ = lsp_cfg;
}
