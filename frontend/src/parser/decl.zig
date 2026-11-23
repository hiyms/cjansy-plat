// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 仓颉顶层结构、注解、宏调用与全部声明解析模块。
//!
//! 覆盖 `source_file`、`features_directive`、`package_header`、`import_spec`、内置注解、
//! 声明与参数位置宏调用，以及 `class`、`interface`、`struct`、`enum`、`extend`、`func`、
//! `main`、`macro`、`var`、`prop`、`type_alias`、`primary_ctor`、`init`、`finalizer`、`foreign`。

const std = @import("std");
const common = @import("common");
const TokenTag = common.TokenTag;
const SyntaxKind = common.SyntaxKind;
const parser_mod = @import("../parser.zig");
const Parser = parser_mod.Parser;
const expr = parser_mod.expr;
const type_parser = parser_mod.type_parser;
const pattern = parser_mod.pattern;

/// 声明所在作用域，用于区分顶层、类型体、扩展体、外部块与函数块内的允许成员。
pub const DeclScope = enum {
    top_level,
    class_body,
    struct_body,
    interface_body,
    enum_body,
    extend_body,
    foreign_block,
    local_block,
};

/// 解析整个源文件，构建最外层 `source_file` 节点并无损覆盖全部词法单元。
pub fn parseSourceFile(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.source_file);

    _ = try p.eatSemicolons();

    // 可选：`features { a.b, c.d }`
    if (isFeaturesDirectiveStart(p)) {
        try parseFeaturesDirective(p);
        _ = try p.eatSemicolons();
    }

    // 可选：`[public|protected|internal] [macro] package ...`
    if (isPackageHeaderStart(p)) {
        try parsePackageHeader(p);
        _ = try p.eatSemicolons();
    }

    // 零或多个 `import`（支持前置 `@When[...]` 注解与访问修饰符）
    while (!p.isAtEof() and isImportSpecStart(p)) {
        const before = p.cursor;
        try parseImportSpec(p);
        _ = try p.eatSemicolons();
        if (p.cursor == before) try p.bumpErrorToken(.expected_item);
    }

    // 零或多个顶层声明与 `main`
    while (!p.isAtEof()) {
        _ = try p.eatSemicolons();
        if (p.isAtEof()) break;

        const before = p.cursor;
        if (isImportSpecStart(p)) {
            try parseImportSpec(p);
        } else if (isPackageHeaderStart(p)) {
            try parsePackageHeader(p);
        } else {
            try parseDecl(p, .top_level);
        }
        _ = try p.eatSemicolons();

        if (p.cursor == before) {
            try p.bumpErrorRun(.expected_item, false);
        }
    }

    try p.finishFile();
    try p.finishNode();
}

/// 只读判断从物理下标 `start_idx` 开始的修饰符序列之后是否紧跟明确声明关键字（用于新行声明边界判定）。
pub fn isModifierFollowedByDeclAt(p: *const Parser, start_idx: usize) bool {
    var idx = start_idx;
    if (idx >= p.tokens.len) return false;
    var count: usize = 0;
    while (idx < p.tokens.len and isModifierAtIndex(p, idx, .top_level)) {
        count += 1;
        idx = p.nextSignificantIndex(idx + 1, true);
    }
    if (count == 0 or idx >= p.tokens.len) return false;
    const tag = p.tokens[idx].tag;
    return Parser.isHardDeclKeyword(tag) or
        tag == .kw_let or
        tag == .kw_var or
        tag == .kw_const or
        tag == .kw_init;
}

/// 只读判断从物理下标 `start_idx` 开始的 `@`/`@!` 注解或宏头之后是否紧跟声明边界（用于新行声明边界判定）。
pub fn isAnnotationFollowedByDeclAt(p: *const Parser, start_idx: usize) bool {
    var idx = start_idx;
    while (idx < p.tokens.len) {
        const tag = p.tokens[idx].tag;
        if (tag != .at and tag != .at_excl) break;
        const after = skipMacroOrAnnotationHeaderIndex(p, idx);
        if (after == idx) break;
        idx = after;
    }
    if (idx == start_idx or idx >= p.tokens.len) return false;
    const tag = p.tokens[idx].tag;
    return Parser.isHardDeclKeyword(tag) or
        tag == .kw_let or
        tag == .kw_var or
        tag == .kw_const or
        tag == .kw_init or
        isModifierFollowedByDeclAt(p, idx);
}

/// 只读判断当前是否位于 `features { ... }` 特性声明头部。
fn isFeaturesDirectiveStart(p: *const Parser) bool {
    return p.atIdentText("features") and p.peekNth(1) == .l_curl;
}

/// 解析 `features { a.b, c.d }` 特性声明。
fn parseFeaturesDirective(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.features_directive);
    try p.emitLeadingTrivia(false);
    try p.bumpAs(.kw_features);

    try p.startNode(.features_set);
    try p.emitLeadingTrivia(false);
    _ = try p.expect(.l_curl);

    while (!p.shouldStopList(.brace_list)) {
        const before = p.cursor;
        try p.startNode(.feature_id);
        try p.emitLeadingTrivia(false);
        _ = try p.expectIdent();
        while (p.at(.dot)) {
            try p.bump();
            if (p.isNewlineDeclBoundary()) {
                try p.emitError(.expected_identifier);
                break;
            }
            _ = try p.expectIdent();
        }
        try p.finishNode();

        if (try p.eat(.comma)) {
            if (p.shouldStopList(.brace_list)) break;
        } else if (Parser.isIdentLike(p.peek()) and !p.shouldStopList(.brace_list)) {
            try p.emitError(.expected_token);
        } else {
            break;
        }
        if (p.cursor == before) try p.bumpErrorToken(.expected_identifier);
    }

    _ = try p.expectClosing(.r_curl);
    try p.finishNode(); // features_set
    try p.finishNode(); // features_directive
}

/// 只读判断当前是否位于 `package` 包声明头部。
fn isPackageHeaderStart(p: *const Parser) bool {
    var idx = p.nextSignificantIndex(p.cursor, true);
    if (idx < p.tokens.len) {
        const t0 = p.tokens[idx].tag;
        if (t0 == .kw_public or t0 == .kw_protected or t0 == .kw_internal) {
            idx = p.nextSignificantIndex(idx + 1, true);
        }
    }
    if (idx < p.tokens.len and p.tokens[idx].tag == .kw_macro) {
        idx = p.nextSignificantIndex(idx + 1, true);
    }
    return idx < p.tokens.len and p.tokens[idx].tag == .kw_package;
}

/// 解析 `[modifier] [macro] package [org::]a.b.c` 包声明。
fn parsePackageHeader(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.package_header);
    try p.emitLeadingTrivia(true);

    const t0 = p.peek();
    if (t0 == .kw_public or t0 == .kw_protected or t0 == .kw_internal) {
        try p.bump();
    }
    _ = try p.eat(.kw_macro);
    _ = try p.expect(.kw_package);

    try p.startNode(.package_name);
    if (p.isNewlineDeclBoundary()) {
        try p.emitError(.expected_identifier);
    } else {
        try p.emitLeadingTrivia(false);
        if (Parser.isPackageIdentLike(p.peek()) and p.peekNth(1) == .double_colon) {
            _ = try p.expectPackageIdent();
            try p.bump(); // ::
        }
        if (p.isNewlineDeclBoundary()) {
            try p.emitError(.expected_identifier);
        } else {
            _ = try p.expectPackageIdent();
            while (p.at(.dot)) {
                try p.bump();
                if (p.isNewlineDeclBoundary()) {
                    try p.emitError(.expected_identifier);
                    break;
                }
                _ = try p.expectPackageIdent();
            }
        }
    }
    try p.finishNode(); // package_name
    try p.finishNode(); // package_header
}

/// 只读线性跳过自物理下标 `start_idx` 起的单个方括号段 `[...]`（正确处理 `\[`、`\]` 转义），返回闭合 `]` 后的下一个有效词法单元下标。
fn skipBracketedIndex(p: *const Parser, start_idx: usize) usize {
    if (start_idx >= p.tokens.len or p.tokens[start_idx].tag != .l_square) return start_idx;
    var depth: u32 = 1;
    var idx = start_idx + 1;
    while (idx < p.tokens.len) {
        const tok = p.tokens[idx];
        if (tok.tag == .end) return idx;
        if (tok.tag == .illegal and std.mem.eql(u8, p.tokenText(tok), "\\") and idx + 1 < p.tokens.len) {
            const next = p.tokens[idx + 1];
            if (Parser.isAdjacent(tok, next) and
                (next.tag == .l_square or next.tag == .r_square or next.tag == .at or next.tag == .at_excl))
            {
                idx += 2;
                continue;
            }
        }
        if (tok.tag == .l_square) {
            depth += 1;
        } else if (tok.tag == .r_square) {
            depth -= 1;
            if (depth == 0) return p.nextSignificantIndex(idx + 1, true);
        }
        idx += 1;
    }
    return idx;
}

/// 只读线性跳过自物理下标 `start_idx` 起的配对圆括号 `(...)`，返回闭合 `)` 后的下一个有效词法单元下标；未闭合返回 `null`。
fn skipParenIndex(p: *const Parser, start_idx: usize) ?usize {
    if (start_idx >= p.tokens.len or p.tokens[start_idx].tag != .l_paren) return null;
    var depth: u32 = 1;
    var idx = start_idx + 1;
    while (idx < p.tokens.len) : (idx += 1) {
        const tag = p.tokens[idx].tag;
        if (tag == .end) return null;
        if (tag == .l_paren) {
            depth += 1;
        } else if (tag == .r_paren) {
            depth -= 1;
            if (depth == 0) return p.nextSignificantIndex(idx + 1, true);
        }
    }
    return null;
}

/// 只读判断物理下标 `at_idx` 处的 `@...` 是否命中内置注解名称表。
pub fn isBuiltinAnnotationAtIndex(p: *const Parser, at_idx: usize) bool {
    if (at_idx >= p.tokens.len or p.tokens[at_idx].tag != .at) return false;
    var idx = p.nextSignificantIndex(at_idx + 1, true);
    if (idx >= p.tokens.len or !Parser.isIdentLike(p.tokens[idx].tag)) return false;

    var last_name = p.tokenText(p.tokens[idx]);
    idx = p.nextSignificantIndex(idx + 1, true);
    while (idx < p.tokens.len and p.tokens[idx].tag == .dot) {
        const next_id = p.nextSignificantIndex(idx + 1, true);
        if (next_id >= p.tokens.len or !Parser.isIdentLike(p.tokens[next_id].tag)) break;
        last_name = p.tokenText(p.tokens[next_id]);
        idx = p.nextSignificantIndex(next_id + 1, true);
    }
    return Parser.isBuiltinAnnotationName(last_name);
}

/// 只读判断当前位置是否位于内置注解起始处。
pub inline fn isBuiltinAnnotation(p: *const Parser) bool {
    return isBuiltinAnnotationAtIndex(p, p.nextSignificantIndex(p.cursor, true));
}

/// 只读线性跳过自物理下标 `start_idx` 起连续的内置注解，返回其后首个有效词法单元下标。
fn skipLeadingBuiltinAnnotationsIndex(p: *const Parser, start_idx: usize) usize {
    var idx = p.nextSignificantIndex(start_idx, true);
    while (idx < p.tokens.len and isBuiltinAnnotationAtIndex(p, idx)) {
        idx = p.nextSignificantIndex(idx + 1, true); // skip @
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
            idx = skipBracketedIndex(p, idx);
        }
    }
    return idx;
}

/// 只读线性跳过自 `start_idx` 起的单个宏/注解头部（`@`/`@!` + 点分名 + 可选 `[...]`），返回其后首个有效词法单元下标。
fn skipMacroOrAnnotationHeaderIndex(p: *const Parser, start_idx: usize) usize {
    var idx = start_idx;
    if (idx >= p.tokens.len) return idx;
    const tag = p.tokens[idx].tag;
    if (tag != .at and tag != .at_excl) return idx;
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
        idx = skipBracketedIndex(p, idx);
    }
    return idx;
}

/// 只读判断当前是否位于 `import` 导入声明（允许前置内置注解如 `@When[...]` 与访问修饰符）。
fn isImportSpecStart(p: *const Parser) bool {
    var idx = skipLeadingBuiltinAnnotationsIndex(p, p.cursor);
    if (idx < p.tokens.len) {
        const t = p.tokens[idx].tag;
        if (t == .kw_public or t == .kw_private or t == .kw_protected or t == .kw_internal) {
            idx = p.nextSignificantIndex(idx + 1, true);
        }
    }
    return idx < p.tokens.len and p.tokens[idx].tag == .kw_import;
}

/// 解析单条 `import` 声明。
fn parseImportSpec(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.import_spec);
    try p.emitLeadingTrivia(true);

    try parseLeadingBuiltinAnnotations(p, true);
    const mod = p.peek();
    if (mod == .kw_public or mod == .kw_private or mod == .kw_protected or mod == .kw_internal) {
        try p.bump();
    }
    _ = try p.expect(.kw_import);
    try parseImportContent(p, true);

    try p.finishNode();
}

/// 解析 `import` 内容（支持可选 `org::`、点分路径、`*`、`as Alias` 与 `{ ... }` 组合集合，禁止嵌套分组）。
fn parseImportContent(p: *Parser, allow_org_and_group: bool) std.mem.Allocator.Error!void {
    if (!try p.enterDepth()) return;
    defer p.leaveDepth();

    try p.startNode(.import_content);
    if (p.isNewlineDeclBoundary()) {
        try p.emitError(.expected_identifier);
        try p.finishNode();
        return;
    }
    try p.emitLeadingTrivia(false);

    if (allow_org_and_group and Parser.isPackageIdentLike(p.peek()) and p.peekNth(1) == .double_colon) {
        _ = try p.expectPackageIdent();
        try p.bump(); // ::
    }

    if (p.at(.l_curl)) {
        try parseImportMultiGroup(p);
        try p.finishNode();
        return;
    }

    if (!p.isNewlineDeclBoundary() and Parser.isPackageIdentLike(p.peek())) {
        _ = try p.expectPackageIdent();
        while (p.at(.dot)) {
            try p.bump(); // .
            if (p.isNewlineDeclBoundary()) {
                try p.emitError(.expected_identifier);
                try p.finishNode();
                return;
            }
            if (p.at(.mul)) {
                try p.bump(); // *
                try p.finishNode();
                return;
            }
            if (p.at(.l_curl)) {
                try parseImportMultiGroup(p);
                try p.finishNode();
                return;
            }
            if (Parser.isPackageIdentLike(p.peek())) {
                _ = try p.expectPackageIdent();
            } else {
                try p.emitError(.expected_identifier);
                break;
            }
        }
        if (try p.eat(.kw_as)) {
            if (p.isNewlineDeclBoundary()) {
                try p.emitError(.expected_identifier);
            } else {
                _ = try p.expectIdent();
            }
        }
    } else {
        try p.emitError(.expected_identifier);
    }

    try p.finishNode();
}

/// 解析 `import` 分组集合 `{ item1, item2 as Alias, sub.* }`（支持缺失逗号恢复与边界保护）。
fn parseImportMultiGroup(p: *Parser) std.mem.Allocator.Error!void {
    try p.bump(); // {
    while (!p.shouldStopList(.brace_list)) {
        const before = p.cursor;
        try parseImportContent(p, false);
        if (try p.eat(.comma)) {
            if (p.shouldStopList(.brace_list)) break;
        } else if (Parser.isPackageIdentLike(p.peek()) and !p.shouldStopList(.brace_list)) {
            try p.emitError(.expected_token);
        } else {
            break;
        }
        if (p.cursor == before) try p.bumpErrorToken(.expected_identifier);
    }
    _ = try p.expectClosing(.r_curl);
}

/// 连续解析零或多个前置内置注解节点（`SyntaxKind.annotation`）。
///
/// 当 `allow_doc_comment` 为真时，若注解之间或注解之后存在文档注释，在当前声明节点层发射，
/// 使文档注释归属声明对象，避免被 `annotation` 吞入或误判为悬空文档注释。
pub fn parseLeadingBuiltinAnnotations(p: *Parser, allow_doc_comment: bool) std.mem.Allocator.Error!void {
    while (isBuiltinAnnotation(p)) {
        if (allow_doc_comment) try p.emitPendingDocComments();
        const before = p.cursor;
        try parseAnnotation(p);
        if (p.cursor == before) break;
    }
    if (allow_doc_comment) try p.emitPendingDocComments();
}

/// 解析单个内置注解 `@Name` 或 `@a.b.Name[args]`。
pub fn parseAnnotation(p: *Parser) std.mem.Allocator.Error!void {
    if (!try p.enterDepth()) return;
    defer p.leaveDepth();

    try p.startNode(.annotation);
    try p.emitLeadingTrivia(false);
    _ = try p.expect(.at);
    _ = try p.expectIdent();
    while (p.at(.dot)) {
        try p.bump();
        _ = try p.expectIdent();
    }

    if (p.at(.l_square)) {
        try p.bump(); // [
        while (!p.shouldStopList(.square_expr_list)) {
            const before = p.cursor;
            try expr.parseFuncArg(p);
            if (try p.eat(.comma)) {
                if (p.shouldStopList(.square_expr_list)) break;
            } else if (p.canStartExpr() and !p.shouldStopList(.square_expr_list)) {
                try p.emitError(.expected_token);
            } else {
                break;
            }
            if (p.cursor == before) try p.bumpErrorToken(.expected_expression);
        }
        _ = try p.expectClosing(.r_square);
    }

    try p.finishNode();
}

/// 只读判断物理下标 `idx` 处的 `kw_const` 是否作为修饰符（如 `const func`、`const init`、`const Point(...) {}`），
/// 从而与 `const public = 1`、`const Box(x) = Box(1)` 等 `const` 变量声明精确消歧。
fn isConstModifierAtIndex(p: *const Parser, const_idx: usize, scope: DeclScope) bool {
    var idx = p.nextSignificantIndex(const_idx + 1, true);
    while (idx < p.tokens.len) {
        const tok = p.tokens[idx];
        switch (tok.tag) {
            .kw_func => return true,
            .kw_init => return scope == .class_body or scope == .struct_body,
            .kw_public,
            .kw_private,
            .kw_protected,
            .kw_internal,
            .kw_static,
            .kw_override,
            .kw_redef,
            .kw_abstract,
            .kw_sealed,
            .kw_open,
            .kw_mut,
            .kw_unsafe,
            .kw_operator,
            => {
                // 在类/结构体中若该上下文关键字直接后接 `(`，则是主构造器名
                if ((scope == .class_body or scope == .struct_body) and Parser.isContextKeywordTag(tok.tag)) {
                    const after_id = p.nextSignificantIndex(idx + 1, true);
                    if (after_id < p.tokens.len and p.tokens[after_id].tag == .l_paren) {
                        if (skipParenIndex(p, after_id)) |after_paren| {
                            return after_paren < p.tokens.len and p.tokens[after_paren].tag == .l_curl;
                        }
                        return false;
                    }
                }
                if (scope == .local_block and tok.tag != .kw_unsafe) return false;
                idx = p.nextSignificantIndex(idx + 1, true);
            },
            .identifier => {
                const text = p.tokenText(tok);
                if (scope != .local_block and
                    (std.mem.eql(u8, text, "common") or std.mem.eql(u8, text, "specific")))
                {
                    if (scope == .class_body or scope == .struct_body) {
                        const after_id = p.nextSignificantIndex(idx + 1, true);
                        if (after_id < p.tokens.len and p.tokens[after_id].tag == .l_paren) {
                            if (skipParenIndex(p, after_id)) |after_paren| {
                                return after_paren < p.tokens.len and p.tokens[after_paren].tag == .l_curl;
                            }
                            return false;
                        }
                    }
                    idx = p.nextSignificantIndex(idx + 1, true);
                    continue;
                }
                if (scope == .class_body or scope == .struct_body) {
                    const after_id = p.nextSignificantIndex(idx + 1, true);
                    if (after_id < p.tokens.len and p.tokens[after_id].tag == .l_paren) {
                        if (skipParenIndex(p, after_id)) |after_paren| {
                            return after_paren < p.tokens.len and p.tokens[after_paren].tag == .l_curl;
                        }
                    }
                }
                return false;
            },
            else => return false,
        }
    }
    return false;
}

/// 统一只读判定物理下标 `idx` 处的词法单元在 `scope` 下是否属于声明修饰符。
fn isModifierAtIndex(p: *const Parser, idx: usize, scope: DeclScope) bool {
    if (idx >= p.tokens.len) return false;
    const tok = p.tokens[idx];

    // 局部语句块中仅允许 `unsafe` 与修饰函数的 `const` 作为声明修饰符
    if (scope == .local_block) {
        return switch (tok.tag) {
            .kw_unsafe => blk: {
                const next = p.nextSignificantIndex(idx + 1, true);
                break :blk next < p.tokens.len and
                    (p.tokens[next].tag == .kw_func or p.tokens[next].tag == .kw_const);
            },
            .kw_const => isConstModifierAtIndex(p, idx, scope),
            else => false,
        };
    }

    // 在类/结构体中若上下文关键字或 `common`/`specific` 后紧跟 `(`，将其留作主构造器名称
    if (scope == .class_body or scope == .struct_body) {
        const is_ctx_or_cs = Parser.isContextKeywordTag(tok.tag) or
            (tok.tag == .identifier and
                (std.mem.eql(u8, p.tokenText(tok), "common") or std.mem.eql(u8, p.tokenText(tok), "specific")));
        if (is_ctx_or_cs) {
            const next = p.nextSignificantIndex(idx + 1, true);
            if (next < p.tokens.len and p.tokens[next].tag == .l_paren) {
                return false;
            }
        }
    }

    return switch (tok.tag) {
        .kw_public,
        .kw_private,
        .kw_protected,
        .kw_internal,
        .kw_static,
        .kw_override,
        .kw_redef,
        .kw_abstract,
        .kw_sealed,
        .kw_open,
        .kw_mut,
        .kw_unsafe,
        .kw_operator,
        => true,
        .kw_const => isConstModifierAtIndex(p, idx, scope),
        .identifier => blk: {
            const text = p.tokenText(tok);
            if (std.mem.eql(u8, text, "common") or std.mem.eql(u8, text, "specific")) {
                break :blk true;
            }
            if (std.mem.eql(u8, text, "late")) {
                const next = p.nextSignificantIndex(idx + 1, true);
                break :blk next < p.tokens.len and p.tokens[next].tag == .kw_macro;
            }
            break :blk false;
        },
        else => false,
    };
}

/// 消费声明修饰符序列，其中 `common` / `specific` 按上下文关键字发射为对应 `SyntaxKind`。
fn parseDeclModifiers(p: *Parser, scope: DeclScope) std.mem.Allocator.Error!void {
    while (true) {
        const idx = p.nextSignificantIndex(p.cursor, true);
        if (!isModifierAtIndex(p, idx, scope)) break;
        const tok = p.tokens[idx];
        if (tok.tag == .identifier) {
            const text = p.tokenText(tok);
            if (std.mem.eql(u8, text, "common")) {
                try p.bumpAs(.kw_common);
                continue;
            }
            if (std.mem.eql(u8, text, "specific")) {
                try p.bumpAs(.kw_specific);
                continue;
            }
        }
        try p.bump();
    }
}

/// 只读前瞻自 `start_idx` 跳过前置内置注解与修饰符后，判定声明体应构造的 `SyntaxKind`。
fn peekDeclKindAt(p: *const Parser, start_idx: usize, scope: DeclScope) ?SyntaxKind {
    var idx = skipLeadingBuiltinAnnotationsIndex(p, start_idx);
    if (idx >= p.tokens.len) return null;

    // 遇到非内置注解的 `@` 或 `@!` 直接归为声明位置宏调用
    const first_after_anno = p.tokens[idx].tag;
    if (first_after_anno == .at or first_after_anno == .at_excl) {
        return .macro_expand_decl;
    }

    while (isModifierAtIndex(p, idx, scope)) {
        idx = p.nextSignificantIndex(idx + 1, true);
    }
    if (idx >= p.tokens.len) return null;

    return switch (p.tokens[idx].tag) {
        .kw_class => .class_decl,
        .kw_interface => .interface_decl,
        .kw_struct => .struct_decl,
        .kw_enum => .enum_decl,
        .kw_extend => .extend_decl,
        .kw_func => .func_decl,
        .kw_main => .main_decl,
        .kw_macro => .macro_decl,
        .kw_let, .kw_var, .kw_const => .var_decl,
        .kw_prop => .prop_decl,
        .kw_type => .type_alias_decl,
        .kw_init => .init_decl,
        .bit_not => blk: {
            const next = p.nextSignificantIndex(idx + 1, true);
            break :blk if (next < p.tokens.len and p.tokens[next].tag == .kw_init) .finalizer_decl else null;
        },
        .kw_foreign => .foreign_decl,
        else => |tag| {
            if ((scope == .class_body or scope == .struct_body) and Parser.isIdentLike(tag)) {
                const next = p.nextSignificantIndex(idx + 1, true);
                if (next < p.tokens.len and p.tokens[next].tag == .l_paren) {
                    return .primary_ctor_decl;
                }
            }
            return null;
        },
    };
}

/// 只读判断当前游标处的声明类型。
fn peekDeclKind(p: *const Parser, scope: DeclScope) ?SyntaxKind {
    return peekDeclKindAt(p, p.cursor, scope);
}

/// 只读判断局部语句块中当前词法位置是否为局部声明（宽松允许块内声明，同时保留独立上下文关键字表达式）。
pub fn isLocalDeclStart(p: *const Parser) bool {
    const first_idx = p.nextSignificantIndex(p.cursor, true);
    if (first_idx >= p.tokens.len) return false;
    const first = p.tokens[first_idx].tag;

    // 排除 `unsafe { ... }`（属于 `unsafe_expr`）
    if (first == .kw_unsafe) {
        const next = p.nextSignificantIndex(first_idx + 1, true);
        if (next < p.tokens.len and p.tokens[next].tag == .l_curl) return false;
    }

    if (first == .at) {
        if (expr.isIfAvailableStart(p)) return false;
        if (isBuiltinAnnotationAtIndex(p, first_idx)) {
            const after_anno = skipLeadingBuiltinAnnotationsIndex(p, first_idx);
            if (after_anno < p.tokens.len and p.tokens[after_anno].tag == .l_curl) return false;
        } else {
            return isMacroWithoutParensAtIndex(p, first_idx);
        }
    }
    if (first == .at_excl) return true;

    const k = peekDeclKindAt(p, first_idx, .local_block) orelse return false;
    return switch (k) {
        .var_decl,
        .func_decl,
        .class_decl,
        .struct_decl,
        .interface_decl,
        .enum_decl,
        .type_alias_decl,
        .extend_decl,
        .macro_expand_decl,
        => true,
        else => false,
    };
}

/// 根据作用域解析单条声明（或声明位置宏调用）。
pub fn parseDecl(p: *Parser, scope: DeclScope) std.mem.Allocator.Error!void {
    if (!try p.enterDepth()) return;
    defer p.leaveDepth();

    const kind = peekDeclKind(p, scope) orelse {
        try p.bumpErrorToken(.expected_item);
        return;
    };

    switch (kind) {
        .macro_expand_decl => try parseMacroExpandDecl(p, scope),
        .class_decl => try parseClassDecl(p),
        .interface_decl => try parseInterfaceDecl(p),
        .struct_decl => try parseStructDecl(p),
        .enum_decl => try parseEnumDecl(p),
        .extend_decl => try parseExtendDecl(p),
        .func_decl => try parseFuncDecl(p, scope),
        .main_decl => try parseMainDecl(p),
        .macro_decl => try parseMacroDecl(p),
        .var_decl => try parseVarDecl(p, scope),
        .prop_decl => try parsePropDecl(p),
        .type_alias_decl => try parseTypeAliasDecl(p),
        .init_decl => try parseInitDecl(p),
        .finalizer_decl => try parseFinalizerDecl(p),
        .primary_ctor_decl => try parsePrimaryCtorDecl(p),
        .foreign_decl => try parseForeignDecl(p),
        else => try p.bumpErrorToken(.expected_item),
    }
}

/// 解析 `class` 声明。
fn parseClassDecl(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.class_decl);
    try p.emitLeadingTrivia(true);
    try parseLeadingBuiltinAnnotations(p, true);
    try parseDeclModifiers(p, .top_level);
    _ = try p.expect(.kw_class);
    _ = try p.expectIdent();
    if (p.at(.less)) try parseTypeParameterList(p);
    try parseOptionalSuperTypes(p);
    if (p.at(.kw_where)) try parseWhereClause(p);
    if (p.at(.l_curl)) {
        try parseMemberBody(p, .class_body, .class_body);
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 解析 `interface` 声明。
fn parseInterfaceDecl(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.interface_decl);
    try p.emitLeadingTrivia(true);
    try parseLeadingBuiltinAnnotations(p, true);
    try parseDeclModifiers(p, .top_level);
    _ = try p.expect(.kw_interface);
    _ = try p.expectIdent();
    if (p.at(.less)) try parseTypeParameterList(p);
    try parseOptionalSuperTypes(p);
    if (p.at(.kw_where)) try parseWhereClause(p);
    if (p.at(.l_curl)) {
        try parseMemberBody(p, .interface_body, .interface_body);
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 解析 `struct` 声明。
fn parseStructDecl(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.struct_decl);
    try p.emitLeadingTrivia(true);
    try parseLeadingBuiltinAnnotations(p, true);
    try parseDeclModifiers(p, .top_level);
    _ = try p.expect(.kw_struct);
    _ = try p.expectIdent();
    if (p.at(.less)) try parseTypeParameterList(p);
    try parseOptionalSuperTypes(p);
    if (p.at(.kw_where)) try parseWhereClause(p);
    if (p.at(.l_curl)) {
        try parseMemberBody(p, .struct_body, .struct_body);
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 解析 `enum` 声明及其包含构造器、可选非详尽 `...` 与成员声明的 `enum_body`。
fn parseEnumDecl(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.enum_decl);
    try p.emitLeadingTrivia(true);
    try parseLeadingBuiltinAnnotations(p, true);
    try parseDeclModifiers(p, .top_level);
    _ = try p.expect(.kw_enum);
    _ = try p.expectIdent();
    if (p.at(.less)) try parseTypeParameterList(p);
    try parseOptionalSuperTypes(p);
    if (p.at(.kw_where)) try parseWhereClause(p);

    if (p.at(.l_curl)) {
        try p.startNode(.enum_body);
        try p.emitLeadingTrivia(false);
        try p.bump(); // {
        _ = try p.eatSemicolons();

        // 枚举构造器部分：`[|] Ctor1 | @Anno Ctor2(T) [| ...]`
        var first_ctor = true;
        while (!p.isAtEof() and !p.at(.r_curl)) {
            const sig_idx = p.nextSignificantIndex(p.cursor, true);
            if (sig_idx >= p.tokens.len) break;

            if (p.tokens[sig_idx].tag == .bit_or) {
                const after_bar = p.nextSignificantIndex(sig_idx + 1, true);
                if (after_bar < p.tokens.len and p.tokens[after_bar].tag == .ellipsis) {
                    try p.bump(); // |
                    try p.bump(); // ...
                    _ = try p.eatSemicolons();
                    break;
                }
                if (isEnumConstructorStartAt(p, after_bar)) {
                    try parseEnumConstructorOrMacro(p, true);
                    first_ctor = false;
                    _ = try p.eatSemicolons();
                    if (p.at(.bit_or)) continue;
                    break;
                }
                try p.bump(); // |
                try p.emitError(.expected_identifier);
                _ = try p.eatSemicolons();
                break;
            }

            if (first_ctor) {
                if (p.tokens[sig_idx].tag == .ellipsis) {
                    try p.bump(); // ...
                    _ = try p.eatSemicolons();
                    break;
                }
                if (isEnumConstructorStartAt(p, sig_idx)) {
                    try parseEnumConstructorOrMacro(p, false);
                    first_ctor = false;
                    _ = try p.eatSemicolons();
                    if (p.at(.bit_or)) continue;
                    break;
                }
            }
            break;
        }

        // 枚举成员函数、属性与宏调用
        while (!p.isAtEof() and !p.at(.r_curl)) {
            _ = try p.eatSemicolons();
            if (p.at(.r_curl) or p.isAtEof()) break;
            const before = p.cursor;
            try parseDecl(p, .enum_body);
            _ = try p.eatSemicolons();
            if (p.cursor == before) try p.bumpErrorRun(.expected_item, true);
        }

        _ = try p.expectClosing(.r_curl);
        try p.finishNode(); // enum_body
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 只读判断从物理下标 `start_idx` 起是否为枚举构造器（含前置内置注解、自定义注解或无括号宏修饰的构造器）。
fn isEnumConstructorStartAt(p: *const Parser, start_idx: usize) bool {
    var idx = p.nextSignificantIndex(start_idx, true);
    while (idx < p.tokens.len) {
        if (isBuiltinAnnotationAtIndex(p, idx)) {
            idx = skipLeadingBuiltinAnnotationsIndex(p, idx);
            continue;
        }
        const tag = p.tokens[idx].tag;
        if (tag == .at or tag == .at_excl) {
            if (!isMacroWithoutParensAtIndex(p, idx)) return false;
            idx = skipMacroOrAnnotationHeaderIndex(p, idx);
            continue;
        }
        break;
    }
    if (idx >= p.tokens.len) return false;
    if (!Parser.isIdentLike(p.tokens[idx].tag)) return false;
    // 若跳过注解与宏头后构成合法枚举成员声明（如 `public func` / `prop`），则非构造器
    if (peekDeclKindAt(p, idx, .enum_body) != null) return false;
    return true;
}

/// 解析枚举构造器或带前置自定义注解/宏修饰的枚举构造器（`has_leading_bar` 为真时先消费前置 `|`）。
fn parseEnumConstructorOrMacro(p: *Parser, has_leading_bar: bool) std.mem.Allocator.Error!void {
    if (!try p.enterDepth()) return;
    defer p.leaveDepth();

    var idx = p.nextSignificantIndex(p.cursor, true);
    if (has_leading_bar and idx < p.tokens.len and p.tokens[idx].tag == .bit_or) {
        idx = p.nextSignificantIndex(idx + 1, true);
    }
    const after_builtin = skipLeadingBuiltinAnnotationsIndex(p, idx);
    if (after_builtin < p.tokens.len and
        (p.tokens[after_builtin].tag == .at or p.tokens[after_builtin].tag == .at_excl))
    {
        try p.startNode(.macro_expand_decl);
        try p.emitLeadingTrivia(true);
        if (has_leading_bar) _ = try p.eat(.bit_or);
        try p.emitPendingDocComments();
        try parseLeadingBuiltinAnnotations(p, true);
        try parseMacroHeader(p, true);
        if (!p.isAtEof() and !p.at(.r_curl) and !p.at(.bit_or)) {
            try parseEnumConstructorOrMacro(p, false);
        }
        try p.finishNode();
        return;
    }

    try parseEnumConstructor(p, has_leading_bar);
}

/// 解析单个枚举构造器 `[|] Ident [( Type, ... )]`。
fn parseEnumConstructor(p: *Parser, has_leading_bar: bool) std.mem.Allocator.Error!void {
    try p.startNode(.enum_constructor);
    try p.emitLeadingTrivia(true);
    if (has_leading_bar) _ = try p.eat(.bit_or);
    try p.emitPendingDocComments();
    try parseLeadingBuiltinAnnotations(p, true);
    _ = try p.expectIdent();
    if (p.at(.l_paren)) {
        try p.bump(); // (
        while (!p.shouldStopList(.paren_type_list)) {
            const before = p.cursor;
            const after_builtin = skipLeadingBuiltinAnnotationsIndex(p, p.cursor);
            if (after_builtin < p.tokens.len and
                (p.tokens[after_builtin].tag == .at or p.tokens[after_builtin].tag == .at_excl))
            {
                try parseMacroExpandParam(p, false);
            } else {
                try parseLeadingBuiltinAnnotations(p, false);
                try type_parser.parseType(p);
            }
            if (try p.eat(.comma)) {
                if (p.shouldStopList(.paren_type_list)) break;
            } else if ((type_parser.canStartType(p) or p.at(.at) or p.at(.at_excl)) and !p.shouldStopList(.paren_type_list)) {
                try p.emitError(.expected_token);
            } else {
                break;
            }
            if (p.cursor == before) try p.bumpErrorToken(.expected_type);
        }
        _ = try p.expectClosing(.r_paren);
    }
    try p.finishNode();
}

/// 解析 `extend` 扩展声明（支持前置泛型参数表、基础类型或复合类型及接口实现列表）。
fn parseExtendDecl(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.extend_decl);
    try p.emitLeadingTrivia(true);
    try parseLeadingBuiltinAnnotations(p, true);
    try parseDeclModifiers(p, .top_level);
    _ = try p.expect(.kw_extend);
    if (p.at(.less)) try parseTypeParameterList(p);
    try type_parser.parseType(p);
    try parseOptionalSuperTypes(p);
    if (p.at(.kw_where)) try parseWhereClause(p);
    if (p.at(.l_curl)) {
        try parseMemberBody(p, .extend_body, .extend_body);
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 解析 `class_body`、`interface_body`、`struct_body`、`extend_body` 或 `foreign_block`。
fn parseMemberBody(p: *Parser, node_kind: SyntaxKind, scope: DeclScope) std.mem.Allocator.Error!void {
    try p.startNode(node_kind);
    try p.emitLeadingTrivia(false);
    try p.bump(); // {
    while (!p.isAtEof() and !p.at(.r_curl)) {
        _ = try p.eatSemicolons();
        if (p.at(.r_curl) or p.isAtEof()) break;
        const before = p.cursor;
        try parseDecl(p, scope);
        _ = try p.eatSemicolons();
        if (p.cursor == before) try p.bumpErrorRun(.expected_item, true);
    }
    _ = try p.expectClosing(.r_curl);
    try p.finishNode();
}

/// 解析 `func` 与 `operator func` 声明（含可选泛型参数表、返回类型、`where` 约束与函数体）。
fn parseFuncDecl(p: *Parser, scope: DeclScope) std.mem.Allocator.Error!void {
    try p.startNode(.func_decl);
    try p.emitLeadingTrivia(true);
    try parseLeadingBuiltinAnnotations(p, true);
    try parseDeclModifiers(p, scope);
    _ = try p.expect(.kw_func);

    if (!try eatOverloadableOperator(p)) {
        _ = try p.expectIdent();
    }

    if (p.at(.less)) try parseTypeParameterList(p);
    try parseFuncParamList(p, false);
    if (try p.eat(.colon)) {
        try parseRetType(p);
    }
    if (p.at(.kw_where)) try parseWhereClause(p);
    if (p.at(.l_curl)) {
        try expr.parseBlock(p);
    }
    try p.finishNode();
}

/// 尝试消费全部 20 种仓颉可重载运算符名称（含 `()`、`[]` 及组合符号 `>>`、`>=`）。
fn eatOverloadableOperator(p: *Parser) std.mem.Allocator.Error!bool {
    if (p.peekCombinedOp(true)) |comb| {
        if (comb.kind == .rshift or comb.kind == .greater_equal) {
            try p.bumpCombined(comb, true);
            return true;
        }
    }
    switch (p.peek()) {
        .l_paren => {
            if (p.peekNth(1) == .r_paren) {
                try p.bump();
                try p.bump();
                return true;
            }
            return false;
        },
        .l_square => {
            if (p.peekNth(1) == .r_square) {
                try p.bump();
                try p.bump();
                return true;
            }
            return false;
        },
        .not,
        .add,
        .sub,
        .exp,
        .mul,
        .div,
        .mod,
        .lshift,
        .less,
        .greater,
        .less_equal,
        .equal,
        .not_equal,
        .bit_and,
        .bit_xor,
        .bit_or,
        => {
            try p.bump();
            return true;
        },
        else => return false,
    }
}

/// 解析程序入口 `[modifiers] main(...) [: Type] { ... }`（修饰符合法性交由语义阶段检查）。
fn parseMainDecl(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.main_decl);
    try p.emitLeadingTrivia(true);
    try parseLeadingBuiltinAnnotations(p, true);
    try parseDeclModifiers(p, .top_level);
    _ = try p.expect(.kw_main);
    try parseFuncParamList(p, false);
    if (try p.eat(.colon)) {
        try parseRetType(p);
    }
    if (p.at(.l_curl)) {
        try expr.parseBlock(p);
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 解析宏定义 `public [late] macro Name(params) [: RetType] (= expr | { ... })`。
fn parseMacroDecl(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.macro_decl);
    try p.emitLeadingTrivia(true);
    try parseLeadingBuiltinAnnotations(p, true);
    try parseDeclModifiers(p, .top_level);
    _ = try p.expect(.kw_macro);
    _ = try p.expectIdent();
    try parseFuncParamList(p, false);
    if (try p.eat(.colon)) {
        try parseRetType(p);
    }
    if (try p.eat(.assign)) {
        try expr.parseExpr(p);
    } else if (p.at(.l_curl)) {
        try expr.parseBlock(p);
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 解析变量与常量声明 `[modifiers] (let | var | const) Pattern [: Type] [= Expr]`。
fn parseVarDecl(p: *Parser, scope: DeclScope) std.mem.Allocator.Error!void {
    try p.startNode(.var_decl);
    try p.emitLeadingTrivia(true);
    try parseLeadingBuiltinAnnotations(p, true);
    try parseDeclModifiers(p, scope);

    if (p.at(.kw_let) or p.at(.kw_var) or p.at(.kw_const)) {
        try p.bump();
    } else {
        try p.emitError(.expected_token);
    }

    try pattern.parsePattern(p, false);
    if (try p.eat(.colon)) {
        try type_parser.parseType(p);
    }
    if (try p.eat(.assign)) {
        try expr.parseExpr(p);
    }
    try p.finishNode();
}

/// 解析属性声明 `[modifiers] prop Ident : Type [{ get() {...} set(v) {...} }]`。
fn parsePropDecl(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.prop_decl);
    try p.emitLeadingTrivia(true);
    try parseLeadingBuiltinAnnotations(p, true);
    try parseDeclModifiers(p, .class_body);
    _ = try p.expect(.kw_prop);
    _ = try p.expectIdent();
    if (try p.expect(.colon)) {
        try type_parser.parseType(p);
    }
    if (p.at(.l_curl)) {
        try p.bump(); // {
        while (!p.isAtEof() and !p.at(.r_curl)) {
            _ = try p.eatSemicolons();
            if (p.at(.r_curl) or p.isAtEof()) break;
            const before = p.cursor;
            if (p.atIdentText("get")) {
                try parsePropGetter(p);
            } else if (p.atIdentText("set")) {
                try parsePropSetter(p);
            } else {
                try p.bumpErrorToken(.expected_item);
            }
            _ = try p.eatSemicolons();
            if (p.cursor == before) try p.bumpErrorToken(.expected_item);
        }
        _ = try p.expectClosing(.r_curl);
    }
    try p.finishNode();
}

/// 解析属性访问器 `get() { ... }`。
fn parsePropGetter(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.prop_getter);
    try p.emitLeadingTrivia(true);
    try p.bumpAs(.identifier); // get
    if (try p.expect(.l_paren)) {
        _ = try p.expectClosing(.r_paren);
    }
    if (p.at(.l_curl)) {
        try expr.parseBlock(p);
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 解析属性修改器 `set(value) { ... }`。
fn parsePropSetter(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.prop_setter);
    try p.emitLeadingTrivia(true);
    try p.bumpAs(.identifier); // set
    if (try p.expect(.l_paren)) {
        _ = try p.expectIdent();
        _ = try p.expectClosing(.r_paren);
    }
    if (p.at(.l_curl)) {
        try expr.parseBlock(p);
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 解析类型别名 `type Alias[<T>] = Type`。
fn parseTypeAliasDecl(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.type_alias_decl);
    try p.emitLeadingTrivia(true);
    try parseLeadingBuiltinAnnotations(p, true);
    try parseDeclModifiers(p, .top_level);
    _ = try p.expect(.kw_type);
    _ = try p.expectIdent();
    if (p.at(.less)) try parseTypeParameterList(p);
    if (try p.expect(.assign)) {
        try type_parser.parseType(p);
    }
    try p.finishNode();
}

/// 解析构造函数与静态初始化器 `[modifiers] init(...) { ... }`。
fn parseInitDecl(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.init_decl);
    try p.emitLeadingTrivia(true);
    try parseLeadingBuiltinAnnotations(p, true);
    try parseDeclModifiers(p, .class_body);
    _ = try p.expect(.kw_init);
    try parseFuncParamList(p, false);
    if (p.at(.l_curl)) {
        try expr.parseBlock(p);
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 解析类终结器 `[modifiers] ~init() { ... }`（修饰符合法性交由语义阶段检查）。
fn parseFinalizerDecl(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.finalizer_decl);
    try p.emitLeadingTrivia(true);
    try parseLeadingBuiltinAnnotations(p, true);
    try parseDeclModifiers(p, .class_body);
    _ = try p.expect(.bit_not);
    _ = try p.expect(.kw_init);
    try parseFuncParamList(p, false);
    if (p.at(.l_curl)) {
        try expr.parseBlock(p);
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 解析类或结构体的主构造器 `[modifiers] TypeName(...) { ... }`。
fn parsePrimaryCtorDecl(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.primary_ctor_decl);
    try p.emitLeadingTrivia(true);
    try parseLeadingBuiltinAnnotations(p, true);
    try parseDeclModifiers(p, .class_body);
    _ = try p.expectIdent();
    try parseFuncParamList(p, true);
    if (p.at(.l_curl)) {
        try expr.parseBlock(p);
    } else {
        try p.emitError(.expected_block);
    }
    try p.finishNode();
}

/// 解析 `foreign` 外部声明（允许前置修饰符与任意内层声明，语义合法性交由后续阶段检查）。
fn parseForeignDecl(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.foreign_decl);
    try p.emitLeadingTrivia(true);
    try parseLeadingBuiltinAnnotations(p, true);
    try parseDeclModifiers(p, .top_level);
    if (try p.expect(.kw_foreign)) {
        if (p.at(.l_curl)) {
            try parseMemberBody(p, .foreign_block, .foreign_block);
        } else {
            try parseDecl(p, .foreign_block);
        }
    }
    try p.finishNode();
}

/// 解析声明侧类型参数表 `<T, U>`（支持缺失逗号恢复与外层边界保护，空 `<>` 报 `.expected_identifier`）。
fn parseTypeParameterList(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.type_parameter_list);
    try p.emitLeadingTrivia(false);
    _ = try p.expect(.less);
    var count: usize = 0;
    while (!p.shouldStopList(.type_param_list)) {
        const before = p.cursor;
        try p.startNode(.type_parameter);
        try p.emitLeadingTrivia(false);
        _ = try p.expectIdent();
        try p.finishNode();
        count += 1;
        if (try p.eat(.comma)) {
            if (p.shouldStopList(.type_param_list)) break;
        } else if (Parser.isIdentLike(p.peek()) and !p.shouldStopList(.type_param_list)) {
            try p.emitError(.expected_token);
        } else {
            break;
        }
        if (p.cursor == before) try p.bumpErrorToken(.expected_identifier);
    }
    if (count == 0) {
        try p.emitError(.expected_identifier);
    }
    _ = try p.expectClosing(.greater);
    try p.finishNode();
}

/// 解析可选的父类与接口实现列表 `<: Super1 & Super2`。
fn parseOptionalSuperTypes(p: *Parser) std.mem.Allocator.Error!void {
    if (!try p.eat(.upperbound)) return;
    try type_parser.parseType(p);
    while (try p.eat(.bit_and)) {
        try type_parser.parseType(p);
    }
}

/// 解析泛型约束子句 `where T <: A & B, This <: C`。
fn parseWhereClause(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.where_clause);
    try p.emitLeadingTrivia(false);
    _ = try p.expect(.kw_where);

    while (!p.isAtEof() and !p.at(.l_curl) and !p.at(.r_curl) and !p.isNewlineDeclBoundary()) {
        const before = p.cursor;
        try p.startNode(.generic_constraint);
        try p.emitLeadingTrivia(false);
        try type_parser.parseType(p);
        if (try p.expect(.upperbound)) {
            try type_parser.parseType(p);
            while (try p.eat(.bit_and)) {
                try type_parser.parseType(p);
            }
        }
        try p.finishNode();

        if (try p.eat(.comma)) {
            if (p.at(.l_curl) or p.at(.r_curl) or p.isNewlineDeclBoundary()) break;
        } else if (type_parser.canStartType(p) and !p.at(.l_curl) and !p.at(.r_curl)) {
            try p.emitError(.expected_token);
        } else {
            break;
        }
        if (p.cursor == before) try p.bumpErrorToken(.expected_type);
    }

    try p.finishNode();
}

/// 解析返回类型包装节点 `ret_type`。
fn parseRetType(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.ret_type);
    if (!p.isNewlineDeclBoundary()) {
        try p.emitLeadingTrivia(false);
    }
    try type_parser.parseType(p);
    try p.finishNode();
}

/// 解析函数、构造器或宏参数表 `(...)`，支持缺失逗号恢复、外层边界保护、主构造器成员参数、参数宏与 `...`。
fn parseFuncParamList(p: *Parser, is_primary_ctor: bool) std.mem.Allocator.Error!void {
    try p.startNode(.func_param_list);
    try p.emitLeadingTrivia(false);
    if (!try p.expect(.l_paren)) {
        try p.finishNode();
        return;
    }

    const list_ctx: parser_mod.ListContext = if (is_primary_ctor) .primary_ctor_param_list else .func_param_list;
    while (!p.shouldStopList(list_ctx)) {
        const before = p.cursor;
        if (p.at(.ellipsis)) {
            try p.bump();
            _ = try p.eat(.comma);
            break;
        }
        const after_builtin = skipLeadingBuiltinAnnotationsIndex(p, p.cursor);
        if (after_builtin < p.tokens.len and
            (p.tokens[after_builtin].tag == .at or p.tokens[after_builtin].tag == .at_excl))
        {
            try parseMacroExpandParam(p, is_primary_ctor);
        } else {
            try parseFuncParam(p, is_primary_ctor);
        }
        if (try p.eat(.comma)) {
            if (p.shouldStopList(list_ctx)) break;
        } else if (canStartFuncParam(p, is_primary_ctor) and !p.shouldStopList(list_ctx)) {
            try p.emitError(.expected_token);
        } else {
            break;
        }
        if (p.cursor == before) try p.bumpErrorToken(.expected_identifier);
    }

    _ = try p.expectClosing(.r_paren);
    try p.finishNode();
}

/// 只读判断当前词法单元是否可以作为函数或主构造器参数的起始符（用于漏逗号恢复判定）。
fn canStartFuncParam(p: *const Parser, is_primary_ctor: bool) bool {
    if (is_primary_ctor and p.isPrimaryCtorMemberParamStart()) return true;
    if (p.isNewlineDeclBoundary()) return false;
    const tag = p.peek();
    if (tag == .wildcard or tag == .ellipsis or tag == .at or tag == .at_excl) return true;
    return Parser.isIdentLike(tag);
}

/// 解析单个函数或主构造器参数（含注解、访问修饰符、`let`/`var`、参数名或 `_`、`!`、类型与默认值）。
pub fn parseFuncParam(p: *Parser, is_primary_ctor: bool) std.mem.Allocator.Error!void {
    try p.startNode(.func_param);
    try p.emitLeadingTrivia(true);
    try parseLeadingBuiltinAnnotations(p, true);

    if (is_primary_ctor) {
        const mod = p.peek();
        if (mod == .kw_public or mod == .kw_private or mod == .kw_protected or mod == .kw_internal) {
            const next = p.peekNth(1);
            if (next == .kw_let or next == .kw_var) {
                try p.bump();
            }
        }
        if (p.at(.kw_let) or p.at(.kw_var)) {
            try p.bump();
        }
    }

    if (p.at(.wildcard)) {
        try p.bump();
    } else {
        _ = try p.expectIdent();
    }

    _ = try p.eat(.not);
    if (try p.eat(.colon)) {
        try type_parser.parseType(p);
    }
    if (try p.eat(.assign)) {
        try expr.parseExpr(p);
    }

    try p.finishNode();
}

/// 只读线性判断从物理下标 `start_idx` 开始的宏调用是否不带括号（即修饰后续声明或参数）。
pub fn isMacroWithoutParensAtIndex(p: *const Parser, start_idx: usize) bool {
    if (start_idx >= p.tokens.len) return false;
    const first = p.tokens[start_idx].tag;
    if (first != .at and first != .at_excl) return false;
    const after_header = skipMacroOrAnnotationHeaderIndex(p, start_idx);
    if (after_header >= p.tokens.len) return true;
    return p.tokens[after_header].tag != .l_paren;
}

/// 解析声明位置的宏调用或自定义注解（`@M[attr](input)`、`@!M[attr] decl`）。
fn parseMacroExpandDecl(p: *Parser, scope: DeclScope) std.mem.Allocator.Error!void {
    if (!try p.enterDepth()) return;
    defer p.leaveDepth();

    try p.startNode(.macro_expand_decl);
    try p.emitLeadingTrivia(true);
    try parseLeadingBuiltinAnnotations(p, true);
    try parseMacroHeader(p, true);

    if (p.at(.l_paren)) {
        try parseMacroInputParens(p);
    } else if (!p.isAtEof() and !p.at(.r_curl)) {
        try parseDecl(p, scope);
    }

    try p.finishNode();
}

/// 解析函数/主构造器参数位置的宏调用或自定义注解（`func f(@M x: Int64)`）。
fn parseMacroExpandParam(p: *Parser, is_primary_ctor: bool) std.mem.Allocator.Error!void {
    if (!try p.enterDepth()) return;
    defer p.leaveDepth();

    try p.startNode(.macro_expand_param);
    try p.emitLeadingTrivia(true);
    try parseLeadingBuiltinAnnotations(p, true);
    try parseMacroHeader(p, true);

    if (p.at(.l_paren)) {
        try parseMacroInputParens(p);
    } else if (!p.isAtEof() and !p.at(.r_paren) and !p.at(.comma)) {
        const after_builtin = skipLeadingBuiltinAnnotationsIndex(p, p.cursor);
        if (after_builtin < p.tokens.len and
            (p.tokens[after_builtin].tag == .at or p.tokens[after_builtin].tag == .at_excl))
        {
            try parseMacroExpandParam(p, is_primary_ctor);
        } else {
            try parseFuncParam(p, is_primary_ctor);
        }
    }

    try p.finishNode();
}

/// 解析宏调用头部：`@`/`@!`、点分宏名与可选 `[...]` 属性片段（`macro_attributes`）。
pub fn parseMacroHeader(p: *Parser, allow_at_excl: bool) std.mem.Allocator.Error!void {
    if (p.at(.at)) {
        try p.bump();
    } else if (p.at(.at_excl)) {
        if (!allow_at_excl) try p.emitError(.unexpected_token);
        try p.bump();
    } else {
        try p.emitError(.expected_token);
    }

    if (p.hasNewlineBefore()) {
        try p.emitError(.expected_identifier);
    }
    _ = try p.expectIdent();
    while (p.at(.dot)) {
        try p.bump();
        _ = try p.expectIdent();
    }

    if (p.at(.l_square)) {
        try parseMacroAttributes(p);
    }
}

/// 解析宏属性 `[...]`（`macro_attributes`），追踪中括号配对并支持 `\[`、`\]`、`\@` 转义。
fn parseMacroAttributes(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.macro_attributes);
    try p.emitLeadingTrivia(false);
    try p.bump(); // [

    var depth: u32 = 1;
    var token_count: usize = 0;

    while (p.cursor < p.tokens.len) {
        const sig_idx = p.nextSignificantIndex(p.cursor, true);
        if (sig_idx >= p.tokens.len) break;
        const tok = p.tokens[sig_idx];
        if (tok.tag == .end) break;

        if (tok.tag == .illegal and std.mem.eql(u8, p.tokenText(tok), "\\") and sig_idx + 1 < p.tokens.len) {
            const next = p.tokens[sig_idx + 1];
            if (Parser.isAdjacent(tok, next) and
                (next.tag == .l_square or next.tag == .r_square or next.tag == .at or next.tag == .at_excl))
            {
                try p.bumpAllowDoc();
                try p.bumpAllowDoc();
                token_count += 1;
                continue;
            }
        }

        if (tok.tag == .l_square) {
            depth += 1;
            try p.bumpAllowDoc();
            token_count += 1;
        } else if (tok.tag == .r_square) {
            depth -= 1;
            try p.bumpAllowDoc();
            if (depth == 0) break;
            token_count += 1;
        } else {
            if (p.combinedOpAt(sig_idx)) |comb| {
                try p.bumpCombinedAllowDoc(comb, true);
            } else {
                try p.bumpAllowDoc();
            }
            token_count += 1;
        }
    }

    if (depth > 0) {
        try p.emitError(.unclosed_delimiter);
    } else if (token_count == 0) {
        try p.emitError(.expected_token);
    }
    try p.finishNode();
}

/// 解析宏调用括号输入 `(...)`（`macro_input`），追踪小括号配对并支持 `\(`、`\)`、`\@` 转义。
pub fn parseMacroInputParens(p: *Parser) std.mem.Allocator.Error!void {
    try p.startNode(.macro_input);
    try p.emitLeadingTrivia(false);
    _ = try p.expect(.l_paren);

    var depth: u32 = 1;
    while (p.cursor < p.tokens.len) {
        const sig_idx = p.nextSignificantIndex(p.cursor, true);
        if (sig_idx >= p.tokens.len) break;
        const tok = p.tokens[sig_idx];
        if (tok.tag == .end) break;

        if (tok.tag == .illegal and std.mem.eql(u8, p.tokenText(tok), "\\") and sig_idx + 1 < p.tokens.len) {
            const next = p.tokens[sig_idx + 1];
            if (Parser.isAdjacent(tok, next) and
                (next.tag == .l_paren or next.tag == .r_paren or next.tag == .at or next.tag == .at_excl))
            {
                try p.bumpAllowDoc();
                try p.bumpAllowDoc();
                continue;
            }
        }

        if (tok.tag == .l_paren) {
            depth += 1;
            try p.bumpAllowDoc();
        } else if (tok.tag == .r_paren) {
            depth -= 1;
            try p.bumpAllowDoc();
            if (depth == 0) break;
        } else {
            if (p.combinedOpAt(sig_idx)) |comb| {
                try p.bumpCombinedAllowDoc(comb, true);
            } else {
                try p.bumpAllowDoc();
            }
        }
    }

    if (depth > 0) {
        try p.emitError(.unclosed_delimiter);
    }
    try p.finishNode();
}
