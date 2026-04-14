const std = @import("std");

/// zzc —— 母语 Zig 方言编译器（transpiler + 工具链驱动）。
/// 模块 zzc_core 暴露翻译/报错回译引擎（供测试与第三方嵌入），
/// exe zzc 是 CLI 入口。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // R9续②（第 54 轮）：构建期自动发现语言包——扫 src/lang/packs/*.txt 的 `# @` 头指令，
    // 生成 pack 注册表模块（含内联包字节），作者丢文件即注册、无需手改 registry.zig。
    // R9f 陷阱（第 100 轮 D45 坐实）：包字节以 u8 字面量内联进生成模块，而脚本用命令式
    // readFileAlloc 读取、不向构建系统声明文件依赖——故**仅改 .txt 包内容不会触发脚本重跑**，
    // exe 仍嵌旧词条（而测图 @embedFile 追踪变更显新行为，二者分歧会假绿）。改包后须让
    // build.zig 自身发生内容变更（或删 .zig-cache 强制重建）方能刷新内联字节。
    const pack_mod = generatePackRegistry(b);

    const mod = b.addModule("zzc_core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "pack_registry", .module = pack_mod }},
    });

    const exe = b.addExecutable(.{
        .name = "zzc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zzc_core", .module = mod },
                .{ .name = "pack_registry", .module = pack_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "运行 zzc（示例：zig build run -- check demo/hello.zz）");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // 注：子模块测试已经由 zzc_core（src/root.zig）汇总；不再单独跑 exe
    // 测试可执行文件，避免同一 test block 被编入两个模块时符号重名。
    // 第 181 轮例外接线：main.zig 的 test 块此前恒不执行（L1335 注在册），但其 LSP 接线侧
    // 四纯函数（parseMachineDiag/kindSeverity/fileMatchesDoc/uriToFilesystemPath）系全库
    // 零直调面——接线本体不入图则无任何钉住通道。单独 addTest 以 main.zig 为 root：其
    // test 块仅此一图（root.zig 不 import main.zig），无重名风险；test 构建下 root 的
    // `pub fn main` 被编译排除，不与测试 runner 冲突。
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zzc_core", .module = mod },
            .{ .name = "pack_registry", .module = pack_mod },
        },
    });
    const main_tests = b.addTest(.{ .root_module = main_mod });
    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "运行单元与快照测试");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_main_tests.step);

    // 第 154 轮：tmLanguage 语法高亮生成器（编辑器集成 MVP）。
    const gen_tmlang_exe = b.addExecutable(.{
        .name = "gen-tmlang",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/editor/gen_tmlang_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zzc_core", .module = mod }},
        }),
    });

    const gen_syntax_step = b.step("gen-editor-syntax", "生成 editors/vscode/syntaxes/zz.tmLanguage.json");
    const gen_run = b.addRunArtifact(gen_tmlang_exe);
    gen_run.addArg("emit");
    gen_syntax_step.dependOn(&gen_run.step);

    const check_syntax_step = b.step("check-editor-syntax", "校验 tmLanguage 与语言包同步（CI 守卫）");
    const check_run = b.addRunArtifact(gen_tmlang_exe);
    check_run.addArg("check");
    check_syntax_step.dependOn(&check_run.step);

    // 第 155 轮：补全片段生成器（编辑器集成 MVP 补全面）。
    const gen_snippets_exe = b.addExecutable(.{
        .name = "gen-snippets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/editor/gen_snippets_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zzc_core", .module = mod }},
        }),
    });

    const gen_snippets_step = b.step("gen-editor-snippets", "生成 editors/vscode/snippets/zz.json");
    const gen_snip_run = b.addRunArtifact(gen_snippets_exe);
    gen_snip_run.addArg("emit");
    gen_snippets_step.dependOn(&gen_snip_run.step);

    const check_snippets_step = b.step("check-editor-snippets", "校验 snippets 与语言包同步（CI 守卫）");
    const check_snip_run = b.addRunArtifact(gen_snippets_exe);
    check_snip_run.addArg("check");
    check_snippets_step.dependOn(&check_snip_run.step);
}

// ---------------------------------------------------------------- 语言包自动发现（R9续②）

/// 一份包文件的注册头指令（`# @key`/`# @code`/`# @display`/`# @aliases`/`# @overlay-of`/`# @order`/`# @default`）。
const Directive = struct {
    file: []const u8 = "",
    key: []const u8 = "",
    code: []const u8 = "",
    display: []const u8 = "",
    aliases: []const []const u8 = &.{},
    overlay_of: []const u8 = "",
    order: i32 = 0,
    has_key: bool = false,
    is_default: bool = false,
};

const packs_dir = "src/lang/packs";

fn generatePackRegistry(b: *std.Build) *std.Build.Module {
    const gpa = b.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(io, packs_dir, .{ .iterate = true }) catch |e|
        std.process.fatal("无法打开语言包目录 {s}（{s}）", .{ packs_dir, @errorName(e) });
    defer dir.close(io);

    // 1) 列出全部 .txt，按文件名字典序（生成确定性）。
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch |e| std.process.fatal("遍历语言包目录失败（{s}）", .{@errorName(e)})) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.name, ".txt")) continue;
        names.append(gpa, gpa.dupe(u8, ent.name) catch @panic("OOM")) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, bb: []const u8) bool {
            return std.mem.lessThan(u8, a, bb);
        }
    }.lt);
    if (names.items.len == 0) std.process.fatal("语言包目录 {s} 下没有 .txt 包", .{packs_dir});

    // 2) 解析每包头指令。
    var dirs: std.ArrayList(Directive) = .empty;
    for (names.items) |n| {
        const bytes = readPack(b, io, gpa, n);
        dirs.append(gpa, parseDirectives(b, gpa, n, bytes)) catch @panic("OOM");
    }

    // 3) 生成注册表源码：基包（有 key 且非 overlay）各成一项，其补充层（overlay-of==key、按 order+文件名）内联进 overlays。
    var out: std.ArrayList(u8) = .empty;
    push(b, gpa, &out,
        \\//! 自动生成——请勿手改。由 build.zig 依据 src/lang/packs/ 的 `# @` 头指令生成（构建缓存内）。
        \\//! 合并语义见 src/lang/pack.zig《叠加层》。本表仅提供数据，选包逻辑在 src/lang/registry.zig。
        \\pub const Entry = struct {
        \\    key: []const u8,
        \\    aliases: []const []const u8,
        \\    code: []const u8,
        \\    display: []const u8,
        \\    bytes: []const u8,
        \\    overlays: []const []const u8,
        \\};
        \\
        \\pub const entries = [_]Entry{
        \\
    );

    // 收集基包下标（有 key 且非 overlay），校验 code，统计 `# @default` 个数。
    var base_idx: std.ArrayList(usize) = .empty;
    var default_seen: usize = 0;
    for (dirs.items, 0..) |d, i| {
        if (!d.has_key or d.overlay_of.len != 0) continue;
        if (d.code.len == 0) std.process.fatal("基包 {s} 缺 `# @code` 头指令", .{d.file});
        if (d.is_default) default_seen += 1;
        base_idx.append(gpa, i) catch @panic("OOM");
    }
    if (base_idx.items.len == 0) std.process.fatal("未发现任何基包（需含 `# @key` 且非 overlay 的 .txt）", .{});
    if (default_seen > 1) std.process.fatal("有多个基包同时标 `# @default`（至多一个）", .{});
    // 校验每个补充层的 `# @overlay-of` 都指向一个真实存在的基包 key：否则下面按 key 匹配时会被静默丢弃、叠加无声失效。
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
        fn lt(ds: []const Directive, a: usize, bb: usize) bool {
            if (ds[a].is_default != ds[bb].is_default) return ds[a].is_default;
            return a < bb;
        }
    }.lt);

    for (base_idx.items) |bi| {
        const base = dirs.items[bi];

        // 收集该基包的补充层下标并按 (order, file) 升序。
        var ovl: std.ArrayList(usize) = .empty;
        for (dirs.items, 0..) |d, i| {
            if (d.overlay_of.len != 0 and std.mem.eql(u8, d.overlay_of, base.key)) {
                ovl.append(gpa, i) catch @panic("OOM");
            }
        }
        std.mem.sort(usize, ovl.items, dirs.items, struct {
            fn lt(ds: []const Directive, a: usize, bb: usize) bool {
                if (ds[a].order != ds[bb].order) return ds[a].order < ds[bb].order;
                return std.mem.lessThan(u8, ds[a].file, ds[bb].file);
            }
        }.lt);

        push(b, gpa, &out, "    .{ .key = ");
        emitStr(b, gpa, &out, base.key);
        push(b, gpa, &out, ", .aliases = &.{");
        for (base.aliases) |a| {
            push(b, gpa, &out, " ");
            emitStr(b, gpa, &out, a);
            push(b, gpa, &out, ",");
        }
        push(b, gpa, &out, " }, .code = ");
        emitStr(b, gpa, &out, base.code);
        push(b, gpa, &out, ", .display = ");
        emitStr(b, gpa, &out, base.display);
        push(b, gpa, &out, ", .bytes = ");
        emitBytes(b, gpa, &out, readPack(b, io, gpa, base.file));
        push(b, gpa, &out, ", .overlays = &.{");
        for (ovl.items) |oi| {
            push(b, gpa, &out, " ");
            emitBytes(b, gpa, &out, readPack(b, io, gpa, dirs.items[oi].file));
            push(b, gpa, &out, ",");
        }
        push(b, gpa, &out, " }, },\n");
    }
    push(b, gpa, &out, "};\n");

    const wf = b.addWriteFiles();
    const src = wf.add("pack_registry.zig", out.items);
    return b.createModule(.{ .root_source_file = src });
}

fn readPack(b: *std.Build, io: std.Io, gpa: std.mem.Allocator, name: []const u8) []const u8 {
    _ = b;
    const path = std.fs.path.join(gpa, &.{ packs_dir, name }) catch @panic("OOM");
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e|
        std.process.fatal("读取语言包 {s} 失败（{s}）", .{ name, @errorName(e) });
}

/// 解析包文件头部（首个非注释/非空行之前）出现的 `# @tag value` 指令。
fn parseDirectives(b: *std.Build, gpa: std.mem.Allocator, file_name: []const u8, bytes: []const u8) Directive {
    var d: Directive = .{ .file = file_name };
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
            d.key = dupe(b, gpa, val);
            d.has_key = true;
        } else if (std.mem.eql(u8, tag, "code")) {
            d.code = dupe(b, gpa, val);
        } else if (std.mem.eql(u8, tag, "display")) {
            d.display = dupe(b, gpa, val);
        } else if (std.mem.eql(u8, tag, "overlay-of")) {
            d.overlay_of = dupe(b, gpa, val);
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
                list.append(gpa, dupe(b, gpa, t)) catch @panic("OOM");
            }
            d.aliases = list.items;
        } else {
            std.process.fatal("包 {s} 有未知头指令 `# @{s}`", .{ file_name, tag });
        }
    }
    return d;
}

fn dupe(b: *std.Build, gpa: std.mem.Allocator, s: []const u8) []const u8 {
    _ = b;
    return gpa.dupe(u8, s) catch @panic("OOM");
}

fn push(b: *std.Build, gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    _ = b;
    out.appendSlice(gpa, s) catch @panic("OOM");
}

/// 发出一个双引号字符串字面量：转义 `"`/`\`，控制字符直接失败（头指令值不该含它们；CJK 原样，源码 UTF-8）。
fn emitStr(b: *std.Build, gpa: std.mem.Allocator, out: *std.ArrayList(u8), val: []const u8) void {
    push(b, gpa, out, "\"");
    for (val) |c| {
        if (c == '"' or c == '\\') {
            out.append(gpa, '\\') catch @panic("OOM");
            out.append(gpa, c) catch @panic("OOM");
        } else if (c < 0x20 or c == 0x7f) {
            std.process.fatal("头指令值含控制字符", .{});
        } else {
            out.append(gpa, c) catch @panic("OOM");
        }
    }
    push(b, gpa, out, "\"");
}

/// 把一段包字节以 u8 数组字面量发出（全 0xNN，规避任意 UTF-8/转义在生成源码里的歧义）。
fn emitBytes(b: *std.Build, gpa: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) void {
    push(b, gpa, out, "&[_]u8{ ");
    for (bytes, 0..) |byt, i| {
        if (i > 0) out.append(gpa, ',') catch @panic("OOM");
        var tmp: [8]u8 = undefined;
        const h = std.fmt.bufPrint(&tmp, "0x{x:0>2}", .{byt}) catch unreachable;
        out.appendSlice(gpa, h) catch @panic("OOM");
    }
    push(b, gpa, out, " }");
}
