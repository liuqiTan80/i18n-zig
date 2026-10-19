//! tmLanguage 生成工具（第 154 轮）：读取语言包、生成 editors/vscode/syntaxes/zz.tmLanguage.json。
//! 用法：gen-tmlang emit [输出路径]  |  gen-tmlang check [文件路径] [包路径]
//!   emit = 生成并写入（默认路径 editors/vscode/syntaxes/zz.tmLanguage.json）
//!   check = 生成并与磁盘文件比对，不同则退出码 1（CI 守卫）

const std = @import("std");
const Io = std.Io;
const zzc = @import("zzc_core");
const tmlang = zzc.tmlang;
const lang_id = zzc.lang_id; // 第 215 轮 D83：资产落点由语言标识族真值派生
const Pack = zzc.Pack;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(gpa);

    if (args.len < 2) {
        std.debug.print("用法: gen-tmlang <emit|check> [路径]\n", .{});
        std.process.exit(1);
    }

    const mode = args[1];
    const default_out = lang_id.grammar_emit_path; // 第 215 轮 D83：与清单 `grammars[].path` 同源派生（分道即装完插件寻不到 grammar）
    const out_path = if (args.len >= 3) args[2] else default_out;

    // 读取语言包。第 228 轮 D96：check 模式下包路径由 `build.zig` 以 `addFileArg` 作
    // 第三参传入（声明为文件依赖·改包即重跑守卫），不再固定 cwd 相对读；
    // emit 模式（手工调用）缺省仍取仓根包。
    const pack_path = if (args.len >= 4) args[3] else zzc.paths.builtin_pack_cwd_rel; // 第 238 轮 D106：emit 缺省包路径由 hub 单源派生
    const pack_bytes = std.Io.Dir.cwd().readFileAlloc(io, pack_path, gpa, .unlimited) catch |e| {
        std.debug.print("无法读取语言包 {s}（{s}）\n", .{ pack_path, @errorName(e) });
        std.process.exit(1);
    };
    defer gpa.free(pack_bytes);

    var lang = try Pack.parse(gpa, pack_bytes);
    defer lang.deinit();

    // 生成 tmLanguage JSON。
    const generated = try tmlang.generate(gpa, lang);
    defer gpa.free(generated);

    if (std.mem.eql(u8, mode, "emit")) {
        // 确保输出目录存在并写入。
        const dir = std.Io.Dir.cwd();
        if (std.fs.path.dirname(out_path)) |parent| {
            try dir.createDirPath(io, parent);
        }
        var f = try dir.createFile(io, out_path, .{});
        defer f.close(io);
        var buf: [4096]u8 = undefined;
        var w = Io.File.Writer.init(f, io, &buf);
        try w.interface.writeAll(generated);
        try w.interface.flush();
        std.debug.print("已生成 {s}（{d} 字节）\n", .{ out_path, generated.len });
    } else if (std.mem.eql(u8, mode, "check")) {
        const existing = std.Io.Dir.cwd().readFileAlloc(io, out_path, gpa, .unlimited) catch |e| {
            std.debug.print("无法读取 {s}（{s}）——请先运行 gen-tmlang emit\n", .{ out_path, @errorName(e) });
            std.process.exit(1);
        };
        defer gpa.free(existing);
        if (std.mem.eql(u8, existing, generated)) {
            std.debug.print("OK: {s} 已是最新\n", .{out_path});
        } else {
            std.debug.print("FAIL: {s} 与语言包不一致，请重新 gen-tmlang emit\n", .{out_path});
            std.process.exit(1);
        }
    } else {
        std.debug.print("未知模式: {s}（须 emit 或 check）\n", .{mode});
        std.process.exit(1);
    }
}
