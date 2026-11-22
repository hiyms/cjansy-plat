// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 单个文件的表示：内容缓冲、附加信息、换行缓存，以及文件的可编辑性。

const std = @import("std");
const LineIndex = @import("LineIndex.zig").LineIndex;

/// 文件的附加信息。
///
/// 所有字符串与哈希表的键都是切片，`Source` 在创建文件时一律深拷贝一份
/// （`clone`），因此调用方传完之后可以立即释放。
pub const FileExtraInfo = struct {
    /// 期望的包名约束，空表示不约束。
    requirePackageName: ?PackageNameConstraint = null,
    /// 特性开关，键与值都由本结构持有。
    features: std.StringHashMapUnmanaged(bool) = .empty,
    typ: FileType = .Source,

    /// 深拷贝。所有字符串与 `features` 的键都重新分配，返回的结构由调用方释放。
    ///
    /// 中途分配失败时已经复制的部分会释放，不留下半初始化的结果。
    pub fn clone(self: FileExtraInfo, gpa: std.mem.Allocator) std.mem.Allocator.Error!FileExtraInfo {
        var result: FileExtraInfo = .{ .typ = self.typ };
        errdefer result.deinit(gpa);

        if (self.requirePackageName) |constraint| {
            result.requirePackageName = try constraint.clone(gpa);
        }

        if (self.features.count() > 0) {
            try result.features.ensureTotalCapacity(gpa, self.features.count());
            var it = self.features.keyIterator();
            while (it.next()) |key| {
                const owned_key = try gpa.dupe(u8, key.*);
                result.features.putAssumeCapacity(owned_key, self.features.get(key.*).?);
            }
        }
        return result;
    }

    /// 释放 `clone` 分配的全部内存，并把结构置为未定义状态。
    pub fn deinit(self: *FileExtraInfo, gpa: std.mem.Allocator) void {
        if (self.requirePackageName) |*constraint| constraint.deinit(gpa);
        var it = self.features.keyIterator();
        while (it.next()) |key| gpa.free(key.*);
        self.features.deinit(gpa);
        self.* = undefined;
    }
};

/// 包名约束：`org` 为组织名，`root_package` 为根包名，`sub_package` 为子包路径。
///
/// 三个字段都是切片，所有权规则与 `FileExtraInfo` 一致：交给 `Source` 之前由调用方持有
/// 原有内存，`Source` 内部持有的是 `clone` 的副本。
pub const PackageNameConstraint = struct {
    org: ?[]const u8 = null,
    root_package: []const u8,
    sub_package: ?[][]const u8 = null,

    /// 深拷贝三个字段。`root_package` 必填，`org` 与 `sub_package` 为空表示未指定。
    pub fn clone(self: PackageNameConstraint, gpa: std.mem.Allocator) std.mem.Allocator.Error!PackageNameConstraint {
        var result: PackageNameConstraint = .{ .root_package = "" };
        errdefer result.deinit(gpa);

        result.root_package = try gpa.dupe(u8, self.root_package);
        if (self.org) |org| result.org = try gpa.dupe(u8, org);
        if (self.sub_package) |sub| {
            const owned = try gpa.alloc([]const u8, sub.len);
            result.sub_package = owned;
            var filled: usize = 0;
            errdefer {
                for (owned[0..filled]) |item| gpa.free(item);
                gpa.free(owned);
                result.sub_package = null;
            }
            for (sub, 0..) |item, i| {
                owned[i] = try gpa.dupe(u8, item);
                filled = i + 1;
            }
        }
        return result;
    }

    /// 释放 `clone` 分配的全部内存。
    pub fn deinit(self: *PackageNameConstraint, gpa: std.mem.Allocator) void {
        if (self.org) |org| gpa.free(org);
        gpa.free(self.root_package);
        if (self.sub_package) |sub| {
            for (sub) |item| gpa.free(item);
            gpa.free(sub);
        }
        self.* = undefined;
    }
};

/// 文件类型。
/// - `Source`: 源文件
/// - `Header`: 不包含具体代码的索引文件
pub const FileType = enum { Source, Header };

/// 文件的可编辑性。
///
/// 两类文件的存储形状完全相同，差别只在于 `Source.applyEdits` 的入口检查，因此相互
/// 转换只需要修改一个字段，不需要重建内容或丢弃换行缓存。
pub const FileKind = enum {
    /// 工作区文件，允许应用 Edit。
    workspace,
    /// 非工作区文件，内容在程序运行期间不变。只允许从磁盘载入或在创建时给定内容。
    external,
};

/// 单个文件。由 `Source` 独占持有，写入只能通过 `Source.applyEdits`。
pub const File = struct {
    kind: FileKind,
    /// 规范化之后的绝对路径；未关联磁盘的工作区文件为 null。非空时与
    /// `Source.path_index` 中的键是同一块内存。
    path: ?[]const u8 = null,
    extra: FileExtraInfo,
    /// 文本内容。`len` 是当前长度，容量供编辑预留。
    ///
    /// 编辑会移动后续字节，因此之前取得的切片在 `applyEdits` 之后全部失效。
    text: std.ArrayListUnmanaged(u8) = .empty,
    /// 每次成功应用一批 Edit 递增。调用方可以拿它做缓存失效的判据。
    version: u32 = 0,
    /// 换行缓存，与 `text` 一同维护。
    line_index: LineIndex = .{},

    /// 当前文本。切片在使用期间只读；再次编辑之后需要重新取得。
    pub fn content(self: *const File) []const u8 {
        return self.text.items;
    }

    /// 释放内容缓冲、换行缓存、附加信息与路径。
    pub fn deinit(self: *File, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        self.line_index.deinit(gpa);
        self.extra.deinit(gpa);
        if (self.path) |path| gpa.free(path);
        self.* = undefined;
    }
};

test "FileExtraInfo 深拷贝" {
    const gpa = std.testing.allocator;

    var raw_features: std.StringHashMapUnmanaged(bool) = .empty;
    defer raw_features.deinit(gpa);
    const key = try gpa.dupe(u8, "compiler");
    try raw_features.put(gpa, key, true);

    var sub = try gpa.alloc([]const u8, 1);
    sub[0] = "inner";

    const raw: FileExtraInfo = .{
        .requirePackageName = .{ .org = "myorg", .root_package = "root", .sub_package = sub },
        .features = raw_features,
        .typ = .Header,
    };

    var cloned = try raw.clone(gpa);
    defer cloned.deinit(gpa);

    // 原始数据全部失效之后，克隆仍然可以读取
    gpa.free(key);
    gpa.free(sub);

    try std.testing.expectEqual(FileType.Header, cloned.typ);
    try std.testing.expectEqualStrings("myorg", cloned.requirePackageName.?.org.?);
    try std.testing.expectEqualStrings("root", cloned.requirePackageName.?.root_package);
    try std.testing.expectEqualStrings("inner", cloned.requirePackageName.?.sub_package.?[0]);
    try std.testing.expectEqual(true, cloned.features.get("compiler").?);
}
