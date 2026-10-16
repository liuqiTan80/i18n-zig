//! 非 ASCII 词法安全审查（合并 fullwidth 与 unicode_confusion 两个关注点）：
//!
//!   - 方言只允许「母语文字」与 ASCII Zig 语法。全角标点（；（）＝）、不可见字符、
//!     以及**文字区间白名单之外**的同形字符（如希腊 α 冒充拉丁）会在这里被泛拦截，
//!     而不是透传给 zig 产生费解报错。
//!   - 白名单策略（显式码点区间表，**非** Unicode Letter 属性）：词元的每个码点必须落在
//!     假名/CJK 各扩展/谚文/西里尔/阿拉伯/泰文等列示区间 ∪ ASCII 字母数字下划线，
//!     否则泛拒绝；另命中「危险字符表」者给针对性更正提示。
//!     注意：组合符（U+0300 段）与拉丁扩展字母（é 等）**不在**白名单——旧注曾误称放行，
//!     实为泛拒绝拦截（见守卫测钉住；若未来要支持越南文等叠加符号方言须正式登记消缺）。
//!   - 文字混排（如西里尔 р+拉丁 rint 冒充 print）本模块**不专门处理**：西里尔等整段系
//!     俄文等方言的合法母语文字，从未建「同形冲突表」；同形防线仅对白名单外字符生效。

const std = @import("std");
const lexer = @import("../transpiler/lexer.zig");

pub const Violation = struct {
    off: usize,
    len: usize,
    word: []const u8,
    /// 命中的危险字符（UTF-8 序列）；纯未知字符时为 null
    danger: ?[]const u8 = null,
    /// 命中的危险字符对应的建议半角 ASCII（无则空）
    ascii: []const u8 = "",
    hint: []const u8 = "",
};

/// 常见全角/易混标点 -> 建议替换的半角 ASCII。
const Danger = struct { full: []const u8, ascii: []const u8, label: []const u8 };
const dangers = [_]Danger{
    .{ .full = "；", .ascii = ";", .label = "全角分号" },
    .{ .full = "，", .ascii = ",", .label = "全角逗号" },
    .{ .full = "（", .ascii = "(", .label = "全角左括号" },
    .{ .full = "）", .ascii = ")", .label = "全角右括号" },
    .{ .full = "｛", .ascii = "{", .label = "全角左花括号" },
    .{ .full = "｝", .ascii = "}", .label = "全角右花括号" },
    .{ .full = "［", .ascii = "[", .label = "全角左方括号" },
    .{ .full = "］", .ascii = "]", .label = "全角右方括号" },
    .{ .full = "＝", .ascii = "=", .label = "全角等号" },
    .{ .full = "：", .ascii = ":", .label = "全角冒号" },
    .{ .full = "！", .ascii = "!", .label = "全角感叹号" },
    .{ .full = "？", .ascii = "?", .label = "全角问号" },
    // 全角空格（U+3000）：中文 IME 打缩进/分隔时最高频的误产出。它字节 E3 80 80≥0x80、会被
    // lexer 归入 nonascii_word（ASCII 空白才被跳过），若不登记危险表只会落到泛白名单提示
    // “不允许出现在母语标识符中”，对用户误导；这里给出“改用半角空格”的精确提示。
    .{ .full = "　", .ascii = " ", .label = "全角空格" },
    // 复制粘贴 / 自动更正的高频误产（与全角空格 U+3000 同族，都不是「非法标识符字符」）：
    //   · 不间断空格 U+00A0、零宽空格 U+200B 不可见，多从网页/文档复制代码时混入；
    //   · 长/短破折号 U+2014/U+2013 是自动更正把半角 `-` 变来的；省略号 U+2026 把 `...` 变来的。
    // 若不登记危险表，它们只会落到泛白名单提示「不允许出现在母语标识符中」，对用户误导。
    .{ .full = "\u{00A0}", .ascii = " ", .label = "不间断空格" },
    .{ .full = "\u{200B}", .ascii = "", .label = "零宽空格（复制粘贴混入，请删除）" },
    .{ .full = "\u{2014}", .ascii = "-", .label = "长破折号" },
    .{ .full = "\u{2013}", .ascii = "-", .label = "短破折号" },
    .{ .full = "\u{2026}", .ascii = "...", .label = "省略号" },
    .{ .full = "。", .ascii = ".", .label = "句号" },
    .{ .full = "、", .ascii = ",", .label = "顿号" },
    .{ .full = "「", .ascii = "\"", .label = "引号" },
    .{ .full = "」", .ascii = "\"", .label = "引号" },
    // 弯引号（智能引号）：中英文输入法打字符串时最常见的误产出，单独给精确提示。
    .{ .full = "\u{201C}", .ascii = "\"", .label = "弯双引号“”" },
    .{ .full = "\u{201D}", .ascii = "\"", .label = "弯双引号“”" },
    .{ .full = "\u{2018}", .ascii = "'", .label = "弯单引号‘’" },
    .{ .full = "\u{2019}", .ascii = "'", .label = "弯单引号‘’" },
    .{ .full = "＂", .ascii = "\"", .label = "全角双引号" },
    .{ .full = "＇", .ascii = "'", .label = "全角单引号" },
    // 全角/数学运算符：算术与位运算表达式里最常见的 IME 误产出（如 甲 ＋ 乙），
    // 需与「标识符非法字符」区分开——给出半角运算符的精确替换提示。
    .{ .full = "\u{FF0B}", .ascii = "+", .label = "全角加号" },
    .{ .full = "\u{FF0D}", .ascii = "-", .label = "全角减号" },
    .{ .full = "\u{2212}", .ascii = "-", .label = "数学减号" },
    .{ .full = "\u{FF0A}", .ascii = "*", .label = "全角乘号" },
    .{ .full = "\u{FF0F}", .ascii = "/", .label = "全角除号" },
    .{ .full = "\u{FF05}", .ascii = "%", .label = "全角百分号" },
    .{ .full = "\u{FF1C}", .ascii = "<", .label = "全角小于号" },
    .{ .full = "\u{FF1E}", .ascii = ">", .label = "全角大于号" },
    .{ .full = "\u{FF06}", .ascii = "&", .label = "全角与号" },
    .{ .full = "\u{FF5C}", .ascii = "|", .label = "全角竖线" },
    .{ .full = "\u{FF5E}", .ascii = "~", .label = "全角波浪号" },
    .{ .full = "\u{FF3E}", .ascii = "^", .label = "全角脱字符" },
    .{ .full = "\u{FF20}", .ascii = "@", .label = "全角 at 符号" },
    .{ .full = "\u{FF3F}", .ascii = "_", .label = "全角下划线" },
};

fn isAllowedScalar(cp: u21) bool {
    // 合并后非 ASCII 词元可含紧邻的 ASCII 字母/数字/下划线（`变量1` 这类整体母语标识符）→ 合法放行。
    // （旧假设“ASCII 字母数字已由 lexer 归入 ascii_word、不会到这里”因词元合并而不再成立。）
    if (cp < 0x80) {
        const c: u8 = @intCast(cp);
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
    }
    // 常用母语文字区白名单：CJK / 假名 / 谚文 / 喃字 / 全角字母数字以外的符号均拦截
    if (cp >= 0x3040 and cp <= 0x30FF) return true; // 日文假名
    if (cp >= 0x3400 and cp <= 0x4DBF) return true; // CJK 扩展 A
    if (cp >= 0x4E00 and cp <= 0x9FFF) return true; // CJK 统一汉字
    if (cp >= 0xF900 and cp <= 0xFAFF) return true; // CJK 兼容汉字
    if (cp >= 0xAC00 and cp <= 0xD7AF) return true; // 谚文音节
    if (cp >= 0x1100 and cp <= 0x11FF) return true; // 谚文字母
    if (cp >= 0x20000 and cp <= 0x2FA1F) return true; // CJK 扩展 B-F / 兼容
    if (cp >= 0x0400 and cp <= 0x04FF) return true; // 西里尔字母（俄文等方言合法母语文字；同形冲突表未建，与拉丁混排不专拦，见文件头）
    if (cp >= 0x0600 and cp <= 0x06FF) return true; // 阿拉伯字母
    if (cp >= 0x0E00 and cp <= 0x0E7F) return true; // 泰文
    if (cp >= 0xFF10 and cp <= 0xFF19) return false; // 全角数字（显式拦截）
    if (cp >= 0xFF21 and cp <= 0xFF3A) return false; // 全角拉丁字母（显式拦截）
    if (cp >= 0xFF41 and cp <= 0xFF5A) return false; // 全角小写（显式拦截）
    return false;
}

/// 全角 ASCII 变体区 U+FF01..U+FF5E 与半角 U+0021..U+007E 逐一对应（差值 0xFEE0）。
/// 下标 i = cp - 0xFF01（0..93），取对应半角字符；comptime 生成，生命期为静态，供 Violation.ascii 直接引用。
const halfwidth_of_fullwidth = blk: {
    @setEvalBranchQuota(1000);
    var buf: [94]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @intCast(0x21 + i);
    break :blk buf;
};

const FwHint = struct { at: usize, len: usize, ascii: []const u8, danger: []const u8, label: []const u8 };

/// 扫描词元中首个落在全角 ASCII 变体区的码点，给出按类划分的精确替换提示。
/// 作为危险表的兜底，一网打尽全角数字（如 ５０→半角 50 场景）、全角拉丁字母与其余全角符号。
fn fullwidthFormHint(word: []const u8) ?FwHint {
    var i: usize = 0;
    while (i < word.len) {
        const blen = std.unicode.utf8ByteSequenceLength(word[i]) catch {
            i += 1;
            continue;
        };
        if (i + blen > word.len) break;
        const cp = std.unicode.utf8Decode(word[i..][0..blen]) catch {
            i += 1;
            continue;
        };
        if (cp >= 0xFF01 and cp <= 0xFF5E) {
            const idx = cp - 0xFF01; // 0..93
            const label: []const u8 = if (cp >= 0xFF10 and cp <= 0xFF19)
                "全角数字"
            else if ((cp >= 0xFF21 and cp <= 0xFF3A) or (cp >= 0xFF41 and cp <= 0xFF5A))
                "全角拉丁字母"
            else
                "全角符号";
            return .{
                .at = i,
                .len = blen,
                .ascii = halfwidth_of_fullwidth[idx .. idx + 1],
                .danger = word[i .. i + blen],
                .label = label,
            };
        }
        i += blen;
    }
    return null;
}

/// 不可见空格类（Unicode Zs / 行段分隔）：与半角空格同职、但肉眼不可见，多从网页/文档复制粘贴混入。
/// （NBSP U+00A0、全角空格 U+3000 已在危险表给专名，这里兜底其余所有不可见空格。）
fn isInvisibleSpace(cp: u21) bool {
    return switch (cp) {
        0x1680, // 欧甘空格
        0x2000...0x200A, // EN QUAD .. HAIR SPACE（连串宽度空格）
        0x2028, // 行分隔符
        0x2029, // 段分隔符
        0x202F, // 窄不间断空格
        0x205F,
        => true, // 中数学空格
        else => false,
    };
}

/// 零宽/格式控制字符（Unicode Cf）：不可见且无可见半角替换，只能删除；
/// 常由复制粘贴、bidi 排版标记、软连字符、文件中部 BOM 等混入。
fn isZeroWidthFormat(cp: u21) bool {
    return switch (cp) {
        0x00AD, // 软连字符
        0x180E, // 蒙古元音分隔符
        0x200B, // 零宽空格
        0x200C, // 零宽不连字
        0x200D, // 零宽连字
        0x200E, // 左到右标记
        0x200F, // 右到左标记
        0x202A...0x202E, // bidi 嵌入/覆盖
        0x2060...0x2064, // 单词连接符与隐形运算符
        0x2066...0x2069, // bidi 隔离
        0xFEFF,
        => true, // BOM / 零宽不换行空格（仅文件首会被 stripBom 剔除，正文中部会落到这里）
        else => false,
    };
}

/// 扫描词元中首个不可见字符（空格类 / 零宽格式类），复用 FwHint 结构。
/// 作为危险表与全角变体兜底之后的不可见字符总网：它们既不在危险表、也不在 FF01–FF5E，
/// 若不拦下只会落到泛白名单“不允许出现在母语标识符中”——对一个肉眼看不见的字符极为误导。
fn invisibleFormHint(word: []const u8) ?FwHint {
    var i: usize = 0;
    while (i < word.len) {
        const blen = std.unicode.utf8ByteSequenceLength(word[i]) catch {
            i += 1;
            continue;
        };
        if (i + blen > word.len) break;
        const cp = std.unicode.utf8Decode(word[i..][0..blen]) catch {
            i += 1;
            continue;
        };
        if (isInvisibleSpace(cp)) {
            return .{ .at = i, .len = blen, .ascii = " ", .danger = word[i .. i + blen], .label = "不可见空格" };
        }
        if (isZeroWidthFormat(cp)) {
            return .{ .at = i, .len = blen, .ascii = "", .danger = word[i .. i + blen], .label = "零宽/格式控制字符（复制粘贴易混入，请删除）" };
        }
        i += blen;
    }
    return null;
}

/// 手写 UTF-8 码点迭代（std.unicode 无 DecodeIterator，版本兼容考虑）。
const CpIter = struct {
    bytes: []const u8,
    i: usize = 0,

    fn next(self: *CpIter) ?u21 {
        if (self.i >= self.bytes.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(self.bytes[self.i]) catch {
            self.i += 1;
            return 0xFFFD;
        };
        if (self.i + len > self.bytes.len) {
            self.i += 1;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(self.bytes[self.i..][0..len]) catch 0xFFFD;
        self.i += len;
        return cp;
    }
};

/// R7（第 52 轮）：「危险表 / 全角变体 / 不可见字符」三类扫描都要求词元含某个特定 UTF-8 首字节，
/// 正常母语标识符（典型 CJK 汉字 U+4E00..U+9FFF，首字节 0xE4..0xE9）一个都不含——原实现对每个
/// nonascii_word 都要跑 ~40 次 `indexOf` 全词扫描 + 两轮码点解码，CJK 密集文本时开销可观。
/// 预合并三类触发前提的首字节为位图，词元不含任一则三类必然无命中，安全跳到逐码点白名单。
/// 位图命中仍走原精确路径（判断逻辑与顺序完全不变）；仅排除「必然无命中」，无假阴故行为等价。
const special_lead_bitmap = blk: {
    var bm: [256]bool = undefined;
    for (&bm) |*x| x.* = false;
    // danger 表首字节（全角标点 U+FFxx→0xEF、。，、「、U+300x→0xE3、NBSP→0xC2、破折/零宽/省略→0xE2）。
    for (dangers) |d| {
        if (d.full.len > 0) bm[d.full[0]] = true;
    }
    // 全角 ASCII 变体区 U+FF01..FF5E（恒 0xEF）+ 不可见空格/格式类并集（0xC2/0xE1/0xE2/0xEF），
    // 覆盖 fullwidthFormHint / invisibleFormHint 的全部触发前提。
    bm[0xC2] = true;
    bm[0xE1] = true;
    bm[0xE2] = true;
    bm[0xEF] = true;
    break :blk bm;
};

/// 词元是否可能命中上述三类专门扫描（首字节位图快跳的判据）。
fn mayNeedSpecialCheck(word: []const u8) bool {
    for (word) |b| {
        if (special_lead_bitmap[b]) return true;
    }
    return false;
}

/// 审查所有 nonascii_word 词元，返回违规列表（字符串/注释天然不参与）。
pub fn check(gpa: std.mem.Allocator, src: []const u8, toks: []const lexer.Token) ![]Violation {
    var out: std.ArrayList(Violation) = .empty;
    errdefer out.deinit(gpa);

    for (toks) |t| {
        if (t.kind != .nonascii_word) continue;
        const word = t.text(src);

        // R7：首字节位图快跳——词元不含危险/全角/不可见任一特征首字节时，以下三类扫描必然落空，
        // 直接跳到逐码点白名单（白名单才是判定非法字符的必要路径，不能跳）。
        if (mayNeedSpecialCheck(word)) {
            // 1) 危险字符表命中：给出精确替换提示
            var hit_danger = false;
            for (dangers) |d| {
                if (std.mem.indexOf(u8, word, d.full)) |at| {
                    try out.append(gpa, .{
                        .off = t.off + at,
                        .len = d.full.len,
                        .word = word,
                        .danger = d.full,
                        .ascii = d.ascii,
                        .hint = d.label,
                    });
                    hit_danger = true;
                    break;
                }
            }
            // 已由危险表精确命中的字符不再走白名单，避免同一位置重复报错
            if (hit_danger) continue;

            // 2) 全角 ASCII 变体兜底：数字/拉丁字母/其余符号按类给半角替换提示（危险表未列举的）。
            if (fullwidthFormHint(word)) |h| {
                try out.append(gpa, .{
                    .off = t.off + h.at,
                    .len = h.len,
                    .word = word,
                    .danger = h.danger,
                    .ascii = h.ascii,
                    .hint = h.label,
                });
                continue;
            }

            // 2.5) 不可见字符总网：空格类→“改用半角空格”（走空格分支）；零宽/格式类→“请删除”（无可见替换、走通用分支显示所在词元定位）。
            if (invisibleFormHint(word)) |h| {
                try out.append(gpa, .{
                    .off = t.off + h.at,
                    .len = h.len,
                    .word = word,
                    .danger = h.danger,
                    .ascii = h.ascii,
                    .hint = h.label,
                });
                continue;
            }
        }

        // 3) 逐码点白名单：拦截同形异体与未知字符
        var it = CpIter{ .bytes = word };
        while (it.next()) |cp| {
            if (!isAllowedScalar(cp)) {
                try out.append(gpa, .{
                    .off = t.off,
                    .len = t.len,
                    .word = word,
                    .hint = "该字符不允许出现在母语标识符中（可能是同形异体字符或混排标点）",
                });
                break;
            }
        }
    }
    // 精确大小复制后释放 ArrayList（避免调用方 free(items) 尺寸不一致）
    const result = try gpa.dupe(Violation, out.items);
    out.deinit(gpa);
    return result;
}

test "全角标点与同形字符被拦截" {
    const gpa = std.testing.allocator;
    const src = "常数 ａ = 1; 常数 名， = 2;";
    const toks = try lexer.scan(gpa, src);
    defer gpa.free(toks);
    const vs = try check(gpa, src, toks);
    defer gpa.free(vs);
    // ａ 为全角字母（非字母白名单外，按未知字符拦截），，为全角逗号
    try std.testing.expect(vs.len >= 2);
}

test "弯引号/全角引号命中危险表，给出半角引号精确提示" {
    const gpa = std.testing.allocator;
    // 字符串误用弯双引号 “ ”（最常见 IME 误产出）
    const src = "常数 标准库 = 导入“std”;";
    const toks = try lexer.scan(gpa, src);
    defer gpa.free(toks);
    const vs = try check(gpa, src, toks);
    defer gpa.free(vs);
    try std.testing.expect(vs.len >= 1);
    // 必须命中危险表（danger 非 null）且建议半角为 `"`，而非泛白名单拒绝。
    var got_quote = false;
    for (vs) |v| {
        if (v.danger != null and std.mem.eql(u8, v.ascii, "\"")) got_quote = true;
    }
    try std.testing.expect(got_quote);
}

test "全角运算符命中危险表，给出半角运算符精确提示（而非泛「标识符非法字符」）" {
    const gpa = std.testing.allocator;
    // 算术表达式里误用全角加号 ＋（U+FF0B）
    const src = "常数 \u{4e59}: \u{6574}\u{6570} = \u{7532} \u{FF0B} 1;";
    const toks = try lexer.scan(gpa, src);
    defer gpa.free(toks);
    const vs = try check(gpa, src, toks);
    defer gpa.free(vs);
    try std.testing.expect(vs.len >= 1);
    // 必须命中危险表（danger 非 null）且建议半角为 `+`，不应走泛白名单拒绝（那时 ascii 为空）。
    var got_op = false;
    for (vs) |v| {
        if (v.danger != null and std.mem.eql(u8, v.ascii, "+")) got_op = true;
    }
    try std.testing.expect(got_op);
}

test "全角数字/拉丁字母命中变体兜底，给出半角替换而非泛「标识符非法字符」" {
    const gpa = std.testing.allocator;
    // 数值字面量误用全角 ５０（U+FF15 U+FF10）
    const src = "常数 \u{7532}: \u{6574}\u{6570} = \u{FF15}\u{FF10};";
    const toks = try lexer.scan(gpa, src);
    defer gpa.free(toks);
    const vs = try check(gpa, src, toks);
    defer gpa.free(vs);
    try std.testing.expect(vs.len >= 1);
    // 首个全角数字 ５ 应命中：danger 非空、hint=全角数字、ascii=“5”（走专门提示而非泛拒绝）。
    var got_digit = false;
    for (vs) |v| {
        if (v.danger != null and std.mem.eql(u8, v.hint, "全角数字") and std.mem.eql(u8, v.ascii, "5")) got_digit = true;
    }
    try std.testing.expect(got_digit);
}

test "全角空格（U+3000）命中危险表，给出精确“全角空格”提示而非泛白名单拒绝" {
    const gpa = std.testing.allocator;
    // 用全角空格做缩进（中文 IME 最高频误产）：
    const src = "常数 甲 = 1;\n\u{3000}常数 乙 = 2;";
    const toks = try lexer.scan(gpa, src);
    defer gpa.free(toks);
    const vs = try check(gpa, src, toks);
    defer gpa.free(vs);
    try std.testing.expect(vs.len >= 1);
    // 必须命中危险表（danger 非 null）、label=全角空格、建议半角为一个空格，
    // 而非落到泛白名单分支（那时 danger=null、hint 为“不允许出现在母语标识符中”）。
    var got_fwsp = false;
    for (vs) |v| {
        if (v.danger != null and std.mem.eql(u8, v.hint, "全角空格") and std.mem.eql(u8, v.ascii, " ")) got_fwsp = true;
    }
    try std.testing.expect(got_fwsp);
}

test "不间断空格/零宽空格/破折号/省略号命中危险表，给精确提示而非泛白名单拒绝" {
    const gpa = std.testing.allocator;
    // 复制粘贴混入的不间断空格 U+00A0（作分隔）、零宽空格 U+200B（粘在标识符里）：
    const src_nb = "常数 甲 = 1;\n\u{00A0}常数 乙 = 2;";
    const toks_nb = try lexer.scan(gpa, src_nb);
    defer gpa.free(toks_nb);
    const vs_nb = try check(gpa, src_nb, toks_nb);
    defer gpa.free(vs_nb);
    var got_nbsp = false;
    for (vs_nb) |v| {
        // 必须命中危险表（danger 非 null）、hint=不间断空格、建议半角为一个空格（走空格分支）。
        if (v.danger != null and std.mem.eql(u8, v.hint, "不间断空格") and std.mem.eql(u8, v.ascii, " ")) got_nbsp = true;
    }
    try std.testing.expect(got_nbsp);

    // 自动更正把半角 - 变来的长破折号 U+2014，以及把 ... 变来的省略号 U+2026：
    const src_dash = "常数 丙 = 10 \u{2014} 3;";
    const toks_dash = try lexer.scan(gpa, src_dash);
    defer gpa.free(toks_dash);
    const vs_dash = try check(gpa, src_dash, toks_dash);
    defer gpa.free(vs_dash);
    var got_dash = false;
    for (vs_dash) |v| {
        if (v.danger != null and std.mem.eql(u8, v.ascii, "-")) got_dash = true;
    }
    try std.testing.expect(got_dash);

    const src_eli = "常数 丁 = 1;\u{2026}";
    const toks_eli = try lexer.scan(gpa, src_eli);
    defer gpa.free(toks_eli);
    const vs_eli = try check(gpa, src_eli, toks_eli);
    defer gpa.free(vs_eli);
    var got_eli = false;
    for (vs_eli) |v| {
        if (v.danger != null and std.mem.eql(u8, v.ascii, "...")) got_eli = true;
    }
    try std.testing.expect(got_eli);

    // 零宽空格 U+200B：无可见半角替换（ascii 为空），靠精确 label 传达“请删除”。
    const src_zw = "常数 戊\u{200B} = 5;";
    const toks_zw = try lexer.scan(gpa, src_zw);
    defer gpa.free(toks_zw);
    const vs_zw = try check(gpa, src_zw, toks_zw);
    defer gpa.free(vs_zw);
    var got_zw = false;
    for (vs_zw) |v| {
        if (v.danger != null and v.ascii.len == 0 and std.mem.indexOf(u8, v.hint, "零宽空格") != null) got_zw = true;
    }
    try std.testing.expect(got_zw);
}

test "不可见字符总网：未逐个登记的危险表外宽度空格与零宽格式字符仍给精确提示而非泛拒绝" {
    const gpa = std.testing.allocator;
    // 细空格 U+2009（不在危险表、不在 FF01–FF5E）作分隔：应归入不可见空格、建议半角为一个空格。
    const src_thin = "常数 甲 = 1;\n\u{2009}常数 乙 = 2;";
    const toks_thin = try lexer.scan(gpa, src_thin);
    defer gpa.free(toks_thin);
    const vs_thin = try check(gpa, src_thin, toks_thin);
    defer gpa.free(vs_thin);
    var got_thin = false;
    for (vs_thin) |v| {
        if (v.danger != null and std.mem.eql(u8, v.hint, "不可见空格") and std.mem.eql(u8, v.ascii, " ")) got_thin = true;
    }
    try std.testing.expect(got_thin);

    // 文件中部 BOM U+FEFF（stripBom 只处理起始）：应归零宽/格式类、无可见半角替换。
    const src_bom = "常数 甲 = 1;\n\u{FEFF}常数 乙 = 2;";
    const toks_bom = try lexer.scan(gpa, src_bom);
    defer gpa.free(toks_bom);
    const vs_bom = try check(gpa, src_bom, toks_bom);
    defer gpa.free(vs_bom);
    var got_bom = false;
    for (vs_bom) |v| {
        if (v.danger != null and v.ascii.len == 0 and std.mem.indexOf(u8, v.hint, "零宽/格式控制字符") != null) got_bom = true;
    }
    try std.testing.expect(got_bom);

    // 单词连接符 U+2060（隐形运算符区）：同样归零宽/格式类。
    const src_wj = "常数 甲 = 1;\n\u{2060}常数 乙 = 2;";
    const toks_wj = try lexer.scan(gpa, src_wj);
    defer gpa.free(toks_wj);
    const vs_wj = try check(gpa, src_wj, toks_wj);
    defer gpa.free(vs_wj);
    var got_wj = false;
    for (vs_wj) |v| {
        if (v.danger != null and v.ascii.len == 0 and std.mem.indexOf(u8, v.hint, "零宽/格式控制字符") != null) got_wj = true;
    }
    try std.testing.expect(got_wj);
}

test "CJK+ASCII 尾合并词元（变量1/甲1）不被误拒（白名单已放行标识符内 ASCII）" {
    const gpa = std.testing.allocator;
    // 合并后这些成为一个 nonascii_word 词元、内含 ASCII 数字：不应被判非法。
    const src = "常数 变量1: i64 = 甲1;";
    const toks = try lexer.scan(gpa, src);
    defer gpa.free(toks);
    const vs = try check(gpa, src, toks);
    defer gpa.free(vs);
    try std.testing.expectEqual(@as(usize, 0), vs.len);
}

test "CJK 名里夹全角数字（甲\u{FF11}）仍被兜底拦下（词元合并未漏放全角）" {
    const gpa = std.testing.allocator;
    // 甲 + 全角 １（U+FF11）：合并后为一个词元，全角数字仍应命中兜底提示。
    const src = "常数 甲\u{FF11}: i64 = 1;";
    const toks = try lexer.scan(gpa, src);
    defer gpa.free(toks);
    const vs = try check(gpa, src, toks);
    defer gpa.free(vs);
    try std.testing.expect(vs.len >= 1);
    var got = false;
    for (vs) |v| {
        if (v.danger != null and std.mem.eql(u8, v.hint, "全角数字")) got = true;
    }
    try std.testing.expect(got);
}

test "R7：首字节位图快跳——只跳专门扫描、绝不跳白名单（同形异体仍被拦）" {
    const gpa = std.testing.allocator;
    // 判据本身：常见汉字标识符（首字节 0xE4..0xE9）不含特征首字节→走快路径；含全角/危险首字节→慢路径。
    try std.testing.expect(!mayNeedSpecialCheck("变量"));
    try std.testing.expect(mayNeedSpecialCheck("甲\u{FF11}")); // 含全角数字（0xEF）
    try std.testing.expect(mayNeedSpecialCheck("甲\u{3000}")); // 含全角空格（0xE3）

    // 关键正确性：希腊同形字母 α（U+03B1，首字节 0xCE）不在位图内→ mayNeedSpecialCheck 为假（走快路径），
    // 但它非白名单合法字符——快路径只跳“危险/全角/不可见”三类，逐码点白名单仍必须拦下它（泛拒绝、danger 为 null）。
    try std.testing.expect(!mayNeedSpecialCheck("\u{03B1}"));
    const src = "常数 \u{03B1} \u{540d} = 1;"; // α名：α 非法、名 合法
    const toks = try lexer.scan(gpa, src);
    defer gpa.free(toks);
    const vs = try check(gpa, src, toks);
    defer gpa.free(vs);
    var got_homoglyph = false;
    for (vs) |v| {
        if (v.danger == null and std.mem.indexOf(u8, v.hint, "不允许出现在母语标识符中") != null) got_homoglyph = true;
    }
    try std.testing.expect(got_homoglyph);
}

test "区间白名单真边界：纯西里尔/与拉丁混排作方言文字放行，组合符与拉丁扩展泛拒（D35 失实注释更正后钉住现行语义）" {
    // 旧头注曾宣称「Unicode Letter 字母+组合符放行」「同形字符（含西里尔冒充）都会在此拦截」
    // 且引用不存在的「冲突表」——本测钉住更正后的真实防线：
    // ① 纯西里尔词元（р）∈ 0x400..0x4FF → 合法方言文字，无违规；
    const gpa = std.testing.allocator;
    const src_cyr = "常数 \u{0440} = 1;"; // р（Cyrillic）单独作标识符
    const toks_cyr = try lexer.scan(gpa, src_cyr);
    defer gpa.free(toks_cyr);
    const vs_cyr = try check(gpa, src_cyr, toks_cyr);
    defer gpa.free(vs_cyr);
    try std.testing.expectEqual(@as(usize, 0), vs_cyr.len);

    // ② 西里尔+拉丁混排（рrint）：冲突表未建、逐码点均合法 → 放行（by-design 缝隙正式建档；
    //    若未来真建冲突表，应作为新的消缺/特性同步改此测，而非静默翻转语义）。
    const src_mix = "常数 \u{0440}rint = 1;";
    const toks_mix = try lexer.scan(gpa, src_mix);
    defer gpa.free(toks_mix);
    const vs_mix = try check(gpa, src_mix, toks_mix);
    defer gpa.free(vs_mix);
    try std.testing.expectEqual(@as(usize, 0), vs_mix.len);

    // ③ 组合符 U+0301（旧注误称放行）：实落白名单外 → 泛拒（danger=null）；首字节 0xCC 不在
    //    R7 位图 → 走快路径仍被白名单拦住，与 α 同形防线同理。
    const src_comb = "常数 名\u{0301} = 1;";
    const toks_comb = try lexer.scan(gpa, src_comb);
    defer gpa.free(toks_comb);
    const vs_comb = try check(gpa, src_comb, toks_comb);
    defer gpa.free(vs_comb);
    var got_comb = false;
    for (vs_comb) |v| {
        if (v.danger == null and std.mem.indexOf(u8, v.hint, "不允许出现在母语标识符中") != null) got_comb = true;
    }
    try std.testing.expect(got_comb);

    // ④ 拉丁扩展 é（U+00E9，非 Unicode Letter 全放而系显式区间表）：同被泛拒。
    const src_e = "常数 caf\u{00e9} = 1;";
    const toks_e = try lexer.scan(gpa, src_e);
    defer gpa.free(toks_e);
    const vs_e = try check(gpa, src_e, toks_e);
    defer gpa.free(vs_e);
    var got_e = false;
    for (vs_e) |v| {
        if (v.danger == null) got_e = true;
    }
    try std.testing.expect(got_e);
}

// 护栏（第 115 轮证伪落位）：`fullwidthFormHint` 系纯函数、此前仅经 `check` 间接触达，且三类
// 划分中仅「全角数字」一类被断言（L389 测题虽称「数字/拉丁字母」实则只 got_digit）——「全角
// 拉丁字母」（大写 FF21..FF3A / 小写 FF41..FF5A）与「全角符号」两类 label、以及 halfwidth 映
// 射的真边界（区下界 FF01 含端、区上界 FF5E 含端、区外 null）零直调覆盖。危险表未列的全角
// 拉丁/符号形（如 Ａ/ａ/＄）在 check 里唯有本函数能给精确提示——独一防线。本测直调钉住三类
// 划分与逐字符半角映射（buf[i]=0x21+i、idx=cp-0xFF01），防分类边界/映射表被误改致静默降级为泛拒绝。
test "fullwidthFormHint 三类划分（数字/拉丁字母/符号）与半角映射真边界（危险表外全角变体兜底独一防线，第 115 轮）" {
    // ① 全角数字段 FF10..FF19 → label「全角数字」、半角=对应数字字符（FF15５ → '5'）。
    {
        const h = fullwidthFormHint("\u{FF15}") orelse return error.ExpectedHint;
        try std.testing.expectEqualStrings("全角数字", h.label);
        try std.testing.expectEqualStrings("5", h.ascii);
    }
    // ② 全角拉丁字母段（大写 FF21..FF3A、小写 FF41..FF5A）→ label「全角拉丁字母」——此两类不在危
    //    险表内、既有测从未触达其分支（证本测独有价值）。
    {
        const up = fullwidthFormHint("\u{FF21}") orelse return error.ExpectedHint; // Ａ
        try std.testing.expectEqualStrings("全角拉丁字母", up.label);
        try std.testing.expectEqualStrings("A", up.ascii); // idx=0xFF21-0xFF01=32 → 0x21+32='A'
        const lo = fullwidthFormHint("\u{FF41}") orelse return error.ExpectedHint; // ａ
        try std.testing.expectEqualStrings("全角拉丁字母", lo.label);
        try std.testing.expectEqualStrings("a", lo.ascii); // idx=64 → 0x61='a'
    }
    // ③ 其余全角符号段 → label「全角符号」；取区下界 FF01 与上界 FF5E 各钉端点闭区间 + 半角映射。
    {
        const low = fullwidthFormHint("\u{FF01}") orelse return error.ExpectedHint;
        try std.testing.expectEqualStrings("全角符号", low.label);
        try std.testing.expectEqualStrings("!", low.ascii); // 下界含端 idx=0 → 0x21 '!'
        const high = fullwidthFormHint("\u{FF5E}") orelse return error.ExpectedHint;
        try std.testing.expectEqualStrings("全角符号", high.label);
        try std.testing.expectEqualStrings("~", high.ascii); // 上界含端 idx=93 → 0x7E '~'
    }
    // ④ 区外（普通 CJK / 低于 FF01 / 高于 FF5E）→ null（不误触发全角兜底、交由白名单或合法放行）。
    try std.testing.expectEqual(null, fullwidthFormHint("\u{4E00}")); // 一：CJK、非全角变体区
    try std.testing.expectEqual(null, fullwidthFormHint("\u{FF00}")); // 区下界外一格
    try std.testing.expectEqual(null, fullwidthFormHint("\u{FF5F}")); // 区上界外一格
}

// 护栏（第 126 轮证伪落位）：头注 L6-10 声明「白名单系显式码点区间表、非 Unicode Letter 属性」，
// 但 isAllowedScalar 的**每条区间边界含端性**全库零直钉——D35 测只经 check 间接碰了西里尔内部的
// р（0x440，非边界）与假名区间外的 α/组合符；假名下界 0x3040、各区间上界与界外一格从未被碰。
// 区间被误改一格的两种翻转形须分别可拦：`>= 0x3040` 改 `>` → 真词元「ニ」被误拦（check 形抓）；
// `<= 0xFAFF` 改小 → 界外假字被误放（仅直调抓）。本测直钉全部 10 条非 ASCII 区间的下界含端/
// 上界含端/界外一格 + ASCII 白名单分支（字母数字下划线放行、空格 @ 及 Latin-1 À 泛拒）。
// 注：0xFEFF 在 isAllowedScalar 为 false（白名单拒），而 check 链里它先被危险表/不可见网接住——
// 两条函数语义不同、勿混。

test "isAllowedScalar 区间边界直钉：10 条非 ASCII 区间含端性与界外一格 + ASCII 分支（显式区间表声明的行为根源，第 126 轮证伪落位）" {
    // ① 假名 0x3040..0x30FF
    try std.testing.expect(isAllowedScalar(0x3040));
    try std.testing.expect(isAllowedScalar(0x30FF));
    try std.testing.expect(!isAllowedScalar(0x303F)); // 假名区下界外（中文标点〿区）
    try std.testing.expect(!isAllowedScalar(0x3100)); // 上界外（注音符号首部）
    // ② CJK 扩展 A 0x3400..0x4DBF
    try std.testing.expect(isAllowedScalar(0x3400));
    try std.testing.expect(isAllowedScalar(0x4DBF));
    try std.testing.expect(!isAllowedScalar(0x33FF));
    try std.testing.expect(!isAllowedScalar(0x4DC0)); // 上界外：易经卜卦符号
    // ③ CJK 统一汉字 0x4E00..0x9FFF
    try std.testing.expect(isAllowedScalar(0x4E00));
    try std.testing.expect(isAllowedScalar(0x9FFF));
    try std.testing.expect(!isAllowedScalar(0x4DFF));
    try std.testing.expect(!isAllowedScalar(0xA000)); // 上界外：彝文首部
    // ④ CJK 兼容汉字 0xF900..0xFAFF（本区间是「误放界外」唯一仅靠直调可拦的点位）
    try std.testing.expect(isAllowedScalar(0xF900));
    try std.testing.expect(isAllowedScalar(0xFAFF));
    try std.testing.expect(!isAllowedScalar(0xFEFF)); // 下界外：BOM（链路由不可见网接、函数层面仍拒）
    try std.testing.expect(!isAllowedScalar(0xFB00)); // 上界外：拉丁连字 ﬀ
    // ⑤ 谚文音节 0xAC00..0xD7AF
    try std.testing.expect(isAllowedScalar(0xAC00));
    try std.testing.expect(isAllowedScalar(0xD7AF));
    try std.testing.expect(!isAllowedScalar(0xABFF));
    try std.testing.expect(!isAllowedScalar(0xD7B0)); // 上界外：谚文兼容字母
    // ⑥ 谚文字母 0x1100..0x11FF
    try std.testing.expect(isAllowedScalar(0x1100));
    try std.testing.expect(isAllowedScalar(0x11FF));
    try std.testing.expect(!isAllowedScalar(0x10FF));
    try std.testing.expect(!isAllowedScalar(0x1200)); // 上界外：埃塞俄比亚文
    // ⑦ CJK 扩展 B-F 0x20000..0x2FA1F（平面 2+，多字节码点）
    try std.testing.expect(isAllowedScalar(0x20000));
    try std.testing.expect(isAllowedScalar(0x2FA1F));
    try std.testing.expect(!isAllowedScalar(0x1FFFF)); // 下界外：平面 1 末
    try std.testing.expect(!isAllowedScalar(0x2FA20)); // 上界外一格
    // ⑧ 西里尔 0x0400..0x04FF（D35 测只碰过内部 0x440，边界零直钉）
    try std.testing.expect(isAllowedScalar(0x0400));
    try std.testing.expect(isAllowedScalar(0x04FF));
    try std.testing.expect(!isAllowedScalar(0x03FF)); // 下界外：希腊扩展末
    try std.testing.expect(!isAllowedScalar(0x0500)); // 上界外：西里尔补充（真边界！）
    // ⑨ 阿拉伯 0x0600..0x06FF
    try std.testing.expect(isAllowedScalar(0x0600));
    try std.testing.expect(isAllowedScalar(0x06FF));
    try std.testing.expect(!isAllowedScalar(0x05FF));
    try std.testing.expect(!isAllowedScalar(0x0700)); // 上界外：叙利亚文
    // ⑩ 泰文 0x0E00..0x0E7F
    try std.testing.expect(isAllowedScalar(0x0E00));
    try std.testing.expect(isAllowedScalar(0x0E7F));
    try std.testing.expect(!isAllowedScalar(0x0DFF)); // 下界外：天城文末
    try std.testing.expect(!isAllowedScalar(0x0E80)); // 上界外：老挝文首
    // ⑪ 全角数字/字母/空格显式拦截（声明「非 Letter 全放」的锚点）：三条拦截段含端即拒，
    // 段间隙也落不到任何合法区间同样泛拒（首跑自捕：臆造「间隙放行」系错，白名单对 FF01..FF5E 全拒）。
    try std.testing.expect(!isAllowedScalar(0xFF10)); // 下界含端即拒
    try std.testing.expect(!isAllowedScalar(0xFF19));
    try std.testing.expect(!isAllowedScalar(0xFF21));
    try std.testing.expect(!isAllowedScalar(0xFF3A));
    try std.testing.expect(!isAllowedScalar(0xFF41));
    try std.testing.expect(!isAllowedScalar(0xFF5A));
    try std.testing.expect(!isAllowedScalar(0xFF20)); // 拦截段间隙（全角空格）：无任何区间命中 → 仍泛拒
    try std.testing.expect(!isAllowedScalar(0xFF3F)); // 拦截段间隙（全角下划线）：同上
    // ⑫ ASCII 分支：字母数字下划线放行、其余泛拒（0x00 与 0x7F 含端）
    try std.testing.expect(isAllowedScalar('a'));
    try std.testing.expect(isAllowedScalar('Z'));
    try std.testing.expect(isAllowedScalar('9'));
    try std.testing.expect(isAllowedScalar('_'));
    try std.testing.expect(!isAllowedScalar(' '));
    try std.testing.expect(!isAllowedScalar('@'));
    try std.testing.expect(!isAllowedScalar(0x00));
    try std.testing.expect(!isAllowedScalar(0x7F));
    try std.testing.expect(!isAllowedScalar(0x80)); // 下界外一格（首跑自捕：`cp < 0x80` 含端即 ASCII 分支，0x80 落不到任何合法区间→泛拒；假名区下界才是 `>=` 含端）
    try std.testing.expect(!isAllowedScalar(0xC0)); // Latin-1 补区首：非法码点亦泛拒（非 Letter 全放）

    // ⑬ check 真词元形：假名下界字「ニ」（U+3042）合法放行——`>= 0x3040` 误改 `>` 则此处 0x3040 形翻红
    {
        const gpa = std.testing.allocator;
        const src = "常数 \u{3042} = 1;";
        const toks = try lexer.scan(gpa, src);
        defer gpa.free(toks);
        const vs = try check(gpa, src, toks);
        defer gpa.free(vs);
        try std.testing.expectEqual(@as(usize, 0), vs.len);
    }
    // ⑭ check 真词元形：假名上界「ヿ」（U+30FF）同样放行（钉 0x30FF 含端）
    {
        const gpa = std.testing.allocator;
        const src = "常数 \u{30FF} = 1;";
        const toks = try lexer.scan(gpa, src);
        defer gpa.free(toks);
        const vs = try check(gpa, src, toks);
        defer gpa.free(vs);
        try std.testing.expectEqual(@as(usize, 0), vs.len);
    }
}

// 护栏（第 126 轮证伪落位）：L266 声明「审查所有 nonascii_word 词元……字符串/注释天然不参与」
// ——此豁免面全库零断言：既有全部测的 src 串/注释内皆无全角字符，若有人把入口 kind 条件放宽
//（如改只跳 .comment、或直接逐 token 全审），串内中文标点「说明，测试」会被当标识符审致工程
// 无法编译——现存 180 测无一能红（零防线）。另 L294「避免同一位置重复报错」的首命中 break 短路
//（每词元 ≤1 违规）亦无比照断言——现存测全用 >= 1 松形，删 break 后多危险符词元重复报错仍全绿；
// 而若短路误改成「只审首字节」（indexOf 位序判断形），甲０，１ 的首命中 ０ 形会翻红。
test "check 作用域与首命中短路：串/注释天然不参与、多危险符词元仅报首个（第 126 轮证伪落位）" {
    const gpa = std.testing.allocator;
    // ① 串与注释内的全角逗号/分号天然豁免：全词元合法 → 零违规（入口只审 nonascii_word）。
    {
        const src = "常数 甲 = \"说明，测试\"; // 备注，测试\n";
        const toks = try lexer.scan(gpa, src);
        defer gpa.free(toks);
        var n_nonascii: usize = 0;
        var n_other: usize = 0;
        for (toks) |t| {
            if (t.kind == .nonascii_word) n_nonascii += 1 else n_other += 1;
        }
        try std.testing.expect(n_other >= 2); // 串与注释确实成了词元（非被空白折叠掉）
        const vs = try check(gpa, src, toks);
        defer gpa.free(vs);
        try std.testing.expectEqual(@as(usize, 0), vs.len);
    }
    // ② 同一词元内混含 danger 表字符与仅全角变体区字符（甲０，１）：０/１ 全角数字**不在** dangers 表、
    // 而 ， 在 → danger 扫描优先命中 ，（非词元内位置序、非兼顾 fullwidthFormHint）——钉住「danger 表
    // 优先于全角变体兜底网」的分层顺序（若有人把 fullwidthFormHint 提到 danger 环前、本形会改报全角数字）。
    {
        const src = "常数 \u{7532}\u{FF10}\u{FF0C}\u{FF11} = 1;";
        const toks = try lexer.scan(gpa, src);
        defer gpa.free(toks);
        const vs = try check(gpa, src, toks);
        defer gpa.free(vs);
        try std.testing.expectEqual(@as(usize, 1), vs.len);
        try std.testing.expectEqualStrings("全角逗号", vs[0].hint); // danger 扫描序命中 ，（非首字符 ０、非 fullwidthFormHint）
        try std.testing.expectEqualStrings(",", vs[0].ascii);
        try std.testing.expect(vs[0].danger != null);
    }
    // ③ 同词元含**两个 danger 表字符**（名；，）：首命中；（表内序：；在，前、L31<L32）即 break、仅报 1 条——钉 break 短路（
    // 删 break 则 dangers 环续扫再命中 ， → 叠为 2 条→ 本形翻红；因②的 ０/１ 不在表、不足以钩 break、故新增本形）。
    {
        const src = "常数 \u{540d}\u{FF1B}\u{FF0C} = 1;"; // 名 + 全角分号 + 全角逗号
        const toks = try lexer.scan(gpa, src);
        defer gpa.free(toks);
        const vs = try check(gpa, src, toks);
        defer gpa.free(vs);
        try std.testing.expectEqual(@as(usize, 1), vs.len); // 删 break 则此处 2 形翻红
        try std.testing.expectEqualStrings("全角分号", vs[0].hint); // 表序：；(L31) 在 ，(L32) 前→首命中 ；
        try std.testing.expectEqualStrings(";", vs[0].ascii);
    }
}

// 护栏（第 176 轮证伪落位）：`invisibleFormHint`（L193·仅经 `check` L311 间接触达、全仓零直调）
// 依赖两个私有纯谓词 `isInvisibleSpace`（L157）/ `isZeroWidthFormat`（L172）划分「不可见字符总网」的
// 两类归属——空格类→提示「改用半角空格」（ascii=" "）、零宽/格式类→提示「请删除」（ascii=""）；二者皆
// 不落的字符透传给逐码点白名单泛拒（对肉眼不可见字符极为误导）。第 126 轮直钉了 `isAllowedScalar` 与
// `fullwidthFormHint` 的边界，但这两个 switch 集合的每条区间含端性、界外一格、两集互斥、以及 0x2065
// 间隙全库零直钉：现有测仅经 `check` 碰了 U+2009/U+FEFF/U+2060/U+200B 四个代表点。误删某区间端点（如
// 把 0x205F 那格漏出、或将 0x202A...0x202E 收窄）即令该不可见字符静默降级为泛白名单拒绝、无测可红。
// 本测直调逐点钉两集含端/界外一格 + 邻域全扫互斥不变量 + 0x2065 双假间隙。
test "isInvisibleSpace/isZeroWidthFormat 不可见字符总网双集合边界直钉：区间含端性 + 界外一格 + 两集互斥 + 0x2065 间隙（invisibleFormHint 独一判据、零直调，第 176 轮证伪落位）" {
    // isInvisibleSpace 集合成员（逐点含端 + 界外一格）
    try std.testing.expect(isInvisibleSpace(0x1680)); // 欧甘空格（孤立点）
    try std.testing.expect(!isInvisibleSpace(0x167F));
    try std.testing.expect(!isInvisibleSpace(0x1681));
    try std.testing.expect(isInvisibleSpace(0x2000)); // EN QUAD 下界含端
    try std.testing.expect(isInvisibleSpace(0x2005)); // 区间内部
    try std.testing.expect(isInvisibleSpace(0x200A)); // HAIR SPACE 上界含端
    try std.testing.expect(!isInvisibleSpace(0x200B)); // 上界外一格（此点属零宽集、非空格集）
    try std.testing.expect(isInvisibleSpace(0x2028)); // 行分隔符
    try std.testing.expect(isInvisibleSpace(0x2029)); // 段分隔符
    try std.testing.expect(!isInvisibleSpace(0x2027));
    try std.testing.expect(!isInvisibleSpace(0x202A)); // 此点属零宽集
    try std.testing.expect(isInvisibleSpace(0x202F)); // 窄不间断空格（孤立点）
    try std.testing.expect(!isInvisibleSpace(0x202E));
    try std.testing.expect(!isInvisibleSpace(0x2030));
    try std.testing.expect(isInvisibleSpace(0x205F)); // 中数学空格（孤立点）
    try std.testing.expect(!isInvisibleSpace(0x205E));
    try std.testing.expect(!isInvisibleSpace(0x2060)); // 此点属零宽集
    try std.testing.expect(!isInvisibleSpace('a')); // 非本集合的普通/字母/汉字码点恒假
    try std.testing.expect(!isInvisibleSpace(0x4E00));

    // isZeroWidthFormat 集合成员（逐点含端 + 界外一格）
    try std.testing.expect(isZeroWidthFormat(0x00AD)); // 软连字符
    try std.testing.expect(!isZeroWidthFormat(0x00AC));
    try std.testing.expect(!isZeroWidthFormat(0x00AE));
    try std.testing.expect(isZeroWidthFormat(0x180E)); // 蒙古元音分隔符
    try std.testing.expect(!isZeroWidthFormat(0x180D));
    try std.testing.expect(!isZeroWidthFormat(0x180F));
    try std.testing.expect(isZeroWidthFormat(0x200B)); // 零宽空格
    try std.testing.expect(isZeroWidthFormat(0x200C));
    try std.testing.expect(isZeroWidthFormat(0x200D)); // 零宽连字
    try std.testing.expect(isZeroWidthFormat(0x200E));
    try std.testing.expect(isZeroWidthFormat(0x200F)); // 右到左标记
    try std.testing.expect(!isZeroWidthFormat(0x2010)); // 区间上界外一格
    try std.testing.expect(isZeroWidthFormat(0x202A)); // bidi 嵌入下界含端
    try std.testing.expect(isZeroWidthFormat(0x202C)); // 内部
    try std.testing.expect(isZeroWidthFormat(0x202E)); // bidi 覆盖上界含端
    try std.testing.expect(!isZeroWidthFormat(0x2029)); // 下界外一格（属空格集）
    try std.testing.expect(!isZeroWidthFormat(0x202F)); // 上界外一格（属空格集）
    try std.testing.expect(isZeroWidthFormat(0x2060)); // 单词连接符下界含端
    try std.testing.expect(isZeroWidthFormat(0x2062)); // 内部
    try std.testing.expect(isZeroWidthFormat(0x2064)); // 隐形运算符上界含端
    try std.testing.expect(!isZeroWidthFormat(0x2065)); // ★间隙：两集皆不含（2060-2064 / 2066-2069 留空 2065）
    try std.testing.expect(isZeroWidthFormat(0x2066)); // bidi 隔离下界含端
    try std.testing.expect(isZeroWidthFormat(0x2069)); // 上界含端
    try std.testing.expect(!isZeroWidthFormat(0x206A)); // 界外一格
    try std.testing.expect(!isZeroWidthFormat(0x205F)); // 下界外（属空格集）
    try std.testing.expect(isZeroWidthFormat(0xFEFF)); // BOM / 零宽不换行空格
    try std.testing.expect(!isZeroWidthFormat(0xFE00));
    try std.testing.expect(!isZeroWidthFormat('a'));

    // 两集互斥不变量：邻域全扫不得同时为真（若误把某点并入两集，invisibleFormHint 先判空格类会掩盖零宽语义）
    for (0x1600..0x2100) |cp| {
        const p: u21 = @intCast(cp);
        try std.testing.expect(!(isInvisibleSpace(p) and isZeroWidthFormat(p)));
    }
    // 0x2065 间隙双向坐实：既非空格亦非零宽（防有人补区间补过头把 2065 误并入致语义漂移）
    try std.testing.expect(!isInvisibleSpace(0x2065));
    try std.testing.expect(!isZeroWidthFormat(0x2065));
}

// 护栏（第 176 轮证伪落位）：`invisibleFormHint` 全仓零直调（仅经 `check` L311 间接触达）。既有测经
// `check` 只喂空格/零宽各代表点、且从未断言其返回结构 FwHint 的 at/len/danger/ascii/label 五字段真形。
// 本测直调钉住三类分派与首命中：①空格类→ascii " "、label「不可见空格」；②零宽类→ascii ""、label 含
// 「零宽/格式控制字符」；③正常/合法词元→null（交由白名单或放行）；④词元内含多个不可见字符取首个（字节偏移 at 精确）。
test "invisibleFormHint 分派与首命中直钉：空格类→半角空格、零宽类→空替换、正常词元→null（check 不可见总网独一防线、零直调，第 176 轮证伪落位）" {
    // ① 空格类（U+205F 中数学空格、不在危险表也不在全角变体区）→「不可见空格」、建议半角一个空格
    {
        const h = invisibleFormHint("\u{205F}") orelse return error.ExpectedHint;
        try std.testing.expectEqualStrings("不可见空格", h.label);
        try std.testing.expectEqualStrings(" ", h.ascii);
        try std.testing.expectEqual(@as(usize, 0), h.at);
        try std.testing.expectEqual(@as(usize, 3), h.len); // U+205F = E2 81 9F（3 字节）
        try std.testing.expectEqualStrings("\u{205F}", h.danger);
    }
    // ② 零宽/格式类（U+200D 零宽连字）→无可见半角替换（ascii 空）、label 含「零宽/格式控制字符」
    {
        const h = invisibleFormHint("\u{200D}") orelse return error.ExpectedHint;
        try std.testing.expectEqual(@as(usize, 0), h.ascii.len);
        try std.testing.expect(std.mem.indexOf(u8, h.label, "零宽/格式控制字符") != null);
        try std.testing.expectEqual(@as(usize, 3), h.len); // U+200D = E2 80 8D
    }
    // ③ 正常 CJK 词元无可命中 → null（不误触发不可见网、交由白名单放行合法汉字）
    try std.testing.expect(invisibleFormHint("\u{4E00}\u{4E8C}") == null);
    // ④ 首命中字节偏移：「名」(E5 90 8D，3 字节) 后接零宽空格 U+200B → at=3、len=3、归零宽类
    {
        const h = invisibleFormHint("\u{540D}\u{200B}") orelse return error.ExpectedHint;
        try std.testing.expectEqual(@as(usize, 3), h.at);
        try std.testing.expectEqual(@as(usize, 3), h.len);
        try std.testing.expect(std.mem.indexOf(u8, h.label, "零宽/格式控制字符") != null);
    }
    // ⑤ 首命中位置优先：词元同时含空格类 U+205F（首）与后随零宽 U+200B，须返回首个（空格类、at=0）
    {
        const h = invisibleFormHint("\u{205F}\u{200B}") orelse return error.ExpectedHint;
        try std.testing.expectEqual(@as(usize, 0), h.at);
        try std.testing.expectEqualStrings("不可见空格", h.label);
    }
}
