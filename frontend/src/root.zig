//! 解析器前端的库入口，供 `cjparser_test` 以及其它项目依赖。

const std = @import("std");
const common = @import("common");

pub const ParseError = common.ParseError;

/// 词法单元类别。
pub const TokenKind = enum {
    identifier,
    number,
    punctuation,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
};

fn isPunctuation(c: u8) bool {
    return switch (c) {
        ';', '(', ')', '{', '}', '[', ']', ',', ':', '.', '=', '+', '-', '*', '/', '<', '>', '!', '&', '|' => true,
        else => false,
    };
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) (ParseError || std.mem.Allocator.Error)![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);

    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }

        const start = i;
        if (isWordChar(c)) {
            while (i < source.len and isWordChar(source[i])) : (i += 1) {}
            const text = source[start..i];
            const kind: TokenKind = if (std.ascii.isDigit(text[0])) .number else .identifier;
            try tokens.append(allocator, .{ .kind = kind, .text = text });
            continue;
        }

        if (isPunctuation(c)) {
            i += 1;
            try tokens.append(allocator, .{ .kind = .punctuation, .text = source[start..i] });
            continue;
        }

        return error.InvalidCharacter;
    }

    try tokens.append(allocator, .{ .kind = .eof, .text = source[source.len..] });
    return tokens.toOwnedSlice(allocator);
}

test "tokenize" {
    const allocator = std.testing.allocator;
    const tokens = try tokenize(allocator, "fn main() { let x = 42; }");
    defer allocator.free(tokens);

    const expected: [12]TokenKind = .{
        .identifier, .identifier, .punctuation, .punctuation, .punctuation,
        .identifier,  .identifier, .punctuation, .number,      .punctuation,
        .punctuation, .eof,
    };
    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, tokens) |kind, token| try std.testing.expectEqual(kind, token.kind);

    try std.testing.expectEqualStrings("fn", tokens[0].text);
    try std.testing.expectEqualStrings("42", tokens[8].text);
}

test "tokenizeInvalidCharacter" {
    try std.testing.expectError(error.InvalidCharacter, tokenize(std.testing.allocator, "main@"));
}

test "tokenizeEmptySource" {
    const allocator = std.testing.allocator;
    const tokens = try tokenize(allocator, "");
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqual(TokenKind.eof, tokens[0].kind);
}
