// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 把解析事件流构建为不可变绿树。
//!
//! `GreenBuilder` 是只接收节点开闭与叶子指令的状态机；`treeBuild` 消费
//! `common.Event` 切片并构建最终绿树。

const std = @import("std");
const common = @import("common");

const lexer = @import("./lexer.zig");
const parser = @import("./parser.zig");

const SyntaxKind = common.SyntaxKind;
const TextRange = common.TextRange;
const Event = common.Event;
const GreenNode = common.GreenNode;
const GreenTree = common.GreenTree;

/// 基于后进先出节点列表的绿树构建状态机。
///
/// 构建期间使用 `gpa` 存放未结束节点列表与每个节点临时的子节点列表，`finishNode` 时把这些列表
/// 复制进 `arena`，最终节点、子节点指针数组与叶子文本都由 `arena` 持有。返回的节点在
/// `arena` 释放之前保持有效，调用者不得单独释放。
pub const GreenBuilder = struct {
    /// 构建期间临时内存的分配器。
    gpa: std.mem.Allocator,
    /// 最终节点、子节点指针数组与叶子文本的分配器。
    arena: std.mem.Allocator,
    /// 叶子事件区间对应的完整源码，只在构建期间借用。
    source: []const u8,
    /// 尚未结束的节点列表，列表末尾是当前正在填充子节点的节点。
    frames: std.ArrayListUnmanaged(Frame) = .empty,
    /// 已经结束的根节点。
    root: ?*const GreenNode = null,

    /// 单个尚未结束的节点。
    const Frame = struct {
        kind: SyntaxKind,
        children: std.ArrayListUnmanaged(*const GreenNode) = .empty,
        text_len: u32 = 0,
    };

    /// 创建空构建器。`source` 只在构建期间借用，`arena` 必须比返回的绿树活得久。
    pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator, source: []const u8) GreenBuilder {
        return .{ .gpa = gpa, .arena = arena, .source = source };
    }

    /// 释放构建期间的临时内存。已经写入 `arena` 的节点不受影响。
    pub fn deinit(self: *GreenBuilder) void {
        for (self.frames.items) |*frame| frame.children.deinit(self.gpa);
        self.frames.deinit(self.gpa);
        self.* = undefined;
    }

    /// 开始一个新节点。新节点成为当前节点，直到对应的 `finishNode`。
    pub fn startNode(self: *GreenBuilder, kind: SyntaxKind) std.mem.Allocator.Error!void {
        if (self.frames.items.len == 0) std.debug.assert(self.root == null);
        try self.frames.append(self.gpa, .{ .kind = kind });
    }

    /// 把当前节点的最后一个已完成子节点包裹进新节点，新节点成为当前节点。
    ///
    /// 新节点以被包裹的子节点作为首个子节点；其后的叶子与其他节点继续追加到新节点中，
    /// 直到对应的 `finishNode` 把整个新节点交还给原父节点。
    pub fn wrapNode(self: *GreenBuilder, kind: SyntaxKind) std.mem.Allocator.Error!void {
        std.debug.assert(self.frames.items.len > 0);
        std.debug.assert(self.frames.items[self.frames.items.len - 1].children.items.len > 0);

        var frame: Frame = .{ .kind = kind };
        errdefer frame.children.deinit(self.gpa);
        try frame.children.ensureTotalCapacity(self.gpa, 1);
        try self.frames.ensureUnusedCapacity(self.gpa, 1);

        const parent = &self.frames.items[self.frames.items.len - 1];
        const child = parent.children.pop().?;
        std.debug.assert(parent.text_len >= child.text_len);
        parent.text_len -= child.text_len;

        frame.text_len = child.text_len;
        frame.children.appendAssumeCapacity(child);
        self.frames.appendAssumeCapacity(frame);
    }

    /// 追加一个叶子节点。叶子文本从 `source` 复制进 `arena`，不引用源码切片。
    pub fn token(self: *GreenBuilder, kind: SyntaxKind, range: TextRange) std.mem.Allocator.Error!void {
        std.debug.assert(self.frames.items.len > 0);
        std.debug.assert(range.start <= range.end);
        std.debug.assert(range.end <= self.source.len);

        const text = try self.arena.dupe(u8, self.source[range.start..range.end]);
        const node = try self.arena.create(GreenNode);
        node.* = .{
            .kind = kind,
            .text_len = range.len(),
            .payload = .{ .leaf = text },
        };

        const frame = &self.frames.items[self.frames.items.len - 1];
        std.debug.assert(frame.text_len <= std.math.maxInt(u32) - node.text_len);
        try frame.children.append(self.gpa, node);
        frame.text_len += node.text_len;
    }

    /// 结束当前节点，把它作为子节点交还给父节点；结束根节点时记录到 `root`。
    pub fn finishNode(self: *GreenBuilder) std.mem.Allocator.Error!void {
        std.debug.assert(self.frames.items.len > 0);
        const is_root = self.frames.items.len == 1;
        if (!is_root) {
            const parent = &self.frames.items[self.frames.items.len - 2];
            try parent.children.ensureUnusedCapacity(self.gpa, 1);
        }

        const top = &self.frames.items[self.frames.items.len - 1];
        const children = try self.arena.dupe(*const GreenNode, top.children.items);
        const node = try self.arena.create(GreenNode);
        node.* = .{
            .kind = top.kind,
            .text_len = top.text_len,
            .payload = .{ .tree = children },
        };
        const finished: *const GreenNode = node;

        var frame = self.frames.pop().?;
        frame.children.deinit(self.gpa);

        if (is_root) {
            std.debug.assert(self.root == null);
            self.root = finished;
        } else {
            const parent = &self.frames.items[self.frames.items.len - 1];
            std.debug.assert(parent.text_len <= std.math.maxInt(u32) - finished.text_len);
            parent.children.appendAssumeCapacity(finished);
            parent.text_len += finished.text_len;
        }
    }

    /// 获取已完成的根节点。调用前须确保未结束节点列表为空且存在已完成的根节点。
    ///
    /// 返回的指针借用自 `arena`，调用者不得单独释放。
    pub fn finish(self: *GreenBuilder) *const GreenNode {
        std.debug.assert(self.frames.items.len == 0);
        return self.root orelse unreachable;
    }
};

/// 从解析事件流构建绿树。
///
/// `source` 是事件区间对应的完整源码；叶子文本复制进 `arena`，构建完成后不再引用
/// `source`。`gpa` 只用于构建期间的未结束节点列表与临时子节点列表，`arena` 用于最终节点、子节点
/// 指针数组与叶子文本，必须比返回的绿树活得久，通常传入 `File.allocator()`。
///
/// 返回绿树中的节点指针借用自 `arena`，调用者不得单独释放。`parse_error` 事件会被忽略，
/// 诊断由调用方从解析器读取。根节点类型由事件流决定，不要求是 `source_file`。
pub fn treeBuild(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
    events: []const Event,
) std.mem.Allocator.Error!GreenTree {
    var builder = GreenBuilder.init(gpa, arena, source);
    defer builder.deinit();
    for (events) |ev| {
        switch (ev) {
            .start_node => |kind| try builder.startNode(kind),
            .wrap_node => |kind| try builder.wrapNode(kind),
            .token => |tok| try builder.token(tok.kind, tok.range),
            .finish_node => try builder.finishNode(),
            .parse_error => {},
        }
    }
    return .{ .root = builder.finish() };
}

/// 按叶子顺序把绿树的文本追加到输出缓冲，测试中用于校验无损还原。
fn appendLeafText(node: *const GreenNode, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    if (node.tokenText()) |text| {
        try out.appendSlice(gpa, text);
        return;
    }
    for (node.children()) |child| try appendLeafText(child, out, gpa);
}

test "GreenBuilder 构建叶子、包裹节点并复制叶子文本" {
    const gpa = std.testing.allocator;
    var source_buffer = [_]u8{ '1', '+', '2' };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var builder = GreenBuilder.init(gpa, arena.allocator(), &source_buffer);
    defer builder.deinit();

    try builder.startNode(.error_node);
    try builder.token(.integer_literal, .{ .start = 0, .end = 1 });
    try builder.wrapNode(.binary_expr);
    try builder.token(.add, .{ .start = 1, .end = 2 });
    try builder.token(.integer_literal, .{ .start = 2, .end = 3 });
    try builder.finishNode();
    try builder.finishNode();

    const tree: GreenTree = .{ .root = builder.finish() };
    try std.testing.expectEqual(SyntaxKind.error_node, tree.root.kind);
    try std.testing.expectEqual(@as(u32, 3), tree.textLen());
    try std.testing.expectEqual(@as(usize, 1), tree.root.childCount());

    const binary = tree.root.childAt(0).?;
    try std.testing.expectEqual(SyntaxKind.binary_expr, binary.kind);
    try std.testing.expectEqual(@as(u32, 3), binary.text_len);
    try std.testing.expectEqual(@as(usize, 3), binary.childCount());
    try std.testing.expectEqualStrings("1", binary.childAt(0).?.tokenText().?);
    try std.testing.expectEqualStrings("+", binary.childAt(1).?.tokenText().?);
    try std.testing.expectEqualStrings("2", binary.childAt(2).?.tokenText().?);
    try std.testing.expectEqual(SyntaxKind.add, binary.childOfKind(.add).?.kind);
    try std.testing.expect(tree.root.childOfKind(.binary_expr) == binary);

    const loc0 = tree.nodeAt(0).?;
    try std.testing.expectEqual(@as(u32, 0), loc0.start);
    try std.testing.expectEqualStrings("1", loc0.green.tokenText().?);
    const loc1 = tree.nodeAt(1).?;
    try std.testing.expectEqual(@as(u32, 1), loc1.start);
    try std.testing.expectEqualStrings("+", loc1.green.tokenText().?);
    const loc2 = tree.nodeAt(2).?;
    try std.testing.expectEqual(@as(u32, 2), loc2.start);
    try std.testing.expectEqualStrings("2", loc2.green.tokenText().?);
    try std.testing.expect(tree.nodeAt(3) == null);

    source_buffer[0] = '9';
    try std.testing.expectEqualStrings("1", tree.nodeAt(0).?.green.tokenText().?);
}

test "treeBuild 分发事件并忽略解析诊断" {
    const gpa = std.testing.allocator;
    const source = "a";

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const events = [_]Event{
        .{ .start_node = .source_file },
        .{ .parse_error = .{ .code = .unexpected_token, .range = .{ .start = 0, .end = 1 } } },
        .{ .token = .{ .kind = .identifier, .range = .{ .start = 0, .end = 1 } } },
        .finish_node,
    };

    const tree = try treeBuild(gpa, arena.allocator(), source, &events);
    try std.testing.expectEqual(SyntaxKind.source_file, tree.root.kind);
    try std.testing.expectEqual(@as(u32, 1), tree.textLen());
    const loc = tree.nodeAt(0).?;
    try std.testing.expectEqual(@as(u32, 0), loc.start);
    try std.testing.expectEqualStrings("a", loc.green.tokenText().?);
}

/// 供分配失败测试调用的构建例程，覆盖 start_node、token、wrap_node 与 finish_node。
fn buildWithAllocationChecks(gpa: std.mem.Allocator) !void {
    const source = "1+2";
    const events = [_]Event{
        .{ .start_node = .source_file },
        .{ .token = .{ .kind = .integer_literal, .range = .{ .start = 0, .end = 1 } } },
        .{ .wrap_node = .binary_expr },
        .{ .token = .{ .kind = .add, .range = .{ .start = 1, .end = 2 } } },
        .{ .token = .{ .kind = .integer_literal, .range = .{ .start = 2, .end = 3 } } },
        .finish_node,
        .finish_node,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const tree = try treeBuild(gpa, arena.allocator(), source, &events);
    try std.testing.expectEqual(@as(u32, 3), tree.textLen());
}

test "treeBuild 在任意分配失败点上返回错误且不泄漏" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildWithAllocationChecks, .{});
}

test "GreenBuilder 支持包裹后立即结束的单子节点" {
    const gpa = std.testing.allocator;
    const source = "abc";

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const events = [_]Event{
        .{ .start_node = .source_file },
        .{ .token = .{ .kind = .identifier, .range = .{ .start = 0, .end = 3 } } },
        .{ .wrap_node = .path_segment },
        .finish_node,
        .finish_node,
    };

    const tree = try treeBuild(gpa, arena.allocator(), source, &events);
    try std.testing.expectEqual(@as(u32, 3), tree.textLen());
    try std.testing.expectEqual(@as(usize, 1), tree.root.childCount());

    const segment = tree.root.childAt(0).?;
    try std.testing.expectEqual(SyntaxKind.path_segment, segment.kind);
    try std.testing.expectEqual(@as(usize, 1), segment.childCount());
    try std.testing.expectEqualStrings("abc", segment.childAt(0).?.tokenText().?);
}

test "解析器事件流构建无损绿树" {
    const gpa = std.testing.allocator;
    const source =
        \\package demo
        \\import std.core.*
        \\class Box {
        \\    let value: Int64
        \\    func get(): Int64 { value }
        \\}
        \\
    ;

    var tokens: std.ArrayList(common.Token) = .empty;
    defer tokens.deinit(gpa);
    var lex = try lexer.Lexer.new(source);
    while (true) {
        const tok = try lex.gen();
        try tokens.append(gpa, tok);
        if (tok.tag == .end) break;
    }

    var parser_instance = parser.Parser.new(gpa, source, tokens.items);
    defer parser_instance.deinit();
    try parser_instance.parse();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const tree = try treeBuild(gpa, arena.allocator(), source, parser_instance.events.items);
    try std.testing.expectEqual(@as(u32, @intCast(source.len)), tree.textLen());

    var rebuilt: std.ArrayList(u8) = .empty;
    defer rebuilt.deinit(gpa);
    try appendLeafText(tree.root, &rebuilt, gpa);
    try std.testing.expectEqualStrings(source, rebuilt.items);

    try std.testing.expectEqual(SyntaxKind.source_file, tree.root.kind);
    try std.testing.expect(tree.root.childOfKind(.class_decl) != null);
}
