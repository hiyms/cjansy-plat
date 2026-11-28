// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 跨文件语义分析核心句柄、可见性、访问域、访问上下文与符号分类定义。

const std = @import("std");
const common = @import("common");

/// 驻留字符串句柄；与 `Database` 同生命周期。
pub const InternedId = enum(u32) {
    _,

    /// 无效占位句柄。
    pub const invalid: InternedId = @fromBackingInt(std.math.maxInt(u32));

    /// 由 0-based 整数序号构造 `InternedId`。
    pub inline fn fromIndex(idx: u32) InternedId {
        return @fromBackingInt(idx);
    }

    /// 获取底层 0-based 整数序号。
    pub inline fn index(self: InternedId) u32 {
        return @backingInt(self);
    }
};

/// 模块句柄，唯一对应 `(org: ?InternedId, root_pkg: InternedId)`。
pub const ModuleId = enum(u32) {
    _,

    /// 无效占位句柄。
    pub const invalid: ModuleId = @fromBackingInt(std.math.maxInt(u32));

    /// 由 0-based 整数序号构造 `ModuleId`。
    pub inline fn fromIndex(idx: u32) ModuleId {
        return @fromBackingInt(idx);
    }

    /// 获取底层 0-based 整数序号。
    pub inline fn index(self: ModuleId) u32 {
        return @backingInt(self);
    }
};

/// 包句柄，唯一对应 `(org: ?InternedId, segments: []const InternedId)`。
pub const PackageId = enum(u32) {
    _,

    /// 无效占位句柄。
    pub const invalid: PackageId = @fromBackingInt(std.math.maxInt(u32));

    /// 由 0-based 整数序号构造 `PackageId`。
    pub inline fn fromIndex(idx: u32) PackageId {
        return @fromBackingInt(idx);
    }

    /// 获取底层 0-based 整数序号。
    pub inline fn index(self: PackageId) u32 {
        return @backingInt(self);
    }
};

/// 跨文件顶层声明项句柄。
pub const GlobalItemId = struct {
    file: common.FileId,
    item: common.ItemId,

    /// 判定两个 `GlobalItemId` 是否指向同一文件的同一顶层声明项。
    pub inline fn eql(a: GlobalItemId, b: GlobalItemId) bool {
        return common.FileId.eql(a.file, b.file) and a.item == b.item;
    }
};

/// 跨文件 HIR 节点句柄。
pub const GlobalHirKey = struct {
    file: common.FileId,
    key: common.HirKey,

    /// 判定两个 `GlobalHirKey` 是否指向同一文件的同一 HIR 节点。
    pub inline fn eql(a: GlobalHirKey, b: GlobalHirKey) bool {
        return common.FileId.eql(a.file, b.file) and common.HirKey.eql(a.key, b.key);
    }
};

/// 包级声明、类型成员、枚举构造器、主构造器与扩展块句柄。
///
/// 携带所属 `PackageState` 世代号 `pkg_gen`：当 `PackageState` 重建递增世代号后，
/// 旧 `DefId` 自动失效且不会与新声明在永久 `TypeInterner` 中发生索引碰撞。
pub const DefId = struct {
    pkg: PackageId,
    pkg_gen: u32,
    idx: u32,

    /// 判定两个 `DefId` 是否指向同一包、同一世代的同一声明对象。
    pub inline fn eql(a: DefId, b: DefId) bool {
        return a.pkg == b.pkg and a.pkg_gen == b.pkg_gen and a.idx == b.idx;
    }
};

/// 函数或语句块内局部符号句柄（局部变量、形参、局部函数、模式绑定、资源声明）。
pub const LocalSymId = struct {
    global_item: GlobalItemId,
    idx: u32,

    /// 判定两个 `LocalSymId` 是否指向同一顶层声明项内的同一局部符号。
    pub inline fn eql(a: LocalSymId, b: LocalSymId) bool {
        return GlobalItemId.eql(a.global_item, b.global_item) and a.idx == b.idx;
    }
};

/// 统一可调用声明句柄（供重载决议与头部签名查询同时覆盖包级与局部函数）。
pub const CallableRef = union(enum) {
    def: DefId,
    local: LocalSymId,

    /// 判定两个 `CallableRef` 是否指向同一可调用声明。
    pub inline fn eql(a: CallableRef, b: CallableRef) bool {
        return switch (a) {
            .def => |da| switch (b) {
                .def => |db| DefId.eql(da, db),
                else => false,
            },
            .local => |la| switch (b) {
                .local => |lb| LocalSymId.eql(la, lb),
                else => false,
            },
        };
    }
};

/// 文件内词法作用域句柄。
pub const ScopeId = struct {
    file: common.FileId,
    idx: u32,

    /// 判定两个 `ScopeId` 是否指向同一文件的同一词法作用域。
    pub inline fn eql(a: ScopeId, b: ScopeId) bool {
        return common.FileId.eql(a.file, b.file) and a.idx == b.idx;
    }
};

/// 规范化语义类型句柄；在 `TypeInterner` 未执行 `gcTypes` 前稳定有效，`O(1)` 比较相等。
pub const TypeId = enum(u32) {
    _,

    /// 由 0-based 整数序号构造 `TypeId`。
    pub inline fn fromIndex(idx: u32) TypeId {
        return @fromBackingInt(idx);
    }

    /// 获取底层 0-based 整数序号。
    pub inline fn index(self: TypeId) u32 {
        return @backingInt(self);
    }
};

/// 驻留的有序 `TypeId` 列表句柄（用于泛型参数列表、元组元素、函数形参列表）。
pub const TypeListId = enum(u32) {
    _,

    /// 空列表固定句柄。
    pub const empty: TypeListId = @fromBackingInt(0);

    /// 由 0-based 整数序号构造 `TypeListId`。
    pub inline fn fromIndex(idx: u32) TypeListId {
        return @fromBackingInt(idx);
    }

    /// 获取底层 0-based 整数序号。
    pub inline fn index(self: TypeListId) u32 {
        return @backingInt(self);
    }
};

/// 仓颉基础类型与内建底层类型种类。
pub const PrimKind = enum(u8) {
    int8,
    int16,
    int32,
    int64,
    int_native,
    uint8,
    uint16,
    uint32,
    uint64,
    uint_native,
    float16,
    float32,
    float64,
    rune,
    bool_,
    unit,
    nothing,
    cstring,

    /// 判定当前基础类型是否为有符号整数类型。
    pub inline fn isSignedInt(self: PrimKind) bool {
        return switch (self) {
            .int8, .int16, .int32, .int64, .int_native => true,
            else => false,
        };
    }

    /// 判定当前基础类型是否为无符号整数类型。
    pub inline fn isUnsignedInt(self: PrimKind) bool {
        return switch (self) {
            .uint8, .uint16, .uint32, .uint64, .uint_native => true,
            else => false,
        };
    }

    /// 判定当前基础类型是否为整数类型。
    pub inline fn isInteger(self: PrimKind) bool {
        return self.isSignedInt() or self.isUnsignedInt();
    }

    /// 判定当前基础类型是否为浮点类型。
    pub inline fn isFloat(self: PrimKind) bool {
        return switch (self) {
            .float16, .float32, .float64 => true,
            else => false,
        };
    }

    /// 判定当前基础类型是否为数值类型（整数或浮点）。
    pub inline fn isNumeric(self: PrimKind) bool {
        return self.isInteger() or self.isFloat();
    }

    /// 返回仓颉语言中的标准类型名称切片（编译期静态字符串，调用者无需释放）。
    pub inline fn displayName(self: PrimKind) []const u8 {
        return switch (self) {
            .int8 => "Int8",
            .int16 => "Int16",
            .int32 => "Int32",
            .int64 => "Int64",
            .int_native => "IntNative",
            .uint8 => "UInt8",
            .uint16 => "UInt16",
            .uint32 => "UInt32",
            .uint64 => "UInt64",
            .uint_native => "UIntNative",
            .float16 => "Float16",
            .float32 => "Float32",
            .float64 => "Float64",
            .rune => "Rune",
            .bool_ => "Bool",
            .unit => "Unit",
            .nothing => "Nothing",
            .cstring => "CString",
        };
    }

    /// 按源码关键字文本匹配基础类型（仅当 `!is_raw` 时由解析器或名称解析调用）。
    pub fn fromKeyword(text: []const u8) ?PrimKind {
        const table = std.StaticStringMap(PrimKind).initComptime(.{
            .{ "Int8", .int8 },
            .{ "Int16", .int16 },
            .{ "Int32", .int32 },
            .{ "Int64", .int64 },
            .{ "IntNative", .int_native },
            .{ "UInt8", .uint8 },
            .{ "UInt16", .uint16 },
            .{ "UInt32", .uint32 },
            .{ "UInt64", .uint64 },
            .{ "UIntNative", .uint_native },
            .{ "Float16", .float16 },
            .{ "Float32", .float32 },
            .{ "Float64", .float64 },
            .{ "Rune", .rune },
            .{ "Bool", .bool_ },
            .{ "Unit", .unit },
            .{ "Nothing", .nothing },
            .{ "CString", .cstring },
        });
        return table.get(text);
    }
};

/// 泛型形参所属声明句柄（支持包级类型/函数/扩展与局部泛型函数）。
pub const CallableOrTypeOwner = union(enum) {
    def: DefId,
    local: LocalSymId,

    /// 判定两个所有者句柄是否相等。
    pub inline fn eql(a: CallableOrTypeOwner, b: CallableOrTypeOwner) bool {
        return switch (a) {
            .def => |da| switch (b) {
                .def => |db| DefId.eql(da, db),
                else => false,
            },
            .local => |la| switch (b) {
                .local => |lb| LocalSymId.eql(la, lb),
                else => false,
            },
        };
    }
};

/// 声明上的泛型形参引用。
pub const TypeParamRef = struct {
    owner: CallableOrTypeOwner,
    index: u16,

    /// 判定两个泛型形参引用是否指向同一声明的同一序号形参。
    pub inline fn eql(a: TypeParamRef, b: TypeParamRef) bool {
        return a.index == b.index and CallableOrTypeOwner.eql(a.owner, b.owner);
    }
};

/// 统一符号引用目标。
pub const SymbolRef = union(enum) {
    def: DefId,
    local: LocalSymId,
    prim: PrimKind,
    pkg: PackageId,
    type_param: TypeParamRef,

    /// 判定两个符号引用是否指向同一目标。
    pub inline fn eql(a: SymbolRef, b: SymbolRef) bool {
        return switch (a) {
            .def => |da| switch (b) {
                .def => |db| DefId.eql(da, db),
                else => false,
            },
            .local => |la| switch (b) {
                .local => |lb| LocalSymId.eql(la, lb),
                else => false,
            },
            .prim => |pa| switch (b) {
                .prim => |pb| pa == pb,
                else => false,
            },
            .pkg => |pa| switch (b) {
                .pkg => |pb| pa == pb,
                else => false,
            },
            .type_param => |ta| switch (b) {
                .type_param => |tb| TypeParamRef.eql(ta, tb),
                else => false,
            },
        };
    }
};

/// 仓颉四级可见性，按开放程度升序排列：`private < internal < protected < public`。
pub const Visibility = enum(u8) {
    private = 0,
    internal = 1,
    protected = 2,
    public = 3,

    /// 返回两者中更严格的可见性（用于外层名义类型封顶计算）。
    pub inline fn min(a: Visibility, b: Visibility) Visibility {
        return if (@backingInt(a) <= @backingInt(b)) a else b;
    }

    /// 返回两者中更开放的可见性。
    pub inline fn max(a: Visibility, b: Visibility) Visibility {
        return if (@backingInt(a) >= @backingInt(b)) a else b;
    }

    /// 判定 `self` 的开放程度是否不高于 `other`（用于公开签名低可见性暴露检查）。
    pub inline fn isNoMoreOpenThan(self: Visibility, other: Visibility) bool {
        return @backingInt(self) <= @backingInt(other);
    }

    /// 从 HIR 修饰符切片中提取可见性修饰符；无显式修饰符时返回 `default_vis`。
    pub fn fromModifiers(modifiers: []const common.Modifier, default_vis: Visibility) Visibility {
        for (modifiers) |m| {
            switch (m) {
                .public => return .public,
                .protected => return .protected,
                .internal => return .internal,
                .private => return .private,
                .sealed => return .public,
                else => {},
            }
        }
        return default_vis;
    }
};

/// 声明的可达范围域，专用于 `references` / `rename` 扫描候选文件集合裁剪。
pub const AccessDomain = union(enum) {
    file_only: common.FileId,
    def_body: DefId,
    package_subtree: PackageId,
    package_subtree_and_parent: PackageId,
    module_only: ModuleId,
    module_and_subclasses: struct { module: ModuleId, owner: DefId },
    everywhere: void,
};

/// 语义访问权限检查上下文。
pub const AccessContext = struct {
    module_id: ModuleId,
    pkg_id: PackageId,
    file_id: common.FileId,
    /// 从内向外排列的封闭类型或 `extend` 定义链（顶层代码中为空切片）。
    enclosing_defs: []const DefId = &.{},
    /// 当前是否位于静态上下文（`static func`、`static init`、静态字段初始化）。
    is_static_context: bool = false,
};

/// 符号分类（用于对外视图与 LSP 符号类别映射）。
pub const SymbolKind = enum(u8) {
    module,
    package,
    class_,
    struct_,
    enum_,
    interface_,
    type_alias,
    func_,
    method,
    constructor,
    primary_ctor,
    finalizer,
    prop,
    field,
    enum_variant,
    variable,
    constant,
    param,
    type_param,
    macro_,
    extend_,
};

/// 标识符引用性质（区分读写、调用与类型引用）。
pub const ReferenceKind = enum(u8) {
    decl,
    read,
    write,
    read_write,
    call,
    type_ref,
    import_ref,
    named_arg,
};

test "句柄相等比较与世代区分" {
    const p0 = PackageId.fromIndex(1);
    const d1: DefId = .{ .pkg = p0, .pkg_gen = 1, .idx = 0 };
    const d2: DefId = .{ .pkg = p0, .pkg_gen = 2, .idx = 0 };
    try std.testing.expect(!DefId.eql(d1, d2));
    try std.testing.expect(DefId.eql(d1, .{ .pkg = p0, .pkg_gen = 1, .idx = 0 }));
    try std.testing.expectEqual(Visibility.internal, Visibility.min(.public, .internal));
    try std.testing.expect(Visibility.internal.isNoMoreOpenThan(.public));
    try std.testing.expect(!Visibility.public.isNoMoreOpenThan(.private));
    try std.testing.expectEqual(PrimKind.int64, PrimKind.fromKeyword("Int64").?);
    try std.testing.expectEqualStrings("Int64", PrimKind.int64.displayName());
}
