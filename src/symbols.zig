//! 符号表持久化

const std = @import("std");
const Mangle = @import("transpiler/mangle.zig");

/// 恢复历史符号表
pub fn loadSymbols(table: *Mangle) void {
    const bytes = std.fs.cwd().readFileAlloc(
        std.heap.page_allocator,
        ".zzc/symbols.txt",
        1024 * 1024 // 1MB 上限
    ) catch return;
    defer std.heap.page_allocator.free(bytes);

    table.parseSymbolText(bytes);
}

/// 保存符号表
pub fn saveSymbols(table: Mangle) void {
    var out = std.ArrayList(u8).init(std.heap.page_allocator);
    defer out.deinit();

    for (table.symbols.items) |s| {
        out.appendSlice(std.heap.page_allocator, s.native) catch return;
        out.appendSlice(std.heap.page_allocator, " = ") catch return;
        out.appendSlice(std.heap.page_allocator, s.ascii) catch return;
        out.append(std.heap.page_allocator, '\n') catch return;
    }

    std.fs.cwd().writeFile(".zzc/symbols.txt", out.items) catch |e| {
        std.debug.print("警告：保存符号表失败：{s}\n", .{@errorName(e)});
    };
}