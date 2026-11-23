// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 仓颉源码的语法解析器。
//!
//! 以事件流（`Event`）形式产出 Lossless CST 构建指令，交由下游 `GreenBuilder` 构造只读绿树。
//! 表达式部分使用 Pratt 解析，其余部分使用递归下降，并严格遵循三项核心不变式：
//! 1. 只读前瞻：所有 `peek*` 方法只读取游标，不向事件流发射任何词法单元。
//! 2. 完全的前导 Trivia 发射：所有空白（`whitespace`）、换行（`newline`）与注释均作为后续语法节点或
//!    词法单元的前导 Trivia 发射在其内部开头，文件末尾残余 Trivia 归属 `source_file`；`///` 与 `/**...*/`
//!    文档注释归属其修饰的声明对象，无注释对象时记录 `dangling_doc_comment` 错误。
//! 3. 点分路径平铺：同链的 `a.b.c`、`a?.b.c`、`g().b.c` 始终平铺在单个 `path_expr` 或 `path_type` 内，
//!    每段均由 `path_segment` 表示。

const std = @import("std");
const common = @import("common");
const TokenTag = common.TokenTag;
const SyntaxKind = common.SyntaxKind;

pub const lexer = @import("./lexer.zig");
pub const decl = @import("./parser/decl.zig");
pub const expr = @import("./parser/expr.zig");
pub const type_parser = @import("./parser/type.zig");
pub const pattern = @import("./parser/pattern.zig");

/// 递归下降与 Pratt 嵌套深度上限，防止极端输入耗尽调用空间。
pub const max_recursion_depth: u32 = 256;

/// 解析错误码。
pub const ParseErrorCode = enum(u8) {
    expected_expression,
    expected_token,
    expected_item,
    non_associative_comparison,
    recursive_depth_limit,
    invalid_literal,
    expected_type,
    expected_pattern,
    expected_identifier,
    expected_block,
    non_associative_assignment,
    non_associative_operator,
    invalid_assignment_target,
    unclosed_delimiter,
    illegal_token,
    unexpected_token,
    invalid_interpolation,
    dangling_doc_comment,
};

/// 解析错误，携带错误码与源码字节区间。
pub const ParseError = struct {
    code: ParseErrorCode,
    range: common.TextRange,

    /// 将当前 `ParseError` 转换为平台统一的 `common.Diagnostic`。
    ///
    /// 若错误消息可在编译期确定，则返回的 `Diagnostic.message` 为静态字符串切片（不经过
    /// `allocator` 分配，不可单独释放）；仅当需拼接源码片段时通过 `allocator` 分配内存。
    /// 推荐传入 `ArenaAllocator` 统一管理诊断消息的生命周期。
    pub inline fn toDiagnostic(
        self: ParseError,
        allocator: std.mem.Allocator,
        file: common.FileId,
        source: []const u8,
    ) std.mem.Allocator.Error!common.Diagnostic {
        return parseErrorToDiagnostic(allocator, file, source, self);
    }
};

/// 诊断消息中嵌入源码片段的最大字节长度（按合法 UTF-8 码点边界截断）。
const max_snippet_bytes: usize = 32;

/// 安全提取用于诊断展示的单行源码片段；区间越界、倒置、为空或首行仅空白时返回 `null`。
///
/// 返回的切片借用自 `source`，调用者不可释放，生命周期不超过 `source`。
fn extractDiagnosticSnippet(source: []const u8, range: common.TextRange) ?[]const u8 {
    if (range.start >= range.end or range.end > source.len) return null;
    var slice = source[range.start..range.end];
    if (std.mem.indexOfAny(u8, slice, "\r\n")) |nl_pos| {
        slice = slice[0..nl_pos];
    }
    slice = std.mem.trim(u8, slice, " \t\x0c");
    if (slice.len == 0) return null;
    if (slice.len <= max_snippet_bytes) return slice;

    // 按 UTF-8 码点边界截断，避免切断多字节字符
    var pos: usize = 0;
    while (pos < slice.len) {
        const cp = common.utf8.decodeAt(slice, pos) orelse break;
        if (pos + cp.len > max_snippet_bytes) break;
        pos += cp.len;
    }
    return if (pos > 0) slice[0..pos] else null;
}

/// 将单个 `ParseError` 转换为平台统一的 `common.Diagnostic`。
///
/// 遵循诊断消息混合所有权约定：
/// - 对于编译期可完全确定的错误码，或 `err.range` 无有效可展示源码片段时，`Diagnostic.message`
///   直接返回编译期静态字符串切片，不调用 `allocator`，调用者不可对其单独 `free`。
/// - 对于需要拼入源码片段的错误，通过 `allocator` 分配 `Diagnostic.message`。
/// - `Diagnostic.related` 始终为空静态切片，`source` 仅作只读借用。
/// 推荐传入 `ArenaAllocator` 统一托管诊断消息的生命周期。
pub fn parseErrorToDiagnostic(
    allocator: std.mem.Allocator,
    file: common.FileId,
    source: []const u8,
    err: ParseError,
) std.mem.Allocator.Error!common.Diagnostic {
    const message: []const u8 = switch (err.code) {
        // 编译期完全确定的固定错误消息：零堆分配
        .recursive_depth_limit => "syntax nesting exceeds maximum recursion depth",
        .non_associative_comparison => "comparison operators are non-associative",
        .non_associative_assignment => "assignment operators are non-associative",
        .non_associative_operator => "operator is non-associative",
        .invalid_assignment_target => "invalid assignment target",
        .unclosed_delimiter => "unclosed delimiter",
        .invalid_interpolation => "invalid string interpolation",
        .dangling_doc_comment => "dangling doc comment has no target declaration",

        // 存在有效源码片段时动态格式化，否则直接返回编译期静态字符串（零分配）
        .expected_expression => if (extractDiagnosticSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "expected expression near `{s}`", .{s})
        else
            "expected expression",
        .expected_token => if (extractDiagnosticSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "expected token near `{s}`", .{s})
        else
            "expected token",
        .expected_item => if (extractDiagnosticSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "expected declaration or item near `{s}`", .{s})
        else
            "expected declaration or item",
        .invalid_literal => if (extractDiagnosticSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "invalid literal `{s}`", .{s})
        else
            "invalid literal",
        .expected_type => if (extractDiagnosticSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "expected type near `{s}`", .{s})
        else
            "expected type",
        .expected_pattern => if (extractDiagnosticSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "expected pattern near `{s}`", .{s})
        else
            "expected pattern",
        .expected_identifier => if (extractDiagnosticSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "expected identifier near `{s}`", .{s})
        else
            "expected identifier",
        .expected_block => if (extractDiagnosticSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "expected block near `{s}`", .{s})
        else
            "expected block",
        .illegal_token => if (extractDiagnosticSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "illegal token `{s}`", .{s})
        else
            "illegal token",
        .unexpected_token => if (extractDiagnosticSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "unexpected token `{s}`", .{s})
        else
            "unexpected token",
    };

    return .{
        .file = file,
        .range = err.range,
        .severity = .err,
        .source = .parser,
        .message = message,
        .related = &.{},
    };
}

/// 词法叶子事件，携带经语法分析确定后的 CST 叶子标签与源码字节区间。
pub const TokenEvent = struct {
    kind: SyntaxKind,
    range: common.TextRange,
};

/// 解析事件。
///
/// Parser 只产生事件而把 Green CST 构建交给 GreenBuilder，以保证绿树的只读性。
/// `start_node` 与 `wrap_node` 的总次数与 `finish_node` 严格相等。位置信息仅由
/// `token` 和 `parse_error` 携带。
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

/// 解析上下文限制标志，控制尾随闭包、区间步长、半开切片与 `if`/`while` 的 `let` 解构条件。
pub const Restrictions = packed struct {
    /// 是否允许表达式后紧跟尾随 lambda（在 `if`、`while`、`match` 条件与 `for-in` 迭代源中关闭）。
    allow_trailing_closure: bool = true,
    /// 是否允许 `range_expr` 解析 `: step` 步长部分。
    allow_range_colon: bool = true,
    /// 是否允许 `range_expr` 省略右端点（用于下标切片 `arr[1..]`）。
    allow_open_range_end: bool = false,
    /// 是否允许 `let pattern <- expr` 条件解构（仅在 `if` / `while` 条件及其单元素括号内启用）。
    allow_let_condition: bool = false,
};

/// 前瞻回溯检查点，完整保存游标、事件缓冲长度、已发射字节位置、递归深度、错误列表长度与上下文限制。
pub const Checkpoint = struct {
    cursor: usize,
    event_len: usize,
    emitted_pos: u32,
    depth: u32,
    error_len: usize,
    restrictions: Restrictions,
};

/// 组合运算符识别结果。
pub const CombinedOp = struct {
    kind: SyntaxKind,
    /// 构成该组合运算符的原始词法单元数量（2 或 3）。
    token_count: u8,
};

/// 逗号分隔列表的恢复上下文类型，用于决定外层硬同步边界（避免未闭合列表吞噬外层代码）。
pub const ListContext = enum {
    paren_expr_list,
    square_expr_list,
    func_param_list,
    primary_ctor_param_list,
    type_param_list,
    type_arg_list,
    paren_type_list,
    pattern_list,
    brace_list,
};

/// 仓颉内置注解名称表，与参考编译器及 `cangjie_spec` 一致。
const builtin_annotations = std.StaticStringMap(void).initComptime(.{
    .{ "Annotation", {} },
    .{ "Deprecated", {} },
    .{ "When", {} },
    .{ "Frozen", {} },
    .{ "Intrinsic", {} },
    .{ "Attribute", {} },
    .{ "ConstSafe", {} },
    .{ "OverflowThrowing", {} },
    .{ "OverflowWrapping", {} },
    .{ "OverflowSaturating", {} },
    .{ "C", {} },
    .{ "CallingConv", {} },
    .{ "FastNative", {} },
    .{ "Java", {} },
    .{ "JavaMirror", {} },
    .{ "JavaImpl", {} },
    .{ "JavaHasDefault", {} },
    .{ "ObjC", {} },
    .{ "ObjCMirror", {} },
    .{ "ObjCImpl", {} },
    .{ "ObjCInit", {} },
    .{ "ObjCOptional", {} },
    .{ "ForeignName", {} },
    .{ "ForeignGetterName", {} },
    .{ "ForeignSetterName", {} },
    .{ "EnsurePreparedToMock", {} },
    .{ "NonProduct", {} },
});

/// 语法解析器。
///
/// 表达式部分使用 Pratt 解析，其余部分使用递归下降。对于传入的任意切片，保证不崩溃且事件流平衡。
pub const Parser = struct {
    allocator: std.mem.Allocator,
    /// 当前解析切片对应的源码文本（由调用者持有，借用期间保持有效）。
    source: []const u8,
    /// 词法单元切片（由调用者持有，借用期间保持有效）。
    tokens: []const common.Token,
    /// 当前源码长度上限（钳制在 `u32` 范围内）。
    source_len: u32,
    /// 全局文件起始位置；顶层文件为 `0`，字符串插值子解析器为插值内容起始字节位置。
    base_offset: u32 = 0,
    /// 当前尚未处理的词法单元下标。
    cursor: usize = 0,
    /// 相对于 `source` 已发射到事件流的字节位置，用于合成 `SyntaxKind.whitespace`。
    emitted_pos: u32 = 0,
    /// 内部事件缓冲区，由 `allocator` 分配并在 `deinit` 时释放。
    events: std.ArrayList(Event) = .empty,
    /// 解析过程中产生的全部 `ParseError`，由 `allocator` 分配并在 `deinit` 时释放。
    errors: std.ArrayList(ParseError) = .empty,
    /// 下一次 `gen` 将要返回的事件下标。
    read_index: usize = 0,
    /// 是否已完成整份输入的解析。
    parsed: bool = false,
    /// 当前递归嵌套深度。
    depth: u32 = 0,
    /// 当前语法上下文限制标志。
    restrictions: Restrictions = .{},

    /// 创建语法解析器。
    ///
    /// `source` 与 `tokens` 均借用自调用者，本结构体不复制也不负责释放它们的内存；
    /// 使用结束后调用者须调用 `deinit` 释放内部事件与错误缓冲区。
    pub fn new(
        allocator: std.mem.Allocator,
        source: []const u8,
        tokens: []const common.Token,
    ) Parser {
        const clamped_len: u32 = @intCast(@min(source.len, std.math.maxInt(u32)));
        return .{
            .allocator = allocator,
            .source = source,
            .tokens = tokens,
            .source_len = clamped_len,
        };
    }

    /// 释放解析器内部的事件缓冲区与 `errors` 错误列表内存。
    ///
    /// 不释放构造时借用的 `source` 与 `tokens`。
    pub fn deinit(self: *Parser) void {
        self.events.deinit(self.allocator);
        self.errors.deinit(self.allocator);
        self.* = undefined;
    }

    /// 产出下一个解析事件；全部事件消费完毕后返回 `null`。
    ///
    /// 首次调用时执行整份源文件的完整语法解析并将事件写入 `events`、错误写入 `errors`；
    /// 若期间发生内存不足，会清空半成品数据并复位全部状态，避免后续读取到残缺状态。
    pub fn gen(self: *Parser) std.mem.Allocator.Error!?Event {
        if (!self.parsed) {
            errdefer {
                self.events.clearRetainingCapacity();
                self.errors.clearRetainingCapacity();
                self.cursor = 0;
                self.emitted_pos = 0;
                self.read_index = 0;
                self.depth = 0;
                self.restrictions = .{};
                self.parsed = false;
            }
            try decl.parseSourceFile(self);
            self.parsed = true;
        }
        if (self.read_index >= self.events.items.len) return null;
        const ev = self.events.items[self.read_index];
        self.read_index += 1;
        return ev;
    }

    /// 判定给定标识符文本是否属于仓颉内置注解名称表。
    pub inline fn isBuiltinAnnotationName(name: []const u8) bool {
        return builtin_annotations.has(name);
    }

    /// 将当前切片内的局部字节位置通过饱和加法映射为全局文件字节位置，防止 `u32` 溢出。
    pub inline fn globalPos(self: *const Parser, local: u32) u32 {
        return self.base_offset +| local;
    }

    /// 将词法 `Span` 防御性钳制到当前 `source` 合法范围，并转换为 `TextRange`。
    pub inline fn safeRange(self: *const Parser, span: common.Span) common.TextRange {
        const start = @min(span.start, self.source_len);
        const end = @max(start, @min(span.end, self.source_len));
        return .{ .start = start, .end = end };
    }

    /// 安全获取指定词法单元对应的源码切片，越界或倒置区间返回空切片。
    ///
    /// 返回的切片借用自 `self.source`，调用者不可释放，且其生命周期不超过 `self.source`。
    pub inline fn tokenText(self: *const Parser, tok: common.Token) []const u8 {
        const r = self.safeRange(tok.span);
        return self.source[r.start..r.end];
    }

    /// 判定标签是否为规范中的上下文关键字或可在标识符位置复用的词法标签。
    pub inline fn isContextKeywordTag(tag: TokenTag) bool {
        return switch (tag) {
            .kw_public,
            .kw_private,
            .kw_protected,
            .kw_internal,
            .kw_override,
            .kw_redef,
            .kw_abstract,
            .kw_sealed,
            .kw_open,
            .kw_with,
            .kw_throwing,
            .kw_handle,
            => true,
            else => false,
        };
    }

    /// 判定标签是否可作为标识符使用（含普通标识符与上下文关键字）。
    pub inline fn isIdentLike(tag: TokenTag) bool {
        return tag == .identifier or isContextKeywordTag(tag);
    }

    /// 判定标签是否为包名段可用标识符（含普通标识符、上下文关键字与反引号包名）。
    pub inline fn isPackageIdentLike(tag: TokenTag) bool {
        return isIdentLike(tag) or tag == .package_identifier;
    }

    /// 判定标签是否为内建基础类型关键字（不含 `This` 与 `VArray`）。
    pub inline fn isPrimitiveTypeTag(tag: TokenTag) bool {
        return switch (tag) {
            .kw_int8,
            .kw_int16,
            .kw_int32,
            .kw_int64,
            .kw_int_native,
            .kw_uint8,
            .kw_uint16,
            .kw_uint32,
            .kw_uint64,
            .kw_uint_native,
            .kw_float16,
            .kw_float32,
            .kw_float64,
            .kw_rune,
            .kw_bool,
            .kw_nothing,
            .kw_unit,
            => true,
            else => false,
        };
    }

    /// 判定标签是否为数值或字符类型转换关键字（`Int8`..`Float64` 及 `Rune`）。
    pub inline fn isNumericOrRuneTypeTag(tag: TokenTag) bool {
        return switch (tag) {
            .kw_int8,
            .kw_int16,
            .kw_int32,
            .kw_int64,
            .kw_int_native,
            .kw_uint8,
            .kw_uint16,
            .kw_uint32,
            .kw_uint64,
            .kw_uint_native,
            .kw_float16,
            .kw_float32,
            .kw_float64,
            .kw_rune,
            => true,
            else => false,
        };
    }

    /// 根据注释源码文本将其划分为单行注释、文档注释或块注释标签。
    ///
    /// 文档注释覆盖 `///...`（不含 `////...`）与 `/**...*/`（不含 `/**/` 与 `/***...`）。
    pub inline fn classifyComment(self: *const Parser, tok: common.Token) SyntaxKind {
        const text = self.tokenText(tok);
        if (std.mem.startsWith(u8, text, "//")) {
            if (text.len >= 3 and text[2] == '/' and (text.len == 3 or text[3] != '/')) {
                return .doc_comment;
            }
            return .line_comment;
        }
        if (std.mem.startsWith(u8, text, "/**") and text.len >= 5 and text[3] != '*') {
            return .doc_comment;
        }
        return .block_comment;
    }

    /// 将任意词法单元转换为对应的 CST 叶子标签。
    pub inline fn tokenToSyntaxKind(self: *const Parser, tok: common.Token) SyntaxKind {
        return switch (tok.tag) {
            .comment => self.classifyComment(tok),
            .sentinel => .illegal,
            else => common.toSyntaxKind(tok.tag) orelse .illegal,
        };
    }

    /// 返回自 `start_idx` 起跳过注释（以及可选跳过换行）后的首个词法单元下标；到达末尾返回 `tokens.len`。
    pub fn nextSignificantIndex(self: *const Parser, start_idx: usize, skip_nl: bool) usize {
        var idx = start_idx;
        while (idx < self.tokens.len) : (idx += 1) {
            const tag = self.tokens[idx].tag;
            if (tag == .comment) continue;
            if (skip_nl and tag == .nl) continue;
            return idx;
        }
        return self.tokens.len;
    }

    /// 只读查询自当前游标起第 `nth`（从 0 起）个非 Trivia 词法单元下标；越界返回 `null`。
    pub fn peekIndexNth(self: *const Parser, nth: usize, skip_nl: bool) ?usize {
        var idx = self.cursor;
        var count: usize = 0;
        while (idx < self.tokens.len) {
            const tag = self.tokens[idx].tag;
            if (tag == .comment or (skip_nl and tag == .nl)) {
                idx += 1;
                continue;
            }
            if (tag == .end) return null;
            if (count == nth) return idx;
            count += 1;
            idx += 1;
        }
        return null;
    }

    /// 只读前瞻当前有效词法单元标签（跳过注释与换行）；到达文件尾返回 `.end`。
    pub inline fn peek(self: *const Parser) TokenTag {
        const idx = self.nextSignificantIndex(self.cursor, true);
        if (idx >= self.tokens.len) return .end;
        return self.tokens[idx].tag;
    }

    /// 只读前瞻当前有效词法单元标签（仅跳过注释，保留换行 `.nl`）；到达文件尾返回 `.end`。
    pub inline fn peekNoNl(self: *const Parser) TokenTag {
        const idx = self.nextSignificantIndex(self.cursor, false);
        if (idx >= self.tokens.len) return .end;
        return self.tokens[idx].tag;
    }

    /// 只读前瞻第 `nth`（从 0 起）个跳过注释与换行后的词法单元标签；越界返回 `.end`。
    pub inline fn peekNth(self: *const Parser, nth: usize) TokenTag {
        const idx = self.peekIndexNth(nth, true) orelse return .end;
        return self.tokens[idx].tag;
    }

    /// 只读前瞻第 `nth`（从 0 起）个词法单元文本（跳过注释与换行）；越界返回空切片。
    ///
    /// 返回的切片借用自 `self.source` 或静态空字面量，调用者不可释放，生命周期不超过 `self.source`。
    pub inline fn peekTextNth(self: *const Parser, nth: usize) []const u8 {
        const idx = self.peekIndexNth(nth, true) orelse return "";
        return self.tokenText(self.tokens[idx]);
    }

    /// 只读判断当前游标至下一个有效词法单元之间是否存在换行符。
    pub fn hasNewlineBefore(self: *const Parser) bool {
        var idx = self.cursor;
        while (idx < self.tokens.len) : (idx += 1) {
            const tag = self.tokens[idx].tag;
            if (tag == .nl) return true;
            if (tag == .comment) continue;
            return false;
        }
        return false;
    }

    /// 只读判断当前是否位于指定标签上（跳过注释与换行）。
    pub inline fn at(self: *const Parser, tag: TokenTag) bool {
        return self.peek() == tag;
    }

    /// 只读判断当前位置是否匹配指定标识符文本（跳过注释与换行，要求为普通 `.identifier`）。
    pub inline fn atIdentText(self: *const Parser, expected: []const u8) bool {
        const idx = self.nextSignificantIndex(self.cursor, true);
        if (idx >= self.tokens.len) return false;
        const tok = self.tokens[idx];
        if (tok.tag != .identifier) return false;
        return std.mem.eql(u8, self.tokenText(tok), expected);
    }

    /// 只读判断当前位置（跳过注释，可选跳过换行）是否构成相邻的组合运算符（`??`、`>>`、`>>=`、`>=`）。
    pub fn peekCombinedOp(self: *const Parser, skip_nl: bool) ?CombinedOp {
        const idx = self.nextSignificantIndex(self.cursor, skip_nl);
        return self.combinedOpAt(idx);
    }

    /// 只读判断给定下标处是否构成物理相邻的组合运算符（`??`、`>>`、`>>=`、`>=`）。
    pub fn combinedOpAt(self: *const Parser, idx: usize) ?CombinedOp {
        if (idx >= self.tokens.len or self.tokens.len - idx < 2) return null;
        const t0 = self.tokens[idx];
        const t1 = self.tokens[idx + 1];
        if (t0.span.end != t1.span.start) return null;

        if (t0.tag == .quest and t1.tag == .quest) {
            return .{ .kind = .coalescing, .token_count = 2 };
        }
        if (t0.tag == .greater and t1.tag == .assign) {
            return .{ .kind = .greater_equal, .token_count = 2 };
        }
        if (t0.tag == .greater and t1.tag == .greater) {
            if (self.tokens.len - idx >= 3) {
                const t2 = self.tokens[idx + 2];
                if (t1.span.end == t2.span.start and t2.tag == .assign) {
                    return .{ .kind = .rshift_assign, .token_count = 3 };
                }
            }
            return .{ .kind = .rshift, .token_count = 2 };
        }
        return null;
    }

    /// 判断两词法单元在源码字节上是否物理紧邻。
    pub inline fn isAdjacent(a: common.Token, b: common.Token) bool {
        return a.span.end == b.span.start;
    }

    /// 只读返回当前有效词法单元对应的全局字节区间（用于错误定位）。
    pub fn currentErrorRange(self: *const Parser) common.TextRange {
        const idx = self.nextSignificantIndex(self.cursor, true);
        if (idx < self.tokens.len and self.tokens[idx].tag != .end) {
            const r = self.safeRange(self.tokens[idx].span);
            return .{
                .start = self.globalPos(r.start),
                .end = self.globalPos(r.end),
            };
        }
        const pos = self.globalPos(self.emitted_pos);
        return .{ .start = pos, .end = pos };
    }

    /// 保存当前状态作为回溯检查点。
    pub inline fn checkpoint(self: *const Parser) Checkpoint {
        return .{
            .cursor = self.cursor,
            .event_len = self.events.items.len,
            .emitted_pos = self.emitted_pos,
            .depth = self.depth,
            .error_len = self.errors.items.len,
            .restrictions = self.restrictions,
        };
    }

    /// 回退解析器状态至指定检查点。
    pub inline fn rollback(self: *Parser, cp: Checkpoint) void {
        self.cursor = cp.cursor;
        self.events.shrinkRetainingCapacity(cp.event_len);
        self.emitted_pos = cp.emitted_pos;
        self.depth = cp.depth;
        self.errors.shrinkRetainingCapacity(cp.error_len);
        self.restrictions = cp.restrictions;
    }

    /// 进入一层递归；超出 `max_recursion_depth` 时记录诊断并返回 `false`。
    pub fn enterDepth(self: *Parser) std.mem.Allocator.Error!bool {
        if (self.depth >= max_recursion_depth) {
            try self.emitError(.recursive_depth_limit);
            return false;
        }
        self.depth += 1;
        return true;
    }

    /// 退出一层递归。
    pub inline fn leaveDepth(self: *Parser) void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
    }

    /// 发射一个 `start_node` 事件。
    pub inline fn startNode(self: *Parser, kind: SyntaxKind) std.mem.Allocator.Error!void {
        try self.events.append(self.allocator, .{ .start_node = kind });
    }

    /// 发射一个 `wrap_node` 事件，包裹当前父节点最后一项已完成子节点。
    pub inline fn wrapNode(self: *Parser, kind: SyntaxKind) std.mem.Allocator.Error!void {
        try self.events.append(self.allocator, .{ .wrap_node = kind });
    }

    /// 发射一个 `finish_node` 事件。
    pub inline fn finishNode(self: *Parser) std.mem.Allocator.Error!void {
        try self.events.append(self.allocator, .finish_node);
    }

    /// 在当前有效词法单元位置记录一条语法错误诊断。
    pub fn emitError(self: *Parser, code: ParseErrorCode) std.mem.Allocator.Error!void {
        try self.emitErrorAt(code, self.currentErrorRange());
    }

    /// 在指定全局字节区间记录一条语法错误诊断，同时存入 `errors` 成员与事件流。
    pub fn emitErrorAt(self: *Parser, code: ParseErrorCode, range: common.TextRange) std.mem.Allocator.Error!void {
        const err_item: ParseError = .{ .code = code, .range = range };
        try self.errors.append(self.allocator, err_item);
        errdefer _ = self.errors.pop();
        try self.events.append(self.allocator, .{
            .parse_error = err_item,
        });
    }

    /// 发射单个 CST 叶子事件，自动补发前导水平空白并钳制区间维持单调不回退与无重复字节。
    pub fn emitLeaf(self: *Parser, kind: SyntaxKind, local_range: common.TextRange) std.mem.Allocator.Error!void {
        const clamped_start = @max(self.emitted_pos, @min(local_range.start, self.source_len));
        const clamped_end = @max(clamped_start, @min(local_range.end, self.source_len));

        if (self.emitted_pos < clamped_start) {
            try self.events.append(self.allocator, .{
                .token = .{
                    .kind = .whitespace,
                    .range = .{
                        .start = self.globalPos(self.emitted_pos),
                        .end = self.globalPos(clamped_start),
                    },
                },
            });
        }
        try self.events.append(self.allocator, .{
            .token = .{
                .kind = kind,
                .range = .{
                    .start = self.globalPos(clamped_start),
                    .end = self.globalPos(clamped_end),
                },
            },
        });
        self.emitted_pos = clamped_end;
    }

    /// 补发 `emitted_pos` 至 `source_len` 之间的尾部水平空白（用于文件末尾与插值片段末尾）。
    pub fn emitTrailingWhitespace(self: *Parser) std.mem.Allocator.Error!void {
        if (self.emitted_pos < self.source_len) {
            try self.events.append(self.allocator, .{
                .token = .{
                    .kind = .whitespace,
                    .range = .{
                        .start = self.globalPos(self.emitted_pos),
                        .end = self.globalPos(self.source_len),
                    },
                },
            });
            self.emitted_pos = self.source_len;
        }
    }

    /// 补发 `emitted_pos` 至当前游标词法单元起点之间的水平空白，使新开启子节点首字符精确对应首个非空白字符。
    pub fn emitPendingWhitespace(self: *Parser) std.mem.Allocator.Error!void {
        if (self.cursor >= self.tokens.len) return;
        const tok = self.tokens[self.cursor];
        if (tok.tag == .end) return;
        const range = self.safeRange(tok.span);
        if (self.emitted_pos < range.start) {
            try self.events.append(self.allocator, .{
                .token = .{
                    .kind = .whitespace,
                    .range = .{
                        .start = self.globalPos(self.emitted_pos),
                        .end = self.globalPos(range.start),
                    },
                },
            });
            self.emitted_pos = range.start;
        }
    }

    /// 内部公共前导 Trivia 发射：消费连续的注释（及可选换行），按需补发其后的水平空白。
    ///
    /// 当 `allow_doc_comment` 为 `false` 且存在 `doc_comment` 时，合并相邻悬空文档注释区间并记录
    /// `ParseErrorCode.dangling_doc_comment`，同时无损发射 `.doc_comment` 叶子。
    fn emitTriviaInternal(
        self: *Parser,
        include_nl: bool,
        allow_doc_comment: bool,
        emit_pending_ws: bool,
    ) std.mem.Allocator.Error!void {
        var dangling_doc_start: ?u32 = null;
        var dangling_doc_end: u32 = 0;

        while (self.cursor < self.tokens.len) {
            const tok = self.tokens[self.cursor];
            if (tok.tag == .comment) {
                const kind = self.classifyComment(tok);
                const range = self.safeRange(tok.span);
                try self.emitLeaf(kind, range);
                if (!allow_doc_comment) {
                    if (kind == .doc_comment) {
                        if (dangling_doc_start == null) {
                            dangling_doc_start = range.start;
                        }
                        dangling_doc_end = range.end;
                    } else if (dangling_doc_start) |s| {
                        try self.emitErrorAt(.dangling_doc_comment, .{
                            .start = self.globalPos(s),
                            .end = self.globalPos(dangling_doc_end),
                        });
                        dangling_doc_start = null;
                    }
                }
                self.cursor += 1;
            } else if (include_nl and tok.tag == .nl) {
                try self.emitLeaf(.newline, self.safeRange(tok.span));
                self.cursor += 1;
            } else {
                break;
            }
        }

        if (dangling_doc_start) |s| {
            try self.emitErrorAt(.dangling_doc_comment, .{
                .start = self.globalPos(s),
                .end = self.globalPos(dangling_doc_end),
            });
        }

        if (emit_pending_ws) {
            try self.emitPendingWhitespace();
        }
    }

    /// 消费并向事件流发射当前游标处连续的 Trivia（注释；当 `include_nl` 为真时含换行）。
    pub inline fn emitTrivia(self: *Parser, include_nl: bool, allow_doc_comment: bool) std.mem.Allocator.Error!void {
        try self.emitTriviaInternal(include_nl, allow_doc_comment, false);
    }

    /// 在已开启的语法节点开头发射全部前导 Trivia（注释、换行与紧接其后的水平空白）。
    pub inline fn emitLeadingTrivia(self: *Parser, allow_doc_comment: bool) std.mem.Allocator.Error!void {
        try self.emitTriviaInternal(true, allow_doc_comment, true);
    }

    /// 若当前前导 Trivia 序列中存在文档注释，则在当前声明节点层发射至最后一个文档注释为止，
    /// 使文档注释成为声明对象的直接成员且保留其后换行与空白作为下一子节点的 leading trivia。
    pub fn emitPendingDocComments(self: *Parser) std.mem.Allocator.Error!void {
        var idx = self.cursor;
        var last_doc_idx: ?usize = null;
        while (idx < self.tokens.len) : (idx += 1) {
            const tok = self.tokens[idx];
            if (tok.tag == .comment) {
                if (self.classifyComment(tok) == .doc_comment) {
                    last_doc_idx = idx;
                }
            } else if (tok.tag == .nl) {
                continue;
            } else {
                break;
            }
        }
        const stop_idx = last_doc_idx orelse return;
        while (self.cursor <= stop_idx) {
            const tok = self.tokens[self.cursor];
            if (tok.tag == .comment) {
                try self.emitLeaf(self.classifyComment(tok), self.safeRange(tok.span));
            } else if (tok.tag == .nl) {
                try self.emitLeaf(.newline, self.safeRange(tok.span));
            }
            self.cursor += 1;
        }
    }

    /// 内部公共词法消费：先发射前导 Trivia，再发射当前词法单元（可选覆盖标签）。
    fn bumpInternal(
        self: *Parser,
        skip_nl: bool,
        allow_doc_comment: bool,
        kind_override: ?SyntaxKind,
    ) std.mem.Allocator.Error!void {
        try self.emitTrivia(skip_nl, allow_doc_comment);
        if (self.cursor >= self.tokens.len) return;
        const tok = self.tokens[self.cursor];
        if (tok.tag == .end) return;
        const kind = kind_override orelse self.tokenToSyntaxKind(tok);
        try self.emitLeaf(kind, self.safeRange(tok.span));
        self.cursor += 1;
    }

    /// 消费下一个非 Trivia 词法单元，发射其前导 Trivia 并按默认映射为 `SyntaxKind` 发射叶子。
    pub inline fn bump(self: *Parser) std.mem.Allocator.Error!void {
        try self.bumpInternal(true, false, null);
    }

    /// 消费下一个非 Trivia 词法单元且允许前导存在文档注释（用于 `quote` 与宏原始词法片段）。
    pub inline fn bumpAllowDoc(self: *Parser) std.mem.Allocator.Error!void {
        try self.bumpInternal(true, true, null);
    }

    /// 消费下一个非 Trivia 词法单元并覆盖发射的 `SyntaxKind`（如将上下文关键字发射为 `.identifier`）。
    pub inline fn bumpAs(self: *Parser, kind: SyntaxKind) std.mem.Allocator.Error!void {
        try self.bumpInternal(true, false, kind);
    }

    /// 消费同行下一个非注释词法单元（不跳过换行），按默认映射发射。
    pub inline fn bumpNoNl(self: *Parser) std.mem.Allocator.Error!void {
        try self.bumpInternal(false, false, null);
    }

    /// 消费当前位置处的组合运算符（如 `??`、`>>`、`>>=`、`>=`），合并为单个 `TokenEvent` 发射。
    pub inline fn bumpCombined(self: *Parser, op: CombinedOp, skip_nl: bool) std.mem.Allocator.Error!void {
        try self.bumpCombinedInternal(op, skip_nl, false);
    }

    /// 消费组合运算符且允许前导存在文档注释（用于 `quote` 与宏原始词法片段）。
    pub inline fn bumpCombinedAllowDoc(self: *Parser, op: CombinedOp, skip_nl: bool) std.mem.Allocator.Error!void {
        try self.bumpCombinedInternal(op, skip_nl, true);
    }

    /// 内部组合运算符消费实现。
    fn bumpCombinedInternal(
        self: *Parser,
        op: CombinedOp,
        skip_nl: bool,
        allow_doc_comment: bool,
    ) std.mem.Allocator.Error!void {
        try self.emitTrivia(skip_nl, allow_doc_comment);
        const count: usize = op.token_count;
        if (count == 0 or self.cursor >= self.tokens.len or self.tokens.len - self.cursor < count) return;
        const first = self.safeRange(self.tokens[self.cursor].span);
        const last = self.safeRange(self.tokens[self.cursor + count - 1].span);
        const merged: common.TextRange = .{
            .start = first.start,
            .end = @max(first.start, last.end),
        };
        try self.emitLeaf(op.kind, merged);
        self.cursor += count;
    }

    /// 若当前有效词法单元匹配 `tag` 则消费并返回 `true`，否则不消费并返回 `false`。
    pub fn eat(self: *Parser, tag: TokenTag) std.mem.Allocator.Error!bool {
        if (self.peek() == tag) {
            try self.bump();
            return true;
        }
        return false;
    }

    /// 期望当前有效词法单元为 `tag`；匹配则消费并返回 `true`，不匹配则记录 `expected_token` 错误并返回 `false`。
    pub fn expect(self: *Parser, tag: TokenTag) std.mem.Allocator.Error!bool {
        if (self.peek() == tag) {
            try self.bump();
            return true;
        }
        try self.emitError(.expected_token);
        return false;
    }

    /// 期望当前有效词法单元为闭合定界符（`)`、`]`、`}`）；不匹配时记录 `unclosed_delimiter` 错误。
    pub fn expectClosing(self: *Parser, tag: TokenTag) std.mem.Allocator.Error!bool {
        if (self.peek() == tag) {
            try self.bump();
            return true;
        }
        try self.emitError(.unclosed_delimiter);
        return false;
    }

    /// 消费一个标识符或上下文关键字并统一发射为 `SyntaxKind.identifier`；不匹配时记录 `expected_identifier`。
    pub fn expectIdent(self: *Parser) std.mem.Allocator.Error!bool {
        if (isIdentLike(self.peek())) {
            try self.bumpAs(.identifier);
            return true;
        }
        try self.emitError(.expected_identifier);
        return false;
    }

    /// 消费一个包名段（标识符、上下文关键字或反引号包名）；不匹配时记录 `expected_identifier`。
    pub fn expectPackageIdent(self: *Parser) std.mem.Allocator.Error!bool {
        const tag = self.peek();
        if (tag == .package_identifier) {
            try self.bump();
            return true;
        }
        if (isIdentLike(tag)) {
            try self.bumpAs(.identifier);
            return true;
        }
        try self.emitError(.expected_identifier);
        return false;
    }

    /// 消费一个无法识别的词法单元并包裹在 `error_node` 内，记录对应错误码以维持无损与游标前进。
    pub fn bumpErrorToken(self: *Parser, code: ParseErrorCode) std.mem.Allocator.Error!void {
        const sig_idx = self.nextSignificantIndex(self.cursor, true);
        if (sig_idx >= self.tokens.len) return;
        const tok = self.tokens[sig_idx];
        if (tok.tag == .end) return;

        const actual_code: ParseErrorCode = if (tok.tag == .illegal) .illegal_token else code;
        try self.emitError(actual_code);
        try self.startNode(.error_node);
        try self.emitLeadingTrivia(false);
        if (self.cursor < self.tokens.len and self.tokens[self.cursor].tag != .end) {
            const cur = self.tokens[self.cursor];
            try self.emitLeaf(self.tokenToSyntaxKind(cur), self.safeRange(cur.span));
            self.cursor += 1;
        }
        try self.finishNode();
    }

    /// 最小范围合并消费连续的同行非法或多余闭定界符词法单元到单个 `error_node`，
    /// 遇换行、分号、花括号、声明起始或合法表达式起始立即停止，兼顾最少 Token 消耗与抑制错误风暴。
    /// 当 `code` 为 `null` 时表示错误已由前序解析步骤记录，不再重复发射诊断。
    pub fn bumpErrorRun(self: *Parser, code: ?ParseErrorCode, stop_at_r_curl: bool) std.mem.Allocator.Error!void {
        const sig_idx = self.nextSignificantIndex(self.cursor, true);
        if (sig_idx >= self.tokens.len) return;
        const first = self.tokens[sig_idx];
        if (first.tag == .end) return;

        if (code) |err_code| {
            const actual_code: ParseErrorCode = if (first.tag == .illegal) .illegal_token else err_code;
            try self.emitError(actual_code);
        }
        try self.startNode(.error_node);
        try self.emitLeadingTrivia(false);
        if (self.cursor < self.tokens.len and self.tokens[self.cursor].tag != .end) {
            const cur = self.tokens[self.cursor];
            try self.emitLeaf(self.tokenToSyntaxKind(cur), self.safeRange(cur.span));
            self.cursor += 1;
        }

        // 仅在同行内继续合并连续的 `.illegal` 或孤立冗余闭合符 `)` / `]`
        while (self.cursor < self.tokens.len) {
            const next_no_nl = self.peekNoNl();
            if (next_no_nl == .end or next_no_nl == .nl or next_no_nl == .semi or next_no_nl == .l_curl) break;
            if (stop_at_r_curl and next_no_nl == .r_curl) break;
            if (next_no_nl != .illegal and next_no_nl != .r_paren and next_no_nl != .r_square) break;
            try self.bumpNoNl();
        }
        try self.finishNode();
    }

    /// 仅消费显式分号分隔符 `;`（不提前消费换行与注释，将其保留为后续节点的 leading trivia）。
    pub fn eatSemicolons(self: *Parser) std.mem.Allocator.Error!bool {
        var consumed = false;
        while (self.at(.semi)) {
            try self.bump();
            consumed = true;
        }
        return consumed;
    }

    /// 判定标签是否为明确不可作为列表元素的顶层或成员声明关键字。
    pub inline fn isHardDeclKeyword(tag: TokenTag) bool {
        return switch (tag) {
            .kw_func,
            .kw_class,
            .kw_struct,
            .kw_interface,
            .kw_enum,
            .kw_extend,
            .kw_foreign,
            .kw_import,
            .kw_package,
            .kw_main,
            .kw_macro,
            .kw_prop,
            .kw_type,
            => true,
            else => false,
        };
    }

    /// 只读判断当前位置是否跨行到达了一条新声明的明确起始边界（用于 LSP 编辑态防止前一行未写完的表达式/类型/点号吞并下一行声明）。
    pub fn isNewlineDeclBoundary(self: *const Parser) bool {
        if (!self.hasNewlineBefore()) return false;
        const idx = self.nextSignificantIndex(self.cursor, true);
        if (idx >= self.tokens.len) return false;
        const tag = self.tokens[idx].tag;
        if (isHardDeclKeyword(tag)) return true;
        switch (tag) {
            .kw_let, .kw_var, .kw_const, .kw_init => return true,
            .bit_not => {
                const next = self.nextSignificantIndex(idx + 1, true);
                return next < self.tokens.len and self.tokens[next].tag == .kw_init;
            },
            .at, .at_excl => return decl.isAnnotationFollowedByDeclAt(self, idx),
            else => return decl.isModifierFollowedByDeclAt(self, idx),
        }
    }

    /// 只读判断当前位置是否为主构造器成员参数起始（`[public|private|protected|internal] (let | var)`）。
    pub fn isPrimaryCtorMemberParamStart(self: *const Parser) bool {
        const t0 = self.peek();
        if (t0 == .kw_let or t0 == .kw_var) return true;
        if (t0 == .kw_public or t0 == .kw_private or t0 == .kw_protected or t0 == .kw_internal) {
            const t1 = self.peekNth(1);
            return t1 == .kw_let or t1 == .kw_var;
        }
        return false;
    }

    /// 判定当前词法位置是否命中指定列表上下文的外层同步恢复边界；命中时列表应立即停止而不吞并外层词法单元。
    pub fn shouldStopList(self: *const Parser, ctx: ListContext) bool {
        const tag = self.peek();
        if (tag == .end or isHardDeclKeyword(tag)) return true;
        if (ctx == .primary_ctor_param_list) {
            if (self.isNewlineDeclBoundary() and !self.isPrimaryCtorMemberParamStart()) return true;
        } else if (self.isNewlineDeclBoundary()) {
            return true;
        }

        return switch (ctx) {
            .paren_expr_list => switch (tag) {
                .r_paren, .r_curl, .r_square, .semi, .kw_let, .kw_var, .kw_const => true,
                else => false,
            },
            .square_expr_list => switch (tag) {
                .r_square, .r_curl, .r_paren, .semi, .kw_let, .kw_var, .kw_const => true,
                else => false,
            },
            .func_param_list, .primary_ctor_param_list => switch (tag) {
                .r_paren, .l_curl, .r_curl, .r_square, .semi, .kw_where => true,
                else => false,
            },
            .type_param_list => switch (tag) {
                .greater, .l_curl, .r_curl, .l_paren, .r_paren, .l_square, .r_square, .upperbound, .kw_where, .assign, .semi => true,
                else => false,
            },
            .type_arg_list => switch (tag) {
                .greater, .l_curl, .r_curl, .r_paren, .r_square, .assign, .semi => true,
                else => false,
            },
            .paren_type_list => switch (tag) {
                .r_paren, .l_curl, .r_curl, .r_square, .assign, .semi, .arrow => true,
                else => false,
            },
            .pattern_list => switch (tag) {
                .r_paren, .l_curl, .r_curl, .r_square, .double_arrow, .backarrow, .assign, .semi, .kw_in, .kw_where => true,
                else => false,
            },
            .brace_list => switch (tag) {
                .r_curl, .semi => true,
                else => false,
            },
        };
    }

    /// 只读判断当前词法单元是否可以合法起始一条常规表达式（用于逗号分隔列表的漏逗号恢复判定）。
    pub fn canStartExpr(self: *const Parser) bool {
        if (self.isNewlineDeclBoundary()) return false;
        const tag = self.peek();
        return switch (tag) {
            .integer_literal,
            .float_literal,
            .rune_literal,
            .rune_byte_literal,
            .bool_literal,
            .string_literal,
            .multiline_string,
            .multiline_raw_string,
            .wildcard,
            .l_paren,
            .l_square,
            .l_curl,
            .sub,
            .not,
            .kw_if,
            .kw_match,
            .kw_while,
            .kw_do,
            .kw_for,
            .kw_try,
            .kw_throw,
            .kw_return,
            .kw_break,
            .kw_continue,
            .kw_spawn,
            .kw_synchronized,
            .kw_unsafe,
            .kw_quote,
            .kw_perform,
            .kw_resume,
            .kw_varray,
            .kw_this,
            .kw_super,
            .kw_this_type,
            .kw_inout,
            .at,
            => true,
            else => isPrimitiveTypeTag(tag) or isIdentLike(tag),
        };
    }

    /// 只读判断当前词法单元是否可以合法起始一个模式（用于模式列表的漏逗号恢复判定）。
    pub fn canStartPattern(self: *const Parser) bool {
        if (self.isNewlineDeclBoundary()) return false;
        const tag = self.peek();
        return switch (tag) {
            .wildcard,
            .l_paren,
            .integer_literal,
            .float_literal,
            .rune_literal,
            .rune_byte_literal,
            .bool_literal,
            .string_literal,
            .multiline_string,
            .multiline_raw_string,
            => true,
            .sub => blk: {
                const next = self.peekNth(1);
                break :blk next == .integer_literal or next == .float_literal;
            },
            else => isIdentLike(tag),
        };
    }

    /// 判定当前是否位于文件尾（跳过注释与换行后为 `.end`）。
    pub inline fn isAtEof(self: *const Parser) bool {
        return self.peek() == .end;
    }

    /// 判定当前游标处（不跳过换行）是否位于语句终止位置（换行、`;`、`}`、`)`、`]`、`eof`）。
    pub inline fn atStmtTerminator(self: *const Parser) bool {
        return switch (self.peekNoNl()) {
            .nl, .semi, .r_curl, .r_paren, .r_square, .end => true,
            else => false,
        };
    }

    /// 在文件结束时发射所有残余词法单元、文件末尾 Trivia（归属 `source_file`）与 `SyntaxKind.eof`。
    pub fn finishFile(self: *Parser) std.mem.Allocator.Error!void {
        while (self.cursor < self.tokens.len) {
            const sig_idx = self.nextSignificantIndex(self.cursor, true);
            if (sig_idx >= self.tokens.len or self.tokens[sig_idx].tag == .end) {
                try self.emitTrivia(true, false);
                if (self.cursor < self.tokens.len and self.tokens[self.cursor].tag == .end) {
                    self.cursor += 1;
                }
                break;
            }
            try self.bumpErrorToken(.unexpected_token);
        }
        try self.emitTrailingWhitespace();
        try self.events.append(self.allocator, .{
            .token = .{
                .kind = .eof,
                .range = .{
                    .start = self.globalPos(self.emitted_pos),
                    .end = self.globalPos(self.emitted_pos),
                },
            },
        });
    }
};

/// 对外导出的语法解析器类型别名，指向 `Parser`。
pub const t = Parser;

// ---------------- 测试辅助与单元测试 ----------------

/// 测试用模拟树节点，用于验证事件流的开闭平衡、`wrap_node` 语义及字节无损覆盖。
const TestNode = struct {
    kind: SyntaxKind,
    children: std.ArrayList(TestChild) = .empty,

    /// 递归释放测试节点树占用的内存。
    fn deinit(self: *TestNode, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            switch (child.*) {
                .node => |*n| n.deinit(allocator),
                .token => {},
            }
        }
        self.children.deinit(allocator);
    }

    /// 判断整棵子树内是否包含指定标签的内部节点或叶子节点。
    fn hasKind(self: *const TestNode, target: SyntaxKind) bool {
        if (self.kind == target) return true;
        for (self.children.items) |*child| {
            switch (child.*) {
                .node => |*n| if (n.hasKind(target)) return true,
                .token => |tok| if (tok.kind == target) return true,
            }
        }
        return false;
    }

    /// 统计子树内指定标签的内部节点数量。
    fn countKind(self: *const TestNode, target: SyntaxKind) usize {
        var total: usize = if (self.kind == target) 1 else 0;
        for (self.children.items) |*child| {
            switch (child.*) {
                .node => |*n| total += n.countKind(target),
                .token => {},
            }
        }
        return total;
    }

    /// 深度优先查找子树内第一个匹配指定标签的内部节点指针。
    ///
    /// 返回的指针借用自 `self` 树内部节点，调用者不可释放，生命周期不超过 `self`。
    fn findFirst(self: *const TestNode, target: SyntaxKind) ?*const TestNode {
        if (self.kind == target) return self;
        for (self.children.items) |*child| {
            switch (child.*) {
                .node => |*n| if (n.findFirst(target)) |found| return found,
                .token => {},
            }
        }
        return null;
    }

    /// 返回当前节点的第 `nth`（从 0 起）个内部子节点指针（忽略叶子）。
    ///
    /// 返回的指针借用自 `self` 树内部节点，调用者不可释放，生命周期不超过 `self`。
    fn nthChildNode(self: *const TestNode, nth: usize) ?*const TestNode {
        var idx: usize = 0;
        for (self.children.items) |*child| {
            switch (child.*) {
                .node => |*n| {
                    if (idx == nth) return n;
                    idx += 1;
                },
                .token => {},
            }
        }
        return null;
    }

    /// 返回当前节点中第一个非空白、非注释、非换行的直接叶子标签。
    fn firstDirectOperator(self: *const TestNode) ?SyntaxKind {
        for (self.children.items) |*child| {
            switch (child.*) {
                .node => {},
                .token => |tok| switch (tok.kind) {
                    .whitespace, .newline, .line_comment, .block_comment, .doc_comment => continue,
                    else => return tok.kind,
                },
            }
        }
        return null;
    }

    /// 将所有叶子字节切片按顺序还原为完整源码文本。
    ///
    /// 返回切片由 `allocator` 分配，调用者负责释放。
    fn reconstruct(self: *const TestNode, allocator: std.mem.Allocator, source: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try self.reconstructInto(allocator, source, &out);
        return out.toOwnedSlice(allocator);
    }

    /// 递归追加叶子字节到输出缓冲。
    fn reconstructInto(
        self: *const TestNode,
        allocator: std.mem.Allocator,
        source: []const u8,
        out: *std.ArrayList(u8),
    ) !void {
        for (self.children.items) |*child| {
            switch (child.*) {
                .node => |*n| try n.reconstructInto(allocator, source, out),
                .token => |tok| {
                    if (tok.kind == .eof) continue;
                    try out.appendSlice(allocator, source[tok.range.start..tok.range.end]);
                },
            }
        }
    }
};

const TestChild = union(enum) {
    node: TestNode,
    token: TokenEvent,
};

const ParseTestResult = struct {
    root: TestNode,
    errors: std.ArrayList(ParseError),

    /// 释放解析测试结果内存。
    fn deinit(self: *ParseTestResult, allocator: std.mem.Allocator) void {
        self.root.deinit(allocator);
        self.errors.deinit(allocator);
    }
};

/// 词法分析并运行 `Parser.gen()`，模拟 `GreenBuilder` 消费全部事件，强制校验：
/// 1. `start_node`/`wrap_node` 与 `finish_node` 严格成对平衡；
/// 2. 全部叶子区间单调不重叠且无损还原原源码文本。
fn parseAndVerify(allocator: std.mem.Allocator, source: []const u8) !ParseTestResult {
    var tok_list: std.ArrayList(common.Token) = .empty;
    defer tok_list.deinit(allocator);

    var lex = try lexer.Lexer.new(source);
    while (true) {
        const tok = try lex.gen();
        try tok_list.append(allocator, tok);
        if (tok.tag == .end) break;
    }

    return parseTokensAndVerify(allocator, source, tok_list.items, true);
}

/// 使用外部提供的词法切片驱动 `Parser.gen()` 并验证事件流平衡、叶子区间单调性与无损还原。
fn parseTokensAndVerify(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const common.Token,
    check_lossless: bool,
) !ParseTestResult {
    var parser = Parser.new(allocator, source, tokens);
    defer parser.deinit();

    var frames: std.ArrayList(TestNode) = .empty;
    defer {
        for (frames.items) |*f| f.deinit(allocator);
        frames.deinit(allocator);
    }

    var errors: std.ArrayList(ParseError) = .empty;
    errdefer errors.deinit(allocator);

    var root_opt: ?TestNode = null;
    errdefer if (root_opt) |*r| r.deinit(allocator);

    var prev_end: u32 = 0;

    while (try parser.gen()) |ev| {
        switch (ev) {
            .start_node => |kind| {
                try frames.append(allocator, .{ .kind = kind });
            },
            .wrap_node => |kind| {
                try std.testing.expect(frames.items.len > 0);
                var parent = &frames.items[frames.items.len - 1];
                try std.testing.expect(parent.children.items.len > 0);
                const last_child = parent.children.pop().?;
                var wrapped: TestNode = .{ .kind = kind };
                errdefer wrapped.deinit(allocator);
                try wrapped.children.append(allocator, last_child);
                try frames.append(allocator, wrapped);
            },
            .token => |tok| {
                try std.testing.expect(frames.items.len > 0);
                try std.testing.expect(tok.range.start <= tok.range.end);
                try std.testing.expect(tok.range.start >= prev_end);
                prev_end = tok.range.end;
                var current = &frames.items[frames.items.len - 1];
                try current.children.append(allocator, .{ .token = tok });
            },
            .finish_node => {
                try std.testing.expect(frames.items.len > 0);
                const finished = frames.pop().?;
                if (frames.items.len == 0) {
                    try std.testing.expect(root_opt == null);
                    root_opt = finished;
                } else {
                    var parent = &frames.items[frames.items.len - 1];
                    try parent.children.append(allocator, .{ .node = finished });
                }
            },
            .parse_error => |err_item| {
                try errors.append(allocator, err_item);
            },
        }
    }

    try std.testing.expectEqual(@as(usize, 0), frames.items.len);
    try std.testing.expect(root_opt != null);
    try std.testing.expectEqualSlices(ParseError, parser.errors.items, errors.items);
    var root = root_opt.?;

    if (check_lossless) {
        const rebuilt = try root.reconstruct(allocator, source);
        defer allocator.free(rebuilt);
        try std.testing.expectEqualStrings(source, rebuilt);
    }

    return .{ .root = root, .errors = errors };
}

test "源文件头部特性、包声明与多种导入无损解析" {
    const gpa = std.testing.allocator;
    const src =
        \\features { os.linux, net.tls }
        \\public macro package org::a.b.`c-d`
        \\import std.core.*
        \\public import org::pkg.{Foo, Bar as Baz, sub.*}
        \\@When[os == "Linux"]
        \\import extra.mod as M
        \\
    ;
    var res = try parseAndVerify(gpa, src);
    defer res.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
    try std.testing.expect(res.root.hasKind(.features_directive));
    try std.testing.expect(res.root.hasKind(.features_set));
    try std.testing.expect(res.root.hasKind(.feature_id));
    try std.testing.expect(res.root.hasKind(.package_header));
    try std.testing.expect(res.root.hasKind(.package_name));
    try std.testing.expectEqual(@as(usize, 3), res.root.countKind(.import_spec));
    try std.testing.expect(res.root.hasKind(.annotation));
}

test "类、接口、结构体、枚举、扩展、属性、主构造器与析构器解析" {
    const gpa = std.testing.allocator;
    const src =
        \\public sealed interface Drawable<T> <: Base & Named where T <: Hashable {
        \\    func draw(): Unit
        \\    mut prop size: Int64
        \\}
        \\public open class Box<T> <: Drawable<T> {
        \\    static init() { let x = 1 }
        \\    public const Box(public let value: T, var tag!: Int64 = 0) {
        \\        super()
        \\    }
        \\    public init(v: T) {
        \\        this(v)
        \\    }
        \\    ~init() {}
        \\    public mut prop size: Int64 {
        \\        get() { 1 }
        \\        set(v) { _ = v }
        \\    }
        \\    public operator func ()(x: Int64): Int64 { x }
        \\    public operator func >>(n: Int64): Int64 { n }
        \\}
        \\struct Point {
        \\    Point(let x: Int64, let y: Int64) {}
        \\}
        \\enum Color {
        \\    | Red
        \\    | Rgb(UInt8, UInt8, UInt8)
        \\    | ...
        \\    public func isRed(): Bool { true }
        \\}
        \\extend<T> Box<T> <: Equatable<Box<T>> where T <: Equatable<T> {
        \\    public operator func ==(other: Box<T>): Bool { true }
        \\}
        \\extend Int64 <: Drawable<Int64> {
        \\    public func draw(): Unit {}
        \\}
        \\foreign {
        \\    @FastNative
        \\    func printf(fmt: CString, ...): Int32
        \\}
        \\type MyBox<T> = Box<T>
        \\public macro Echo(attr: Tokens, input: Tokens): Tokens {
        \\    quote($attr + $input)
        \\}
        \\main(args: Array<String>): Int64 { 0 }
        \\
    ;
    var res = try parseAndVerify(gpa, src);
    defer res.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
    try std.testing.expect(res.root.hasKind(.interface_decl));
    try std.testing.expect(res.root.hasKind(.class_decl));
    try std.testing.expect(res.root.hasKind(.primary_ctor_decl));
    try std.testing.expect(res.root.hasKind(.init_decl));
    try std.testing.expect(res.root.hasKind(.finalizer_decl));
    try std.testing.expect(res.root.hasKind(.prop_decl));
    try std.testing.expect(res.root.hasKind(.prop_getter));
    try std.testing.expect(res.root.hasKind(.prop_setter));
    try std.testing.expect(res.root.hasKind(.struct_decl));
    try std.testing.expect(res.root.hasKind(.enum_decl));
    try std.testing.expect(res.root.hasKind(.enum_constructor));
    try std.testing.expect(res.root.hasKind(.extend_decl));
    try std.testing.expect(res.root.hasKind(.foreign_decl));
    try std.testing.expect(res.root.hasKind(.foreign_block));
    try std.testing.expect(res.root.hasKind(.type_alias_decl));
    try std.testing.expect(res.root.hasKind(.macro_decl));
    try std.testing.expect(res.root.hasKind(.main_decl));
    try std.testing.expect(res.root.hasKind(.rshift));
}

test "类型系统、嵌套可空、嵌套泛型与 VArray 消歧" {
    const gpa = std.testing.allocator;
    const src =
        \\let a: ??Int64 = None
        \\let b: Array<Array<Map<String, Int64>>> = []
        \\let c: (Int64) = 1
        \\let d: (x: Int64, y: String) = (1, "a")
        \\let e: (Int64, String) -> Unit = { x, y => () }
        \\let f: () -> VArray<Int64, $8> = { => VArray<Int64, $8>(repeat: 0) }
        \\let g: Int64 = foo<Array<Int64>>(1)
        \\let h: Bool = a < b && c > d
        \\let i: Int64 = arr<Int64>[0]
        \\let j: Int64 = val<Int64> + 1
        \\let k: (Bool, Bool) = (a < b, c >= 0)
        \\
    ;
    var res = try parseAndVerify(gpa, src);
    defer res.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), res.root.countKind(.option_type));
    try std.testing.expect(!res.root.hasKind(.coalescing));
    try std.testing.expect(!res.root.hasKind(.rshift));
    try std.testing.expect(res.root.hasKind(.paren_type));
    try std.testing.expect(res.root.hasKind(.tuple_type));
    try std.testing.expect(res.root.hasKind(.func_type));
    try std.testing.expect(res.root.hasKind(.varray_type));
    try std.testing.expect(res.root.hasKind(.constant_type));
    try std.testing.expect(res.root.hasKind(.varray_expr));
    try std.testing.expect(res.root.hasKind(.greater_equal));
    try std.testing.expect(!res.root.hasKind(.assign_expr));
}

test "表达式优先级、非结合比较与赋值、可选链与路径平铺" {
    const gpa = std.testing.allocator;
    const src =
        \\func demo() {
        \\    let r1 = a /* keep */ + b * c ** d ** e
        \\    let r2 = x < y == true & flag | mask
        \\    let r3 = 0..10:2
        \\    let r3b = 0..5 == 0..5
        \\    let r3c = 1..10 is Range<Int64>
        \\    let r4 = a ?? b ?? c |> f ~> g
        \\    let r5 = obj.a.b?.c
        \\    let r6 = getObj()?.field.next?(1)?[0]?{ x => x }
        \\    let r7 = arr[..5]
        \\    let r8 = arr[1..]
        \\    let r9 = arr[..]
        \\    let r9b = arr[0, ..5]
        \\    let r10 = [1, *other, 2]
        \\    let r11 = Int64(3.14)
        \\    let r12 = Rune(65)
        \\    let r13 = x is ?Int64
        \\    let r14 = x as Box<Int64>
        \\    let r15 = This.create()
        \\    (a, _) = (1, 2)
        \\    x >>= 2
        \\    x++
        \\    a
        \\    (b, c) = (1, 2)
        \\}
        \\
    ;
    var res = try parseAndVerify(gpa, src);
    defer res.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
    try std.testing.expect(res.root.hasKind(.block_comment));
    try std.testing.expect(res.root.hasKind(.range_expr));
    try std.testing.expect(res.root.hasKind(.coalescing));
    try std.testing.expect(res.root.hasKind(.rshift_assign));
    try std.testing.expect(res.root.hasKind(.inc_or_dec_expr));
    try std.testing.expect(res.root.hasKind(.type_conv_expr));
    try std.testing.expect(res.root.hasKind(.is_expr));
    try std.testing.expect(res.root.hasKind(.as_expr));
    try std.testing.expect(res.root.hasKind(.optional_expr));
    try std.testing.expect(res.root.hasKind(.trailing_closure_expr));
    try std.testing.expect(res.root.hasKind(.assign_expr));
}

test "非结合比较、非结合赋值、非结合区间与非法后缀自增报告预期错误" {
    const gpa = std.testing.allocator;

    const cases = [_]struct { src: []const u8, code: ParseErrorCode }{
        .{ .src = "func f() { let x = a < b < c }", .code = .non_associative_comparison },
        .{ .src = "func f() { let x = a == b == c }", .code = .non_associative_comparison },
        .{ .src = "func f() { a = b = 0 }", .code = .non_associative_assignment },
        .{ .src = "func f() { a++-- }", .code = .non_associative_operator },
        .{ .src = "func f() { 1..2..3 }", .code = .non_associative_operator },
    };
    for (cases) |c| {
        var res = try parseAndVerify(gpa, c.src);
        defer res.deinit(gpa);
        try std.testing.expect(res.errors.items.len >= 1);
        try std.testing.expectEqual(c.code, res.errors.items[0].code);
    }
}

test "控制流、模式匹配、异常与代数效应、并发与条件表达式边界" {
    const gpa = std.testing.allocator;
    const src =
        \\func flow(opt: ?Int64, optBool: ?Bool, public: Int64) {
        \\    if (optBool ?? false) {
        \\        let x = public
        \\    }
        \\    if (x |> isValid) {
        \\        let y = 1
        \\    }
        \\    if (({ => let tmp = 1; tmp })() == 1) {
        \\        let z = 1
        \\    }
        \\    if (Int64(f { 1 }) > 0) {
        \\        let w = 1
        \\    }
        \\    if (let Some(v) <- opt && v > 0) {
        \\        let x = public + v
        \\    } else {
        \\        return
        \\    }
        \\    while (let Some(n) <- opt) {
        \\        break
        \\    }
        \\    do {
        \\        continue
        \\    } while (false)
        \\    for ((k, v) in items where k > 0) {
        \\        _ = v
        \\    }
        \\    match (opt) {
        \\        case Some(1) | Some(-2) where true =>
        \\            let a = 1
        \\            a + 1
        \\        case Option
        \\        <Int64>.Some(x) => x
        \\        case () => return
        \\        case x: Int64 => x
        \\        case _ => 0
        \\    }
        \\    match {
        \\        case true => 1
        \\        case _ => 2
        \\    }
        \\    try (f: File = open(), g = open()) {
        \\        let r = perform Ask(1)
        \\        unsafe { _ = r }
        \\    } catch (e: IOError | NetError) {
        \\        throw e
        \\    } handle (cmd: Ask) {
        \\        resume cmd with 42
        \\        resume cmd throwing err
        \\    } finally {
        \\        spawn {
        \\            synchronized (mtx) { () }
        \\        }
        \\    }
        \\}
        \\
    ;
    var res = try parseAndVerify(gpa, src);
    defer res.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
    try std.testing.expect(res.root.hasKind(.if_expr));
    try std.testing.expect(res.root.hasKind(.let_pattern_destructor));
    try std.testing.expect(res.root.hasKind(.while_expr));
    try std.testing.expect(res.root.hasKind(.do_while_expr));
    try std.testing.expect(res.root.hasKind(.for_in_expr));
    try std.testing.expect(res.root.hasKind(.match_expr));
    try std.testing.expect(res.root.hasKind(.match_case));
    try std.testing.expect(res.root.hasKind(.match_case_other));
    try std.testing.expect(res.root.hasKind(.pattern_guard));
    try std.testing.expect(res.root.hasKind(.const_pattern));
    try std.testing.expect(res.root.hasKind(.unit_literal));
    try std.testing.expect(res.root.hasKind(.try_expr));
    try std.testing.expect(res.root.hasKind(.resource_spec));
    try std.testing.expect(res.root.hasKind(.catch_clause));
    try std.testing.expect(res.root.hasKind(.except_type_pattern));
    try std.testing.expect(res.root.hasKind(.handle_clause));
    try std.testing.expect(res.root.hasKind(.command_type_pattern));
    try std.testing.expect(res.root.hasKind(.finally_clause));
    try std.testing.expect(res.root.hasKind(.perform_expr));
    try std.testing.expect(res.root.hasKind(.resume_expr));
    try std.testing.expect(res.root.hasKind(.spawn_expr));
    try std.testing.expect(res.root.hasKind(.synchronized_expr));
    try std.testing.expect(res.root.hasKind(.unsafe_expr));
}

test "quote 表达式：转义、插值边界、token_part 干净切分与错误校验" {
    const gpa = std.testing.allocator;
    const src =
        \\func testQuote() {
        \\    let q1 = quote(2 + $x + $(y + 1))
        \\    let q2 = quote(\( \) \$ \@ \$x \$(a + b))
        \\    let q3 = quote(quote(x))
        \\    let q4 = quote($(quote($t)))
        \\    let q5 = quote(@PlusOne($x) + a >> b >= c ?? d)
        \\    let q6 = quote(
        \\        var a = 3
        \\        var b = 4
        \\    )
        \\}
        \\
    ;
    var res = try parseAndVerify(gpa, src);
    defer res.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
    try std.testing.expectEqual(@as(usize, 7), res.root.countKind(.quote_expr));
    try std.testing.expect(res.root.hasKind(.token_part));
    try std.testing.expect(res.root.hasKind(.quote_interpolation));
    try std.testing.expect(res.root.hasKind(.rshift));
    try std.testing.expect(res.root.hasKind(.greater_equal));
    try std.testing.expect(res.root.hasKind(.coalescing));

    // token_part 不吞入尾随注释与换行
    {
        const s = "let q = quote(a /* c */\n$x)";
        var r = try parseAndVerify(gpa, s);
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), r.errors.items.len);
        const tp = r.root.findFirst(.token_part).?;
        const tp_txt = try tp.reconstruct(gpa, s);
        defer gpa.free(tp_txt);
        try std.testing.expectEqualStrings("a", tp_txt);
        const qi = r.root.findFirst(.quote_interpolation).?;
        const qi_txt = try qi.reconstruct(gpa, s);
        defer gpa.free(qi_txt);
        try std.testing.expectEqualStrings(" /* c */\n$x", qi_txt);
    }

    // quote 语法错误边界（未转义孤立 $、不匹配括号、quote 后换行、非紧邻反斜杠）
    for ([_][]const u8{
        "let q = quote(1 + $ + 2)",
        "let q = quote(()",
        "let q = quote\n(1)",
        "let q = quote(\\ )",
    }) |bad_src| {
        var bad = try parseAndVerify(gpa, bad_src);
        defer bad.deinit(gpa);
        try std.testing.expect(bad.errors.items.len >= 1);
    }

    // 面向分析平台的宽松建树：空 quote() 与 $(...) 内任意表达式正常构建 CST
    for ([_][]const u8{
        "let q = quote()",
        "let q = quote($(return 1))",
        "let q = quote($(try {} finally {}))",
    }) |relaxed_src| {
        var r = try parseAndVerify(gpa, relaxed_src);
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), r.errors.items.len);
        try std.testing.expect(r.root.hasKind(.quote_expr));
    }

    // quote 后换行且缺少 `(` 只报一次错误
    {
        var bad = try parseAndVerify(gpa, "func f() { let q = quote\nfoo }");
        defer bad.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), bad.errors.items.len);
    }
}

test "宏调用、自定义注解、内置注解、参数宏、枚举构造器宏与 @IfAvailable" {
    const gpa = std.testing.allocator;
    const src =
        \\@Deprecated["old", strict: true]
        \\@!CustomAnno[key: "v"]
        \\@Outer[a + \[1\]]
        \\@Inner
        \\public class S {
        \\    func f(@ParamMacro x: Int64, @Deprecated["old"] @MyAnno y: Int64, @!ParamAnno[1] z: Int64) {
        \\        let a = @Twice(1 + \( + 2)
        \\        let b = @sourceLine()
        \\        let c = @M1 @M2(1)
        \\        let d = @M[\]](1 + 2) + 3
        \\        @M[\[] let e = 1
        \\        let g = @IfAvailable(arg: v, { => 1 }, { => 2 })
        \\    }
        \\}
        \\enum E {
        \\    | @MyAnno Red
        \\    | @Deprecated["old"] @MyMacro Green(Int64)
        \\    | Blue
        \\}
        \\
    ;
    var res = try parseAndVerify(gpa, src);
    defer res.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
    try std.testing.expect(res.root.hasKind(.annotation));
    try std.testing.expect(res.root.hasKind(.macro_expand_decl));
    try std.testing.expect(res.root.hasKind(.macro_expand_param));
    try std.testing.expect(res.root.hasKind(.macro_expand_expr));
    try std.testing.expect(res.root.hasKind(.macro_attributes));
    try std.testing.expect(res.root.hasKind(.macro_input));
    try std.testing.expect(res.root.hasKind(.if_available_expr));
    try std.testing.expectEqual(@as(usize, 3), res.root.countKind(.enum_constructor));
}

test "声明消歧：上下文关键字主构造器、const 消歧、块内上下文关键字与非法前置修饰符防自递归" {
    const gpa = std.testing.allocator;
    const src =
        \\const public = 1
        \\const open: Int64 = 2
        \\class open {
        \\    open() {}
        \\    const Box(x) = Box(1)
        \\    const common func helper(): Int64 { 0 }
        \\}
        \\struct common {
        \\    common(let x: Int64) {}
        \\}
        \\func locals() {
        \\    let open = 1
        \\    let public = 2
        \\    let common = 3
        \\    open
        \\    let x = public
        \\    public
        \\    func inner() {}
        \\    common
        \\    var y = 4
        \\}
        \\
    ;
    var res = try parseAndVerify(gpa, src);
    defer res.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), res.root.countKind(.primary_ctor_decl));

    // 面向分析平台宽松允许带前置修饰符的 foreign/main/~init，以及块内嵌套声明，不触发自递归或误报
    {
        const relaxed =
            \\public foreign func foo(): Unit
            \\public main() {
            \\    class LocalClass {
            \\        const X: Int64 = 1
            \\        func inner() { func nested() {} }
            \\    }
            \\    match (x) {}
            \\    try { 1 }
            \\}
            \\import std.{ a.{b} }
            \\import std.{}
            \\
        ;
        var r = try parseAndVerify(gpa, relaxed);
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), r.errors.items.len);
        try std.testing.expect(r.root.hasKind(.foreign_decl));
        try std.testing.expect(r.root.hasKind(.class_decl));
        try std.testing.expect(r.root.hasKind(.match_expr));
        try std.testing.expect(r.root.hasKind(.try_expr));
    }
}

test "单行与多行字符串插值展开、转义跳过与未闭合插值无损防御" {
    const gpa = std.testing.allocator;
    const src =
        \\let s1 = "hello ${name}, sum=${let t = 1; t + 2} \${escaped}"
        \\let s2 = """
        \\line1 ${a + b}
        \\line2 ${
        \\    let k = "inner ${c}"
        \\    k
        \\}
        \\"""
        \\let s3 = "plain string without interp"
        \\
    ;
    var res = try parseAndVerify(gpa, src);
    defer res.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
    try std.testing.expectEqual(@as(usize, 3), res.root.countKind(.str_interpolation_expr));
    try std.testing.expect(res.root.hasKind(.string_content));
    try std.testing.expect(res.root.hasKind(.interpolation_expr));
    try std.testing.expect(res.root.hasKind(.string_literal));

    // 外部传入畸形未闭合插值 .string_literal 保持严格无损不重复发射前段
    {
        const raw = "\"a${b\"";
        const toks = [_]common.Token{
            .{ .tag = .string_literal, .span = .{ .start = 0, .end = @intCast(raw.len) } },
            .{ .tag = .end, .span = .{ .start = @intCast(raw.len), .end = @intCast(raw.len) } },
        };
        var r = try parseTokensAndVerify(gpa, raw, &toks, true);
        defer r.deinit(gpa);
        try std.testing.expect(r.errors.items.len >= 1);
    }
}

test "wrap_node 安全性、极端递归、畸形 span、base_offset 饱和与 OOM 恢复" {
    const gpa = std.testing.allocator;

    // 缺失左操作数紧接中缀/后缀/条件运算符绝不触发 wrap_node 崩溃
    for ([_][]const u8{
        "func f() { + 1 }",
        "func f() { * 2 }",
        "func f() { .a }",
        "func f() { ++ }",
        "func f() { ?.(a) }",
        "func f() { ?(1) }",
        "func f() { ?[0] }",
        "func f() { ?{ 1 } }",
        "let x = + 1",
        "let x = ( + 1)",
        "func f() { a + * b }",
        "func f() { - ++ }",
        "func f() { if (&& a) {} }",
        "func f() { if (|| a) {} }",
        "func f() { if (a || && b) {} }",
        "let x: Array<> = []",
        "class A<> {}",
        "func f(x: (Foo<Int64), y: () -> Int64) {}",
    }) |bad_src| {
        var r = try parseAndVerify(gpa, bad_src);
        defer r.deinit(gpa);
        try std.testing.expect(r.errors.items.len >= 1);
    }

    // 空源码、仅空白无 tokens、乱序/越界 span 均保持单调无损不崩溃
    {
        var r1 = try parseTokensAndVerify(gpa, "", &.{}, true);
        defer r1.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), r1.errors.items.len);

        var r2 = try parseTokensAndVerify(gpa, "   \t ", &.{}, true);
        defer r2.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), r2.errors.items.len);

        const bad_tokens = [_]common.Token{
            .{ .tag = .kw_let, .span = .{ .start = 100, .end = 50 } },
            .{ .tag = .illegal, .span = .{ .start = 0, .end = 999 } },
        };
        var r3 = try parseTokensAndVerify(gpa, "abc", &bad_tokens, true);
        defer r3.deinit(gpa);
        try std.testing.expect(r3.errors.items.len >= 1);
    }

    // 无 .end 结尾的未闭合定界符正确报告 unclosed_delimiter
    {
        const raw = "quote(a";
        const toks = [_]common.Token{
            .{ .tag = .kw_quote, .span = .{ .start = 0, .end = 5 } },
            .{ .tag = .l_paren, .span = .{ .start = 5, .end = 6 } },
            .{ .tag = .identifier, .span = .{ .start = 6, .end = 7 } },
        };
        var r = try parseTokensAndVerify(gpa, raw, &toks, true);
        defer r.deinit(gpa);
        try std.testing.expect(r.errors.items.len >= 1);
    }

    // base_offset 极大时不触发 u32 溢出崩溃
    {
        const raw = "let x = 1";
        var tok_list: std.ArrayList(common.Token) = .empty;
        defer tok_list.deinit(gpa);
        var lex = try lexer.Lexer.new(raw);
        while (true) {
            const tok = try lex.gen();
            try tok_list.append(gpa, tok);
            if (tok.tag == .end) break;
        }
        var p = Parser.new(gpa, raw, tok_list.items);
        defer p.deinit();
        p.base_offset = std.math.maxInt(u32);
        while (try p.gen()) |_| {}
    }

    // 超深括号 + 尾随闭包、超长前缀负号、超长 else if 均安全触发 recursive_depth_limit 且不无限循环
    {
        var b1: std.ArrayList(u8) = .empty;
        defer b1.deinit(gpa);
        try b1.appendSlice(gpa, "let x = ");
        for (0..255) |_| try b1.append(gpa, '(');
        try b1.appendSlice(gpa, "a { 1 }");
        for (0..255) |_| try b1.append(gpa, ')');
        var r = try parseAndVerify(gpa, b1.items);
        defer r.deinit(gpa);
        try std.testing.expect(r.errors.items.len >= 1);
    }
    {
        var b2: std.ArrayList(u8) = .empty;
        defer b2.deinit(gpa);
        try b2.appendSlice(gpa, "let x = ");
        for (0..400) |_| try b2.append(gpa, '-');
        try b2.append(gpa, '1');
        var r = try parseAndVerify(gpa, b2.items);
        defer r.deinit(gpa);
        try std.testing.expect(r.errors.items.len >= 1);
    }
    {
        var b3: std.ArrayList(u8) = .empty;
        defer b3.deinit(gpa);
        try b3.appendSlice(gpa, "func f() { if (a) {} ");
        for (0..300) |_| try b3.appendSlice(gpa, "else if (a) {} ");
        try b3.append(gpa, '}');
        var r = try parseAndVerify(gpa, b3.items);
        defer r.deinit(gpa);
        try std.testing.expect(r.errors.items.len >= 1);
    }

    // 分配失败（OOM）无泄漏且保持状态可安全重试
    {
        const raw = "func f(a: Int64): Int64 { a + 1 }";
        var tok_list: std.ArrayList(common.Token) = .empty;
        defer tok_list.deinit(gpa);
        var lex = try lexer.Lexer.new(raw);
        while (true) {
            const tok = try lex.gen();
            try tok_list.append(gpa, tok);
            if (tok.tag == .end) break;
        }
        try std.testing.checkAllAllocationFailures(gpa, struct {
            /// 在受限分配器下完整运行一次 `Parser.gen()`。
            fn run(alloc: std.mem.Allocator, src: []const u8, toks: []const common.Token) !void {
                var p = Parser.new(alloc, src, toks);
                defer p.deinit();
                while (try p.gen()) |_| {}
            }
        }.run, .{ raw, tok_list.items });
    }
}

test "精确树形校验：wrap_node 不误抓 Trivia、优先级与结合性、点分路径平铺" {
    const gpa = std.testing.allocator;

    {
        var res = try parseAndVerify(gpa, "func f() { a /* c */ + b }");
        defer res.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
        const bin = res.root.findFirst(.binary_expr).?;
        try std.testing.expect(bin.children.items.len >= 3);
        try std.testing.expect(bin.children.items[0] == .node);
        try std.testing.expectEqual(SyntaxKind.path_expr, bin.children.items[0].node.kind);
        try std.testing.expectEqual(@as(?SyntaxKind, .add), bin.firstDirectOperator());
    }
    {
        var res = try parseAndVerify(gpa, "func f() { a ** b ** c }");
        defer res.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
        const outer = res.root.findFirst(.binary_expr).?;
        try std.testing.expectEqual(@as(?SyntaxKind, .exp), outer.firstDirectOperator());
        try std.testing.expectEqual(SyntaxKind.path_expr, outer.nthChildNode(0).?.kind);
        try std.testing.expectEqual(SyntaxKind.binary_expr, outer.nthChildNode(1).?.kind);
    }
    {
        var res = try parseAndVerify(gpa, "func f() { a ?? b ?? c }");
        defer res.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
        const outer = res.root.findFirst(.binary_expr).?;
        try std.testing.expectEqual(@as(?SyntaxKind, .coalescing), outer.firstDirectOperator());
        try std.testing.expectEqual(SyntaxKind.path_expr, outer.nthChildNode(0).?.kind);
        try std.testing.expectEqual(SyntaxKind.binary_expr, outer.nthChildNode(1).?.kind);
    }
    {
        var res = try parseAndVerify(gpa, "func f() { a |> b |> c }");
        defer res.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
        const outer = res.root.findFirst(.binary_expr).?;
        try std.testing.expectEqual(@as(?SyntaxKind, .pipeline), outer.firstDirectOperator());
        try std.testing.expectEqual(SyntaxKind.binary_expr, outer.nthChildNode(0).?.kind);
        try std.testing.expectEqual(SyntaxKind.path_expr, outer.nthChildNode(1).?.kind);
    }
    {
        var res = try parseAndVerify(gpa, "func f() { a < b == c & d ^ e | g }");
        defer res.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
        const bit_or = res.root.findFirst(.binary_expr).?;
        try std.testing.expectEqual(@as(?SyntaxKind, .bit_or), bit_or.firstDirectOperator());
        const bit_xor = bit_or.nthChildNode(0).?;
        try std.testing.expectEqual(@as(?SyntaxKind, .bit_xor), bit_xor.firstDirectOperator());
        const bit_and = bit_xor.nthChildNode(0).?;
        try std.testing.expectEqual(@as(?SyntaxKind, .bit_and), bit_and.firstDirectOperator());
        const eq = bit_and.nthChildNode(0).?;
        try std.testing.expectEqual(@as(?SyntaxKind, .equal), eq.firstDirectOperator());
        const lt = eq.nthChildNode(0).?;
        try std.testing.expectEqual(@as(?SyntaxKind, .less), lt.firstDirectOperator());
    }
    {
        var res = try parseAndVerify(gpa, "func f() { a.b.c }");
        defer res.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
        try std.testing.expectEqual(@as(usize, 1), res.root.countKind(.path_expr));
        const path = res.root.findFirst(.path_expr).?;
        try std.testing.expectEqual(@as(usize, 3), path.countKind(.path_segment));
    }
    {
        var res = try parseAndVerify(gpa, "func f() { g().b.c }");
        defer res.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
        const outer_path = res.root.findFirst(.path_expr).?;
        const seg0 = outer_path.nthChildNode(0).?;
        try std.testing.expectEqual(SyntaxKind.path_segment, seg0.kind);
        try std.testing.expectEqual(SyntaxKind.call_expr, seg0.nthChildNode(0).?.kind);
        try std.testing.expectEqual(SyntaxKind.path_segment, outer_path.nthChildNode(1).?.kind);
        try std.testing.expectEqual(SyntaxKind.path_segment, outer_path.nthChildNode(2).?.kind);
    }
}

test "禁止跨行连接的表达式、新行一元负号、带注解 lambda 与尾随闭包边界" {
    const gpa = std.testing.allocator;

    {
        const src =
            \\func f() {
            \\    a
            \\    (b, c) = (1, 2)
            \\    foo()
            \\    [1, 2]
            \\    doSomething()
            \\    -1
            \\    return
            \\    42
            \\}
            \\
        ;
        var res = try parseAndVerify(gpa, src);
        defer res.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
        try std.testing.expectEqual(@as(usize, 8), res.root.countKind(.expression_statement));
        try std.testing.expectEqual(@as(usize, 2), res.root.countKind(.call_expr));
        try std.testing.expectEqual(@as(usize, 0), res.root.countKind(.subscript_expr));
        try std.testing.expectEqual(@as(usize, 1), res.root.countKind(.unary_expr));
    }

    // 一元负号后换行报错
    {
        var res = try parseAndVerify(gpa, "func f() {\n    -\n    1\n}");
        defer res.deinit(gpa);
        try std.testing.expect(res.errors.items.len >= 1);
    }

    // lambdaHasArrow 不被 `<` 配嵌套 match 误判
    {
        const src =
            \\func f() {
            \\    foo {
            \\        let k = a < b
            \\        match {
            \\            case c > d => 1
            \\            case _ => 0
            \\        }
            \\    }
            \\}
            \\
        ;
        var res = try parseAndVerify(gpa, src);
        defer res.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
    }

    // 带注解 lambda、带注解尾随闭包、late 宏、表达式宏体与泛型优先消歧
    {
        const src =
            \\public late macro FindType(varDecl: VarDecl) {}
            \\public macro Id(x: Tokens): Tokens = quote($x)
            \\func open(public: Int64, get: Int64, handle: Int64) {
            \\    let sealed = public + get + handle
            \\    let fn1 = @OverflowWrapping { x => x + 1 }
            \\    let fn2 = foo @OverflowWrapping { x => x + 1 }
            \\    let g = (c < d, e > (f))
            \\    unsafe func inner() {}
            \\    unsafe { inner() }
            \\    _ = sealed
            \\    _ = fn1
            \\    _ = fn2
            \\    _ = g
            \\}
            \\
        ;
        var res = try parseAndVerify(gpa, src);
        defer res.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
        try std.testing.expectEqual(@as(usize, 2), res.root.countKind(.macro_decl));
        try std.testing.expect(res.root.hasKind(.annotation));
        try std.testing.expect(res.root.hasKind(.lambda_expr));
        try std.testing.expect(res.root.hasKind(.trailing_closure_expr));
        try std.testing.expect(res.root.hasKind(.type_argument_list));
        try std.testing.expect(res.root.hasKind(.unsafe_expr));
    }

    // 非尾随带注解 lambda 省略 `=>` 报错
    {
        var bad = try parseAndVerify(gpa, "let fn1 = @OverflowWrapping { 1 + 2 }");
        defer bad.deinit(gpa);
        try std.testing.expect(bad.errors.items.len >= 1);
    }
}

test "LSP 编辑态错误恢复：点号补全、漏逗号、未闭合定界符与新行声明零误吞" {
    const gpa = std.testing.allocator;

    // 1. 点号补全后紧跟局部声明与带修饰符声明，零外层 Token 被吞
    {
        const src =
            \\func f() {
            \\    obj.
            \\    let x = 1
            \\    return x
            \\}
            \\
        ;
        var r = try parseAndVerify(gpa, src);
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), r.errors.items.len);
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.var_decl));
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.return_expr));
    }
    {
        const src =
            \\import std.
            \\public class A {
            \\    func m() {
            \\        this.
            \\    }
            \\    public func g() {}
            \\}
            \\
        ;
        var r = try parseAndVerify(gpa, src);
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 2), r.errors.items.len);
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.import_spec));
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.class_decl));
        try std.testing.expectEqual(@as(usize, 2), r.root.countKind(.func_decl));
    }

    // 2. 列表中漏敲逗号：仅报 1 次错且后续全部元素与函数体完好
    {
        var r = try parseAndVerify(gpa, "func f(a: Int64 b: Int64) { return a + b }");
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), r.errors.items.len);
        try std.testing.expectEqual(@as(usize, 2), r.root.countKind(.func_param));
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.return_expr));
    }
    {
        var r = try parseAndVerify(gpa, "func f() { foo(a b); let y = 1 }");
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), r.errors.items.len);
        try std.testing.expectEqual(@as(usize, 2), r.root.countKind(.func_arg));
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.var_decl));
    }
    {
        var r = try parseAndVerify(gpa, "class A<T U> { func f() {} }");
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), r.errors.items.len);
        try std.testing.expectEqual(@as(usize, 2), r.root.countKind(.type_parameter));
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.func_decl));
    }
    {
        var r = try parseAndVerify(gpa, "let x: Array<Int64 String> = []");
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), r.errors.items.len);
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.type_argument_list));
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.array_lit));
    }

    // 3. 未闭合定界符绝不吞噬后续声明或函数体
    {
        const src =
            \\func f() {
            \\    foo(a,
            \\    let y = 2
            \\    bar()
            \\}
            \\func g() {}
            \\
        ;
        var r = try parseAndVerify(gpa, src);
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), r.errors.items.len);
        try std.testing.expectEqual(ParseErrorCode.unclosed_delimiter, r.errors.items[0].code);
        try std.testing.expectEqual(@as(usize, 2), r.root.countKind(.func_decl));
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.var_decl));
        try std.testing.expectEqual(@as(usize, 2), r.root.countKind(.call_expr));
    }
    {
        const src =
            \\func foo(a: Int64 {
            \\    return a
            \\}
            \\func bar() {}
            \\
        ;
        var r = try parseAndVerify(gpa, src);
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), r.errors.items.len);
        try std.testing.expectEqual(@as(usize, 2), r.root.countKind(.func_decl));
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.return_expr));
    }
    {
        const src =
            \\class Foo<T {
            \\    let x = 1
            \\}
            \\class Bar {}
            \\
        ;
        var r = try parseAndVerify(gpa, src);
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), r.errors.items.len);
        try std.testing.expectEqual(@as(usize, 2), r.root.countKind(.class_decl));
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.var_decl));
    }
    {
        const src =
            \\let x: Array<Int64
            \\let y = 2
            \\
        ;
        var r = try parseAndVerify(gpa, src);
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), r.errors.items.len);
        try std.testing.expectEqual(@as(usize, 2), r.root.countKind(.var_decl));
    }

    // 4. 半成品表达式/类型/模式后紧跟新行带修饰符声明，零修饰符被吞
    for ([_][]const u8{
        "let x =\npublic func g() {}",
        "let x:\npublic func g() {}",
        "let \npublic func g() {}",
    }) |src| {
        var r = try parseAndVerify(gpa, src);
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), r.errors.items.len);
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.var_decl));
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.func_decl));
    }

    // 5. 控制流、match、枚举与行内多余闭括号最小范围恢复
    {
        var r = try parseAndVerify(gpa, "func f() { if (a > b { let x = 1 } }");
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), r.errors.items.len);
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.if_expr));
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.var_decl));
    }
    {
        var r = try parseAndVerify(gpa, "func f(x: Int64) { match (x) {\ncase 1\ncase 2 => 2\n} }");
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), r.errors.items.len);
        try std.testing.expectEqual(@as(usize, 2), r.root.countKind(.match_case));
    }
    {
        var r = try parseAndVerify(gpa, "enum E { Red |\npublic func f() {} }");
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), r.errors.items.len);
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.enum_constructor));
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.func_decl));
    }
    {
        var r = try parseAndVerify(gpa, "func f() { let a = 1; ))) let b = 2 }");
        defer r.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), r.errors.items.len);
        try std.testing.expectEqual(@as(usize, 1), r.root.countKind(.error_node));
        try std.testing.expectEqual(@as(usize, 2), r.root.countKind(.var_decl));
    }
}

test "LSP 逐字符实时输入前缀测试：任意截断位置均无损且事件流平衡" {
    const gpa = std.testing.allocator;
    const sample =
        \\package demo.app
        \\import std.core.{Option, Array}
        \\@Deprecated["old"]
        \\public class User<T> <: Named where T <: Hashable {
        \\    public User(public let id: Int64, var name: T) {}
        \\    public func greet(opt: ?Int64): String {
        \\        if (let Some(v) <- opt && v > 0) {
        \\            let q = quote(1 + $v + $(v + 1))
        \\            return "hi ${v}"
        \\        }
        \\        match (opt) {
        \\            case Some(n) => "${n}"
        \\            case _ => "none"
        \\        }
        \\    }
        \\}
        \\
    ;

    for (0..sample.len + 1) |prefix_len| {
        const prefix = sample[0..prefix_len];
        var res = try parseAndVerify(gpa, prefix);
        defer res.deinit(gpa);
    }
}

test "Parser.errors 与 parseErrorToDiagnostic 零分配静态消息及动态片段格式化" {
    const gpa = std.testing.allocator;
    const file_id: common.FileId = .{ .index = 3, .generation = 1 };

    // 1. 编译期确定消息的错误码使用 failing_allocator 验证严格零堆分配
    const static_codes = [_]ParseErrorCode{
        .recursive_depth_limit,
        .non_associative_comparison,
        .non_associative_assignment,
        .non_associative_operator,
        .invalid_assignment_target,
        .unclosed_delimiter,
        .invalid_interpolation,
        .dangling_doc_comment,
    };
    for (static_codes) |code| {
        const err_item: ParseError = .{ .code = code, .range = .{ .start = 0, .end = 3 } };
        const diag = try err_item.toDiagnostic(std.testing.failing_allocator, file_id, "abc");
        try std.testing.expectEqual(file_id, diag.file);
        try std.testing.expectEqual(err_item.range, diag.range);
        try std.testing.expectEqual(common.Severity.err, diag.severity);
        try std.testing.expect(common.DiagnosticSource.eql(.parser, diag.source));
        try std.testing.expect(diag.message.len > 0);
        try std.testing.expectEqual(@as(usize, 0), diag.related.len);
    }

    // 2. 需源码片段的错误码在空区间、越界与倒置区间下同样零分配返回编译期静态消息
    const snippet_codes = [_]ParseErrorCode{
        .expected_expression,
        .expected_token,
        .expected_item,
        .invalid_literal,
        .expected_type,
        .expected_pattern,
        .expected_identifier,
        .expected_block,
        .illegal_token,
        .unexpected_token,
    };
    const invalid_ranges = [_]common.TextRange{
        .{ .start = 0, .end = 0 },
        .{ .start = 5, .end = 2 },
        .{ .start = 0, .end = 999 },
    };
    for (snippet_codes) |code| {
        for (invalid_ranges) |r| {
            const diag = try parseErrorToDiagnostic(std.testing.failing_allocator, file_id, "let x", .{
                .code = code,
                .range = r,
            });
            try std.testing.expect(diag.message.len > 0);
        }
    }

    // 3. 有效源码片段动态格式化与多字节 UTF-8 截断安全校验
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        const long_utf8 = "这是一段非常非常长的中文标识符用于测试按码点截断边界不会破坏编码";
        for (snippet_codes) |code| {
            const diag = try parseErrorToDiagnostic(alloc, file_id, long_utf8, .{
                .code = code,
                .range = .{ .start = 0, .end = @intCast(long_utf8.len) },
            });
            try std.testing.expect(std.unicode.utf8ValidateSlice(diag.message));
            try std.testing.expect(std.mem.indexOf(u8, diag.message, "这是一段") != null);
        }
    }

    // 4. 完整解析流程：验证 Parser.errors 包含插值子解析错误、排除回溯临时错误并转换为 Diagnostic 数组
    {
        const src = "let ok = a < b && c > d\nlet bad = \"hi ${a < b < c}\"\n";
        var tok_list: std.ArrayList(common.Token) = .empty;
        defer tok_list.deinit(gpa);

        var lex = try lexer.Lexer.new(src);
        while (true) {
            const tok = try lex.gen();
            try tok_list.append(gpa, tok);
            if (tok.tag == .end) break;
        }

        var parser = Parser.new(gpa, src, tok_list.items);
        defer parser.deinit();
        while (try parser.gen()) |_| {}

        try std.testing.expectEqual(@as(usize, 1), parser.errors.items.len);
        try std.testing.expectEqual(ParseErrorCode.non_associative_comparison, parser.errors.items[0].code);

        const diag = try parser.errors.items[0].toDiagnostic(std.testing.failing_allocator, file_id, src);
        try std.testing.expectEqual(file_id, diag.file);
        try std.testing.expectEqual(common.Severity.err, diag.severity);
        try std.testing.expectEqualStrings("comparison operators are non-associative", diag.message);
    }
}

test "完全 leading trivia、文件末尾 trivia 归属 source_file 与链式成员 path_segment 包装" {
    const gpa = std.testing.allocator;

    // 1. 文件头部注释归属首个顶层项，项间空行与注释归属后续项，文件末尾注释与空行归属 source_file
    {
        const src =
            \\// file header
            \\package demo
            \\
            \\// import note
            \\import std.core.*
            \\
            \\func f() {
            \\    // stmt note
            \\    let x = g().a.b
            \\    x[0]?.c.d
            \\    // before r_curl
            \\}
            \\// trailing file comment
            \\
        ;
        var res = try parseAndVerify(gpa, src);
        defer res.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);

        // source_file 仅在末尾保留文件尾 trivia 与 eof，开头注释归 package_header
        try std.testing.expect(res.root.children.items[0] == .node);
        try std.testing.expectEqual(SyntaxKind.package_header, res.root.children.items[0].node.kind);
        const pkg_txt = try res.root.children.items[0].node.reconstruct(gpa, src);
        defer gpa.free(pkg_txt);
        try std.testing.expectEqualStrings("// file header\npackage demo", pkg_txt);

        // import_spec 承接前导空行与注释
        try std.testing.expect(res.root.children.items[1] == .node);
        try std.testing.expectEqual(SyntaxKind.import_spec, res.root.children.items[1].node.kind);
        const imp_txt = try res.root.children.items[1].node.reconstruct(gpa, src);
        defer gpa.free(imp_txt);
        try std.testing.expectEqualStrings("\n\n// import note\nimport std.core.*", imp_txt);

        // func_decl 承接前导空行，其后文件尾 trivia 归属 source_file
        try std.testing.expect(res.root.children.items[2] == .node);
        try std.testing.expectEqual(SyntaxKind.func_decl, res.root.children.items[2].node.kind);
        var has_trailing_comment_in_root = false;
        for (res.root.children.items[3..]) |child| {
            if (child == .token and child.token.kind == .line_comment) {
                has_trailing_comment_in_root = true;
            }
        }
        try std.testing.expect(has_trailing_comment_in_root);

        // g().a.b 与 x[0]?.c.d 的外层 path_expr 首子节点均为 path_segment
        const vdecl = res.root.findFirst(.var_decl).?;
        const call_chain = vdecl.findFirst(.path_expr).?;
        try std.testing.expectEqual(SyntaxKind.path_segment, call_chain.nthChildNode(0).?.kind);
        try std.testing.expectEqual(SyntaxKind.call_expr, call_chain.nthChildNode(0).?.nthChildNode(0).?.kind);

        const expr_stmt = res.root.findFirst(.expression_statement).?;
        const sub_chain = expr_stmt.findFirst(.path_expr).?;
        try std.testing.expectEqual(SyntaxKind.path_segment, sub_chain.nthChildNode(0).?.kind);
        try std.testing.expectEqual(SyntaxKind.subscript_expr, sub_chain.nthChildNode(0).?.nthChildNode(0).?.kind);
    }

    // 2. 纯注释与空白文件：全部 trivia 归属 source_file
    {
        const src = "// only comment\n   \n";
        var res = try parseAndVerify(gpa, src);
        defer res.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);
        try std.testing.expect(res.root.hasKind(.line_comment));
    }
}

test "文档注释：支持 /// 与 /** */、归属注释对象成员，无注释对象报 dangling_doc_comment" {
    const gpa = std.testing.allocator;

    // 1. 合法文档注释（/// 与 /** */）归属对应声明对象成员；////、/**/、/*** */ 为普通注释
    {
        const src =
            \\/// 包级文档
            \\package docdemo
            \\
            \\/// 重导出说明
            \\public import std.core.*
            \\
            \\//// 普通四斜杠分割线
            \\/**/
            \\/*** 普通块注释 ***/
            \\/**
            \\ * 函数文档
            \\ */
            \\@Frozen
            \\/// 注解与修饰符之间的文档
            \\@When[os == "Linux"]
            \\/// 末尾注解之后的文档
            \\public func f(
            \\    /// 参数文档
            \\    x: Int64,
            \\): Int64 {
            \\    /// 局部变量文档
            \\    let y = x
            \\    let q = quote(/// quote 内文档注释不误报
            \\        func g() {}
            \\    )
            \\    y
            \\}
            \\
            \\/// 枚举文档
            \\enum Color {
            \\    /// 红色
            \\    | Red
            \\    | /// 绿色
            \\    Green(Int64)
            \\    ///
            \\    | @MyAnno Blue
            \\}
            \\
            \\/// 类文档
            \\class Box {
            \\    /// 主构造器文档
            \\    Box(
            \\        /// 成员参数文档
            \\        public let v: Int64,
            \\    ) {}
            \\    /// 属性文档
            \\    prop p: Int64 {
            \\        /// getter 文档
            \\        get() { v }
            \\    }
            \\}
            \\//// 文件尾普通注释不报错
            \\
        ;
        var res = try parseAndVerify(gpa, src);
        defer res.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), res.errors.items.len);

        // 验证文档注释直接属于目标节点成员，未游离在 source_file 且未进入 annotation 内部
        for (res.root.children.items) |child| {
            if (child == .token) {
                try std.testing.expect(child.token.kind != .doc_comment);
            }
        }
        const pkg = res.root.findFirst(.package_header).?;
        try std.testing.expect(pkg.hasKind(.doc_comment));

        const func_node = res.root.findFirst(.func_decl).?;
        var direct_func_docs: usize = 0;
        for (func_node.children.items) |child| {
            if (child == .token and child.token.kind == .doc_comment) direct_func_docs += 1;
            if (child == .node and child.node.kind == .annotation) {
                try std.testing.expect(!child.node.hasKind(.doc_comment));
            }
        }
        try std.testing.expectEqual(@as(usize, 3), direct_func_docs);

        const param_node = func_node.findFirst(.func_param).?;
        try std.testing.expect(param_node.hasKind(.doc_comment));

        const enum_node = res.root.findFirst(.enum_decl).?;
        try std.testing.expect(enum_node.hasKind(.doc_comment));
        try std.testing.expectEqual(@as(usize, 3), enum_node.countKind(.enum_constructor));
        const ctor0 = enum_node.findFirst(.enum_constructor).?;
        try std.testing.expect(ctor0.hasKind(.doc_comment));
    }

    // 2. 无注释对象的悬空文档注释一律报告 dangling_doc_comment 且保持无损
    const dangling_cases = [_][]const u8{
        "/// 文件尾孤立文档注释",
        "/** 文件尾块文档注释 */",
        "func f() {}\n/// 末尾悬空\n/// 第二行悬空\n",
        "class C {\n    func m() {}\n    /// 类体末尾悬空\n}",
        "func f() {\n    let x = 1\n    /** 块尾悬空 */\n}",
        "func f() {\n    /// 表达式语句前非法\n    1 + 2\n}",
        "func f() {\n    let x = 1 + /** 运算符后非法 */ 2\n}",
        "func f(x: /** 类型前非法 */ Int64) {}",
        "/// 分号前悬空\n; func f() {}",
        "let s = \"${1 /** 插值尾悬空 */}\"",
    };
    for (dangling_cases) |bad_src| {
        var res = try parseAndVerify(gpa, bad_src);
        defer res.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), res.errors.items.len);
        try std.testing.expectEqual(ParseErrorCode.dangling_doc_comment, res.errors.items[0].code);
        try std.testing.expect(res.root.hasKind(.doc_comment));
    }
}
