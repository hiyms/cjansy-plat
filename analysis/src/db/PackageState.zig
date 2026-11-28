// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 包级世代状态（`PackageState`）、结构稳定路径（`DefOrigin`）与包级声明头结构定义。

const std = @import("std");
const common = @import("common");
const ids = @import("../ids.zig");

const CallableRef = ids.CallableRef;
const DefId = ids.DefId;
const InternedId = ids.InternedId;
const ModuleId = ids.ModuleId;
const PackageId = ids.PackageId;
const PrimKind = ids.PrimKind;
const SymbolKind = ids.SymbolKind;
const TypeId = ids.TypeId;
const TypeParamRef = ids.TypeParamRef;
const Visibility = ids.Visibility;

/// 与函数体内部编辑完全解耦的声明结构路径（通过 `O(1)` 切片下标直接定位当前版本 `LoweredFile` 中的目标 HIR 节点）。
pub const DefOrigin = union(enum) {
    /// 顶层声明项：`lowered.lowered_items[item].item`。
    top_item: struct { file: common.FileId, item: common.ItemId },
    /// 容器成员声明（`class`/`struct`/`enum`/`interface`/`extend` 的 `members[member_idx]`）。
    member: struct { file: common.FileId, item: common.ItemId, member_idx: u32 },
    /// 枚举构造器（`enum_.variants[variant_idx]`）。
    enum_variant: struct { file: common.FileId, item: common.ItemId, variant_idx: u32 },
    /// 主构造器带 `let`/`var` 的成员字段（`members[member_idx].primary_ctor.params[param_idx]`）。
    primary_ctor_field: struct { file: common.FileId, item: common.ItemId, member_idx: u32, param_idx: u32 },
    /// `foreign` 块内声明（`foreign.members[member_idx]`）。
    foreign_member: struct { file: common.FileId, item: common.ItemId, member_idx: u32 },
    /// 顶层或成员解构绑定 `let (a, b) = ...` 中的第 `pat_ordinal` 个绑定变量。
    binding_var: struct { file: common.FileId, item: common.ItemId, member_idx: ?u32, pat_ordinal: u32 },

    /// 返回当前结构路径所属的源文件句柄。
    pub inline fn fileId(self: DefOrigin) common.FileId {
        return switch (self) {
            inline else => |payload| payload.file,
        };
    }

    /// 返回当前结构路径所属的顶层声明项句柄。
    pub inline fn itemId(self: DefOrigin) common.ItemId {
        return switch (self) {
            inline else => |payload| payload.item,
        };
    }
};

/// 声明修饰标志位集合。
pub const DefFlags = packed struct(u16) {
    is_static: bool = false,
    is_open: bool = false,
    is_sealed: bool = false,
    is_abstract: bool = false,
    is_override: bool = false,
    is_redef: bool = false,
    is_mut: bool = false,
    is_const: bool = false,
    is_unsafe: bool = false,
    is_operator: bool = false,
    is_foreign: bool = false,
    is_variadic: bool = false,
    has_body: bool = false,
    _pad: u3 = 0,

    /// 从 HIR 修饰符切片构造标志位集合。
    pub fn fromModifiers(modifiers: []const common.Modifier, has_body: bool, is_variadic: bool) DefFlags {
        var f: DefFlags = .{ .has_body = has_body, .is_variadic = is_variadic };
        for (modifiers) |m| {
            switch (m) {
                .static => f.is_static = true,
                .open => f.is_open = true,
                .sealed => {
                    f.is_sealed = true;
                    f.is_open = true;
                },
                .abstract => {
                    f.is_abstract = true;
                    f.is_open = true;
                },
                .override => f.is_override = true,
                .redef => f.is_redef = true,
                .mut => f.is_mut = true,
                .const_ => f.is_const = true,
                .unsafe => f.is_unsafe = true,
                .operator => f.is_operator = true,
                else => {},
            }
        }
        return f;
    }
};

/// 包级声明对象记录（顶层声明、类型成员、构造器、枚举构造器、`extend` 块）。
pub const DefEntry = struct {
    id: DefId,
    kind: SymbolKind,
    name: InternedId,
    /// 源码结构路径（预编译索引来源时为 `null`）。
    origin: ?DefOrigin = null,
    /// 声明来源文件（顶层 `private` 同文件过滤与失效追踪依据；预编译索引来源时为 `null`）。
    source_file: ?common.FileId = null,
    /// 声明自身书写的（或语法默认的）可见性。
    declared_vis: Visibility,
    /// 经外层名义类型封顶后的有效可见性（对应 `cangjie_compiler` 的 `GetAccessLevel`，不含 `package` 修饰符封顶）。
    effective_vis: Visibility,
    /// 封闭宿主定义（顶层声明为 `null`，成员指向所属 `class`/`struct`/`enum`/`interface`/`extend`）。
    owner: ?DefId = null,
    /// 前导文档注释正文（已去除注释定界符，统一覆盖源码声明与预编译标准库索引）。
    doc: ?InternedId = null,
    flags: DefFlags = .{},
    /// 类型形参名称列表（`class`/`struct`/`enum`/`interface`/`extend`/`type`/`func`）。
    type_param_names: []const InternedId = &.{},
    /// 成员列表（容器声明拥有）。
    members: []const DefId = &.{},
    /// 是否由 `FileType.Header` 或预编译索引提供（允许无函数体声明）。
    is_header_decl: bool = false,
};

/// 泛型 `where` 约束上界签名（不含绝对字节区间，定位源码位置时通过 `DefOrigin` 从当前版本 `LoweredFile` 按约束下标读取）。
pub const GenericBoundSig = struct {
    subject: TypeId,
    upper_bounds: []const TypeId,
};

/// 名义类型声明（`class`/`struct`/`enum`/`interface`）的继承、泛型约束与文档注释头（分配于 `PackageState.arena`）。
pub const NominalHeader = struct {
    def: DefId,
    type_params: []const TypeParamRef,
    /// `class` 首项为直接父类（省略时隐式指向 `Object`），其余项为实现接口；其余容器全部为父接口或实现接口。
    supertypes: []const TypeId,
    where_bounds: []const GenericBoundSig,
    /// 该类型声明的前导文档注释句柄（经 `StringInterner` 驻留，无文档注释为 `null`）。
    doc: ?InternedId = null,
};

/// 类型别名声明（`type Alias<T> = Target`）的完整头信息（分配于 `PackageState.arena`）。
pub const TypeAliasHeader = struct {
    def: DefId,
    type_params: []const TypeParamRef,
    /// 在 `buildPackageState` 阶段经 `Database.type_alias_cache` 三色求值完成后写入的展开目标类型（循环别名置 `TypeInterner.err_ty`），构造后保持只读不可变。
    target: TypeId,
    /// 该类型别名声明的前导文档注释句柄（无文档注释为 `null`）。
    doc: ?InternedId = null,
};

/// 可调用声明的形参头签名（不含绝对字节区间，定位源码位置时通过 `DefOrigin` 从当前版本 `LoweredFile` 按形参下标读取）。
pub const CallableParamSig = struct {
    name: ?InternedId,
    ty: TypeId,
    is_named: bool,
    has_default: bool,
};

/// 可调用声明的不依赖函数体的头部签名（包级签名分配于 `PackageState.arena`，局部函数签名分配于 `FileQueryState.sema_arena`）。
pub const CallableHeaderSig = struct {
    owner: CallableRef,
    type_params: []const TypeParamRef,
    where_bounds: []const GenericBoundSig,
    params: []const CallableParamSig,
    is_variadic: bool,
    /// 显式返回类型；源码函数省略返回类型标注时为 `null`（抽象/接口/`foreign`/`FileType.Header` 缺标注置 `TypeInterner.err_ty`）。
    explicit_ret: ?TypeId,
    is_ctor: bool = false,
    is_enum_ctor: bool = false,
};

/// 包内符号导出条目（含当前包声明与经非私有 `import` 重导出的外部符号）。
pub const ExportEntry = struct {
    def: DefId,
    exported_name: InternedId,
    vis: Visibility,
    /// `true` 表示来自 `public`/`protected`/`internal import` 重导出（影响 `scope_level` 与包限定访问）。
    is_reexport: bool,
    source_file: ?common.FileId,
};

/// `extend` 成员与所实现接口的对应记录（用于跨包接口扩展可见性检查）。
pub const ExtendMemberIface = struct {
    member: DefId,
    /// 若该成员实现某个扩展接口中的成员，指向对应接口 `DefId`；否则为 `null`。
    implemented_iface: ?DefId,
};

/// 被扩展目标类型的归类键（用于 `VisibleExtendIndex` 按主类型快速分组）。
pub const ExtendTargetKind = union(enum) {
    nominal: DefId,
    prim: PrimKind,
};

/// 单个 `extend` 声明的包级完整元数据。
pub const ExtendEntry = struct {
    def: DefId,
    target_kind: ExtendTargetKind,
    /// 被扩展目标类型的完整模板类型（区分 `extend Array<Int64>`、`extend<T> Array<T>` 与 `extend<T> Array<Option<T>>`）。
    target_ty: TypeId,
    type_params: []const TypeParamRef = &.{},
    where_bounds: []const GenericBoundSig = &.{},
    /// 该 `extend` 实现的接口类型列表。
    implemented_interfaces: []const TypeId = &.{},
    /// 扩展内各成员到其实现接口的映射（跨包接口扩展要求该接口在调用方文件已导入）。
    member_ifaces: []const ExtendMemberIface = &.{},
    /// 扩展自身计算出的导出可见性（遵循 `SetExtendExternalAttr` 规则）。
    export_vis: Visibility,
    is_direct: bool,
    is_exported: bool,
    /// 泛型约束上界中引用的全部名义类型（跨包可见性检查要求调用方文件已导入全部上界类型）。
    constraint_types: []const DefId = &.{},
    /// 该 `extend` 声明的前导文档注释句柄（无文档注释为 `null`）。
    doc: ?InternedId = null,
};

/// 包级声明目录、重导出结果、继承头、类型别名头、可调用头、属性与变量显式类型表与扩展目录。
pub const PackageState = struct {
    pkg_id: PackageId,
    module_id: ModuleId,
    pkg_vis: Visibility = .public,
    is_macro_pkg: bool = false,
    /// `true` 表示来自预编译只读索引（如内置 `std`），禁止被源码重建路径覆写。
    is_preloaded: bool = false,
    /// 本包世代号（从 1 起递增，同步写入本包所有 `DefId.pkg_gen`）。
    generation: u32 = 1,
    arena: std.heap.ArenaAllocator,

    files: []const common.FileId = &.{},
    /// 按源文件索引本包归属该文件的全部 `DefId`（与 `PackageState.arena` 同生命周期，供 `updateFile` 安全清理本文件推导缓存）。
    file_defs: std.AutoHashMapUnmanaged(common.FileId, []const DefId) = .empty,
    /// 按 `DefId.idx` 顺序存储本包全部声明对象。
    defs: []const DefEntry = &.{},
    /// 本包名义类型的继承、泛型约束与文档注释头表（键为 `DefId.idx`）。
    nominal_headers: std.AutoHashMapUnmanaged(u32, *const NominalHeader) = .empty,
    /// 本包类型别名的头信息表（键为 `DefId.idx`，包含泛型形参、展开目标类型与前导文档注释）。
    type_alias_headers: std.AutoHashMapUnmanaged(u32, *const TypeAliasHeader) = .empty,
    /// 本包可调用声明（顶层函数、方法、构造器、枚举构造器、宏）的头部签名表（键为 `DefId.idx`）。
    callable_headers: std.AutoHashMapUnmanaged(u32, *const CallableHeaderSig) = .empty,
    /// 本包属性类型表（键为 `DefId.idx`）。
    prop_types: std.AutoHashMapUnmanaged(u32, TypeId) = .empty,
    /// 本包顶层与成员 `let`/`var`/`const` 的显式类型注解表（键为 `DefId.idx`；省略类型注解时不入表，交由 `varTypeOf` 按需推导）。
    explicit_var_types: std.AutoHashMapUnmanaged(u32, TypeId) = .empty,

    /// 包顶层名称到全部可见导出条目的映射（支持同名重载函数多条目）。
    top_exports: std.AutoHashMapUnmanaged(InternedId, []const ExportEntry) = .empty,
    /// 按名称索引本包全部无限定枚举构造器。
    enum_ctors: std.AutoHashMapUnmanaged(InternedId, []const DefId) = .empty,
    /// 成员名称到所属容器类型列表的反向索引（支持无上下文 Lambda 参数类型反推 `TryInferFromSyntaxInfo`）。
    member_to_owners: std.AutoHashMapUnmanaged(InternedId, []const DefId) = .empty,
    /// 本包内所有 `extend` 记录。
    extends: []const ExtendEntry = &.{},
    /// 本包直接依赖的外部包列表（用于反向依赖图维护与循环依赖检测）。
    direct_deps: []const PackageId = &.{},
    /// 包结构汇聚阶段产生的诊断。
    diagnostics: []const common.Diagnostic = &.{},

    /// 按 `DefId.idx` 在 `O(1)` 时间内获取只读定义条目；返回指针借用自 `PackageState.arena`，调用者不得释放。
    pub inline fn getDef(self: *const PackageState, idx: u32) ?*const DefEntry {
        return if (idx < self.defs.len) &self.defs[idx] else null;
    }

    /// 查找顶层名称对应的全部导出条目；返回切片借用自 `PackageState.arena`，调用者不得释放。
    pub inline fn lookupTop(self: *const PackageState, name: InternedId) []const ExportEntry {
        return self.top_exports.get(name) orelse &.{};
    }

    /// 查找指定 `extend` 中某成员对应的实现接口 `DefId`；非接口实现成员返回 `null`。
    pub fn findImplementingInterface(self: *const PackageState, extend_def: DefId, member: DefId) ?DefId {
        for (self.extends) |ext| {
            if (!DefId.eql(ext.def, extend_def)) continue;
            for (ext.member_ifaces) |mi| {
                if (DefId.eql(mi.member, member)) return mi.implemented_iface;
            }
            return null;
        }
        return null;
    }

    /// 释放 `PackageState` 独占的 `arena` 内存池（所有内部哈希表与切片均分配于 `arena`）。
    pub fn deinit(self: *PackageState) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
