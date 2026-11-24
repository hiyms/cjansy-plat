// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 仓颉源码的 Lossless CST（具体语法树）节点标签。
//!
//! CST 保留源文件的全部内容，注释、空白、换行同样是树中的节点，按原始文本重建源文件时不会丢失任何字节。
//! 标签分两类：词法单元叶子，以及由若干子节点组成的内部节点。
//!
//! 与 `token.zig` 的 `TokenTag` 相比：
//!
//! - `??`、`>>`、`>>=`、`>=` 在这里各自是一个标签。词法分析阶段把它们分成单个字符，是因为那时还
//!   不知道是否处于泛型参数列表；语法分析阶段已经确定它们是不是运算符，CST 中直接记录整体。嵌套
//!   泛型实参的收尾 `>>` 依然是两个 `greater`，那里确实是两个独立的 `>`。
//! - `nl`、`end`、`sentinel` 不出现在这里：换行记作 `newline`，文件结束记作 `eof`，占位标签没有
//!   对应的节点；`comment` 按注释形态分为 `line_comment`、`block_comment`、`doc_comment`。
//!
//! 点分路径始终平铺：`a.b.c` 是一个 `path_expr`（或类型位置的 `path_type`），子节点是三个
//! `path_segment` 与两个 `dot`，不会出现 `a.b` 再包一层的同名嵌套。

const std = @import("std");
const token = @import("token.zig");
const TokenTag = token.TokenTag;

/// CST 节点标签。
pub const SyntaxKind = enum {
    // ---------------- 空白、换行与注释 ----------------

    /// 空白字符（空格、制表符、换页符）
    whitespace,
    /// 换行，`\n` 或 `\r\n`
    newline,
    /// `//...` 单行注释（含 `////...`）
    line_comment,
    /// `/*...*/` 块注释，以 `/***` 开头或内容为空的 `/**/` 也属于块注释
    block_comment,
    /// `///...`（不含 `////...`）或 `/**...*/` 文档注释
    doc_comment,

    /// 文件结束
    eof,
    /// 词法分析无法识别的字符序列
    illegal,

    // ---------------- 标识符与字面量 ----------------

    /// 标识符，包括反引号包围的原始标识符
    identifier,
    /// 反引号包围的包名，例如 `` `a-b.c` ``
    package_identifier,
    /// `$name`
    dollar_identifier,
    /// 整数字面量
    integer_literal,
    /// 浮点数字面量
    float_literal,
    /// 字符字面量
    rune_literal,
    /// `b'x'`
    rune_byte_literal,
    /// 单行字符串字面量，不含插值
    string_literal,
    /// 多行字符串字面量
    multiline_string,
    /// 多行原始字符串字面量，开头的若干 `#` 包含在节点文本内
    multiline_raw_string,
    /// 字符串中的一段纯文本。出现在 `str_interpolation_expr` 内部，
    /// 第一个片段带开始引号，最后一个片段带结束引号
    string_content,
    /// `true` 或 `false`
    bool_literal,

    // ---------------- 运算符与分隔符 ----------------

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
    /// `??`
    coalescing,
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
    /// `>>`
    rshift,
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
    /// `>>=`
    rshift_assign,
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
    /// `@!`
    at_excl,
    /// `?`
    quest,
    /// `<`
    less,
    /// `>`
    greater,
    /// `<=`
    less_equal,
    /// `>=`
    greater_equal,
    /// `!=`
    not_equal,
    /// `==`
    equal,
    /// `_`
    wildcard,
    /// `$`
    dollar,
    /// `::`
    double_colon,
    /// `<:`
    upperbound,
    /// `is`
    kw_is,
    /// `as`
    kw_as,
    /// `!in`
    kw_not_in,

    // ---------------- 关键字 ----------------

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
    /// `main`
    kw_main,
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
    /// `features`
    kw_features,

    // ---------------- 源文件、特性、包与导入 ----------------

    /// 整个源文件
    source_file,
    /// `features { ... }` 特性声明
    features_directive,
    /// 特性声明中的 `{ ... }` 集合
    features_set,
    /// 特性集合中的点分标识符，`a.b.c`
    feature_id,
    /// `package a.b.c` 包声明，`macro package a.b.c` 也是此标签
    package_header,
    /// 整个点分包名 `a.b.c`，子节点是 `identifier` 与 `dot`
    package_name,
    /// 单条 `import` 声明
    import_spec,
    /// `import` 之后的部分：点分路径、`*`、`{...}` 集合或 `as` 别名
    import_content,

    // ---------------- 注解与宏调用 ----------------

    /// 注解，`@Deprecated[...]`、`@When[...]`、`@OverflowWrapping`，名字可以是点分限定名。
    /// 名字在内置注解名称表里的是注解，其余 `@Name` 是宏调用
    annotation,

    // ---------------- 声明 ----------------

    /// `class Foo <: Bar { ... }`
    class_decl,
    /// `interface Foo { ... }`
    interface_decl,
    /// `struct Foo { ... }`
    struct_decl,
    /// `enum Foo { A | B(Int64) }`
    enum_decl,
    /// 枚举体中的一个构造器，`A` 或 `B(Int64, String)`。后一种形式的括号内是类型
    enum_constructor,
    /// `func f(a: Int64): Int64 { ... }`，包括 `operator func` 与无函数体的声明
    func_decl,
    /// `main() { ... }`
    main_decl,
    /// `macro m(input: Tokens): Tokens { ... }`
    macro_decl,
    /// `let x: Int64 = 0`、`var (a, b) = (1, 2)`、`const c = 1`。`let` 与 `var` 后面、`=` 前面
    /// 的内容是一个模式节点
    var_decl,
    /// `prop p: Int64 { get() { ... } }`
    prop_decl,
    /// 属性声明中的 `get() { ... }`，`get` 是 `identifier` 叶子，因为它是一个上下文关键字
    prop_getter,
    /// 属性声明中的 `set(value) { ... }`，`set` 是 `identifier` 叶子
    prop_setter,
    /// `type Alias = Foo`
    type_alias_decl,
    /// `extend Foo <: Bar { ... }`
    extend_decl,
    /// 类或结构体的主构造器，`Foo(let x: Int64) { ... }`
    primary_ctor_decl,
    /// `init(x: Int64) { ... }`，包含 `static init() { ... }`
    init_decl,
    /// `~init() { ... }`
    finalizer_decl,
    /// `foreign func f(): Unit` 或 `foreign { ... }`
    foreign_decl,
    /// `foreign` 之后的 `{ ... }`
    foreign_block,
    /// 声明位置的宏调用，`@M func f() {}`、`@!M class C {}`。带括号时输入是 `macro_input`，
    /// 不带括号时输入是被正常解析的声明节点
    macro_expand_decl,
    /// 参数位置的宏调用，`func f(@M x: Int64)`
    macro_expand_param,

    // ---------------- 声明体与语句块 ----------------

    /// `class` 之后的 `{ ... }`
    class_body,
    /// `interface` 之后的 `{ ... }`
    interface_body,
    /// `struct` 之后的 `{ ... }`
    struct_body,
    /// `enum` 之后的 `{ ... }`
    enum_body,
    /// `extend` 之后的 `{ ... }`
    extend_body,
    /// `{ ... }` 语句块，函数体、循环体、lambda 体与 `if` 分支都是这种节点
    block,
    /// 块内的语句序列，子节点是 `expression_statement` 或块内允许出现的声明
    stmt_list,

    // ---------------- 泛型与参数 ----------------

    /// 声明侧的类型参数表，`func f<T, U>(...)` 中的 `<T, U>`
    type_parameter_list,
    /// 单个类型参数名
    type_parameter,
    /// 使用侧的类型实参表，`Foo<T, U>` 中的 `<T, U>`
    type_argument_list,
    /// `where T <: A & B`
    where_clause,
    /// `T <: A & B`
    generic_constraint,
    /// `(a: Int64, b!: Int64)` 声明侧参数表；lambda 的无括号参数表也使用此标签
    func_param_list,
    /// 参数表之后的返回类型，`func f(): T` 中的 `T`
    ret_type,
    /// 单个参数，含修饰符、注解、主构造器参数上的 `let`/`var`、命名参数的 `!`、类型与默认值
    func_param,
    /// 调用实参、`inout` 实参与注解实参共用的节点
    func_arg,

    // ---------------- 路径 ----------------

    /// 点分路径中的一段：一个名字加可选的类型实参（名字是 `identifier`，也可能是 `kw_this`、
    /// `kw_super` 或内置类型关键字），或在链式成员访问中包裹前置表达式（如 `g().b` 中的 `call_expr`）。
    /// `a.b.c` 与 `g().b.c` 的各段是兄弟节点，平铺在父节点的子节点里
    path_segment,

    // ---------------- 类型 ----------------

    /// 内置类型名，`Int64`、`Bool`、`Rune`、`Nothing`、`Unit` 都是这个标签，
    /// 类型名对应的关键字是 `kw_int64` 之类的叶子
    primitive_type,
    /// 用户定义类型的点分路径，`Foo`、`a.b.C<T>`。子节点是 `path_segment` 与 `dot`
    path_type,
    /// `(T)`
    paren_type,
    /// `(T, U)`
    tuple_type,
    /// `(T, U) -> R`
    func_type,
    /// `?T`
    option_type,
    /// `VArray<T, $N>`
    varray_type,
    /// `VArray<T, $N>` 中的 `$N` 常量类型实参
    constant_type,
    /// `This`
    this_type,

    // ---------------- 模式 ----------------

    /// `_`
    wildcard_pattern,
    /// 绑定标识符，`let x = 0` 中的 `x`，`case y =>` 中的 `y`
    var_pattern,
    /// 字面量模式，`case 1 =>`
    const_pattern,
    /// `(a, b)`
    tuple_pattern,
    /// `Some(x)`、`Color.Red`，构造器名字写成 `path_expr`
    enum_pattern,
    /// `x: Int64`
    type_pattern,
    /// `catch (e: Exception)` 中的 `e: Exception`
    except_type_pattern,
    /// `handle (e: Command)` 中的 `e: Command`
    command_type_pattern,

    // ---------------- 表达式 ----------------

    /// 表达式位置上的 `_`
    wildcard_expr,
    /// 点分路径表达式，`a`、`a.b`、`this.x`、`super.f`、`Int64.Max`、`a?.b`。
    /// 子节点是 `path_segment`、`dot`，带可选后缀时还有 `quest`，各段平铺成兄弟节点
    path_expr,
    /// `f(args)`
    call_expr,
    /// `expr[index]`
    subscript_expr,
    /// `expr?`
    optional_expr,
    /// `(expr)`
    paren_expr,
    /// `(a, b)`
    tuple_lit,
    /// `[a, b]`
    array_lit,
    /// `VArray<T, $N>(...)`
    varray_expr,
    /// `()`
    unit_literal,
    /// 二元运算，`a + b`
    binary_expr,
    /// 前缀 `-` 或 `!`
    unary_expr,
    /// 后缀 `++` 或 `--`
    inc_or_dec_expr,
    /// 赋值与复合赋值，`a = b`、`a += b`
    assign_expr,
    /// `a..b`、`a..=b`，可带步长
    range_expr,
    /// `a is T`
    is_expr,
    /// `a as T`
    as_expr,
    /// `Int64(x)` 形式的类型转换
    type_conv_expr,
    /// `if (cond) { ... } else { ... }`
    if_expr,
    /// `match (selector) { case ... => ... }`
    match_expr,
    /// `case pat where cond => body`
    match_case,
    /// 无选择器的 `match` 中 `case expr => body`
    match_case_other,
    /// `where cond`
    pattern_guard,
    /// `while (cond) { ... }`
    while_expr,
    /// `do { ... } while (cond)`
    do_while_expr,
    /// `for (p in expr) { ... }`
    for_in_expr,
    /// `if`、`while` 条件中的 `let 模式 <- 表达式`
    let_pattern_destructor,
    /// `try { ... } catch (...) { ... } finally { ... }`
    try_expr,
    /// `try (name: File = open(), ...)` 中的一个资源声明
    resource_spec,
    /// `catch (pattern) { ... }`
    catch_clause,
    /// `handle (pattern) { ... }`
    handle_clause,
    /// `finally { ... }`
    finally_clause,
    /// `throw expr`
    throw_expr,
    /// `return expr`
    return_expr,
    /// `break` 或 `continue`
    jump_expr,
    /// `{ a, b => ... }`，子节点含 `func_param_list` 与作为函数体的 `block`
    lambda_expr,
    /// 尾随 lambda，`f { ... }`，子节点是作为被调者的表达式与一个 `lambda_expr`
    trailing_closure_expr,
    /// `spawn { ... }`，子节点里的任务是一个 `lambda_expr`
    spawn_expr,
    /// `synchronized (mutex) { ... }`
    synchronized_expr,
    /// `unsafe { ... }`
    unsafe_expr,
    /// `quote(...)`，子节点是 `token_part`、`quote_interpolation`
    quote_expr,
    /// 包含 `${...}` 插值的字符串字面量整体，单行与多行形式共用此标签，
    /// 子节点是交替的 `string_content` 与 `interpolation_expr`
    str_interpolation_expr,
    /// `${...}` 插值片段，节点文本包含 `${` 与 `}`，子节点是一个 `block`
    interpolation_expr,
    /// `@IfAvailable(...)`
    if_available_expr,
    /// 表达式位置的宏调用，`@M(...)`
    macro_expand_expr,
    /// `perform expr`
    perform_expr,
    /// `resume expr`、`resume expr with ...`、`resume expr throwing ...`
    resume_expr,

    // ---------------- 语句 ----------------

    /// 语句位置上的表达式，后面可带 `;`
    expression_statement,

    // ---------------- 宏与 quote 的原始词法单元片段 ----------------

    /// 宏调用名之后的 `[...]` 属性，内部词法单元不做语法分析
    macro_attributes,
    /// 宏调用的括号输入，`(` 与 `)` 之间的词法单元不做语法分析
    macro_input,
    /// quote 表达式内部一段不做语法分析的词法单元
    token_part,
    /// quote 表达式中的 `$name` 或 `$(expr)` 插值
    quote_interpolation,

    // ---------------- 错误恢复 ----------------

    /// 无法按语法解析的一段词法单元，保留在树中以维持无损
    error_node,
};

/// 编译期构造的词法标签到 CST 标签查找表，`.comment` 与 `.sentinel` 映射为 `null`。
const token_to_syntax_table: [@typeInfo(TokenTag).@"enum".field_names.len]?SyntaxKind = blk: {
    var table: [@typeInfo(TokenTag).@"enum".field_names.len]?SyntaxKind = @splat(null);
    for (std.enums.values(TokenTag)) |tag| {
        table[@backingInt(tag)] = switch (tag) {
            .nl => .newline,
            .end => .eof,
            .comment, .sentinel => null,
            inline else => |t| @field(SyntaxKind, @tagName(t)),
        };
    }
    break :blk table;
};

/// 把词法单元标签转换为 CST 节点标签。
///
/// `comment` 需按注释文本区分单行、块注释与文档注释，`sentinel` 是解析器内部占位，两者返回 null。
/// `??`、`>>`、`>>=`、`>=`、`unit_literal`、`annotation` 及带插值的 `str_interpolation_expr`
/// 由语法分析阶段按上下文组合或展开。
pub inline fn toSyntaxKind(token_tag: TokenTag) ?SyntaxKind {
    return token_to_syntax_table[@backingInt(token_tag)];
}

/// 按注释源码文本区分单行注释、文档注释与块注释。
///
/// 文档注释为 `///...`（不含 `////...`）与 `/**...*/`（不含 `/**/` 与 `/***...`）；
/// 其余 `//` 开头为单行注释，`/*` 开头为块注释。
pub fn classifyComment(text: []const u8) SyntaxKind {
    if (std.mem.startsWith(u8, text, "//")) {
        if (text.len >= 3 and text[2] == '/' and (text.len == 3 or text[3] != '/')) {
            return .doc_comment;
        }
        return .line_comment;
    }
    if (std.mem.startsWith(u8, text, "/**") and text.len >= 5 and text[3] != '*') {
        return .doc_comment;
    }
    return .block_comment;
}

/// 把词法单元标签与其源码文本转换为 CST 叶子标签。
///
/// 注释按文本细分为单行注释、块注释与文档注释；`sentinel` 是解析器内部占位，映射为 `illegal`。
pub inline fn tokenToSyntaxKind(tag: TokenTag, text: []const u8) SyntaxKind {
    if (tag == .comment) return classifyComment(text);
    return token_to_syntax_table[@backingInt(tag)] orelse .illegal;
}

test "SyntaxKind 为空白、换行与三类注释提供独立标签" {
    const trivia = [_]SyntaxKind{ .whitespace, .newline, .line_comment, .block_comment, .doc_comment };
    for (trivia, 0..) |kind, i| {
        for (trivia[i + 1 ..]) |other| try std.testing.expect(kind != other);
    }
}

test "组合运算符在 CST 中是单个标签" {
    try std.testing.expect(SyntaxKind.coalescing != SyntaxKind.quest);
    try std.testing.expect(SyntaxKind.rshift != SyntaxKind.greater);
    try std.testing.expect(SyntaxKind.rshift_assign != SyntaxKind.greater_equal);
    try std.testing.expect(SyntaxKind.greater_equal != SyntaxKind.assign);
}

test "为便于扫描而存在的词法标签不出现在 CST 中" {
    const names = @typeInfo(SyntaxKind).@"enum".field_names;
    for (names) |name| {
        for ([_][]const u8{ "sentinel", "end", "nl", "comment" }) |absent| {
            try std.testing.expect(!std.mem.eql(u8, name, absent));
        }
    }
}

test "有对应节点的词法单元标签逐个转换" {
    try std.testing.expectEqual(@as(?SyntaxKind, .newline), toSyntaxKind(.nl));
    try std.testing.expectEqual(@as(?SyntaxKind, .eof), toSyntaxKind(.end));
    try std.testing.expectEqual(@as(?SyntaxKind, .kw_func), toSyntaxKind(.kw_func));
    try std.testing.expectEqual(@as(?SyntaxKind, .identifier), toSyntaxKind(.identifier));
    try std.testing.expectEqual(@as(?SyntaxKind, .l_curl), toSyntaxKind(.l_curl));
    try std.testing.expectEqual(@as(?SyntaxKind, .illegal), toSyntaxKind(.illegal));
    try std.testing.expectEqual(@as(?SyntaxKind, null), toSyntaxKind(.comment));
    try std.testing.expectEqual(@as(?SyntaxKind, null), toSyntaxKind(.sentinel));
}

test "除注释与占位外每个词法单元标签都能转换" {
    for (std.enums.values(TokenTag)) |tag| {
        const converted = toSyntaxKind(tag);
        switch (tag) {
            .comment, .sentinel => try std.testing.expectEqual(@as(?SyntaxKind, null), converted),
            else => try std.testing.expect(converted != null),
        }
    }
}

test "注释文本按形态分类" {
    try std.testing.expectEqual(SyntaxKind.line_comment, classifyComment("//"));
    try std.testing.expectEqual(SyntaxKind.line_comment, classifyComment("// note"));
    try std.testing.expectEqual(SyntaxKind.line_comment, classifyComment("//// note"));
    try std.testing.expectEqual(SyntaxKind.doc_comment, classifyComment("///"));
    try std.testing.expectEqual(SyntaxKind.doc_comment, classifyComment("/// doc"));
    try std.testing.expectEqual(SyntaxKind.doc_comment, classifyComment("/** x */"));
    try std.testing.expectEqual(SyntaxKind.block_comment, classifyComment("/* note */"));
    try std.testing.expectEqual(SyntaxKind.block_comment, classifyComment("/**/"));
    try std.testing.expectEqual(SyntaxKind.block_comment, classifyComment("/*** x */"));
}

test "词法单元标签与源码文本共同确定 CST 叶子标签" {
    try std.testing.expectEqual(SyntaxKind.identifier, tokenToSyntaxKind(.identifier, "x"));
    try std.testing.expectEqual(SyntaxKind.newline, tokenToSyntaxKind(.nl, "\n"));
    try std.testing.expectEqual(SyntaxKind.eof, tokenToSyntaxKind(.end, ""));
    try std.testing.expectEqual(SyntaxKind.doc_comment, tokenToSyntaxKind(.comment, "/// doc"));
    try std.testing.expectEqual(SyntaxKind.line_comment, tokenToSyntaxKind(.comment, "// note"));
    try std.testing.expectEqual(SyntaxKind.illegal, tokenToSyntaxKind(.sentinel, ""));
}
