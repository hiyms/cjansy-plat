// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 外部预编译包索引加载协议（`PackageIndexProvider`）与内置最小核心标准库引导。

const std = @import("std");
const common = @import("common");
const ids = @import("../ids.zig");
const pkg_state_mod = @import("PackageState.zig");
const file_state_mod = @import("FileState.zig");
const type_interner_mod = @import("../interner/TypeInterner.zig");
const queries_mod = @import("../view/Queries.zig");
const db_mod = @import("Database.zig");

const CallableHeaderSig = pkg_state_mod.CallableHeaderSig;
const CallableParamSig = pkg_state_mod.CallableParamSig;
const Database = db_mod.Database;
const DefEntry = pkg_state_mod.DefEntry;
const DefId = ids.DefId;
const ExportEntry = pkg_state_mod.ExportEntry;
const InternedId = ids.InternedId;
const Location = queries_mod.Location;
const NominalHeader = pkg_state_mod.NominalHeader;
const PackageId = ids.PackageId;
const PackageState = pkg_state_mod.PackageState;
const PlatformError = file_state_mod.PlatformError;
const PrimKind = ids.PrimKind;
const SymbolKind = ids.SymbolKind;
const TypeAliasHeader = pkg_state_mod.TypeAliasHeader;
const TypeId = ids.TypeId;
const TypeInterner = type_interner_mod.TypeInterner;
const TypeParamRef = ids.TypeParamRef;

/// 预编译索引符号检索命中项（支撑未导入标准库符号的自动导入补全）。
pub const PreloadSymbolMatch = struct {
    pkg: PackageId,
    name: InternedId,
    kind: SymbolKind,
};

/// 预编译包索引加载器（纯内存抽象，无宿主磁盘 I/O 依赖）。
pub const PackageIndexProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 查询给定 `PackageId` 是否由预编译索引提供。
        hasPackage: *const fn (ctx: *anyopaque, db: *Database, pkg: PackageId) bool,

        /// 将目标包反序列化到新分配的 `*PackageState`（必须通过 `db.gpa` 分配并置 `is_preloaded = true`，
        /// 同时填充包内 `defs`、`nominal_headers`、`type_alias_headers`、`callable_headers`、`prop_types`、`explicit_var_types`、
        /// `top_exports`、`enum_ctors`、`member_to_owners`、`extends` 及对应文档注释句柄；加载 `std.core` 时一并向 `db.types` 写入基础类型、`VArray` 与 `CPointer` 的文档注释）。
        /// 返回的 `*PackageState` 所有权移交 `Database`，由 `Database` 统一托管与释放。
        loadPackage: *const fn (
            ctx: *anyopaque,
            db: *Database,
            pkg: PackageId,
        ) PlatformError!?*PackageState,

        /// 列举指定父包下的直接子包列表（`parent == null` 时列举根包，支撑 `import std.` 补全）。
        /// 返回切片由调用者传入的 `alloc` 分配，结束后须由调用者释放。
        listSubpackages: *const fn (
            ctx: *anyopaque,
            db: *Database,
            parent: ?PackageId,
            alloc: std.mem.Allocator,
        ) PlatformError![]PackageId,

        /// 按标识符前缀检索尚未加载的预编译包中可自动导入的公开符号。
        /// 返回切片由调用者传入的 `alloc` 分配，结束后须由调用者释放。
        searchExportedSymbols: *const fn (
            ctx: *anyopaque,
            db: *Database,
            prefix: []const u8,
            alloc: std.mem.Allocator,
        ) PlatformError![]PreloadSymbolMatch,

        /// 在执行定义跳转或类型定义跳转时，按需为预编译声明生成只读内存声明源码（`FileType.Header`）并返回精确跳转位置 `Location`。
        materializeHeaderSource: *const fn (
            ctx: *anyopaque,
            db: *Database,
            def: DefId,
        ) PlatformError!?Location,
    };
};

/// 引导初始化内置最小 `std.core` 只读核心包并绑定 `Database.types.known` 与基础类型默认文档注释。
/// 仅在未配置外部 `preload_provider` 或外部索引未提供 `std.core` 时由 `Database.init` / `Database.gcTypes` 调用。
pub fn bootstrapBuiltinCore(db: *Database) PlatformError!void {
    const s_std = try db.strings.intern("std");
    const s_core = try db.strings.intern("core");
    const core_pkg = try db.pkg_interner.internPackage(null, &.{ s_std, s_core });
    const pkg_info = db.pkg_interner.getPackage(core_pkg);

    const state = try db.gpa.create(PackageState);
    errdefer db.gpa.destroy(state);
    state.* = .{
        .pkg_id = core_pkg,
        .module_id = pkg_info.module_id,
        .pkg_vis = .public,
        .is_preloaded = true,
        .generation = 1,
        .arena = .init(db.gpa),
    };
    errdefer state.deinit();

    const a = state.arena.allocator();
    var defs_buf: std.ArrayListUnmanaged(DefEntry) = .empty;

    const addNominal = struct {
        /// 向核心引导包登记单个名义类型及其 `NominalHeader` 与公开顶层导出条目。
        fn call(
            db_inner: *Database,
            alloc: std.mem.Allocator,
            buf: *std.ArrayListUnmanaged(DefEntry),
            st: *PackageState,
            kind: SymbolKind,
            name_str: []const u8,
            doc_str: []const u8,
            tp_names: []const []const u8,
            supertypes: []const TypeId,
        ) PlatformError!DefId {
            const def_idx: u32 = @intCast(buf.items.len);
            const def_id: DefId = .{ .pkg = st.pkg_id, .pkg_gen = st.generation, .idx = def_idx };
            const name_id = try db_inner.strings.intern(name_str);
            const doc_id = try db_inner.strings.intern(doc_str);
            const tps_interned = try alloc.alloc(InternedId, tp_names.len);
            const tp_refs = try alloc.alloc(TypeParamRef, tp_names.len);
            for (tp_names, 0..) |tp, i| {
                tps_interned[i] = try db_inner.strings.intern(tp);
                tp_refs[i] = .{ .owner = .{ .def = def_id }, .index = @intCast(i) };
            }
            try buf.append(alloc, .{
                .id = def_id,
                .kind = kind,
                .name = name_id,
                .declared_vis = .public,
                .effective_vis = .public,
                .doc = doc_id,
                .type_param_names = tps_interned,
                .is_header_decl = true,
            });
            const nh = try alloc.create(NominalHeader);
            nh.* = .{
                .def = def_id,
                .type_params = tp_refs,
                .supertypes = try alloc.dupe(TypeId, supertypes),
                .where_bounds = &.{},
                .doc = doc_id,
            };
            try st.nominal_headers.put(alloc, def_idx, nh);
            const exp = try alloc.dupe(ExportEntry, &.{.{
                .def = def_id,
                .exported_name = name_id,
                .vis = .public,
                .is_reexport = false,
                .source_file = null,
            }});
            try st.top_exports.put(alloc, name_id, exp);
            return def_id;
        }
    }.call;

    // 预填基础类型默认文档注释
    const prim_doc_pairs = [_]struct { PrimKind, []const u8 }{
        .{ .int8, "8 位有符号整数类型（范围 -128 至 127）。" },
        .{ .int16, "16 位有符号整数类型（范围 -32768 至 32767）。" },
        .{ .int32, "32 位有符号整数类型。" },
        .{ .int64, "64 位有符号整数类型，也是无后缀整数字面量的默认类型。" },
        .{ .int_native, "与目标平台指针位宽一致的有符号整数类型。" },
        .{ .uint8, "8 位无符号整数类型（范围 0 至 255）。" },
        .{ .uint16, "16 位无符号整数类型（范围 0 至 65535）。" },
        .{ .uint32, "32 位无符号整数类型。" },
        .{ .uint64, "64 位无符号整数类型。" },
        .{ .uint_native, "与目标平台指针位宽一致的无符号整数类型。" },
        .{ .float16, "IEEE 754 半精度（16 位）浮点类型。" },
        .{ .float32, "IEEE 754 单精度（32 位）浮点类型。" },
        .{ .float64, "IEEE 754 双精度（64 位）浮点类型，也是无后缀浮点字面量的默认类型。" },
        .{ .rune, "表示单个 Unicode 码点的字符类型。" },
        .{ .bool_, "布尔逻辑类型，取值为 true 或 false。" },
        .{ .unit, "仅包含唯一取值 () 的单元类型。" },
        .{ .nothing, "所有类型的底类型，表示不会正常返回的发散表达式。" },
        .{ .cstring, "C 互操作空终止字节字符串类型。" },
    };
    for (prim_doc_pairs) |pair| {
        db.types.setPrimDoc(pair[0], try db.strings.intern(pair[1]));
    }
    db.types.setVArrayDoc(try db.strings.intern("固定长度值数组类型 VArray<T, $N>。"));
    db.types.setCPointerDoc(try db.strings.intern("C 互操作指针类型 CPointer<T>。"));

    // 注册 std.core 核心名义类型
    const any_def = try addNominal(db, a, &defs_buf, state, .interface_, "Any", "仓颉所有类型默认实现的顶层接口。", &.{}, &.{});
    const any_ty = try db.types.intern(.{ .nominal = .{ .def = any_def, .args = .empty } });
    const ctype_def = try addNominal(db, a, &defs_buf, state, .interface_, "CType", "C 互操作类型约束顶层接口。", &.{}, &.{any_ty});
    const obj_def = try addNominal(db, a, &defs_buf, state, .class_, "Object", "仓颉所有类的默认根父类。", &.{}, &.{any_ty});
    const obj_ty = try db.types.intern(.{ .nominal = .{ .def = obj_def, .args = .empty } });
    const to_str_def = try addNominal(db, a, &defs_buf, state, .interface_, "ToString", "提供字符串格式化转换能力的接口。", &.{}, &.{any_ty});
    const to_str_ty = try db.types.intern(.{ .nominal = .{ .def = to_str_def, .args = .empty } });
    const eq_def = try addNominal(db, a, &defs_buf, state, .interface_, "Equatable", "提供相等比较运算符的泛型接口。", &.{"T"}, &.{any_ty});
    const cmp_def = try addNominal(db, a, &defs_buf, state, .interface_, "Comparable", "提供全序比较运算符的泛型接口。", &.{"T"}, &.{any_ty});
    const cnt_def = try addNominal(db, a, &defs_buf, state, .interface_, "Countable", "表示可离散步进计数类型的泛型接口。", &.{"T"}, &.{any_ty});
    const iter_def = try addNominal(db, a, &defs_buf, state, .interface_, "Iterator", "顺序访问集合元素的迭代器接口。", &.{"E"}, &.{any_ty});
    const iterable_def = try addNominal(db, a, &defs_buf, state, .interface_, "Iterable", "支持 for-in 循环遍历的泛型接口。", &.{"E"}, &.{any_ty});
    const res_def = try addNominal(db, a, &defs_buf, state, .interface_, "Resource", "支持 try-with-resources 自动释放的资源接口。", &.{}, &.{any_ty});
    const str_def = try addNominal(db, a, &defs_buf, state, .struct_, "String", "UTF-8 编码的不可变字符串类型。", &.{}, &.{to_str_ty});
    const arr_def = try addNominal(db, a, &defs_buf, state, .struct_, "Array", "动态长度顺序数组类型 Array<T>。", &.{"T"}, &.{any_ty});
    const opt_def = try addNominal(db, a, &defs_buf, state, .enum_, "Option", "表示可能存在值（Some）或空值（None）的可选枚举类型。", &.{"T"}, &.{any_ty});
    const range_def = try addNominal(db, a, &defs_buf, state, .struct_, "Range", "表示起止区间与步长的区间类型 Range<T>。", &.{"T"}, &.{any_ty});
    const exc_def = try addNominal(db, a, &defs_buf, state, .class_, "Exception", "可捕获运行时异常基类。", &.{}, &.{ obj_ty, to_str_ty });
    const err_def = try addNominal(db, a, &defs_buf, state, .class_, "Error", "系统级错误基类。", &.{}, &.{ obj_ty, to_str_ty });
    const tc_def = try addNominal(db, a, &defs_buf, state, .interface_, "ThreadContext", "仓颉并发线程调度上下文接口。", &.{}, &.{any_ty});
    const fut_def = try addNominal(db, a, &defs_buf, state, .class_, "Future", "表示并发任务异步执行结果的泛型类 Future<T>。", &.{"T"}, &.{obj_ty});

    // 为 Option<T> 补充 Some(T) 与 None 构造器
    const opt_tp_ty = try db.types.intern(.{ .type_param = .{ .owner = .{ .def = opt_def }, .index = 0 } });
    const opt_self_args = try db.types.internList(&.{opt_tp_ty});
    const opt_self_ty = try db.types.intern(.{ .nominal = .{ .def = opt_def, .args = opt_self_args } });

    const some_idx: u32 = @intCast(defs_buf.items.len);
    const some_def: DefId = .{ .pkg = core_pkg, .pkg_gen = state.generation, .idx = some_idx };
    const s_some = try db.strings.intern("Some");
    try defs_buf.append(a, .{
        .id = some_def,
        .kind = .enum_variant,
        .name = s_some,
        .declared_vis = .public,
        .effective_vis = .public,
        .owner = opt_def,
        .doc = try db.strings.intern("表示 Option<T> 包含有效值。"),
        .is_header_decl = true,
    });
    const some_sig = try a.create(CallableHeaderSig);
    some_sig.* = .{
        .owner = .{ .def = some_def },
        .type_params = state.nominal_headers.get(opt_def.idx).?.type_params,
        .where_bounds = &.{},
        .params = try a.dupe(CallableParamSig, &.{.{ .name = null, .ty = opt_tp_ty, .is_named = false, .has_default = false }}),
        .is_variadic = false,
        .explicit_ret = opt_self_ty,
        .is_enum_ctor = true,
    };
    try state.callable_headers.put(a, some_idx, some_sig);
    try state.enum_ctors.put(a, s_some, try a.dupe(DefId, &.{some_def}));

    const none_idx: u32 = @intCast(defs_buf.items.len);
    const none_def: DefId = .{ .pkg = core_pkg, .pkg_gen = state.generation, .idx = none_idx };
    const s_none = try db.strings.intern("None");
    try defs_buf.append(a, .{
        .id = none_def,
        .kind = .enum_variant,
        .name = s_none,
        .declared_vis = .public,
        .effective_vis = .public,
        .owner = opt_def,
        .doc = try db.strings.intern("表示 Option<T> 为空值。"),
        .is_header_decl = true,
    });
    try state.explicit_var_types.put(a, none_idx, opt_self_ty);
    try state.enum_ctors.put(a, s_none, try a.dupe(DefId, &.{none_def}));

    defs_buf.items[opt_def.idx].members = try a.dupe(DefId, &.{ some_def, none_def });

    // 为 Array<T> 补充常见属性 size 与下标运算符/构造器，确保基础容器表达式可推导
    const arr_tp_ty = try db.types.intern(.{ .type_param = .{ .owner = .{ .def = arr_def }, .index = 0 } });
    const arr_self_args = try db.types.internList(&.{arr_tp_ty});
    const arr_self_ty = try db.types.intern(.{ .nominal = .{ .def = arr_def, .args = arr_self_args } });
    const arr_size_idx: u32 = @intCast(defs_buf.items.len);
    const arr_size_def: DefId = .{ .pkg = core_pkg, .pkg_gen = state.generation, .idx = arr_size_idx };
    const s_size = try db.strings.intern("size");
    try defs_buf.append(a, .{
        .id = arr_size_def,
        .kind = .prop,
        .name = s_size,
        .declared_vis = .public,
        .effective_vis = .public,
        .owner = arr_def,
        .doc = try db.strings.intern("数组元素个数。"),
        .is_header_decl = true,
    });
    try state.prop_types.put(a, arr_size_idx, TypeInterner.int64_ty);

    const arr_init_idx: u32 = @intCast(defs_buf.items.len);
    const arr_init_def: DefId = .{ .pkg = core_pkg, .pkg_gen = state.generation, .idx = arr_init_idx };
    const s_init = try db.strings.intern("init");
    try defs_buf.append(a, .{
        .id = arr_init_def,
        .kind = .constructor,
        .name = s_init,
        .declared_vis = .public,
        .effective_vis = .public,
        .owner = arr_def,
        .doc = try db.strings.intern("构造指定长度与初始值的数组。"),
        .is_header_decl = true,
    });
    const arr_init_sig = try a.create(CallableHeaderSig);
    arr_init_sig.* = .{
        .owner = .{ .def = arr_init_def },
        .type_params = state.nominal_headers.get(arr_def.idx).?.type_params,
        .where_bounds = &.{},
        .params = try a.dupe(CallableParamSig, &.{
            .{ .name = try db.strings.intern("size"), .ty = TypeInterner.int64_ty, .is_named = false, .has_default = false },
            .{ .name = try db.strings.intern("repeat"), .ty = arr_tp_ty, .is_named = true, .has_default = false },
        }),
        .is_variadic = false,
        .explicit_ret = arr_self_ty,
        .is_ctor = true,
    };
    try state.callable_headers.put(a, arr_init_idx, arr_init_sig);
    defs_buf.items[arr_def.idx].members = try a.dupe(DefId, &.{ arr_size_def, arr_init_def });

    // 为 String 补充 size 属性
    const str_size_idx: u32 = @intCast(defs_buf.items.len);
    const str_size_def: DefId = .{ .pkg = core_pkg, .pkg_gen = state.generation, .idx = str_size_idx };
    try defs_buf.append(a, .{
        .id = str_size_def,
        .kind = .prop,
        .name = s_size,
        .declared_vis = .public,
        .effective_vis = .public,
        .owner = str_def,
        .doc = try db.strings.intern("字符串 UTF-8 字节长度。"),
        .is_header_decl = true,
    });
    try state.prop_types.put(a, str_size_idx, TypeInterner.int64_ty);
    defs_buf.items[str_def.idx].members = try a.dupe(DefId, &.{str_size_def});

    // 注册内置类型别名：Byte = UInt8、Int = Int64、UInt = UInt64
    const alias_specs = [_]struct { []const u8, TypeId, []const u8 }{
        .{ "Byte", TypeInterner.uint8_ty, "UInt8 的内置类型别名。" },
        .{ "Int", TypeInterner.int64_ty, "Int64 的内置类型别名。" },
        .{ "UInt", TypeInterner.uint64_ty, "UInt64 的内置类型别名。" },
    };
    for (alias_specs) |spec| {
        const idx: u32 = @intCast(defs_buf.items.len);
        const alias_def: DefId = .{ .pkg = core_pkg, .pkg_gen = state.generation, .idx = idx };
        const name_id = try db.strings.intern(spec[0]);
        const doc_id = try db.strings.intern(spec[2]);
        try defs_buf.append(a, .{
            .id = alias_def,
            .kind = .type_alias,
            .name = name_id,
            .declared_vis = .public,
            .effective_vis = .public,
            .doc = doc_id,
            .is_header_decl = true,
        });
        const tah = try a.create(TypeAliasHeader);
        tah.* = .{
            .def = alias_def,
            .type_params = &.{},
            .target = spec[1],
            .doc = doc_id,
        };
        try state.type_alias_headers.put(a, idx, tah);
        try state.top_exports.put(a, name_id, try a.dupe(ExportEntry, &.{.{
            .def = alias_def,
            .exported_name = name_id,
            .vis = .public,
            .is_reexport = false,
            .source_file = null,
        }}));
    }

    // 注册基础打印函数 println / print
    const print_names = [_]struct { []const u8, []const u8 }{
        .{ "println", "向标准输出打印字符串或可转换对象并换行。" },
        .{ "print", "向标准输出打印字符串或可转换对象。" },
    };
    for (print_names) |pn| {
        const idx: u32 = @intCast(defs_buf.items.len);
        const fn_def: DefId = .{ .pkg = core_pkg, .pkg_gen = state.generation, .idx = idx };
        const name_id = try db.strings.intern(pn[0]);
        const doc_id = try db.strings.intern(pn[1]);
        try defs_buf.append(a, .{
            .id = fn_def,
            .kind = .func_,
            .name = name_id,
            .declared_vis = .public,
            .effective_vis = .public,
            .doc = doc_id,
            .is_header_decl = true,
        });
        const sig = try a.create(CallableHeaderSig);
        sig.* = .{
            .owner = .{ .def = fn_def },
            .type_params = &.{},
            .where_bounds = &.{},
            .params = try a.dupe(CallableParamSig, &.{.{
                .name = try db.strings.intern("value"),
                .ty = any_ty,
                .is_named = false,
                .has_default = true,
            }}),
            .is_variadic = false,
            .explicit_ret = TypeInterner.unit_ty,
        };
        try state.callable_headers.put(a, idx, sig);
        try state.top_exports.put(a, name_id, try a.dupe(ExportEntry, &.{.{
            .def = fn_def,
            .exported_name = name_id,
            .vis = .public,
            .is_reexport = false,
            .source_file = null,
        }}));
    }

    state.defs = try defs_buf.toOwnedSlice(a);
    try state.member_to_owners.put(a, s_size, try a.dupe(DefId, &.{ arr_def, str_def }));

    try db.pkg_generations.put(db.gpa, core_pkg, state.generation);
    try db.packages.put(db.gpa, core_pkg, state);

    db.types.known = .{
        .std_core_pkg = core_pkg,
        .any_iface = any_def,
        .ctype_iface = ctype_def,
        .object_class = obj_def,
        .string_struct = str_def,
        .array_struct = arr_def,
        .option_enum = opt_def,
        .option_some = some_def,
        .option_none = none_def,
        .range_struct = range_def,
        .iterable_iface = iterable_def,
        .iterator_iface = iter_def,
        .to_string_iface = to_str_def,
        .equatable_iface = eq_def,
        .comparable_iface = cmp_def,
        .countable_iface = cnt_def,
        .resource_iface = res_def,
        .exception_class = exc_def,
        .error_class = err_def,
        .thread_context_iface = tc_def,
        .future_class = fut_def,
    };
}
