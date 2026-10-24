//! 母语标识符 → 稳定 ASCII 名（`z_<n>`）转码表。
//! 同一工程内同名母语标识符映射到同一 ASCII 名（跨文件一致，
//! 因此 pub 符号在模块间引用天然成立）；编号按首次出现顺序，可复现。

const std = @import("std");

pub const Mangle = @This();

pub const Symbol = struct {
    native: []const u8,
    ascii: []const u8,
    /// ascii 是否为 intern 拥有的堆分配（文件加载来的为借用，不可 free）
    owned: bool = false,
};

gpa: std.mem.Allocator,
native_to_ascii: std.StringHashMap([]const u8),
ascii_to_native: std.StringHashMap([]const u8),
symbols: std.ArrayList(Symbol),
/// 下一个可用编号：从已恢复/已分配的最大 `z_<n>` 的 n+1 起算，而非符号个数+1。
/// 后者在 .zzc/symbols.txt 非连续（手工编辑/删除行）时会与已加载的编号撞车。
next_index: usize = 1,
/// 已被用户源码里的 ASCII 标识符 `z_<n>` 占用的编号集合：intern 派新名时跳过之，
/// 避免母语名被转成与用户手写的 `z_1` 等同名而撞车（详见 reserveZInText）。
reserved: std.AutoHashMap(usize, void),
/// 第 332 轮 D191：与本表配套的词表指纹（0 = 尚未绑定／旧格式缓存）。`saveSymbols` 把它写进
/// 缓存首行、`loadSymbols` 用它对账；不符即整表作废——避免旧缓存把「当年的未知词」永久
/// 钉成标识符（translate 的 `ident_first` 让位于用户标识符），使后来补上的词表永不生效。
pack_fp: u64 = 0,

pub fn init(gpa: std.mem.Allocator) Mangle {
    return .{
        .gpa = gpa,
        .native_to_ascii = std.StringHashMap([]const u8).init(gpa),
        .ascii_to_native = std.StringHashMap([]const u8).init(gpa),
        .symbols = .empty,
        .reserved = std.AutoHashMap(usize, void).init(gpa),
    };
}

pub fn deinit(self: *Mangle) void {
    // 只释放 intern 拥有的 ASCII 名（StringHashMap.deinit 不会释放 value 字节）
    for (self.symbols.items) |s| {
        if (s.owned) self.gpa.free(s.ascii);
    }
    self.native_to_ascii.deinit();
    self.ascii_to_native.deinit();
    self.symbols.deinit(self.gpa);
    self.reserved.deinit();
}

/// 查表；不存在则分配下一个 `z_<n>` 名（跳过被用户 ASCII 标识符占用的编号）。返回键的只读视图与 ASCII 名。
pub fn intern(self: *Mangle, native: []const u8) ![]const u8 {
    if (self.native_to_ascii.get(native)) |ascii| return ascii;
    // 跳过用户已手写的 `z_<n>` 编号，防母语名 intern 成同名而撞车。
    while (self.reserved.contains(self.next_index)) self.next_index += 1;
    const n = self.next_index;
    self.next_index += 1;
    const ascii = try std.fmt.allocPrint(self.gpa, "z_{d}", .{n});
    errdefer self.gpa.free(ascii);
    try self.put(native, ascii, true);
    return ascii;
}

/// 预留一个编号 n，使后续 intern 不会派生 `z_<n>`。
/// 预留失败必须传播（台账 D16）：静默吞掉会让后续 intern 派生到被占编号、生成重复声明。
pub fn reserveNumber(self: *Mangle, n: usize) !void {
    try self.reserved.put(n, {});
}

/// 是否为标识符字节（ASCII 字母/数字/下划线）；非此类的字节（含任意 UTF-8 多字节 CJK、标点、空白）皆为词边界。
fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// 若整段恰为 `z_` + 一个或多个十进制数字，返回其数值；否则 null。
fn parseZNumber(tok: []const u8) ?usize {
    if (tok.len < 3 or tok[0] != 'z' or tok[1] != '_') return null;
    const digits = tok[2..];
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(usize, digits, 10) catch null;
}

/// 扫描源码文本，把所有独立成词的 `z_<十进制>` 标识符的编号预留下来。
/// 按标识符字符切成极大连续段再判定，天然保证词边界：`az_1`、`z_1x`、`zz_1` 均不匹配，
/// `x.z_1.y` 中的 `z_1` 匹配。对字符串/注释里偶然出现的 `z_1` 亦会预留（超集预留无害，仅多跳一个号）。
pub fn reserveZInText(self: *Mangle, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (!isIdentByte(text[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and isIdentByte(text[i])) i += 1;
        if (parseZNumber(text[start..i])) |n| try self.reserveNumber(n);
    }
}

/// 预留完成后消除“持久母语名 ↔ 用户新写 `z_N`”的跨会话撞名：
/// 上一轮只拦截新 intern（跳过 reserved），但从 .zzc/symbols.txt 恢复的历史映射（如
/// `甲 = z_1`）已写入、`intern(甲)` 命中缓存直接返回 z_1、不查 reserved。若本次用户新写 ASCII
/// `z_1`，两者仍撞。本函数把任何 ASCII 尾号落在 reserved 上的既有映射，重新安置到一个空闲编号
/// （next_index 恒大于所有已加载号且跳过 reserved，故不与其他符号撞）；只改派生态、不动用户手写的 ASCII，
/// 安置后写回 symbols.txt、后续会话沿用新号（前向稳定）。需在 reserveZInText 之后、翻译之前调用一次。
pub fn relocateReservedCollisions(self: *Mangle) !void {
    const n = self.symbols.items.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const sym = self.symbols.items[i];
        const num = trailingNumber(sym.ascii) orelse continue;
        if (!self.reserved.contains(num)) continue;
        // 与用户 ASCII 预留号相撞：重新安置到下一个未被 reserved 占用的编号。
        while (self.reserved.contains(self.next_index)) self.next_index += 1;
        const nn = self.next_index;
        self.next_index += 1;
        const new_ascii = try std.fmt.allocPrint(self.gpa, "z_{d}", .{nn});
        errdefer self.gpa.free(new_ascii);
        _ = self.native_to_ascii.remove(sym.native);
        _ = self.ascii_to_native.remove(sym.ascii);
        try self.native_to_ascii.put(sym.native, new_ascii);
        try self.ascii_to_native.put(new_ascii, sym.native);
        if (sym.owned) self.gpa.free(sym.ascii); // 文件加载来的（owned=false）为借用、不能 free
        self.symbols.items[i] = .{ .native = sym.native, .ascii = new_ascii, .owned = true };
    }
}

/// 恢复历史映射（.zzc/symbols.txt 加载），保证编号跨会话稳定。
/// 并把 next_index 推过所有已恢复的 `z_<n>`，使非连续文件中后续新符号不会撞号。
pub fn putExisting(self: *Mangle, native: []const u8, ascii: []const u8) !void {
    try self.put(native, ascii, false);
    if (trailingNumber(ascii)) |n| {
        if (n >= self.next_index) self.next_index = n + 1;
    }
}

/// 取 ASCII 名末尾一段十进制数（`z_12` -> 12）；无数字则返回 null。
fn trailingNumber(ascii: []const u8) ?usize {
    var end = ascii.len;
    while (end > 0 and std.ascii.isDigit(ascii[end - 1])) end -= 1;
    if (end == ascii.len) return null; // 结尾无数字
    return std.fmt.parseInt(usize, ascii[end..], 10) catch null;
}

fn put(self: *Mangle, native: []const u8, ascii: []const u8, owned: bool) !void {
    if (self.native_to_ascii.contains(native)) return;
    // D36（第 84 轮）：不同母语名争一个已被占用的 ASCII 编号→源头拒（旧行为：正表双双写入、
    // 两标识符转码后共享同一 z_N（生成码静默合并、语义改变零警告）、反表被后行覆盖）。
    // 手工编辑错号的 symbols.txt 可达；同号但同名（幂等重加载）已由上方 contains 提前 return 吞并。
    if (self.ascii_to_native.contains(ascii)) return error.DuplicateSymbol;
    try self.native_to_ascii.put(native, ascii);
    errdefer _ = self.native_to_ascii.remove(native);
    try self.ascii_to_native.put(ascii, native);
    errdefer _ = self.ascii_to_native.remove(ascii);
    try self.symbols.append(self.gpa, .{ .native = native, .ascii = ascii, .owned = owned });
}

/// 报错回译用：ASCII 名反查母语名。
pub fn unmangle(self: Mangle, ascii: []const u8) ?[]const u8 {
    return self.ascii_to_native.get(ascii);
}

/// 从 `.zzc/symbols.txt` 文本恢复映射：每行 `母语名 = z_N`，跳过空行/`#`注释/`[`段头/无 `=` 行/空侧；
/// 不同母语名撞同一 ASCII 编号传播 `error.DuplicateSymbol`（D36·拒两标识符静默合并，调用方须给出可操作提示）。
/// 逐条走 `putExisting`（会把 next_index 推过已恢复的最大编号）。与文件读取解耦，便于单测锁定格式契约。
pub fn parseSymbolText(self: *Mangle, text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const native = std.mem.trim(u8, line[0..eq], " ");
        const ascii = std.mem.trim(u8, line[eq + 1 ..], " ");
        if (native.len == 0 or ascii.len == 0) continue;
        // 恢复失败必须传播（台账 D16）：丢一条映射即破坏跨会话稳定、可能后续撞号。
        try self.putExisting(native, ascii);
    }
}

pub fn count(self: Mangle) usize {
    return self.symbols.items.len;
}

test "转码稳定且双向" {
    const gpa = std.testing.allocator;
    var table = init(gpa);
    defer table.deinit();

    const a1 = try table.intern("数量");
    const a2 = try table.intern("数量");
    try std.testing.expectEqualStrings(a1, a2);
    try std.testing.expectEqualStrings("z_1", a1);
    try std.testing.expectEqualStrings("数量", table.unmangle("z_1").?);
    try std.testing.expectEqual(@as(usize, 1), table.count());
}

test "非连续 symbols 加载：新符号不与已恢复的编号撞车" {
    const gpa = std.testing.allocator;
    var table = init(gpa);
    defer table.deinit();

    // 模拟 .zzc/symbols.txt 被手工编辑成非连续：只剩 `乙 = z_2`（z_1 已删）。
    try table.putExisting("乙", "z_2");
    // 新 intern 的符号必须取 z_3（而非旧的 len+1=z_2），避免与已加载的 乙 撞号。
    const a = try table.intern("甲");
    try std.testing.expectEqualStrings("z_3", a);
    // 已加载的 乙 仍为 z_2，双向映射不被破坏。
    try std.testing.expectEqualStrings("z_2", try table.intern("乙"));
    try std.testing.expectEqualStrings("乙", table.unmangle("z_2").?);
    try std.testing.expectEqualStrings("甲", table.unmangle("z_3").?);
}

test "parseSymbolText：跳过注释/空行/段头/坏行，恢复双向映射并推高 next_index 不撞号" {
    const gpa = std.testing.allocator;
    var table = init(gpa);
    defer table.deinit();
    // 混合有效行与应被忽略的行（#注释、[段头]、空行、无等号坏行）；含无空格/多空格两种写法。
    try table.parseSymbolText("# 注释行\n[符号段]\n\n模块 = z_1\n招呼=z_2\n  多余   =   z_7  \n坏行没有等号\n");
    // 3 条有效映射均恢复，双向可查；注释/段头/空行/坏行全忽略。
    try std.testing.expectEqual(@as(usize, 3), table.count());
    try std.testing.expectEqualStrings("模块", table.unmangle("z_1").?);
    try std.testing.expectEqualStrings("招呼", table.unmangle("z_2").?);
    try std.testing.expectEqualStrings("多余", table.unmangle("z_7").?);
    // next_index 必须推过已恢复的最大编号 z_7，新符号从 z_8 起，不与历史撞号。
    const fresh = try table.intern("新名字");
    try std.testing.expectEqualStrings("z_8", fresh);
}

test "reserveZInText：预留用户 ASCII z_<n> 编号，intern 跳过不撞名" {
    const gpa = std.testing.allocator;
    var table = init(gpa);
    defer table.deinit();
    // 源码里用户手写了 `z_1`、`x.z_3.y`（成员访问）两个独立词元，应预留编号 1 与 3。
    try table.reserveZInText("const z_1 = 5; var v = x.z_3.y; print(\"z_9\");");
    // 母语名不能再得到 z_1：应跳到未预留的 z_2。
    try std.testing.expectEqualStrings("z_2", try table.intern("甲"));
    // 下一个也不能是 z_3（被预留）：应跳到 z_4。
    try std.testing.expectEqualStrings("z_4", try table.intern("乙"));
}

test "reserveZInText：词边界与超集预留" {
    const gpa = std.testing.allocator;
    var table = init(gpa);
    defer table.deinit();
    // `az_1`（前接字母）、`zz_2`（多 z）、`z_3x`（后接非数字）、`z_`（无数字）均不是 z_<纯数字> 词元，不预留。
    // 但 `z_5` 应预留（即便在字符串里，超集预留无害）。
    try table.reserveZInText("az_1 zz_2 z_3x z_ z_5");
    // 前四个都不影响编号，首个 intern 应为 z_1（未被预留）。
    try std.testing.expectEqualStrings("z_1", try table.intern("甲"));
    // 直到碰编号 5 时跳过（z_5 被预留）。
    _ = try table.intern("乙"); // z_2
    _ = try table.intern("丙"); // z_3
    _ = try table.intern("丁"); // z_4
    try std.testing.expectEqualStrings("z_6", try table.intern("戊")); // 跳过 z_5
}

test "relocateReservedCollisions：持久历史映射撞上用户新写 z_N 时重新安置" {
    const gpa = std.testing.allocator;
    var table = init(gpa);
    defer table.deinit();
    // 模拟会话A恢复：symbols.txt 里 `甲 = z_1`（文件加载、owned=false），next_index 推至 2。
    try table.putExisting("甲", "z_1");
    // 会话B：用户新写 ASCII `z_1`，预留编号 1。
    try table.reserveZInText("const z_1 = 5;");
    try table.relocateReservedCollisions();
    // 甲 必须从被占的 z_1 改到空闲的 z_2（next_index 从 2 起）。
    try std.testing.expectEqualStrings("z_2", try table.intern("甲"));
    try std.testing.expectEqualStrings("甲", table.unmangle("z_2").?);
    // z_1 不再属于甲（已腾空给用户 ASCII）。
    try std.testing.expectEqual(@as(?[]const u8, null), table.unmangle("z_1"));
    // 符号总数不变（仅改派生态、未新增）。
    try std.testing.expectEqual(@as(usize, 1), table.count());
    // 新符号从 z_3 起。
    try std.testing.expectEqualStrings("z_3", try table.intern("乙"));
}

test "relocateReservedCollisions：未被撞的历史映射原样不动" {
    const gpa = std.testing.allocator;
    var table = init(gpa);
    defer table.deinit();
    // 恢复两个历史映射 z_1/z_2；本次用户只写了 z_9（与它们无关）。
    try table.putExisting("甲", "z_1");
    try table.putExisting("乙", "z_2");
    try table.reserveZInText("const v = z_9;");
    try table.relocateReservedCollisions();
    // 甲/乙 都不该被挪动。
    try std.testing.expectEqualStrings("z_1", try table.intern("甲"));
    try std.testing.expectEqualStrings("z_2", try table.intern("乙"));
}

test "D36：不同母语名撞同一 ASCII 编号源头拒——propagate error.DuplicateSymbol、不再静默合并两标识符" {
    const gpa = std.testing.allocator;
    // 手工编辑错号的 symbols.txt：甲/乙 两行同指 z_1。旧行为：正表双双写入→两标识符转码后
    // 共享 z_1（生成码静默合并、语义改变零警告），反表被后行覆盖。新行为：源头拒、传播。
    var table = init(gpa);
    defer table.deinit();
    try std.testing.expectError(error.DuplicateSymbol, table.parseSymbolText("甲 = z_1\n乙 = z_1\n"));
    // 拒绝不留半成品状态：首行合法映射仍在，撞号行未入表；后续不同名 intern 能正常派新号。
    try std.testing.expectEqual(@as(usize, 1), table.count());
    try std.testing.expectEqualStrings("z_1", try table.intern("甲"));
    try std.testing.expectEqualStrings("z_2", try table.intern("乙"));

    // 同名同值的幂等重复行（两遍加载同一映射）仍合法且被正表 early-return 吞并。
    var t2 = init(gpa);
    defer t2.deinit();
    try t2.parseSymbolText("甲 = z_1\n甲 = z_1\n");
    try std.testing.expectEqual(@as(usize, 1), t2.count());

    // putExisting 直调面同样拒撞号（不经 parseSymbolText 的调用方同受保护）。
    try std.testing.expectError(error.DuplicateSymbol, t2.putExisting("乙", "z_1"));
}

test "护栏：转码词边界/编号解析纯谓词边界形——strict 整词与 lenient 尾数语义不对称、溢出退化不崩（第 111 轮证伪落位）" {
    // 承 108/109/110 方法论：isIdentByte/parseZNumber/trailingNumber 三个纯谓词决定 reserveZInText
    // 的词边界预留（D16：扫源码把独立成词的 z_<十进制> 编号预留、防母语名 intern 撞用户手写 z_N）
    // 与 relocate/putExisting 的尾号提取（D36 撞号避让），此前仅经 reserve 系列端到端测间接触达、
    // 零直调覆盖（脚本实测测试区直调为 0）。逐例推演证伪皆安全，本测把结论钉成回归防线：
    // parseZNumber「整词严格」与 trailingNumber「尾数宽松」的语义不对称须锁定（前者用于扫任意文本、
    // 必须整段恰为 z_+数字才认，故 az_1/z_1x/zz_1 在极大标识符段上不误命中预留；后者作用于已是 z_N
    // 形的存量名、只取尾部连续数字），溢出/畸形一律退化 null 不 panic（未来改动破边界即红）。
    // 护栏测自身推演也须实跑自证（承 108 轮教训）。

    // isIdentByte：ASCII 字母/数字/下划线为标识符字节，其余（空白/标点/UTF-8 多字节）皆词边界。
    try std.testing.expect(isIdentByte('a'));
    try std.testing.expect(isIdentByte('Z'));
    try std.testing.expect(isIdentByte('0'));
    try std.testing.expect(isIdentByte('_'));
    try std.testing.expect(!isIdentByte(' '));
    try std.testing.expect(!isIdentByte('.'));
    try std.testing.expect(!isIdentByte(0xFF)); // 非 ASCII 字节（CJK 续字节等）恒判词边界

    // parseZNumber：整段须恰为 `z_` + 一或多十进制数字——前缀/后缀/缺数字一律 null（词边界严格）。
    try std.testing.expectEqual(@as(?usize, 1), parseZNumber("z_1"));
    try std.testing.expectEqual(@as(?usize, 99), parseZNumber("z_99"));
    try std.testing.expectEqual(@as(?usize, 0), parseZNumber("z_0")); // 编号 0 合法整词
    try std.testing.expectEqual(@as(?usize, null), parseZNumber("z_")); // len<3、无数字
    try std.testing.expectEqual(@as(?usize, null), parseZNumber("az_1")); // 前缀污染非整词
    try std.testing.expectEqual(@as(?usize, null), parseZNumber("z_1x")); // 后缀污染
    try std.testing.expectEqual(@as(?usize, null), parseZNumber("zz_1")); // 非 z_ 前缀
    try std.testing.expectEqual(@as(?usize, null), parseZNumber("z_99999999999999999999999999")); // 溢出退化

    // trailingNumber：只取尾部连续数字段（宽松、不校验 z_ 前缀）——与 parseZNumber 整词严格刻意不对称；
    // 结尾无数字/溢出退化 null。
    try std.testing.expectEqual(@as(?usize, 12), trailingNumber("z_12"));
    try std.testing.expectEqual(@as(?usize, 12), trailingNumber("_12")); // 只认尾数、不校前缀（对照 parseZNumber 拒此形）
    try std.testing.expectEqual(@as(?usize, 9), trailingNumber("x9"));
    try std.testing.expectEqual(@as(?usize, 2), trailingNumber("z_1_2")); // 尾段独立取数、不要求整词
    try std.testing.expectEqual(@as(?usize, null), trailingNumber("z_")); // 结尾无数字
    try std.testing.expectEqual(@as(?usize, null), trailingNumber("abc"));
    try std.testing.expectEqual(@as(?usize, null), trailingNumber("")); // 空串
    try std.testing.expectEqual(@as(?usize, null), trailingNumber("z_99999999999999999999999999")); // 溢出退化
}

// 护栏（第 121 轮证伪落位）：parseSymbolText 对 CRLF（Windows 行尾）的容错此前零测——所有既有测
// 皆纯 `\n`。此容错系 L165 `trim(u8, raw, " \t\r")` 的 `\r` 独力承担，且恰恰 load-bearing：若 `\r` 漏
// trim，ascii 得 `z_7\r` → trailingNumber 因末字节非数字返 null → next_index 不被推高 → 后续新符号撞
// 历史号（D36 同族）、且历史母语名被转成带尾 `\r` 的非法标识符泄漏进生成码。symbols.txt 支持手工
// 编辑（D36 测即防此）、Windows 记事本写 CRLF 天然可达→本测钉住 CRLF 行尾解析与编号推进不被尾部 `\r` 击穿。
test "parseSymbolText：CRLF（Windows）行尾容错——尾部 \\r 被归一、编号提取不被击穿（第 121 轮证伪落位）" {
    const gpa = std.testing.allocator;
    var table = init(gpa);
    defer table.deinit();
    // Windows 原生 .zzc/symbols.txt 用 CRLF；两条有效映射以 \\r\\n 行尾分隔。
    try table.parseSymbolText("甲 = z_1\r\n招呼 = z_7\r\n");
    try std.testing.expectEqual(@as(usize, 2), table.count());
    // 反查侧须用干净的 "z_1"/"z_7"（无尾 \\r）——若 trim 漏 \\r，表内存的是 "z_1\\r"、此处 .? 将坠 null 而红。
    try std.testing.expectEqualStrings("甲", table.unmangle("z_1").?);
    try std.testing.expectEqualStrings("招呼", table.unmangle("z_7").?);
    // next_index 必须推过 z_7（坐实 ascii 尾部无 \\r、trailingNumber 正常取到 7）→ 新符号从 z_8 起。
    try std.testing.expectEqualStrings("z_8", try table.intern("新名字"));
}
