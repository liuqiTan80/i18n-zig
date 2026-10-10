//! 语言包管理模块

const std = @import("std");
const Pack = @import("pack.zig");

/// 语言包注册表
pub const Registry = struct {
    gpa: std.mem.Allocator,
    packs: std.ArrayList(Pack),

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{
            .gpa = gpa,
            .packs = std.ArrayList(Pack).init(gpa),
        };
    }

    pub fn deinit(self: *Registry) void {
        for (self.packs.items) |*pack| {
            pack.deinit();
        }
        self.packs.deinit(self.gpa);
    }

    /// 注册一个语言包
    pub fn register(self: *Registry, pack: Pack) !void {
        try self.packs.append(pack);
    }

    /// 根据语言代码查找语言包
    pub fn findByCode(self: Registry, code: []const u8) ?*const Pack {
        for (self.packs.items) |*pack| {
            if (std.mem.eql(u8, pack.code, code)) return pack;
        }
        return null;
    }

    /// 根据语言名称查找语言包
    pub fn findByName(self: Registry, name: []const u8) ?*const Pack {
        for (self.packs.items) |*pack| {
            if (std.mem.eql(u8, pack.name, name)) return pack;
        }
        return null;
    }

    /// 获取所有已注册的语言包
    pub fn getAll(self: Registry) []const Pack {
        return self.packs.items;
    }

    /// 获取语言包数量
    pub fn count(self: Registry) usize {
        return self.packs.items.len;
    }
};

/// 语言包加载器
pub const Loader = struct {
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Loader {
        return .{ .gpa = gpa };
    }

    /// 从文件路径加载语言包
    pub fn fromFile(self: Loader, path: []const u8) !Pack {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file.close();

        const size = try file.getEndPos();
        const bytes = try self.gpa.alloc(u8, size);
        errdefer self.gpa.free(bytes);

        const bytes_read = try file.readAll(bytes);
        if (bytes_read != size) return error.Unexpected;

        return try Pack.parse(self.gpa, bytes);
    }

    /// 从字节流加载语言包
    pub fn fromBytes(self: Loader, bytes: []const u8) !Pack {
        return try Pack.parse(self.gpa, bytes);
    }

    /// 加载内置语言包
    pub fn loadBuiltin(self: Loader, name: []const u8) !?Pack {
        if (std.mem.eql(u8, name, "中文") or std.mem.eql(u8, name, "zh")) {
            const zh_pack = @embedFile("packs/中文.txt");
            return try self.fromBytes(zh_pack);
        }
        // 可扩展其他内置语言
        return null;
    }
};

/// 语言包验证器
pub const Validator = struct {
    /// 验证语言包格式
    pub fn validate(pack: Pack) error{InvalidFormat}!void {
        // 检查必需字段
        if (pack.name.len == 0) return error.InvalidFormat;
        if (pack.code.len == 0) return error.InvalidFormat;

        // 检查关键字表
        var kw_iter = pack.keywords.iterator();
        while (kw_iter.next()) |entry| {
            if (entry.key_ptr.*.len == 0) return error.InvalidFormat;
            if (entry.value_ptr.*.len == 0) return error.InvalidFormat;
        }

        // 检查别名表
        var alias_iter = pack.aliases.iterator();
        while (alias_iter.next()) |entry| {
            if (entry.key_ptr.*.len == 0) return error.InvalidFormat;
            if (entry.value_ptr.*.len == 0) return error.InvalidFormat;
        }

        // 检查诊断模式
        for (pack.diagnostics.items) |diag| {
            if (diag.pattern.len == 0) return error.InvalidFormat;
            if (diag.message.len == 0) return error.InvalidFormat;
        }
    }

    /// 验证语言包是否包含必需的关键字
    pub fn validateRequiredKeywords(pack: Pack, required: []const []const u8) bool {
        for (required) |kw| {
            if (pack.keywords.get(kw) == null) return false;
        }
        return true;
    }

    /// 验证语言包是否包含重复的诊断模式
    pub fn validateNoDuplicatePatterns(pack: Pack) bool {
        for (pack.diagnostics.items, 0..) |diag1, i| {
            for (pack.diagnostics.items[i + 1 ..]) |diag2| {
                if (std.mem.eql(u8, diag1.pattern, diag2.pattern)) return false;
            }
        }
        return true;
    }
};