// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 语法解析事件流协议。
//!
//! 解析器只产生事件而把 Lossless CST 的构建交给下游构建器，以保证绿树的只读性。
//! `start_node` 与 `wrap_node` 的总次数与 `finish_node` 严格相等。位置信息仅由
//! `token` 与 `parse_error` 携带。

const std = @import("std");
const syntax = @import("syntax.zig");
const source_mod = @import("source.zig");
const parse_error_mod = @import("parse_error.zig");

const SyntaxKind = syntax.SyntaxKind;
const TextRange = source_mod.TextRange;
const ParseError = parse_error_mod.ParseError;

/// 词法叶子事件，携带经语法分析确定后的 CST 叶子标签与源码字节区间。
pub const TokenEvent = struct {
    kind: SyntaxKind,
    range: TextRange,
};

/// 解析事件。
pub const Event = union(enum) {
    /// 标识语法节点开始。
    start_node: SyntaxKind,
    /// 将当前父节点已完成子节点列表的最后一项包进新节点，成为其首个子节点。
    ///
    /// 如对于 `a + b + c`，产生事件 `[a], wrap_node(binary_expr), token(+), [b], finish_node, wrap_node(binary_expr), token(+), [c], finish_node`。
    wrap_node: SyntaxKind,
    /// 发射叶子词法单元。
    token: TokenEvent,
    /// 标识当前语法节点结束。
    finish_node: void,
    /// 记录语法诊断，不破坏节点开闭平衡。
    parse_error: ParseError,
};

/// 紧凑事件存储（12 字节），避免对外 `Event` 联合体的尾部填充开销。
pub const CompactEvent = struct {
    /// 紧凑事件类型标签。
    pub const Tag = enum(u8) {
        start_node,
        wrap_node,
        token,
        finish_node,
        parse_error,
    };

    range: TextRange = .{ .start = 0, .end = 0 },
    payload: u16 = 0,
    tag: Tag,

    /// 构造 `start_node` 紧凑事件。
    pub inline fn startNode(kind: SyntaxKind) CompactEvent {
        return .{ .payload = @backingInt(kind), .tag = .start_node };
    }

    /// 构造 `wrap_node` 紧凑事件。
    pub inline fn wrapNode(kind: SyntaxKind) CompactEvent {
        return .{ .payload = @backingInt(kind), .tag = .wrap_node };
    }

    /// 构造 `token` 紧凑事件。
    pub inline fn token(kind: SyntaxKind, range: TextRange) CompactEvent {
        return .{ .range = range, .payload = @backingInt(kind), .tag = .token };
    }

    /// 构造 `finish_node` 紧凑事件。
    pub inline fn finishNode() CompactEvent {
        return .{ .tag = .finish_node };
    }

    /// 构造 `parse_error` 紧凑事件。
    pub inline fn parseError(err: ParseError) CompactEvent {
        return .{ .range = err.range, .payload = @backingInt(err.code), .tag = .parse_error };
    }

    /// 转换为对外导出的 `Event`。
    pub inline fn toEvent(self: CompactEvent) Event {
        return switch (self.tag) {
            .start_node => .{ .start_node = @fromBackingInt(@intCast(self.payload)) },
            .wrap_node => .{ .wrap_node = @fromBackingInt(@intCast(self.payload)) },
            .token => .{ .token = .{ .kind = @fromBackingInt(@intCast(self.payload)), .range = self.range } },
            .finish_node => .finish_node,
            .parse_error => .{ .parse_error = .{
                .code = @fromBackingInt(@intCast(self.payload)),
                .range = self.range,
            } },
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(CompactEvent) == 12);
}

test "紧凑事件往返转换为对外事件" {
    const range: TextRange = .{ .start = 4, .end = 9 };
    try std.testing.expectEqual(Event{ .start_node = .source_file }, CompactEvent.startNode(.source_file).toEvent());
    try std.testing.expectEqual(Event{ .wrap_node = .binary_expr }, CompactEvent.wrapNode(.binary_expr).toEvent());
    try std.testing.expectEqual(Event{ .token = .{ .kind = .identifier, .range = range } }, CompactEvent.token(.identifier, range).toEvent());
    try std.testing.expectEqual(Event.finish_node, CompactEvent.finishNode().toEvent());
    try std.testing.expectEqual(Event{ .parse_error = .{ .code = .expected_token, .range = range } }, CompactEvent.parseError(.{
        .code = .expected_token,
        .range = range,
    }).toEvent());
}
