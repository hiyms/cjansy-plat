// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 行首偏移缓存：把字节偏移映射到行号与列号，并支持编辑之后的增量更新。
//!
//! 只把 `'\n'` 当作换行符，`'\r'` 保留在行内容里。列号以字节为单位，
//! 从行首开始计数。

const std = @import("std");
const builtin = @import("builtin");
const TextRange = @import("Edit.zig").TextRange;

const newline: u8 = '\n';

/// 是否使用按块向量比较扫描换行符。
///
/// 需要目标平台有可用的向量寄存器；位掩码的位序只在低位在前的目标上与向量 lane
/// 顺序一致，因此大端目标退回逐字节比较；部分后端尚未实现向量指令。
const use_simd = if (std.simd.suggestVectorLength(u8)) |len|
    len >= 8 and
        builtin.cpu.arch.endian() == .little and
        switch (builtin.zig_backend) {
            .stage2_aarch64, .stage2_loongarch, .stage2_powerpc, .stage2_riscv64, .stage2_spirv => false,
            else => true,
        }
else
    false;

/// 换行符扫描策略。两种实现对外提供相同的 `count` 与 `append`。
const Scanner = if (use_simd) VectorScanner else ByteScanner;

/// 按向量块比较：一次加载 `block_len` 字节，比较结果按位压成掩码。
const VectorScanner = struct {
    const block_len: comptime_int = std.simd.suggestVectorLength(u8).?;
    const Chunk = @Vector(block_len, u8);
    /// 第 `k` 位对应块内偏移 `k` 处是否为换行符。
    const Mask = @Int(.unsigned, block_len);

    /// 读取 `bytes[offset..][0..block_len]`，返回其中的换行符掩码。
    inline fn maskAt(bytes: []const u8, offset: usize) Mask {
        const block: Chunk = bytes[offset..][0..block_len].*;
        return @bitCast(block == @as(Chunk, @splat(newline)));
    }

    fn count(bytes: []const u8) usize {
        var total: usize = 0;
        var i: usize = 0;
        while (i + block_len <= bytes.len) : (i += block_len) {
            total += @popCount(maskAt(bytes, i));
        }
        while (i < bytes.len) : (i += 1) {
            total += @intFromBool(bytes[i] == newline);
        }
        return total;
    }

    fn append(starts: *std.ArrayListUnmanaged(u32), base: u32, bytes: []const u8) void {
        var i: usize = 0;
        while (i + block_len <= bytes.len) : (i += block_len) {
            var mask = maskAt(bytes, i);
            while (mask != 0) : (mask &= mask - 1) {
                const lane: u32 = @intCast(@ctz(mask));
                starts.appendAssumeCapacity(base + @as(u32, @intCast(i)) + lane + 1);
            }
        }
        while (i < bytes.len) : (i += 1) {
            if (bytes[i] == newline) starts.appendAssumeCapacity(base + @as(u32, @intCast(i)) + 1);
        }
    }
};

/// 逐字节比较。
const ByteScanner = struct {
    fn count(bytes: []const u8) usize {
        var total: usize = 0;
        for (bytes) |byte| total += @intFromBool(byte == newline);
        return total;
    }

    fn append(starts: *std.ArrayListUnmanaged(u32), base: u32, bytes: []const u8) void {
        for (bytes, 0..) |byte, i| {
            if (byte == newline) starts.appendAssumeCapacity(base + @as(u32, @intCast(i)) + 1);
        }
    }
};

/// 文本位置。行号从 0 开始，列以字节为单位，从行首开始计数。
pub const Position = struct { line: u32, column: u32 };

/// 行首偏移缓存。
///
/// `starts[0]` 恒为 0，其余每项是某个换行符之后的偏移。前 `scanned` 个字节扫描完毕，
/// `starts` 中所有值都不大于 `scanned`，且 `text[0..scanned]` 内的换行符与 `starts`
/// 中除首项之外的项一一对应。
pub const LineIndex = struct {
    starts: std.ArrayListUnmanaged(u32) = .empty,
    /// 已经扫描过的文本前缀长度。
    scanned: u32 = 0,

    pub fn deinit(self: *LineIndex, gpa: std.mem.Allocator) void {
        self.starts.deinit(gpa);
        self.* = .{};
    }

    /// 扫描尚未处理的部分。首次调用时从头扫到尾，之后只处理新增的字节。
    ///
    /// 行首数组在第一次扫描时才写入首项 0，因此从未查询过行号的文件不付出扫描成本。
    /// 容量先一次预留再写入：分配失败时 `starts` 与 `scanned` 都保持在扫描前的状态，
    /// 再次调用不会把同一个换行位置追加两次。
    fn scanTo(self: *LineIndex, gpa: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!void {
        std.debug.assert(self.scanned <= text.len);
        std.debug.assert(text.len <= std.math.maxInt(u32));
        const need_first = self.starts.items.len == 0;
        const base = self.scanned;
        const rest = text[base..];

        try self.starts.ensureUnusedCapacity(gpa, Scanner.count(rest) + @intFromBool(need_first));
        if (need_first) self.starts.appendAssumeCapacity(0);

        Scanner.append(&self.starts, base, rest);
        self.scanned = @intCast(text.len);
    }

    /// 文本在 `from` 处发生编辑之后丢弃失效的行首。
    ///
    /// `from` 之前的行首仍然成立：它们对应的换行符都在编辑起点之前，编辑改动不到。
    /// 水位只能回退，因为 `[scanned, from)` 这段字节原本就还没扫描过。
    pub fn invalidate(self: *LineIndex, from: u32) void {
        if (self.starts.items.len == 0) return;
        const keep = std.sort.upperBound(u32, self.starts.items, from, compareAsc);
        self.starts.shrinkRetainingCapacity(keep);
        self.scanned = @min(self.scanned, from);
    }

    /// 总行数。空文本算作一行；以 `'\n'` 结尾的文本末尾多出一个空行。
    pub fn lineCount(self: *LineIndex, gpa: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!u32 {
        try self.scanTo(gpa, text);
        return @intCast(self.starts.items.len);
    }

    /// 包含 `offset` 的行号。`offset` 可以等于文本长度（文件末尾），超出则报错。
    pub fn lineOf(self: *LineIndex, gpa: std.mem.Allocator, text: []const u8, offset: u32) (std.mem.Allocator.Error || error{InvalidPosition})!u32 {
        if (offset > text.len) return error.InvalidPosition;
        try self.scanTo(gpa, text);
        return @intCast(std.sort.upperBound(u32, self.starts.items, offset, compareAsc) - 1);
    }

    /// 行区间，半开，包含该行末尾的换行符。最后一行以文本长度为终点。
    pub fn lineRange(self: *LineIndex, gpa: std.mem.Allocator, text: []const u8, line: u32) (std.mem.Allocator.Error || error{InvalidLine})!TextRange {
        try self.scanTo(gpa, text);
        if (line >= self.starts.items.len) return error.InvalidLine;
        return .{ .start = self.starts.items[line], .end = self.lineEnd(line, text) };
    }

    /// 字节偏移对应的行列。列号按字节计。
    pub fn positionOf(self: *LineIndex, gpa: std.mem.Allocator, text: []const u8, offset: u32) (std.mem.Allocator.Error || error{InvalidPosition})!Position {
        if (offset > text.len) return error.InvalidPosition;
        try self.scanTo(gpa, text);
        const line = std.sort.upperBound(u32, self.starts.items, offset, compareAsc) - 1;
        return .{ .line = @intCast(line), .column = offset - self.starts.items[line] };
    }

    /// 行列对应的字节偏移，与 `positionOf` 互为逆运算。列号不得超过该行长度。
    pub fn offsetOf(self: *LineIndex, gpa: std.mem.Allocator, text: []const u8, pos: Position) (std.mem.Allocator.Error || error{InvalidPosition})!u32 {
        try self.scanTo(gpa, text);
        if (pos.line >= self.starts.items.len) return error.InvalidPosition;
        const start = self.starts.items[pos.line];
        if (pos.column > self.lineEnd(pos.line, text) - start) return error.InvalidPosition;
        return start + pos.column;
    }

    /// 行的终点：下一行的行首，最后一行取文本长度。
    fn lineEnd(self: *LineIndex, line: u32, text: []const u8) u32 {
        if (line + 1 < self.starts.items.len) return self.starts.items[line + 1];
        return @intCast(text.len);
    }
};

fn compareAsc(context: u32, item: u32) std.math.Order {
    return std.math.order(context, item);
}

test "空文本只有一行" {
    const gpa = std.testing.allocator;
    var index: LineIndex = .{};
    defer index.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 1), try index.lineCount(gpa, ""));
    try std.testing.expectEqual(@as(u32, 0), try index.lineOf(gpa, "", 0));
}

test "行首与行区间" {
    const gpa = std.testing.allocator;
    var index: LineIndex = .{};
    defer index.deinit(gpa);

    const text = "ab\n\ncd\n";
    try std.testing.expectEqual(@as(u32, 4), try index.lineCount(gpa, text));

    try std.testing.expectEqual(TextRange{ .start = 0, .end = 3 }, try index.lineRange(gpa, text, 0));
    try std.testing.expectEqual(TextRange{ .start = 3, .end = 4 }, try index.lineRange(gpa, text, 1));
    try std.testing.expectEqual(TextRange{ .start = 4, .end = 7 }, try index.lineRange(gpa, text, 2));
    try std.testing.expectEqual(TextRange{ .start = 7, .end = 7 }, try index.lineRange(gpa, text, 3));
    try std.testing.expectError(error.InvalidLine, index.lineRange(gpa, text, 4));
}

test "偏移与位置互为逆运算" {
    const gpa = std.testing.allocator;
    var index: LineIndex = .{};
    defer index.deinit(gpa);

    const text = "one\ntwo\n\nfour";
    var offset: u32 = 0;
    while (offset <= text.len) : (offset += 1) {
        const pos = try index.positionOf(gpa, text, offset);
        try std.testing.expectEqual(offset, try index.offsetOf(gpa, text, pos));
    }
    try std.testing.expectError(error.InvalidPosition, index.positionOf(gpa, text, text.len + 1));
}

test "invalidate 之后与全量扫描结果一致" {
    const gpa = std.testing.allocator;
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(gpa);
    try buffer.appendSlice(gpa, "one\ntwo\nthree\nfour");

    var index: LineIndex = .{};
    defer index.deinit(gpa);
    _ = try index.lineCount(gpa, buffer.items);

    // 删掉 "two\n"，等价于在偏移 4 处做一次编辑
    buffer.replaceRangeAssumeCapacity(4, 4, "");
    index.invalidate(4);

    var fresh: LineIndex = .{};
    defer fresh.deinit(gpa);
    const count = try fresh.lineCount(gpa, buffer.items);
    try std.testing.expectEqual(count, try index.lineCount(gpa, buffer.items));
    var line: u32 = 0;
    while (line < count) : (line += 1) {
        try std.testing.expectEqual(try fresh.lineRange(gpa, buffer.items, line), try index.lineRange(gpa, buffer.items, line));
    }
}

test "未扫描到编辑点时水位不回退" {
    const gpa = std.testing.allocator;
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(gpa);
    try buffer.appendSlice(gpa, "a\nb\nc\nd");

    var index: LineIndex = .{};
    defer index.deinit(gpa);
    // 只扫描前两个字节，水位停在 2
    _ = try index.lineOf(gpa, buffer.items[0..2], 1);
    try std.testing.expectEqual(@as(u32, 2), index.scanned);

    // 在两段未扫描区域之间插入换行，水位不得越过未扫描的字节
    buffer.replaceRangeAssumeCapacity(2, 0, "\n");
    index.invalidate(2);
    try std.testing.expectEqual(@as(u32, 2), index.scanned);

    var fresh: LineIndex = .{};
    defer fresh.deinit(gpa);
    try std.testing.expectEqual(try fresh.lineCount(gpa, buffer.items), try index.lineCount(gpa, buffer.items));
}

test "扫描在任意分配失败点上不重复追加" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, scanAll, .{});
}

fn scanAll(gpa: std.mem.Allocator) !void {
    var index: LineIndex = .{};
    defer index.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 4), try index.lineCount(gpa, "a\nb\nc\n"));
    try std.testing.expectEqual(TextRange{ .start = 2, .end = 4 }, try index.lineRange(gpa, "a\nb\nc\n", 1));
}

test "扫描失败之后重试不会重写已有行首" {
    const gpa = std.testing.allocator;
    const text = "a\nb\nc\n";

    var index: LineIndex = .{};
    defer index.deinit(gpa);

    // 行首数组的全部内存来自一次 ensureUnusedCapacity，让这次分配失败
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, index.lineCount(failing.allocator(), text));
    try std.testing.expectEqual(@as(usize, 0), index.starts.items.len);
    try std.testing.expectEqual(@as(u32, 0), index.scanned);

    try std.testing.expectEqual(@as(u32, 4), try index.lineCount(gpa, text));
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 4, 6 }, index.starts.items);
}

test "向量扫描与逐字节扫描结果一致" {
    if (!use_simd) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const lengths = [_]usize{ 0, 1, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 100 };
    const step = [_]usize{ 1, 2, 3, 5, 7 };

    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(gpa);

    for (lengths) |length| {
        for (step) |stride| {
            source.clearRetainingCapacity();
            try source.ensureTotalCapacity(gpa, length);
            for (0..length) |i| {
                try source.append(gpa, if (i % stride == 0) newline else 'x');
            }

            var vector_starts: std.ArrayListUnmanaged(u32) = .empty;
            defer vector_starts.deinit(gpa);
            try vector_starts.ensureTotalCapacity(gpa, VectorScanner.count(source.items));
            VectorScanner.append(&vector_starts, 0, source.items);

            var byte_starts: std.ArrayListUnmanaged(u32) = .empty;
            defer byte_starts.deinit(gpa);
            try byte_starts.ensureTotalCapacity(gpa, ByteScanner.count(source.items));
            ByteScanner.append(&byte_starts, 0, source.items);

            try std.testing.expectEqual(ByteScanner.count(source.items), VectorScanner.count(source.items));
            try std.testing.expectEqualSlices(u32, byte_starts.items, vector_starts.items);
        }
    }
}

test "扫描起点不在块边界上时结果仍然正确" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, scanInTwoChunks, .{});
}

fn scanInTwoChunks(gpa: std.mem.Allocator) !void {
    if (!use_simd) return;

    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(gpa);
    for (0..VectorScanner.block_len * 3 + 5) |i| {
        try buffer.append(gpa, if (i % 4 == 3) newline else 'x');
    }

    var fresh: LineIndex = .{};
    defer fresh.deinit(gpa);
    const expected = try fresh.lineCount(gpa, buffer.items);

    var index: LineIndex = .{};
    defer index.deinit(gpa);
    // 先用短前缀推进水位，让后续扫描的起点落在块内部的任意位置
    _ = try index.lineCount(gpa, buffer.items[0..3]);
    try std.testing.expectEqual(expected, try index.lineCount(gpa, buffer.items));
    try std.testing.expectEqualSlices(u32, fresh.starts.items, index.starts.items);
}

test "末尾追加只扫描新增部分" {
    const gpa = std.testing.allocator;
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(gpa);
    try buffer.appendSlice(gpa, "a\nb");

    var index: LineIndex = .{};
    defer index.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), try index.lineCount(gpa, buffer.items));

    try buffer.appendSlice(gpa, "\nc\nd");
    index.invalidate(@intCast(buffer.items.len - 4));

    try std.testing.expectEqual(@as(u32, 4), try index.lineCount(gpa, buffer.items));
    try std.testing.expectEqual(TextRange{ .start = 2, .end = 4 }, try index.lineRange(gpa, buffer.items, 1));
    try std.testing.expectEqual(TextRange{ .start = 4, .end = 6 }, try index.lineRange(gpa, buffer.items, 2));
    try std.testing.expectEqual(TextRange{ .start = 6, .end = 7 }, try index.lineRange(gpa, buffer.items, 3));
}
