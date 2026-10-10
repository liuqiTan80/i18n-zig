//! zzc_core 模块门面：暴露翻译引擎与报错回译，供测试与第三方嵌入。
pub const lexer = @import("transpiler/lexer.zig");
pub const translate = @import("transpiler/translate.zig");
pub const Mangle = @import("transpiler/mangle.zig");
pub const ColumnMap = @import("transpiler/column_map.zig");
pub const Pack = @import("lang/pack.zig");
pub const fullwidth = @import("diag/fullwidth.zig");
pub const diag = @import("diag/translate.zig");
pub const cli = @import("cli/args.zig");

pub const zh_pack_bytes = @embedFile("lang/packs/中文.txt");

test {
    _ = lexer;
    _ = translate;
    _ = Mangle;
    _ = ColumnMap;
    _ = Pack;
    _ = fullwidth;
    _ = diag;
    _ = cli;
}
