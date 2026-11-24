// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 分析平台统一的诊断数据结构，用于描述词法、语法、名称解析、类型检查与 Linter 等阶段产生的诊断信息。

const std = @import("std");
const source_mod = @import("source.zig");
const FileId = source_mod.FileId;
const TextRange = source_mod.TextRange;

/// 诊断严重级别，按数值升序排列（`err` 优先级最高）。
pub const Severity = enum(u8) {
    err = 0,
    warning = 1,
    info = 2,
    hint = 3,
};

/// 诊断来源阶段或 Linter 规则标识。
pub const Source = union(enum) {
    lexer,
    parser,
    name_res,
    typeck,
    /// Linter 规则名称（如 `"unused_var"`）；要求为程序生命周期内的静态字符串切片。
    linter: []const u8,

    /// 判断两个诊断来源是否相等。
    pub inline fn eql(a: Source, b: Source) bool {
        return switch (a) {
            .linter => |name| switch (b) {
                .linter => |other| std.mem.eql(u8, name, other),
                else => false,
            },
            else => std.meta.activeTag(a) == std.meta.activeTag(b),
        };
    }
};

/// 诊断附带的关联位置与说明。
pub const RelatedInfo = struct {
    range: TextRange,
    /// 遵循与 `Diagnostic.message` 相同的生命周期约定（静态字符串、Arena 托管或独立分配）。
    message: []const u8,
};

/// 平台统一诊断数据结构。
///
/// 本结构体本身不绑定特定分配策略：`message` 与 `related` 可来自编译期静态字符串、
/// Arena 统一托管或外部借用，具体所有权与释放方式由构造方在其文档注释中说明。
pub const Diagnostic = struct {
    file: FileId,
    range: TextRange,
    severity: Severity,
    source: Source,
    message: []const u8,
    related: []const RelatedInfo = &.{},

    /// 按 `severity`（`err` 最先）、`file`、`range.start`、`range.end` 比较两条诊断的顺序。
    pub fn order(a: Diagnostic, b: Diagnostic) std.math.Order {
        const sev = std.math.order(@backingInt(a.severity), @backingInt(b.severity));
        if (sev != .eq) return sev;
        const file_idx = std.math.order(a.file.index, b.file.index);
        if (file_idx != .eq) return file_idx;
        const file_gen = std.math.order(a.file.generation, b.file.generation);
        if (file_gen != .eq) return file_gen;
        const start_ord = std.math.order(a.range.start, b.range.start);
        if (start_ord != .eq) return start_ord;
        return std.math.order(a.range.end, b.range.end);
    }

    /// 供 `std.mem.sort` 使用的诊断排序比较函数。
    pub fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
        return order(a, b) == .lt;
    }
};

test "Severity 数值顺序满足 err 最先" {
    try std.testing.expectEqual(@as(u8, 0), @backingInt(Severity.err));
    try std.testing.expectEqual(@as(u8, 1), @backingInt(Severity.warning));
    try std.testing.expectEqual(@as(u8, 2), @backingInt(Severity.info));
    try std.testing.expectEqual(@as(u8, 3), @backingInt(Severity.hint));
}

test "Source.eql 正确比较各阶段与 linter 规则名" {
    try std.testing.expect(Source.eql(.lexer, .lexer));
    try std.testing.expect(!Source.eql(.lexer, .parser));
    try std.testing.expect(Source.eql(.{ .linter = "unused_var" }, .{ .linter = "unused_var" }));
    try std.testing.expect(!Source.eql(.{ .linter = "unused_var" }, .{ .linter = "shadowing" }));
    try std.testing.expect(!Source.eql(.{ .linter = "unused_var" }, .typeck));
}

test "Diagnostic 排序优先按 severity 再按 file 与 range" {
    const f0: FileId = .{ .index = 0, .generation = 0 };
    const f1: FileId = .{ .index = 1, .generation = 0 };
    const related = [_]RelatedInfo{.{
        .range = .{ .start = 1, .end = 3 },
        .message = "declared here",
    }};

    var list = [_]Diagnostic{
        .{
            .file = f0,
            .range = .{ .start = 0, .end = 2 },
            .severity = .hint,
            .source = .{ .linter = "style" },
            .message = "hint msg",
            .related = &.{},
        },
        .{
            .file = f1,
            .range = .{ .start = 5, .end = 8 },
            .severity = .err,
            .source = .parser,
            .message = "err f1",
            .related = &related,
        },
        .{
            .file = f0,
            .range = .{ .start = 10, .end = 12 },
            .severity = .err,
            .source = .lexer,
            .message = "err f0 late",
        },
        .{
            .file = f0,
            .range = .{ .start = 2, .end = 4 },
            .severity = .err,
            .source = .typeck,
            .message = "err f0 early",
        },
        .{
            .file = f0,
            .range = .{ .start = 0, .end = 1 },
            .severity = .warning,
            .source = .name_res,
            .message = "warn msg",
        },
    };

    std.mem.sort(Diagnostic, &list, {}, Diagnostic.lessThan);

    try std.testing.expectEqualStrings("err f0 early", list[0].message);
    try std.testing.expectEqualStrings("err f0 late", list[1].message);
    try std.testing.expectEqualStrings("err f1", list[2].message);
    try std.testing.expectEqual(@as(usize, 1), list[2].related.len);
    try std.testing.expectEqualStrings("warn msg", list[3].message);
    try std.testing.expectEqualStrings("hint msg", list[4].message);
}
