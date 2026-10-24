//! VSIX（OPC/zip）**元数据**读取与打包面判据单一真值（第 292 轮 D151）。
//!
//! 为何立此模块：`editors/vscode/*.vsix` 是「装进宿主的那一份」，而它被 `.gitignore` 的
//! `*.vsix` 排除（不入版本库）、由 `tools/build-vsix.py` 离线打包。此前**全部门禁都不读它**——
//! 292 轮探针实锤：把 0.5.0 包整体换成 0.4.0 的字节（缺 D149 客户端 kind 换算）后
//! `zig build test`／`check-machine-matcher`／客户端 e2e 三门禁皆一字不变，而按 README／
//! CHANGELOG 的 `--install-extension` 指引装载的本机包已装到旧码。本模块把「包内每个成员
//! 须与盘上源逐字节同源」这条判据的**读侧**（zip 中央目录布局与 CRC-32 真值）收成单源，
//! 由 `check-machine-matcher` 只做 I/O 地调用（同 203/210/214 轮「判据入 hub、守卫只做 I/O」形制）。
//!
//! 只读中央目录（central directory）里的**元数据**：文件名／CRC-32／未压尺寸——不解压、
//! 不依赖 `std.compress.flate`（本项目的打包器与真 `vsce` 都用 deflate，比对哈希即可判同源）。
//! 布局常量取自 ZIP APPNOTE 中央目录头（46 字节定长 + 名/附加/注三段变长）。

const std = @import("std");

/// 打包器写入包内的根前缀（`tools/build-vsix.py` 逐成员写 `"extension/" + rel`）——
/// 这是**跨语言的一处手抄**：python 写侧与本 Zig 读侧必须同形，否则前缀落空即一条不核。
pub const entry_prefix: []const u8 = "extension/";

/// 包内应核成员枚数下界（当前扩展文件树：`extension.js`／`client_frames.js`／`package.json`／
/// `language-configuration.json`／`README.md`／`examples/tasks.json`／`snippets/zz.json`／
/// `syntaxes/zz.tmLanguage.json`）。须**手设独立**：不可从包内或文件树程序化抽取，否则
/// 成员被吞时锚随其同漂成空转伪钉（同 240 轮 pack 护栏下限判例）。
pub const member_floor: usize = 8;

/// 打包器与 `.gitignore` 落盘族共用的排除后缀（包体自身不入包，否则自嵌）。
pub const skip_suffix: []const u8 = ".vsix";

// —— ZIP 布局真值（APPNOTE 4.3.6 中央目录头 / 4.3.5 结束记录）——
pub const eocd_sig: u32 = 0x0605_4b50; // "PK\x05\x06"
pub const central_sig: u32 = 0x0201_4b50; // "PK\x01\x02"
pub const eocd_len: usize = 22; // 定长部分（不含变长注释）
pub const eocd_total: usize = 10; // u16：中央目录条目总数
pub const eocd_dir_size: usize = 12; // u32：中央目录字节长
pub const eocd_dir_off: usize = 16; // u32：中央目录起始偏移
pub const central_len: usize = 46; // 定长部分
pub const c_crc: usize = 16; // u32：未压内容的 CRC-32
pub const c_size: usize = 24; // u32：未压尺寸
pub const c_name_len: usize = 28; // u16
pub const c_extra_len: usize = 30; // u16
pub const c_comment_len: usize = 32; // u16
pub const c_name: usize = 46; // 变长名段起点
/// EOCD 回溯窗口：注释段最长 65535 字节（超出即认作不是 zip 尾部）。
pub const eocd_window: usize = 65535 + eocd_len;

pub const Error = error{ BadZip, NoCentralDir, Truncated };

/// 一面对账针的形状（同 `lang_identity.FaceCheck`／`jsonrpc.FaceCheck` 形制；`checkFace` 以
/// `@hasField` 兼容，故本模块不反向依赖 lsp 族）。
pub const FaceCheck = struct {
    needle: []const u8,
    why: []const u8,
    occ: usize = 1,
};

/// 对面·`tools/build-vsix.py` 打包器命名面（守卫对面二十九）。本模块与 python 打包器是
/// **跨语言的两处手抄**：包名前缀形、包内根前缀、排除后缀各一份。此前皆无锚——292 轮探针实锤
/// 「改打包器命名形 → 守卫按新形组包名却找不到包、而目录里也无别的包 → 落 NOTE 跳过文案，
/// 产物对账整条防线静默消失」。三枚 needle 的值段全由上面三枚 hub 常量 comptime 派生，
/// 一侧漂形即分道转锚（判据入 hub、守卫只做 I/O）。
pub const pack_face = [_]FaceCheck{
    .{ .needle = "-{pkg['version']}" ++ skip_suffix ++ "\")", .why = "打包器落盘文件名的骨架须等于「<name>-<version>」拼 hub `skip_suffix`——改命名形而守卫侧常量不随动，守卫就按旧名找不到包、若目录亦无旧包则整条产物对账静默停摆（第 292 轮 D151）" },
    .{ .needle = "\"" ++ entry_prefix ++ "\" + rel", .why = "包内根前缀的写入形须等于 hub `entry_prefix`——漂即守卫侧 `diskRel` 一条也不核（成员计数落 0 虽会红，但改形不改成 0 时是静默漏核）（第 292 轮 D151）" },
    .{ .needle = "SKIP_SUFFIXES = (\"" ++ skip_suffix ++ "\"", .why = "排除后缀的写侧首员须等于 hub `skip_suffix`（包体自嵌防线）——与 `.gitignore` 的 `*.vsix` 落盘族同源，漂即打包器把旧包吞进新包（第 292 轮 D151）" },
};

/// 产物包名唯一构造（第 296 轮 D155）：`<name>-<version>` 拼 `skip_suffix`——守卫期望包名
/// （对面二十八 auditVsix）与 README 指路面（对面三十二）共用同一变换，组名形制不再在
/// 守卫内另写第二份（旧形制 auditVsix 内联 allocPrint，与打包器 py 侧、README 侧皆只靠巧合对齐）。
pub fn vsixNameFor(alloc: std.mem.Allocator, name: []const u8, version: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}-{s}" ++ skip_suffix, .{ name, version });
}

/// README 是否以全角括号反引号形注记当前扩展版本（第 296 轮 D155·对面三十二扩展臂）：
/// 真值是 `package.json` 的 `version`（打包器/安装目录皆据它），README 手抄的「（`v<version>`）」
/// 是唯一对外宣称形——一侧改代另一侧不随即分道（t2 探针 P5 实锤独漂 v0.5.0→v0.4.0 三门禁零信号）。
pub fn readmeDeclaresExtVersion(readme: []const u8, version: []const u8) bool {
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "（`v{s}`）", .{version}) catch return false; // 超界即不命中：守卫报红而非静默放过
    return std.mem.indexOf(u8, readme, needle) != null;
}

/// README 是否提到当前代产物全名（第 296 轮 D155）：安装指引/打包注释共三处手抄
/// `zzc-dialect-<version>.vsix`，形串由 `vsixNameFor` 单源派生——改代而文档不随即指路指向不存在的包。
pub fn readmeDeclaresVsixName(readme: []const u8, name: []const u8, version: []const u8) bool {
    var buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "{s}-{s}{s}", .{ name, version, skip_suffix }) catch return false; // 同上：超界报红不静默
    return std.mem.indexOf(u8, readme, needle) != null;
}

pub const Entry = struct {
    name: []const u8,
    crc: u32,
    size: u32,

    /// 去掉包内根前缀后的盘上相对路径；非本族成员（如 `[Content_Types].xml`——由打包器
    /// 依 `package.json` 现生成，盘上无同名文件）返 null，守卫据此不核。
    pub fn diskRel(self: Entry) ?[]const u8 {
        if (self.name.len < entry_prefix.len) return null;
        if (!std.mem.eql(u8, self.name[0..entry_prefix.len], entry_prefix)) return null;
        return self.name[entry_prefix.len..];
    }
};

fn readU16(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn readU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

/// 包尾的结束记录（EOCD）起点；找不到即非 zip（或尾部被截）。自尾向前扫，窗口受
/// `eocd_window` 限（注释段上限），不做全文件暴力搜索。
pub fn eocdOffset(bytes: []const u8) ?usize {
    if (bytes.len < eocd_len) return null;
    const lo = bytes.len - @min(bytes.len, eocd_window); // 回溯窗口下界
    var p: usize = bytes.len - eocd_len + 1; // 半开区间上界
    while (p > lo) {
        p -= 1;
        if (readU32(bytes, p) == eocd_sig) return p;
    }
    return null;
}

/// 中央目录零分配迭代器：`open` 定位并校验记数，`next` 逐条解头。
pub const Dir = struct {
    bytes: []const u8,
    pos: usize,
    left: usize,

    pub fn open(bytes: []const u8) Error!?Dir {
        const e = eocdOffset(bytes) orelse return error.NoCentralDir;
        const count = readU16(bytes, e + eocd_total);
        const off = readU32(bytes, e + eocd_dir_off);
        const size = readU32(bytes, e + eocd_dir_size);
        if (count == 0) return null; // 空包：无成员可对账（守卫据此判「未打包」）
        if (off + size > bytes.len) return error.Truncated;
        return .{ .bytes = bytes, .pos = off, .left = count };
    }

    pub fn next(self: *Dir) Error!?Entry {
        if (self.left == 0) return null;
        const b = self.bytes;
        const h = self.pos;
        if (h + central_len > b.len) return error.Truncated;
        if (readU32(b, h) != central_sig) return error.BadZip;
        const nl = readU16(b, h + c_name_len);
        const el = readU16(b, h + c_extra_len);
        const cl = readU16(b, h + c_comment_len);
        const total = central_len + @as(usize, nl) + el + cl;
        if (h + total > b.len) return error.Truncated;
        const item = Entry{
            .name = b[h + c_name .. h + c_name + nl],
            .crc = readU32(b, h + c_crc),
            .size = readU32(b, h + c_size),
        };
        self.pos = h + total;
        self.left -= 1;
        return item;
    }
};

/// 未压内容的 CRC-32（ZIP 用的 CRC-32/ISO-HDLC：标准检验值 `"123456789"` → `0xCBF43926`，
/// 由 292 T0 以该外部真值独立钉住，不取自打包器）。
pub fn crcOf(data: []const u8) u32 {
    return std.hash.Crc32.hash(data);
}

// ─── 292 T0（第 292 轮 · D151）：zip 元数据读侧判据 ──────────────────────────

test "292 T0 vsix：布局常量、CRC 标准检验值、中央目录正反漂形与包内前缀判据" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // A1：CRC-32/ISO-HDLC 的标准检验值（外部真值，不取自打包器）——漂实现即此钉红。
    try std.testing.expectEqual(@as(u32, 0xCBF4_3926), crcOf("123456789"));
    try std.testing.expectEqual(@as(u32, 0), crcOf(""));
    try std.testing.expectEqual(@as(u32, 0x3610_A686), crcOf("hello"));

    // A2：正形——两条成员逐条解出，名/crc/尺寸俱对；仅 `extension/` 族入对账。
    const names = [_][]const u8{ "extension/extension.js", "[Content_Types].xml" };
    const crcs = [_]u32{ 0x1111_1111, 0x2222_2222 };
    const sizes = [_]u32{ 4096, 620 };
    const blob = try synth(gpa, &names, &crcs, &sizes);
    var dir = (try Dir.open(blob)).?;
    var got: usize = 0;
    var prefixed: usize = 0;
    while (try dir.next()) |e| {
        try std.testing.expectEqual(crcs[got], e.crc);
        try std.testing.expectEqual(sizes[got], e.size);
        try std.testing.expectEqualStrings(names[got], e.name);
        if (e.diskRel()) |rel| {
            try std.testing.expectEqualStrings("extension.js", rel);
            prefixed += 1;
        } else {
            try std.testing.expectEqualStrings("[Content_Types].xml", e.name);
        }
        got += 1;
    }
    try std.testing.expectEqual(names.len, got);
    try std.testing.expectEqual(@as(usize, 1), prefixed);

    // A3：漂形一——EOCD 签名被改即认作非 zip（守卫据此不会误当空包放行）。
    const e = (eocdOffset(blob)).?;
    try std.testing.expectEqual(blob.len - eocd_len, e); // 无注释段：EOCD 恰在尾
    {
        const t = try dupe(gpa, blob);
        t[e + 3] = 7;
        try std.testing.expectError(error.NoCentralDir, Dir.open(t));
    }
    // A3b：漂形二——条目记数漂 0 → open 返 null（与「未打包」同侧，守卫须显式文案不得静默）。
    {
        const t = try dupe(gpa, blob);
        std.mem.writeInt(u16, t[e + eocd_total ..][0..2], 0, .little);
        try std.testing.expectEqual(@as(?Dir, null), try Dir.open(t));
    }
    // A3c：漂形三——中央目录签名漂 → 首条即 BadZip（不得把任意 46 字节当条目吞下）。
    {
        const central = readU32(blob, e + eocd_dir_off);
        const t = try dupe(gpa, blob);
        t[central + 3] = 9;
        var it = (try Dir.open(t)).?;
        try std.testing.expectError(error.BadZip, it.next());
    }
    // A4：截断形——名段长度越界即 Truncated（不得读到别处内存）。
    {
        const central = readU32(blob, e + eocd_dir_off);
        const t = try dupe(gpa, blob);
        std.mem.writeInt(u16, t[central + c_name_len ..][0..2], 0xFFFF, .little);
        var it = (try Dir.open(t)).?;
        try std.testing.expectError(error.Truncated, it.next());
    }
    // A4b：目录起点越界即 Truncated（尾部被切的半截包不可静默通过）。
    {
        const t = try dupe(gpa, blob);
        std.mem.writeInt(u32, t[e + eocd_dir_off ..][0..4], @intCast(blob.len - 8), .little);
        try std.testing.expectError(error.Truncated, Dir.open(t));
    }
    // A5：hub 判据值钉——前缀/排除后缀/成员下限（下限须手设独立，漂数即此钉红）。
    try std.testing.expectEqualStrings("extension/", entry_prefix);
    try std.testing.expectEqualStrings(".vsix", skip_suffix);
    try std.testing.expectEqual(@as(usize, 8), member_floor);
    // A6：短名与异族名皆不落对账族（防把 `[Content_Types].xml`／`extension` 本体误核）。
    try std.testing.expectEqual(@as(?[]const u8, null), (Entry{ .name = "ex", .crc = 0, .size = 0 }).diskRel());
    try std.testing.expectEqual(@as(?[]const u8, null), (Entry{ .name = "extension", .crc = 0, .size = 0 }).diskRel());
    try std.testing.expectEqualStrings("a/b.zz", (Entry{ .name = "extension/a/b.zz", .crc = 0, .size = 0 }).diskRel().?);

    // A7：对面二十九——打包器 py 实文三枚针脚的值段皆由 hub 常量派生，正/漂两形对拍。
    try std.testing.expectEqual(@as(usize, 3), pack_face.len);
    try std.testing.expect(std.mem.indexOf(u8, pack_face[0].needle, skip_suffix) != null);
    try std.testing.expect(std.mem.indexOf(u8, pack_face[1].needle, entry_prefix) != null);
    const py_ok = "    target = os.path.join(out_dir, f\"{pkg['name']}-{pkg['version']}.vsix\")\n" ++
        "        add(zf, \"extension/\" + rel, f.read())\n" ++
        "SKIP_SUFFIXES = (\".vsix\", \".vsixmanifest\")\n";
    inline for (pack_face) |c| try std.testing.expect(std.mem.indexOf(u8, py_ok, c.needle) != null);
    // 漂形：命名形加后缀／前缀族改形／排除后缀改义——三枚针脚分别落空。
    const py_drift = "    target = os.path.join(out_dir, f\"{pkg['name']}-{pkg['version']}-win32.vsix\")\n" ++
        "        add(zf, \"ext/\" + rel, f.read())\n" ++
        "SKIP_SUFFIXES = (\".zip\", \".vsixmanifest\")\n";
    inline for (pack_face) |c| try std.testing.expect(std.mem.indexOf(u8, py_drift, c.needle) == null);
}

test "第 296 轮 T0 README 扩展版号族：vsixNameFor 构造钉／两枚 readmeDeclares 正反小样（对面三十二扩展臂·D155）" {
    // A1 包名构造钉（独立字面量、不复用常量）：与打包器 py 侧/README 指路面同形的唯一变换。
    const gpa = std.testing.allocator;
    const vname = try vsixNameFor(gpa, "zzc-dialect", "0.5.0");
    defer gpa.free(vname);
    try std.testing.expectEqualStrings("zzc-dialect-0.5.0.vsix", vname);
    // A2 扩展版号注记形正反例：全角括号反引号形命中；半角形／缺 v 前缀／异代一律不命中
    //    ——判据只认 README 实用那一形，改形即分道（非子串放过）。
    const rd = "包名 `zzc-dialect`（`v0.5.0`）。另提 (v0.5.0) 与 `0.5.0` 异形";
    try std.testing.expect(readmeDeclaresExtVersion(rd, "0.5.0"));
    try std.testing.expect(!readmeDeclaresExtVersion(rd, "0.5.1")); // 改代不随动即红
    try std.testing.expect(!readmeDeclaresExtVersion("", "0.5.0")); // 空文档
    try std.testing.expect(!readmeDeclaresExtVersion("半角 (v0.5.0) 形", "0.5.0")); // 改形不算命中
    // A3 产物全名指路正反例：形串与 vsixNameFor 同骨；旧代名不命中新判据。
    try std.testing.expect(readmeDeclaresVsixName("跑 `code --install-extension zzc-dialect-0.5.0.vsix`", "zzc-dialect", "0.5.0"));
    try std.testing.expect(!readmeDeclaresVsixName("只提 zzc-dialect-0.4.0.vsix", "zzc-dialect", "0.5.0"));
    try std.testing.expect(!readmeDeclaresVsixName("", "zzc-dialect", "0.5.0"));
}

/// 测试小样复制器（盘上不落文件，纯内存）。
fn dupe(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    const t = try alloc.alloc(u8, src.len);
    @memcpy(t, src);
    return t;
}

/// 按 APPNOTE 中央目录布局拼 n 条元数据项 + EOCD（条目本体不入样，只核元数据；
/// 压缩尺寸与未压尺寸同值——读侧只取 crc/size/名长，此形不影响判据）。
fn synth(
    alloc: std.mem.Allocator,
    names: []const []const u8,
    crcs: []const u32,
    sizes: []const u32,
) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    for (names, crcs, sizes) |nm, crc, size| {
        try b.appendSlice(alloc, "PK\x01\x02");
        try b.appendNTimes(alloc, 0, 12); // 版本(4)/标志(8)/方法(10)/时间(12)/日期(14)——共 12 字节，crc 落 16
        try u32To(&b, alloc, crc); // 16 CRC-32
        try u32To(&b, alloc, size); // 20 压缩尺寸
        try u32To(&b, alloc, size); // 24 未压尺寸
        try u16To(&b, alloc, @intCast(nm.len)); // 28 名长
        try u16To(&b, alloc, 0); // 30 附加长
        try u16To(&b, alloc, 0); // 32 注长
        try u16To(&b, alloc, 0); // 34 起盘号
        try u16To(&b, alloc, 0); // 36 内部属性
        try u32To(&b, alloc, 0); // 38 外部属性
        try u32To(&b, alloc, 0); // 42 本地头偏移
        try b.appendSlice(alloc, nm);
    }
    const dir_off: u32 = 0;
    const dir_size: u32 = @intCast(b.items.len);
    const total: u16 = @intCast(names.len);
    try b.appendSlice(alloc, "PK\x05\x06");
    try u16To(&b, alloc, 0); // 本盘号
    try u16To(&b, alloc, 0); // 目录起盘号
    try u16To(&b, alloc, total); // 本盘条目数
    try u16To(&b, alloc, total); // 总条目数
    try u32To(&b, alloc, dir_size); // 目录字节长
    try u32To(&b, alloc, dir_off); // 目录起始偏移
    try u16To(&b, alloc, 0); // 注长
    return b.toOwnedSlice(alloc);
}

fn u16To(b: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u16) !void {
    var b2: [2]u8 = undefined;
    std.mem.writeInt(u16, &b2, v, .little);
    try b.appendSlice(alloc, &b2);
}

fn u32To(b: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u32) !void {
    var b4: [4]u8 = undefined;
    std.mem.writeInt(u32, &b4, v, .little);
    try b.appendSlice(alloc, &b4);
}
