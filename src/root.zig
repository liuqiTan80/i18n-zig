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

pub const zh_pack_bytes = @embedFile("lang/packs/中文.txt");

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
}
