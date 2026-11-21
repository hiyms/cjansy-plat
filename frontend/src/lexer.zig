//! 仓颉源码的词法分析器。
//!
//! 产出的词法单元标签以 `common.TokenTag` 为准：
//! - 水平空白（空格、制表符、换页符）在扫描下一词法单元前跳过，换行（`\n`、`\r\n`）产出 `nl`。
//! - `??`、`>>`、`>>=`、`>=`、`()`、`@Name` 按单字符或独立标识符词法单元输出，由语法阶段组合。
//! - 含 `${...}` 插值的单行与多行字符串分别整体产出 `string_literal` 与 `multiline_string`。
//! - 词法非法片段统一产出 `TokenTag.illegal` 并推进游标；超出 `std.math.maxInt(u32)` 长度上限、
//!   游标越界或插值嵌套超出深度上限时返回 `Lexer.Error`。

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
/// `Letter` 已覆盖 u0000 到 u00FF 之外的全部非代理项码点，因此只有 u0080 到 u00FF
/// 这一段需要逐项对应：包含来自 `XID_Start` 的 `ª`、`µ`、`º` 及
/// `U+00C0`–`U+00D6`、`U+00D8`–`U+00F6`、`U+00F8`–`U+00FF` 三段，以及来自 `Letter` 的 `·`（`U+00B7`）。
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

/// 标识符的后续字符。`XID_Continue` 在 u0100 以下多出的只有 ASCII 数字与 `·`（`U+00B7`）；
/// 数字归 ASCII 分支，`·` 已包含在首字符集里，因此非 ASCII 部分与首字符一致。
fn isIdentifierContinue(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_';

    return isIdentifierStart(cp);
}

/// 水平空白：空格、制表符、换页符。换行由 `TokenTag.nl` 单独表示，不在这里消费。
inline fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\x0c';
}

fn isBinDigit(c: u8) bool {
    return c == '0' or c == '1';
}

fn isOctDigit(c: u8) bool {
    return c >= '0' and c <= '7';
}

fn isDecDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return std.ascii.isHex(c);
}

fn isIntegerSuffix(s: []const u8) bool {
    const suffixes = [_][]const u8{ "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64" };
    for (suffixes) |suffix| {
        if (std.mem.eql(u8, s, suffix)) return true;
    }
    return false;
}

fn isFloatSuffix(s: []const u8) bool {
    return std.mem.eql(u8, s, "f16") or std.mem.eql(u8, s, "f32") or std.mem.eql(u8, s, "f64");
}

/// 判定反引号内的文本是否为合法的原始标识符。
///
/// 字符集沿用 `isIdentifierStart` 与 `isIdentifierContinue`，同时排除单独的 `_`。
fn isRawIdentContent(content: []const u8) bool {
    if (content.len == 0 or std.mem.eql(u8, content, "_")) return false;

    const first = common.utf8.decodeAt(content, 0) orelse return false;
    if (!isIdentifierStart(first.value)) return false;

    var pos: usize = first.len;
    while (pos < content.len) {
        const cp = common.utf8.decodeAt(content, pos) orelse return false;
        if (!isIdentifierContinue(cp.value)) return false;
        pos += cp.len;
    }
    return true;
}

/// 判定反引号内的文本是否为合法的包名标识符（如 `a-b.c`）。
///
/// 至少包含 `-` 或 `.` 分隔符，且每个分隔段均非空并由标识符续字符组成。
fn isPackageIdentContent(content: []const u8) bool {
    if (content.len == 0) return false;

    var has_sep = false;
    var seg_len: usize = 0;
    var pos: usize = 0;
    while (pos < content.len) {
        const cp = common.utf8.decodeAt(content, pos) orelse return false;
        if (cp.value == '-' or cp.value == '.') {
            if (seg_len == 0) return false;
            has_sep = true;
            seg_len = 0;
        } else if (isIdentifierContinue(cp.value)) {
            seg_len += 1;
        } else {
            return false;
        }
        pos += cp.len;
    }
    return has_sep and seg_len > 0;
}

/// 关键字表。标识符按最长匹配扫描完成之后才整词比较，`island` 不会命中 `is`。
///
/// 覆盖 `TokenTag` 中需在词法阶段识别的标识符形态 `kw_` 成员：
/// - `kw_not_in`（`!in`）属于符号形态，由 `'!'` 分支产生。
/// - `kw_common`、`kw_specific`、`kw_features` 未收入此表，词法阶段按普通标识符产出。
/// - `_`（`wildcard`）、`true` 与 `false`（`bool_literal`）同样按标识符形态参与查表。
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

/// 字符串插值嵌套深度上限，防止过深嵌套耗尽调用空间。
const max_interpolation_depth: u32 = 128;

/// 仓颉源码的流式词法分析器。
///
/// 按 UTF-8 字节流顺序逐个产出 `common.Token`，每个词法单元仅记录标签与在源码中的
/// 字节区间（`common.Span`，左闭右开），不分配额外内存；`raw` 仅借用外部源码切片，
/// 调用方须保证在 `Lexer` 使用期间底层切片持续有效。
///
/// 使用方式：通过 `new` 创建实例后循环调用 `gen`，直至返回 `TokenTag.end`。
/// 词法非法片段产出 `TokenTag.illegal` 并继续推进游标；超出 `u32` 长度上限、游标越界
/// 或插值嵌套超出深度上限时返回 `Error`。
pub const Lexer = struct {
    /// 无法表示为单个词法单元（包括 `TokenTag.illegal`）的结构性错误。
    pub const Error = error{
        /// 输入源码长度超过 `std.math.maxInt(u32)`，无法用 `common.Span` 表示字节区间。
        SourceTooLarge,
        /// 游标位置越过输入源码末尾。
        InvalidCursor,
        /// 字符串插值嵌套层级超过 `max_interpolation_depth`。
        InterpolationDepthExceeded,
    };

    /// 待扫描的 UTF-8 源码切片（由调用方持有内存，长度不超过 `std.math.maxInt(u32)`）。
    raw: []const u8,
    /// 当前扫描游标所在的字节下标，范围 `0..=raw.len`。
    index: u32,
    /// 记录已确认后无引号的连续 `#` 结束位置，避免连续 `#` 重复前瞻导致二次时间复杂度。
    plain_hash_end: u32 = 0,

    fn validateSourceLen(len: usize) Error!void {
        if (len > std.math.maxInt(u32)) return error.SourceTooLarge;
    }

    /// 创建词法分析器，借用 `source` 切片（不拷贝也不负责释放）。
    ///
    /// 当 `source.len > std.math.maxInt(u32)` 时返回 `error.SourceTooLarge`。
    pub inline fn new(source: []const u8) Error!Lexer {
        try validateSourceLen(source.len);
        return .{ .raw = source, .index = 0 };
    }

    inline fn peekAt(self: *const @This(), offset: usize) ?u8 {
        const pos = std.math.add(usize, self.index, offset) catch return null;
        if (pos >= self.raw.len) return null;
        return self.raw[pos];
    }

    inline fn take(self: *@This(), comptime n: u32, tag: TokenTag) TokenTag {
        std.debug.assert(self.raw.len - self.index >= n);
        self.index += n;
        return tag;
    }

    /// 解码当前位置的码点，不移动游标。
    fn peekCodepoint(self: *const @This()) ?common.utf8.Codepoint {
        return common.utf8.decodeAt(self.raw, self.index);
    }

    /// 解码当前位置向后 `offset` 字节处的码点，不移动游标。
    fn peekCodepointAt(self: *const @This(), offset: usize) ?common.utf8.Codepoint {
        const pos = std.math.add(usize, self.index, offset) catch return null;
        return common.utf8.decodeAt(self.raw, pos);
    }

    /// 按合法 UTF-8 码点前进；遇到非法 UTF-8 字节时前进 1 字节并返回 `false`。
    fn advanceCodepoint(self: *@This()) bool {
        if (self.peekCodepoint()) |cp| {
            self.index += @intCast(cp.len);
            return true;
        }
        self.index += 1;
        return false;
    }

    /// 消费后续连续的标识符续字符，用于标识符尾部、数字后缀或非法数字后的同步恢复。
    fn consumeIdentTrail(self: *@This()) void {
        while (self.peekCodepoint()) |cp| {
            if (!isIdentifierContinue(cp.value)) break;
            self.index += @intCast(cp.len);
        }
    }

    /// 消费满足 `isDigit` 或 `'_'` 的后续字符。
    fn consumeDigits(self: *@This(), comptime isDigit: fn (u8) bool) void {
        while (self.peekAt(0)) |c| {
            if (!isDigit(c) and c != '_') break;
            self.index += 1;
        }
    }

    /// 消费以合法数字开头的数字序列；首字符不合法时消费后续标识符字符并返回 `false`。
    fn consumeDigitFragment(self: *@This(), comptime isDigit: fn (u8) bool) bool {
        const first = self.peekAt(0) orelse return false;
        if (!isDigit(first)) {
            self.consumeIdentTrail();
            return false;
        }
        self.index += 1;
        self.consumeDigits(isDigit);
        return true;
    }

    fn hasDotDigit(self: *const @This(), comptime isDigit: fn (u8) bool) bool {
        if (self.peekAt(0) != '.') return false;
        const after_dot = self.peekAt(1) orelse return false;
        return isDigit(after_dot);
    }

    /// 扫描一个完整标识符，返回其区间。调用前 `index` 必须指向标识符的首字符。
    ///
    /// 按最长匹配前进：`island` 整体是一个标识符，不会停在 `is`。区间是扫描前后的
    /// `index`，左闭右开。非 ASCII 字符按码点整体消费，不会在 UTF-8 序列中间停下。
    fn scanIdentifier(self: *@This()) common.Span {
        const start = self.index;
        const first = self.peekCodepoint() orelse unreachable;
        std.debug.assert(isIdentifierStart(first.value));
        self.index += @intCast(first.len);
        self.consumeIdentTrail();
        return .{ .start = start, .end = self.index };
    }

    /// 扫描一段连续空白，返回其区间。调用前 `index` 必须指向空白字节。
    ///
    /// 换行不在扫描范围内，扫描停在 `\n`、`\r` 或任何非空白字节之前。
    fn scanWhitespace(self: *@This()) common.Span {
        std.debug.assert(self.index < self.raw.len);
        std.debug.assert(isWhitespace(self.raw[self.index]));

        const start = self.index;
        while (self.peekAt(0)) |c| {
            if (!isWhitespace(c)) break;
            self.index += 1;
        }
        return .{ .start = start, .end = self.index };
    }

    /// 扫描单行注释 `//...`，停在换行或文件末尾之前；含非法 UTF-8 字节时返回 `illegal`。
    fn scanLineComment(self: *@This()) TokenTag {
        self.index += 2;
        var valid = true;
        while (self.index < self.raw.len) {
            const c = self.raw[self.index];
            if (c == '\n' or c == '\r') break;
            if (c < 0x80) {
                self.index += 1;
            } else if (!self.advanceCodepoint()) {
                valid = false;
            }
        }
        return if (valid) .comment else .illegal;
    }

    /// 扫描支持嵌套的多行注释 `/* ... */`。
    ///
    /// `allow_newline` 为 `false` 时（单行字符串插值内）遇换行立即停止并返回 `illegal`；
    /// 注释未闭合或含非法 UTF-8 字节时返回 `illegal`。
    fn scanBlockComment(self: *@This(), allow_newline: bool) TokenTag {
        self.index += 2;
        var depth: usize = 1;
        var valid = true;
        while (depth > 0 and self.index < self.raw.len) {
            const c = self.raw[self.index];
            if (!allow_newline and (c == '\n' or c == '\r')) return .illegal;
            if (c == '/' and self.peekAt(1) == '*') {
                depth += 1;
                self.index += 2;
            } else if (c == '*' and self.peekAt(1) == '/') {
                depth -= 1;
                self.index += 2;
            } else if (c < 0x80) {
                self.index += 1;
            } else if (!self.advanceCodepoint()) {
                valid = false;
            }
        }
        return if (depth == 0 and valid) .comment else .illegal;
    }

    /// 扫描反斜杠开头的转义序列，返回是否合法。
    ///
    /// `is_byte` 为 `true` 时按 `ByteEscapeSeq` 校验（排除 `\$`，`\u{...}` 仅允许 1 至 2 位十六进制）。
    fn scanEscapeSeq(self: *@This(), comptime is_byte: bool) bool {
        std.debug.assert(self.peekAt(0) == '\\');
        self.index += 1;

        const c = self.peekAt(0) orelse return false;
        switch (c) {
            't', 'b', 'r', 'n', '\'', '"', '\\', 'f', 'v', '0' => {
                self.index += 1;
                return true;
            },
            '$' => {
                self.index += 1;
                return !is_byte;
            },
            'u' => {
                self.index += 1;
                if (self.peekAt(0) != '{') return false;
                self.index += 1;

                const max_digits: u8 = if (is_byte) 2 else 8;
                var digit_count: u8 = 0;
                var value: u32 = 0;
                while (self.peekAt(0)) |h| {
                    if (!isHexDigit(h)) break;
                    digit_count = digit_count +| 1;
                    const digit: u32 = std.fmt.charToDigit(h, 16) catch unreachable;
                    if (value <= 0x10ffff) {
                        value = (value << 4) | digit;
                    }
                    self.index += 1;
                }

                if (self.peekAt(0) != '}') return false;
                self.index += 1;

                if (digit_count == 0 or digit_count > max_digits) return false;
                if (!is_byte) {
                    if (value > 0x10ffff) return false;
                    if (common.utf8.isSurrogate(@intCast(value))) return false;
                }
                return true;
            },
            '\n', '\r' => return false,
            else => {
                _ = self.advanceCodepoint();
                return false;
            },
        }
    }

    /// 统计当前位置起的连续 `#` 个数及紧随其后是否为引号（`"` 或 `'`）。
    fn scanHashRun(self: *const @This()) struct { count: u32, is_raw_string: bool } {
        var count: usize = 0;
        while (self.peekAt(count) == '#') : (count += 1) {}
        const quote = self.peekAt(count) orelse return .{
            .count = @intCast(count),
            .is_raw_string = false,
        };
        return .{
            .count = @intCast(count),
            .is_raw_string = quote == '"' or quote == '\'',
        };
    }

    /// 扫描多行原始字符串字面量 `#"..."#` / `#'...'#`。
    ///
    /// `allow_newline` 为 `false` 时遇换行立即停止并返回 `illegal`。
    fn scanMultilineRawString(self: *@This(), hash_count: u32, allow_newline: bool) TokenTag {
        self.index += hash_count;
        const quote = self.raw[self.index];
        self.index += 1;

        var valid = true;
        while (self.index < self.raw.len) {
            const c = self.raw[self.index];
            if (!allow_newline and (c == '\n' or c == '\r')) return .illegal;
            if (c == quote) {
                var matched: u32 = 0;
                while (matched < hash_count and self.peekAt(1 + @as(usize, matched)) == '#') : (matched += 1) {}
                if (matched == hash_count) {
                    self.index += 1 + hash_count;
                    return if (valid) .multiline_raw_string else .illegal;
                }
                self.index += 1;
            } else if (c < 0x80) {
                self.index += 1;
            } else if (!self.advanceCodepoint()) {
                valid = false;
            }
        }
        return .illegal;
    }

    /// 尝试扫描带单字母前缀的字面量（`r'...'`、`r"..."`、`b'...'`）。
    fn scanPrefixedLiteral(self: *@This(), c: u8) ?TokenTag {
        if (c == 'r' and (self.peekAt(1) == '\'' or self.peekAt(1) == '"')) {
            return self.scanCharLiteral(false);
        }
        if (c == 'b' and self.peekAt(1) == '\'') {
            return self.scanCharLiteral(true);
        }
        return null;
    }

    /// 扫描插值表达式 `${...}`，追踪大括号嵌套以及内部字符串、注释、美元标识符与反引号标识符。
    ///
    /// 嵌套层级超过 `max_interpolation_depth` 时返回 `error.InterpolationDepthExceeded`。
    fn scanInterpolation(self: *@This(), allow_newline: bool, interp_depth: u32) Error!bool {
        std.debug.assert(self.peekAt(0) == '$' and self.peekAt(1) == '{');
        if (interp_depth >= max_interpolation_depth) return error.InterpolationDepthExceeded;
        self.index += 2;

        const next_depth = interp_depth + 1;
        var depth: usize = 1;
        var valid = true;

        while (depth > 0 and self.index < self.raw.len) {
            const c = self.raw[self.index];
            switch (c) {
                '\n', '\r' => {
                    if (!allow_newline) return false;
                    self.index += 1;
                },
                '{' => {
                    depth += 1;
                    self.index += 1;
                },
                '}' => {
                    depth -= 1;
                    self.index += 1;
                },
                '"', '\'' => {
                    if (self.peekAt(1) == c and self.peekAt(2) == c) {
                        if ((try self.scanMultilineString(c, allow_newline, next_depth)) == .illegal) {
                            valid = false;
                            if (!allow_newline and (self.peekAt(0) == '\n' or self.peekAt(0) == '\r')) {
                                return false;
                            }
                        }
                    } else {
                        if ((try self.scanLineString(c, next_depth)) == .illegal) valid = false;
                    }
                },
                '#' => {
                    const run = self.scanHashRun();
                    if (run.is_raw_string) {
                        if (self.scanMultilineRawString(run.count, allow_newline) == .illegal) {
                            valid = false;
                            if (!allow_newline and (self.peekAt(0) == '\n' or self.peekAt(0) == '\r')) {
                                return false;
                            }
                        }
                    } else {
                        self.index += run.count;
                    }
                },
                '/' => {
                    if (self.peekAt(1) == '/') {
                        if (self.scanLineComment() == .illegal) valid = false;
                    } else if (self.peekAt(1) == '*') {
                        if (self.scanBlockComment(allow_newline) == .illegal) {
                            valid = false;
                            if (!allow_newline and (self.peekAt(0) == '\n' or self.peekAt(0) == '\r')) {
                                return false;
                            }
                        }
                    } else {
                        self.index += 1;
                    }
                },
                '$' => _ = self.scanDollar(),
                '`' => {
                    if (self.scanBacktickIdentifier() == .illegal) valid = false;
                },
                else => {
                    if (self.scanPrefixedLiteral(c)) |tag| {
                        if (tag == .illegal) valid = false;
                    } else if (c < 0x80) {
                        if (isIdentifierStart(c)) {
                            _ = self.scanIdentifier();
                        } else {
                            self.index += 1;
                        }
                    } else if (self.peekCodepoint()) |cp| {
                        if (isIdentifierStart(cp.value)) {
                            _ = self.scanIdentifier();
                        } else {
                            self.index += @intCast(cp.len);
                        }
                    } else {
                        valid = false;
                        self.index += 1;
                    }
                },
            }
        }

        return depth == 0 and valid;
    }

    /// 扫描单行字符串字面量（`"..."` 或 `'...'`）。
    fn scanLineString(self: *@This(), quote: u8, interp_depth: u32) Error!TokenTag {
        std.debug.assert(self.peekAt(0) == quote);
        self.index += 1;

        var valid = true;
        while (self.index < self.raw.len) {
            const c = self.raw[self.index];
            if (c == quote) {
                self.index += 1;
                return if (valid) .string_literal else .illegal;
            }
            if (c == '\n' or c == '\r') return .illegal;

            if (c == '\\') {
                if (!self.scanEscapeSeq(false)) valid = false;
            } else if (c == '$' and self.peekAt(1) == '{') {
                if (!try self.scanInterpolation(false, interp_depth)) valid = false;
            } else if (c < 0x80) {
                self.index += 1;
            } else if (!self.advanceCodepoint()) {
                valid = false;
            }
        }
        return .illegal;
    }

    /// 扫描多行字符串字面量（`"""\n..."""` 或 `'''\n...'''`）。
    ///
    /// `allow_newline` 为 `false` 时遇换行立即停止并返回 `illegal`。
    fn scanMultilineString(self: *@This(), quote: u8, allow_newline: bool, interp_depth: u32) Error!TokenTag {
        std.debug.assert(self.peekAt(0) == quote and self.peekAt(1) == quote and self.peekAt(2) == quote);
        self.index += 3;

        var valid = true;
        if (self.peekAt(0) == '\n') {
            if (!allow_newline) return .illegal;
            self.index += 1;
        } else if (self.peekAt(0) == '\r' and self.peekAt(1) == '\n') {
            if (!allow_newline) return .illegal;
            self.index += 2;
        } else {
            // 起始三个引号后必须紧跟换行符，否则该多行字符串非法
            valid = false;
        }

        while (self.index < self.raw.len) {
            const c = self.raw[self.index];
            if (!allow_newline and (c == '\n' or c == '\r')) return .illegal;
            if (c == quote and self.peekAt(1) == quote and self.peekAt(2) == quote) {
                self.index += 3;
                return if (valid) .multiline_string else .illegal;
            }
            if (c == '\\') {
                if (!self.scanEscapeSeq(false)) valid = false;
            } else if (c == '$' and self.peekAt(1) == '{') {
                if (!try self.scanInterpolation(allow_newline, interp_depth)) valid = false;
            } else if (c < 0x80) {
                self.index += 1;
            } else if (!self.advanceCodepoint()) {
                valid = false;
            }
        }
        return .illegal;
    }

    /// 扫描 Rune 字面量（`r'x'` / `r"x"`）或 Byte 字面量（`b'x'`）。
    fn scanCharLiteral(self: *@This(), comptime is_byte: bool) TokenTag {
        const quote = self.raw[self.index + 1];
        self.index += 2;

        var valid = true;
        var count: u8 = 0;

        while (self.index < self.raw.len) {
            const c = self.raw[self.index];
            if (c == quote) {
                self.index += 1;
                const ok_tag: TokenTag = if (is_byte) .rune_byte_literal else .rune_literal;
                return if (valid and count == 1) ok_tag else .illegal;
            }
            if (c == '\n' or c == '\r') return .illegal;

            if (c == '\\') {
                if (!self.scanEscapeSeq(is_byte)) valid = false;
            } else if (is_byte) {
                // `SingleCharByte` 仅接受非双引号 ASCII 字节
                if (c < 0x80) {
                    if (c == '"') valid = false;
                    self.index += 1;
                } else {
                    valid = false;
                    _ = self.advanceCodepoint();
                }
            } else if (!self.advanceCodepoint()) {
                valid = false;
            }
            count = count +| 1;
        }
        return .illegal;
    }

    /// 扫描反引号包围的原始标识符（`` `if` ``）或包名标识符（`` `a-b.c` ``）。
    fn scanBacktickIdentifier(self: *@This()) TokenTag {
        std.debug.assert(self.peekAt(0) == '`');
        self.index += 1;

        const content_start = self.index;
        while (self.index < self.raw.len) {
            const c = self.raw[self.index];
            if (c == '`') {
                const content = self.raw[content_start..self.index];
                self.index += 1;
                if (isRawIdentContent(content)) return .identifier;
                if (isPackageIdentContent(content)) return .package_identifier;
                return .illegal;
            }
            if (c == '\n' or c == '\r') return .illegal;
            self.index += 1;
        }
        return .illegal;
    }

    /// 扫描 `$` 或 `$name` / `` $`ident` ``。
    fn scanDollar(self: *@This()) TokenTag {
        self.index += 1;
        if (self.peekAt(0) == '`') {
            const saved = self.index;
            if (self.scanBacktickIdentifier() == .identifier) return .dollar_identifier;
            self.index = saved;
            return .dollar;
        }
        if (self.peekCodepoint()) |cp| {
            if (isIdentifierStart(cp.value)) {
                const saved = self.index;
                const span = self.scanIdentifier();
                // 单独的 `_` 不构成 `Ident`，回退交由后续产生 `wildcard`
                if (std.mem.eql(u8, self.raw[span.start..span.end], "_")) {
                    self.index = saved;
                    return .dollar;
                }
                return .dollar_identifier;
            }
        }
        return .dollar;
    }

    /// 校验数字字面量尾部可选的类型后缀。
    fn finishNumberSuffix(self: *@This(), is_float: bool, has_error: bool) TokenTag {
        const ok_tag: TokenTag = if (is_float) .float_literal else .integer_literal;
        if (self.peekCodepoint()) |cp| {
            if (isIdentifierContinue(cp.value)) {
                const suffix_start = self.index;
                self.consumeIdentTrail();
                if (has_error) return .illegal;
                const suffix = self.raw[suffix_start..self.index];
                const ok = if (is_float) isFloatSuffix(suffix) else isIntegerSuffix(suffix);
                return if (ok) ok_tag else .illegal;
            }
        }
        return if (has_error) .illegal else ok_tag;
    }

    /// 扫描浮点指数部分（`[eE]` 或 `[pP]` 之后的 `'-'? DecimalFragment`），返回是否合法。
    fn scanExponentBody(self: *@This()) bool {
        if (self.peekAt(0) == '-') {
            self.index += 1;
        }
        return self.consumeDigitFragment(isDecDigit);
    }

    /// 消费十六进制浮点指数 `[pP] '-'? DecimalFragment`，按 Spec BNF 不接受类型后缀。
    fn finishHexExponent(self: *@This()) TokenTag {
        self.index += 1;
        const exp_ok = self.scanExponentBody();
        if (self.peekCodepoint()) |cp| {
            if (isIdentifierContinue(cp.value)) {
                self.consumeIdentTrail();
                return .illegal;
            }
        }
        return if (exp_ok) .float_literal else .illegal;
    }

    /// 扫描整数或浮点数字面量（调用前当前字节必须是 ASCII 数字）。
    fn scanNumber(self: *@This()) TokenTag {
        if (self.raw[self.index] == '0') {
            if (self.peekAt(1)) |prefix| {
                switch (prefix) {
                    'b', 'B' => return self.scanRadixInt(isBinDigit),
                    'o', 'O' => return self.scanRadixInt(isOctDigit),
                    'x', 'X' => return self.scanHexNumber(),
                    else => {},
                }
            }
        }
        return self.scanDecimalNumber();
    }

    fn scanRadixInt(self: *@This(), comptime isDigit: fn (u8) bool) TokenTag {
        self.index += 2;
        if (!self.consumeDigitFragment(isDigit)) return .illegal;
        return self.finishNumberSuffix(false, false);
    }

    fn scanHexNumber(self: *@This()) TokenTag {
        self.index += 2;

        // 无整数部分的十六进制浮点数，例如 `0x.2p4`
        if (self.peekAt(0) == '.') {
            self.index += 1;
            if (!self.consumeDigitFragment(isHexDigit)) return .illegal;
            if (self.peekAt(0) != 'p' and self.peekAt(0) != 'P') {
                self.consumeIdentTrail();
                return .illegal;
            }
            return self.finishHexExponent();
        }

        if (!self.consumeDigitFragment(isHexDigit)) return .illegal;

        // `0x1.foo()`、`0x1.append()`、`0x1.fp()` 中小数点后为成员访问名，需确认存在合法指数再归为浮点
        if (self.hasDotDigit(isHexDigit)) {
            const dot_pos = self.index;
            const frac_first = self.raw[self.index + 1];
            self.index += 2;
            self.consumeDigits(isHexDigit);
            if (self.peekAt(0) == 'p' or self.peekAt(0) == 'P') {
                const exp_after_p = self.peekAt(1);
                const has_exp_digit = if (exp_after_p) |ch|
                    isDecDigit(ch) or (ch == '-' and if (self.peekAt(2)) |d| isDecDigit(d) else false)
                else
                    false;
                if (has_exp_digit or isDecDigit(frac_first)) {
                    return self.finishHexExponent();
                }
            }
            self.index = dot_pos;
        }

        if (self.peekAt(0) == 'p' or self.peekAt(0) == 'P') {
            return self.finishHexExponent();
        }

        return self.finishNumberSuffix(false, false);
    }

    fn scanDecimalNumber(self: *@This()) TokenTag {
        var has_error = false;
        var zero_with_underscore = false;
        if (self.raw[self.index] == '0') {
            self.index += 1;
            if (self.peekAt(0) == '_') {
                zero_with_underscore = true;
                while (self.peekAt(0) == '_') : (self.index += 1) {}
            }
            if (self.peekAt(0)) |next_c| {
                if (isDecDigit(next_c)) {
                    // 十进制整数部分不允许前导零后接数字（如 `0123`、`0_1`）
                    has_error = true;
                    self.consumeDigits(isDecDigit);
                }
            }
        } else {
            self.index += 1;
            self.consumeDigits(isDecDigit);
        }

        var is_float = false;
        if (self.hasDotDigit(isDecDigit)) {
            is_float = true;
            self.index += 2;
            self.consumeDigits(isDecDigit);
        }

        if (self.peekAt(0) == 'e' or self.peekAt(0) == 'E') {
            is_float = true;
            self.index += 1;
            if (!self.scanExponentBody()) has_error = true;
        }

        if (is_float and zero_with_underscore) has_error = true;

        return self.finishNumberSuffix(is_float, has_error);
    }

    /// 扫描以小数点开头的十进制浮点数（如 `.8`、`.123e2`、`.5f32`）。
    fn scanDotFloat(self: *@This()) TokenTag {
        self.index += 2;
        self.consumeDigits(isDecDigit);

        var has_error = false;
        if (self.peekAt(0) == 'e' or self.peekAt(0) == 'E') {
            self.index += 1;
            if (!self.scanExponentBody()) has_error = true;
        }

        return self.finishNumberSuffix(true, has_error);
    }

    /// 扫描 ASCII 运算符、分隔符、注释、换行及非法 ASCII 字节。
    fn scanPunctuation(self: *@This(), c: u8) TokenTag {
        return switch (c) {
            ',' => self.take(1, .comma),
            '(' => self.take(1, .l_paren),
            ')' => self.take(1, .r_paren),
            '[' => self.take(1, .l_square),
            ']' => self.take(1, .r_square),
            '{' => self.take(1, .l_curl),
            '}' => self.take(1, .r_curl),
            ';' => self.take(1, .semi),
            '?' => self.take(1, .quest),
            '>' => self.take(1, .greater),
            '\n' => self.take(1, .nl),
            '\r' => if (self.peekAt(1) == '\n') self.take(2, .nl) else self.take(1, .illegal),
            '.' => {
                if (self.peekAt(1) == '.') {
                    if (self.peekAt(2) == '.') return self.take(3, .ellipsis);
                    if (self.peekAt(2) == '=') return self.take(3, .closed_range_op);
                    return self.take(2, .range_op);
                }
                if (self.hasDotDigit(isDecDigit)) return self.scanDotFloat();
                return self.take(1, .dot);
            },
            '*' => {
                if (self.peekAt(1) == '*') {
                    return if (self.peekAt(2) == '=') self.take(3, .exp_assign) else self.take(2, .exp);
                }
                return if (self.peekAt(1) == '=') self.take(2, .mul_assign) else self.take(1, .mul);
            },
            '%' => if (self.peekAt(1) == '=') self.take(2, .mod_assign) else self.take(1, .mod),
            '/' => {
                if (self.peekAt(1) == '/') return self.scanLineComment();
                if (self.peekAt(1) == '*') return self.scanBlockComment(true);
                return if (self.peekAt(1) == '=') self.take(2, .div_assign) else self.take(1, .div);
            },
            '+' => {
                if (self.peekAt(1) == '+') return self.take(2, .incr);
                return if (self.peekAt(1) == '=') self.take(2, .add_assign) else self.take(1, .add);
            },
            '-' => {
                if (self.peekAt(1) == '-') return self.take(2, .decr);
                if (self.peekAt(1) == '=') return self.take(2, .sub_assign);
                if (self.peekAt(1) == '>') return self.take(2, .arrow);
                return self.take(1, .sub);
            },
            '&' => {
                if (self.peekAt(1) == '&') {
                    return if (self.peekAt(2) == '=') self.take(3, .logical_and_assign) else self.take(2, .logical_and);
                }
                return if (self.peekAt(1) == '=') self.take(2, .bit_and_assign) else self.take(1, .bit_and);
            },
            '|' => {
                if (self.peekAt(1) == '|') {
                    return if (self.peekAt(2) == '=') self.take(3, .logical_or_assign) else self.take(2, .logical_or);
                }
                if (self.peekAt(1) == '>') return self.take(2, .pipeline);
                return if (self.peekAt(1) == '=') self.take(2, .bit_or_assign) else self.take(1, .bit_or);
            },
            '^' => if (self.peekAt(1) == '=') self.take(2, .bit_xor_assign) else self.take(1, .bit_xor),
            '~' => if (self.peekAt(1) == '>') self.take(2, .composition) else self.take(1, .bit_not),
            '!' => {
                if (self.peekAt(1) == '=') return self.take(2, .not_equal);
                if (self.peekAt(1) == 'i' and self.peekAt(2) == 'n') {
                    const continues = if (self.peekCodepointAt(3)) |after|
                        isIdentifierContinue(after.value)
                    else
                        false;
                    if (!continues) return self.take(3, .kw_not_in);
                }
                return self.take(1, .not);
            },
            '<' => {
                if (self.peekAt(1) == '<') {
                    return if (self.peekAt(2) == '=') self.take(3, .lshift_assign) else self.take(2, .lshift);
                }
                if (self.peekAt(1) == '=') return self.take(2, .less_equal);
                if (self.peekAt(1) == ':') return self.take(2, .upperbound);
                if (self.peekAt(1) == '-') return self.take(2, .backarrow);
                return self.take(1, .less);
            },
            ':' => if (self.peekAt(1) == ':') self.take(2, .double_colon) else self.take(1, .colon),
            '=' => {
                if (self.peekAt(1) == '=') return self.take(2, .equal);
                if (self.peekAt(1) == '>') return self.take(2, .double_arrow);
                return self.take(1, .assign);
            },
            '@' => if (self.peekAt(1) == '!') self.take(2, .at_excl) else self.take(1, .at),
            else => self.take(1, .illegal),
        };
    }

    fn nextTag(self: *@This()) Error!TokenTag {
        if (self.index >= self.raw.len) return .end;

        const first = self.raw[self.index];
        if (first < 0x80) {
            if (self.scanPrefixedLiteral(first)) |tag| return tag;
            if (isIdentifierStart(first)) {
                const span = self.scanIdentifier();
                return keywords.get(self.raw[span.start..span.end]) orelse .identifier;
            }
            return switch (first) {
                '0'...'9' => self.scanNumber(),
                '"', '\'' => if (self.peekAt(1) == first and self.peekAt(2) == first)
                    try self.scanMultilineString(first, true, 0)
                else
                    try self.scanLineString(first, 0),
                '`' => self.scanBacktickIdentifier(),
                '$' => self.scanDollar(),
                '#' => {
                    if (self.index < self.plain_hash_end) return self.take(1, .hash);
                    const run = self.scanHashRun();
                    if (run.is_raw_string) return self.scanMultilineRawString(run.count, true);
                    self.plain_hash_end = self.index + run.count;
                    return self.take(1, .hash);
                },
                else => self.scanPunctuation(first),
            };
        }

        if (self.peekCodepoint()) |cp| {
            if (isIdentifierStart(cp.value)) {
                const span = self.scanIdentifier();
                return keywords.get(self.raw[span.start..span.end]) orelse .identifier;
            }
            // 非 ASCII 的非标识符码点整体消费，避免把单个码点分成多个非法词法单元
            self.index += @intCast(cp.len);
            return .illegal;
        }

        // 非法 UTF-8：跳过一个字节继续，后续字节可能是合法文本
        self.index += 1;
        return .illegal;
    }

    /// 扫描并返回下一个词法单元；到达文件末尾时返回 `TokenTag.end`。
    ///
    /// 词法非法的源码片段返回 `TokenTag.illegal` 并推进游标；超出 `u32` 长度上限、
    /// 游标越界或插值嵌套超出深度上限时返回对应 `Error`。
    pub fn gen(self: *@This()) Error!common.Token {
        try validateSourceLen(self.raw.len);
        if (self.index > self.raw.len) return error.InvalidCursor;
        if (self.index < self.raw.len and isWhitespace(self.raw[self.index])) {
            _ = self.scanWhitespace();
        }
        const start = self.index;
        const tag = try self.nextTag();
        return .{ .span = .{ .start = start, .end = self.index }, .tag = tag };
    }
};

/// 对外导出的词法分析器类型别名，指向 `Lexer`。
pub const t = Lexer;

fn verify_token_kind(lexer_result: []const common.Token, hope_kind: []const common.TokenTag) !void {
    try std.testing.expectEqual(hope_kind.len, lexer_result.len);

    for (lexer_result[0..], hope_kind[0..]) |r, hope| {
        try std.testing.expectEqual(hope, r.tag);
    }
}

fn collectTokens(allocator: std.mem.Allocator, source: []const u8) ![]common.Token {
    var list: std.ArrayList(common.Token) = .empty;
    errdefer list.deinit(allocator);

    var lexer = try Lexer.new(source);
    while (true) {
        const tok = try lexer.gen();
        if (tok.tag == .end) break;
        try list.append(allocator, tok);
    }
    return list.toOwnedSlice(allocator);
}

fn expectSingleToken(src: []const u8, expected_tag: TokenTag) !void {
    var lexer = try Lexer.new(src);
    const tok = try lexer.gen();
    try std.testing.expectEqual(expected_tag, tok.tag);
    try std.testing.expectEqual(common.Span{ .start = 0, .end = @intCast(src.len) }, tok.span);
    try std.testing.expectEqual(TokenTag.end, (try lexer.gen()).tag);
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
        try expectSingleToken(case.src, case.tag);
    }
}

test "源文件末尾的单字符标识符" {
    try expectSingleToken("i", .identifier);
}

test "关键字表覆盖 TokenTag 中保留的标识符形态关键字" {
    const excluded = [_]TokenTag{ .kw_not_in, .kw_common, .kw_specific, .kw_features };

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
        try expectSingleToken(key, keywords.get(key).?);
    }
}

test "关键字后紧跟标识符字符时归为标识符" {
    const allocator = std.testing.allocator;

    for (keywords.keys()) |key| {
        const src = try std.fmt.allocPrint(allocator, "{s}x", .{key});
        defer allocator.free(src);

        try expectSingleToken(src, .identifier);
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
        try expectSingleToken(case.src, case.tag);
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
        try expectSingleToken(case.src, case.tag);
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
        try expectSingleToken(case.src, case.tag);
    }
}

test "扫描完整标识符取最长匹配" {
    const src = "island";
    var lexer = try Lexer.new(src);

    try std.testing.expectEqual(common.Span{ .start = 0, .end = 6 }, lexer.scanIdentifier());
    try std.testing.expectEqual(@as(u32, 6), lexer.index);
}

test "标识符扫描覆盖下划线开头与数字结尾" {
    const src = "_a1";
    var lexer = try Lexer.new(src);

    try std.testing.expectEqual(common.Span{ .start = 0, .end = 3 }, lexer.scanIdentifier());
}

test "标识符扫描停在非标识符字节" {
    const src = "foo.bar";
    var lexer = try Lexer.new(src);

    try std.testing.expectEqual(common.Span{ .start = 0, .end = 3 }, lexer.scanIdentifier());
    try std.testing.expectEqual(@as(?u8, '.'), lexer.peekAt(0));
}

test "标识符扫描在源文件末尾结束" {
    const src = "i";
    var lexer = try Lexer.new(src);

    try std.testing.expectEqual(common.Span{ .start = 0, .end = 1 }, lexer.scanIdentifier());
    try std.testing.expectEqual(@as(u32, 1), lexer.index);
}

test "扫描连续空白" {
    const src = "  \t\x0c;";
    var lexer = try Lexer.new(src);

    try std.testing.expectEqual(common.Span{ .start = 0, .end = 4 }, lexer.scanWhitespace());
    try std.testing.expectEqual(@as(?u8, ';'), lexer.peekAt(0));
}

test "空白扫描停在换行之前" {
    const src = "  \n";
    var lexer = try Lexer.new(src);

    try std.testing.expectEqual(common.Span{ .start = 0, .end = 2 }, lexer.scanWhitespace());
    try std.testing.expectEqual(@as(?u8, '\n'), lexer.peekAt(0));
}

test "空白扫描在源文件末尾结束" {
    const src = " ";
    var lexer = try Lexer.new(src);

    try std.testing.expectEqual(common.Span{ .start = 0, .end = 1 }, lexer.scanWhitespace());
    try std.testing.expectEqual(@as(u32, 1), lexer.index);
}

test "非 ASCII 标识符按码点整体扫描" {
    const cases = [_]struct { src: []const u8, end: u32 }{
        // 中文、含数字的混排、希腊字母
        .{ .src = "变量", .end = 6 },
        .{ .src = "名字1", .end = 7 },
        .{ .src = "λx", .end = 3 },
        // U+00C0 与 U+00FF 是 `XID_Start` 覆盖的拉丁补充字母
        .{ .src = "\u{00c0}", .end = 2 },
        .{ .src = "\u{00ff}", .end = 2 },
        // `ª` `µ` `º` 来自 `XID_Start`，`·` 来自 `Letter`
        .{ .src = "\u{00aa}x", .end = 3 },
        .{ .src = "\u{00b5}x", .end = 3 },
        .{ .src = "\u{00ba}x", .end = 3 },
        .{ .src = "a\u{00b7}b", .end = 4 },
    };

    for (cases) |case| {
        var lexer = try Lexer.new(case.src);
        const token = try lexer.gen();

        try std.testing.expectEqual(common.TokenTag.identifier, token.tag);
        try std.testing.expectEqual(common.Span{ .start = 0, .end = case.end }, token.span);
    }
}

test "u0080 到 u00FF 之间的非标识符码点整体成为非法词法单元" {
    const cases = [_]struct { src: []const u8, end: u32 }{
        // 非 `XID_Start` 且不等于 `·` 的码点归为非法
        .{ .src = "\u{0080}", .end = 2 },
        .{ .src = "\u{00a0}", .end = 2 },
        .{ .src = "\u{00a1}", .end = 2 },
        .{ .src = "\u{00a9}", .end = 2 },
        .{ .src = "\u{00b0}", .end = 2 },
        .{ .src = "\u{00d7}", .end = 2 },
        .{ .src = "\u{00f7}", .end = 2 },
    };

    for (cases) |case| {
        var lexer = try Lexer.new(case.src);
        const token = try lexer.gen();

        try std.testing.expectEqual(common.TokenTag.illegal, token.tag);
        try std.testing.expectEqual(common.Span{ .start = 0, .end = case.end }, token.span);
    }
}

test "非标识符的非 ASCII 码点整体成为单个非法词法单元" {
    // U+00A9 占用两个字节，一次 `gen` 应当整体交付
    const src = "\u{00a9}a";
    var lexer = try Lexer.new(src);

    const first = try lexer.gen();
    try std.testing.expectEqual(common.TokenTag.illegal, first.tag);
    try std.testing.expectEqual(common.Span{ .start = 0, .end = 2 }, first.span);

    const second = try lexer.gen();
    try std.testing.expectEqual(common.TokenTag.identifier, second.tag);
    try std.testing.expectEqual(common.Span{ .start = 2, .end = 3 }, second.span);
}

test "u0100 以上的非代理项码点都算标识符字符" {
    // `Letter` 的代理对分支 `[\uD800-\uDBFF] [\uDC00-\uDFFF]` 覆盖辅助平面码点，因此表情符号也是标识符字符
    const src = "\u{1f914}a";
    var lexer = try Lexer.new(src);

    const token = try lexer.gen();
    try std.testing.expectEqual(common.TokenTag.identifier, token.tag);
    try std.testing.expectEqual(common.Span{ .start = 0, .end = 5 }, token.span);
}

test "代理项码点不构成标识符" {
    try std.testing.expect(!isIdentifierStart(0xd800));
    try std.testing.expect(!isIdentifierStart(0xdfff));
    try std.testing.expect(!isIdentifierContinue(0xd800));
}

test "文本末尾返回 end 词法单元" {
    const src = "ab";
    var lexer = try Lexer.new(src);

    _ = try lexer.gen();
    const token = try lexer.gen();

    try std.testing.expectEqual(common.TokenTag.end, token.tag);
    try std.testing.expectEqual(common.Span{ .start = 2, .end = 2 }, token.span);
}

test "空源文件只产生 end 词法单元" {
    var lexer = try Lexer.new("");
    const token = try lexer.gen();

    try std.testing.expectEqual(common.TokenTag.end, token.tag);
    try std.testing.expectEqual(common.Span{ .start = 0, .end = 0 }, token.span);
}

test "非法 UTF-8 每次前进一个字节" {
    // 0xFF 属于非法 UTF-8 首字节
    const src = "\xff\xffa";
    var lexer = try Lexer.new(src);

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
    // U+4E2D 编码为 3 字节 `\xe4\xb8\xad`，此处缺少最后一个续字节
    const src = "\xe4\xb8";
    var lexer = try Lexer.new(src);

    const token = try lexer.gen();
    try std.testing.expectEqual(common.TokenTag.illegal, token.tag);
    try std.testing.expectEqual(common.Span{ .start = 0, .end = 1 }, token.span);
}

test "跳过水平空白并保留换行词法单元" {
    const src = "  \t\x0clet\t x \n y \r\n z \r";
    const tokens = try collectTokens(std.testing.allocator, src);
    defer std.testing.allocator.free(tokens);

    try verify_token_kind(tokens, &.{
        .kw_let,
        .identifier,
        .nl,
        .identifier,
        .nl,
        .identifier,
        .illegal,
    });
    try std.testing.expectEqual(common.Span{ .start = 4, .end = 7 }, tokens[0].span);
    try std.testing.expectEqual(common.Span{ .start = 9, .end = 10 }, tokens[1].span);
    try std.testing.expectEqual(common.Span{ .start = 11, .end = 12 }, tokens[2].span);
    try std.testing.expectEqual(common.Span{ .start = 15, .end = 17 }, tokens[4].span);
    try std.testing.expectEqual(common.Span{ .start = 20, .end = 21 }, tokens[6].span);
}

test "仅含水平空白的源文件返回 end" {
    var lexer = try Lexer.new("  \t\x0c ");
    const token = try lexer.gen();

    try std.testing.expectEqual(TokenTag.end, token.tag);
    try std.testing.expectEqual(common.Span{ .start = 5, .end = 5 }, token.span);
}

test "全部运算符与分隔符按最长匹配识别" {
    const cases = [_]struct { src: []const u8, tag: TokenTag }{
        .{ .src = ".", .tag = .dot },
        .{ .src = ",", .tag = .comma },
        .{ .src = "(", .tag = .l_paren },
        .{ .src = ")", .tag = .r_paren },
        .{ .src = "[", .tag = .l_square },
        .{ .src = "]", .tag = .r_square },
        .{ .src = "{", .tag = .l_curl },
        .{ .src = "}", .tag = .r_curl },
        .{ .src = "**", .tag = .exp },
        .{ .src = "*", .tag = .mul },
        .{ .src = "%", .tag = .mod },
        .{ .src = "/", .tag = .div },
        .{ .src = "+", .tag = .add },
        .{ .src = "-", .tag = .sub },
        .{ .src = "++", .tag = .incr },
        .{ .src = "--", .tag = .decr },
        .{ .src = "&&", .tag = .logical_and },
        .{ .src = "||", .tag = .logical_or },
        .{ .src = "|>", .tag = .pipeline },
        .{ .src = "~>", .tag = .composition },
        .{ .src = "!", .tag = .not },
        .{ .src = "&", .tag = .bit_and },
        .{ .src = "|", .tag = .bit_or },
        .{ .src = "^", .tag = .bit_xor },
        .{ .src = "~", .tag = .bit_not },
        .{ .src = "<<", .tag = .lshift },
        .{ .src = ":", .tag = .colon },
        .{ .src = "::", .tag = .double_colon },
        .{ .src = ";", .tag = .semi },
        .{ .src = "=", .tag = .assign },
        .{ .src = "+=", .tag = .add_assign },
        .{ .src = "-=", .tag = .sub_assign },
        .{ .src = "*=", .tag = .mul_assign },
        .{ .src = "**=", .tag = .exp_assign },
        .{ .src = "/=", .tag = .div_assign },
        .{ .src = "%=", .tag = .mod_assign },
        .{ .src = "&&=", .tag = .logical_and_assign },
        .{ .src = "||=", .tag = .logical_or_assign },
        .{ .src = "&=", .tag = .bit_and_assign },
        .{ .src = "|=", .tag = .bit_or_assign },
        .{ .src = "^=", .tag = .bit_xor_assign },
        .{ .src = "<<=", .tag = .lshift_assign },
        .{ .src = "->", .tag = .arrow },
        .{ .src = "<-", .tag = .backarrow },
        .{ .src = "=>", .tag = .double_arrow },
        .{ .src = "..", .tag = .range_op },
        .{ .src = "..=", .tag = .closed_range_op },
        .{ .src = "...", .tag = .ellipsis },
        .{ .src = "#", .tag = .hash },
        .{ .src = "@", .tag = .at },
        .{ .src = "@!", .tag = .at_excl },
        .{ .src = "?", .tag = .quest },
        .{ .src = "<", .tag = .less },
        .{ .src = ">", .tag = .greater },
        .{ .src = "<=", .tag = .less_equal },
        .{ .src = "<:", .tag = .upperbound },
        .{ .src = "!=", .tag = .not_equal },
        .{ .src = "==", .tag = .equal },
        .{ .src = "!in", .tag = .kw_not_in },
        .{ .src = "$", .tag = .dollar },
    };

    for (cases) |case| {
        try expectSingleToken(case.src, case.tag);
    }
}

test "由语法阶段组合的多字符符号在词法阶段保持单字符输出" {
    const tokens = try collectTokens(std.testing.allocator, "?? >> >>= >= () @Deprecated");
    defer std.testing.allocator.free(tokens);

    try verify_token_kind(tokens, &.{
        .quest,
        .quest,
        .greater,
        .greater,
        .greater,
        .greater,
        .assign,
        .greater,
        .assign,
        .l_paren,
        .r_paren,
        .at,
        .identifier,
    });
}

test "!in 后紧跟标识符字符时不合并为 kw_not_in" {
    const tokens = try collectTokens(std.testing.allocator, "!in !info !in1 !in_a !in(x)");
    defer std.testing.allocator.free(tokens);

    try verify_token_kind(tokens, &.{
        .kw_not_in,
        .not,
        .identifier,
        .not,
        .identifier,
        .not,
        .identifier,
        .kw_not_in,
        .l_paren,
        .identifier,
        .r_paren,
    });
}

test "单行注释与嵌套多行注释" {
    const src =
        \\// 行注释
        \\let a = 1 /* 块注释 */ + /* 外层 /* 嵌套 */ 结束 */ 2 /** 文档注释 */
    ;
    const tokens = try collectTokens(std.testing.allocator, src);
    defer std.testing.allocator.free(tokens);

    try verify_token_kind(tokens, &.{
        .comment,
        .nl,
        .kw_let,
        .identifier,
        .assign,
        .integer_literal,
        .comment,
        .add,
        .comment,
        .integer_literal,
        .comment,
    });
}

test "未闭合块注释产生 illegal" {
    const cases = [_][]const u8{
        "/* unclosed",
        "/* outer /* inner */ still open",
    };

    for (cases) |src| {
        try expectSingleToken(src, .illegal);
    }
}

test "合法整数字面量覆盖四种进制与全部后缀" {
    const cases = [_][]const u8{
        "0",
        "0_",
        "0_i64",
        "0u8",
        "42",
        "1_000_000",
        "123i8",
        "123i16",
        "123i32",
        "123i64",
        "123u8",
        "123u16",
        "123u32",
        "123u64",
        "0b0",
        "0B1010_0101",
        "0b1_u8",
        "0o0",
        "0O755",
        "0o30_i32",
        "0x0",
        "0x18",
        "0Xdead_BEEF",
        "0x1f32",
        "0xFF_u64",
        "0x10i16",
    };

    for (cases) |src| {
        try expectSingleToken(src, .integer_literal);
    }
}

test "合法浮点数字面量覆盖十进制、十六进制与全部后缀" {
    const cases = [_][]const u8{
        "3.14",
        "0.0",
        "1_0.2_5",
        "2.4e-1",
        "2e3",
        "2E3",
        "0e0",
        ".8",
        ".123e2",
        ".5f16",
        "3.14f32",
        "1e10f64",
        "1_0e2_0f64",
        "0x1.1p0",
        "0x1p2",
        "0x.2p4",
        "0X1_A.B_CP-3",
        "0x1.fp0",
    };

    for (cases) |src| {
        try expectSingleToken(src, .float_literal);
    }
}

test "数字后的点号区分范围运算符、成员访问与小数" {
    const src = "1..10 1..=10 1.toString() 0x1.foo() 0x1.append() 0x1.fp() 0x1.deep() 0x1.cap() 0x1.a 1._x";
    const tokens = try collectTokens(std.testing.allocator, src);
    defer std.testing.allocator.free(tokens);

    try verify_token_kind(tokens, &.{
        .integer_literal, .range_op,        .integer_literal,
        .integer_literal, .closed_range_op, .integer_literal,
        .integer_literal, .dot,             .identifier,
        .l_paren,         .r_paren,         .integer_literal,
        .dot,             .identifier,      .l_paren,
        .r_paren,         .integer_literal, .dot,
        .identifier,      .l_paren,         .r_paren,
        .integer_literal, .dot,             .identifier,
        .l_paren,         .r_paren,         .integer_literal,
        .dot,             .identifier,      .l_paren,
        .r_paren,         .integer_literal, .dot,
        .identifier,      .l_paren,         .r_paren,
        .integer_literal, .dot,             .identifier,
        .integer_literal, .dot,             .identifier,
    });
}

test "非法数字字面量整体返回 illegal" {
    const cases = [_][]const u8{
        "0b",
        "0b_1",
        "0b102",
        "0o",
        "0o_7",
        "0o8",
        "0x",
        "0x_1",
        "0x1g",
        "0x.2",
        "0x1p",
        "0x1p-",
        "0x1p_2",
        "0x1.1p",
        "0x1.1p-",
        "0x1p2f32",
        "0x1.fp0f64",
        "00",
        "0123",
        "0_1",
        "0_.5",
        "0_e2",
        "123i7",
        "123abc",
        "1f32",
        "1.0f128",
        "1e",
        "1e-",
        "1e_2",
        "1.0i32",
    };

    for (cases) |src| {
        try expectSingleToken(src, .illegal);
    }

    // Spec BNF 的 `Sign` 仅允许 `'-'`，`+` 不构成指数符号
    const plus_exp = try collectTokens(std.testing.allocator, "2.4e+1 0x1p+2");
    defer std.testing.allocator.free(plus_exp);
    try verify_token_kind(plus_exp, &.{
        .illegal, .add, .integer_literal,
        .illegal, .add, .integer_literal,
    });
}

test "单行字符串、转义序列与插值表达式" {
    const cases = [_][]const u8{
        "\"\"",
        "''",
        "\"hello\"",
        "'world'",
        "\"\\t\\b\\r\\n\\'\\\"\\\\\\f\\v\\0\\$\"",
        "\"\\u{41}\\u{4e2d}\\u{1F600}\"",
        "\"$ plain dollar\"",
        "\"\\${escaped}\"",
        "\"value = ${a + b}\"",
        "\"nested ${\"inner ${x}\"}\"",
        "\"block ${{ let x = 1; x }}\"",
        "\"char ${r'\"'} and ${b'a'}\"",
        "\"quote ${quote($r\"hello\")}\"",
        "\"quote ${quote($b'hello')}\"",
        "\"raw ${`if`}\"",
        "\"comment ${/* ok */ 1}\"",
        "'single ${'inner'}'",
    };

    for (cases) |src| {
        try expectSingleToken(src, .string_literal);
    }
}

test "非法单行字符串返回 illegal" {
    const cases = [_][]const u8{
        "\"unterminated",
        "'unterminated",
        "\"bad escape \\q\"",
        "\"bad unicode \\u\"",
        "\"bad unicode \\u{12\"",
        "\"bad unicode \\u{}\"",
        "\"bad unicode \\u{123456789}\"",
        "\"surrogate \\u{D800}\"",
        "\"out of range \\u{110000}\"",
        "\"unclosed interp ${a + b\"",
    };

    for (cases) |src| {
        try expectSingleToken(src, .illegal);
    }

    // 单行字符串遇到换行在换行之前停止
    const line_cases = [_]struct { src: []const u8, end: u32 }{
        .{ .src = "\"line1\nline2\"", .end = 6 },
        .{ .src = "\"line1\\\nline2\"", .end = 7 },
        .{ .src = "\"${a\nb}\"", .end = 4 },
        .{ .src = "\"${\"\"\"\n\"\"\"}\"", .end = 6 },
        .{ .src = "\"${#\"\n\"#}\"", .end = 5 },
        .{ .src = "\"${/*\n*/a}\"", .end = 5 },
    };

    for (line_cases) |case| {
        var lexer = try Lexer.new(case.src);
        const first = try lexer.gen();
        try std.testing.expectEqual(TokenTag.illegal, first.tag);
        try std.testing.expectEqual(common.Span{ .start = 0, .end = case.end }, first.span);
        try std.testing.expectEqual(TokenTag.nl, (try lexer.gen()).tag);
    }
}

test "多行字符串字面量" {
    const cases = [_][]const u8{
        "\"\"\"\n\"\"\"",
        "\"\"\"\r\nhello\r\nworld\"\"\"",
        "'''\nhello\n'''",
        "\"\"\"\nescaped \\\"\"\" quotes\n\"\"\"",
        "\"\"\"\ninterp ${\n  // 行注释\n  let x = 1\n  x + 2\n}\n\"\"\"",
    };

    for (cases) |src| {
        try expectSingleToken(src, .multiline_string);
    }

    // 开头三引号后缺少换行或未闭合均返回 illegal
    const illegal_cases = [_][]const u8{
        "\"\"\"abc\n\"\"\"",
        "\"\"\"\nunterminated",
    };
    for (illegal_cases) |src| {
        try expectSingleToken(src, .illegal);
    }
}

test "多行原始字符串字面量与普通井号" {
    const cases = [_][]const u8{
        "#\"\"#",
        "##\"\"##",
        "#'raw'#",
        "#\"line1\\n\nline2\"#",
        "##\"contains \"# inside\"##",
    };

    for (cases) |src| {
        try expectSingleToken(src, .multiline_raw_string);
    }

    // 遇到匹配数量的井号即结束，多余的井号属于下一个词法单元
    const extra_hash = try collectTokens(std.testing.allocator, "##\"hi\"### #foo");
    defer std.testing.allocator.free(extra_hash);
    try verify_token_kind(extra_hash, &.{
        .multiline_raw_string,
        .hash,
        .hash,
        .identifier,
    });

    // 未闭合原始字符串返回 illegal
    try expectSingleToken("##\"hi\"#", .illegal);
}

test "大量连续井号线性终止，深层嵌套插值返回错误" {
    const allocator = std.testing.allocator;

    // 4096 个连续 `#`（后无引号）
    const hashes = try allocator.alloc(u8, 4096);
    defer allocator.free(hashes);
    @memset(hashes, '#');
    const hash_tokens = try collectTokens(allocator, hashes);
    defer allocator.free(hash_tokens);
    try std.testing.expectEqual(@as(usize, 4096), hash_tokens.len);
    for (hash_tokens) |tok| try std.testing.expectEqual(TokenTag.hash, tok.tag);

    // 超过深度上限的嵌套单行插值返回 InterpolationDepthExceeded
    const deep_line = try allocator.alloc(u8, 3 * 512);
    defer allocator.free(deep_line);
    for (0..512) |i| {
        deep_line[i * 3] = '"';
        deep_line[i * 3 + 1] = '$';
        deep_line[i * 3 + 2] = '{';
    }
    var deep_line_lexer = try Lexer.new(deep_line);
    try std.testing.expectError(Lexer.Error.InterpolationDepthExceeded, deep_line_lexer.gen());

    // 超过深度上限的嵌套多行插值返回 InterpolationDepthExceeded
    const deep_multi = try allocator.alloc(u8, 6 * 512);
    defer allocator.free(deep_multi);
    for (0..512) |i| {
        @memcpy(deep_multi[i * 6 .. i * 6 + 6], "\"\"\"\n${");
    }
    var deep_multi_lexer = try Lexer.new(deep_multi);
    try std.testing.expectError(Lexer.Error.InterpolationDepthExceeded, deep_multi_lexer.gen());
}

test "源码超长与游标越界返回错误" {
    try Lexer.validateSourceLen(std.math.maxInt(u32));
    if (@sizeOf(usize) > @sizeOf(u32)) {
        const too_large = @as(usize, std.math.maxInt(u32)) + 1;
        try std.testing.expectError(Lexer.Error.SourceTooLarge, Lexer.validateSourceLen(too_large));
    }

    var invalid_cursor = Lexer{ .raw = "abc", .index = 4 };
    try std.testing.expectError(Lexer.Error.InvalidCursor, invalid_cursor.gen());
}

test "注释含非法 UTF-8 字节返回 illegal 并保持后续同步" {
    const tokens = try collectTokens(std.testing.allocator, "// bad \xff\n/* bad \xff */ let x = 1");
    defer std.testing.allocator.free(tokens);

    try verify_token_kind(tokens, &.{
        .illegal,
        .nl,
        .illegal,
        .kw_let,
        .identifier,
        .assign,
        .integer_literal,
    });
}

test "全单字节输入与畸形序列均可推进至 end" {
    for (0..256) |byte_val| {
        const buf = [_]u8{@intCast(byte_val)};
        var lexer = try Lexer.new(&buf);
        const tok = try lexer.gen();
        if (tok.tag != .end) {
            try std.testing.expect(tok.span.end > tok.span.start);
            try std.testing.expectEqual(TokenTag.end, (try lexer.gen()).tag);
        }
    }

    const malformed = [_][]const u8{
        "\\",
        "\"\\",
        "'\\u{",
        "\"${",
        "\"\"\"\\u{ffffffffff}",
        "##\"\\xff",
        "/* /* /*",
        "`\xff`",
        "$\xff",
        "0x.p-",
        "r'\\",
        "b'\\",
    };

    for (malformed) |src| {
        var lexer = try Lexer.new(src);
        var prev_index: u32 = 0;
        while (true) {
            const tok = try lexer.gen();
            if (tok.tag == .end) break;
            try std.testing.expect(lexer.index > prev_index);
            prev_index = lexer.index;
        }
        try std.testing.expectEqual(@as(u32, @intCast(src.len)), lexer.index);
    }
}

test "Rune 字面量与 Byte 字面量" {
    const rune_cases = [_][]const u8{
        "r'a'",
        "r\"a\"",
        "r'中'",
        "r'\\n'",
        "r'\\u{4e2d}'",
        "r'\"'",
        "r\"'\"",
        "r'\\$'",
    };
    for (rune_cases) |src| {
        try expectSingleToken(src, .rune_literal);
    }

    const illegal_runes = [_][]const u8{ "r''", "r'ab'", "r'\\q'", "r'a" };
    for (illegal_runes) |src| {
        try expectSingleToken(src, .illegal);
    }

    const byte_cases = [_][]const u8{
        "b'a'",
        "b'\\n'",
        "b'\\0'",
        "b'\\\"'",
        "b'\\u{a}'",
        "b'\\u{ff}'",
    };
    for (byte_cases) |src| {
        try expectSingleToken(src, .rune_byte_literal);
    }

    const illegal_bytes = [_][]const u8{ "b''", "b'ab'", "b'中'", "b'\"'", "b'\\$'", "b'\\u{100}'" };
    for (illegal_bytes) |src| {
        try expectSingleToken(src, .illegal);
    }

    // 单独的 r、b、j、J 仍是普通标识符，j"..." 与 J"..." 分别产出标识符与字符串
    const idents = try collectTokens(std.testing.allocator, "r b j\"hello\" J\"world\" return");
    defer std.testing.allocator.free(idents);
    try verify_token_kind(idents, &.{
        .identifier,
        .identifier,
        .identifier,
        .string_literal,
        .identifier,
        .string_literal,
        .kw_return,
    });
}

test "反引号原始标识符与包名标识符" {
    const raw_cases = [_][]const u8{ "`if`", "`class`", "`foo`", "`_a`", "`仓颉`" };
    for (raw_cases) |src| {
        try expectSingleToken(src, .identifier);
    }

    const pkg_cases = [_][]const u8{ "`a-b.c`", "`ohos-http`", "`foo.bar`" };
    for (pkg_cases) |src| {
        try expectSingleToken(src, .package_identifier);
    }

    const illegal_cases = [_][]const u8{
        "``",
        "`_`",
        "`123`",
        "`-a`",
        "`a-`",
        "`a.`",
        "`a--b`",
        "`a..b`",
        "`unclosed",
    };
    for (illegal_cases) |src| {
        try expectSingleToken(src, .illegal);
    }

    // 反引号内遇到换行停在换行之前
    var lexer = try Lexer.new("`a\nb`");
    const first = try lexer.gen();
    try std.testing.expectEqual(TokenTag.illegal, first.tag);
    try std.testing.expectEqual(common.Span{ .start = 0, .end = 2 }, first.span);
    try std.testing.expectEqual(TokenTag.nl, (try lexer.gen()).tag);
}

test "美元符号与美元标识符" {
    const tokens = try collectTokens(std.testing.allocator, "$x $`if` $10 $(a) $_ $ $`a-b` $`` $`_`");
    defer std.testing.allocator.free(tokens);

    try verify_token_kind(tokens, &.{
        .dollar_identifier,
        .dollar_identifier,
        .dollar,
        .integer_literal,
        .dollar,
        .l_paren,
        .identifier,
        .r_paren,
        .dollar,
        .wildcard,
        .dollar,
        .dollar,
        .package_identifier,
        .dollar,
        .illegal,
        .dollar,
        .illegal,
    });
}

test "完整仓颉代码片段词法分析" {
    const src =
        \\package org::`my-pkg`.sub
        \\@!CustomAnno[version: 1]
        \\public func sum<T>(xs: Array<Array<T>>): Int64 where T <: ToString {
        \\    var total: Int64 = 0
        \\    for (i in 0..=10) {
        \\        if (i !in xs) {
        \\            total += i
        \\        }
        \\    }
        \\    return total
        \\}
    ;
    const tokens = try collectTokens(std.testing.allocator, src);
    defer std.testing.allocator.free(tokens);

    try verify_token_kind(tokens, &.{
        .kw_package, .identifier, .double_colon,    .package_identifier, .dot,             .identifier,      .nl,
        .at_excl,    .identifier, .l_square,        .identifier,         .colon,           .integer_literal, .r_square,
        .nl,         .kw_public,  .kw_func,         .identifier,         .less,            .identifier,      .greater,
        .l_paren,    .identifier, .colon,           .identifier,         .less,            .identifier,      .less,
        .identifier, .greater,    .greater,         .r_paren,            .colon,           .kw_int64,        .kw_where,
        .identifier, .upperbound, .identifier,      .l_curl,             .nl,              .kw_var,          .identifier,
        .colon,      .kw_int64,   .assign,          .integer_literal,    .nl,              .kw_for,          .l_paren,
        .identifier, .kw_in,      .integer_literal, .closed_range_op,    .integer_literal, .r_paren,         .l_curl,
        .nl,         .kw_if,      .l_paren,         .identifier,         .kw_not_in,       .identifier,      .r_paren,
        .l_curl,     .nl,         .identifier,      .add_assign,         .identifier,      .nl,              .r_curl,
        .nl,         .r_curl,     .nl,              .kw_return,          .identifier,      .nl,              .r_curl,
    });
}
