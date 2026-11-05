//! 供其它项目依赖的公共库。

const std = @import("std");

/// 解析器前端与公共库之间的通用错误集合。
pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEndOfInput,
    InvalidCharacter,
};

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "add" {
    try std.testing.expectEqual(@as(i32, 10), add(3, 7));
}
