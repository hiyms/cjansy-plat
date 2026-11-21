//! 仓颉源码的词法单元标签。
//!
//! 标签对应 cangjie_compiler 中 `include/cangjie/Lex/Tokens.inc` 定义的词法单元。
//!
//! 以下标签在词法分析阶段不直接产出，交由语法分析阶段按上下文或相邻标签处理：
//! - `??`、`>>`、`>>=`、`>=` 与嵌套可空类型后缀或泛型参数列表的 `>` 重叠，词法阶段仅产出
//!   单个字符标签（`quest`、`greater`、`assign`）。
//! - `unit_literal`（`()`）在词法阶段产出 `l_paren` 与 `r_paren`。
//! - `annotation`（`@abc`）在词法阶段产出 `at` / `at_excl` 与后续标识符。
//! - `sentinel` 仅作解析器内部占位。
//!
//! 含 `${...}` 插值的单行与多行字符串在词法阶段整体分别产出 `string_literal` 与 `multiline_string`。

const std = @import("std");
const Span = @import("common.zig").Span;

/// 词法单元标签。
pub const TokenTag = enum {
    /// `.`
    dot,
    /// `,`
    comma,
    /// `(`
    l_paren,
    /// `)`
    r_paren,
    /// `[`
    l_square,
    /// `]`
    r_square,
    /// `{`
    l_curl,
    /// `}`
    r_curl,
    /// `**`
    exp,
    /// `*`
    mul,
    /// `%`
    mod,
    /// `/`
    div,
    /// `+`
    add,
    /// `-`
    sub,
    /// `++`
    incr,
    /// `--`
    decr,
    /// `&&`
    logical_and,
    /// `||`
    logical_or,
    /// `|>`
    pipeline,
    /// `~>`
    composition,
    /// `!`
    not,
    /// `&`
    bit_and,
    /// `|`
    bit_or,
    /// `^`
    bit_xor,
    /// `~`
    bit_not,
    /// `<<`
    lshift,
    /// `:`
    colon,
    /// `;`
    semi,
    /// `=`
    assign,
    /// `+=`
    add_assign,
    /// `-=`
    sub_assign,
    /// `*=`
    mul_assign,
    /// `**=`
    exp_assign,
    /// `/=`
    div_assign,
    /// `%=`
    mod_assign,
    /// `&&=`
    logical_and_assign,
    /// `||=`
    logical_or_assign,
    /// `&=`
    bit_and_assign,
    /// `|=`
    bit_or_assign,
    /// `^=`
    bit_xor_assign,
    /// `<<=`
    lshift_assign,
    /// `->`
    arrow,
    /// `<-`
    backarrow,
    /// `=>`
    double_arrow,
    /// `..`
    range_op,
    /// `..=`
    closed_range_op,
    /// `...`
    ellipsis,
    /// `#`
    hash,
    /// `@`
    at,
    /// `?`
    quest,
    /// `<`
    less,
    /// `>`
    greater,
    /// `<=`
    less_equal,
    /// `is`
    kw_is,
    /// `as`
    kw_as,
    /// `!=`
    not_equal,
    /// `==`
    equal,
    /// `_`
    wildcard,

    /// `Int8`
    kw_int8,
    /// `Int16`
    kw_int16,
    /// `Int32`
    kw_int32,
    /// `Int64`
    kw_int64,
    /// `IntNative`
    kw_int_native,
    /// `UInt8`
    kw_uint8,
    /// `UInt16`
    kw_uint16,
    /// `UInt32`
    kw_uint32,
    /// `UInt64`
    kw_uint64,
    /// `UIntNative`
    kw_uint_native,
    /// `Float16`
    kw_float16,
    /// `Float32`
    kw_float32,
    /// `Float64`
    kw_float64,
    /// `Rune`
    kw_rune,
    /// `Bool`
    kw_bool,
    /// `Nothing`
    kw_nothing,
    /// `Unit`
    kw_unit,
    /// `struct`
    kw_struct,
    /// `enum`
    kw_enum,
    /// `VArray`
    kw_varray,
    /// `This`
    kw_this_type,
    /// `package`
    kw_package,
    /// `import`
    kw_import,
    /// `class`
    kw_class,
    /// `interface`
    kw_interface,
    /// `func`
    kw_func,
    /// `macro`
    kw_macro,
    /// `quote`
    kw_quote,
    /// `$`
    dollar,
    /// `let`
    kw_let,
    /// `var`
    kw_var,
    /// `const`
    kw_const,
    /// `type`
    kw_type,
    /// `init`
    kw_init,
    /// `this`
    kw_this,
    /// `super`
    kw_super,
    /// `if`
    kw_if,
    /// `else`
    kw_else,
    /// `case`
    kw_case,
    /// `try`
    kw_try,
    /// `catch`
    kw_catch,
    /// `finally`
    kw_finally,
    /// `for`
    kw_for,
    /// `do`
    kw_do,
    /// `while`
    kw_while,
    /// `throw`
    kw_throw,
    /// `return`
    kw_return,
    /// `continue`
    kw_continue,
    /// `break`
    kw_break,
    /// `in`
    kw_in,
    /// `!in`
    kw_not_in,
    /// `match`
    kw_match,
    /// `where`
    kw_where,
    /// `extend`
    kw_extend,
    /// `with`
    kw_with,
    /// `prop`
    kw_prop,
    /// `static`
    kw_static,
    /// `public`
    kw_public,
    /// `private`
    kw_private,
    /// `internal`
    kw_internal,
    /// `protected`
    kw_protected,
    /// `override`
    kw_override,
    /// `redef`
    kw_redef,
    /// `abstract`
    kw_abstract,
    /// `sealed`
    kw_sealed,
    /// `open`
    kw_open,
    /// `foreign`
    kw_foreign,
    /// `inout`
    kw_inout,
    /// `mut`
    kw_mut,
    /// `unsafe`
    kw_unsafe,
    /// `operator`
    kw_operator,
    /// `spawn`
    kw_spawn,
    /// `synchronized`
    kw_synchronized,
    /// `<:`
    upperbound,
    /// `main`
    kw_main,
    /// 标识符
    identifier,
    /// 反引号包名标识符
    package_identifier,
    /// 整数字面量
    integer_literal,
    /// `b'x'`
    rune_byte_literal,
    /// 浮点数字面量
    float_literal,
    /// 注释
    comment,
    /// 换行
    nl,
    /// 文件结束
    end,
    /// 占位
    sentinel,
    /// 字符字面量
    rune_literal,
    /// 单行字符串字面量（含插值时词法阶段保持整体）
    string_literal,
    /// 多行字符串字面量（含插值时词法阶段保持整体）
    multiline_string,
    /// 多行原始字符串字面量
    multiline_raw_string,
    /// `true` `false`
    bool_literal,
    /// `()`
    unit_literal,
    /// `$name`
    dollar_identifier,
    /// `@abc`
    annotation,
    /// `@!`
    at_excl,
    /// `common`
    kw_common,
    /// `specific`
    kw_specific,
    /// `perform`
    kw_perform,
    /// `resume`
    kw_resume,
    /// `throwing`
    kw_throwing,
    /// `handle`
    kw_handle,
    /// 非法词法单元
    illegal,
    /// `::`
    double_colon,
    /// `features`
    kw_features,
};

pub const Token = struct {
    tag: TokenTag,
    span: Span,
};

test "Token 只承载标签与区间" {
    const token: Token = .{ .tag = .kw_func, .span = .{ .start = 3, .end = 7 } };
    try std.testing.expectEqual(TokenTag.kw_func, token.tag);
    try std.testing.expectEqual(@as(u32, 3), token.span.start);
    try std.testing.expectEqual(@as(u32, 7), token.span.end);
}

