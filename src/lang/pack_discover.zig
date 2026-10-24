//! 语言包自动发现与注册表源码生成（R9续②，第 54 轮；第 260 轮 D126 自 build.zig 下沉为单源真值）。
//!
//! 为什么要独立成模块：旧形制下「扫 packs 目录 → 解析 `# @` 头指令 → 把包字节内联成
//! `&[_]u8{...}` 源码」全部逻辑**内联在 build.zig 里、于 build.zig 求值期执行**。而 build.zig
//! 的求值结果被构建缓存，且求值期用命令式 `readFileAlloc` 读 .txt **不向构建系统声明文件依赖**
//! ——故仅改 .txt 包内容不会触发求值重跑，生成的 `pack_registry.zig` 仍嵌旧字节（台账 D45/R9f 假绿形）。
//! 根治之道是把生成从「求值期内联」迁到「独立 run 步」：run 步以 `addFileArg` 声明每个包文件为
//! 输入依赖，包内容一改即 cache miss、重跑本生成器、产出新鲜字节。本模块即那台生成器的**纯逻辑内核**，
//! 由构建期驱动程序（`src/gen/pack_registry_main.zig`）调用；单源收编使「生成规则」只此一份，
//! 未来若加守卫对盘字节亦复用此处。
//!
//! 本模块刻意只依赖 `std`（不碰 `zzc_paths`、不 `@import("pack_registry")`），既可被 build 工具
//! 复用，也可编入 zzc_core 测试图供字节保真测（见文件尾）。配置错误经 `std.process.fatal` 面向
//! 包作者报母语可操作提示（与旧 build.zig 内联时同一诊断口径）。

const std = @import("std");
const Allocator = std.mem.Allocator;

/// 一份包文件：文件名（basename，用于确定性排序与错误指向）+ 原始字节。
pub const PackFile = struct {
    name: []const u8,
    bytes: []const u8,
};

/// 生成 `pack_registry` 模块的完整 Zig 源码。`files` 为 packs 目录下全部 `.txt` 包（顺序任意，
/// 内部按文件名字典序归一，故生成确定性）。返回串归调用方（`gpa` 拥有）。
pub fn generateRegistrySource(gpa: Allocator, files: []const PackFile) ![]const u8 {
    if (files.len == 0) std.process.fatal("语言包目录下没有 .txt 包", .{});

    // 1) 按文件名字典序排序（生成确定性）。以索引置换，不改输入切片。
    const order = try gpa.alloc(usize, files.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, files, struct {
        fn lt(fs: []const PackFile, a: usize, b: usize) bool {
            return std.mem.lessThan(u8, fs[a].name, fs[b].name);
        }
    }.lt);

    // 2) 解析每份包头部 `# @` 指令（与排序后的 names 同序，故 dirs 下标序即字典序）。
    var dirs: std.ArrayList(Directive) = .empty;
    for (order) |i| {
        const f = files[i];
        dirs.append(gpa, parseDirectives(gpa, f.name, f.bytes)) catch std.process.fatal("OOM", .{});
    }

    // 3) 收集基包（有 key 且非 overlay），校验 code/default，检查补充层的 overlay-of 指向。
    var base_idx: std.ArrayList(usize) = .empty;
    var default_seen: usize = 0;
    for (dirs.items, 0..) |d, i| {
        if (!d.has_key or d.overlay_of.len != 0) continue;
        if (d.code.len == 0) std.process.fatal("基包 {s} 缺 `# @code` 头指令", .{d.file});
        if (d.is_default) default_seen += 1;
        base_idx.append(gpa, i) catch std.process.fatal("OOM", .{});
    }
    if (base_idx.items.len == 0) std.process.fatal("未发现任何基包（需含 `# @key` 且非 overlay 的 .txt）", .{});
    if (default_seen > 1) std.process.fatal("有多个基包同时标 `# @default`（至多一个）", .{});
    // 撞号基包封口（承 D18 `default`>1 / D19 孤儿补充层 同族「该拒绝未拒绝·静默错选」）：
    // 两基包同 `# @key` 时 `registry.lookup` 取发射序首枚、后者被无声遮蔽（选错语言包且无提示）；
    // 发射前逐对比对拒之并指出相冲两文件（基包数为文件量级·枚举个位数，无需哈希）。与 D18/D19 同用
    // `std.process.fatal` 面向包作者报母语提示（构建期配置错、非运行期可 catch 路径，故与同族守卫一致不入测图）。
    for (base_idx.items, 0..) |bi, k| {
        for (base_idx.items[k + 1 ..]) |bj| {
            if (std.mem.eql(u8, dirs.items[bi].key, dirs.items[bj].key))
                std.process.fatal("两个基包同 `# @key {s}`（{s} 与 {s}）：选包将静默取首枚、另一枚被遮蔽", .{ dirs.items[bi].key, dirs.items[bi].file, dirs.items[bj].file });
        }
    }
    for (dirs.items) |d| {
        if (d.overlay_of.len == 0) continue;
        var hit = false;
        for (base_idx.items) |bi| {
            if (std.mem.eql(u8, dirs.items[bi].key, d.overlay_of)) {
                hit = true;
                break;
            }
        }
        if (!hit) std.process.fatal("补充层 {s} 的 `# @overlay-of {s}` 未指向任何基包（拼写错误将静默丢弃该层）", .{ d.file, d.overlay_of });
    }
    // 发射序：默认包恒置首（registry.defaultEntry() 取 entries[0]），其余维持文件名字典序
    //（dirs 与已排序 names 同序，故下标序即字典序；比较子对非默认项按唯一下标给出全序，排序结果确定）。
    std.mem.sort(usize, base_idx.items, dirs.items, struct {
        fn lt(ds: []const Directive, a: usize, b: usize) bool {
            if (ds[a].is_default != ds[b].is_default) return ds[a].is_default;
            return a < b;
        }
    }.lt);

    // 4) 发射注册表源码。
    var out: std.ArrayList(u8) = .empty;
    push(gpa, &out,
        \\//! 自动生成——请勿手改。由 build.zig 经 src/gen/pack_registry_main.zig（run 步）依据
        \\//! src/lang/packs/ 的 `# @` 头指令生成；生成规则单源在 src/lang/pack_discover.zig。
        \\//! 合并语义见 src/lang/pack.zig《叠加层》。本表仅提供数据，选包逻辑在 src/lang/registry.zig。
        \\pub const Entry = struct {
        \\    key: []const u8,
        \\    aliases: []const []const u8,
        \\    code: []const u8,
        \\    display: []const u8,
        \\    bytes: []const u8,
        \\    overlays: []const []const u8,
        \\    /// 各叠加层的可读名族（第 328 轮 D187）：与 overlays 同序同长；每组首名是 `# @display`，其余为 `# @aliases`。
        \\    overlay_names: []const []const []const u8,
        \\};
        \\
        \\pub const entries = [_]Entry{
        \\
    );

    for (base_idx.items) |bi| {
        const base = dirs.items[bi];

        // 收集该基包的补充层下标并按 (order, file) 升序。
        var ovl: std.ArrayList(usize) = .empty;
        for (dirs.items, 0..) |d, i| {
            if (d.overlay_of.len != 0 and std.mem.eql(u8, d.overlay_of, base.key)) {
                ovl.append(gpa, i) catch std.process.fatal("OOM", .{});
            }
        }
        std.mem.sort(usize, ovl.items, dirs.items, struct {
            fn lt(ds: []const Directive, a: usize, b: usize) bool {
                if (ds[a].order != ds[b].order) return ds[a].order < ds[b].order;
                return std.mem.lessThan(u8, ds[a].file, ds[b].file);
            }
        }.lt);

        push(gpa, &out, "    .{ .key = ");
        emitStr(gpa, &out, base.key);
        push(gpa, &out, ", .aliases = &.{");
        for (base.aliases) |a| {
            push(gpa, &out, " ");
            emitStr(gpa, &out, a);
            push(gpa, &out, ",");
        }
        push(gpa, &out, " }, .code = ");
        emitStr(gpa, &out, base.code);
        push(gpa, &out, ", .display = ");
        emitStr(gpa, &out, base.display);
        push(gpa, &out, ", .bytes = ");
        emitBytes(gpa, &out, base.bytes);
        push(gpa, &out, ", .overlays = &.{");
        for (ovl.items) |oi| {
            push(gpa, &out, " ");
            emitBytes(gpa, &out, dirs.items[oi].bytes);
            push(gpa, &out, ",");
        }
        push(gpa, &out, " }, .overlay_names = &.{");
        for (ovl.items) |oi| {
            const od = dirs.items[oi];
            push(gpa, &out, " &.{");
            if (od.display.len != 0) {
                push(gpa, &out, " ");
                emitStr(gpa, &out, od.display);
                push(gpa, &out, ",");
            }
            for (od.aliases) |a| {
                push(gpa, &out, " ");
                emitStr(gpa, &out, a);
                push(gpa, &out, ",");
            }
            push(gpa, &out, " },");
        }
        push(gpa, &out, " }, },\n");
    }
    push(gpa, &out, "};\n");

    return out.toOwnedSlice(gpa);
}

/// 一份包文件的注册头指令（`# @key`/`# @code`/`# @display`/`# @aliases`/`# @overlay-of`/`# @order`/`# @default`）。
pub const Directive = struct {
    file: []const u8 = "",
    key: []const u8 = "",
    code: []const u8 = "",
    display: []const u8 = "",
    aliases: []const []const u8 = &.{},
    overlay_of: []const u8 = "",
    order: i32 = 0,
    has_key: bool = false,
    is_default: bool = false,
    /// 基包/补充层的原始字节（供发射内联；补充层也带自身字节）。
    bytes: []const u8 = "",
};

/// 解析包文件头部（首个非注释/非空行之前）出现的 `# @tag value` 指令。
pub fn parseDirectives(gpa: Allocator, file_name: []const u8, bytes: []const u8) Directive {
    var d: Directive = .{ .file = file_name, .bytes = bytes };
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "#")) break; // 头注释区结束
        if (!std.mem.startsWith(u8, line, "# @")) continue;
        const rest = std.mem.trim(u8, line[3..], " ");
        const sp = std.mem.indexOfScalar(u8, rest, ' ');
        const tag = if (sp) |p| rest[0..p] else rest;
        const val = if (sp) |p| std.mem.trim(u8, rest[p + 1 ..], " ") else "";
        if (std.mem.eql(u8, tag, "key")) {
            d.key = dupe(gpa, val);
            d.has_key = true;
        } else if (std.mem.eql(u8, tag, "code")) {
            d.code = dupe(gpa, val);
        } else if (std.mem.eql(u8, tag, "display")) {
            d.display = dupe(gpa, val);
        } else if (std.mem.eql(u8, tag, "overlay-of")) {
            d.overlay_of = dupe(gpa, val);
        } else if (std.mem.eql(u8, tag, "default")) {
            d.is_default = true; // 基包发射时置首（entries[0]），registry.defaultEntry() 由此真实取到默认包，不再靠文件名字典序偶然命中
        } else if (std.mem.eql(u8, tag, "order")) {
            d.order = std.fmt.parseInt(i32, val, 10) catch std.process.fatal("包 {s} 的 `# @order` 非整数：{s}", .{ file_name, val });
        } else if (std.mem.eql(u8, tag, "aliases")) {
            var parts = std.mem.splitScalar(u8, val, ',');
            var list: std.ArrayList([]const u8) = .empty;
            while (parts.next()) |p| {
                const t = std.mem.trim(u8, p, " \t");
                if (t.len == 0) continue;
                list.append(gpa, dupe(gpa, t)) catch std.process.fatal("OOM", .{});
            }
            d.aliases = list.items;
        } else {
            std.process.fatal("包 {s} 有未知头指令 `# @{s}`", .{ file_name, tag });
        }
    }
    return d;
}

fn dupe(gpa: Allocator, s: []const u8) []const u8 {
    return gpa.dupe(u8, s) catch std.process.fatal("OOM", .{});
}

fn push(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    out.appendSlice(gpa, s) catch std.process.fatal("OOM", .{});
}

/// 发出一个双引号字符串字面量：转义 `"`/`\`，控制字符直接失败（头指令值不该含它们；CJK 原样，源码 UTF-8）。
fn emitStr(gpa: Allocator, out: *std.ArrayList(u8), val: []const u8) void {
    push(gpa, out, "\"");
    for (val) |c| {
        if (c == '"' or c == '\\') {
            out.append(gpa, '\\') catch std.process.fatal("OOM", .{});
            out.append(gpa, c) catch std.process.fatal("OOM", .{});
        } else if (c < 0x20 or c == 0x7f) {
            std.process.fatal("头指令值含控制字符", .{});
        } else {
            out.append(gpa, c) catch std.process.fatal("OOM", .{});
        }
    }
    push(gpa, out, "\"");
}

/// 把一段包字节以 u8 数组字面量发出（全 0xNN，规避任意 UTF-8/转义在生成源码里的歧义）。
fn emitBytes(gpa: Allocator, out: *std.ArrayList(u8), bytes: []const u8) void {
    push(gpa, out, "&[_]u8{ ");
    for (bytes, 0..) |byt, i| {
        if (i > 0) out.append(gpa, ',') catch std.process.fatal("OOM", .{});
        var tmp: [8]u8 = undefined;
        const h = std.fmt.bufPrint(&tmp, "0x{x:0>2}", .{byt}) catch unreachable;
        out.appendSlice(gpa, h) catch std.process.fatal("OOM", .{});
    }
    push(gpa, out, " }");
}

// ---------------------------------------------------------------- 测试（编入 zzc_core 测图）

/// 从生成的注册表源码里按出现顺序抽出每一段 `&[_]u8{ 0xNN,... }` 并解码回字节。
/// 用于字节保真对拍：验证 emitBytes 的内联/解码往返逐字节等于原始输入（D45 假绿形制的生成侧防线）。
pub fn extractInlinedBytes(gpa: Allocator, source: []const u8) ![]const []const u8 {
    const marker = "&[_]u8{ ";
    const closer = " }";
    var list: std.ArrayList([]const u8) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, pos, marker)) |start| {
        const body_start = start + marker.len;
        // indexOfPos 返回的是针线在 haystack 中的**绝对**下标（非相对于 body_start）。
        const body_end = std.mem.indexOfPos(u8, source, body_start, closer) orelse break;
        const body = source[body_start..body_end];
        var buf: std.ArrayList(u8) = .empty;
        var parts = std.mem.splitScalar(u8, body, ',');
        while (parts.next()) |tok| {
            const t = std.mem.trim(u8, tok, " ");
            if (t.len == 0) continue;
            const raw = if (std.mem.startsWith(u8, t, "0x")) t[2..] else t; // 去 0x 前缀后按 base16 解
            const v = try std.fmt.parseInt(u8, raw, 16);
            try buf.append(gpa, v);
        }
        try list.append(gpa, try buf.toOwnedSlice(gpa));
        pos = body_end + closer.len;
    }
    return list.toOwnedSlice(gpa);
}

test "生成器字节保真：内联的 Entry.bytes 逐字节 == 输入包字节（D45 假绿根治·c 对拍）" {
    // 生成器会 dup 指令值/分配多处临时块且不移交所有权→用 arena over testing.allocator 域尾统一回收（同仓库惯例）。
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const gpa = arena_impl.allocator();
    // 合成包（不耦合真实文件名）：基包 zh（默认）+ 补充层 繁体。正文故意夹引号/反斜杠/CJK，
    // 压力测 emitBytes（全 0xNN hex）的内联↔抽回往返——这是 D45 假绿形制下最需保真的「字节保真」面。
    const zh =
        \\# @key zh
        \\# @code zh
        \\# @default
        \\$code = zh
        \\[docs]
        \\x = 含引号 " 反斜杠 \ 与 CJK
    ;
    const trad =
        \\# @overlay-of zh
        \\# @order 10
        \\[keywords]
        \\常數 = const
    ;
    const files = [_]PackFile{
        .{ .name = "中文.txt", .bytes = zh },
        .{ .name = "繁体.txt", .bytes = trad },
    };
    const source = try generateRegistrySource(gpa, &files);
    defer gpa.free(source);

    const inlined = try extractInlinedBytes(gpa, source);
    defer {
        for (inlined) |b| gpa.free(b);
        gpa.free(inlined);
    }
    // 内联字节段共两枚：基包 zh 的 .bytes + 补充层 繁体 的 overlay 字节。逐枚与输入全等。
    try std.testing.expectEqual(@as(usize, 2), inlined.len);
    try std.testing.expectEqualStrings(zh, inlined[0]);
    try std.testing.expectEqualStrings(trad, inlined[1]);
}

test "生成器结构：默认包置首、补充层内联进 overlays、非默认基包各自成条目" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const gpa = arena_impl.allocator();
    // 故意以非默认包名 aa 先传入，验生成器按 default 优先重排（默认包恒 entries[0]）；繁体为 zh 补充层。
    const base_a =
        \\# @key aa
        \\# @code aa
        \\$code = aa
        \\[keywords]
        \\常数 = const
    ;
    const zh =
        \\# @key zh
        \\# @code zh
        \\# @default
        \\$code = zh
        \\[keywords]
        \\常数 = const
    ;
    const trad =
        \\# @overlay-of zh
        \\# @order 10
        \\[keywords]
        \\常數 = const
    ;
    const files = [_]PackFile{
        .{ .name = "a.txt", .bytes = base_a },
        .{ .name = "中文.txt", .bytes = zh },
        .{ .name = "繁体.txt", .bytes = trad },
    };
    const source = try generateRegistrySource(gpa, &files);
    defer gpa.free(source);

    // 两个基包条目（zh、aa），繁体被吞作 zh 的 overlay（不另立条目）。
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, ".key = "));
    // entries 首项即默认包 zh（`# @default` 置首发射，即便 a.txt 字典序更靠前）。
    const first_key = std.mem.indexOf(u8, source, ".key = ").?;
    try std.testing.expectEqualStrings(".key = \"zh\"", source[first_key .. first_key + 11]);
    // 内联字节块总数：两基包各一枚 .bytes（zh/aa）+ 繁体一枚 overlay = 3（繁体不另立条目）。
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, source, "&[_]u8{"));
    // 每个基包恰一个 .overlays 段标记（zh/aa 各一）——与基包条目数平恒，防多余/缺失条目。
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, ".overlays = &.{"));
}

test "parseDirectives：基包 key/code/default 与补充层 overlay-of/order 各归位" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const gpa = arena_impl.allocator();
    const base =
        \\# 头
        \\# @key xx
        \\# @code xx
        \\# @default
        \\$code = xx
        \\[keywords]
        \\常数 = const
    ;
    const d = parseDirectives(gpa, "x.txt", base);
    try std.testing.expect(d.has_key);
    try std.testing.expectEqualStrings("xx", d.key);
    try std.testing.expect(d.is_default);
    try std.testing.expectEqual(@as(usize, 0), d.overlay_of.len);

    const overlay =
        \\# @overlay-of xx
        \\# @order 20
        \\[keywords]
        \\常數 = const
    ;
    const o = parseDirectives(gpa, "y.txt", overlay);
    try std.testing.expect(!o.has_key);
    try std.testing.expectEqualStrings("xx", o.overlay_of);
    try std.testing.expectEqual(@as(i32, 20), o.order);
}
