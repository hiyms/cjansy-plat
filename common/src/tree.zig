// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 不可变语法节点、绿树与语法树封装。

const std = @import("std");
const syntax = @import("syntax.zig");
const source_mod = @import("source.zig");

const SyntaxKind = syntax.SyntaxKind;
const FileId = source_mod.FileId;

/// 表示一个语法节点。构造完成后不可变。
///
/// 指针内存约定：叶子节点文本与内部节点子节点数组由 `arena` 分配。调用者通过
/// 释放所属 `arena` 统一回收节点内存，无需逐节点释放。
pub const GreenNode = struct {
    /// CST 节点标签。
    kind: SyntaxKind,
    /// 节点覆盖的源码字节数。
    text_len: u32,
    /// 叶子文本或子节点指针数组。
    payload: Payload,

    pub const Payload = union(enum) {
        /// 叶子节点对应的源码文本，生命周期与所属 arena 一致。
        leaf: []const u8,
        /// 内部节点的直接子节点指针，指向同一 arena 中的节点。
        tree: []const *const GreenNode,
    };

    /// 判定是否为叶子节点。
    pub inline fn isLeaf(self: *const GreenNode) bool {
        return self.payload == .leaf;
    }

    /// 获取子节点数量。叶子节点返回 0。
    pub inline fn childCount(self: *const GreenNode) usize {
        return if (self.payload == .tree) self.payload.tree.len else 0;
    }

    /// 获取指定索引的子节点。叶子节点或越界返回 null。
    ///
    /// 返回的指针借用自所属 `arena`，调用者不得单独释放。
    pub inline fn childAt(self: *const GreenNode, index: usize) ?*const GreenNode {
        if (self.payload == .tree and index < self.payload.tree.len) {
            return self.payload.tree[index];
        }
        return null;
    }

    /// 获取所有子节点。叶子节点返回空切片。
    ///
    /// 返回的切片借用自所属 `arena`，调用者不得单独释放。
    pub inline fn children(self: *const GreenNode) []const *const GreenNode {
        return if (self.payload == .tree) self.payload.tree else &.{};
    }

    /// 获取叶子节点文本。内部节点返回 null。
    ///
    /// 返回的切片借用自所属 `arena`，调用者不得单独释放。
    pub inline fn tokenText(self: *const GreenNode) ?[]const u8 {
        return if (self.payload == .leaf) self.payload.leaf else null;
    }

    /// 获取首个匹配类型的直接子节点。内部节点若未找到或叶子节点返回 null。
    ///
    /// 返回的指针借用自所属 `arena`，调用者不得单独释放。
    pub inline fn childOfKind(self: *const GreenNode, kind: SyntaxKind) ?*const GreenNode {
        if (self.payload == .tree) {
            for (self.payload.tree) |child| {
                if (child.kind == kind) return child;
            }
        }
        return null;
    }
};

/// 对根 GreenNode 节点的封装。
pub const GreenTree = struct {
    /// 根节点，指针借用自所属 arena。
    root: *const GreenNode,

    /// 树覆盖的文本字节总长度。
    pub inline fn textLen(self: GreenTree) u32 {
        return self.root.text_len;
    }

    /// 计算给定字节位置所在的叶子节点。
    ///
    /// 返回的指针借用自所属 `arena`，调用者不得单独释放。
    pub fn nodeAt(self: GreenTree, offset: u32) ?*const GreenNode {
        if (offset >= self.textLen()) return null;
        var current = self.root;
        var pos = offset;
        while (!current.isLeaf()) {
            var found = false;
            for (current.children()) |child| {
                if (pos < child.text_len) {
                    current = child;
                    found = true;
                    break;
                }
                pos -= child.text_len;
            }
            if (!found) return null;
        }
        return current;
    }
};

/// 包含文件标识与版本信息的语法树，用于判定树相对于文件是否过期。
pub const SyntaxTree = struct {
    /// 语法树对应的文件句柄。
    file: FileId,
    /// 构建语法树时的文件版本号。
    version: u32,
    /// 绿树。
    tree: GreenTree,

    /// 判定树相对于给定文件与文件版本是否过期。
    pub inline fn isOutdated(self: SyntaxTree, file: FileId, current_version: u32) bool {
        return self.version != current_version or !std.meta.eql(self.file, file);
    }

    /// 转发：获取树覆盖总长度。
    pub inline fn textLen(self: SyntaxTree) u32 {
        return self.tree.textLen();
    }

    /// 转发：定位指定字节位置处的叶子节点。
    ///
    /// 返回的指针借用自所属 `arena`，调用者不得单独释放。
    pub fn nodeAt(self: SyntaxTree, offset: u32) ?*const GreenNode {
        return self.tree.nodeAt(offset);
    }
};

test "GreenNode 与 GreenTree 基础逻辑" {
    const gpa = std.testing.allocator;
    // 使用 Arena 分配节点，测试完成后释放
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const leaf1 = try alloc.create(GreenNode);
    leaf1.* = .{ .kind = .identifier, .text_len = 3, .payload = .{ .leaf = "abc" } };
    const leaf2 = try alloc.create(GreenNode);
    leaf2.* = .{ .kind = .add, .text_len = 1, .payload = .{ .leaf = "+" } };

    const children = try alloc.alloc(*const GreenNode, 2);
    children[0] = leaf1;
    children[1] = leaf2;

    const root = try alloc.create(GreenNode);
    root.* = .{ .kind = .binary_expr, .text_len = 4, .payload = .{ .tree = children } };

    const tree: GreenTree = .{ .root = root };
    try std.testing.expectEqual(@as(u32, 4), tree.textLen());
    try std.testing.expectEqual(leaf1, tree.nodeAt(0));
    try std.testing.expectEqual(leaf1, tree.nodeAt(2));
    try std.testing.expectEqual(leaf2, tree.nodeAt(3));
    try std.testing.expect(tree.nodeAt(4) == null);

    try std.testing.expect(!root.isLeaf());
    try std.testing.expectEqual(@as(usize, 2), root.childCount());
    try std.testing.expectEqual(leaf2, root.childAt(1).?);
    try std.testing.expect(root.childAt(2) == null);
    try std.testing.expectEqual(@as(usize, 2), root.children().len);
    try std.testing.expect(root.tokenText() == null);
    try std.testing.expectEqual(leaf2, root.childOfKind(.add).?);
    try std.testing.expect(root.childOfKind(.comma) == null);

    try std.testing.expect(leaf1.isLeaf());
    try std.testing.expectEqual(@as(usize, 0), leaf1.childCount());
    try std.testing.expect(leaf1.childAt(0) == null);
    try std.testing.expectEqual(@as(usize, 0), leaf1.children().len);
    try std.testing.expectEqualStrings("abc", leaf1.tokenText().?);
    try std.testing.expect(leaf1.childOfKind(.identifier) == null);
}

test "SyntaxTree 按文件标识与版本判定过期" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const root = try arena.allocator().create(GreenNode);
    root.* = .{ .kind = .source_file, .text_len = 0, .payload = .{ .tree = &.{} } };

    const file: FileId = .{ .index = 3, .generation = 7 };
    const syntax_tree: SyntaxTree = .{
        .file = file,
        .version = 5,
        .tree = .{ .root = root },
    };

    try std.testing.expect(!syntax_tree.isOutdated(file, 5));
    try std.testing.expect(syntax_tree.isOutdated(file, 6));
    try std.testing.expect(syntax_tree.isOutdated(.{ .index = 3, .generation = 8 }, 5));
    try std.testing.expect(syntax_tree.isOutdated(.{ .index = 4, .generation = 7 }, 5));
}
