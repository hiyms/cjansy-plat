const std = @import("std");
const common = @import("common");
const TokenTag = common.TokenTag;

/// 标识符的首字符。规则来自 `cangjie_deveco_plugins` 的 `DeclarationLexer.g4`：
///
/// ```antlr
/// Identifier
///     : (Letter | '_' | [\p{XID_Start}]) (Letter | '_' | DecimalDigit | [\p{XID_Continue}])*
///     ;
/// fragment Letter
///     : [a-zA-Z] | ~[\u0000-\u00FF\uD800-\uDBFF] | [\uD800-\uDBFF] [\uDC00-\uDFFF] | '·'
///     ;
/// ```
///
/// `Letter` 已覆盖 u0000 到 u00FF 之外的全部非代理项码点，所以只有 u0080 到 u00FF
/// 这一段需要按 `XID_Start` 逐个对应：那一区间的 `XID_Start` 是 `ª`、`µ`、`º` 三个
/// 单独码点，加上 `U+00C0`–`U+00D6`、`U+00D8`–`U+00F6`、`U+00F8`–`U+00FF` 三段。
fn isIdentifierStart(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isAlphabetic(@intCast(cp)) or cp == '_';

    if (cp < 0x100) return switch (cp) {
        // `ª`、`µ`、`º` 来自 `XID_Start`，`·` 来自 `Letter`
        0xaa, 0xb5, 0xb7, 0xba => true,
        0xc0...0xd6, 0xd8...0xf6, 0xf8...0xff => true,
        else => false,
    };

    return !common.utf8.isSurrogate(cp);
}

/// 标识符的后续字符。`XID_Continue` 在 u0080 以下多出的只有数字与 `·`，数字归 ASCII 分支，
/// `·` 已算在首字符集里，因此非 ASCII 部分与首字符一致。
fn isIdentifierContinue(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_';

    return isIdentifierStart(cp);
}

/// 水平空白：空格、制表符、换页符。换行由 `TokenTag.nl` 单独表示，不在这里消费。
inline fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\x0c';
}

/// 关键字表。标识符按最长匹配扫描完成之后才整词比较，`island` 不会命中 `is`。
///
/// 键与 `TokenTag` 中 `kw_` 开头的成员一一对应，字面量取该成员的文档注释；
/// 另外三项也按标识符形态参与查表：`_`（`wildcard`）、`true` 与 `false`（`bool_literal`）。
/// `!in` 与 `<:` 不是标识符形态，由各自的符号分支产生。
const keywords = std.StaticStringMap(TokenTag).initComptime(.{
    // 运算符形式的关键字
    .{ "is", TokenTag.kw_is },
    .{ "as", TokenTag.kw_as },

    // 内置类型
    .{ "Int8", TokenTag.kw_int8 },
    .{ "Int16", TokenTag.kw_int16 },
    .{ "Int32", TokenTag.kw_int32 },
    .{ "Int64", TokenTag.kw_int64 },
    .{ "IntNative", TokenTag.kw_int_native },
    .{ "UInt8", TokenTag.kw_uint8 },
    .{ "UInt16", TokenTag.kw_uint16 },
    .{ "UInt32", TokenTag.kw_uint32 },
    .{ "UInt64", TokenTag.kw_uint64 },
    .{ "UIntNative", TokenTag.kw_uint_native },
    .{ "Float16", TokenTag.kw_float16 },
    .{ "Float32", TokenTag.kw_float32 },
    .{ "Float64", TokenTag.kw_float64 },
    .{ "Rune", TokenTag.kw_rune },
    .{ "Bool", TokenTag.kw_bool },
    .{ "Nothing", TokenTag.kw_nothing },
    .{ "Unit", TokenTag.kw_unit },
    .{ "VArray", TokenTag.kw_varray },
    .{ "This", TokenTag.kw_this_type },

    // 声明
    .{ "package", TokenTag.kw_package },
    .{ "import", TokenTag.kw_import },
    .{ "class", TokenTag.kw_class },
    .{ "interface", TokenTag.kw_interface },
    .{ "struct", TokenTag.kw_struct },
    .{ "enum", TokenTag.kw_enum },
    .{ "func", TokenTag.kw_func },
    .{ "main", TokenTag.kw_main },
    .{ "macro", TokenTag.kw_macro },
    .{ "quote", TokenTag.kw_quote },
    .{ "let", TokenTag.kw_let },
    .{ "var", TokenTag.kw_var },
    .{ "const", TokenTag.kw_const },
    .{ "type", TokenTag.kw_type },
    .{ "init", TokenTag.kw_init },
    .{ "prop", TokenTag.kw_prop },
    .{ "extend", TokenTag.kw_extend },
    .{ "foreign", TokenTag.kw_foreign },

    // 修饰符与访问控制
    .{ "static", TokenTag.kw_static },
    .{ "public", TokenTag.kw_public },
    .{ "private", TokenTag.kw_private },
    .{ "internal", TokenTag.kw_internal },
    .{ "protected", TokenTag.kw_protected },
    .{ "override", TokenTag.kw_override },
    .{ "redef", TokenTag.kw_redef },
    .{ "abstract", TokenTag.kw_abstract },
    .{ "sealed", TokenTag.kw_sealed },
    .{ "open", TokenTag.kw_open },
    .{ "inout", TokenTag.kw_inout },
    .{ "mut", TokenTag.kw_mut },
    .{ "unsafe", TokenTag.kw_unsafe },
    .{ "operator", TokenTag.kw_operator },

    // 表达式与语句
    .{ "this", TokenTag.kw_this },
    .{ "super", TokenTag.kw_super },
    .{ "if", TokenTag.kw_if },
    .{ "else", TokenTag.kw_else },
    .{ "case", TokenTag.kw_case },
    .{ "match", TokenTag.kw_match },
    .{ "where", TokenTag.kw_where },
    .{ "try", TokenTag.kw_try },
    .{ "catch", TokenTag.kw_catch },
    .{ "finally", TokenTag.kw_finally },
    .{ "for", TokenTag.kw_for },
    .{ "in", TokenTag.kw_in },
    .{ "do", TokenTag.kw_do },
    .{ "while", TokenTag.kw_while },
    .{ "break", TokenTag.kw_break },
    .{ "continue", TokenTag.kw_continue },
    .{ "return", TokenTag.kw_return },
    .{ "throw", TokenTag.kw_throw },
    .{ "spawn", TokenTag.kw_spawn },
    .{ "synchronized", TokenTag.kw_synchronized },
    .{ "with", TokenTag.kw_with },
    .{ "perform", TokenTag.kw_perform },
    .{ "resume", TokenTag.kw_resume },
    .{ "throwing", TokenTag.kw_throwing },
    .{ "handle", TokenTag.kw_handle },

    // 标识符形态的其余词法单元
    .{ "_", TokenTag.wildcard },
    .{ "true", TokenTag.bool_literal },
    .{ "false", TokenTag.bool_literal },
});

const Lexer = struct {
    raw: []const u8,
    index: u32,

    inline fn new(source: []const u8) Lexer {
        return .{ .raw = source, .index = 0 };
    }

    inline fn next(self: *@This()) !u8 {
        const result = self.peek(0);
        self.push(1);
        return result;
    }

    inline fn push(self: *@This(), n: comptime_int) void {
        std.debug.assert(self.can_push(n));

        self.index += n;
    }

    inline fn can_push(self: *const @This(), n: comptime_int) bool {
        return self.raw.len >= self.index + n;
    }

    inline fn peek(self: *const @This(), comptime n: u32) u8 {
        std.debug.assert(self.raw.len >= self.index + n);
        return self.raw[self.index + n];
    }

    /// 解码当前位置的码点，不移动游标。
    fn peekCodepoint(self: *const @This()) ?common.utf8.Codepoint {
        return common.utf8.decodeAt(self.raw, self.index);
    }

    /// 扫描一个完整标识符，返回其区间。调用前 `index` 必须指向标识符的首字符。
    ///
    /// 按最长匹配前进：`island` 整体是一个标识符，不会停在 `is`。区间是扫描前后的
    /// `index`，左闭右开。非 ASCII 字符按码点整体消费，不会在 UTF-8 序列中间停下。
    pub fn scanIdentifier(self: *@This()) common.Span {
        const start = self.index;
        const first = self.peekCodepoint() orelse unreachable;
        std.debug.assert(isIdentifierStart(first.value));
        self.index += @intCast(first.len);

        while (self.peekCodepoint()) |cp| {
            if (!isIdentifierContinue(cp.value)) break;
            self.index += @intCast(cp.len);
        }

        return .{ .start = start, .end = self.index };
    }

    /// 扫描一段连续空白，返回其区间。调用前 `index` 必须指向空白字节。
    ///
    /// 换行不在扫描范围内，扫描停在 `\n`、`\r` 或任何非空白字节之前。
    pub fn scanWhitespace(self: *@This()) common.Span {
        std.debug.assert(self.can_push(1));
        std.debug.assert(isWhitespace(self.peek(0)));

        const start = self.index;
        while (self.can_push(1) and isWhitespace(self.peek(0))) self.push(1);

        return .{ .start = start, .end = self.index };
    }

    pub fn gen(self: *@This()) !common.Token {
        const start = self.index;

        const tok: TokenTag = if (self.peekCodepoint()) |cp| blk: {
            if (isIdentifierStart(cp.value)) {
                const span = self.scanIdentifier();
                break :blk keywords.get(self.raw[span.start..span.end]) orelse TokenTag.identifier;
            }

            if (cp.value < 0x80) {
                break :blk switch (try self.next()) {
                    '.' => TokenTag.dot,
                    ',' => TokenTag.comma,
                    '(' => TokenTag.l_paren,
                    ')' => TokenTag.r_paren,
                    '[' => TokenTag.l_square,
                    ']' => TokenTag.r_square,
                    '{' => TokenTag.l_curl,
                    '}' => TokenTag.r_curl,
                    ';' => TokenTag.semi,
                    '#' => TokenTag.hash,
                    '?' => TokenTag.quest,
                    '>' => TokenTag.greater,
                    '\n' => TokenTag.nl,
                    else => TokenTag.illegal,
                };
            }

            // 非 ASCII 的非标识符码点整体消费，避免把一个码点切成多个非法词法单元
            self.index += @intCast(cp.len);
            break :blk TokenTag.illegal;
        } else if (self.index < self.raw.len) blk: {
            // 非法 UTF-8：跳过一个字节继续，后续字节可能是合法文本
            self.index += 1;
            break :blk TokenTag.illegal;
        } else TokenTag.end;

        const end = self.index;
        return .{ .span = .{ .start = start, .end = end }, .tag = tok };
    }
};

pub const t = Lexer;

fn verify_token_kind(lexer_result: []const common.Token, hope_kind: []const common.TokenTag) !void {
    errdefer {
        std.testing.failPrint(
            "",
        );
    }

    try std.testing.expectEqual(lexer_result.len, lexer_result.len);

    for (lexer_result[0..], hope_kind[0..]) |r, hope| {
        try std.testing.expectEqual(r.tag, hope);
    }
}

test "Simple Token Lexer" {
    const src = "as";
    var lexer = Lexer.new(src);
    const result = try lexer.gen();

    try std.testing.expectEqual(common.TokenTag.kw_as, result.tag);
    try std.testing.expectEqual(common.Span{ .start = 0, .end = 2 }, result.span);
}

test "关键字按整词识别" {
    const cases = [_]struct { src: []const u8, tag: common.TokenTag }{
        .{ .src = "is", .tag = .kw_is },
        .{ .src = "as", .tag = .kw_as },
        .{ .src = "land", .tag = .identifier },
        .{ .src = "async", .tag = .identifier },
        .{ .src = "island", .tag = .identifier },
        .{ .src = "Is", .tag = .identifier },
        .{ .src = "asis", .tag = .identifier },
    };

    for (cases) |case| {
        var lexer = Lexer.new(case.src);
        const token = try lexer.gen();

        try std.testing.expectEqual(case.tag, token.tag);
        try std.testing.expectEqual(common.Span{ .start = 0, .end = @intCast(case.src.len) }, token.span);
    }
}

test "关键字前缀长于关键字时归为标识符" {
    const src = "async";
    var lexer = Lexer.new(src);
    const token = try lexer.gen();

    try std.testing.expectEqual(common.TokenTag.identifier, token.tag);
    try std.testing.expectEqual(common.Span{ .start = 0, .end = 5 }, token.span);
}

test "源文件末尾的单字符标识符" {
    const src = "i";
    var lexer = Lexer.new(src);
    const token = try lexer.gen();

    try std.testing.expectEqual(common.TokenTag.identifier, token.tag);
    try std.testing.expectEqual(common.Span{ .start = 0, .end = 1 }, token.span);
}

test "关键字表覆盖 TokenTag 里全部标识符形态的关键字" {
    // `kw_not_in` 的字面量是 `!in`，`upperbound` 的是 `<:`，两者都不是标识符形态
    const excluded = [_]TokenTag{ .kw_not_in, .upperbound };

    for (std.enums.values(TokenTag)) |tag| {
        const name = @tagName(tag);
        if (!std.mem.startsWith(u8, name, "kw_")) continue;
        if (std.mem.indexOfScalar(TokenTag, &excluded, tag) != null) continue;

        var found = false;
        for (keywords.keys()) |key| {
            if (keywords.get(key).? == tag) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "关键字表的每一项都能被 gen 识别" {
    for (keywords.keys()) |key| {
        var lexer = Lexer.new(key);
        const token = try lexer.gen();

        try std.testing.expectEqual(keywords.get(key).?, token.tag);
        try std.testing.expectEqual(common.Span{ .start = 0, .end = @intCast(key.len) }, token.span);
    }
}

test "关键字后紧跟标识符字符时归为标识符" {
    const allocator = std.testing.allocator;

    for (keywords.keys()) |key| {
        const src = try std.fmt.allocPrint(allocator, "{s}x", .{key});
        defer allocator.free(src);

        var lexer = Lexer.new(src);
        const token = try lexer.gen();

        try std.testing.expectEqual(TokenTag.identifier, token.tag);
        try std.testing.expectEqual(common.Span{ .start = 0, .end = @intCast(src.len) }, token.span);
    }
}

test "内置类型关键字区分大小写" {
    const cases = [_]struct { src: []const u8, tag: TokenTag }{
        .{ .src = "Int64", .tag = .kw_int64 },
        .{ .src = "int64", .tag = .identifier },
        .{ .src = "This", .tag = .kw_this_type },
        .{ .src = "this", .tag = .kw_this },
        .{ .src = "VArray", .tag = .kw_varray },
        .{ .src = "varray", .tag = .identifier },
        .{ .src = "UIntNative", .tag = .kw_uint_native },
        .{ .src = "Bool", .tag = .kw_bool },
        .{ .src = "Nothing", .tag = .kw_nothing },
        .{ .src = "Unit", .tag = .kw_unit },
    };

    for (cases) |case| {
        var lexer = Lexer.new(case.src);
        const token = try lexer.gen();

        try std.testing.expectEqual(case.tag, token.tag);
    }
}

test "单个下划线是占位符，带后缀时是标识符" {
    const cases = [_]struct { src: []const u8, tag: TokenTag }{
        .{ .src = "_", .tag = .wildcard },
        .{ .src = "_x", .tag = .identifier },
        .{ .src = "__", .tag = .identifier },
        .{ .src = "x_", .tag = .identifier },
    };

    for (cases) |case| {
        var lexer = Lexer.new(case.src);
        const token = try lexer.gen();

        try std.testing.expectEqual(case.tag, token.tag);
    }
}

test "布尔字面量" {
    const cases = [_]struct { src: []const u8, tag: TokenTag }{
        .{ .src = "true", .tag = .bool_literal },
        .{ .src = "false", .tag = .bool_literal },
        .{ .src = "True", .tag = .identifier },
        .{ .src = "truely", .tag = .identifier },
    };

    for (cases) |case| {
        var lexer = Lexer.new(case.src);
        const token = try lexer.gen();

        try std.testing.expectEqual(case.tag, token.tag);
    }
}

test "扫描完整标识符取最长匹配" {
    const src = "island";
    var lexer = Lexer.new(src);

    try std.testing.expectEqual(common.Span{ .start = 0, .end = 6 }, lexer.scanIdentifier());
    try std.testing.expectEqual(@as(u32, 6), lexer.index);
}

test "标识符扫描覆盖下划线开头与数字结尾" {
    const src = "_a1";
    var lexer = Lexer.new(src);

    try std.testing.expectEqual(common.Span{ .start = 0, .end = 3 }, lexer.scanIdentifier());
}

test "标识符扫描停在非标识符字节" {
    const src = "foo.bar";
    var lexer = Lexer.new(src);

    try std.testing.expectEqual(common.Span{ .start = 0, .end = 3 }, lexer.scanIdentifier());
    try std.testing.expectEqual(@as(u8, '.'), lexer.peek(0));
}

test "标识符扫描在源文件末尾结束" {
    const src = "i";
    var lexer = Lexer.new(src);

    try std.testing.expectEqual(common.Span{ .start = 0, .end = 1 }, lexer.scanIdentifier());
    try std.testing.expectEqual(@as(u32, 1), lexer.index);
}

test "扫描连续空白" {
    const src = "  \t\x0c;";
    var lexer = Lexer.new(src);

    try std.testing.expectEqual(common.Span{ .start = 0, .end = 4 }, lexer.scanWhitespace());
    try std.testing.expectEqual(@as(u8, ';'), lexer.peek(0));
}

test "空白扫描停在换行之前" {
    const src = "  \n";
    var lexer = Lexer.new(src);

    try std.testing.expectEqual(common.Span{ .start = 0, .end = 2 }, lexer.scanWhitespace());
    try std.testing.expectEqual(@as(u8, '\n'), lexer.peek(0));
}

test "空白扫描在源文件末尾结束" {
    const src = " ";
    var lexer = Lexer.new(src);

    try std.testing.expectEqual(common.Span{ .start = 0, .end = 1 }, lexer.scanWhitespace());
    try std.testing.expectEqual(@as(u32, 1), lexer.index);
}

test "非 ASCII 标识符按码点整体扫描" {
    const cases = [_]struct { src: []const u8, end: u32 }{
        // 中文、含数字的混排、希腊字母
        .{ .src = "变量", .end = 6 },
        .{ .src = "名字1", .end = 7 },
        .{ .src = "λx", .end = 3 },
        // U+00C0 与 U+00FF 是 `Letter` 覆盖的拉丁补充字母
        .{ .src = "\u{00c0}", .end = 2 },
        .{ .src = "\u{00ff}", .end = 2 },
        // `ª` `µ` `º` 来自 `XID_Start`，`·` 来自 `Letter`
        .{ .src = "\u{00aa}x", .end = 3 },
        .{ .src = "\u{00b5}x", .end = 3 },
        .{ .src = "\u{00ba}x", .end = 3 },
        .{ .src = "a\u{00b7}b", .end = 4 },
    };

    for (cases) |case| {
        var lexer = Lexer.new(case.src);
        const token = try lexer.gen();

        try std.testing.expectEqual(common.TokenTag.identifier, token.tag);
        try std.testing.expectEqual(common.Span{ .start = 0, .end = case.end }, token.span);
    }
}

test "u0080 到 u00FF 之间的非标识符码点整体成为非法词法单元" {
    const cases = [_]struct { src: []const u8, end: u32 }{
        // 控制字符与分隔符不与 `Letter` 重叠
        .{ .src = "\u{0080}", .end = 2 },
        .{ .src = "\u{00a0}", .end = 2 },
        .{ .src = "\u{00a1}", .end = 2 },
        .{ .src = "\u{00a9}", .end = 2 },
        .{ .src = "\u{00b0}", .end = 2 },
        .{ .src = "\u{00d7}", .end = 2 },
        .{ .src = "\u{00f7}", .end = 2 },
    };

    for (cases) |case| {
        var lexer = Lexer.new(case.src);
        const token = try lexer.gen();

        try std.testing.expectEqual(common.TokenTag.illegal, token.tag);
        try std.testing.expectEqual(common.Span{ .start = 0, .end = case.end }, token.span);
    }
}

test "非标识符的非 ASCII 码点不被拆成多个词法单元" {
    // U+00A9 占用两个字节，一次 `gen` 应当整体交付
    const src = "\u{00a9}a";
    var lexer = Lexer.new(src);

    const first = try lexer.gen();
    try std.testing.expectEqual(common.TokenTag.illegal, first.tag);
    try std.testing.expectEqual(common.Span{ .start = 0, .end = 2 }, first.span);

    const second = try lexer.gen();
    try std.testing.expectEqual(common.TokenTag.identifier, second.tag);
    try std.testing.expectEqual(common.Span{ .start = 2, .end = 3 }, second.span);
}

test "u0100 以上的非代理项码点都算标识符字符" {
    // `Letter` 写作 `~[\u0000-\u00FF\uD800-\uDBFF]`，因此表情符号也是标识符字符
    const src = "\u{1f914}a";
    var lexer = Lexer.new(src);

    const token = try lexer.gen();
    try std.testing.expectEqual(common.TokenTag.identifier, token.tag);
    try std.testing.expectEqual(common.Span{ .start = 0, .end = 5 }, token.span);
}

test "代理项码点既不是标识符也不能编码成 UTF-8" {
    try std.testing.expect(!isIdentifierStart(0xd800));
    try std.testing.expect(!isIdentifierStart(0xdfff));
    try std.testing.expect(!isIdentifierContinue(0xd800));
}

test "文本末尾返回 end 词法单元" {
    const src = "ab";
    var lexer = Lexer.new(src);

    _ = try lexer.gen();
    const token = try lexer.gen();

    try std.testing.expectEqual(common.TokenTag.end, token.tag);
    try std.testing.expectEqual(common.Span{ .start = 2, .end = 2 }, token.span);
}

test "空源文件只产生 end 词法单元" {
    var lexer = Lexer.new("");
    const token = try lexer.gen();

    try std.testing.expectEqual(common.TokenTag.end, token.tag);
    try std.testing.expectEqual(common.Span{ .start = 0, .end = 0 }, token.span);
}

test "非法 UTF-8 每次前进一个字节" {
    // 0xFF 不是合法的 UTF-8 首字节
    const src = "\xff\xffa";
    var lexer = Lexer.new(src);

    const first = try lexer.gen();
    try std.testing.expectEqual(common.TokenTag.illegal, first.tag);
    try std.testing.expectEqual(common.Span{ .start = 0, .end = 1 }, first.span);

    const second = try lexer.gen();
    try std.testing.expectEqual(common.TokenTag.illegal, second.tag);
    try std.testing.expectEqual(common.Span{ .start = 1, .end = 2 }, second.span);

    const third = try lexer.gen();
    try std.testing.expectEqual(common.TokenTag.identifier, third.tag);
    try std.testing.expectEqual(common.Span{ .start = 2, .end = 3 }, third.span);
}

test "被截断的 UTF-8 序列在文件末尾不越界" {
    // U+4E2D 的首字节之后直接结束
    const src = "\xe4\xb8";
    var lexer = Lexer.new(src);

    const token = try lexer.gen();
    try std.testing.expectEqual(common.TokenTag.illegal, token.tag);
    try std.testing.expectEqual(common.Span{ .start = 0, .end = 1 }, token.span);
}
