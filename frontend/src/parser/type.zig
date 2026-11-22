//! 仓颉类型语法解析模块。
//!
//! 覆盖基础类型、`This`、`VArray<T, $N>`、点分路径类型、可空类型 `?T`、
//! 括号类型 `(T)`、元组类型 `(T, U)` 与函数类型 `(T) -> R`，以及表达式与模式位置的泛型实参前瞻。

const std = @import("std");
const common = @import("common");
const TokenTag = common.TokenTag;
const parser_mod = @import("../parser.zig");
const Parser = parser_mod.Parser;

/// 解析任意类型节点；若跨行遇到新声明起始边界，立即报错返回且不吞并下一行修饰符。
pub fn parseType(p: *Parser) std.mem.Allocator.Error!void {
    if (!try p.enterDepth()) return;
    defer p.leaveDepth();

    if (p.isNewlineDeclBoundary()) {
        try p.emitError(.expected_type);
        return;
    }

    switch (p.peek()) {
        .quest => try parseOptionType(p),
        .l_paren => try parseParenTupleOrFuncType(p),
        .kw_this_type => try parseThisType(p),
        .kw_varray => try parseVArrayType(p),
        else => |tag| {
            if (Parser.isPrimitiveTypeTag(tag)) {
                try parsePrimitiveType(p);
            } else if (Parser.isIdentLike(tag)) {
                try parsePathType(p);
            } else {
                try p.emitError(.expected_type);
            }
        },
    }
}

/// 判定当前词法单元是否可以作为类型起始符（排除跨行的新声明边界）。
pub fn canStartType(p: *const Parser) bool {
    if (p.isNewlineDeclBoundary()) return false;
    const tag = p.peek();
    return tag == .quest or
        tag == .l_paren or
        tag == .kw_this_type or
        tag == .kw_varray or
        Parser.isPrimitiveTypeTag(tag) or
        Parser.isIdentLike(tag);
}

/// 解析基础内置类型节点（如 `Int64`、`Bool`、`Unit`）。
pub fn parsePrimitiveType(p: *Parser) std.mem.Allocator.Error!void {
    try p.emitTrivia(true);
    try p.startNode(.primitive_type);
    try p.bump();
    try p.finishNode();
}

/// 解析 `This` 类型节点。
fn parseThisType(p: *Parser) std.mem.Allocator.Error!void {
    try p.emitTrivia(true);
    try p.startNode(.this_type);
    try p.bump();
    try p.finishNode();
}

/// 解析前缀可空类型 `?Type`；连续的 `??T` 每次仅消费单个 `?`，形成嵌套 `option_type`。
fn parseOptionType(p: *Parser) std.mem.Allocator.Error!void {
    try p.emitTrivia(true);
    try p.startNode(.option_type);
    try p.bump();
    try parseType(p);
    try p.finishNode();
}

/// 解析 `VArray<Type, $N>` 值数组类型。
pub fn parseVArrayType(p: *Parser) std.mem.Allocator.Error!void {
    try p.emitTrivia(true);
    try p.startNode(.varray_type);
    try p.bump(); // VArray
    if (try p.expect(.less)) {
        try parseType(p);
        _ = try p.expect(.comma);
        try parseConstantType(p);
        _ = try p.expect(.greater);
    }
    try p.finishNode();
}

/// 解析 `VArray` 中的常量类型实参 `$N`。
fn parseConstantType(p: *Parser) std.mem.Allocator.Error!void {
    try p.emitTrivia(true);
    try p.startNode(.constant_type);
    if (try p.expect(.dollar)) {
        if (p.peek() == .integer_literal) {
            try p.bump();
        } else {
            try p.emitError(.invalid_literal);
        }
    }
    try p.finishNode();
}

/// 解析用户定义类型的点分路径（`a.b.C<T>`），各段平铺为兄弟 `path_segment`。
pub fn parsePathType(p: *Parser) std.mem.Allocator.Error!void {
    try p.emitTrivia(true);
    try p.startNode(.path_type);
    try parseTypePathSegment(p);
    while (p.at(.dot)) {
        try p.bump();
        try parseTypePathSegment(p);
    }
    try p.finishNode();
}

/// 解析类型路径中的单个段：标识符与可选的 `<Type, ...>` 类型实参表。
fn parseTypePathSegment(p: *Parser) std.mem.Allocator.Error!void {
    try p.emitTrivia(true);
    try p.startNode(.path_segment);
    if (p.isNewlineDeclBoundary()) {
        try p.emitError(.expected_identifier);
    } else {
        _ = try p.expectIdent();
        if (p.at(.less)) {
            try parseTypeArgumentList(p);
        }
    }
    try p.finishNode();
}

/// 解析类型实参表 `<Type (, Type)*>`；闭合时每次仅消费单个 `>`，支持缺失逗号恢复与外层边界保护。
pub fn parseTypeArgumentList(p: *Parser) std.mem.Allocator.Error!void {
    if (!try p.enterDepth()) return;
    defer p.leaveDepth();

    try p.emitTrivia(true);
    try p.startNode(.type_argument_list);
    _ = try p.expect(.less);

    var count: usize = 0;
    while (!p.shouldStopList(.type_arg_list)) {
        if (count > 0) {
            if (try p.eat(.comma)) {
                if (p.shouldStopList(.type_arg_list)) break;
            } else if (canStartType(p)) {
                // 列表内漏敲逗号：报告一次缺失分隔符并继续解析下一类型实参
                try p.emitError(.expected_token);
            } else {
                break;
            }
        }

        const before = p.cursor;
        try parseType(p);
        count += 1;
        if (p.cursor == before) {
            if (p.at(.comma) or p.shouldStopList(.type_arg_list)) continue;
            break;
        }
    }

    if (count == 0) {
        try p.emitError(.expected_type);
    }

    _ = try p.expectClosing(.greater);
    try p.finishNode();
}

/// 只读探测自当前 `(` 起括号内的形态：是否含顶层逗号、是否含顶层参数标签，以及配对 `)` 后是否紧跟 `->`。
const ParenTypeShape = struct {
    is_func: bool,
    has_comma: bool,
    has_label: bool,
    is_empty: bool,
};

/// 只读扫描括号类型头部，一次确定外层应构造 `func_type`、`tuple_type` 还是 `paren_type`。
fn classifyParenType(p: *const Parser) ParenTypeShape {
    const start_idx = p.nextSignificantIndex(p.cursor, true);
    if (start_idx >= p.tokens.len or p.tokens[start_idx].tag != .l_paren) {
        return .{ .is_func = false, .has_comma = false, .has_label = false, .is_empty = true };
    }

    var paren_depth: u32 = 0;
    var angle_depth: u32 = 0;
    var has_comma = false;
    var has_label = false;
    var has_any_token = false;
    var idx = start_idx + 1;

    while (idx < p.tokens.len) : (idx += 1) {
        const tag = p.tokens[idx].tag;
        if (tag == .comment or tag == .nl) continue;
        if (tag == .end) break;

        // 类型实参 `<...>` 不可跨越外层 `)`，遇到 `paren_depth == 0` 的 `)` 立即终止防止穿透扫描
        if (paren_depth == 0 and tag == .r_paren) {
            const after = p.nextSignificantIndex(idx + 1, true);
            const is_func = angle_depth == 0 and after < p.tokens.len and p.tokens[after].tag == .arrow;
            return .{
                .is_func = is_func,
                .has_comma = has_comma,
                .has_label = has_label,
                .is_empty = !has_any_token,
            };
        }

        has_any_token = true;
        switch (tag) {
            .l_paren => paren_depth += 1,
            .r_paren => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            .less => angle_depth += 1,
            .greater => {
                if (angle_depth > 0) angle_depth -= 1;
            },
            .comma => {
                if (paren_depth == 0 and angle_depth == 0) has_comma = true;
            },
            .colon => {
                if (paren_depth == 0 and angle_depth == 0) has_label = true;
            },
            else => {},
        }
    }

    return .{
        .is_func = false,
        .has_comma = has_comma,
        .has_label = has_label,
        .is_empty = !has_any_token,
    };
}

/// 解析括号类型 `(T)`、元组类型 `(T, U)` / `(x: T, y: U)` 或函数类型 `(T, U) -> R`。
fn parseParenTupleOrFuncType(p: *Parser) std.mem.Allocator.Error!void {
    const shape = classifyParenType(p);
    const node_kind: common.SyntaxKind = if (shape.is_func)
        .func_type
    else if (shape.has_comma or shape.has_label or shape.is_empty)
        .tuple_type
    else
        .paren_type;

    try p.emitTrivia(true);
    try p.startNode(node_kind);
    try p.bump(); // (

    if (!p.at(.r_paren)) {
        while (!p.shouldStopList(.paren_type_list)) {
            const before = p.cursor;
            try parseOptionalLabeledType(p);
            if (try p.eat(.comma)) {
                if (p.shouldStopList(.paren_type_list)) break;
            } else if (canStartType(p) and !p.shouldStopList(.paren_type_list)) {
                try p.emitError(.expected_token);
            } else {
                break;
            }
            if (p.cursor == before) {
                try p.bumpErrorToken(.expected_type);
            }
        }
    } else if (node_kind == .tuple_type) {
        try p.emitError(.expected_type);
    }

    _ = try p.expectClosing(.r_paren);
    if (shape.is_func) {
        if (try p.expect(.arrow)) {
            try parseType(p);
        }
    }
    try p.finishNode();
}

/// 解析可选带参数名标签的类型元素（`ident : Type` 或 `Type`）。
fn parseOptionalLabeledType(p: *Parser) std.mem.Allocator.Error!void {
    if (Parser.isIdentLike(p.peek()) and p.peekNth(1) == .colon) {
        try p.bumpAs(.identifier);
        try p.bump(); // :
    }
    try parseType(p);
}

/// 在表达式路径段之后试探解析 `<Type, ...>` 泛型实参列表；
/// 依据 `cangjie_spec` 泛型消歧规则，解析成功、闭合 `>` 未与后继构成 `>=`/`>>=` 且后继合法时提交，否则回溯。
pub fn tryParseExprTypeArguments(p: *Parser) std.mem.Allocator.Error!bool {
    if (!p.at(.less)) return false;
    if (p.hasNewlineBefore()) return false;

    const cp = p.checkpoint();
    try parseTypeArgumentList(p);

    if (p.error_count == cp.error_count and !closingGreaterFormsCombinedAssign(p) and isValidAfterExprTypeArgs(p)) {
        return true;
    }

    p.rollback(cp);
    return false;
}

/// 在模式枚举路径段之后试探解析 `<Type, ...>` 泛型实参列表（允许 `<` 前换行，匹配 `compositeType` BNF）。
pub fn tryParsePatternTypeArguments(p: *Parser) std.mem.Allocator.Error!bool {
    if (!p.at(.less)) return false;

    const cp = p.checkpoint();
    try parseTypeArgumentList(p);

    if (p.error_count == cp.error_count and !closingGreaterFormsCombinedAssign(p)) {
        const next = p.peek();
        if (next == .dot or next == .l_paren or next == .double_arrow or
            next == .bit_or or next == .kw_where or next == .comma or
            next == .r_paren or next == .backarrow or next == .kw_in or next == .assign)
        {
            return true;
        }
    }

    p.rollback(cp);
    return false;
}

/// 检查刚刚消费的闭合 `>` 是否与紧随其后的词法单元物理紧邻构成 `>=` 或 `>>=`（防止误拆 `c >= 0`）。
fn closingGreaterFormsCombinedAssign(p: *const Parser) bool {
    if (p.cursor == 0 or p.cursor >= p.tokens.len) return false;
    const prev_gt = p.tokens[p.cursor - 1];
    if (prev_gt.tag != .greater) return false;
    const next = p.tokens[p.cursor];
    if (!Parser.isAdjacent(prev_gt, next)) return false;
    if (next.tag == .assign) return true;
    if (next.tag == .greater and p.cursor + 1 < p.tokens.len) {
        const after = p.tokens[p.cursor + 1];
        if (Parser.isAdjacent(next, after) and after.tag == .assign) return true;
    }
    return false;
}

/// 判定闭合泛型实参列表 `>` 之后的词法单元是否符合表达式位置泛型引用的合法后继集合。
fn isValidAfterExprTypeArgs(p: *const Parser) bool {
    const next_no_nl = p.peekNoNl();
    return switch (next_no_nl) {
        .l_paren,
        .l_square,
        .dot,
        .l_curl,
        .quest,
        .r_paren,
        .r_square,
        .r_curl,
        .comma,
        .semi,
        .nl,
        .end,
        .colon,
        .equal,
        .not_equal,
        .pipeline,
        .composition,
        .logical_and,
        .logical_or,
        .double_arrow,
        .kw_is,
        .kw_as,
        .kw_where,
        .kw_in,
        .add,
        .mul,
        .div,
        .mod,
        .exp,
        .bit_and,
        .bit_or,
        .bit_xor,
        .lshift,
        .range_op,
        .closed_range_op,
        => true,
        else => false,
    };
}
