// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 语法分析错误及其到平台统一诊断的转换。
//!
//! 错误码覆盖语法分析阶段可能遇到的各类问题，与具体的词法标签枚举无关，供语法解析器及其测试共用。

const std = @import("std");
const source_mod = @import("source.zig");
const diagnostic_mod = @import("diagnostic.zig");
const utf8 = @import("utf8.zig");

const FileId = source_mod.FileId;
const TextRange = source_mod.TextRange;
const Diagnostic = diagnostic_mod.Diagnostic;

/// 语法分析错误码。
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
    invalid_declaration_position,
};

/// 语法分析错误，携带错误码与源码字节区间。
pub const ParseError = struct {
    code: ParseErrorCode,
    range: TextRange,

    /// 将当前 `ParseError` 转换为平台统一的 `Diagnostic`。
    ///
    /// 若错误消息可在编译期确定，则返回的 `Diagnostic.message` 为静态字符串切片（不经过
    /// `allocator` 分配，不可单独释放）；仅当需拼接源码片段时通过 `allocator` 分配内存。
    /// 推荐传入 `ArenaAllocator` 统一管理诊断消息的生命周期。
    pub inline fn toDiagnostic(
        self: ParseError,
        allocator: std.mem.Allocator,
        file: FileId,
        source: []const u8,
    ) std.mem.Allocator.Error!Diagnostic {
        return parseErrorToDiagnostic(allocator, file, source, self);
    }
};

/// 诊断消息中嵌入源码片段的最大字节长度（按合法 UTF-8 码点边界截断）。
const max_snippet_bytes: usize = 32;

/// 安全提取用于诊断展示的单行源码片段；区间越界、倒置、为空或首行仅空白时返回 `null`。
///
/// 返回的切片借用自 `source`，调用者不可释放，生命周期不超过 `source`。
fn extractSnippet(source: []const u8, range: TextRange) ?[]const u8 {
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
        const cp = utf8.decodeAt(slice, pos) orelse break;
        if (pos + cp.len > max_snippet_bytes) break;
        pos += cp.len;
    }
    return if (pos > 0) slice[0..pos] else null;
}

/// 将单个 `ParseError` 转换为平台统一的 `Diagnostic`。
///
/// 遵循诊断消息混合所有权约定：
/// - 对于编译期可完全确定的错误码，或 `err.range` 无有效可展示源码片段时，`Diagnostic.message`
///   直接返回编译期静态字符串切片，不调用 `allocator`，调用者不可对其单独 `free`。
/// - 对于需要拼入源码片段的错误，通过 `allocator` 分配 `Diagnostic.message`。
/// - `Diagnostic.related` 始终为空静态切片，`source` 仅作只读借用。
/// 推荐传入 `ArenaAllocator` 统一托管诊断消息的生命周期。
pub fn parseErrorToDiagnostic(
    allocator: std.mem.Allocator,
    file: FileId,
    source: []const u8,
    err: ParseError,
) std.mem.Allocator.Error!Diagnostic {
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
        .expected_expression => if (extractSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "expected expression near `{s}`", .{s})
        else
            "expected expression",
        .expected_token => if (extractSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "expected token near `{s}`", .{s})
        else
            "expected token",
        .expected_item => if (extractSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "expected declaration or item near `{s}`", .{s})
        else
            "expected declaration or item",
        .invalid_literal => if (extractSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "invalid literal `{s}`", .{s})
        else
            "invalid literal",
        .expected_type => if (extractSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "expected type near `{s}`", .{s})
        else
            "expected type",
        .expected_pattern => if (extractSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "expected pattern near `{s}`", .{s})
        else
            "expected pattern",
        .expected_identifier => if (extractSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "expected identifier near `{s}`", .{s})
        else
            "expected identifier",
        .expected_block => if (extractSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "expected block near `{s}`", .{s})
        else
            "expected block",
        .illegal_token => if (extractSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "illegal token `{s}`", .{s})
        else
            "illegal token",
        .unexpected_token => if (extractSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "unexpected token `{s}`", .{s})
        else
            "unexpected token",
        .invalid_declaration_position => if (extractSnippet(source, err.range)) |s|
            try std.fmt.allocPrint(allocator, "declaration is not allowed in this position near `{s}`", .{s})
        else
            "declaration is not allowed in this position",
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

test "ParseError.toDiagnostic 编译期消息不分配堆内存" {
    const file_id: FileId = .{ .index = 3, .generation = 1 };
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
        try std.testing.expectEqual(diagnostic_mod.Severity.err, diag.severity);
        try std.testing.expect(diagnostic_mod.Source.eql(.parser, diag.source));
        try std.testing.expect(diag.message.len > 0);
        try std.testing.expectEqual(@as(usize, 0), diag.related.len);
    }
}

test "ParseError.toDiagnostic 无效区间退化为静态消息" {
    const file_id: FileId = .{ .index = 0, .generation = 0 };
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
        .invalid_declaration_position,
    };
    const invalid_ranges = [_]TextRange{
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
}

test "ParseError.toDiagnostic 源码片段按 UTF-8 码点边界截断" {
    const file_id: FileId = .{ .index = 0, .generation = 0 };
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
        .invalid_declaration_position,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
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
