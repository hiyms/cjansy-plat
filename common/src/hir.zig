// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 高层中间表示（HIR）数据结构，由 GreenTree 经由 lower 阶段生成。
//!
//! HIR 去除源码中的空白、注释与纯语法标点，保留语义分析、名称解析、类型检查与静态检查
//! 所需的抽象语法结构与源码字节区间（`TextRange`）。每个节点都携带覆盖其源码范围的
//! `range`，名称位置另外携带 `Name` 中的独立区间，供诊断定位到具体标识符。
//!
//! 括号表达式与括号类型在 HIR 中折叠，其 `range` 取内层表达式或内层的区间。
//!
//! 命名约定：`Hir` 前缀用于跨声明项共用的节点类型（`HirType`、`HirExpr`、`HirStmt`、
//! `HirPattern`、`HirItem`、`HirCondition`、`HirParam`、`HirCallArg`、`HirTypeElement`、
//! `HirFile`），其余载荷结构体、字面量与运算符枚举按语言术语命名。
//!
//! 内存约定：所有 HIR 节点及其内部切片与子指针通常由所属 `arena` 分配（如 `File.allocator()`
//! 或专用 `ArenaAllocator`），节点在构建完成后按不可变数据使用，并随所属 `arena` 统一释放，
//! 调用者不得单独释放其中任何指针或切片。

const std = @import("std");
const source_mod = @import("source.zig");
const syntax_mod = @import("syntax.zig");

const FileId = source_mod.FileId;
const TextRange = source_mod.TextRange;
const SyntaxKind = syntax_mod.SyntaxKind;

/// 源码中的一个名字及其字节区间。
pub const Name = struct {
    /// 名字文本，已去掉包围原始标识符与包名的反引号。
    text: []const u8,
    /// 是否由反引号包围。用于区分关键字与反引号包围的同名原始标识符。
    is_raw: bool,
    /// 名字在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 声明修饰符。
///
/// `const_` 表示 `const func` 与 `const init` 上的上下文关键字，绑定类别使用 `BindingKind`。
pub const Modifier = enum(u8) {
    public,
    private,
    protected,
    internal,
    static,
    open,
    sealed,
    abstract,
    override,
    redef,
    unsafe,
    mut,
    operator,
    const_,
    common,
    specific,
    late,
};

/// 注解，`@Name[args]` 或点分限定名 `@a.b.Name[args]`。
pub const Annotation = struct {
    /// 注解名的各个名字段，至少一段。
    path: []const Name,
    /// 方括号内的注解实参；无实参时为空切片。
    args: []const HirCallArg = &.{},
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 二元运算符标签。赋值运算符见 `AssignOp`，区间运算符见 `HirExpr.range`。
pub const BinaryOp = enum(u8) {
    add,
    sub,
    mul,
    div,
    mod,
    exp,

    eq,
    ne,
    lt,
    le,
    gt,
    ge,

    logical_and,
    logical_or,

    bit_and,
    bit_or,
    bit_xor,
    lshift,
    rshift,

    coalescing,
    pipeline,
    composition,

    /// 编译期构造的 CST 运算符标签到二元运算符查找表，非二元运算符映射为 null。
    const syntax_table: [@typeInfo(SyntaxKind).@"enum".field_names.len]?BinaryOp = blk: {
        var table: [@typeInfo(SyntaxKind).@"enum".field_names.len]?BinaryOp = @splat(null);
        table[@backingInt(SyntaxKind.add)] = .add;
        table[@backingInt(SyntaxKind.sub)] = .sub;
        table[@backingInt(SyntaxKind.mul)] = .mul;
        table[@backingInt(SyntaxKind.div)] = .div;
        table[@backingInt(SyntaxKind.mod)] = .mod;
        table[@backingInt(SyntaxKind.exp)] = .exp;
        table[@backingInt(SyntaxKind.equal)] = .eq;
        table[@backingInt(SyntaxKind.not_equal)] = .ne;
        table[@backingInt(SyntaxKind.less)] = .lt;
        table[@backingInt(SyntaxKind.less_equal)] = .le;
        table[@backingInt(SyntaxKind.greater)] = .gt;
        table[@backingInt(SyntaxKind.greater_equal)] = .ge;
        table[@backingInt(SyntaxKind.logical_and)] = .logical_and;
        table[@backingInt(SyntaxKind.logical_or)] = .logical_or;
        table[@backingInt(SyntaxKind.bit_and)] = .bit_and;
        table[@backingInt(SyntaxKind.bit_or)] = .bit_or;
        table[@backingInt(SyntaxKind.bit_xor)] = .bit_xor;
        table[@backingInt(SyntaxKind.lshift)] = .lshift;
        table[@backingInt(SyntaxKind.rshift)] = .rshift;
        table[@backingInt(SyntaxKind.coalescing)] = .coalescing;
        table[@backingInt(SyntaxKind.pipeline)] = .pipeline;
        table[@backingInt(SyntaxKind.composition)] = .composition;
        break :blk table;
    };

    /// 把 CST 运算符节点标签转换为对应的二元运算符；非二元运算符标签返回 null。
    pub inline fn fromSyntaxKind(kind: SyntaxKind) ?BinaryOp {
        return syntax_table[@backingInt(kind)];
    }
};

/// 赋值与复合赋值运算符标签。
pub const AssignOp = enum(u8) {
    assign,
    add_assign,
    sub_assign,
    mul_assign,
    exp_assign,
    div_assign,
    mod_assign,
    logical_and_assign,
    logical_or_assign,
    bit_and_assign,
    bit_or_assign,
    bit_xor_assign,
    lshift_assign,
    rshift_assign,

    /// 编译期构造的 CST 运算符标签到赋值运算符查找表，非赋值运算符映射为 null。
    const syntax_table: [@typeInfo(SyntaxKind).@"enum".field_names.len]?AssignOp = blk: {
        var table: [@typeInfo(SyntaxKind).@"enum".field_names.len]?AssignOp = @splat(null);
        table[@backingInt(SyntaxKind.assign)] = .assign;
        table[@backingInt(SyntaxKind.add_assign)] = .add_assign;
        table[@backingInt(SyntaxKind.sub_assign)] = .sub_assign;
        table[@backingInt(SyntaxKind.mul_assign)] = .mul_assign;
        table[@backingInt(SyntaxKind.exp_assign)] = .exp_assign;
        table[@backingInt(SyntaxKind.div_assign)] = .div_assign;
        table[@backingInt(SyntaxKind.mod_assign)] = .mod_assign;
        table[@backingInt(SyntaxKind.logical_and_assign)] = .logical_and_assign;
        table[@backingInt(SyntaxKind.logical_or_assign)] = .logical_or_assign;
        table[@backingInt(SyntaxKind.bit_and_assign)] = .bit_and_assign;
        table[@backingInt(SyntaxKind.bit_or_assign)] = .bit_or_assign;
        table[@backingInt(SyntaxKind.bit_xor_assign)] = .bit_xor_assign;
        table[@backingInt(SyntaxKind.lshift_assign)] = .lshift_assign;
        table[@backingInt(SyntaxKind.rshift_assign)] = .rshift_assign;
        break :blk table;
    };

    /// 把 CST 运算符节点标签转换为对应的赋值运算符；非赋值运算符标签返回 null。
    pub inline fn fromSyntaxKind(kind: SyntaxKind) ?AssignOp {
        return syntax_table[@backingInt(kind)];
    }
};

/// 前缀一元运算符标签。
///
/// 仓颉语言中算术取负为 `-`，逻辑取反与按位取反统一使用 `!`。
pub const UnaryOp = enum(u8) {
    /// 算术取负 `-`
    neg,
    /// 逻辑取反与按位取反 `!`
    not,

    /// 把 CST 运算符节点标签转换为对应的一元运算符；非一元运算符标签返回 null。
    pub inline fn fromSyntaxKind(kind: SyntaxKind) ?UnaryOp {
        return switch (kind) {
            .sub => .neg,
            .not => .not,
            else => null,
        };
    }
};

/// 后缀自增自减运算符标签。
pub const IncDecOp = enum(u8) {
    /// `++`
    incr,
    /// `--`
    decr,

    /// 把 CST 运算符节点标签转换为自增自减运算符；其余标签返回 null。
    pub inline fn fromSyntaxKind(kind: SyntaxKind) ?IncDecOp {
        return switch (kind) {
            .incr => .incr,
            .decr => .decr,
            else => null,
        };
    }
};

/// 跳转关键字标签。
pub const JumpOp = enum(u8) {
    /// `break`
    break_,
    /// `continue`
    continue_,

    /// 把 CST 关键字标签转换为跳转标签；其余标签返回 null。
    pub inline fn fromSyntaxKind(kind: SyntaxKind) ?JumpOp {
        return switch (kind) {
            .kw_break => .break_,
            .kw_continue => .continue_,
            else => null,
        };
    }
};

/// 整数字面量显式类型后缀。
pub const IntSuffix = enum(u8) {
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
};

/// 浮点数字面量显式类型后缀。
pub const FloatSuffix = enum(u8) {
    f16,
    f32,
    f64,
};

/// 绑定类别，对应 `let`、`var` 与 `const`。
pub const BindingKind = enum(u8) {
    /// 不可变绑定 `let`
    let_,
    /// 可变绑定 `var`
    var_,
    /// 编译期常量绑定 `const`
    const_,
};

/// 字符串字面量的书写形式。
pub const StrKind = enum(u8) {
    /// 单行字符串
    single,
    /// 多行字符串
    multiline,
    /// 多行原始字符串
    raw_multiline,
};

/// 类型路径中的单个段：一个名字与可选类型实参。
pub const TypePathSegment = struct {
    /// 段名。
    name: Name,
    /// 该段的类型实参列表；无实参时为空切片。
    type_args: []const HirType = &.{},
};

/// 类型位置的点分路径载荷，例如 `Int64`、`a.b.List<Int64>`。
pub const PathType = struct {
    /// 点分路径的各个段。
    segments: []const TypePathSegment,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 元组类型或函数类型中的单个元素类型，可带可读性标签。
pub const HirTypeElement = struct {
    /// 可选标签名（`(x: Int64, y: Int64)` 中的 `x`）。
    label: ?Name = null,
    /// 元素类型。
    ty: *const HirType,
    /// 元素在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 可空类型载荷，例如 `?T`。
pub const OptionalType = struct {
    /// 被包裹的内层类型。
    inner: *const HirType,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 元组类型载荷，例如 `(Int64, String)` 或 `(x: Int64, y: Int64)`。
pub const TupleType = struct {
    /// 元组各元素类型。
    elements: []const HirTypeElement,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 函数类型载荷，例如 `(Int64) -> Bool` 或 `(x: Int64) -> Bool`。
pub const FuncType = struct {
    /// 参数类型列表。
    params: []const HirTypeElement = &.{},
    /// 返回类型。
    ret: *const HirType,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 值数组类型载荷，例如 `VArray<Int64, $4>`。
pub const VArrayType = struct {
    /// 元素类型。
    elem: *const HirType,
    /// 长度字面量的源码文本（`$4` 中的 `4`），不保存为定宽数值。
    size: []const u8,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `This` 类型载荷。
pub const ThisType = struct {
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// HIR 类型引用。
pub const HirType = union(enum) {
    path: PathType,
    option: OptionalType,
    tuple: TupleType,
    func: FuncType,
    varray: VArrayType,
    this: ThisType,

    /// 统一获取当前类型节点覆盖的源文件字节区间。
    ///
    /// 指针内存约定：`self` 仅作只读借用，不转移所有权。
    pub inline fn range(self: *const HirType) TextRange {
        return switch (self.*) {
            inline else => |*payload| payload.range,
        };
    }
};

/// 整数字面量表达式载荷。
///
/// 字面量在宏实参等非表达式位置可以超出所有整数类型的范围，因此这里不保存解析后的数值，
/// 只保留完整源码文本。需要数值的阶段按 `text` 解析并做类型范围检查。
pub const IntLit = struct {
    /// 字面量源码文本，包含进制前缀、下划线分隔符与类型后缀。
    text: []const u8,
    /// 可选显式类型后缀（如 `i32`、`u64`）；未显式指定后缀时为 null。
    suffix: ?IntSuffix = null,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 浮点数字面量表达式载荷。
///
/// 与 `IntLit` 相同，不保存解析后的数值，避免对字面量大小做任何预设。
pub const FloatLit = struct {
    /// 字面量源码文本，包含小数点、指数、下划线分隔符与类型后缀。
    text: []const u8,
    /// 可选显式类型后缀（如 `f32`、`f64`）；未显式指定后缀时为 null。
    suffix: ?FloatSuffix = null,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 字符字面量表达式载荷。
pub const RuneLit = struct {
    /// 解码后的码点值；`b'x'` 形式的字节字面量取 `0` 到 `255`。
    value: u21,
    /// 是否为 `b'x'` 字节字面量。
    is_byte: bool,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 字符串字面量表达式载荷。
pub const StringLit = struct {
    /// 字符串字面量的源码文本内容，不含插值。
    text: []const u8,
    /// 书写形式。
    kind: StrKind,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 字符串插值中的一段纯文本。
pub const StrText = struct {
    /// 文本片段内容，生命周期与所属 `arena` 一致。
    text: []const u8,
    /// 片段在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 字符串插值中的一段 `${...}`。
pub const StrInterpolation = struct {
    /// 插值内容，语法位置上是一个语句块。
    body: *const BlockExpr,
    /// 片段在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 字符串插值片段。
pub const StrPart = union(enum) {
    text: StrText,
    interpolation: StrInterpolation,
};

/// 带插值的字符串字面量表达式载荷。
pub const StrInterp = struct {
    /// 按源码顺序交替排列的文本片段与插值片段。
    parts: []const StrPart,
    /// 书写形式。
    kind: StrKind,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 布尔字面量表达式载荷。
pub const BoolLit = struct {
    /// 布尔值（`true` 或 `false`）。
    value: bool,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 无载荷节点的字节区间，用于 `()`、`_`、`break` 等不含子结构的节点。
pub const Bare = struct {
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 表达式路径中的单个段：名字、可选类型实参。
pub const ExprPathSegment = struct {
    /// 段名；`this`、`super`、`This` 与内置类型名也作为段名保存。
    name: Name,
    /// 该段的类型实参列表；无实参时为空切片。
    type_args: []const HirType = &.{},
};

/// 路径表达式载荷，例如 `x`、`std.io.println`、`this.x`、`Int64.Max`。
pub const PathExpr = struct {
    /// 点分路径的各个段，至少一段。
    segments: []const ExprPathSegment,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 字段访问表达式载荷，例如 `obj.field` 与带显式类型实参的成员引用 `obj.method<Int64>`。
pub const FieldExpr = struct {
    /// 接收者表达式。
    base: *const HirExpr,
    /// 字段或成员名称。
    name: Name,
    /// 成员的类型实参列表；无实参时为空切片。
    type_args: []const HirType = &.{},
    /// 整个字段访问表达式在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 后缀可选标记载荷，例如 `a?.b`、`c?(d)`、`e?[f]` 中的 `?`。
pub const OptionalExpr = struct {
    /// 被施加 `?` 的操作数。
    operand: *const HirExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 函数或方法调用中的单个实参。
pub const HirCallArg = struct {
    /// 可选命名实参名称（`name: expr` 中的 `name`）；位置实参为 null。
    name: ?Name = null,
    /// 是否为 `inout` 引用传值实参，仅用于调用 `CFunc`。
    is_inout: bool = false,
    /// 实参表达式。
    value: *const HirExpr,
    /// 整个实参在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 函数或方法调用表达式载荷。
pub const CallExpr = struct {
    /// 被调用的目标表达式。
    callee: *const HirExpr,
    /// 圆括号内的实参列表。
    args: []const HirCallArg = &.{},
    /// 可选尾随闭包 `f { ... }`，作为末尾的一个函数实参。
    trailing_lambda: ?*const HirExpr = null,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 下标索引表达式载荷，例如 `arr[i]`、多维索引 `matrix[i, j]` 与切片下标 `arr[1..5]`。
pub const IndexExpr = struct {
    /// 被索引的容器表达式。
    base: *const HirExpr,
    /// 索引表达式列表，区间表达式与开区间下标使用 `HirExpr.range`。
    indices: []const HirExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 后缀自增自减表达式载荷。
pub const IncDecExpr = struct {
    /// 自增自减运算符。
    op: IncDecOp,
    /// 操作数表达式。
    operand: *const HirExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 前缀一元运算表达式载荷。
pub const UnaryExpr = struct {
    /// 前缀一元运算符。
    op: UnaryOp,
    /// 操作数表达式。
    operand: *const HirExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 二元运算表达式载荷。
pub const BinaryExpr = struct {
    /// 二元运算符。
    op: BinaryOp,
    /// 左操作数表达式。
    lhs: *const HirExpr,
    /// 右操作数表达式。
    rhs: *const HirExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 赋值与复合赋值表达式载荷。
pub const AssignExpr = struct {
    /// 赋值运算符。
    op: AssignOp,
    /// 赋值目标表达式。
    lhs: *const HirExpr,
    /// 赋值来源表达式。
    rhs: *const HirExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 区间表达式载荷，例如 `a..b`、`a..=b`、`a..=b:step`，以及下标位置的 `..b`、`a..`。
pub const RangeExpr = struct {
    /// 可选起始端点；下标位置的 `..b` 为 null。
    start: ?*const HirExpr = null,
    /// 可选结束端点；下标位置的 `a..` 为 null。
    end: ?*const HirExpr = null,
    /// 是否为闭区间 `..=`。
    inclusive: bool,
    /// 可选步长表达式。
    step: ?*const HirExpr = null,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `is` 类型判定表达式载荷。
pub const IsExpr = struct {
    /// 被判定类型的操作数。
    operand: *const HirExpr,
    /// 判定目标类型。
    ty: *const HirType,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `as` 类型转换表达式载荷。
pub const AsExpr = struct {
    /// 被转换的操作数。
    operand: *const HirExpr,
    /// 转换目标类型。
    ty: *const HirType,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 内置类型转换表达式载荷，例如 `Int64(x)`、`Rune(65)`。
pub const TypeConvExpr = struct {
    /// 目标内置类型。
    ty: *const HirType,
    /// 被转换的表达式。
    value: *const HirExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `VArray<T, $N>(...)` 构造表达式载荷。
pub const VArrayExpr = struct {
    /// 值数组类型。
    ty: *const HirType,
    /// 圆括号内的实参。
    args: []const HirCallArg = &.{},
    /// 可选尾随闭包。
    trailing_lambda: ?*const HirExpr = null,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 元组字面量载荷，例如 `(1, 2)`。
pub const TupleLit = struct {
    /// 按源码顺序排列的元素表达式。
    elements: []const HirExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 数组字面量中的单个元素，可带 `*` 展开前缀。
pub const ArrayElement = struct {
    /// 是否带 `*` 展开前缀，例如 `[*xs, y]` 中的 `*xs`。
    spread: bool = false,
    /// 元素表达式。
    value: *const HirExpr,
    /// 元素在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 数组字面量载荷，例如 `[a, b]`。
pub const ArrayLit = struct {
    /// 按源码顺序排列的元素。
    elements: []const ArrayElement,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 语句块载荷，例如 `{ let x = 1; x + 2 }`。
pub const BlockExpr = struct {
    /// 块内除尾表达式之外的语句序列。
    stmts: []const HirStmt = &.{},
    /// 可选尾表达式，作为语句块的求值结果。
    tail: ?*const HirExpr = null,
    /// 节点在源文件中的左闭右开字节区间；`range` 不含外层花括号时对应 `match` 分支体。
    range: TextRange,
};

/// `if` 或 `while` 中的 `let` 模式解构条件，例如 `let Some(x) <- value`。
pub const LetDestructor = struct {
    /// 候选模式列表，以 `|` 分隔。
    patterns: []const HirPattern,
    /// 右侧被解构的表达式。
    value: *const HirExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `if` 与 `while` 的条件。
pub const HirCondition = union(enum) {
    expr: *const HirExpr,
    let_destructor: LetDestructor,
};

/// 条件分支表达式载荷，例如 `if (cond) { ... } else { ... }`。
pub const IfExpr = struct {
    /// 条件。
    condition: HirCondition,
    /// 条件成立时执行的语句块。
    then_branch: *const BlockExpr,
    /// 可选 `else` 分支，通常为 `.block` 或嵌套 `.if_expr`。
    else_branch: ?*const HirExpr = null,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `match` 中的模式分支载荷，例如 `case Some(x) | None where cond => ...`。
pub const PatternCase = struct {
    /// 候选模式列表，以 `|` 分隔。
    patterns: []const HirPattern,
    /// 可选模式守卫 `where cond`。
    guard: ?*const HirExpr = null,
    /// 分支体。
    body: *const BlockExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 无选择器 `match` 中的表达式分支载荷，例如 `case x => ...`。
pub const ExprCase = struct {
    /// 分支表达式，`case _ =>` 使用 `.wildcard`。
    value: *const HirExpr,
    /// 分支体。
    body: *const BlockExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `match` 分支。
pub const MatchCase = union(enum) {
    pattern: PatternCase,
    expr: ExprCase,
};

/// `match` 表达式载荷。
pub const MatchExpr = struct {
    /// 可选选择器；无选择器 `match` 的各分支使用表达式分支。
    selector: ?*const HirExpr = null,
    /// 分支列表。
    cases: []const MatchCase = &.{},
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 循环表达式载荷，例如 `while (cond) { ... }`。
pub const WhileExpr = struct {
    /// 循环条件。
    condition: HirCondition,
    /// 循环体语句块。
    body: *const BlockExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `do { ... } while (cond)` 表达式载荷。
pub const DoWhileExpr = struct {
    /// 循环体语句块。
    body: *const BlockExpr,
    /// 循环条件。
    condition: *const HirExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `for (pattern in iterable) { ... }` 表达式载荷。
pub const ForInExpr = struct {
    /// 迭代变量模式。
    pattern: *const HirPattern,
    /// 被迭代的表达式。
    iterable: *const HirExpr,
    /// 可选模式守卫 `where cond`。
    guard: ?*const HirExpr = null,
    /// 循环体语句块。
    body: *const BlockExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `try` 语句的单个资源声明，例如 `try (f: File = open()) { ... }` 中的 `f: File = open()`。
pub const Resource = struct {
    /// 资源名称。
    name: Name,
    /// 可选类型标注。
    ty: ?*const HirType = null,
    /// 可选初始化表达式。
    init: ?*const HirExpr = null,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `catch` 子句载荷。
pub const CatchClause = struct {
    /// 捕获模式。
    pattern: *const HirPattern,
    /// 处理语句块。
    body: *const BlockExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `handle` 子句载荷。
pub const HandleClause = struct {
    /// 效应命令模式。
    pattern: *const HirPattern,
    /// 处理语句块。
    body: *const BlockExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `try` 之后的处理子句。
pub const TryClause = union(enum) {
    catch_: CatchClause,
    handle: HandleClause,
};

/// `try` 表达式载荷，例如 `try { ... } catch (e) { ... } finally { ... }`。
pub const TryExpr = struct {
    /// 资源声明列表；无资源时为切片为空。
    resources: []const Resource = &.{},
    /// 受保护语句块。
    body: *const BlockExpr,
    /// 按源码顺序排列的 `catch` 与 `handle` 子句。
    clauses: []const TryClause = &.{},
    /// 可选 `finally` 语句块。
    finally: ?*const BlockExpr = null,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `throw expr` 表达式载荷。
pub const ThrowExpr = struct {
    /// 抛出的表达式。
    value: *const HirExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `return` 表达式载荷。
pub const ReturnExpr = struct {
    /// 可选返回值表达式。
    value: ?*const HirExpr = null,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `break` 或 `continue` 表达式载荷。
pub const JumpExpr = struct {
    /// 跳转关键字。
    op: JumpOp,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// lambda 表达式载荷，例如 `{ x => x + 1 }`。
pub const LambdaExpr = struct {
    /// 参数表之前的内置注解。
    annotations: []const Annotation = &.{},
    /// 参数列表；省略参数时为切片为空。
    params: []const Param = &.{},
    /// 参数表是否以 `...` 结尾。
    is_variadic: bool = false,
    /// lambda 体语句块。
    body: *const BlockExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `spawn` 表达式载荷，例如 `spawn (ctx) { ... }`。
pub const SpawnExpr = struct {
    /// 可选上下文表达式。
    context: ?*const HirExpr = null,
    /// 任务表达式，通常为 `.lambda`。
    task: *const HirExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `synchronized (mutex) { ... }` 表达式载荷。
pub const SynchronizedExpr = struct {
    /// 互斥量表达式。
    mutex: *const HirExpr,
    /// 受保护语句块。
    body: *const BlockExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `unsafe { ... }` 表达式载荷。
pub const UnsafeExpr = struct {
    /// 语句块。
    body: *const BlockExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `quote(...)` 中的一段词法单元，内容由 `range` 从源文件取得。
pub const QuotePart = union(enum) {
    /// 未插值的词法单元片段。
    token: TextRange,
    /// `$(expr)` 或 `$name` 插值，`$name` 表示为单段路径表达式。
    interpolation: *const HirExpr,
};

/// `quote(...)` 表达式载荷。
pub const QuoteExpr = struct {
    /// 按源码顺序排列的词法单元片段与插值片段。
    parts: []const QuotePart = &.{},
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 宏调用的名字与标记，供表达式、声明、参数与枚举构造器共用。
pub const MacroCall = struct {
    /// 宏名的各个名字段，至少一段。
    path: []const Name,
    /// 是否使用 `@!` 宏调用形式。
    has_bang: bool = false,
    /// `[...]` 宏属性的字节区间；无属性时为 null。
    attributes: ?TextRange = null,
    /// 括号输入的字节区间；无括号输入时为 null。
    input: ?TextRange = null,
};

/// 表达式位置的宏调用载荷。宏的括号输入保留在 CST 中。
pub const MacroCallExpr = struct {
    /// 宏名与调用标记。
    call: MacroCall,
    /// 链式宏调用中内层宏调用表达式。
    inner: ?*const HirExpr = null,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `@IfAvailable(...)` 表达式载荷。
pub const IfAvailableExpr = struct {
    /// 圆括号内的实参。
    args: []const HirCallArg,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `perform expr` 表达式载荷。
pub const PerformExpr = struct {
    /// 被执行的效应命令表达式。
    value: *const HirExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `resume` 表达式中的附加关键字。
pub const ResumeModifier = enum(u8) {
    /// `with expr`
    with,
    /// `throwing expr`
    throwing,
};

/// `resume` 表达式载荷，例如 `resume value with expr throwing expr`。
pub const ResumeExpr = struct {
    /// 可选恢复值表达式。
    value: ?*const HirExpr = null,
    /// 可选附加关键字。
    modifier: ?ResumeModifier = null,
    /// 附加关键字之后的表达式。
    modifier_value: ?*const HirExpr = null,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// HIR 表达式节点。
pub const HirExpr = union(enum) {
    int_lit: IntLit,
    float_lit: FloatLit,
    rune_lit: RuneLit,
    string_lit: StringLit,
    str_interp: StrInterp,
    bool_lit: BoolLit,
    unit_lit: Bare,
    wildcard: Bare,
    path: PathExpr,
    field: FieldExpr,
    optional: OptionalExpr,
    call: CallExpr,
    index: IndexExpr,
    inc_dec: IncDecExpr,
    unary: UnaryExpr,
    binary: BinaryExpr,
    assign: AssignExpr,
    range_expr: RangeExpr,
    is_expr: IsExpr,
    as_expr: AsExpr,
    type_conv: TypeConvExpr,
    varray: VArrayExpr,
    tuple_lit: TupleLit,
    array_lit: ArrayLit,
    block: BlockExpr,
    if_expr: IfExpr,
    match_expr: MatchExpr,
    while_expr: WhileExpr,
    do_while_expr: DoWhileExpr,
    for_in_expr: ForInExpr,
    try_expr: TryExpr,
    throw_expr: ThrowExpr,
    return_expr: ReturnExpr,
    jump: JumpExpr,
    lambda: LambdaExpr,
    spawn: SpawnExpr,
    synchronized: SynchronizedExpr,
    unsafe: UnsafeExpr,
    quote: QuoteExpr,
    macro_call: MacroCallExpr,
    if_available: IfAvailableExpr,
    perform: PerformExpr,
    resume_expr: ResumeExpr,

    /// 统一获取当前表达式节点覆盖的源文件字节区间。
    ///
    /// 指针内存约定：`self` 仅作只读借用，不转移所有权。
    pub inline fn range(self: *const HirExpr) TextRange {
        return switch (self.*) {
            inline else => |*payload| payload.range,
        };
    }
};

/// 通配符模式载荷。
pub const WildcardPattern = struct {
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 变量绑定模式载荷。
pub const BindingPattern = struct {
    /// 绑定变量名称。
    name: Name,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 字面量常量模式载荷。
pub const ConstPattern = struct {
    /// 字面量表达式，负数字面量的负号包含在值表达式内。
    value: *const HirExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 元组模式载荷。
pub const TuplePattern = struct {
    /// 按源码顺序排列的元素模式。
    elements: []const HirPattern,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 枚举构造器模式载荷，例如 `Some(x)`、`Color.Red`。
pub const EnumPattern = struct {
    /// 构造器路径。
    path: PathType,
    /// 圆括号内的子模式列表；无子模式时为空切片。
    args: []const HirPattern = &.{},
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 类型模式载荷，例如 `x: Int64`、`_: Int64`。
pub const TypePattern = struct {
    /// 可选绑定名称；`_` 为 null。
    name: ?Name = null,
    /// 绑定的类型。
    ty: *const HirType,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// `catch` 与 `handle` 的类型模式载荷，例如 `e: Exception`、`e: A | B`。
pub const ClausePattern = struct {
    /// 可选绑定名称；`_` 为 null。
    name: ?Name = null,
    /// 类型列表，至少一项。
    types: []const HirType,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// HIR 模式节点。
pub const HirPattern = union(enum) {
    wildcard: WildcardPattern,
    binding: BindingPattern,
    const_: ConstPattern,
    tuple: TuplePattern,
    enum_: EnumPattern,
    typed: TypePattern,
    except_type: ClausePattern,
    command_type: ClausePattern,

    /// 统一获取当前模式节点覆盖的源文件字节区间。
    ///
    /// 指针内存约定：`self` 仅作只读借用，不转移所有权。
    pub inline fn range(self: *const HirPattern) TextRange {
        return switch (self.*) {
            inline else => |*payload| payload.range,
        };
    }
};

/// 局部绑定语句或成员字段声明载荷（`let` / `var` / `const`）。
pub const Binding = struct {
    /// 声明修饰符，顶层与成员位置可为空切片。
    modifiers: []const Modifier = &.{},
    /// 声明上的注解。
    annotations: []const Annotation = &.{},
    /// 绑定类别。
    kind: BindingKind,
    /// 绑定模式，支持 `let (a, b) = ...` 与 `let _ = ...`。
    pattern: *const HirPattern,
    /// 可选显式类型标注。
    ty: ?*const HirType = null,
    /// 可选初始化表达式。
    init: ?*const HirExpr = null,
    /// 整条声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 表达式语句载荷。
pub const ExprStmt = struct {
    /// 语句包含的表达式。
    value: *const HirExpr,
    /// 语句末尾是否带有显式分号。
    has_semi: bool = false,
    /// 整条语句在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// HIR 语句节点。语句块内允许出现局部声明，因此 `item` 也是语句的一种。
pub const HirStmt = union(enum) {
    binding: Binding,
    expr: ExprStmt,
    item: HirItem,

    /// 统一获取当前语句节点覆盖的源文件字节区间。
    ///
    /// 指针内存约定：`self` 仅作只读借用，不转移所有权。
    pub inline fn range(self: *const HirStmt) TextRange {
        return switch (self.*) {
            .item => |*payload| payload.range(),
            inline else => |*payload| payload.range,
        };
    }
};

/// 函数形参定义。
pub const HirParam = struct {
    /// 参数修饰符，例如主构造器成员参数上的访问修饰符。
    modifiers: []const Modifier = &.{},
    /// 参数上的注解。
    annotations: []const Annotation = &.{},
    /// 主构造器成员参数的 `let` 或 `var`；普通参数为 null。
    binding: ?BindingKind = null,
    /// 参数名；`_` 参数为 null。
    name: ?Name = null,
    /// 是否为命名参数（`a!: T`）。
    is_named: bool = false,
    /// 可选参数类型标注。
    ty: ?*const HirType = null,
    /// 可选默认值表达式。
    default_value: ?*const HirExpr = null,
    /// 整个参数声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 参数位置的宏调用载荷。
pub const ParamMacro = struct {
    /// 宏之前的注解。
    annotations: []const Annotation = &.{},
    /// 宏名与调用标记。
    call: MacroCall,
    /// 被宏修饰的参数；宏自行生成参数时为 null。链式参数宏在这里嵌套另一个 `Param`。
    param: ?*const Param = null,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 参数表元素。
pub const Param = union(enum) {
    param: HirParam,
    macro_call: ParamMacro,
};

/// 函数名：普通标识符或可重载运算符。
pub const FuncName = union(enum) {
    /// 普通函数名。
    ident: Name,
    /// 可重载运算符名称，`text` 为运算符源码文本（如 `+`、`()`、`[]`）。
    operator: Name,
};

/// 泛型约束子句中的单条约束，例如 `T <: A & B`。
pub const GenericConstraint = struct {
    /// 被约束的类型，通常是类型参数名或 `This`。
    subject: *const HirType,
    /// 约束上界列表。
    bounds: []const HirType,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 泛型约束子句 `where ...`。
pub const WhereClause = struct {
    /// 约束列表。
    constraints: []const GenericConstraint,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 函数声明项载荷。
pub const FuncItem = struct {
    /// 声明修饰符。
    modifiers: []const Modifier = &.{},
    /// 声明上的注解。
    annotations: []const Annotation = &.{},
    /// 函数名。
    name: FuncName,
    /// 泛型类型参数列表。
    type_params: []const Name = &.{},
    /// 形参列表。
    params: []const Param = &.{},
    /// 参数表是否以 `...` 结尾。
    is_variadic: bool = false,
    /// 可选返回类型标注。
    ret_type: ?*const HirType = null,
    /// 可选泛型约束子句。
    where_clause: ?*const WhereClause = null,
    /// 可选函数体语句块；无函数体的声明为 null。
    body: ?*const BlockExpr = null,
    /// 整个函数声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 程序入口 `main` 声明项载荷。
pub const MainItem = struct {
    /// 声明修饰符。
    modifiers: []const Modifier = &.{},
    /// 声明上的注解。
    annotations: []const Annotation = &.{},
    /// 形参列表。
    params: []const Param = &.{},
    /// 参数表是否以 `...` 结尾。
    is_variadic: bool = false,
    /// 可选返回类型标注。
    ret_type: ?*const HirType = null,
    /// 函数体语句块。
    body: *const BlockExpr,
    /// 整个声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 类声明项载荷。
pub const ClassItem = struct {
    /// 声明修饰符。
    modifiers: []const Modifier = &.{},
    /// 声明上的注解。
    annotations: []const Annotation = &.{},
    /// 类名。
    name: Name,
    /// 泛型类型参数列表。
    type_params: []const Name = &.{},
    /// 父类与接口列表，第一个元素为父类，其余为接口。
    supertypes: []const HirType = &.{},
    /// 可选泛型约束子句。
    where_clause: ?*const WhereClause = null,
    /// 按源码顺序排列的成员声明。
    members: []const HirItem = &.{},
    /// 整个类声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 结构体声明项载荷。
pub const StructItem = struct {
    /// 声明修饰符。
    modifiers: []const Modifier = &.{},
    /// 声明上的注解。
    annotations: []const Annotation = &.{},
    /// 结构体名。
    name: Name,
    /// 泛型类型参数列表。
    type_params: []const Name = &.{},
    /// 实现的接口类型列表。
    interfaces: []const HirType = &.{},
    /// 可选泛型约束子句。
    where_clause: ?*const WhereClause = null,
    /// 按源码顺序排列的成员声明，字段以 `.binding` 形式出现。
    members: []const HirItem = &.{},
    /// 整个结构体声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 枚举构造器载荷中的类型元素，可带注解。
pub const EnumPayloadType = struct {
    /// 类型之前的注解。
    annotations: []const Annotation = &.{},
    /// 载荷类型。
    ty: *const HirType,
    /// 元素在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 枚举构造器载荷元素。
pub const EnumPayloadElement = union(enum) {
    ty: EnumPayloadType,
    macro_call: ParamMacro,
};

/// 枚举构造器定义。
pub const EnumConstructor = struct {
    /// 构造器上的注解。
    annotations: []const Annotation = &.{},
    /// 构造器名称。
    name: Name,
    /// 载荷元素列表；无参构造器为空切片。
    payload: []const EnumPayloadElement = &.{},
    /// 整个构造器声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 枚举构造器位置的宏调用载荷。
pub const VariantMacro = struct {
    /// 宏之前的注解。
    annotations: []const Annotation = &.{},
    /// 宏名与调用标记。
    call: MacroCall,
    /// 被宏修饰的构造器；宏自行生成构造器时为 null。链式构造器宏在这里嵌套另一个 `EnumVariant`。
    constructor: ?*const EnumVariant = null,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 枚举体中的构造器位置元素。
pub const EnumVariant = union(enum) {
    constructor: EnumConstructor,
    macro_call: VariantMacro,
};

/// 枚举声明项载荷。
pub const EnumItem = struct {
    /// 声明修饰符。
    modifiers: []const Modifier = &.{},
    /// 声明上的注解。
    annotations: []const Annotation = &.{},
    /// 枚举名。
    name: Name,
    /// 泛型类型参数列表。
    type_params: []const Name = &.{},
    /// 实现的接口类型列表。
    interfaces: []const HirType = &.{},
    /// 可选泛型约束子句。
    where_clause: ?*const WhereClause = null,
    /// 按源码顺序排列的构造器位置元素。
    variants: []const EnumVariant = &.{},
    /// 是否带非详尽标记 `...`。
    is_non_exhaustive: bool = false,
    /// 按源码顺序排列的成员声明。
    members: []const HirItem = &.{},
    /// 整个枚举声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 接口声明项载荷。
pub const InterfaceItem = struct {
    /// 声明修饰符。
    modifiers: []const Modifier = &.{},
    /// 声明上的注解。
    annotations: []const Annotation = &.{},
    /// 接口名。
    name: Name,
    /// 泛型类型参数列表。
    type_params: []const Name = &.{},
    /// 父接口类型列表。
    interfaces: []const HirType = &.{},
    /// 可选泛型约束子句。
    where_clause: ?*const WhereClause = null,
    /// 按源码顺序排列的成员声明。
    members: []const HirItem = &.{},
    /// 整个接口声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 类型扩展与接口实现项载荷，对应 `extend` 声明。
pub const ExtendItem = struct {
    /// 声明修饰符。
    modifiers: []const Modifier = &.{},
    /// 声明上的注解。
    annotations: []const Annotation = &.{},
    /// 泛型类型参数列表。
    type_params: []const Name = &.{},
    /// 被扩展的目标类型。
    target: *const HirType,
    /// 实现的接口类型列表；直接扩展类型时为空切片。
    interfaces: []const HirType = &.{},
    /// 可选泛型约束子句。
    where_clause: ?*const WhereClause = null,
    /// 按源码顺序排列的成员声明。
    members: []const HirItem = &.{},
    /// 整个扩展声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 属性访问器载荷，例如 `get() { ... }`、`set(value) { ... }`。
pub const PropAccessor = struct {
    /// 访问器名称（`get` 或 `set`）。
    name: Name,
    /// 访问器参数列表，`set` 的值参数由 CST 中的标识符叶子构造。
    params: []const Param = &.{},
    /// 访问器体语句块。
    body: *const BlockExpr,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 属性声明项载荷。
pub const PropItem = struct {
    /// 声明修饰符。
    modifiers: []const Modifier = &.{},
    /// 声明上的注解。
    annotations: []const Annotation = &.{},
    /// 属性名。
    name: Name,
    /// 属性类型。
    ty: *const HirType,
    /// 访问器列表，可为空切片。
    accessors: []const PropAccessor = &.{},
    /// 整个属性声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 类型别名声明项载荷，例如 `type Alias<T> = Foo<T>`。
pub const TypeAliasItem = struct {
    /// 声明修饰符。
    modifiers: []const Modifier = &.{},
    /// 声明上的注解。
    annotations: []const Annotation = &.{},
    /// 别名名称。
    name: Name,
    /// 泛型类型参数列表。
    type_params: []const Name = &.{},
    /// 目标类型。
    target: *const HirType,
    /// 整个声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 构造函数与静态初始化器载荷，对应 `init(...) { ... }`。
pub const InitItem = struct {
    /// 声明修饰符。
    modifiers: []const Modifier = &.{},
    /// 声明上的注解。
    annotations: []const Annotation = &.{},
    /// 形参列表。
    params: []const Param = &.{},
    /// 参数表是否以 `...` 结尾。
    is_variadic: bool = false,
    /// 函数体语句块。
    body: *const BlockExpr,
    /// 整个声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 类终结器载荷，对应 `~init() { ... }`。
pub const FinalizerItem = struct {
    /// 声明修饰符。
    modifiers: []const Modifier = &.{},
    /// 声明上的注解。
    annotations: []const Annotation = &.{},
    /// 形参列表。
    params: []const Param = &.{},
    /// 参数表是否以 `...` 结尾。
    is_variadic: bool = false,
    /// 函数体语句块。
    body: *const BlockExpr,
    /// 整个声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 类或结构体主构造器载荷，例如 `Point(let x: Int64) { ... }`。
pub const PrimaryCtorItem = struct {
    /// 声明修饰符。
    modifiers: []const Modifier = &.{},
    /// 声明上的注解。
    annotations: []const Annotation = &.{},
    /// 构造器名，与所属类型同名。
    name: Name,
    /// 主构造器成员参数列表。
    params: []const Param = &.{},
    /// 参数表是否以 `...` 结尾。
    is_variadic: bool = false,
    /// 主构造器体语句块。
    body: *const BlockExpr,
    /// 整个声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 宏定义声明项载荷。
pub const MacroItem = struct {
    /// 声明修饰符。
    modifiers: []const Modifier = &.{},
    /// 声明上的注解。
    annotations: []const Annotation = &.{},
    /// 宏名称。
    name: Name,
    /// 形参列表。
    params: []const Param = &.{},
    /// 参数表是否以 `...` 结尾。
    is_variadic: bool = false,
    /// 可选返回类型标注。
    ret_type: ?*const HirType = null,
    /// 宏体，可为 `.block` 或任意表达式。
    body: *const HirExpr,
    /// 整个声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 声明位置的宏调用载荷。宏的括号输入与属性保留在 CST 中。
pub const MacroExpandItem = struct {
    /// 宏之前的注解。
    annotations: []const Annotation = &.{},
    /// 宏名与调用标记。
    call: MacroCall,
    /// 被宏修饰的声明；宏自行生成声明时为 null。
    wrapped: ?*const HirItem = null,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 外部声明载荷，对应 `foreign func ...` 与 `foreign { ... }`。
pub const ForeignItem = struct {
    /// 声明修饰符。
    modifiers: []const Modifier = &.{},
    /// 声明上的注解。
    annotations: []const Annotation = &.{},
    /// 外部声明成员列表。
    members: []const HirItem = &.{},
    /// 整个声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 导入路径元素。
pub const ImportAlias = struct {
    /// 被导入的名字。
    name: Name,
    /// `as` 之后的别名。
    alias: Name,
};

/// 导入声明的形态。
pub const ImportKind = union(enum) {
    /// 导入单个名字。
    single: Name,
    /// 导入单个名字并重命名。
    alias: ImportAlias,
    /// 通配符导入 `*`。
    glob: void,
    /// 分组导入 `{ ... }`。
    group: []const ImportItem,
};

/// 导入声明项载荷，例如 `import a.b.C as D`、`import a.*`、`import a.{b, c as d, e.*}`。
pub const ImportItem = struct {
    /// 导入修饰符。
    modifier: ?Modifier = null,
    /// 导入之前的注解。
    annotations: []const Annotation = &.{},
    /// 可选组织名前缀（`org::a.b` 中的 `org`）。
    org: ?Name = null,
    /// 导入路径的点分包名前缀。
    prefix: []const Name = &.{},
    /// 导入形态。
    kind: ImportKind,
    /// 整个导入声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 包声明载荷，对应 `[modifier] [macro] package [org::]a.b.c`。
pub const PackageHeader = struct {
    /// 可选包修饰符。
    modifier: ?Modifier = null,
    /// 是否为 `macro package`。
    is_macro: bool = false,
    /// 可选组织名前缀。
    org: ?Name = null,
    /// 点分包名的各个名字段，至少一段。
    name: []const Name,
    /// 整个包声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 特性声明中的单个特性标识，例如 `a.b.c`。
pub const FeatureId = struct {
    /// 点分标识符的各个名字段，至少一段。
    segments: []const Name,
    /// 节点在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// 特性声明载荷，对应 `features { a.b, c.d }`。
pub const FeaturesDirective = struct {
    /// 特性标识列表。
    features: []const FeatureId,
    /// 整个声明在源文件中的左闭右开字节区间。
    range: TextRange,
};

/// HIR 顶层或成员声明项节点。
pub const HirItem = union(enum) {
    func: FuncItem,
    main: MainItem,
    class: ClassItem,
    struct_: StructItem,
    enum_: EnumItem,
    interface: InterfaceItem,
    extend_: ExtendItem,
    prop: PropItem,
    type_alias: TypeAliasItem,
    init: InitItem,
    finalizer: FinalizerItem,
    primary_ctor: PrimaryCtorItem,
    binding: Binding,
    foreign: ForeignItem,
    macro_: MacroItem,
    macro_expand: MacroExpandItem,

    /// 统一获取当前声明项节点覆盖的源文件字节区间。
    ///
    /// 指针内存约定：`self` 仅作只读借用，不转移所有权。
    pub inline fn range(self: *const HirItem) TextRange {
        return switch (self.*) {
            inline else => |*payload| payload.range,
        };
    }
};

/// 单个源文件对应的 HIR 模块根节点。
///
/// 指针内存约定：`items`、`imports` 切片及其内部所有指针均由所属 `arena` 分配，随 `arena`
/// 统一释放，调用者不得单独释放。
pub const HirFile = struct {
    /// 对应的源文件标识。
    file: FileId,
    /// 构建该 HIR 时的文件版本号。
    version: u32,
    /// 可选包声明。
    package: ?PackageHeader = null,
    /// 可选特性声明。
    features: ?FeaturesDirective = null,
    /// 文件中的导入声明列表。导入在源码中通常位于声明项之前；若 parser 在声明项之后接受导入，
    /// lower 仍将其收入此列表，与声明项之间的源码位置关系不保留。
    imports: []const ImportItem = &.{},
    /// 文件顶层声明项列表。
    items: []const HirItem = &.{},

    /// 判定当前 HIR 相对于给定文件与文件版本是否过期。
    pub inline fn isOutdated(self: HirFile, file: FileId, current_version: u32) bool {
        return source_mod.isOutdated(self.file, self.version, file, current_version);
    }
};

/// 测试辅助：验证切片中的带标签联合体元素无重复地覆盖了该联合体的全部变体，且各自 `range()` 匹配预期。
fn expectAllVariantsAndRanges(
    comptime T: type,
    values: []const T,
    expected_ranges: []const TextRange,
) !void {
    const Tag = std.meta.Tag(T);
    const total = @typeInfo(T).@"union".field_names.len;
    try std.testing.expectEqual(total, values.len);
    try std.testing.expectEqual(total, expected_ranges.len);

    var seen = std.EnumSet(Tag).empty;
    for (values, expected_ranges) |*item, exp| {
        const tag = std.meta.activeTag(item.*);
        try std.testing.expect(!seen.contains(tag));
        seen.insert(tag);
        try std.testing.expectEqual(exp, item.range());
        const copy = item.*;
        try std.testing.expectEqual(exp, copy.range());
    }
    try std.testing.expectEqual(total, seen.count());
}

/// 测试辅助：构造字节区间。
fn rng(start: u32, end: u32) TextRange {
    return .{ .start = start, .end = end };
}

/// 测试辅助：构造不带反引号的名字。
fn nm(text: []const u8, range: TextRange) Name {
    return .{ .text = text, .is_raw = false, .range = range };
}

/// 测试辅助：构造反引号包围的原始名字。
fn rawName(text: []const u8, range: TextRange) Name {
    return .{ .text = text, .is_raw = true, .range = range };
}

test "运算符与关键字的 CST 标签映射精确覆盖" {
    var seen_binary = std.EnumSet(BinaryOp).empty;
    var seen_assign = std.EnumSet(AssignOp).empty;
    var seen_unary = std.EnumSet(UnaryOp).empty;
    var seen_inc_dec = std.EnumSet(IncDecOp).empty;
    var seen_jump = std.EnumSet(JumpOp).empty;

    for (std.enums.values(SyntaxKind)) |kind| {
        const expected_bin: ?BinaryOp = switch (kind) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .mod => .mod,
            .exp => .exp,
            .equal => .eq,
            .not_equal => .ne,
            .less => .lt,
            .less_equal => .le,
            .greater => .gt,
            .greater_equal => .ge,
            .logical_and => .logical_and,
            .logical_or => .logical_or,
            .bit_and => .bit_and,
            .bit_or => .bit_or,
            .bit_xor => .bit_xor,
            .lshift => .lshift,
            .rshift => .rshift,
            .coalescing => .coalescing,
            .pipeline => .pipeline,
            .composition => .composition,
            else => null,
        };
        try std.testing.expectEqual(expected_bin, BinaryOp.fromSyntaxKind(kind));
        if (expected_bin) |op| {
            try std.testing.expect(!seen_binary.contains(op));
            seen_binary.insert(op);
        }

        const expected_asg: ?AssignOp = switch (kind) {
            .assign => .assign,
            .add_assign => .add_assign,
            .sub_assign => .sub_assign,
            .mul_assign => .mul_assign,
            .exp_assign => .exp_assign,
            .div_assign => .div_assign,
            .mod_assign => .mod_assign,
            .logical_and_assign => .logical_and_assign,
            .logical_or_assign => .logical_or_assign,
            .bit_and_assign => .bit_and_assign,
            .bit_or_assign => .bit_or_assign,
            .bit_xor_assign => .bit_xor_assign,
            .lshift_assign => .lshift_assign,
            .rshift_assign => .rshift_assign,
            else => null,
        };
        try std.testing.expectEqual(expected_asg, AssignOp.fromSyntaxKind(kind));
        if (expected_asg) |op| {
            try std.testing.expect(!seen_assign.contains(op));
            seen_assign.insert(op);
        }

        const expected_un: ?UnaryOp = switch (kind) {
            .sub => .neg,
            .not => .not,
            else => null,
        };
        try std.testing.expectEqual(expected_un, UnaryOp.fromSyntaxKind(kind));
        if (expected_un) |op| {
            try std.testing.expect(!seen_unary.contains(op));
            seen_unary.insert(op);
        }

        const expected_id: ?IncDecOp = switch (kind) {
            .incr => .incr,
            .decr => .decr,
            else => null,
        };
        try std.testing.expectEqual(expected_id, IncDecOp.fromSyntaxKind(kind));
        if (expected_id) |op| {
            try std.testing.expect(!seen_inc_dec.contains(op));
            seen_inc_dec.insert(op);
        }

        const expected_jmp: ?JumpOp = switch (kind) {
            .kw_break => .break_,
            .kw_continue => .continue_,
            else => null,
        };
        try std.testing.expectEqual(expected_jmp, JumpOp.fromSyntaxKind(kind));
        if (expected_jmp) |op| {
            try std.testing.expect(!seen_jump.contains(op));
            seen_jump.insert(op);
        }
    }

    try std.testing.expectEqual(@typeInfo(BinaryOp).@"enum".field_names.len, seen_binary.count());
    try std.testing.expectEqual(@typeInfo(AssignOp).@"enum".field_names.len, seen_assign.count());
    try std.testing.expectEqual(@typeInfo(UnaryOp).@"enum".field_names.len, seen_unary.count());
    try std.testing.expectEqual(@typeInfo(IncDecOp).@"enum".field_names.len, seen_inc_dec.count());
    try std.testing.expectEqual(@typeInfo(JumpOp).@"enum".field_names.len, seen_jump.count());

    // 区间表达式与类型判定使用独立 HIR 变体，不出现在运算符映射表中
    try std.testing.expectEqual(@as(?BinaryOp, null), BinaryOp.fromSyntaxKind(.range_op));
    try std.testing.expectEqual(@as(?BinaryOp, null), BinaryOp.fromSyntaxKind(.closed_range_op));
    try std.testing.expectEqual(@as(?BinaryOp, null), BinaryOp.fromSyntaxKind(.kw_is));
    try std.testing.expectEqual(@as(?BinaryOp, null), BinaryOp.fromSyntaxKind(.kw_as));
    try std.testing.expectEqual(@as(?UnaryOp, null), UnaryOp.fromSyntaxKind(.bit_not));
}

test "HirType 全部变体覆盖与统一 range() 访问器" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const int_ty: HirType = .{ .path = .{
        .segments = &.{.{ .name = nm("Int64", rng(1, 6)) }},
        .range = rng(1, 6),
    } };

    const list_ty: HirType = .{ .path = .{
        .segments = &.{.{ .name = nm("List", rng(7, 11)), .type_args = try alloc.dupe(HirType, &.{int_ty}) }},
        .range = rng(7, 17),
    } };

    const opt_ty: HirType = .{ .option = .{ .inner = &int_ty, .range = rng(18, 24) } };
    const tuple_ty: HirType = .{ .tuple = .{
        .elements = try alloc.dupe(HirTypeElement, &.{.{ .ty = &int_ty, .range = rng(25, 31) }}),
        .range = rng(25, 41),
    } };
    const func_ty: HirType = .{ .func = .{
        .params = try alloc.dupe(HirTypeElement, &.{.{ .label = nm("x", rng(42, 43)), .ty = &int_ty, .range = rng(42, 47) }}),
        .ret = &opt_ty,
        .range = rng(41, 58),
    } };
    const varray_ty: HirType = .{ .varray = .{ .elem = &int_ty, .size = "4", .range = rng(59, 75) } };
    const this_ty: HirType = .{ .this = .{ .range = rng(76, 80) } };

    const all = [_]HirType{ list_ty, opt_ty, tuple_ty, func_ty, varray_ty, this_ty };
    const expected = [_]TextRange{
        rng(7, 17),
        rng(18, 24),
        rng(25, 41),
        rng(41, 58),
        rng(59, 75),
        rng(76, 80),
    };

    try expectAllVariantsAndRanges(HirType, &all, &expected);

    try std.testing.expectEqualStrings("4", varray_ty.varray.size);
    try std.testing.expectEqual(@as(usize, 1), tuple_ty.tuple.elements.len);
    try std.testing.expectEqualStrings("x", func_ty.func.params[0].label.?.text);
    try std.testing.expectEqual(@as(usize, 1), list_ty.path.segments.len);
    try std.testing.expectEqual(@as(usize, 1), list_ty.path.segments[0].type_args.len);
}

test "HirPattern 全部变体覆盖与字段语义" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const int_ty: HirType = .{ .path = .{
        .segments = &.{.{ .name = nm("Int64", rng(90, 95)) }},
        .range = rng(90, 95),
    } };
    const one: HirExpr = .{ .int_lit = .{ .text = "1", .range = rng(96, 97) } };

    const wildcard: HirPattern = .{ .wildcard = .{ .range = rng(0, 1) } };
    const binding: HirPattern = .{ .binding = .{ .name = nm("x", rng(2, 3)), .range = rng(2, 3) } };
    const const_pat: HirPattern = .{ .const_ = .{ .value = &one, .range = rng(4, 5) } };
    const tuple_pat: HirPattern = .{ .tuple = .{
        .elements = try alloc.dupe(HirPattern, &.{ wildcard, binding }),
        .range = rng(6, 12),
    } };
    const enum_pat: HirPattern = .{ .enum_ = .{
        .path = .{ .segments = &.{.{ .name = nm("Some", rng(13, 17)) }}, .range = rng(13, 17) },
        .args = try alloc.dupe(HirPattern, &.{binding}),
        .range = rng(13, 21),
    } };
    const typed_pat: HirPattern = .{ .typed = .{
        .name = nm("y", rng(22, 23)),
        .ty = &int_ty,
        .range = rng(22, 28),
    } };
    const unnamed_typed: HirPattern = .{ .typed = .{ .ty = &int_ty, .range = rng(29, 35) } };
    const except_pat: HirPattern = .{ .except_type = .{
        .name = nm("e", rng(36, 37)),
        .types = try alloc.dupe(HirType, &.{int_ty}),
        .range = rng(36, 42),
    } };
    const command_pat: HirPattern = .{ .command_type = .{
        .types = try alloc.dupe(HirType, &.{int_ty}),
        .range = rng(43, 49),
    } };

    try expectAllVariantsAndRanges(HirPattern, &[_]HirPattern{
        wildcard,
        binding,
        const_pat,
        tuple_pat,
        enum_pat,
        typed_pat,
        except_pat,
        command_pat,
    }, &[_]TextRange{
        rng(0, 1),
        rng(2, 3),
        rng(4, 5),
        rng(6, 12),
        rng(13, 21),
        rng(22, 28),
        rng(36, 42),
        rng(43, 49),
    });

    try std.testing.expect(unnamed_typed.typed.name == null);
    try std.testing.expectEqual(@as(usize, 2), tuple_pat.tuple.elements.len);
    try std.testing.expectEqualStrings("Some", enum_pat.enum_.path.segments[0].name.text);
    try std.testing.expectEqual(@as(usize, 1), enum_pat.enum_.args.len);
    try std.testing.expectEqualStrings("1", const_pat.const_.value.int_lit.text);
}

test "HirExpr 全部变体覆盖与统一 range() 访问器" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const int_ty: HirType = .{ .path = .{
        .segments = &.{.{ .name = nm("Int64", rng(200, 205)) }},
        .range = rng(200, 205),
    } };
    const int_expr: HirExpr = .{ .int_lit = .{ .text = "42", .suffix = .i64, .range = rng(0, 2) } };
    const bool_expr: HirExpr = .{ .bool_lit = .{ .value = true, .range = rng(3, 7) } };
    const block: BlockExpr = .{ .stmts = &.{}, .range = rng(8, 10) };
    const path_expr: PathExpr = .{
        .segments = try alloc.dupe(ExprPathSegment, &.{
            .{ .name = nm("pkg", rng(11, 14)) },
            .{ .name = nm("foo", rng(15, 18)), .type_args = try alloc.dupe(HirType, &.{int_ty}) },
        }),
        .range = rng(11, 24),
    };
    const ident = nm("m", rng(31, 32));

    const for_pat = try alloc.create(HirPattern);
    for_pat.* = .{ .wildcard = .{ .range = rng(36, 37) } };

    const all = [_]HirExpr{
        .{ .int_lit = .{ .text = "42", .suffix = .i64, .range = rng(0, 2) } },
        .{ .float_lit = .{ .text = "3.5", .suffix = .f32, .range = rng(2, 3) } },
        .{ .rune_lit = .{ .value = 'a', .is_byte = true, .range = rng(3, 4) } },
        .{ .string_lit = .{ .text = "hello", .kind = .raw_multiline, .range = rng(4, 5) } },
        .{ .str_interp = .{ .parts = try alloc.dupe(StrPart, &.{
            .{ .text = .{ .text = "a", .range = rng(5, 6) } },
            .{ .interpolation = .{ .body = &block, .range = rng(6, 7) } },
        }), .kind = .multiline, .range = rng(5, 7) } },
        .{ .bool_lit = .{ .value = true, .range = rng(7, 8) } },
        .{ .unit_lit = .{ .range = rng(8, 9) } },
        .{ .wildcard = .{ .range = rng(9, 10) } },
        .{ .path = path_expr },
        .{ .field = .{ .base = &int_expr, .name = ident, .type_args = try alloc.dupe(HirType, &.{int_ty}), .range = rng(10, 11) } },
        .{ .optional = .{ .operand = &int_expr, .range = rng(11, 12) } },
        .{ .call = .{ .callee = &int_expr, .args = try alloc.dupe(HirCallArg, &.{.{ .value = &bool_expr, .range = rng(12, 13) }}), .trailing_lambda = &int_expr, .range = rng(12, 14) } },
        .{ .index = .{ .base = &int_expr, .indices = try alloc.dupe(HirExpr, &.{int_expr}), .range = rng(14, 15) } },
        .{ .inc_dec = .{ .op = .incr, .operand = &int_expr, .range = rng(15, 16) } },
        .{ .unary = .{ .op = .neg, .operand = &int_expr, .range = rng(16, 17) } },
        .{ .binary = .{ .op = .add, .lhs = &int_expr, .rhs = &bool_expr, .range = rng(17, 18) } },
        .{ .assign = .{ .op = .add_assign, .lhs = &int_expr, .rhs = &bool_expr, .range = rng(18, 19) } },
        .{ .range_expr = .{ .start = &int_expr, .end = &bool_expr, .inclusive = true, .step = &int_expr, .range = rng(19, 20) } },
        .{ .is_expr = .{ .operand = &int_expr, .ty = &int_ty, .range = rng(20, 21) } },
        .{ .as_expr = .{ .operand = &int_expr, .ty = &int_ty, .range = rng(21, 22) } },
        .{ .type_conv = .{ .ty = &int_ty, .value = &int_expr, .range = rng(22, 24) } },
        .{ .varray = .{ .ty = &int_ty, .args = &.{}, .range = rng(24, 25) } },
        .{ .tuple_lit = .{ .elements = try alloc.dupe(HirExpr, &.{ int_expr, bool_expr }), .range = rng(25, 26) } },
        .{ .array_lit = .{ .elements = try alloc.dupe(ArrayElement, &.{.{ .spread = true, .value = &int_expr, .range = rng(26, 27) }}), .range = rng(26, 28) } },
        .{ .block = block },
        .{ .if_expr = .{ .condition = .{ .expr = &bool_expr }, .then_branch = &block, .else_branch = &int_expr, .range = rng(28, 29) } },
        .{ .match_expr = .{ .selector = &int_expr, .cases = try alloc.dupe(MatchCase, &.{.{ .pattern = .{
            .patterns = try alloc.dupe(HirPattern, &.{.{ .wildcard = .{ .range = rng(29, 30) } }}),
            .body = &block,
            .range = rng(29, 31),
        } }}), .range = rng(29, 32) } },
        .{ .while_expr = .{ .condition = .{ .let_destructor = .{
            .patterns = try alloc.dupe(HirPattern, &.{.{ .binding = .{ .name = ident, .range = rng(32, 33) } }}),
            .value = &int_expr,
            .range = rng(32, 34),
        } }, .body = &block, .range = rng(32, 35) } },
        .{ .do_while_expr = .{ .body = &block, .condition = &bool_expr, .range = rng(35, 36) } },
        .{ .for_in_expr = .{
            .pattern = for_pat,
            .iterable = &int_expr,
            .guard = &bool_expr,
            .body = &block,
            .range = rng(36, 37),
        } },
        .{ .try_expr = .{ .resources = try alloc.dupe(Resource, &.{.{ .name = ident, .ty = &int_ty, .init = &int_expr, .range = rng(37, 38) }}), .body = &block, .clauses = &.{}, .finally = &block, .range = rng(37, 39) } },
        .{ .throw_expr = .{ .value = &int_expr, .range = rng(39, 40) } },
        .{ .return_expr = .{ .value = &int_expr, .range = rng(40, 41) } },
        .{ .jump = .{ .op = .break_, .range = rng(41, 42) } },
        .{ .lambda = .{ .params = &.{}, .body = &block, .range = rng(42, 45) } },
        .{ .spawn = .{ .context = &int_expr, .task = &int_expr, .range = rng(45, 46) } },
        .{ .synchronized = .{ .mutex = &int_expr, .body = &block, .range = rng(46, 47) } },
        .{ .unsafe = .{ .body = &block, .range = rng(47, 48) } },
        .{ .quote = .{ .parts = try alloc.dupe(QuotePart, &.{ .{ .token = rng(48, 49) }, .{ .interpolation = &int_expr } }), .range = rng(48, 50) } },
        .{ .macro_call = .{ .call = .{ .path = try alloc.dupe(Name, &.{ident}), .has_bang = true }, .inner = &int_expr, .range = rng(49, 50) } },
        .{ .if_available = .{ .args = try alloc.dupe(HirCallArg, &.{.{ .value = &int_expr, .range = rng(50, 51) }}), .range = rng(50, 52) } },
        .{ .perform = .{ .value = &int_expr, .range = rng(52, 53) } },
        .{ .resume_expr = .{ .value = &int_expr, .modifier = .with, .modifier_value = &bool_expr, .range = rng(53, 54) } },
    };
    const expected = [_]TextRange{
        rng(0, 2),   rng(2, 3),   rng(3, 4),   rng(4, 5),   rng(5, 7),   rng(7, 8),
        rng(8, 9),   rng(9, 10),  rng(11, 24), rng(10, 11), rng(11, 12), rng(12, 14),
        rng(14, 15), rng(15, 16), rng(16, 17), rng(17, 18), rng(18, 19), rng(19, 20),
        rng(20, 21), rng(21, 22), rng(22, 24), rng(24, 25), rng(25, 26), rng(26, 28),
        rng(8, 10),  rng(28, 29), rng(29, 32), rng(32, 35), rng(35, 36), rng(36, 37),
        rng(37, 39), rng(39, 40), rng(40, 41), rng(41, 42), rng(42, 45), rng(45, 46),
        rng(46, 47), rng(47, 48), rng(48, 50), rng(49, 50), rng(50, 52), rng(52, 53),
        rng(53, 54),
    };

    try expectAllVariantsAndRanges(HirExpr, &all, &expected);

    // 关键载荷语义
    try std.testing.expectEqualStrings("42", all[0].int_lit.text);
    try std.testing.expectEqual(@as(?IntSuffix, .i64), all[0].int_lit.suffix);
    try std.testing.expectEqual(@as(?FloatSuffix, .f32), all[1].float_lit.suffix);
    try std.testing.expectEqual(@as(u21, 'a'), all[2].rune_lit.value);
    try std.testing.expect(all[2].rune_lit.is_byte);
    try std.testing.expectEqual(StrKind.raw_multiline, all[3].string_lit.kind);
    try std.testing.expectEqual(@as(usize, 2), all[4].str_interp.parts.len);
    try std.testing.expectEqual(@as(usize, 2), all[8].path.segments.len);
    try std.testing.expectEqual(@as(usize, 1), all[8].path.segments[1].type_args.len);
    try std.testing.expect(all[11].call.trailing_lambda != null);
    try std.testing.expectEqual(BinaryOp.add, all[15].binary.op);
    try std.testing.expectEqual(AssignOp.add_assign, all[16].assign.op);
    try std.testing.expectEqual(@as(?*const HirExpr, &int_expr), all[17].range_expr.start);
    try std.testing.expect(all[17].range_expr.inclusive);
    try std.testing.expect(all[23].array_lit.elements[0].spread);
    try std.testing.expectEqual(.let_destructor, std.meta.activeTag(all[27].while_expr.condition));
    try std.testing.expectEqual(ResumeModifier.with, all[42].resume_expr.modifier.?);
    try std.testing.expectEqual(.token, std.meta.activeTag(all[38].quote.parts[0]));
    try std.testing.expectEqual(.interpolation, std.meta.activeTag(all[38].quote.parts[1]));
}

test "HirStmt 与 HirItem 全部变体覆盖及 HirFile 版本判定" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const int_ty: HirType = .{ .path = .{
        .segments = &.{.{ .name = nm("Int64", rng(300, 305)) }},
        .range = rng(300, 305),
    } };
    const int_expr: HirExpr = .{ .int_lit = .{ .text = "0", .range = rng(0, 1) } };
    const block: BlockExpr = .{ .stmts = &.{}, .range = rng(1, 2) };
    const pat: HirPattern = .{ .binding = .{ .name = nm("x", rng(2, 3)), .range = rng(2, 3) } };
    const ident = nm("f", rng(4, 5));
    const empty_params: []const Param = &.{};

    const alias_item: HirItem = .{ .type_alias = .{
        .name = ident,
        .target = &int_ty,
        .range = rng(5, 6),
    } };

    const all_stmts = [_]HirStmt{
        .{ .binding = .{ .kind = .var_, .pattern = &pat, .ty = &int_ty, .init = &int_expr, .range = rng(0, 6) } },
        .{ .expr = .{ .value = &int_expr, .has_semi = true, .range = rng(6, 8) } },
        .{ .item = alias_item },
    };
    try expectAllVariantsAndRanges(HirStmt, &all_stmts, &[_]TextRange{ rng(0, 6), rng(6, 8), rng(5, 6) });

    const where_clause = try alloc.create(WhereClause);
    where_clause.* = .{
        .constraints = try alloc.dupe(GenericConstraint, &.{.{ .subject = &int_ty, .bounds = try alloc.dupe(HirType, &.{int_ty}), .range = rng(21, 28) }}),
        .range = rng(21, 28),
    };

    const func_item: HirItem = .{ .func = .{
        .modifiers = &.{ .public, .static },
        .annotations = try alloc.dupe(Annotation, &.{.{ .path = try alloc.dupe(Name, &.{nm("Deprecated", rng(6, 17))}), .range = rng(6, 18) }}),
        .name = .{ .ident = ident },
        .type_params = try alloc.dupe(Name, &.{nm("T", rng(19, 20))}),
        .params = empty_params,
        .ret_type = &int_ty,
        .where_clause = where_clause,
        .body = &block,
        .range = rng(5, 30),
    } };

    const all_items = [_]HirItem{
        func_item,
        .{ .main = .{ .params = empty_params, .body = &block, .range = rng(30, 40) } },
        .{ .class = .{ .name = ident, .supertypes = try alloc.dupe(HirType, &.{int_ty}), .members = try alloc.dupe(HirItem, &.{alias_item}), .range = rng(41, 50) } },
        .{ .struct_ = .{ .name = ident, .interfaces = try alloc.dupe(HirType, &.{int_ty}), .members = try alloc.dupe(HirItem, &.{alias_item}), .range = rng(51, 60) } },
        .{ .enum_ = .{ .name = ident, .interfaces = try alloc.dupe(HirType, &.{int_ty}), .variants = try alloc.dupe(EnumVariant, &.{.{ .constructor = .{ .name = ident, .range = rng(61, 62) } }}), .is_non_exhaustive = true, .members = &.{}, .range = rng(61, 70) } },
        .{ .interface = .{ .name = ident, .interfaces = try alloc.dupe(HirType, &.{int_ty}), .members = &.{}, .range = rng(71, 80) } },
        .{ .extend_ = .{ .target = &int_ty, .interfaces = try alloc.dupe(HirType, &.{int_ty}), .members = &.{}, .range = rng(81, 90) } },
        .{ .prop = .{ .name = ident, .ty = &int_ty, .accessors = try alloc.dupe(PropAccessor, &.{.{ .name = ident, .params = empty_params, .body = &block, .range = rng(91, 95) }}), .range = rng(91, 96) } },
        alias_item,
        .{ .init = .{ .params = empty_params, .body = &block, .range = rng(97, 100) } },
        .{ .finalizer = .{ .params = empty_params, .body = &block, .range = rng(101, 104) } },
        .{ .primary_ctor = .{ .name = ident, .params = empty_params, .body = &block, .range = rng(105, 110) } },
        .{ .binding = .{ .kind = .let_, .pattern = &pat, .ty = &int_ty, .init = &int_expr, .range = rng(111, 118) } },
        .{ .foreign = .{ .members = try alloc.dupe(HirItem, &.{alias_item}), .range = rng(119, 125) } },
        .{ .macro_ = .{ .name = ident, .params = empty_params, .body = &int_expr, .range = rng(126, 130) } },
        .{ .macro_expand = .{ .call = .{ .path = try alloc.dupe(Name, &.{ident}), .has_bang = true }, .wrapped = &alias_item, .range = rng(131, 135) } },
    };

    try expectAllVariantsAndRanges(HirItem, &all_items, &[_]TextRange{
        rng(5, 30),    rng(30, 40),   rng(41, 50),   rng(51, 60),
        rng(61, 70),   rng(71, 80),   rng(81, 90),   rng(91, 96),
        rng(5, 6),     rng(97, 100),  rng(101, 104), rng(105, 110),
        rng(111, 118), rng(119, 125), rng(126, 130), rng(131, 135),
    });

    try std.testing.expectEqual(@as(usize, 2), func_item.func.modifiers.len);
    try std.testing.expectEqual(@as(usize, 1), func_item.func.type_params.len);
    try std.testing.expectEqual(@as(usize, 1), func_item.func.where_clause.?.constraints.len);
    try std.testing.expect(all_items[4].enum_.is_non_exhaustive);
    try std.testing.expectEqual(@as(usize, 1), all_items[4].enum_.variants.len);
    try std.testing.expectEqualStrings("f", all_items[11].primary_ctor.name.text);

    // 导入：分组、别名、通配符、组织名前缀与修饰符
    const imports = [_]ImportItem{
        .{
            .modifier = .public,
            .annotations = try alloc.dupe(Annotation, &.{.{ .path = try alloc.dupe(Name, &.{nm("When", rng(140, 144))}), .range = rng(139, 148) }}),
            .org = nm("myorg", rng(150, 155)),
            .prefix = try alloc.dupe(Name, &.{nm("a", rng(157, 158))}),
            .kind = .{ .group = try alloc.dupe(ImportItem, &.{
                .{ .kind = .{ .single = nm("b", rng(160, 161)) }, .range = rng(160, 161) },
                .{ .kind = .{ .alias = .{ .name = nm("c", rng(163, 164)), .alias = nm("d", rng(168, 169)) } }, .range = rng(163, 169) },
                .{ .kind = .{ .glob = {} }, .range = rng(171, 172) },
            }) },
            .range = rng(139, 174),
        },
        .{
            .prefix = try alloc.dupe(Name, &.{nm("std", rng(180, 183))}),
            .kind = .{ .glob = {} },
            .range = rng(175, 185),
        },
    };

    const file_id: FileId = .{ .index = 1, .generation = 2 };
    const hir_file: HirFile = .{
        .file = file_id,
        .version = 3,
        .package = .{
            .modifier = .public,
            .org = nm("myorg", rng(190, 195)),
            .name = try alloc.dupe(Name, &.{ nm("a", rng(197, 198)), nm("b", rng(199, 200)) }),
            .range = rng(188, 200),
        },
        .features = .{
            .features = try alloc.dupe(FeatureId, &.{.{ .segments = try alloc.dupe(Name, &.{nm("x", rng(201, 202))}), .range = rng(201, 202) }}),
            .range = rng(200, 204),
        },
        .imports = &imports,
        .items = &all_items,
    };

    try std.testing.expectEqual(@as(usize, 2), hir_file.imports.len);
    try std.testing.expectEqual(Modifier.public, hir_file.imports[0].modifier.?);
    try std.testing.expectEqual(@as(usize, 3), hir_file.imports[0].kind.group.len);
    try std.testing.expectEqualStrings("d", hir_file.imports[0].kind.group[1].kind.alias.alias.text);
    try std.testing.expectEqual(@as(usize, 2), hir_file.package.?.name.len);
    try std.testing.expectEqualStrings("myorg", hir_file.package.?.org.?.text);
    try std.testing.expectEqual(@as(usize, 1), hir_file.features.?.features.len);
    try std.testing.expectEqualStrings("x", hir_file.features.?.features[0].segments[0].text);

    try std.testing.expect(!hir_file.isOutdated(file_id, 3));
    try std.testing.expect(hir_file.isOutdated(file_id, 4));
    try std.testing.expect(hir_file.isOutdated(.{ .index = 1, .generation = 3 }, 3));
    try std.testing.expect(hir_file.isOutdated(.{ .index = 2, .generation = 2 }, 3));
}

// 覆盖带载荷变体的构造语法与分组导入元素的路径前缀。
test "参数、函数名、处理子句与枚举宏的带载荷变体构造" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const int_ty: HirType = .{ .path = .{
        .segments = &.{.{ .name = nm("Int64", rng(400, 405)) }},
        .range = rng(400, 405),
    } };
    const int_expr: HirExpr = .{ .int_lit = .{ .text = "0", .range = rng(0, 1) } };
    const block: BlockExpr = .{ .stmts = &.{}, .range = rng(1, 2) };
    const ident = nm("x", rng(2, 3));
    const raw_ident = rawName("this", rng(81, 85));
    const raw_path: HirExpr = .{ .path = .{ .segments = &.{.{ .name = raw_ident }}, .range = rng(81, 85) } };

    const payload_ty: EnumPayloadElement = .{ .ty = .{ .ty = &int_ty, .range = rng(86, 90) } };
    const payload_macro: EnumPayloadElement = .{ .macro_call = .{
        .call = .{
            .path = try alloc.dupe(Name, &.{nm("M", rng(91, 92))}),
            .attributes = rng(91, 94),
            .input = rng(94, 99),
        },
        .range = rng(91, 99),
    } };

    const plain_param_value: HirParam = .{ .name = ident, .ty = &int_ty, .range = rng(2, 12) };
    const plain_param: Param = .{ .param = plain_param_value };
    const macro_param: Param = .{ .macro_call = .{
        .call = .{ .path = try alloc.dupe(Name, &.{nm("M", rng(13, 14))}), .has_bang = true },
        .param = &plain_param,
        .range = rng(13, 22),
    } };
    const chained_param: Param = .{ .macro_call = .{
        .call = .{ .path = try alloc.dupe(Name, &.{nm("N", rng(61, 62))}) },
        .param = &macro_param,
        .range = rng(61, 70),
    } };

    const operator_name: FuncName = .{ .operator = nm("<=", rng(23, 25)) };

    const pat: HirPattern = .{ .binding = .{ .name = ident, .range = rng(2, 3) } };
    const catch_clause: TryClause = .{ .catch_ = .{ .pattern = &pat, .body = &block, .range = rng(26, 30) } };
    const handle_clause: TryClause = .{ .handle = .{ .pattern = &pat, .body = &block, .range = rng(31, 35) } };
    const expr_case: MatchCase = .{ .expr = .{ .value = &int_expr, .body = &block, .range = rng(36, 40) } };
    const resume_expr: ResumeExpr = .{
        .value = &int_expr,
        .modifier = .throwing,
        .modifier_value = &int_expr,
        .range = rng(41, 45),
    };

    const variant_macro: EnumVariant = .{ .macro_call = .{
        .call = .{ .path = try alloc.dupe(Name, &.{ident}) },
        .constructor = null,
        .range = rng(46, 50),
    } };
    const simple_variant: EnumVariant = .{ .constructor = .{ .name = ident, .range = rng(71, 72) } };
    const chained_variant: EnumVariant = .{ .macro_call = .{
        .call = .{ .path = try alloc.dupe(Name, &.{ident}), .has_bang = true },
        .constructor = &simple_variant,
        .range = rng(71, 80),
    } };

    const group_child: ImportItem = .{
        .prefix = try alloc.dupe(Name, &.{nm("e", rng(51, 52))}),
        .kind = .{ .glob = {} },
        .range = rng(51, 54),
    };
    const group_import: ImportItem = .{
        .prefix = try alloc.dupe(Name, &.{nm("a", rng(55, 56))}),
        .kind = .{ .group = try alloc.dupe(ImportItem, &.{group_child}) },
        .range = rng(55, 60),
    };

    try std.testing.expectEqual(.param, std.meta.activeTag(plain_param));
    try std.testing.expectEqual(.macro_call, std.meta.activeTag(macro_param));
    try std.testing.expect(macro_param.macro_call.call.has_bang);
    try std.testing.expectEqualStrings("x", macro_param.macro_call.param.?.param.name.?.text);
    try std.testing.expectEqual(.macro_call, std.meta.activeTag(chained_param.macro_call.param.?.*));
    try std.testing.expectEqualStrings("<=", operator_name.operator.text);
    try std.testing.expectEqual(.catch_, std.meta.activeTag(catch_clause));
    try std.testing.expectEqual(.handle, std.meta.activeTag(handle_clause));
    try std.testing.expectEqual(.expr, std.meta.activeTag(expr_case));
    try std.testing.expectEqual(ResumeModifier.throwing, resume_expr.modifier.?);
    try std.testing.expect(raw_ident.is_raw);
    try std.testing.expectEqualStrings("this", raw_path.path.segments[0].name.text);
    try std.testing.expectEqual(.ty, std.meta.activeTag(payload_ty));
    try std.testing.expectEqual(.macro_call, std.meta.activeTag(payload_macro));
    try std.testing.expectEqual(@as(?TextRange, rng(91, 94)), payload_macro.macro_call.call.attributes);
    try std.testing.expectEqual(.macro_call, std.meta.activeTag(variant_macro));
    try std.testing.expectEqual(.constructor, std.meta.activeTag(chained_variant.macro_call.constructor.?.*));
    try std.testing.expect(chained_variant.macro_call.call.has_bang);
    try std.testing.expectEqualStrings("e", group_import.kind.group[0].prefix[0].text);
    try std.testing.expectEqual(.glob, std.meta.activeTag(group_import.kind.group[0].kind));
}

/// CST 标签在 HIR 中的对应形态，用于确认每个 parser 节点都能被表达。
const CstRole = union(enum) {
    /// 空白、换行、注释、文件结束与词法错误，不进入 HIR。
    trivia,
    /// 运算符、分隔符与关键字叶子。
    lexeme,
    /// 标识符与字面量叶子，文本进入 HIR 的名字或字面量节点。
    value,
    /// 语法包装节点，信息并入父 HIR 节点或子列表。
    wrapper,
    /// 语法错误占位节点，不属于合法语法树。
    error_node,
    /// 对应独立 HIR 节点类型。
    node: type,
};

/// 测试辅助：给出每个 CST 标签的 HIR 对应形态。
///
/// 返回类型带 `type` 字段，必须在编译期求值。`SyntaxKind` 新增标签时这里会编译失败，
/// 迫使补齐 HIR 对应关系或明确归为包装节点。
fn cstRole(comptime kind: SyntaxKind) CstRole {
    return switch (kind) {
        // 空白、注释与文件边界
        .whitespace,
        .newline,
        .line_comment,
        .block_comment,
        .doc_comment,
        .eof,
        .illegal,
        => .trivia,

        // 标识符与字面量
        .identifier,
        .package_identifier,
        .dollar_identifier,
        .integer_literal,
        .float_literal,
        .rune_literal,
        .rune_byte_literal,
        .string_literal,
        .multiline_string,
        .multiline_raw_string,
        .string_content,
        .bool_literal,
        => .value,

        // 标点、分隔符与关键字
        .dot,
        .comma,
        .l_paren,
        .r_paren,
        .l_square,
        .r_square,
        .l_curl,
        .r_curl,
        .exp,
        .mul,
        .mod,
        .div,
        .add,
        .sub,
        .incr,
        .decr,
        .logical_and,
        .logical_or,
        .coalescing,
        .pipeline,
        .composition,
        .not,
        .bit_and,
        .bit_or,
        .bit_xor,
        .bit_not,
        .lshift,
        .rshift,
        .colon,
        .semi,
        .assign,
        .add_assign,
        .sub_assign,
        .mul_assign,
        .exp_assign,
        .div_assign,
        .mod_assign,
        .logical_and_assign,
        .logical_or_assign,
        .bit_and_assign,
        .bit_or_assign,
        .bit_xor_assign,
        .lshift_assign,
        .rshift_assign,
        .arrow,
        .backarrow,
        .double_arrow,
        .range_op,
        .closed_range_op,
        .ellipsis,
        .hash,
        .at,
        .at_excl,
        .quest,
        .less,
        .greater,
        .less_equal,
        .greater_equal,
        .not_equal,
        .equal,
        .wildcard,
        .dollar,
        .double_colon,
        .upperbound,
        .kw_is,
        .kw_as,
        .kw_not_in,
        .kw_int8,
        .kw_int16,
        .kw_int32,
        .kw_int64,
        .kw_int_native,
        .kw_uint8,
        .kw_uint16,
        .kw_uint32,
        .kw_uint64,
        .kw_uint_native,
        .kw_float16,
        .kw_float32,
        .kw_float64,
        .kw_rune,
        .kw_bool,
        .kw_nothing,
        .kw_unit,
        .kw_struct,
        .kw_enum,
        .kw_varray,
        .kw_this_type,
        .kw_package,
        .kw_import,
        .kw_class,
        .kw_interface,
        .kw_func,
        .kw_macro,
        .kw_quote,
        .kw_let,
        .kw_var,
        .kw_const,
        .kw_type,
        .kw_init,
        .kw_this,
        .kw_super,
        .kw_if,
        .kw_else,
        .kw_case,
        .kw_try,
        .kw_catch,
        .kw_finally,
        .kw_for,
        .kw_do,
        .kw_while,
        .kw_throw,
        .kw_return,
        .kw_continue,
        .kw_break,
        .kw_in,
        .kw_match,
        .kw_where,
        .kw_extend,
        .kw_with,
        .kw_prop,
        .kw_static,
        .kw_public,
        .kw_private,
        .kw_internal,
        .kw_protected,
        .kw_override,
        .kw_redef,
        .kw_abstract,
        .kw_sealed,
        .kw_open,
        .kw_foreign,
        .kw_inout,
        .kw_mut,
        .kw_unsafe,
        .kw_operator,
        .kw_spawn,
        .kw_synchronized,
        .kw_main,
        .kw_common,
        .kw_specific,
        .kw_perform,
        .kw_resume,
        .kw_throwing,
        .kw_handle,
        .kw_features,
        => .lexeme,

        // 源文件、特性、包与导入
        .source_file => .{ .node = HirFile },
        .features_directive => .{ .node = FeaturesDirective },
        .features_set => .wrapper,
        .feature_id => .{ .node = FeatureId },
        .package_header => .{ .node = PackageHeader },
        .package_name => .wrapper,
        .import_spec, .import_content => .{ .node = ImportItem },
        .annotation => .{ .node = Annotation },

        // 声明
        .class_decl => .{ .node = ClassItem },
        .interface_decl => .{ .node = InterfaceItem },
        .struct_decl => .{ .node = StructItem },
        .enum_decl => .{ .node = EnumItem },
        .enum_constructor => .{ .node = EnumConstructor },
        .func_decl => .{ .node = FuncItem },
        .main_decl => .{ .node = MainItem },
        .macro_decl => .{ .node = MacroItem },
        .var_decl => .{ .node = Binding },
        .prop_decl => .{ .node = PropItem },
        .prop_getter, .prop_setter => .{ .node = PropAccessor },
        .type_alias_decl => .{ .node = TypeAliasItem },
        .extend_decl => .{ .node = ExtendItem },
        .primary_ctor_decl => .{ .node = PrimaryCtorItem },
        .init_decl => .{ .node = InitItem },
        .finalizer_decl => .{ .node = FinalizerItem },
        .foreign_decl => .{ .node = ForeignItem },
        .foreign_block => .wrapper,
        .macro_expand_decl => .{ .node = MacroExpandItem }, // 枚举体内对应 VariantMacro
        .macro_expand_param => .{ .node = ParamMacro },
        .class_body, .interface_body, .struct_body, .enum_body, .extend_body => .wrapper,

        // 语句块、泛型与参数
        .block => .{ .node = BlockExpr },
        .stmt_list => .wrapper,
        .type_parameter_list => .wrapper,
        .type_parameter => .{ .node = Name },
        .type_argument_list => .wrapper,
        .where_clause => .{ .node = WhereClause },
        .generic_constraint => .{ .node = GenericConstraint },
        .func_param_list => .wrapper,
        .ret_type => .wrapper,
        .func_param => .{ .node = HirParam },
        .func_arg => .{ .node = HirCallArg },

        // 类型
        .path_segment => .wrapper,
        .primitive_type => .wrapper,
        .path_type => .{ .node = PathType },
        .paren_type => .wrapper,
        .tuple_type => .{ .node = TupleType },
        .func_type => .{ .node = FuncType },
        .option_type => .{ .node = OptionalType },
        .varray_type => .{ .node = VArrayType },
        .constant_type => .wrapper,
        .this_type => .{ .node = ThisType },

        // 模式
        .wildcard_pattern => .{ .node = WildcardPattern },
        .var_pattern => .{ .node = BindingPattern },
        .const_pattern => .{ .node = ConstPattern },
        .tuple_pattern => .{ .node = TuplePattern },
        .enum_pattern => .{ .node = EnumPattern },
        .type_pattern => .{ .node = TypePattern },
        .except_type_pattern, .command_type_pattern => .{ .node = ClausePattern },

        // 表达式
        .wildcard_expr => .{ .node = Bare },
        .path_expr => .{ .node = PathExpr },
        .call_expr => .{ .node = CallExpr },
        .subscript_expr => .{ .node = IndexExpr },
        .optional_expr => .{ .node = OptionalExpr },
        .paren_expr => .wrapper,
        .tuple_lit => .{ .node = TupleLit },
        .array_lit => .{ .node = ArrayLit },
        .varray_expr => .{ .node = VArrayExpr },
        .unit_literal => .{ .node = Bare },
        .binary_expr => .{ .node = BinaryExpr },
        .unary_expr => .{ .node = UnaryExpr },
        .inc_or_dec_expr => .{ .node = IncDecExpr },
        .assign_expr => .{ .node = AssignExpr },
        .range_expr => .{ .node = RangeExpr },
        .is_expr => .{ .node = IsExpr },
        .as_expr => .{ .node = AsExpr },
        .type_conv_expr => .{ .node = TypeConvExpr },
        .if_expr => .{ .node = IfExpr },
        .match_expr => .{ .node = MatchExpr },
        .match_case => .{ .node = PatternCase },
        .match_case_other => .{ .node = ExprCase },
        .pattern_guard => .wrapper,
        .while_expr => .{ .node = WhileExpr },
        .do_while_expr => .{ .node = DoWhileExpr },
        .for_in_expr => .{ .node = ForInExpr },
        .let_pattern_destructor => .{ .node = LetDestructor },
        .try_expr => .{ .node = TryExpr },
        .resource_spec => .{ .node = Resource },
        .catch_clause => .{ .node = CatchClause },
        .handle_clause => .{ .node = HandleClause },
        .finally_clause => .wrapper,
        .throw_expr => .{ .node = ThrowExpr },
        .return_expr => .{ .node = ReturnExpr },
        .jump_expr => .{ .node = JumpExpr },
        .lambda_expr => .{ .node = LambdaExpr },
        .trailing_closure_expr => .wrapper,
        .spawn_expr => .{ .node = SpawnExpr },
        .synchronized_expr => .{ .node = SynchronizedExpr },
        .unsafe_expr => .{ .node = UnsafeExpr },
        .quote_expr => .{ .node = QuoteExpr },
        .str_interpolation_expr => .{ .node = StrInterp },
        .interpolation_expr => .{ .node = StrInterpolation },
        .if_available_expr => .{ .node = IfAvailableExpr },
        .macro_expand_expr => .{ .node = MacroCallExpr },
        .perform_expr => .{ .node = PerformExpr },
        .resume_expr => .{ .node = ResumeExpr },
        .expression_statement => .{ .node = ExprStmt },

        // 宏的原始词法单元片段，内容由所属 HIR 节点的区间从源文件取得
        .macro_attributes, .macro_input, .token_part, .quote_interpolation => .wrapper,

        // 语法错误占位
        .error_node => .error_node,
    };
}

test "每个 CST 标签都有 HIR 对应或明确的折叠规则" {
    var node_count: usize = 0;
    var wrapper_count: usize = 0;

    inline for (std.enums.values(SyntaxKind)) |kind| {
        switch (comptime cstRole(kind)) {
            .trivia, .lexeme, .value, .error_node => {},
            .wrapper => wrapper_count += 1,
            .node => |T| {
                node_count += 1;
                if (T != HirFile and !@hasField(T, "range") and !@hasDecl(T, "range")) {
                    @compileError("HIR 节点类型缺少 range: " ++ @typeName(T));
                }
            },
        }
    }

    try std.testing.expect(node_count >= 70);
    try std.testing.expect(wrapper_count >= 20);
}
