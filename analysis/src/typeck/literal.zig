// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 未加后缀数值字面量（`IdealInt` / `IdealFloat`）解析与溢出范围校验。

const std = @import("std");
const ids = @import("../ids.zig");
const type_interner_mod = @import("../interner/TypeInterner.zig");

const PrimKind = ids.PrimKind;
const TargetConfig = type_interner_mod.TargetConfig;
const TypeId = ids.TypeId;
const TypeInterner = type_interner_mod.TypeInterner;

/// 数值字面量范围校验结果。
pub const LiteralRangeStatus = enum(u8) {
    ok,
    int_out_of_range,
    float_overflow,
    float_underflow_to_zero,
};

/// 去掉整数字面量源码文本中的类型后缀与下划线分隔符，解析其无符号幅值与进制。
/// 支持二进制 `0b`、八进制 `0o`、十六进制 `0x` 与十进制。
pub fn parseIntegerMagnitude(text: []const u8) ?u128 {
    if (text.len == 0) return null;
    var end: usize = text.len;
    // 剥离尾部类型后缀（如 i8、i16、i32、i64、u8、u16、u32、u64）
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (i >= 2 and (text[0] == '0' and (text[1] == 'x' or text[1] == 'X'))) {
            if (text[i] == 'i' or text[i] == 'u') {
                end = i;
                break;
            }
        } else if (text[i] == 'i' or text[i] == 'u') {
            end = i;
            break;
        }
    }
    var body = text[0..end];
    var base: u128 = 10;
    if (body.len >= 2 and body[0] == '0') {
        switch (body[1]) {
            'b', 'B' => {
                base = 2;
                body = body[2..];
            },
            'o', 'O' => {
                base = 8;
                body = body[2..];
            },
            'x', 'X' => {
                base = 16;
                body = body[2..];
            },
            else => {},
        }
    }

    var value: u128 = 0;
    var has_digit = false;
    for (body) |ch| {
        if (ch == '_') continue;
        const digit: u128 = switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => return null,
        };
        if (digit >= base) return null;
        has_digit = true;
        const mul = @mulWithOverflow(value, base);
        if (mul[1] != 0) return std.math.maxInt(u128);
        const add = @addWithOverflow(mul[0], digit);
        if (add[1] != 0) return std.math.maxInt(u128);
        value = add[0];
    }
    return if (has_digit) value else null;
}

/// 根据 `TargetConfig` 校验整数或浮点字面量源码文本是否位于具体 `PrimKind` 或 `Ideal` 宽范围 `[INT64_MIN, UINT64_MAX]` 内。
pub fn checkNumericLiteralRange(
    target: TargetConfig,
    text: []const u8,
    is_negated: bool,
    ty: TypeId,
) LiteralRangeStatus {
    if (ty == TypeInterner.ideal_int_ty) {
        const mag = parseIntegerMagnitude(text) orelse return .ok;
        if (is_negated) {
            return if (mag <= @as(u128, @intCast(std.math.maxInt(i64))) + 1) .ok else .int_out_of_range;
        }
        return if (mag <= std.math.maxInt(u64)) .ok else .int_out_of_range;
    }
    if (ty == TypeInterner.ideal_float_ty) {
        return checkFloatRange(text, .float64);
    }

    const kind: PrimKind = switch (ty) {
        TypeInterner.int8_ty => .int8,
        TypeInterner.int16_ty => .int16,
        TypeInterner.int32_ty => .int32,
        TypeInterner.int64_ty => .int64,
        TypeInterner.int_native_ty => .int_native,
        TypeInterner.uint8_ty => .uint8,
        TypeInterner.uint16_ty => .uint16,
        TypeInterner.uint32_ty => .uint32,
        TypeInterner.uint64_ty => .uint64,
        TypeInterner.uint_native_ty => .uint_native,
        TypeInterner.float16_ty => .float16,
        TypeInterner.float32_ty => .float32,
        TypeInterner.float64_ty => .float64,
        else => return .ok,
    };

    if (kind.isFloat()) return checkFloatRange(text, kind);

    const mag = parseIntegerMagnitude(text) orelse return .ok;
    const bits: u7 = switch (kind) {
        .int8, .uint8 => 8,
        .int16, .uint16 => 16,
        .int32, .uint32 => 32,
        .int64, .uint64 => 64,
        .int_native, .uint_native => @intCast(@backingInt(target.pointer_width)),
        else => return .ok,
    };

    if (kind.isUnsignedInt()) {
        if (is_negated and mag > 0) return .int_out_of_range;
        const max_u: u128 = (@as(u128, 1) << bits) - 1;
        return if (mag <= max_u) .ok else .int_out_of_range;
    }

    const max_pos: u128 = (@as(u128, 1) << (bits - 1)) - 1;
    const max_neg: u128 = @as(u128, 1) << (bits - 1);
    return if (is_negated)
        (if (mag <= max_neg) .ok else .int_out_of_range)
    else
        (if (mag <= max_pos) .ok else .int_out_of_range);
}

/// 校验浮点字面量在目标 IEEE 754 精度下是否上溢为无穷或非零下溢归零。
fn checkFloatRange(text: []const u8, kind: PrimKind) LiteralRangeStatus {
    var clean_buf: [256]u8 = undefined;
    var len: usize = 0;
    var end: usize = text.len;
    if (std.mem.endsWith(u8, text, "f16") or std.mem.endsWith(u8, text, "f32") or std.mem.endsWith(u8, text, "f64")) {
        end -= 3;
    }
    var has_nonzero = false;
    var in_exponent = false;
    for (text[0..end]) |ch| {
        if (ch == '_') continue;
        if (ch == 'e' or ch == 'E' or ch == 'p' or ch == 'P') in_exponent = true;
        if (!in_exponent and ((ch >= '1' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F'))) {
            has_nonzero = true;
        }
        if (len >= clean_buf.len) return .ok;
        clean_buf[len] = ch;
        len += 1;
    }
    const clean = clean_buf[0..len];
    if (clean.len == 0) return .ok;
    const val = std.fmt.parseFloat(f64, clean) catch return .ok;
    if (std.math.isInf(val)) return .float_overflow;
    if (has_nonzero and val == 0.0) return .float_underflow_to_zero;

    switch (kind) {
        .float16 => {
            const abs_v = @abs(val);
            if (abs_v > 65504.0) return .float_overflow;
            if (has_nonzero and abs_v < 5.960464477539063e-8) return .float_underflow_to_zero;
        },
        .float32 => {
            const f32_v: f32 = @floatCast(val);
            if (std.math.isInf(f32_v)) return .float_overflow;
            if (has_nonzero and f32_v == 0.0) return .float_underflow_to_zero;
        },
        .float64 => {},
        else => {},
    }
    return .ok;
}

/// 比较两个数值类型的重载优先级（对应 `cangjie_compiler` 的 `CompareIntAndFloat`）：
/// `Int64` 优于其他整数、整数优于浮点、`Float64` 优于其他浮点。
pub fn compareNumericPriority(a: PrimKind, b: PrimKind) std.math.Order {
    if (a == b) return .eq;
    if (a.isInteger() and b.isFloat()) return .lt;
    if (a.isFloat() and b.isInteger()) return .gt;
    if (a == .int64 and b.isInteger()) return .lt;
    if (b == .int64 and a.isInteger()) return .gt;
    if (a == .float64 and b.isFloat()) return .lt;
    if (b == .float64 and a.isFloat()) return .gt;
    return .eq;
}

test "checkNumericLiteralRange 支持 32/64 位 IntNative 与边界范围" {
    try std.testing.expectEqual(LiteralRangeStatus.ok, checkNumericLiteralRange(.{}, "127", false, TypeInterner.int8_ty));
    try std.testing.expectEqual(LiteralRangeStatus.int_out_of_range, checkNumericLiteralRange(.{}, "128", false, TypeInterner.int8_ty));
    try std.testing.expectEqual(LiteralRangeStatus.ok, checkNumericLiteralRange(.{}, "128", true, TypeInterner.int8_ty));
    try std.testing.expectEqual(LiteralRangeStatus.int_out_of_range, checkNumericLiteralRange(.{}, "1", true, TypeInterner.uint8_ty));
    try std.testing.expectEqual(
        LiteralRangeStatus.int_out_of_range,
        checkNumericLiteralRange(.{ .pointer_width = .bits32 }, "3000000000", false, TypeInterner.int_native_ty),
    );
    try std.testing.expectEqual(
        LiteralRangeStatus.ok,
        checkNumericLiteralRange(.{ .pointer_width = .bits64 }, "3000000000", false, TypeInterner.int_native_ty),
    );
    try std.testing.expectEqual(LiteralRangeStatus.ok, checkNumericLiteralRange(.{}, "0xFF_FF", false, TypeInterner.uint16_ty));
    try std.testing.expectEqual(LiteralRangeStatus.float_overflow, checkNumericLiteralRange(.{}, "1e100", false, TypeInterner.float32_ty));
}
