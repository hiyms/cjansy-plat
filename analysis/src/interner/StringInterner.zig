// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 全局字符串驻留池与模块/包路径前缀树。

const std = @import("std");
const ids = @import("../ids.zig");

const InternedId = ids.InternedId;
const ModuleId = ids.ModuleId;
const PackageId = ids.PackageId;

/// 全局永久字符串驻留池（随 `Database.deinit` 统一释放）。
///
/// 仅用于驻留标识符、包路径段、组织名与文档注释正文；不得将每次编辑临时拼装的动态诊断消息写入驻留池。
pub const StringInterner = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(InternedId) = .empty,
    strings: std.ArrayListUnmanaged([]const u8) = .empty,

    /// 初始化字符串驻留池。
    pub fn init(gpa: std.mem.Allocator) StringInterner {
        return .{
            .gpa = gpa,
            .arena = .init(gpa),
        };
    }

    /// 释放驻留池及内部全部字符串内存。
    pub fn deinit(self: *StringInterner) void {
        self.map.deinit(self.gpa);
        self.strings.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// 驻留字节切片并返回稳定的 `InternedId`；已存在相同文本时直接返回既有句柄。
    pub fn intern(self: *StringInterner, text: []const u8) std.mem.Allocator.Error!InternedId {
        if (self.map.get(text)) |existing| return existing;
        const owned = try self.arena.allocator().dupe(u8, text);
        const id = InternedId.fromIndex(@intCast(self.strings.items.len));
        try self.strings.ensureUnusedCapacity(self.gpa, 1);
        try self.map.put(self.gpa, owned, id);
        self.strings.appendAssumeCapacity(owned);
        return id;
    }

    /// 只读查找已驻留文本；不存在返回 `null`。
    pub fn lookup(self: *const StringInterner, text: []const u8) ?InternedId {
        return self.map.get(text);
    }

    /// 按 `InternedId` 在 `O(1)` 时间内获取只读文本切片；返回切片借用自内部 `arena`，调用者不得释放。
    pub inline fn get(self: *const StringInterner, id: InternedId) []const u8 {
        return self.strings.items[id.index()];
    }

    /// 返回当前已驻留的字符串总数。
    pub inline fn count(self: *const StringInterner) usize {
        return self.strings.items.len;
    }
};

/// 单个包的完整路径元信息。
pub const PackageInfo = struct {
    id: PackageId,
    module_id: ModuleId,
    org: ?InternedId,
    parent: ?PackageId,
    segments: []const InternedId,
};

/// 模块元信息，唯一对应 `(org, root_pkg)`。
pub const ModuleInfo = struct {
    id: ModuleId,
    org: ?InternedId,
    root_name: InternedId,
    root_pkg: PackageId,
};

/// 调用方包相对于目标包的层级关系。
pub const PackageRelation = enum(u8) {
    same_package,
    /// 调用方 `package` 是目标 `package` 的后代子包（`target` 是 `src` 的真前缀）。
    child_of_target,
    /// 调用方 `package` 是目标 `package` 的直接上一层父包（支撑 `internal package` 规则）。
    direct_parent_of_target,
    same_module,
    unrelated,
};

const RootKey = struct {
    org: ?InternedId,
    root_name: InternedId,
};

const ChildKey = struct {
    parent: PackageId,
    segment: InternedId,
};

/// 维护模块与包路径前缀树，提供 `O(1)` 父包查询与子包前缀判定。
pub const PackageInterner = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    modules: std.ArrayListUnmanaged(ModuleInfo) = .empty,
    packages: std.ArrayListUnmanaged(PackageInfo) = .empty,
    root_map: std.AutoHashMapUnmanaged(RootKey, PackageId) = .empty,
    child_map: std.AutoHashMapUnmanaged(ChildKey, PackageId) = .empty,

    /// 初始化模块与包路径驻留前缀树。
    pub fn init(gpa: std.mem.Allocator) PackageInterner {
        return .{
            .gpa = gpa,
            .arena = .init(gpa),
        };
    }

    /// 释放前缀树及内部全部包元信息内存。
    pub fn deinit(self: *PackageInterner) void {
        self.modules.deinit(self.gpa);
        self.packages.deinit(self.gpa);
        self.root_map.deinit(self.gpa);
        self.child_map.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// 驻留 `(org, segments)` 路径，自动补齐路径上缺失的祖先 `PackageId` 与 `ModuleId`。
    /// 要求 `segments.len >= 1`。
    pub fn internPackage(
        self: *PackageInterner,
        org: ?InternedId,
        segments: []const InternedId,
    ) std.mem.Allocator.Error!PackageId {
        std.debug.assert(segments.len > 0);
        const root_key: RootKey = .{ .org = org, .root_name = segments[0] };
        var cur_pkg: PackageId = undefined;
        var module_id: ModuleId = undefined;

        if (self.root_map.get(root_key)) |existing_root| {
            cur_pkg = existing_root;
            module_id = self.packages.items[existing_root.index()].module_id;
        } else {
            const root_segs = try self.arena.allocator().dupe(InternedId, segments[0..1]);
            module_id = ModuleId.fromIndex(@intCast(self.modules.items.len));
            cur_pkg = PackageId.fromIndex(@intCast(self.packages.items.len));

            try self.modules.ensureUnusedCapacity(self.gpa, 1);
            try self.packages.ensureUnusedCapacity(self.gpa, 1);
            try self.root_map.put(self.gpa, root_key, cur_pkg);
            self.modules.appendAssumeCapacity(.{
                .id = module_id,
                .org = org,
                .root_name = segments[0],
                .root_pkg = cur_pkg,
            });
            self.packages.appendAssumeCapacity(.{
                .id = cur_pkg,
                .module_id = module_id,
                .org = org,
                .parent = null,
                .segments = root_segs,
            });
        }

        for (segments[1..], 1..) |seg, depth| {
            const child_key: ChildKey = .{ .parent = cur_pkg, .segment = seg };
            if (self.child_map.get(child_key)) |existing_child| {
                cur_pkg = existing_child;
                continue;
            }
            const prefix = try self.arena.allocator().dupe(InternedId, segments[0 .. depth + 1]);
            const next_pkg = PackageId.fromIndex(@intCast(self.packages.items.len));
            try self.packages.ensureUnusedCapacity(self.gpa, 1);
            try self.child_map.put(self.gpa, child_key, next_pkg);
            self.packages.appendAssumeCapacity(.{
                .id = next_pkg,
                .module_id = module_id,
                .org = org,
                .parent = cur_pkg,
                .segments = prefix,
            });
            cur_pkg = next_pkg;
        }
        return cur_pkg;
    }

    /// 只读查找已有包路径；不存在返回 `null`。
    pub fn lookupPackage(self: *const PackageInterner, org: ?InternedId, segments: []const InternedId) ?PackageId {
        if (segments.len == 0) return null;
        var cur = self.root_map.get(.{ .org = org, .root_name = segments[0] }) orelse return null;
        for (segments[1..]) |seg| {
            cur = self.child_map.get(.{ .parent = cur, .segment = seg }) orelse return null;
        }
        return cur;
    }

    /// 按 `PackageId` 获取包元信息；返回指针借用自内部容器，在下次 `internPackage` 扩容或 `deinit` 前有效，调用者不得释放。
    pub inline fn getPackage(self: *const PackageInterner, id: PackageId) *const PackageInfo {
        return &self.packages.items[id.index()];
    }

    /// 校验 `PackageId` 下标合法性并获取只读包元信息；越界返回 `null`。
    /// 返回指针借用自内部容器，在下次 `internPackage` 扩容或 `deinit` 前有效，调用者不得释放。
    pub inline fn tryGetPackage(self: *const PackageInterner, id: PackageId) ?*const PackageInfo {
        const idx = id.index();
        return if (idx < self.packages.items.len) &self.packages.items[idx] else null;
    }

    /// 返回当前已驻留的包总数。
    pub inline fn packageCount(self: *const PackageInterner) usize {
        return self.packages.items.len;
    }

    /// 判定 `pkg` 是否等于 `ancestor` 或为 `ancestor` 的后代子包。
    pub fn isSameOrSubPackage(self: *const PackageInterner, pkg: PackageId, ancestor: PackageId) bool {
        if (pkg == ancestor) return true;
        const p_info = self.getPackage(pkg);
        const a_info = self.getPackage(ancestor);
        if (p_info.module_id != a_info.module_id) return false;
        if (p_info.segments.len < a_info.segments.len) return false;
        var cur: ?PackageId = pkg;
        while (cur) |c| {
            if (c == ancestor) return true;
            cur = self.getPackage(c).parent;
        }
        return false;
    }

    /// 判定 `parent` 是否为 `child` 的直接上一层父包。
    pub inline fn isDirectParent(self: *const PackageInterner, parent: PackageId, child: PackageId) bool {
        return self.getPackage(child).parent == parent;
    }

    /// 判定 `src` 相对于 `target` 的包层级关系。
    pub fn relation(self: *const PackageInterner, src: PackageId, target: PackageId) PackageRelation {
        if (src == target) return .same_package;
        const src_info = self.getPackage(src);
        const tgt_info = self.getPackage(target);
        if (src_info.module_id != tgt_info.module_id) return .unrelated;
        if (self.isDirectParent(src, target)) return .direct_parent_of_target;
        if (self.isSameOrSubPackage(src, target)) return .child_of_target;
        return .same_module;
    }

    /// 列举指定父包下的直接子包（`parent == null` 时列举全部根包）。
    /// 返回切片由调用者传入的 `alloc` 分配，结束后须由调用者通过 `alloc.free` 释放。
    pub fn listDirectChildren(
        self: *const PackageInterner,
        alloc: std.mem.Allocator,
        parent: ?PackageId,
    ) std.mem.Allocator.Error![]PackageId {
        var out: std.ArrayListUnmanaged(PackageId) = .empty;
        errdefer out.deinit(alloc);
        for (self.packages.items) |info| {
            if (info.parent == parent) {
                try out.append(alloc, info.id);
            }
        }
        return out.toOwnedSlice(alloc);
    }
};

test "StringInterner 驻留与去重" {
    const gpa = std.testing.allocator;
    var interner = StringInterner.init(gpa);
    defer interner.deinit();

    const a1 = try interner.intern("foo");
    const b1 = try interner.intern("bar");
    const a2 = try interner.intern("foo");
    try std.testing.expectEqual(a1, a2);
    try std.testing.expect(a1 != b1);
    try std.testing.expectEqualStrings("foo", interner.get(a1));
    try std.testing.expectEqual(b1, interner.lookup("bar").?);
    try std.testing.expect(interner.lookup("baz") == null);
}

test "PackageInterner 模块隔离与父子包关系判定" {
    const gpa = std.testing.allocator;
    var strings = StringInterner.init(gpa);
    defer strings.deinit();
    var pkgs = PackageInterner.init(gpa);
    defer pkgs.deinit();

    const s_org1 = try strings.intern("org1");
    const s_org2 = try strings.intern("org2");
    const s_a = try strings.intern("a");
    const s_b = try strings.intern("b");
    const s_c = try strings.intern("c");
    const s_d = try strings.intern("d");

    const p_a = try pkgs.internPackage(null, &.{s_a});
    const p_ab = try pkgs.internPackage(null, &.{ s_a, s_b });
    const p_abc = try pkgs.internPackage(null, &.{ s_a, s_b, s_c });
    const p_ad = try pkgs.internPackage(null, &.{ s_a, s_d });
    const p_org1_a = try pkgs.internPackage(s_org1, &.{s_a});
    const p_org2_a = try pkgs.internPackage(s_org2, &.{s_a});

    try std.testing.expectEqual(PackageRelation.same_package, pkgs.relation(p_a, p_a));
    try std.testing.expectEqual(PackageRelation.child_of_target, pkgs.relation(p_abc, p_a));
    try std.testing.expectEqual(PackageRelation.direct_parent_of_target, pkgs.relation(p_a, p_ab));
    try std.testing.expectEqual(PackageRelation.same_module, pkgs.relation(p_a, p_abc));
    try std.testing.expectEqual(PackageRelation.same_module, pkgs.relation(p_ab, p_ad));
    try std.testing.expectEqual(PackageRelation.unrelated, pkgs.relation(p_org1_a, p_org2_a));
    try std.testing.expectEqual(PackageRelation.unrelated, pkgs.relation(p_a, p_org1_a));
    try std.testing.expect(pkgs.isSameOrSubPackage(p_abc, p_ab));
    try std.testing.expect(!pkgs.isSameOrSubPackage(p_ab, p_abc));
}
