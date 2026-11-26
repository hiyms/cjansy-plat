// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 不可变语法节点、绿树、红节点视图、查询上下文与前向遍历。

const std = @import("std");
const syntax = @import("syntax.zig");
const source_mod = @import("source.zig");

const SyntaxKind = syntax.SyntaxKind;
const FileId = source_mod.FileId;
const TextRange = source_mod.TextRange;

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

/// 携带绝对起始字节偏移的绿树节点定位结果。
pub const LocatedGreen = struct {
    /// 指向底层不可变绿树节点，指针借用自所属 arena。
    green: *const GreenNode,
    /// 该节点在文件中的绝对起始字节偏移。
    start: u32,
};

/// 对根 GreenNode 节点的封装。
pub const GreenTree = struct {
    /// 根节点，指针借用自所属 arena。
    root: *const GreenNode,

    /// 树覆盖的文本字节总长度。
    pub inline fn textLen(self: GreenTree) u32 {
        return self.root.text_len;
    }

    /// 计算给定字节位置所在的叶子节点及其绝对起始偏移。
    ///
    /// 返回结果中的 `green` 指针借用自所属 `arena`，调用者不得单独释放。
    pub fn nodeAt(self: GreenTree, offset: u32) ?LocatedGreen {
        if (offset >= self.textLen()) return null;
        var current = self.root;
        var start: u32 = 0;
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
                start += child.text_len;
            }
            if (!found) return null;
        }
        return .{ .green = current, .start = start };
    }

    /// 创建用于深度优先前向遍历当前绿树的迭代器。
    ///
    /// 迭代器内部使用 `gpa` 维护遍历状态，调用者结束后须调用 `GreenTraversal.deinit` 释放。
    pub inline fn traversal(self: GreenTree, gpa: std.mem.Allocator) GreenTraversal {
        return GreenTraversal.init(gpa, self);
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

    /// 转发：定位指定字节位置处的叶子节点及其绝对起始偏移。
    ///
    /// 返回结果中的 `green` 指针借用自所属 `arena`，调用者不得单独释放。
    pub inline fn nodeAt(self: SyntaxTree, offset: u32) ?LocatedGreen {
        return self.tree.nodeAt(offset);
    }
};

/// 单次语法树查询会话的红节点分配与去重上下文。
///
/// 内部基于外部传入的 `gpa` 自持有 `arena` 与去重缓存表；同一 `QueryContext` 面向同一棵
/// `GreenTree`，当传入相同的 `green` 与 `offset` 时 `allocRed` 必然返回同一个 `RedNode` 指针。
///
/// 生命周期约定：通过 `QueryContext` 分配的所有 `RedNode` 指针及子节点切片均由内部 `arena`
/// 持有，预期短于对应 `GreenTree` 的生命周期，随 `deinit` 统一回收，调用者不得单独释放。
pub const QueryContext = struct {
    /// 存放红节点实例及查询期切片的内存池，底层由外部 `gpa` 支撑。
    arena: std.heap.ArenaAllocator,
    /// 按 `(green, offset)` 去重的红节点指针索引，桶数组由 `arena.child_allocator` 分配。
    cache: std.AutoHashMapUnmanaged(RedKey, *const RedNode) = .empty,

    const RedKey = struct {
        green: usize,
        offset: u32,
    };

    /// 基于外部 `gpa` 创建查询上下文。
    ///
    /// 调用者使用完毕后须调用 `deinit` 释放内部缓存与 `arena`。
    pub fn init(gpa: std.mem.Allocator) QueryContext {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .cache = .empty,
        };
    }

    /// 释放去重索引与内部 `arena` 中的全部红节点数据。
    pub fn deinit(self: *QueryContext) void {
        self.cache.deinit(self.arena.child_allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    /// 获取内部 `arena` 分配器。
    ///
    /// 通过该分配器分配的内存随 `QueryContext.deinit` 统一释放，调用者不得单独释放。
    pub inline fn allocator(self: *QueryContext) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// 按 `(green, offset)` 分配或复用对应的 `RedNode` 实例。
    ///
    /// 同一 `QueryContext` 中传入相同的 `green` 与 `offset` 时直接复用既有实例并返回同一指针
    /// （不覆写已有实例的 `parent_node`）；根节点传入 `parent = null` 与 `offset = 0`。
    ///
    /// 指针内存约定：传入的 `green` 与 `parent` 指针仅作借用（不转移所有权、不由本上下文释放），
    /// 调用者须保证二者生命周期长于本 `QueryContext`；返回的指针由本 `QueryContext` 的 `arena`
    /// 持有，调用者不得单独释放。
    pub fn allocRed(
        self: *QueryContext,
        green: *const GreenNode,
        parent: ?*const RedNode,
        offset: u32,
    ) std.mem.Allocator.Error!*const RedNode {
        const key: RedKey = .{
            .green = @intFromPtr(green),
            .offset = offset,
        };
        if (self.cache.get(key)) |existing| {
            return existing;
        }
        try self.cache.ensureUnusedCapacity(self.arena.child_allocator, 1);
        const node = try self.allocator().create(RedNode);
        node.* = .{
            .green = green,
            .parent_node = parent,
            .text_offset = offset,
        };
        self.cache.putAssumeCapacityNoClobber(key, node);
        return node;
    }
};

/// 沿父节点链向上遍历 `RedNode` 的迭代器。
///
/// 迭代顺序从起始节点自身开始，逐级向上直至根节点。
pub const AncestorIter = struct {
    current: ?*const RedNode,

    /// 返回当前红节点并推进至父节点；越过根节点后返回 null。
    ///
    /// 返回的指针借用自对应的 `QueryContext`，调用者不得单独释放。
    pub inline fn next(self: *AncestorIter) ?*const RedNode {
        const node = self.current orelse return null;
        self.current = node.parent_node;
        return node;
    }
};

/// 绑定了父节点指针与绝对文件偏移的语法树视图节点（红节点）。
///
/// `RedNode` 由 `QueryContext.allocRed` 在查询上下文的 `arena` 中按需创建并缓存，
/// 其生命周期随所属 `QueryContext` 结束，短于底层不可变 `GreenNode`。
pub const RedNode = struct {
    /// 指向底层不可变绿树节点。
    green: *const GreenNode,
    /// 父节点实例；根节点为 null。
    parent_node: ?*const RedNode,
    /// 该节点在文件中的绝对起始字节偏移。
    text_offset: u32,

    /// 获取节点对应的 CST 标签。
    pub inline fn kind(self: *const RedNode) SyntaxKind {
        return self.green.kind;
    }

    /// 获取节点覆盖的源码字节长度。
    pub inline fn textLen(self: *const RedNode) u32 {
        return self.green.text_len;
    }

    /// 获取该节点在文件中的绝对起始字节偏移。
    pub inline fn offset(self: *const RedNode) u32 {
        return self.text_offset;
    }

    /// 获取该节点在文件中的左闭右开字节区间。
    pub inline fn range(self: *const RedNode) TextRange {
        return .{
            .start = self.text_offset,
            .end = self.text_offset + self.green.text_len,
        };
    }

    /// 获取父节点实例；根节点返回 null。
    ///
    /// 返回的指针借用自所属 `QueryContext`，调用者不得单独释放。
    pub inline fn parent(self: *const RedNode) ?*const RedNode {
        return self.parent_node;
    }

    /// 判定是否为叶子节点。
    pub inline fn isLeaf(self: *const RedNode) bool {
        return self.green.isLeaf();
    }

    /// 获取叶子节点文本；内部节点返回 null。
    ///
    /// 返回的切片借用自底层绿树所属 `arena`，调用者不得单独释放。
    pub inline fn tokenText(self: *const RedNode) ?[]const u8 {
        return self.green.tokenText();
    }

    /// 获取直接子节点数量；叶子节点返回 0。
    pub inline fn childCount(self: *const RedNode) usize {
        return self.green.childCount();
    }

    /// 获取指定索引处的直接子节点红节点。叶子节点或索引越界返回 null。
    ///
    /// 指针内存约定：`self` 会作为父指针写入新建子节点，调用者须保证 `self` 由同一 `ctx` 分配
    /// 或生命周期长于 `ctx`；子节点经由 `ctx.allocRed` 分配并缓存，返回的指针借用自 `ctx`，
    /// 调用者不得单独释放。
    pub fn childAt(
        self: *const RedNode,
        ctx: *QueryContext,
        index: usize,
    ) std.mem.Allocator.Error!?*const RedNode {
        const green_children = self.green.children();
        if (index >= green_children.len) return null;
        var child_offset = self.text_offset;
        for (green_children[0..index]) |prev| {
            child_offset += prev.text_len;
        }
        return try ctx.allocRed(green_children[index], self, child_offset);
    }

    /// 获取全部直接子节点的红节点切片。叶子节点或无子节点时返回空切片且不分配。
    ///
    /// 指针内存约定：`self` 会作为父指针写入新建子节点，调用者须保证 `self` 由同一 `ctx` 分配
    /// 或生命周期长于 `ctx`；返回的切片与其中每个子节点指针均借用自 `ctx` 的 `arena`，
    /// 调用者不得单独释放。
    pub fn children(
        self: *const RedNode,
        ctx: *QueryContext,
    ) std.mem.Allocator.Error![]const *const RedNode {
        const green_children = self.green.children();
        if (green_children.len == 0) return &.{};
        const result = try ctx.allocator().alloc(*const RedNode, green_children.len);
        var child_offset = self.text_offset;
        for (green_children, 0..) |child_green, i| {
            result[i] = try ctx.allocRed(child_green, self, child_offset);
            child_offset += child_green.text_len;
        }
        return result;
    }

    /// 在以当前节点为根的子树中查找包含绝对字节偏移 `target_offset` 的叶子红节点。
    ///
    /// 沿下探路径逐层经由 `ctx.allocRed` 构建父子链；越界或未命中返回 null。
    /// 指针内存约定：`self` 会作为父指针写入路径节点，调用者须保证 `self` 由同一 `ctx` 分配
    /// 或生命周期长于 `ctx`；返回的指针借用自 `ctx`，调用者不得单独释放。
    pub fn findTokenAt(
        self: *const RedNode,
        ctx: *QueryContext,
        target_offset: u32,
    ) std.mem.Allocator.Error!?*const RedNode {
        if (!self.range().contains(target_offset)) return null;
        var current = self;
        while (!current.isLeaf()) {
            var child_offset = current.text_offset;
            var found: ?*const RedNode = null;
            for (current.green.children()) |child_green| {
                const child_end = child_offset + child_green.text_len;
                if (target_offset < child_end) {
                    found = try ctx.allocRed(child_green, current, child_offset);
                    break;
                }
                child_offset = child_end;
            }
            current = found orelse return null;
        }
        return current;
    }

    /// 创建沿父节点链向上遍历的迭代器，依次产出当前节点及其全部祖先直至根节点。
    ///
    /// 返回的迭代器仅借用 `self` 及父链上的 `RedNode` 指针，在所属 `QueryContext` 释放前有效。
    pub inline fn ancestors(self: *const RedNode) AncestorIter {
        return .{ .current = self };
    }
};

/// 对 `GreenTree` 执行非递归深度优先前向遍历的迭代器。
///
/// 遍历过程无需分配 `RedNode`，直接沿 `GreenNode` 推进并实时维护每个节点的绝对起始偏移。
/// 每个节点先产出 `.enter` 事件，在其所有子节点遍历完毕后产出对应的 `.leave` 事件
/// （叶子节点同样先产出 `.enter` 再产出 `.leave`）。
///
/// 内存约定：内部状态列表由外部传入的 `gpa` 分配，调用者使用完毕后须调用 `deinit` 释放；
/// 事件中的 `LocatedGreen.green` 借用自绿树所属 `arena`，调用者不得单独释放。
pub const GreenTraversal = struct {
    gpa: std.mem.Allocator,
    pending_root: ?LocatedGreen,
    frames: std.ArrayListUnmanaged(Frame) = .empty,

    /// 单步前向遍历事件。
    pub const Event = union(enum) {
        /// 进入节点（前序位置）。
        enter: LocatedGreen,
        /// 离开节点（后序位置）。
        leave: LocatedGreen,
    };

    const Frame = struct {
        node: *const GreenNode,
        start: u32,
        next_child: usize = 0,
        next_child_offset: u32,
    };

    /// 初始化覆盖整棵 `GreenTree` 的前向遍历迭代器。
    ///
    /// 迭代期间仅借用 `tree.root` 及其子树，调用者须保证绿树所属 `arena` 生命周期覆盖整个遍历过程，
    /// 并在结束后调用 `deinit` 释放内部缓冲。
    pub inline fn init(gpa: std.mem.Allocator, tree: GreenTree) GreenTraversal {
        return initFromNode(gpa, tree.root, 0);
    }

    /// 初始化从指定 `GreenNode` 与绝对起始偏移开始的前向遍历迭代器。
    ///
    /// 指针内存约定：传入的 `node` 及其子树仅作借用，调用者须保证其生命周期覆盖整个遍历过程，
    /// 并在结束后调用 `deinit` 释放内部缓冲。
    pub fn initFromNode(
        gpa: std.mem.Allocator,
        node: *const GreenNode,
        start_offset: u32,
    ) GreenTraversal {
        return .{
            .gpa = gpa,
            .pending_root = .{ .green = node, .start = start_offset },
            .frames = .empty,
        };
    }

    /// 释放遍历器内部的临时帧列表。
    pub fn deinit(self: *GreenTraversal) void {
        self.frames.deinit(self.gpa);
        self.* = undefined;
    }

    /// 推进遍历一步并返回下一个 `.enter` 或 `.leave` 事件；全部遍历完成后返回 null。
    ///
    /// 返回事件中的 `LocatedGreen.green` 借用自绿树所属 `arena`，调用者不得单独释放。
    pub fn next(self: *GreenTraversal) std.mem.Allocator.Error!?Event {
        if (self.pending_root) |root| {
            try self.frames.append(self.gpa, .{
                .node = root.green,
                .start = root.start,
                .next_child = 0,
                .next_child_offset = root.start,
            });
            self.pending_root = null;
            return .{ .enter = root };
        }

        if (self.frames.items.len == 0) return null;

        const top_index = self.frames.items.len - 1;
        const top_node = self.frames.items[top_index].node;
        const node_children = top_node.children();
        if (self.frames.items[top_index].next_child < node_children.len) {
            try self.frames.ensureUnusedCapacity(self.gpa, 1);
            const parent_frame = &self.frames.items[top_index];
            const child = node_children[parent_frame.next_child];
            const child_start = parent_frame.next_child_offset;
            parent_frame.next_child += 1;
            parent_frame.next_child_offset += child.text_len;
            self.frames.appendAssumeCapacity(.{
                .node = child,
                .start = child_start,
                .next_child = 0,
                .next_child_offset = child_start,
            });
            return .{ .enter = .{ .green = child, .start = child_start } };
        }

        const finished = self.frames.pop().?;
        return .{ .leave = .{ .green = finished.node, .start = finished.start } };
    }

    /// 跳过当前活动帧的剩余子节点。
    ///
    /// 在节点 `.enter` 事件之后调用会跳过该节点的全部子节点，使下一次 `next` 直接产出该节点的
    /// `.leave` 事件；在某个子节点 `.leave` 事件之后调用会跳过其父节点的全部剩余兄弟子节点；
    /// 在尚未调用 `next` 进入根节点或遍历已结束后调用无效果。
    pub fn skipChildren(self: *GreenTraversal) void {
        if (self.frames.items.len == 0) return;
        const top = &self.frames.items[self.frames.items.len - 1];
        top.next_child = top.node.childCount();
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
    try std.testing.expectEqual(LocatedGreen{ .green = leaf1, .start = 0 }, tree.nodeAt(0).?);
    try std.testing.expectEqual(LocatedGreen{ .green = leaf1, .start = 0 }, tree.nodeAt(2).?);
    try std.testing.expectEqual(LocatedGreen{ .green = leaf2, .start = 3 }, tree.nodeAt(3).?);
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

test "SyntaxTree 按文件标识与版本判定过期并转发 nodeAt" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const leaf = try alloc.create(GreenNode);
    leaf.* = .{ .kind = .identifier, .text_len = 2, .payload = .{ .leaf = "ok" } };
    const kids = try alloc.alloc(*const GreenNode, 1);
    kids[0] = leaf;
    const root = try alloc.create(GreenNode);
    root.* = .{ .kind = .source_file, .text_len = 2, .payload = .{ .tree = kids } };

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
    try std.testing.expectEqual(LocatedGreen{ .green = leaf, .start = 0 }, syntax_tree.nodeAt(1).?);
    try std.testing.expect(syntax_tree.nodeAt(2) == null);
}

/// 测试辅助：构造表示 `a + (b * c)` 的嵌套绿树（包含空节点以验证边界）。
const SampleTree = struct {
    root: *const GreenNode,
    lhs: *const GreenNode,
    plus: *const GreenNode,
    rhs_group: *const GreenNode,
    empty_leaf: *const GreenNode,
    b_leaf: *const GreenNode,
    star_leaf: *const GreenNode,
    c_leaf: *const GreenNode,

    /// 在 `alloc` 中构建示例绿树。
    fn build(alloc: std.mem.Allocator) !SampleTree {
        const lhs = try alloc.create(GreenNode);
        lhs.* = .{ .kind = .identifier, .text_len = 1, .payload = .{ .leaf = "a" } };

        const plus = try alloc.create(GreenNode);
        plus.* = .{ .kind = .add, .text_len = 1, .payload = .{ .leaf = "+" } };

        const empty_leaf = try alloc.create(GreenNode);
        empty_leaf.* = .{ .kind = .whitespace, .text_len = 0, .payload = .{ .leaf = "" } };

        const b_leaf = try alloc.create(GreenNode);
        b_leaf.* = .{ .kind = .identifier, .text_len = 2, .payload = .{ .leaf = "bb" } };

        const star_leaf = try alloc.create(GreenNode);
        star_leaf.* = .{ .kind = .mul, .text_len = 1, .payload = .{ .leaf = "*" } };

        const c_leaf = try alloc.create(GreenNode);
        c_leaf.* = .{ .kind = .identifier, .text_len = 3, .payload = .{ .leaf = "ccc" } };

        const rhs_children = try alloc.alloc(*const GreenNode, 4);
        rhs_children[0] = empty_leaf;
        rhs_children[1] = b_leaf;
        rhs_children[2] = star_leaf;
        rhs_children[3] = c_leaf;

        const rhs_group = try alloc.create(GreenNode);
        rhs_group.* = .{ .kind = .binary_expr, .text_len = 6, .payload = .{ .tree = rhs_children } };

        const root_children = try alloc.alloc(*const GreenNode, 3);
        root_children[0] = lhs;
        root_children[1] = plus;
        root_children[2] = rhs_group;

        const root = try alloc.create(GreenNode);
        root.* = .{ .kind = .binary_expr, .text_len = 8, .payload = .{ .tree = root_children } };

        return .{
            .root = root,
            .lhs = lhs,
            .plus = plus,
            .rhs_group = rhs_group,
            .empty_leaf = empty_leaf,
            .b_leaf = b_leaf,
            .star_leaf = star_leaf,
            .c_leaf = c_leaf,
        };
    }
};

test "QueryContext 对相同 (green, offset) 返回同一 RedNode 指针" {
    const gpa = std.testing.allocator;
    var green_arena = std.heap.ArenaAllocator.init(gpa);
    defer green_arena.deinit();
    const sample = try SampleTree.build(green_arena.allocator());

    var ctx = QueryContext.init(gpa);
    defer ctx.deinit();

    const r1 = try ctx.allocRed(sample.root, null, 0);
    const r2 = try ctx.allocRed(sample.root, null, 0);
    try std.testing.expectEqual(r1, r2);

    // 同一 GreenNode 在不同 offset 下视为不同实例
    const b_at_2 = try ctx.allocRed(sample.b_leaf, r1, 2);
    const b_at_2_again = try ctx.allocRed(sample.b_leaf, r1, 2);
    const b_at_10 = try ctx.allocRed(sample.b_leaf, r1, 10);
    try std.testing.expectEqual(b_at_2, b_at_2_again);
    try std.testing.expect(b_at_2 != b_at_10);
    try std.testing.expectEqual(@as(u32, 2), b_at_2.offset());
    try std.testing.expectEqual(@as(u32, 10), b_at_10.offset());
}

test "RedNode 基础属性、childAt、children、findTokenAt 与 AncestorIter" {
    const gpa = std.testing.allocator;
    var green_arena = std.heap.ArenaAllocator.init(gpa);
    defer green_arena.deinit();
    const sample = try SampleTree.build(green_arena.allocator());

    // 先验证 GreenTree.nodeAt 对嵌套节点与空叶子的绝对偏移计算
    const gtree: GreenTree = .{ .root = sample.root };
    try std.testing.expectEqual(LocatedGreen{ .green = sample.lhs, .start = 0 }, gtree.nodeAt(0).?);
    try std.testing.expectEqual(LocatedGreen{ .green = sample.plus, .start = 1 }, gtree.nodeAt(1).?);
    try std.testing.expectEqual(LocatedGreen{ .green = sample.b_leaf, .start = 2 }, gtree.nodeAt(2).?);
    try std.testing.expectEqual(LocatedGreen{ .green = sample.b_leaf, .start = 2 }, gtree.nodeAt(3).?);
    try std.testing.expectEqual(LocatedGreen{ .green = sample.star_leaf, .start = 4 }, gtree.nodeAt(4).?);
    try std.testing.expectEqual(LocatedGreen{ .green = sample.c_leaf, .start = 5 }, gtree.nodeAt(7).?);
    try std.testing.expect(gtree.nodeAt(8) == null);

    var ctx = QueryContext.init(gpa);
    defer ctx.deinit();

    const root_red = try ctx.allocRed(sample.root, null, 0);
    try std.testing.expectEqual(SyntaxKind.binary_expr, root_red.kind());
    try std.testing.expectEqual(@as(u32, 8), root_red.textLen());
    try std.testing.expectEqual(@as(u32, 0), root_red.offset());
    try std.testing.expectEqual(TextRange{ .start = 0, .end = 8 }, root_red.range());
    try std.testing.expect(root_red.parent() == null);
    try std.testing.expect(!root_red.isLeaf());
    try std.testing.expect(root_red.tokenText() == null);
    try std.testing.expectEqual(@as(usize, 3), root_red.childCount());

    // childAt 与 children 返回的子红节点指针保持同一性
    const rhs_via_at = (try root_red.childAt(&ctx, 2)).?;
    try std.testing.expect((try root_red.childAt(&ctx, 3)) == null);
    try std.testing.expectEqual(@as(u32, 2), rhs_via_at.offset());
    try std.testing.expectEqual(TextRange{ .start = 2, .end = 8 }, rhs_via_at.range());
    try std.testing.expectEqual(root_red, rhs_via_at.parent().?);

    const root_kids = try root_red.children(&ctx);
    try std.testing.expectEqual(@as(usize, 3), root_kids.len);
    try std.testing.expectEqual(rhs_via_at, root_kids[2]);
    try std.testing.expectEqualStrings("a", root_kids[0].tokenText().?);
    try std.testing.expect(root_kids[0].isLeaf());
    try std.testing.expectEqual(@as(usize, 0), root_kids[0].childCount());
    try std.testing.expectEqual(@as(usize, 0), (try root_kids[0].children(&ctx)).len);
    try std.testing.expect((try root_kids[0].childAt(&ctx, 0)) == null);

    // findTokenAt 跨过空叶子节点并保持路径节点同一性
    const found_b = (try root_red.findTokenAt(&ctx, 2)).?;
    try std.testing.expectEqual(sample.b_leaf, found_b.green);
    try std.testing.expectEqual(@as(u32, 2), found_b.offset());
    try std.testing.expectEqual(TextRange{ .start = 2, .end = 4 }, found_b.range());
    try std.testing.expectEqual(rhs_via_at, found_b.parent().?);
    try std.testing.expectEqual(found_b, (try rhs_via_at.findTokenAt(&ctx, 3)).?);
    try std.testing.expectEqual(found_b, (try found_b.findTokenAt(&ctx, 2)).?);
    try std.testing.expect((try rhs_via_at.findTokenAt(&ctx, 1)) == null);
    try std.testing.expect((try root_red.findTokenAt(&ctx, 8)) == null);

    const found_c = (try root_red.findTokenAt(&ctx, 6)).?;
    try std.testing.expectEqualStrings("ccc", found_c.tokenText().?);
    try std.testing.expectEqual(TextRange{ .start = 5, .end = 8 }, found_c.range());

    // AncestorIter 从当前节点向上迭代直至根节点
    var anc = found_c.ancestors();
    try std.testing.expectEqual(found_c, anc.next().?);
    try std.testing.expectEqual(rhs_via_at, anc.next().?);
    try std.testing.expectEqual(root_red, anc.next().?);
    try std.testing.expect(anc.next() == null);
}

test "GreenTraversal 前向遍历顺序、绝对偏移与 skipChildren" {
    const gpa = std.testing.allocator;
    var green_arena = std.heap.ArenaAllocator.init(gpa);
    defer green_arena.deinit();
    const sample = try SampleTree.build(green_arena.allocator());
    const gtree: GreenTree = .{ .root = sample.root };

    const expected = [_]GreenTraversal.Event{
        .{ .enter = .{ .green = sample.root, .start = 0 } },
        .{ .enter = .{ .green = sample.lhs, .start = 0 } },
        .{ .leave = .{ .green = sample.lhs, .start = 0 } },
        .{ .enter = .{ .green = sample.plus, .start = 1 } },
        .{ .leave = .{ .green = sample.plus, .start = 1 } },
        .{ .enter = .{ .green = sample.rhs_group, .start = 2 } },
        .{ .enter = .{ .green = sample.empty_leaf, .start = 2 } },
        .{ .leave = .{ .green = sample.empty_leaf, .start = 2 } },
        .{ .enter = .{ .green = sample.b_leaf, .start = 2 } },
        .{ .leave = .{ .green = sample.b_leaf, .start = 2 } },
        .{ .enter = .{ .green = sample.star_leaf, .start = 4 } },
        .{ .leave = .{ .green = sample.star_leaf, .start = 4 } },
        .{ .enter = .{ .green = sample.c_leaf, .start = 5 } },
        .{ .leave = .{ .green = sample.c_leaf, .start = 5 } },
        .{ .leave = .{ .green = sample.rhs_group, .start = 2 } },
        .{ .leave = .{ .green = sample.root, .start = 0 } },
    };

    var trav = gtree.traversal(gpa);
    defer trav.deinit();
    var idx: usize = 0;
    while (try trav.next()) |ev| {
        try std.testing.expect(idx < expected.len);
        try std.testing.expectEqual(expected[idx], ev);
        idx += 1;
    }
    try std.testing.expectEqual(expected.len, idx);

    // 验证 skipChildren 跳过 rhs_group 子树
    var skip_trav = GreenTraversal.init(gpa, gtree);
    defer skip_trav.deinit();
    const expected_skip = [_]GreenTraversal.Event{
        .{ .enter = .{ .green = sample.root, .start = 0 } },
        .{ .enter = .{ .green = sample.lhs, .start = 0 } },
        .{ .leave = .{ .green = sample.lhs, .start = 0 } },
        .{ .enter = .{ .green = sample.plus, .start = 1 } },
        .{ .leave = .{ .green = sample.plus, .start = 1 } },
        .{ .enter = .{ .green = sample.rhs_group, .start = 2 } },
        .{ .leave = .{ .green = sample.rhs_group, .start = 2 } },
        .{ .leave = .{ .green = sample.root, .start = 0 } },
    };
    idx = 0;
    while (try skip_trav.next()) |ev| {
        try std.testing.expect(idx < expected_skip.len);
        try std.testing.expectEqual(expected_skip[idx], ev);
        if (ev == .enter and ev.enter.green == sample.rhs_group) {
            skip_trav.skipChildren();
        }
        idx += 1;
    }
    try std.testing.expectEqual(expected_skip.len, idx);
}

/// 供分配失败测试调用的例程，覆盖 QueryContext、RedNode 与 GreenTraversal。
fn redAndTraversalAllocationChecks(gpa: std.mem.Allocator) !void {
    var green_arena = std.heap.ArenaAllocator.init(gpa);
    defer green_arena.deinit();
    const sample = try SampleTree.build(green_arena.allocator());
    const gtree: GreenTree = .{ .root = sample.root };

    var ctx = QueryContext.init(gpa);
    defer ctx.deinit();

    const root_red = try ctx.allocRed(sample.root, null, 0);
    _ = try root_red.children(&ctx);
    const leaf = (try root_red.findTokenAt(&ctx, 6)).?;
    try std.testing.expectEqual(sample.c_leaf, leaf.green);

    var trav = GreenTraversal.init(gpa, gtree);
    defer trav.deinit();
    var count: usize = 0;
    while (try trav.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 16), count);
}

test "QueryContext、RedNode 与 GreenTraversal 在任意分配失败点上无泄漏" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        redAndTraversalAllocationChecks,
        .{},
    );
}

test "边界场景：空内部节点、单叶子根节点、QueryContext.allocator 与 GreenTraversal 高级调用" {
    const gpa = std.testing.allocator;
    var green_arena = std.heap.ArenaAllocator.init(gpa);
    defer green_arena.deinit();
    const alloc = green_arena.allocator();

    // 1. 0 长度空内部节点作为根节点
    const empty_root = try alloc.create(GreenNode);
    empty_root.* = .{ .kind = .source_file, .text_len = 0, .payload = .{ .tree = &.{} } };
    const empty_tree: GreenTree = .{ .root = empty_root };
    try std.testing.expect(empty_tree.nodeAt(0) == null);

    var ctx = QueryContext.init(gpa);
    defer ctx.deinit();

    // 验证 QueryContext.allocator 分配的内容随 deinit 回收无泄漏
    const scratch_slice = try ctx.allocator().dupe(u8, "query_temp");
    try std.testing.expectEqualStrings("query_temp", scratch_slice);

    const empty_red = try ctx.allocRed(empty_root, null, 0);
    try std.testing.expectEqual(@as(usize, 0), (try empty_red.children(&ctx)).len);
    try std.testing.expect((try empty_red.findTokenAt(&ctx, 0)) == null);

    var empty_trav = GreenTraversal.init(gpa, empty_tree);
    defer empty_trav.deinit();
    // 首次 next 之前调用 skipChildren 应无效果
    empty_trav.skipChildren();
    try std.testing.expectEqual(
        GreenTraversal.Event{ .enter = .{ .green = empty_root, .start = 0 } },
        (try empty_trav.next()).?,
    );
    try std.testing.expectEqual(
        GreenTraversal.Event{ .leave = .{ .green = empty_root, .start = 0 } },
        (try empty_trav.next()).?,
    );
    try std.testing.expect((try empty_trav.next()) == null);
    // 遍历结束后重复调用 next 与 skipChildren 保持安全
    empty_trav.skipChildren();
    try std.testing.expect((try empty_trav.next()) == null);

    // 2. 0 长度空内部节点作为非空叶子的前置兄弟节点
    const empty_inner = try alloc.create(GreenNode);
    empty_inner.* = .{ .kind = .error_node, .text_len = 0, .payload = .{ .tree = &.{} } };
    const tail_leaf = try alloc.create(GreenNode);
    tail_leaf.* = .{ .kind = .identifier, .text_len = 2, .payload = .{ .leaf = "xy" } };
    const pair = try alloc.alloc(*const GreenNode, 2);
    pair[0] = empty_inner;
    pair[1] = tail_leaf;
    const parent_green = try alloc.create(GreenNode);
    parent_green.* = .{ .kind = .source_file, .text_len = 2, .payload = .{ .tree = pair } };
    const parent_tree: GreenTree = .{ .root = parent_green };

    try std.testing.expectEqual(LocatedGreen{ .green = tail_leaf, .start = 0 }, parent_tree.nodeAt(0).?);
    try std.testing.expectEqual(LocatedGreen{ .green = tail_leaf, .start = 0 }, parent_tree.nodeAt(1).?);
    const parent_red = try ctx.allocRed(parent_green, null, 0);
    const located_tail = (try parent_red.findTokenAt(&ctx, 0)).?;
    try std.testing.expectEqual(tail_leaf, located_tail.green);
    try std.testing.expectEqual(@as(u32, 0), located_tail.offset());

    // 3. 单叶子根节点
    const solo_leaf = try alloc.create(GreenNode);
    solo_leaf.* = .{ .kind = .identifier, .text_len = 3, .payload = .{ .leaf = "foo" } };
    const solo_tree: GreenTree = .{ .root = solo_leaf };
    try std.testing.expectEqual(LocatedGreen{ .green = solo_leaf, .start = 0 }, solo_tree.nodeAt(2).?);
    try std.testing.expect(solo_tree.nodeAt(3) == null);

    const solo_red = try ctx.allocRed(solo_leaf, null, 0);
    try std.testing.expectEqual(solo_red, (try solo_red.findTokenAt(&ctx, 1)).?);
    try std.testing.expect((try solo_red.findTokenAt(&ctx, 3)) == null);
    var solo_anc = solo_red.ancestors();
    try std.testing.expectEqual(solo_red, solo_anc.next().?);
    try std.testing.expect(solo_anc.next() == null);

    var solo_trav = solo_tree.traversal(gpa);
    defer solo_trav.deinit();
    try std.testing.expectEqual(
        GreenTraversal.Event{ .enter = .{ .green = solo_leaf, .start = 0 } },
        (try solo_trav.next()).?,
    );
    // 叶子节点 .enter 后调用 skipChildren 不影响随后的 .leave
    solo_trav.skipChildren();
    try std.testing.expectEqual(
        GreenTraversal.Event{ .leave = .{ .green = solo_leaf, .start = 0 } },
        (try solo_trav.next()).?,
    );
    try std.testing.expect((try solo_trav.next()) == null);

    // 4. GreenTraversal.initFromNode（非零起始偏移）与 .leave 后调用 skipChildren
    const sample = try SampleTree.build(alloc);
    var sub_trav = GreenTraversal.initFromNode(gpa, sample.rhs_group, 10);
    defer sub_trav.deinit();
    const expected_sub = [_]GreenTraversal.Event{
        .{ .enter = .{ .green = sample.rhs_group, .start = 10 } },
        .{ .enter = .{ .green = sample.empty_leaf, .start = 10 } },
        .{ .leave = .{ .green = sample.empty_leaf, .start = 10 } },
        .{ .enter = .{ .green = sample.b_leaf, .start = 10 } },
        .{ .leave = .{ .green = sample.b_leaf, .start = 10 } },
        .{ .enter = .{ .green = sample.star_leaf, .start = 12 } },
        .{ .leave = .{ .green = sample.star_leaf, .start = 12 } },
        .{ .enter = .{ .green = sample.c_leaf, .start = 13 } },
        .{ .leave = .{ .green = sample.c_leaf, .start = 13 } },
        .{ .leave = .{ .green = sample.rhs_group, .start = 10 } },
    };
    var idx: usize = 0;
    while (try sub_trav.next()) |ev| {
        try std.testing.expectEqual(expected_sub[idx], ev);
        idx += 1;
    }
    try std.testing.expectEqual(expected_sub.len, idx);

    // 在子树子节点 .leave 后调用 skipChildren，验证跳过当前父节点剩余子节点且更外层兄弟节点偏移准确
    const outer_tail = try alloc.create(GreenNode);
    outer_tail.* = .{ .kind = .comma, .text_len = 1, .payload = .{ .leaf = "," } };
    const outer_kids = try alloc.alloc(*const GreenNode, 2);
    outer_kids[0] = sample.rhs_group;
    outer_kids[1] = outer_tail;
    const outer_root = try alloc.create(GreenNode);
    outer_root.* = .{ .kind = .source_file, .text_len = 7, .payload = .{ .tree = outer_kids } };

    var leave_skip_trav = GreenTraversal.init(gpa, .{ .root = outer_root });
    defer leave_skip_trav.deinit();
    const expected_leave_skip = [_]GreenTraversal.Event{
        .{ .enter = .{ .green = outer_root, .start = 0 } },
        .{ .enter = .{ .green = sample.rhs_group, .start = 0 } },
        .{ .enter = .{ .green = sample.empty_leaf, .start = 0 } },
        .{ .leave = .{ .green = sample.empty_leaf, .start = 0 } },
        .{ .enter = .{ .green = sample.b_leaf, .start = 0 } },
        .{ .leave = .{ .green = sample.b_leaf, .start = 0 } },
        .{ .leave = .{ .green = sample.rhs_group, .start = 0 } },
        .{ .enter = .{ .green = outer_tail, .start = 6 } },
        .{ .leave = .{ .green = outer_tail, .start = 6 } },
        .{ .leave = .{ .green = outer_root, .start = 0 } },
    };
    idx = 0;
    while (try leave_skip_trav.next()) |ev| {
        try std.testing.expectEqual(expected_leave_skip[idx], ev);
        if (ev == .leave and ev.leave.green == sample.b_leaf) {
            leave_skip_trav.skipChildren();
        }
        idx += 1;
    }
    try std.testing.expectEqual(expected_leave_skip.len, idx);
}
