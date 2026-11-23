// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 仓颉模式语法解析模块。
//!
//! 覆盖通配模式、变量绑定模式、常量字面量模式（含 `()` Unit 字面量）、元组模式、
//! 枚举构造器模式、类型模式、异常捕获模式（`catch`）与代数效应处理模式（`handle`）。

const std = @import("std");
const common = @import("common");
const TokenTag = common.TokenTag;
const parser_mod = @import("../parser.zig");
const Parser = parser_mod.Parser;
const type_parser = parser_mod.type_parser;

/// 解析通用模式（用于 `match`、`if let`、`while let` 等位置）。
///
/// 当 `allow_type_pattern` 为 `true` 时支持 `x: Type` 与 `_: Type` 类型模式（如 `match` 分支）；
/// 当 `allow_type_pattern` 为 `false` 时用于 `let`/`var` 声明（其后的 `:` 属于变量类型标注）。
pub fn parsePattern(p: *Parser, allow_type_pattern: bool) std.mem.Allocator.Error!void {
    if (!try p.enterDepth()) return;
    defer p.leaveDepth();

    if (p.isNewlineDeclBoundary()) {
        try p.emitError(.expected_pattern);
        return;
    }

    const tag = p.peek();
    switch (tag) {
        .wildcard => {
            if (allow_type_pattern and p.peekNth(1) == .colon) {
                try parseTypePattern(p);
            } else {
                try parseWildcardPattern(p);
            }
        },
        .l_paren => {
            // `()` 按规范属于 `unitLiteral` 常量模式，而非空元组模式
            if (p.peekNth(1) == .r_paren) {
                try parseUnitConstPattern(p);
            } else {
                try parseTuplePattern(p, allow_type_pattern);
            }
        },
        .integer_literal,
        .float_literal,
        .rune_literal,
        .rune_byte_literal,
        .bool_literal,
        .string_literal,
        .multiline_string,
        .multiline_raw_string,
        => try parseConstPattern(p),
        .sub => {
            const next = p.peekNth(1);
            if (next == .integer_literal or next == .float_literal) {
                try parseConstPattern(p);
            } else {
                try p.emitError(.expected_pattern);
            }
        },
        else => {
            if (Parser.isIdentLike(tag)) {
                const next = p.peekNth(1);
                if (allow_type_pattern and next == .colon) {
                    try parseTypePattern(p);
                } else {
                    try parseIdentOrEnumPattern(p, allow_type_pattern, next);
                }
            } else {
                try p.emitError(.expected_pattern);
            }
        },
    }
}

/// 解析通配符模式 `_`。
pub fn parseWildcardPattern(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.wildcard_pattern);
    try p.emitLeadingTrivia(false);
    try p.bump();
    try p.finishNode();
}

/// 解析 `()` Unit 字面量常量模式。
fn parseUnitConstPattern(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.const_pattern);
    try p.emitLeadingTrivia(false);
    try p.startNode(.unit_literal);
    try p.bump(); // (
    try p.bump(); // )
    try p.finishNode(); // unit_literal
    try p.finishNode(); // const_pattern
}

/// 解析字面量常量模式（含带前缀负号的数值字面量，如 `-1`、`-1.5`）。
fn parseConstPattern(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.const_pattern);
    try p.emitLeadingTrivia(false);
    if (p.at(.sub)) {
        try p.bump();
    }
    try p.bump();
    try p.finishNode();
}

/// 解析类型模式 `(ident | _) : Type`。
fn parseTypePattern(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.type_pattern);
    try p.emitLeadingTrivia(false);
    if (p.at(.wildcard)) {
        try p.bump();
    } else {
        _ = try p.expectIdent();
    }
    _ = try p.expect(.colon);
    try type_parser.parseType(p);
    try p.finishNode();
}

/// 解析元组模式 `(pat1, pat2, ...)`，支持缺失逗号恢复与外层边界保护。
fn parseTuplePattern(p: *Parser, allow_type_pattern: bool) std.mem.Allocator.Error!void {
    try p.startNode(.tuple_pattern);
    try p.emitLeadingTrivia(false);
    try p.bump(); // (
    while (!p.shouldStopList(.pattern_list)) {
        const before = p.cursor;
        try parsePattern(p, allow_type_pattern);
        if (try p.eat(.comma)) {
            continue;
        } else if (p.shouldStopList(.pattern_list)) {
            break;
        } else if (p.canStartPattern()) {
            try p.emitError(.expected_token);
        } else {
            break;
        }
        if (p.cursor == before) {
            try p.bumpErrorToken(.expected_pattern);
        }
    }
    _ = try p.expectClosing(.r_paren);
    try p.finishNode();
}

/// 区分单标识符变量绑定模式（`var_pattern`）与枚举构造器模式（`enum_pattern`，含点分路径或参数括号）。
fn parseIdentOrEnumPattern(p: *Parser, allow_type_pattern: bool, next: TokenTag) std.mem.Allocator.Error!void {
    const maybe_enum = next == .dot or next == .l_paren or next == .less;
    if (!maybe_enum) {
        try p.startNode(.var_pattern);
        try p.emitLeadingTrivia(false);
        try p.bumpAs(.identifier);
        try p.finishNode();
        return;
    }

    const cp = p.checkpoint();
    try p.startNode(.enum_pattern);
    try p.emitLeadingTrivia(false);
    try p.startNode(.path_expr);

    const parsed_type_args = try parseEnumPathSegment(p);
    var has_dot_or_paren = false;
    while (p.at(.dot)) {
        has_dot_or_paren = true;
        try p.bump();
        _ = try parseEnumPathSegment(p);
    }
    try p.finishNode(); // path_expr

    if (p.at(.l_paren)) {
        has_dot_or_paren = true;
        try p.bump(); // (
        while (!p.shouldStopList(.pattern_list)) {
            const before = p.cursor;
            try parsePattern(p, allow_type_pattern);
            if (try p.eat(.comma)) {
                continue;
            } else if (p.shouldStopList(.pattern_list)) {
                break;
            } else if (p.canStartPattern()) {
                try p.emitError(.expected_token);
            } else {
                break;
            }
            if (p.cursor == before) {
                try p.bumpErrorToken(.expected_pattern);
            }
        }
        _ = try p.expectClosing(.r_paren);
    }

    try p.finishNode(); // enum_pattern

    // 仅当由 `<` 触发试探、既未成功解析出泛型实参又未出现 `.` 或 `(` 时，才回退为简单 `var_pattern`
    if (next == .less and !parsed_type_args and !has_dot_or_paren) {
        p.rollback(cp);
        try p.startNode(.var_pattern);
        try p.emitLeadingTrivia(false);
        try p.bumpAs(.identifier);
        try p.finishNode();
    }
}

/// 解析枚举构造器路径中的单个 `path_segment`（标识符与可选泛型实参），返回是否解析出了类型实参表。
fn parseEnumPathSegment(p: *Parser) std.mem.Allocator.Error!bool {
    try p.startNode(.path_segment);
    if (p.isNewlineDeclBoundary()) {
        try p.emitError(.expected_identifier);
        try p.finishNode();
        return false;
    }
    try p.emitLeadingTrivia(false);
    _ = try p.expectIdent();
    var parsed_args = false;
    if (p.at(.less)) {
        parsed_args = try type_parser.tryParsePatternTypeArguments(p);
    }
    try p.finishNode();
    return parsed_args;
}

/// 解析 `catch (...)` 内的捕获模式：`wildcard_pattern` 或 `except_type_pattern`（支持 `T1 | T2`）。
pub fn parseCatchPattern(p: *Parser) std.mem.Allocator.Error!void {
    if (p.at(.wildcard) and p.peekNth(1) != .colon) {
        try parseWildcardPattern(p);
        return;
    }
    try parseTypedClausePattern(p, .except_type_pattern);
}

/// 解析 `handle (...)` 内的效应命令模式：`command_type_pattern`（支持 `T1 | T2`）。
pub fn parseHandlePattern(p: *Parser) std.mem.Allocator.Error!void {
    if (p.at(.wildcard) and p.peekNth(1) != .colon) {
        try parseWildcardPattern(p);
        return;
    }
    try parseTypedClausePattern(p, .command_type_pattern);
}

/// 解析 `catch` / `handle` 共用的 `(ident | _) : Type (| Type)*` 模式结构。
fn parseTypedClausePattern(p: *Parser, kind: common.SyntaxKind) std.mem.Allocator.Error!void {
    try p.startNode(kind);
    try p.emitLeadingTrivia(false);
    if (p.at(.wildcard)) {
        try p.bump();
    } else {
        _ = try p.expectIdent();
    }
    if (try p.expect(.colon)) {
        try type_parser.parseType(p);
        while (try p.eat(.bit_or)) {
            try type_parser.parseType(p);
        }
    }
    try p.finishNode();
}
