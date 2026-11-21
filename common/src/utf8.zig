//! UTF-8 字节序列解码与 Unicode 码点基础判定。

const std = @import("std");

/// 解码得到的单个 Unicode 码点及其在 UTF-8 字节流中占用的字节数。
pub const Codepoint = struct {
    value: u21,
    len: u3,
};

/// UTF-16 代理项区间（U+D800 到 U+DFFF），这些数值不是合法的 Unicode 标量值。
pub fn isSurrogate(cp: u21) bool {
    return cp >= 0xd800 and cp <= 0xdfff;
}

/// 从字节切片开头解码一个合法的 UTF-8 码点。
///
/// 切片为空、UTF-8 序列非法或末尾被截断时返回 `null`。
pub fn decode(bytes: []const u8) ?Codepoint {
    if (bytes.len == 0) return null;

    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
    if (bytes.len < len) return null;

    const value = std.unicode.utf8Decode(bytes[0..len]) catch return null;
    return .{ .value = value, .len = len };
}

/// 从字节切片的 `index` 偏移处解码一个合法的 UTF-8 码点。
///
/// `index` 越界、UTF-8 序列非法或末尾被截断时返回 `null`。
pub fn decodeAt(bytes: []const u8, index: usize) ?Codepoint {
    if (index >= bytes.len) return null;
    return decode(bytes[index..]);
}

test "解码 ASCII 与多字节 UTF-8 码点" {
    try std.testing.expectEqual(@as(?Codepoint, .{ .value = 'a', .len = 1 }), decode("abc"));
    try std.testing.expectEqual(@as(?Codepoint, .{ .value = 0x00c0, .len = 2 }), decode("\u{00c0}x"));
    try std.testing.expectEqual(@as(?Codepoint, .{ .value = 0x4e2d, .len = 3 }), decode("中文"));
    try std.testing.expectEqual(@as(?Codepoint, .{ .value = 0x1f914, .len = 4 }), decode("\u{1f914}a"));
}

test "按偏移解码 UTF-8 码点" {
    const text = "a中\u{1f914}";
    try std.testing.expectEqual(@as(?Codepoint, .{ .value = 'a', .len = 1 }), decodeAt(text, 0));
    try std.testing.expectEqual(@as(?Codepoint, .{ .value = 0x4e2d, .len = 3 }), decodeAt(text, 1));
    try std.testing.expectEqual(@as(?Codepoint, .{ .value = 0x1f914, .len = 4 }), decodeAt(text, 4));
    try std.testing.expectEqual(@as(?Codepoint, null), decodeAt(text, text.len));
    try std.testing.expectEqual(@as(?Codepoint, null), decodeAt(text, text.len + 1));
}

test "空切片、非法字节与截断序列返回 null" {
    try std.testing.expectEqual(@as(?Codepoint, null), decode(""));
    try std.testing.expectEqual(@as(?Codepoint, null), decode("\xff"));
    try std.testing.expectEqual(@as(?Codepoint, null), decode("\x80"));
    try std.testing.expectEqual(@as(?Codepoint, null), decode("\xe4\xb8"));
    // 过长编码与 UTF-8 编码的代理项（U+D800）均非法
    try std.testing.expectEqual(@as(?Codepoint, null), decode("\xc0\xaf"));
    try std.testing.expectEqual(@as(?Codepoint, null), decode("\xed\xa0\x80"));
}

test "代理项区间判定" {
    try std.testing.expect(!isSurrogate(0xd7ff));
    try std.testing.expect(isSurrogate(0xd800));
    try std.testing.expect(isSurrogate(0xdfff));
    try std.testing.expect(!isSurrogate(0xe000));
}
