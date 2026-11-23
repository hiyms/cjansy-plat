// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 仓颉表达式、语句块、控制流、`quote(...)` 与字符串插值解析模块。
//!
//! 表达式二元与赋值层采用 Pratt 解析，优先级与结合性以 `cangjie_spec` 为基准，
//! 面向分析平台保持相对宽松的容错与建树策略；前缀、后缀与块语句严格遵守只读前瞻、
//! 惰性 Trivia 发射、`wrap_node` 非空左操作数校验与递归深度保护不变式。

const std = @import("std");
const common = @import("common");
const TokenTag = common.TokenTag;
const SyntaxKind = common.SyntaxKind;
const parser_mod = @import("../parser.zig");
const Parser = parser_mod.Parser;
const CombinedOp = parser_mod.CombinedOp;
const decl = parser_mod.decl;
const type_parser = parser_mod.type_parser;
const pattern = parser_mod.pattern;

/// 运算符优先级层级（按 `cangjie_spec` 运算符优先级总表从低到高排列）。
const Prec = struct {
    const lowest: u8 = 0;
    const assign: u8 = 1; // = += -= *= **= /= %= &&= ||= &= |= ^= <<= >>=（非结合）
    const flow: u8 = 2; // |> ~>（左结合）
    const coalescing: u8 = 3; // ??（右结合）
    const logical_or: u8 = 4; // ||（左结合）
    const logical_and: u8 = 5; // &&（左结合）
    const bit_or: u8 = 6; // |（左结合）
    const bit_xor: u8 = 7; // ^（左结合）
    const bit_and: u8 = 8; // &（左结合）
    const equality: u8 = 9; // == !=（非结合）
    const comparison: u8 = 10; // < <= > >= is as（非结合）
    const range: u8 = 11; // .. ..=（非结合）
    const shift: u8 = 12; // << >>（左结合）
    const additive: u8 = 13; // + -（左结合）
    const multiplicative: u8 = 14; // * / %（左结合）
    const exponent: u8 = 15; // **（右结合）
};

/// 表达式左侧解析状态，用于保障 `wrap_node` 绝不抓空或错抓前序兄弟节点，并记录点分路径状态。
const LhsKind = enum {
    /// 未产出任何子节点（出错或触发递归深度上限），禁止对其执行 `wrap_node`。
    missing,
    /// 普通表达式节点。
    general,
    /// 平铺的 `path_expr` 节点。
    path_node,
};

/// 二元/中缀运算符分类信息。
const InfixInfo = struct {
    prec: u8,
    right_prec: u8,
    kind: enum {
        binary,
        assign,
        range,
        is_type,
        as_type,
    },
    non_assoc: bool = false,
    combined: ?CombinedOp = null,
};

/// 解析完整语句块 `{ stmt_list }`，内部重置上下文限制以允许正常尾随闭包。
pub fn parseBlock(p: *Parser) std.mem.Allocator.Error!void {
    if (!try p.enterDepth()) return;
    defer p.leaveDepth();

    const saved = p.restrictions;
    p.restrictions = .{};
    defer p.restrictions = saved;

    try p.startNode(.block);
    try p.emitLeadingTrivia(false);
    _ = try p.expect(.l_curl);
    _ = try parseStmtList(p, .r_curl, false);
    _ = try p.expectClosing(.r_curl);
    try p.finishNode();
}

/// 解析语句序列 `stmt_list`，持续消费直到遇到终止符（`}`、`case` 或文件尾），返回解析出的语句条数。
pub fn parseStmtList(p: *Parser, stop_tag: TokenTag, stop_at_case: bool) std.mem.Allocator.Error!usize {
    try p.startNode(.stmt_list);

    var count: usize = 0;
    while (true) {
        _ = try p.eatSemicolons();
        const cur = p.peek();
        if (cur == .end or cur == stop_tag) break;
        if (stop_at_case and cur == .kw_case) break;

        const before = p.cursor;
        if (decl.peekLocalDeclKind(p)) |decl_kind| {
            try decl.parseDeclWithKind(p, .local_block, decl_kind);
        } else {
            try parseExprStmt(p);
        }

        if (p.cursor == before) {
            try p.bumpErrorRun(.expected_expression, true);
        }
        count += 1;
        _ = try p.eatSemicolons();
    }

    try p.finishNode();
    return count;
}

/// 解析表达式语句 `expression_statement`（含同行尾随可选 `;`）。
fn parseExprStmt(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.expression_statement);
    try p.emitLeadingTrivia(false);
    const lhs = try parseExprBp(p, Prec.lowest);
    if (lhs == .missing and !p.isAtEof()) {
        const cur = p.peek();
        if (cur != .r_curl and cur != .semi and cur != .kw_case and !p.isNewlineDeclBoundary()) {
            // `parseExprBp` 已记录 `.expected_expression`，此处仅最小范围吞并异常词法单元避免重复诊断
            try p.bumpErrorRun(null, true);
        }
    }
    if (p.peekNoNl() == .semi) {
        try p.bumpNoNl();
    }
    try p.finishNode();
}

/// 解析完整表达式（默认允许尾随闭包与区间步长）。
pub fn parseExpr(p: *Parser) std.mem.Allocator.Error!void {
    _ = try parseExprBp(p, Prec.lowest);
}

/// 在临时修改 `Restrictions` 的上下文中解析表达式，退出时自动恢复原标志。
fn parseExprWithRestrictions(p: *Parser, r: parser_mod.Restrictions) std.mem.Allocator.Error!LhsKind {
    const saved = p.restrictions;
    p.restrictions = r;
    defer p.restrictions = saved;
    return parseExprBp(p, Prec.lowest);
}

/// Pratt 表达式核心：按最小绑定强度 `min_prec` 解析表达式并返回最外层左侧状态。
fn parseExprBp(p: *Parser, min_prec: u8) std.mem.Allocator.Error!LhsKind {
    if (!try p.enterDepth()) return .missing;
    defer p.leaveDepth();

    var lhs = try parsePrefixExpr(p);
    if (lhs == .missing) return .missing;

    var last_non_assoc_prec: u8 = 0;

    while (true) {
        const info = peekInfixOp(p) orelse break;

        if (info.non_assoc and last_non_assoc_prec == info.prec) {
            const err_code: parser_mod.ParseErrorCode = switch (info.kind) {
                .assign => .non_associative_assignment,
                .range => .non_associative_operator,
                else => .non_associative_comparison,
            };
            try p.emitError(err_code);
        } else if (info.prec < min_prec) {
            break;
        }

        switch (info.kind) {
            .assign => {
                try p.wrapNode(.assign_expr);
                if (info.combined) |comb| {
                    try p.bumpCombined(comb, true);
                } else {
                    try p.bump();
                }
                _ = try parseExprBp(p, info.right_prec);
                try p.finishNode();
                lhs = .general;
                last_non_assoc_prec = Prec.assign;
            },
            .range => {
                try p.wrapNode(.range_expr);
                try p.bump(); // .. or ..=
                const omit_end = p.restrictions.allow_open_range_end and
                    (p.at(.r_square) or p.at(.comma) or p.at(.colon));
                if (!omit_end) {
                    _ = try parseExprBp(p, Prec.shift);
                }
                if (p.restrictions.allow_range_colon and p.at(.colon)) {
                    try p.bump(); // :
                    _ = try parseExprBp(p, Prec.shift);
                }
                try p.finishNode();
                lhs = .general;
                last_non_assoc_prec = Prec.range;
            },
            .is_type => {
                try p.wrapNode(.is_expr);
                try p.bump(); // is
                try type_parser.parseType(p);
                try p.finishNode();
                lhs = .general;
                last_non_assoc_prec = Prec.comparison;
            },
            .as_type => {
                try p.wrapNode(.as_expr);
                try p.bump(); // as
                try type_parser.parseType(p);
                try p.finishNode();
                lhs = .general;
                last_non_assoc_prec = Prec.comparison;
            },
            .binary => {
                try p.wrapNode(.binary_expr);
                if (info.combined) |comb| {
                    try p.bumpCombined(comb, true);
                } else {
                    try p.bump();
                }
                _ = try parseExprBp(p, info.right_prec);
                try p.finishNode();
                lhs = .general;
                last_non_assoc_prec = if (info.non_assoc) info.prec else 0;
            },
        }
    }

    return lhs;
}

/// 只读识别当前位置的中缀运算符及其优先级、结合性与组合形态。
inline fn peekInfixOp(p: *const Parser) ?InfixInfo {
    return switch (p.sig_tag) {
        .quest => blk: {
            if (p.combinedOpAt(p.sig_idx)) |comb| {
                if (comb.kind == .coalescing) {
                    break :blk .{
                        .prec = Prec.coalescing,
                        .right_prec = Prec.coalescing,
                        .kind = .binary,
                        .combined = comb,
                    };
                }
            }
            break :blk null;
        },
        .greater => blk: {
            if (p.combinedOpAt(p.sig_idx)) |comb| {
                break :blk switch (comb.kind) {
                    .rshift_assign => .{
                        .prec = Prec.assign,
                        .right_prec = Prec.flow,
                        .kind = .assign,
                        .non_assoc = true,
                        .combined = comb,
                    },
                    .greater_equal => .{
                        .prec = Prec.comparison,
                        .right_prec = Prec.range,
                        .kind = .binary,
                        .non_assoc = true,
                        .combined = comb,
                    },
                    .rshift => .{
                        .prec = Prec.shift,
                        .right_prec = Prec.shift + 1,
                        .kind = .binary,
                        .combined = comb,
                    },
                    else => null,
                };
            }
            break :blk .{
                .prec = Prec.comparison,
                .right_prec = Prec.range,
                .kind = .binary,
                .non_assoc = true,
            };
        },
        .assign,
        .add_assign,
        .sub_assign,
        .mul_assign,
        .exp_assign,
        .div_assign,
        .mod_assign,
        .logical_and_assign,
        .logical_or_assign,
        .bit_and_assign,
        .bit_or_assign,
        .bit_xor_assign,
        .lshift_assign,
        => .{
            .prec = Prec.assign,
            .right_prec = Prec.flow,
            .kind = .assign,
            .non_assoc = true,
        },
        .pipeline, .composition => .{
            .prec = Prec.flow,
            .right_prec = Prec.flow + 1,
            .kind = .binary,
        },
        .logical_or => .{
            .prec = Prec.logical_or,
            .right_prec = Prec.logical_or + 1,
            .kind = .binary,
        },
        .logical_and => .{
            .prec = Prec.logical_and,
            .right_prec = Prec.logical_and + 1,
            .kind = .binary,
        },
        .bit_or => .{
            .prec = Prec.bit_or,
            .right_prec = Prec.bit_or + 1,
            .kind = .binary,
        },
        .bit_xor => .{
            .prec = Prec.bit_xor,
            .right_prec = Prec.bit_xor + 1,
            .kind = .binary,
        },
        .bit_and => .{
            .prec = Prec.bit_and,
            .right_prec = Prec.bit_and + 1,
            .kind = .binary,
        },
        .equal, .not_equal => .{
            .prec = Prec.equality,
            .right_prec = Prec.comparison,
            .kind = .binary,
            .non_assoc = true,
        },
        .less, .less_equal => .{
            .prec = Prec.comparison,
            .right_prec = Prec.range,
            .kind = .binary,
            .non_assoc = true,
        },
        .kw_is => .{
            .prec = Prec.comparison,
            .right_prec = Prec.range,
            .kind = .is_type,
            .non_assoc = true,
        },
        .kw_as => .{
            .prec = Prec.comparison,
            .right_prec = Prec.range,
            .kind = .as_type,
            .non_assoc = true,
        },
        .range_op, .closed_range_op => .{
            .prec = Prec.range,
            .right_prec = Prec.shift,
            .kind = .range,
            .non_assoc = true,
        },
        .lshift => .{
            .prec = Prec.shift,
            .right_prec = Prec.shift + 1,
            .kind = .binary,
        },
        .add => .{
            .prec = Prec.additive,
            .right_prec = Prec.additive + 1,
            .kind = .binary,
        },
        .sub => blk: {
            // 新行开头的 `-` 按独立语句的一元负号处理，不与上一行合并为二元减法
            if (p.hasNewlineBefore()) break :blk null;
            break :blk .{
                .prec = Prec.additive,
                .right_prec = Prec.additive + 1,
                .kind = .binary,
            };
        },
        .mul, .div, .mod => .{
            .prec = Prec.multiplicative,
            .right_prec = Prec.multiplicative + 1,
            .kind = .binary,
        },
        .exp => .{
            .prec = Prec.exponent,
            .right_prec = Prec.exponent,
            .kind = .binary,
        },
        else => null,
    };
}

/// 解析前缀一元表达式（`-`、`!`），带递归深度上限保护；否则进入后缀与自增自减层。
fn parsePrefixExpr(p: *Parser) std.mem.Allocator.Error!LhsKind {
    const tag = p.sig_tag;
    if (tag == .sub or tag == .not) {
        if (!try p.enterDepth()) return .missing;
        defer p.leaveDepth();

        const saved = p.restrictions;
        p.restrictions.allow_let_condition = false;
        defer p.restrictions = saved;

        try p.startNode(.unary_expr);
        try p.emitLeadingTrivia(false);
        try p.bump();
        if (p.hasNewlineBefore()) {
            try p.emitError(.expected_expression);
        } else {
            _ = try parsePrefixExpr(p);
        }
        try p.finishNode();
        return .general;
    }

    return parseIncDecExpr(p);
}

/// 解析基础后缀表达式及其后至多一次的同行 `++` / `--`（非结合，低于成员/调用/下标）。
fn parseIncDecExpr(p: *Parser) std.mem.Allocator.Error!LhsKind {
    var lhs = try parsePostfixExpr(p);
    if (lhs == .missing) return .missing;

    const next_no_nl = p.peekNoNl();
    if (next_no_nl == .incr or next_no_nl == .decr) {
        try p.wrapNode(.inc_or_dec_expr);
        try p.bumpNoNl();
        try p.finishNode();
        lhs = .general;

        const after = p.peekNoNl();
        if (after == .incr or after == .decr) {
            try p.emitError(.non_associative_operator);
            try p.wrapNode(.inc_or_dec_expr);
            try p.bumpNoNl();
            try p.finishNode();
        }
    }

    return lhs;
}

/// 解析原子表达式与左结合基础后缀链（`.`、`?.`、`(...)`、`[...]`、尾随 `{ ... }`、带注解尾随闭包与可选链）。
fn parsePostfixExpr(p: *Parser) std.mem.Allocator.Error!LhsKind {
    var lhs = try parseAtomExpr(p);
    if (lhs == .missing) return .missing;

    while (true) {
        const before = p.cursor;

        // 1. 允许跨行的成员访问 `.seg`（非路径表达式首段包裹为 `path_segment`，全链平铺进 `path_expr`）
        if (p.at(.dot)) {
            if (lhs != .path_node) {
                try p.wrapNode(.path_segment);
                try p.finishNode();
            }
            try p.wrapNode(.path_expr);
            try parseFlatPathTail(p);
            try p.finishNode();
            lhs = .path_node;
            if (p.cursor == before) break;
            continue;
        }

        // 2. 以下后缀均禁止跨行连接
        const next_no_nl = p.peekNoNl();
        switch (next_no_nl) {
            .l_paren => {
                try p.wrapNode(.call_expr);
                try parseCallArgs(p);
                try p.finishNode();
                lhs = .general;
            },
            .l_square => {
                try p.wrapNode(.subscript_expr);
                try parseSubscriptArgs(p);
                try p.finishNode();
                lhs = .general;
            },
            .l_curl => {
                if (!p.restrictions.allow_trailing_closure) break;
                if (p.depth >= parser_mod.max_recursion_depth) {
                    try p.emitError(.recursive_depth_limit);
                    break;
                }
                try p.wrapNode(.trailing_closure_expr);
                try parseLambdaExpr(p, true, false);
                try p.finishNode();
                lhs = .general;
            },
            .at => {
                // 支持带内置注解的尾随闭包，如 `foo @OverflowWrapping { x => x + 1 }`
                if (!p.restrictions.allow_trailing_closure) break;
                if (!isAnnotatedTrailingLambdaSameLine(p)) break;
                if (p.depth >= parser_mod.max_recursion_depth) {
                    try p.emitError(.recursive_depth_limit);
                    break;
                }
                try p.wrapNode(.trailing_closure_expr);
                try parseLambdaExpr(p, true, true);
                try p.finishNode();
                lhs = .general;
            },
            .quest => {
                if (p.peekCombinedOp(false)) |comb| {
                    if (comb.kind == .coalescing) break;
                }
                const after_q = peekAfterQuest(p);
                switch (after_q) {
                    .dot => {
                        if (lhs != .path_node) {
                            try p.wrapNode(.path_segment);
                            try p.finishNode();
                        }
                        try p.wrapNode(.path_expr);
                        try parseFlatPathTail(p);
                        try p.finishNode();
                        lhs = .path_node;
                    },
                    .l_paren => {
                        try p.wrapNode(.optional_expr);
                        try p.bumpNoNl(); // ?
                        try p.finishNode();
                        try p.wrapNode(.call_expr);
                        try parseCallArgs(p);
                        try p.finishNode();
                        lhs = .general;
                    },
                    .l_square => {
                        try p.wrapNode(.optional_expr);
                        try p.bumpNoNl(); // ?
                        try p.finishNode();
                        try p.wrapNode(.subscript_expr);
                        try parseSubscriptArgs(p);
                        try p.finishNode();
                        lhs = .general;
                    },
                    .l_curl => {
                        if (!p.restrictions.allow_trailing_closure) break;
                        if (p.depth >= parser_mod.max_recursion_depth) {
                            try p.emitError(.recursive_depth_limit);
                            break;
                        }
                        try p.wrapNode(.optional_expr);
                        try p.bumpNoNl(); // ?
                        try p.finishNode();
                        try p.wrapNode(.trailing_closure_expr);
                        try parseLambdaExpr(p, true, false);
                        try p.finishNode();
                        lhs = .general;
                    },
                    else => break,
                }
            },
            else => break,
        }

        if (p.cursor == before) break;
    }

    return lhs;
}

/// 只读判断当前同行是否紧接前置内置注解的尾随闭包（`@Anno ... { ... }`）。
fn isAnnotatedTrailingLambdaSameLine(p: *const Parser) bool {
    const start_idx = p.nextSignificantIndex(p.cursor, false);
    if (start_idx >= p.tokens.len or !decl.isBuiltinAnnotationAtIndex(p, start_idx)) return false;

    var idx = start_idx;
    while (idx < p.tokens.len and decl.isBuiltinAnnotationAtIndex(p, idx)) {
        idx = p.nextSignificantIndex(idx + 1, true);
        if (idx < p.tokens.len and Parser.isIdentLike(p.tokens[idx].tag)) {
            idx = p.nextSignificantIndex(idx + 1, true);
        }
        while (idx < p.tokens.len and p.tokens[idx].tag == .dot) {
            idx = p.nextSignificantIndex(idx + 1, true);
            if (idx < p.tokens.len and Parser.isIdentLike(p.tokens[idx].tag)) {
                idx = p.nextSignificantIndex(idx + 1, true);
            }
        }
        if (idx < p.tokens.len and p.tokens[idx].tag == .l_square) {
            var depth: u32 = 1;
            idx += 1;
            while (idx < p.tokens.len and depth > 0) : (idx += 1) {
                if (p.tokens[idx].tag == .l_square) depth += 1;
                if (p.tokens[idx].tag == .r_square) depth -= 1;
            }
            idx = p.nextSignificantIndex(idx, true);
        }
    }
    return idx < p.tokens.len and p.tokens[idx].tag == .l_curl;
}

/// 只读前瞻同行 `?` 之后的下一个非注释词法单元（用于判定 `?.`、`?(`、`?[`、`?{`）。
fn peekAfterQuest(p: *const Parser) TokenTag {
    const q_idx = p.sig_no_nl_idx;
    if (q_idx >= p.tokens.len or p.sig_no_nl_tag != .quest) return .end;
    const next_idx = p.nextSignificantIndex(q_idx + 1, true);
    if (next_idx >= p.tokens.len) return .end;
    if (p.tokens[next_idx].tag == .dot) return .dot;
    const same_line_idx = p.nextSignificantIndex(q_idx + 1, false);
    if (same_line_idx >= p.tokens.len) return .end;
    return p.tokens[same_line_idx].tag;
}

/// 在已开启的 `path_expr` 内平铺消费连续的 `.seg` 与 `?.seg` 后缀段。
fn parseFlatPathTail(p: *Parser) std.mem.Allocator.Error!void {
    while (true) {
        if (p.at(.dot)) {
            try p.bump();
            try parseExprPathSegment(p);
            continue;
        }
        if (p.peekNoNl() == .quest) {
            if (p.peekCombinedOp(false)) |comb| {
                if (comb.kind == .coalescing) break;
            }
            if (peekAfterQuest(p) == .dot) {
                try p.bumpNoNl();
                try p.bump();
                try parseExprPathSegment(p);
                continue;
            }
        }
        break;
    }
}

/// 解析表达式原子节点；跨行遇明确新声明边界、未能识别或超深未产出节点时返回 `.missing`。
fn parseAtomExpr(p: *Parser) std.mem.Allocator.Error!LhsKind {
    if (p.isNewlineDeclBoundary()) {
        try p.emitError(.expected_expression);
        return .missing;
    }

    const tag = p.peek();
    switch (tag) {
        .integer_literal,
        .float_literal,
        .rune_literal,
        .rune_byte_literal,
        .bool_literal,
        .multiline_raw_string,
        => {
            try p.bump();
            return .general;
        },
        .string_literal, .multiline_string => {
            try parseStringOrInterpolation(p);
            return .general;
        },
        .wildcard => {
            try p.startNode(.wildcard_expr);
            try p.emitLeadingTrivia(false);
            try p.bump();
            try p.finishNode();
            return .general;
        },
        .kw_let => {
            if (p.restrictions.allow_let_condition) {
                try parseLetConditionDestructor(p);
                return .general;
            }
            try p.emitError(.expected_expression);
            return .missing;
        },
        .l_paren => return parseParenUnitOrTupleExpr(p),
        .l_square => {
            try parseArrayLit(p);
            return .general;
        },
        .l_curl => {
            if (p.depth >= parser_mod.max_recursion_depth) {
                try p.emitError(.recursive_depth_limit);
                return .missing;
            }
            try parseLambdaExpr(p, false, false);
            return .general;
        },
        .kw_if => {
            if (p.depth >= parser_mod.max_recursion_depth) {
                try p.emitError(.recursive_depth_limit);
                return .missing;
            }
            try parseIfExpr(p);
            return .general;
        },
        .kw_match => {
            try parseMatchExpr(p);
            return .general;
        },
        .kw_while => {
            try parseWhileExpr(p);
            return .general;
        },
        .kw_do => {
            try parseDoWhileExpr(p);
            return .general;
        },
        .kw_for => {
            try parseForInExpr(p);
            return .general;
        },
        .kw_try => {
            try parseTryExpr(p);
            return .general;
        },
        .kw_throw => {
            try parseThrowExpr(p);
            return .general;
        },
        .kw_return => {
            try parseReturnExpr(p);
            return .general;
        },
        .kw_break, .kw_continue => {
            try p.startNode(.jump_expr);
            try p.emitLeadingTrivia(false);
            try p.bump();
            try p.finishNode();
            return .general;
        },
        .kw_spawn => {
            try parseSpawnExpr(p);
            return .general;
        },
        .kw_synchronized => {
            try parseSynchronizedExpr(p);
            return .general;
        },
        .kw_unsafe => {
            try parseUnsafeExpr(p);
            return .general;
        },
        .kw_quote => {
            if (p.depth >= parser_mod.max_recursion_depth) {
                try p.emitError(.recursive_depth_limit);
                return .missing;
            }
            try parseQuoteExpr(p);
            return .general;
        },
        .kw_perform => {
            try parsePerformExpr(p);
            return .general;
        },
        .kw_resume => {
            try parseResumeExpr(p);
            return .general;
        },
        .kw_varray => {
            try parseVArrayExpr(p);
            return .general;
        },
        .at, .at_excl => {
            if (isIfAvailableStart(p)) {
                try parseIfAvailableExpr(p);
            } else if (decl.isBuiltinAnnotation(p)) {
                if (p.depth >= parser_mod.max_recursion_depth) {
                    try p.emitError(.recursive_depth_limit);
                    return .missing;
                }
                try parseLambdaExpr(p, false, true);
            } else {
                if (p.depth >= parser_mod.max_recursion_depth) {
                    try p.emitError(.recursive_depth_limit);
                    return .missing;
                }
                try parseMacroExpandExpr(p);
            }
            return .general;
        },
        .kw_this, .kw_super, .kw_this_type => {
            try parsePathExpr(p);
            return .path_node;
        },
        else => {
            if (Parser.isNumericOrRuneTypeTag(tag) and isSameLineLParenAfterCurrent(p)) {
                try parseTypeConvExpr(p);
                return .general;
            }
            if (Parser.isPrimitiveTypeTag(tag) or Parser.isIdentLike(tag)) {
                try parsePathExpr(p);
                return .path_node;
            }
            if (tag == .illegal) {
                try p.bumpErrorToken(.invalid_literal);
                return .general;
            }
            try p.emitError(.expected_expression);
            return .missing;
        },
    }
}

/// 解析 `if` / `while` 条件中的 `let pattern (| pattern)* <- expr` 模式解构节点。
fn parseLetConditionDestructor(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.let_pattern_destructor);
    try p.emitLeadingTrivia(false);
    try p.bump(); // let
    try pattern.parsePattern(p, true);
    while (try p.eat(.bit_or)) {
        try pattern.parsePattern(p, true);
    }
    if (try p.expect(.backarrow)) {
        const saved = p.restrictions;
        p.restrictions = .{
            .allow_trailing_closure = false,
            .allow_range_colon = true,
            .allow_let_condition = false,
        };
        defer p.restrictions = saved;
        // 右侧解析到 `bit_or` 及以上，涵盖范围、比较与位运算，不吞并外层的 `&&` 与 `||`
        _ = try parseExprBp(p, Prec.bit_or);
    }
    try p.finishNode();
}

/// 只读判断当前有效词法单元之后是否在同一行紧接 `(`（避免跨行误判类型转换表达式）。
fn isSameLineLParenAfterCurrent(p: *const Parser) bool {
    const cur_idx = p.sig_idx;
    if (cur_idx >= p.tokens.len) return false;
    const next_idx = p.nextSignificantIndex(cur_idx + 1, false);
    if (next_idx >= p.tokens.len) return false;
    return p.tokens[next_idx].tag == .l_paren;
}

/// 解析平铺的点分路径表达式（`a`、`a.b`、`this.x`、`super.f`、`This.foo`、`Int64.Max`、`a?.b`）。
fn parsePathExpr(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.path_expr);
    try p.emitLeadingTrivia(false);
    // 首段已由 `parseAtomExpr` 确认非声明边界、已发射前导 Trivia 且标签合法
    try p.startNode(.path_segment);
    const tag = p.sig_tag;
    if (tag == .kw_this or tag == .kw_super or tag == .kw_this_type or Parser.isPrimitiveTypeTag(tag)) {
        try p.bump();
    } else {
        try p.bumpAs(.identifier);
    }
    if (p.sig_tag == .less) {
        _ = try type_parser.tryParseExprTypeArguments(p);
    }
    try p.finishNode();
    try parseFlatPathTail(p);
    try p.finishNode();
}

/// 解析路径表达式中的单个 `path_segment`（名称与可选泛型实参表）；
/// 当点号之后跨行到达新声明边界（如 `obj.\npublic func g()`）时立即停止，避免吞并下一行声明修饰符。
fn parseExprPathSegment(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.path_segment);
    if (p.isNewlineDeclBoundary()) {
        try p.emitError(.expected_identifier);
        try p.finishNode();
        return;
    }
    try p.emitLeadingTrivia(false);
    const tag = p.sig_tag;
    if (tag == .kw_this or tag == .kw_super or tag == .kw_this_type or Parser.isPrimitiveTypeTag(tag)) {
        try p.bump();
    } else if (Parser.isIdentLike(tag)) {
        try p.bumpAs(.identifier);
    } else {
        try p.emitError(.expected_identifier);
    }
    if (p.sig_tag == .less) {
        _ = try type_parser.tryParseExprTypeArguments(p);
    }
    try p.finishNode();
}

/// 解析数值与 `Rune` 类型转换表达式（如 `Int64(x)`、`Rune(65)`）。
fn parseTypeConvExpr(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.type_conv_expr);
    try p.emitLeadingTrivia(false);
    try type_parser.parsePrimitiveType(p);
    if (try p.expect(.l_paren)) {
        _ = try parseExprWithRestrictions(p, .{});
        _ = try p.expectClosing(.r_paren);
    }
    try p.finishNode();
}

/// 解析 `VArray<T, $N>(...)` 或 `VArray<T, $N> { ... }` 值数组构造表达式。
fn parseVArrayExpr(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.varray_expr);
    try p.emitLeadingTrivia(false);
    try type_parser.parseVArrayType(p);
    if (p.peekNoNl() == .l_paren) {
        try parseCallArgs(p);
    } else if (p.peekNoNl() == .l_curl and p.restrictions.allow_trailing_closure) {
        try parseLambdaExpr(p, true, false);
    }
    try p.finishNode();
}

/// 只读探测自 `start_idx` 起当前未闭合圆括号内剩余部分是否存在顶层逗号。
fn scanTopCommaInParenFrom(p: *const Parser, start_idx: usize) bool {
    var paren_depth: u32 = 0;
    var square_depth: u32 = 0;
    var curl_depth: u32 = 0;
    var idx = start_idx;

    while (idx < p.tokens.len) : (idx += 1) {
        const tag = p.tokens[idx].tag;
        if (tag == .comment or tag == .nl) continue;
        if (tag == .end) break;

        if (paren_depth == 0 and square_depth == 0 and curl_depth == 0) {
            if (tag == .r_paren) return false;
            if (tag == .comma) return true;
        }
        switch (tag) {
            .l_paren => paren_depth += 1,
            .r_paren => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            .l_square => square_depth += 1,
            .r_square => if (square_depth > 0) {
                square_depth -= 1;
            },
            .l_curl => curl_depth += 1,
            .r_curl => if (curl_depth > 0) {
                curl_depth -= 1;
            },
            else => {},
        }
    }
    return false;
}

/// 只读探测当前 `(` 括号表达式内是否存在顶层逗号，用于 `allow_let_condition` 场景下区分 `paren_expr` 与 `tuple_lit`。
fn parenExprHasTopComma(p: *const Parser) bool {
    const start_idx = p.sig_idx;
    if (start_idx >= p.tokens.len or p.sig_tag != .l_paren) return false;
    return scanTopCommaInParenFrom(p, start_idx + 1);
}

/// 解析 `tuple_lit` 中剩余的逗号分隔元素直到闭合 `)` 或外层同步边界。
fn parseTupleTailElements(p: *Parser) std.mem.Allocator.Error!void {
    while (!p.shouldStopList(.paren_expr_list)) {
        const before = p.cursor;
        _ = try parseExprWithRestrictions(p, .{});
        if (try p.eat(.comma)) {
            continue;
        } else if (p.shouldStopList(.paren_expr_list)) {
            break;
        } else if (p.canStartExpr()) {
            try p.emitError(.expected_token);
        } else {
            break;
        }
        if (p.cursor == before) try p.bumpErrorToken(.expected_expression);
    }
}

/// 解析 `()`（`unit_literal`）、`(expr)`（`paren_expr`）或 `(e1, e2, ...)`（`tuple_lit`）。
fn parseParenUnitOrTupleExpr(p: *Parser) std.mem.Allocator.Error!LhsKind {
    if (p.peekNth(1) == .r_paren) {
        try p.startNode(.unit_literal);
        try p.emitLeadingTrivia(false);
        try p.bump(); // (
        try p.bump(); // )
        try p.finishNode();
        return .general;
    }

    // `if` / `while` 条件内需根据是否含逗号决定首元素是否继承 `allow_let_condition`
    if (p.restrictions.allow_let_condition) {
        if (parenExprHasTopComma(p)) {
            try p.startNode(.tuple_lit);
            try p.emitLeadingTrivia(false);
            try p.bump(); // (
            try parseTupleTailElements(p);
            _ = try p.expectClosing(.r_paren);
            try p.finishNode();
            return .general;
        }

        const inner_r: parser_mod.Restrictions = .{
            .allow_trailing_closure = true,
            .allow_range_colon = true,
            .allow_let_condition = true,
        };
        try p.startNode(.paren_expr);
        try p.emitLeadingTrivia(false);
        try p.bump(); // (
        _ = try parseExprWithRestrictions(p, inner_r);
        _ = try p.expectClosing(.r_paren);
        try p.finishNode();
        return .general;
    }

    // 常规括号表达式与元组统一单趟解析：先按 `paren_expr` 开启，遇 `,` 时原地改写为 `tuple_lit`
    const start_ev_idx = p.events.items.len;
    try p.startNode(.paren_expr);
    try p.emitLeadingTrivia(false);
    try p.bump(); // (
    _ = try parseExprWithRestrictions(p, .{});
    if (try p.eat(.comma)) {
        p.setNodeKindAt(start_ev_idx, .tuple_lit);
        try parseTupleTailElements(p);
    } else if (p.sig_tag != .r_paren and
        !p.shouldStopList(.paren_expr_list) and
        p.canStartExpr() and
        scanTopCommaInParenFrom(p, p.sig_idx))
    {
        // 错误恢复冷路径：首元素后漏逗号但括号内后续仍存在顶层逗号（如 `(a b, c)`）
        p.setNodeKindAt(start_ev_idx, .tuple_lit);
        try p.emitError(.expected_token);
        try parseTupleTailElements(p);
    }
    _ = try p.expectClosing(.r_paren);
    try p.finishNode();
    return .general;
}

/// 解析数组字面量 `[e1, *spread, e2]`，支持缺失逗号恢复与外层边界保护。
fn parseArrayLit(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.array_lit);
    try p.emitLeadingTrivia(false);
    try p.bump(); // [
    while (!p.shouldStopList(.square_expr_list)) {
        const before = p.cursor;
        _ = try p.eat(.mul);
        _ = try parseExprWithRestrictions(p, .{});
        if (try p.eat(.comma)) {
            continue;
        } else if (p.shouldStopList(.square_expr_list)) {
            break;
        } else if (p.canStartExpr() or p.at(.mul)) {
            try p.emitError(.expected_token);
        } else {
            break;
        }
        if (p.cursor == before) try p.bumpErrorToken(.expected_expression);
    }
    _ = try p.expectClosing(.r_square);
    try p.finishNode();
}

/// 解析函数调用实参列表 `(...)`，支持缺失逗号恢复与外层边界保护。
fn parseCallArgs(p: *Parser) std.mem.Allocator.Error!void {
    try p.bumpNoNl(); // (
    while (!p.shouldStopList(.paren_expr_list)) {
        const before = p.cursor;
        try parseFuncArg(p);
        if (try p.eat(.comma)) {
            continue;
        } else if (p.shouldStopList(.paren_expr_list)) {
            break;
        } else if (p.canStartExpr()) {
            try p.emitError(.expected_token);
        } else {
            break;
        }
        if (p.cursor == before) try p.bumpErrorToken(.expected_expression);
    }
    _ = try p.expectClosing(.r_paren);
}

/// 解析单个实参节点 `func_arg`（支持命名实参 `name: expr` 与 `inout expr`）。
pub fn parseFuncArg(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.func_arg);
    try p.emitLeadingTrivia(false);

    if (Parser.isIdentLike(p.peek()) and p.peekNth(1) == .colon) {
        try p.bumpAs(.identifier);
        try p.bump(); // :
    }
    _ = try p.eat(.kw_inout);
    _ = try parseExprWithRestrictions(p, .{});

    try p.finishNode();
}

/// 解析下标访问 `[args]`，支持多维逗号下标、缺失逗号恢复、边界保护以及各维度的半开切片范围。
fn parseSubscriptArgs(p: *Parser) std.mem.Allocator.Error!void {
    try p.bumpNoNl(); // [

    while (!p.shouldStopList(.square_expr_list)) {
        const before = p.cursor;
        if (p.at(.range_op) or p.at(.closed_range_op)) {
            try p.startNode(.range_expr);
            try p.emitLeadingTrivia(false);
            try p.bump(); // .. or ..=
            if (!p.shouldStopList(.square_expr_list) and !p.at(.comma) and !p.at(.colon)) {
                _ = try parseExprBp(p, Prec.shift);
            }
            if (try p.eat(.colon)) {
                _ = try parseExprBp(p, Prec.shift);
            }
            try p.finishNode();
        } else {
            _ = try parseExprWithRestrictions(p, .{
                .allow_trailing_closure = true,
                .allow_range_colon = true,
                .allow_open_range_end = true,
            });
        }

        if (try p.eat(.comma)) {
            continue;
        } else if (p.shouldStopList(.square_expr_list)) {
            break;
        } else if (p.canStartExpr() or p.at(.range_op) or p.at(.closed_range_op)) {
            try p.emitError(.expected_token);
        } else {
            break;
        }
        if (p.cursor == before) try p.bumpErrorToken(.expected_expression);
    }

    _ = try p.expectClosing(.r_square);
}

/// 解析 `if (condition) block [else (if_expr | block)]`，带递归深度上限保护。
fn parseIfExpr(p: *Parser) std.mem.Allocator.Error!void {
    if (!try p.enterDepth()) return;
    defer p.leaveDepth();

    try p.startNode(.if_expr);
    try p.emitLeadingTrivia(false);
    try p.bump(); // if
    if (try p.expect(.l_paren)) {
        _ = try parseExprWithRestrictions(p, .{
            .allow_trailing_closure = false,
            .allow_range_colon = true,
            .allow_let_condition = true,
        });
        _ = try p.expectClosing(.r_paren);
    }
    if (p.at(.l_curl)) {
        try parseBlock(p);
    } else {
        try p.emitError(.expected_block);
    }
    if (try p.eat(.kw_else)) {
        if (p.at(.kw_if)) {
            try parseIfExpr(p);
        } else if (p.at(.l_curl)) {
            try parseBlock(p);
        } else {
            try p.emitError(.expected_block);
        }
    }
    try p.finishNode();
}

/// 解析有选择器或无选择器的 `match` 表达式。
fn parseMatchExpr(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.match_expr);
    try p.emitLeadingTrivia(false);
    try p.bump(); // match

    var has_selector = false;
    if (p.at(.l_paren)) {
        has_selector = true;
        try p.bump(); // (
        _ = try parseExprWithRestrictions(p, .{ .allow_trailing_closure = false });
        _ = try p.expectClosing(.r_paren);
    }

    if (try p.expect(.l_curl)) {
        while (!p.isAtEof() and !p.at(.r_curl)) {
            _ = try p.eatSemicolons();
            if (p.at(.r_curl) or p.isAtEof()) break;
            const before = p.cursor;
            if (p.at(.kw_case)) {
                if (has_selector) {
                    try parseMatchCase(p);
                } else {
                    try parseMatchCaseOther(p);
                }
            } else {
                try p.bumpErrorToken(.expected_token);
            }
            if (p.cursor == before) try p.bumpErrorToken(.expected_token);
        }
        _ = try p.expectClosing(.r_curl);
    }

    try p.finishNode();
}

/// 解析有选择器 `match` 中的单个分支 `case pat (| pat)* [where expr] => stmt_list`。
fn parseMatchCase(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.match_case);
    try p.emitLeadingTrivia(false);
    try p.bump(); // case
    try pattern.parsePattern(p, true);
    while (try p.eat(.bit_or)) {
        try pattern.parsePattern(p, true);
    }
    if (p.at(.kw_where)) {
        try parsePatternGuard(p);
    }
    _ = try p.expect(.double_arrow);
    _ = try parseStmtList(p, .r_curl, true);
    try p.finishNode();
}

/// 解析无选择器 `match` 中的单个分支 `case (expr | _) => stmt_list`。
fn parseMatchCaseOther(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.match_case_other);
    try p.emitLeadingTrivia(false);
    try p.bump(); // case
    if (p.at(.wildcard) and p.peekNth(1) == .double_arrow) {
        try pattern.parseWildcardPattern(p);
    } else {
        _ = try parseExprWithRestrictions(p, .{ .allow_trailing_closure = false });
    }
    _ = try p.expect(.double_arrow);
    _ = try parseStmtList(p, .r_curl, true);
    try p.finishNode();
}

/// 解析模式守卫 `where expr`。
fn parsePatternGuard(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.pattern_guard);
    try p.emitLeadingTrivia(false);
    try p.bump(); // where
    _ = try parseExprWithRestrictions(p, .{ .allow_trailing_closure = false });
    try p.finishNode();
}

/// 解析 `while (condition) block`。
fn parseWhileExpr(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.while_expr);
    try p.emitLeadingTrivia(false);
    try p.bump(); // while
    if (try p.expect(.l_paren)) {
        _ = try parseExprWithRestrictions(p, .{
            .allow_trailing_closure = false,
            .allow_range_colon = true,
            .allow_let_condition = true,
        });
        _ = try p.expectClosing(.r_paren);
    }
    if (p.at(.l_curl)) {
        try parseBlock(p);
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 解析 `do block while (expr)`。
fn parseDoWhileExpr(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.do_while_expr);
    try p.emitLeadingTrivia(false);
    try p.bump(); // do
    if (p.at(.l_curl)) {
        try parseBlock(p);
    } else {
        try p.emitError(.expected_block);
    }
    if (try p.expect(.kw_while)) {
        if (try p.expect(.l_paren)) {
            _ = try parseExprWithRestrictions(p, .{ .allow_trailing_closure = false });
            _ = try p.expectClosing(.r_paren);
        }
    }
    try p.finishNode();
}

/// 解析 `for (pattern in expr [where guard]) block`。
fn parseForInExpr(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.for_in_expr);
    try p.emitLeadingTrivia(false);
    try p.bump(); // for
    if (try p.expect(.l_paren)) {
        try pattern.parsePattern(p, false);
        if (try p.expect(.kw_in)) {
            _ = try parseExprWithRestrictions(p, .{ .allow_trailing_closure = false });
        }
        if (p.at(.kw_where)) {
            try parsePatternGuard(p);
        }
        _ = try p.expectClosing(.r_paren);
    }
    if (p.at(.l_curl)) {
        try parseBlock(p);
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 解析 `try [(resources)] block catch* handle* [finally]`。
fn parseTryExpr(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.try_expr);
    try p.emitLeadingTrivia(false);
    try p.bump(); // try

    if (p.at(.l_paren)) {
        try p.bump(); // (
        while (!p.shouldStopList(.paren_expr_list)) {
            const before = p.cursor;
            try parseResourceSpec(p);
            if (try p.eat(.comma)) {
                if (p.shouldStopList(.paren_expr_list)) break;
            } else if (Parser.isIdentLike(p.peek()) and !p.shouldStopList(.paren_expr_list)) {
                try p.emitError(.expected_token);
            } else {
                break;
            }
            if (p.cursor == before) try p.bumpErrorToken(.expected_identifier);
        }
        _ = try p.expectClosing(.r_paren);
    }

    if (p.at(.l_curl)) {
        try parseBlock(p);
    } else {
        try p.emitError(.expected_block);
    }

    while (p.at(.kw_catch) or p.at(.kw_handle)) {
        if (p.at(.kw_catch)) {
            try parseCatchClause(p);
        } else {
            try parseHandleClause(p);
        }
    }

    if (p.at(.kw_finally)) {
        try p.startNode(.finally_clause);
        try p.emitLeadingTrivia(false);
        try p.bump(); // finally
        if (p.at(.l_curl)) {
            try parseBlock(p);
        } else {
            try p.emitError(.expected_block);
        }
        try p.finishNode();
    }

    try p.finishNode();
}

/// 解析 `try (...)` 中的单个资源声明 `name [: Type] = expr`。
fn parseResourceSpec(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.resource_spec);
    try p.emitLeadingTrivia(false);
    _ = try p.expectIdent();
    if (try p.eat(.colon)) {
        try type_parser.parseType(p);
    }
    if (try p.expect(.assign)) {
        _ = try parseExprWithRestrictions(p, .{});
    }
    try p.finishNode();
}

/// 解析 `catch (pattern) block`。
fn parseCatchClause(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.catch_clause);
    try p.emitLeadingTrivia(false);
    try p.bump(); // catch
    if (try p.expect(.l_paren)) {
        try pattern.parseCatchPattern(p);
        _ = try p.expectClosing(.r_paren);
    }
    if (p.at(.l_curl)) {
        try parseBlock(p);
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 解析代数效应 `handle (pattern) block`。
fn parseHandleClause(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.handle_clause);
    try p.emitLeadingTrivia(false);
    try p.bump(); // handle
    if (try p.expect(.l_paren)) {
        try pattern.parseHandlePattern(p);
        _ = try p.expectClosing(.r_paren);
    }
    if (p.at(.l_curl)) {
        try parseBlock(p);
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 解析 `throw expr`。
fn parseThrowExpr(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.throw_expr);
    try p.emitLeadingTrivia(false);
    try p.bump(); // throw
    try parseExpr(p);
    try p.finishNode();
}

/// 解析 `return [expr]`；同行后续为终止符、`,` 或 `case` 时作为无值返回。
fn parseReturnExpr(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.return_expr);
    try p.emitLeadingTrivia(false);
    try p.bump(); // return
    const next_no_nl = p.peekNoNl();
    if (!p.atStmtTerminator() and next_no_nl != .comma and next_no_nl != .kw_case) {
        try parseExpr(p);
    }
    try p.finishNode();
}

/// 解析 `perform expr`。
fn parsePerformExpr(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.perform_expr);
    try p.emitLeadingTrivia(false);
    try p.bump(); // perform
    try parseExpr(p);
    try p.finishNode();
}

/// 解析 `resume [expr] [with expr | throwing expr]`，同行判定 `with` / `throwing` 与表达式终止。
fn parseResumeExpr(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.resume_expr);
    try p.emitLeadingTrivia(false);
    try p.bump(); // resume
    const next_no_nl = p.peekNoNl();
    if (!p.atStmtTerminator() and
        next_no_nl != .comma and
        next_no_nl != .kw_with and
        next_no_nl != .kw_throwing)
    {
        try parseExpr(p);
    }
    if (p.peekNoNl() == .kw_with or p.peekNoNl() == .kw_throwing) {
        try p.bumpNoNl();
        try parseExpr(p);
    }
    try p.finishNode();
}

/// 解析 `spawn [(context)] { ... }`。
fn parseSpawnExpr(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.spawn_expr);
    try p.emitLeadingTrivia(false);
    try p.bump(); // spawn
    if (p.at(.l_paren)) {
        try p.bump();
        _ = try parseExprWithRestrictions(p, .{ .allow_trailing_closure = false });
        _ = try p.expectClosing(.r_paren);
    }
    if (p.at(.l_curl)) {
        try parseLambdaExpr(p, true, false);
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 解析 `synchronized (mutex) block`。
fn parseSynchronizedExpr(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.synchronized_expr);
    try p.emitLeadingTrivia(false);
    try p.bump(); // synchronized
    if (try p.expect(.l_paren)) {
        _ = try parseExprWithRestrictions(p, .{ .allow_trailing_closure = false });
        _ = try p.expectClosing(.r_paren);
    }
    if (p.at(.l_curl)) {
        try parseBlock(p);
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 解析 `unsafe block`。
fn parseUnsafeExpr(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.unsafe_expr);
    try p.emitLeadingTrivia(false);
    try p.bump(); // unsafe
    if (p.at(.l_curl)) {
        try parseBlock(p);
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 只读前瞻 `{` 之后是否存在顶层 `=>`（遇任意 `{` / `}` 或非参数关键字立即终止，避免 `<` 与嵌套 `match` 误判）。
fn lambdaHasArrow(p: *const Parser) bool {
    const start_idx = p.sig_idx;
    if (start_idx >= p.tokens.len or p.sig_tag != .l_curl) return false;

    var paren_depth: u32 = 0;
    var angle_depth: u32 = 0;
    var idx = start_idx + 1;

    while (idx < p.tokens.len) : (idx += 1) {
        const tag = p.tokens[idx].tag;
        if (tag == .comment or tag == .nl) continue;
        if (tag == .end or tag == .semi or tag == .l_curl or tag == .r_curl) return false;

        if (paren_depth == 0 and angle_depth == 0) {
            if (tag == .double_arrow) return true;
            switch (tag) {
                .kw_let,
                .kw_var,
                .kw_return,
                .kw_if,
                .kw_while,
                .kw_for,
                .kw_match,
                .kw_try,
                .kw_break,
                .kw_continue,
                .kw_throw,
                => return false,
                else => {},
            }
        }
        switch (tag) {
            .l_paren => paren_depth += 1,
            .r_paren => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            .less => angle_depth += 1,
            .greater => if (angle_depth > 0) {
                angle_depth -= 1;
            },
            else => {},
        }
    }
    return false;
}

/// 解析 lambda 表达式 `{ [params] => body }`、尾随闭包 `{ [params =>] body }` 或带前置内置注解的 lambda。
///
/// 子节点含可选 `annotation`、可选 `func_param_list` 与作为函数体的 `block`（内含 `stmt_list`）。
fn parseLambdaExpr(p: *Parser, allow_omitted_arrow: bool, has_leading_annotations: bool) std.mem.Allocator.Error!void {
    if (!try p.enterDepth()) return;
    defer p.leaveDepth();

    const saved = p.restrictions;
    p.restrictions = .{};
    defer p.restrictions = saved;

    try p.startNode(.lambda_expr);
    try p.emitLeadingTrivia(false);

    if (has_leading_annotations) {
        try decl.parseLeadingBuiltinAnnotations(p, false);
        if (!p.at(.l_curl)) {
            try p.emitError(.expected_block);
            try p.finishNode();
            return;
        }
    }

    const has_arrow = lambdaHasArrow(p);
    try p.bump(); // {

    if (has_arrow) {
        if (!p.at(.double_arrow)) {
            try p.startNode(.func_param_list);
            try p.emitLeadingTrivia(false);
            while (!p.isAtEof() and !p.at(.double_arrow) and !p.at(.r_curl) and !p.isNewlineDeclBoundary()) {
                const before = p.cursor;
                try decl.parseFuncParam(p, false);
                if (try p.eat(.comma)) {
                    if (p.at(.double_arrow) or p.at(.r_curl)) break;
                } else if ((Parser.isIdentLike(p.peek()) or p.at(.wildcard)) and !p.isNewlineDeclBoundary()) {
                    try p.emitError(.expected_token);
                } else {
                    break;
                }
                if (p.cursor == before) try p.bumpErrorToken(.expected_identifier);
            }
            try p.finishNode();
        }
        _ = try p.expect(.double_arrow);
    } else if (!allow_omitted_arrow) {
        try p.emitError(.expected_token);
    }

    try p.startNode(.block);
    _ = try parseStmtList(p, .r_curl, false);
    try p.finishNode();

    _ = try p.expectClosing(.r_curl);
    try p.finishNode();
}

/// 只读判断当前位置是否为 `@IfAvailable(...)` 表达式。
pub fn isIfAvailableStart(p: *const Parser) bool {
    return p.at(.at) and
        p.peekNth(1) == .identifier and
        std.mem.eql(u8, p.peekTextNth(1), "IfAvailable") and
        p.peekNth(2) == .l_paren;
}

/// 解析 `@IfAvailable(arg, lambda1, lambda2)` 表达式。
fn parseIfAvailableExpr(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.if_available_expr);
    try p.emitLeadingTrivia(false);
    try p.bump(); // @
    try p.bumpAs(.identifier); // IfAvailable
    if (p.peekNoNl() == .l_paren) {
        try parseCallArgs(p);
    } else {
        try p.emitError(.expected_token);
    }
    try p.finishNode();
}

/// 解析表达式位置的宏调用 `@M[attr](input)` 或链式宏 `@M1 @M2(input)`。
fn parseMacroExpandExpr(p: *Parser) std.mem.Allocator.Error!void {
    if (!try p.enterDepth()) return;
    defer p.leaveDepth();

    try p.startNode(.macro_expand_expr);
    try p.emitLeadingTrivia(false);
    try decl.parseMacroHeader(p, false);

    if (p.at(.l_paren)) {
        try decl.parseMacroInputParens(p);
    } else if (p.at(.at) and !isIfAvailableStart(p) and !decl.isBuiltinAnnotation(p)) {
        try parseMacroExpandExpr(p);
    } else {
        try p.emitError(.expected_token);
    }
    try p.finishNode();
}

/// 解析 `quote(...)` 表达式，严格遵循 `cangjie_spec` 转义、括号配对与插值规则：
/// - `quote` 与 `(` 之间禁止换行；
/// - 识别 `lexer` 产出的 `\`（单字节 `.illegal`）与其物理紧邻的 `(`、`)`、`$`、`$ident`、`@`、`@!` 构成转义，
///   被转义的括号不计入配对深度，被转义的 `$` 不触发代码插值；
/// - 未转义的 `$(expr)` 与 `$ident` 切分为 `quote_interpolation`，先关闭 `token_part` 再由后续节点承接前导 Trivia；
/// - 孤立未转义 `$` 与不匹配的小括号均报告语法错误并维持无损。
fn parseQuoteExpr(p: *Parser) std.mem.Allocator.Error!void {
    if (!try p.enterDepth()) return;
    defer p.leaveDepth();

    try p.startNode(.quote_expr);
    try p.emitLeadingTrivia(false);
    try p.bump(); // quote

    if (p.at(.l_paren) and p.hasNewlineBefore()) {
        try p.emitError(.expected_token);
    }
    if (!try p.expect(.l_paren)) {
        try p.finishNode();
        return;
    }

    var lparen_depth: u32 = 1;
    var in_token_part = false;

    while (p.cursor < p.tokens.len) {
        // 先只读定位下一个非 Trivia 词法单元，决定前导 Trivia 归属于哪个节点
        const sig_idx = p.nextSignificantIndex(p.cursor, true);
        if (sig_idx >= p.tokens.len or p.tokens[sig_idx].tag == .end) {
            if (in_token_part) {
                try p.finishNode();
                in_token_part = false;
            }
            break;
        }

        const tok = p.tokens[sig_idx];

        // 判断下一个有效词法单元是否会终止当前 `token_part`
        const is_interp_paren = tok.tag == .dollar and blk: {
            const next_same_line = p.nextSignificantIndex(sig_idx + 1, false);
            break :blk next_same_line < p.tokens.len and p.tokens[next_same_line].tag == .l_paren;
        };
        const is_interp_ident = tok.tag == .dollar_identifier;
        const is_outer_rparen = tok.tag == .r_paren and lparen_depth == 1;

        if (is_interp_paren) {
            if (in_token_part) {
                try p.finishNode();
                in_token_part = false;
            }
            try p.startNode(.quote_interpolation);
            try p.emitLeadingTrivia(true);
            try p.bumpAllowDoc(); // $
            try p.bumpNoNl(); // (
            _ = try parseExprWithRestrictions(p, .{});
            _ = try p.expectClosing(.r_paren);
            try p.finishNode();
            continue;
        }

        if (is_interp_ident) {
            if (in_token_part) {
                try p.finishNode();
                in_token_part = false;
            }
            try p.startNode(.quote_interpolation);
            try p.emitLeadingTrivia(true);
            try p.bumpAllowDoc();
            try p.finishNode();
            continue;
        }

        if (is_outer_rparen) {
            if (in_token_part) {
                try p.finishNode();
                in_token_part = false;
            }
            lparen_depth -= 1;
            try p.bumpAllowDoc(); // )
            break;
        }

        if (!in_token_part) {
            try p.startNode(.token_part);
            try p.emitLeadingTrivia(true);
            in_token_part = true;
        }

        // 1. 识别反斜杠转义：`\(`、`\)`、`\$`、`\$x`、`\@`、`\@!`
        if (tok.tag == .illegal and std.mem.eql(u8, p.tokenText(tok), "\\")) {
            if (sig_idx + 1 < p.tokens.len) {
                const next = p.tokens[sig_idx + 1];
                if (Parser.isAdjacent(tok, next) and isValidQuoteEscapeTarget(next.tag)) {
                    try p.bumpAllowDoc(); // \
                    try p.bumpAllowDoc(); // 转义目标，不参与括号配对与插值
                    continue;
                }
            }
            try p.emitError(.illegal_token);
            try p.bumpAllowDoc();
            continue;
        }

        // 2. 孤立未转义 `$`：按规范需写为 `\$`
        if (tok.tag == .dollar) {
            try p.emitError(.unexpected_token);
            try p.bumpAllowDoc();
            continue;
        }

        // 3. 嵌套小括号配对追踪
        if (tok.tag == .l_paren) {
            lparen_depth += 1;
            try p.bumpAllowDoc();
            continue;
        }

        if (tok.tag == .r_paren) {
            lparen_depth -= 1;
            try p.bumpAllowDoc();
            if (lparen_depth == 0) break;
            continue;
        }

        // 4. 普通 quoteToken（含组合运算符 `??`、`>>`、`>>=`、`>=` 与嵌套 `quote` / `@Macro`）
        if (p.combinedOpAt(sig_idx)) |comb| {
            try p.bumpCombinedAllowDoc(comb, true);
        } else {
            if (tok.tag == .illegal) {
                try p.emitError(.illegal_token);
            }
            try p.bumpAllowDoc();
        }
    }

    if (in_token_part) {
        try p.finishNode();
    }
    if (lparen_depth > 0) {
        try p.emitError(.unclosed_delimiter);
    }

    try p.finishNode(); // quote_expr
}

/// 判定给定词法标签是否为 `quote(...)` 内反斜杠 `\` 的合法转义目标。
inline fn isValidQuoteEscapeTarget(tag: TokenTag) bool {
    return switch (tag) {
        .l_paren, .r_paren, .dollar, .dollar_identifier, .at, .at_excl => true,
        else => false,
    };
}

/// 解析单行或多行字符串字面量；若内部包含未转义的 `${...}` 插值则展开为 `str_interpolation_expr`。
fn parseStringOrInterpolation(p: *Parser) std.mem.Allocator.Error!void {
    const idx = p.sig_idx;
    if (idx >= p.tokens.len) return;
    const tok = p.tokens[idx];
    const text = p.tokenText(tok);
    const is_multiline = tok.tag == .multiline_string;

    const first_interp = findNextInterpolation(text, 0, is_multiline) orelse {
        try p.bump();
        return;
    };

    if (!try p.enterDepth()) {
        try p.bump();
        return;
    }
    defer p.leaveDepth();

    try p.startNode(.str_interpolation_expr);
    try p.emitLeadingTrivia(false);
    const range = p.safeRange(tok.span);
    p.setCursor(p.cursor + 1);

    var seg_start: u32 = 0;
    const text_len: u32 = @intCast(text.len);
    var next_interp: ?u32 = first_interp;

    while (next_interp) |dollar_rel| {
        if (dollar_rel > seg_start) {
            try p.emitLeaf(.string_content, .{
                .start = range.start + seg_start,
                .end = range.start + dollar_rel,
            });
            seg_start = dollar_rel;
        }

        const expr_rel_start = dollar_rel + 2;
        var inline_tokens: [64]common.Token = undefined;
        var heap_tokens: std.ArrayList(common.Token) = .empty;
        defer heap_tokens.deinit(p.allocator);

        if (try lexInterpolationUntilClose(p.allocator, text, expr_rel_start, &inline_tokens, &heap_tokens)) |interp_res| {
            const r_curl_rel = interp_res.close_rel;
            try p.startNode(.interpolation_expr);
            try p.emitLeaf(.dollar, .{
                .start = range.start + dollar_rel,
                .end = range.start + dollar_rel + 1,
            });
            try p.emitLeaf(.l_curl, .{
                .start = range.start + dollar_rel + 1,
                .end = range.start + expr_rel_start,
            });

            try parseInterpolationTokens(p, range.start + expr_rel_start, range.start + r_curl_rel, interp_res.tokens);

            try p.emitLeaf(.r_curl, .{
                .start = range.start + r_curl_rel,
                .end = range.start + r_curl_rel + 1,
            });
            try p.finishNode();

            seg_start = r_curl_rel + 1;
            next_interp = findNextInterpolation(text, seg_start, is_multiline);
        } else {
            try p.emitErrorAt(.invalid_interpolation, .{
                .start = p.globalPos(range.start + dollar_rel),
                .end = p.globalPos(range.end),
            });
            break;
        }
    }

    if (seg_start < text_len) {
        try p.emitLeaf(.string_content, .{
            .start = range.start + seg_start,
            .end = range.end,
        });
    }

    try p.finishNode();
}

/// 在字符串字面量文本中自 `start` 起查找下一个未转义的 `${` 相对位置；优先使用向量化查找跳过不含 `$` 的文本。
fn findNextInterpolation(text: []const u8, start: u32, is_multiline: bool) ?u32 {
    var pos: usize = start;
    if (start == 0) {
        if (is_multiline) {
            if (text.len < 6) return null;
            pos = 3;
            if (pos < text.len and text[pos] == '\r') pos += 1;
            if (pos < text.len and text[pos] == '\n') pos += 1;
        } else {
            if (text.len < 2) return null;
            pos = 1;
        }
    }

    const end_limit: usize = if (is_multiline)
        (if (text.len >= 3) text.len - 3 else 0)
    else
        (if (text.len >= 1) text.len - 1 else 0);

    if (pos >= end_limit) return null;
    const body = text[0..end_limit];
    if (std.mem.indexOfScalarPos(u8, body, pos, '$') == null) return null;

    while (pos < end_limit) {
        const hit = std.mem.indexOfAnyPos(u8, body, pos, "\\$") orelse return null;
        if (body[hit] == '\\') {
            pos = hit + 2;
            continue;
        }
        if (hit + 1 < end_limit and body[hit + 1] == '{') {
            return @intCast(hit);
        }
        pos = hit + 1;
    }
    return null;
}

/// 单遍词法扫描插值体的结果：`close_rel` 为配对 `}` 在字符串文本中的相对位置，`tokens` 借用自调用方传入缓冲。
const InterpLexResult = struct {
    close_rel: u32,
    tokens: []const common.Token,
};

/// 单遍扫描自 `${` 之后第一字节至配对 `}` 的全部词法单元，同时定位闭合 `}` 相对位置。
///
/// 短插值直接写入调用方提供的 `inline_buf`（零堆分配），超长插值溢出到 `heap_buf`（由调用方释放）；
/// 返回结果中的 `tokens` 切片借用自 `inline_buf` 或 `heap_buf`，调用方不得单独释放。
fn lexInterpolationUntilClose(
    allocator: std.mem.Allocator,
    text: []const u8,
    start: u32,
    inline_buf: []common.Token,
    heap_buf: *std.ArrayList(common.Token),
) std.mem.Allocator.Error!?InterpLexResult {
    const sub = text[start..];
    var lex = parser_mod.lexer.Lexer.new(sub) catch return null;
    var brace_depth: u32 = 1;
    var inline_len: usize = 0;
    var using_heap = false;

    while (true) {
        const tok = lex.gen() catch return null;
        if (tok.tag == .end) return null;
        if (tok.tag == .l_curl) {
            brace_depth += 1;
        } else if (tok.tag == .r_curl) {
            brace_depth -= 1;
            if (brace_depth == 0) {
                const end_tok: common.Token = .{
                    .tag = .end,
                    .span = .{ .start = tok.span.start, .end = tok.span.start },
                };
                const tokens_slice: []const common.Token = if (!using_heap and inline_len < inline_buf.len) blk: {
                    inline_buf[inline_len] = end_tok;
                    inline_len += 1;
                    break :blk inline_buf[0..inline_len];
                } else blk: {
                    if (!using_heap) {
                        try heap_buf.ensureTotalCapacity(allocator, inline_len + 1);
                        heap_buf.appendSliceAssumeCapacity(inline_buf[0..inline_len]);
                        using_heap = true;
                    }
                    try heap_buf.append(allocator, end_tok);
                    break :blk heap_buf.items;
                };
                return .{
                    .close_rel = start + tok.span.start,
                    .tokens = tokens_slice,
                };
            }
        }

        if (!using_heap) {
            if (inline_len < inline_buf.len) {
                inline_buf[inline_len] = tok;
                inline_len += 1;
            } else {
                try heap_buf.ensureTotalCapacity(allocator, @max(inline_len * 2, 16));
                heap_buf.appendSliceAssumeCapacity(inline_buf[0..inline_len]);
                heap_buf.appendAssumeCapacity(tok);
                using_heap = true;
            }
        } else {
            try heap_buf.append(allocator, tok);
        }
    }
}

/// 复用父 `Parser` 的事件与错误缓冲直接解析 `${...}` 内部词法单元切片，消除子缓冲分配与事件拷贝。
fn parseInterpolationTokens(
    p: *Parser,
    local_start: u32,
    local_end: u32,
    sub_tokens: []const common.Token,
) std.mem.Allocator.Error!void {
    const slice = p.source[local_start..local_end];

    const saved_source = p.source;
    const saved_tokens = p.tokens;
    const saved_source_len = p.source_len;
    const saved_base_offset = p.base_offset;
    const saved_cursor = p.cursor;
    const saved_sig_no_nl_idx = p.sig_no_nl_idx;
    const saved_sig_no_nl_tag = p.sig_no_nl_tag;
    const saved_sig_idx = p.sig_idx;
    const saved_sig_tag = p.sig_tag;
    var restored_emitted_pos = p.emitted_pos;
    const saved_restrictions = p.restrictions;

    defer {
        p.source = saved_source;
        p.tokens = saved_tokens;
        p.source_len = saved_source_len;
        p.base_offset = saved_base_offset;
        p.cursor = saved_cursor;
        p.sig_no_nl_idx = saved_sig_no_nl_idx;
        p.sig_no_nl_tag = saved_sig_no_nl_tag;
        p.sig_idx = saved_sig_idx;
        p.sig_tag = saved_sig_tag;
        p.emitted_pos = restored_emitted_pos;
        p.restrictions = saved_restrictions;
    }

    p.source = slice;
    p.tokens = sub_tokens;
    p.source_len = @intCast(slice.len);
    p.base_offset = p.globalPos(local_start);
    p.emitted_pos = 0;
    p.restrictions = .{};
    p.setCursor(0);

    try p.startNode(.block);
    _ = try parseStmtList(p, .end, false);
    try p.finishNode();
    try p.emitTrivia(true, false);
    try p.emitTrailingWhitespace();

    if (local_end > restored_emitted_pos) {
        restored_emitted_pos = local_end;
    }
}
