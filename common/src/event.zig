// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 语法解析事件流协议。
//!
//! 解析器只产生事件而把 Lossless CST 的构建交给下游构建器，以保证绿树的只读性。
//! `start_node` 与 `wrap_node` 的总次数与 `finish_node` 严格相等。位置信息仅由
//! `token` 与 `parse_error` 携带。

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
