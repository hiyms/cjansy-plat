// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 全局规范化类型驻留池、内建类型文档表与已知标准库声明句柄表。

const std = @import("std");
const ids = @import("../ids.zig");

const DefId = ids.DefId;
const InternedId = ids.InternedId;
const PackageId = ids.PackageId;
const PrimKind = ids.PrimKind;
const TypeId = ids.TypeId;
const TypeListId = ids.TypeListId;
const TypeParamRef = ids.TypeParamRef;

/// 目标平台指针位宽配置（解耦 WASM 32 位宿主与目标 64 位编译环境）。
pub const PointerWidth = enum(u8) {
    bits32 = 32,
    bits64 = 64,
};

/// 类型系统目标平台行为配置。
pub const TargetConfig = struct {
    pointer_width: PointerWidth = .bits64,
    implicit_prelude: bool = true,
};

/// 驻留后的规范化语义类型载荷（不含局部求解器临时占位符 `TyVarId`）。
pub const TypeData = union(enum) {
    /// 毒药错误类型。
    err: void,
    /// 部分未知目标或待定返回哨兵（对应 `cangjie_compiler` 的 `QuestTy`）。
    quest: void,
    /// 未加后缀整数字面量中间类型（`IdealInt`），禁止进入公开函数签名。
    ideal_int: void,
    /// 未加后缀浮点字面量中间类型（`IdealFloat`），禁止进入公开函数签名。
    ideal_float: void,
    /// 内建基础类型（含 `Unit`、底类型 `Nothing` 与 `CString`）。
    prim: PrimKind,
    /// 名义类型具体化：`class` / `struct` / `enum` / `interface`。
    nominal: struct {
        def: DefId,
        args: TypeListId,
    },
    /// C 互操作指针类型 `CPointer<T>`（类型参数严格不变）。
    cpointer: TypeId,
    /// 固定长度值数组 `VArray<T, $N>`。
    varray: struct {
        elem: TypeId,
        len: u64,
    },
    /// 元组类型 `(T1, T2, ...)`（已移除仅供可读性的元素标签）。
    tuple: TypeListId,
    /// 函数类型 `(P1, P2, ...) -> R` 或 `CFunc<(P1, P2, ...) -> R>`。
    func: struct {
        params: TypeListId,
        ret: TypeId,
        is_cfunc: bool = false,
    },
    /// 泛型声明上的通用类型形参（`isPlaceholder == false`）。
    type_param: TypeParamRef,
    /// 类成员返回 `This` 时的动态绑定类型（`ClassThisTy`）。
    class_this: DefId,
};

/// `std.core` 与 `std.sync` 中与语言语义直接耦合的已知声明句柄表。
pub const KnownDefs = struct {
    std_core_pkg: ?PackageId = null,
    std_sync_pkg: ?PackageId = null,
    any_iface: ?DefId = null,
    ctype_iface: ?DefId = null,
    object_class: ?DefId = null,
    string_struct: ?DefId = null,
    array_struct: ?DefId = null,
    option_enum: ?DefId = null,
    option_some: ?DefId = null,
    option_none: ?DefId = null,
    range_struct: ?DefId = null,
    iterable_iface: ?DefId = null,
    iterator_iface: ?DefId = null,
    to_string_iface: ?DefId = null,
    equatable_iface: ?DefId = null,
    comparable_iface: ?DefId = null,
    countable_iface: ?DefId = null,
    resource_iface: ?DefId = null,
    exception_class: ?DefId = null,
    error_class: ?DefId = null,
    thread_context_iface: ?DefId = null,
    future_class: ?DefId = null,
    lock_iface: ?DefId = null,
};

const TypeListContext = struct {
    /// 计算 `TypeId` 切片的 64 位哈希值。
    pub fn hash(_: TypeListContext, key: []const TypeId) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(key));
    }

    /// 比较两个 `TypeId` 切片是否逐元素相等。
    pub fn eql(_: TypeListContext, a: []const TypeId, b: []const TypeId) bool {
        return std.mem.eql(TypeId, a, b);
    }
};

const TypeDataContext = struct {
    /// 计算 `TypeData` 的结构哈希值。
    pub fn hash(_: TypeDataContext, key: TypeData) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const tag: u8 = @backingInt(std.meta.activeTag(key));
        hasher.update(&.{tag});
        switch (key) {
            .err, .quest, .ideal_int, .ideal_float => {},
            .prim => |p| hasher.update(&.{@backingInt(p)}),
            .nominal => |n| {
                hasher.update(std.mem.asBytes(&n.def.pkg));
                hasher.update(std.mem.asBytes(&n.def.pkg_gen));
                hasher.update(std.mem.asBytes(&n.def.idx));
                hasher.update(std.mem.asBytes(&n.args));
            },
            .cpointer => |c| hasher.update(std.mem.asBytes(&c)),
            .varray => |v| {
                hasher.update(std.mem.asBytes(&v.elem));
                hasher.update(std.mem.asBytes(&v.len));
            },
            .tuple => |t| hasher.update(std.mem.asBytes(&t)),
            .func => |f| {
                hasher.update(std.mem.asBytes(&f.params));
                hasher.update(std.mem.asBytes(&f.ret));
                hasher.update(&.{@intFromBool(f.is_cfunc)});
            },
            .type_param => |tp| {
                const owner_tag: u8 = @backingInt(std.meta.activeTag(tp.owner));
                hasher.update(&.{owner_tag});
                switch (tp.owner) {
                    .def => |d| {
                        hasher.update(std.mem.asBytes(&d.pkg));
                        hasher.update(std.mem.asBytes(&d.pkg_gen));
                        hasher.update(std.mem.asBytes(&d.idx));
                    },
                    .local => |l| {
                        hasher.update(std.mem.asBytes(&l.global_item.file.index));
                        hasher.update(std.mem.asBytes(&l.global_item.file.generation));
                        hasher.update(std.mem.asBytes(&l.global_item.item));
                        hasher.update(std.mem.asBytes(&l.idx));
                    },
                }
                hasher.update(std.mem.asBytes(&tp.index));
            },
            .class_this => |d| {
                hasher.update(std.mem.asBytes(&d.pkg));
                hasher.update(std.mem.asBytes(&d.pkg_gen));
                hasher.update(std.mem.asBytes(&d.idx));
            },
        }
        return hasher.final();
    }

    /// 比较两个 `TypeData` 是否结构相等。
    pub fn eql(_: TypeDataContext, a: TypeData, b: TypeData) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .err, .quest, .ideal_int, .ideal_float => true,
            .prim => |pa| pa == b.prim,
            .nominal => |na| DefId.eql(na.def, b.nominal.def) and na.args == b.nominal.args,
            .cpointer => |ca| ca == b.cpointer,
            .varray => |va| va.elem == b.varray.elem and va.len == b.varray.len,
            .tuple => |ta| ta == b.tuple,
            .func => |fa| fa.params == b.func.params and fa.ret == b.func.ret and fa.is_cfunc == b.func.is_cfunc,
            .type_param => |tpa| TypeParamRef.eql(tpa, b.type_param),
            .class_this => |da| DefId.eql(da, b.class_this),
        };
    }
};

/// 全局规范化语义类型驻留池。
pub const TypeInterner = struct {
    pub const err_ty: TypeId = .fromIndex(0);
    pub const quest_ty: TypeId = .fromIndex(1);
    pub const ideal_int_ty: TypeId = .fromIndex(2);
    pub const ideal_float_ty: TypeId = .fromIndex(3);
    pub const unit_ty: TypeId = .fromIndex(4);
    pub const nothing_ty: TypeId = .fromIndex(5);
    pub const bool_ty: TypeId = .fromIndex(6);
    pub const rune_ty: TypeId = .fromIndex(7);
    pub const int8_ty: TypeId = .fromIndex(8);
    pub const int16_ty: TypeId = .fromIndex(9);
    pub const int32_ty: TypeId = .fromIndex(10);
    pub const int64_ty: TypeId = .fromIndex(11);
    pub const int_native_ty: TypeId = .fromIndex(12);
    pub const uint8_ty: TypeId = .fromIndex(13);
    pub const uint16_ty: TypeId = .fromIndex(14);
    pub const uint32_ty: TypeId = .fromIndex(15);
    pub const uint64_ty: TypeId = .fromIndex(16);
    pub const uint_native_ty: TypeId = .fromIndex(17);
    pub const float16_ty: TypeId = .fromIndex(18);
    pub const float32_ty: TypeId = .fromIndex(19);
    pub const float64_ty: TypeId = .fromIndex(20);
    pub const cstring_ty: TypeId = .fromIndex(21);

    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    types: std.ArrayListUnmanaged(TypeData) = .empty,
    type_map: std.HashMapUnmanaged(TypeData, TypeId, TypeDataContext, std.hash_map.default_max_load_percentage) = .empty,
    lists: std.ArrayListUnmanaged([]const TypeId) = .empty,
    list_map: std.HashMapUnmanaged([]const TypeId, TypeListId, TypeListContext, std.hash_map.default_max_load_percentage) = .empty,

    known: KnownDefs = .{},
    target: TargetConfig = .{},
    /// 内建基础类型、`VArray` 与 `CPointer` 的文档注释句柄表（`resetKeepingBuiltins` 予以保留）。
    prim_docs: [@typeInfo(PrimKind).@"enum".field_names.len]?InternedId = @splat(null),
    varray_doc: ?InternedId = null,
    cpointer_doc: ?InternedId = null,

    /// 初始化类型驻留池并预填全部固定类型槽位。
    pub fn init(gpa: std.mem.Allocator, target: TargetConfig) std.mem.Allocator.Error!TypeInterner {
        var self: TypeInterner = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .target = target,
        };
        errdefer self.deinit();
        try self.populateBuiltins();
        return self;
    }

    /// 释放类型驻留池与内部全部类型列表内存。
    pub fn deinit(self: *TypeInterner) void {
        self.types.deinit(self.gpa);
        self.type_map.deinit(self.gpa);
        self.lists.deinit(self.gpa);
        self.list_map.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// 清空除预置固定槽位与内建类型文档表外的所有驻留类型与列表（供 `Database.gcTypes` 调用，调用前须先清空全部依赖旧 `TypeId` 的语义缓存）。
    pub fn resetKeepingBuiltins(self: *TypeInterner) std.mem.Allocator.Error!void {
        self.types.clearRetainingCapacity();
        self.type_map.clearRetainingCapacity();
        self.lists.clearRetainingCapacity();
        self.list_map.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        try self.populateBuiltins();
    }

    /// 写入全部预置固定槽位与空类型列表槽位 `TypeListId.empty`。
    fn populateBuiltins(self: *TypeInterner) std.mem.Allocator.Error!void {
        const empty_id = try self.internList(&.{});
        std.debug.assert(empty_id == TypeListId.empty);

        const builtins = [_]TypeData{
            .{ .err = {} },
            .{ .quest = {} },
            .{ .ideal_int = {} },
            .{ .ideal_float = {} },
            .{ .prim = .unit },
            .{ .prim = .nothing },
            .{ .prim = .bool_ },
            .{ .prim = .rune },
            .{ .prim = .int8 },
            .{ .prim = .int16 },
            .{ .prim = .int32 },
            .{ .prim = .int64 },
            .{ .prim = .int_native },
            .{ .prim = .uint8 },
            .{ .prim = .uint16 },
            .{ .prim = .uint32 },
            .{ .prim = .uint64 },
            .{ .prim = .uint_native },
            .{ .prim = .float16 },
            .{ .prim = .float32 },
            .{ .prim = .float64 },
            .{ .prim = .cstring },
        };
        for (builtins, 0..) |data, idx| {
            const id = try self.intern(data);
            std.debug.assert(id.index() == idx);
        }
    }

    /// 返回当前已驻留的 `TypeData` 总条目数（用于内存水位监控）。
    pub inline fn count(self: *const TypeInterner) u32 {
        return @intCast(self.types.items.len);
    }

    /// 设置指定基础类型的文档注释驻留句柄。
    pub fn setPrimDoc(self: *TypeInterner, kind: PrimKind, doc: ?InternedId) void {
        self.prim_docs[@backingInt(kind)] = doc;
    }

    /// 获取指定基础类型的文档注释驻留句柄；未设置返回 `null`。
    pub inline fn getPrimDoc(self: *const TypeInterner, kind: PrimKind) ?InternedId {
        return self.prim_docs[@backingInt(kind)];
    }

    /// 设置内建 `VArray` 类型的文档注释驻留句柄。
    pub fn setVArrayDoc(self: *TypeInterner, doc: ?InternedId) void {
        self.varray_doc = doc;
    }

    /// 设置内建 `CPointer` 类型的文档注释驻留句柄。
    pub fn setCPointerDoc(self: *TypeInterner, doc: ?InternedId) void {
        self.cpointer_doc = doc;
    }

    /// 查询内建类型（`prim`、`varray`、`cpointer`）对应的文档注释驻留句柄；非内建类型或未设置返回 `null`。
    pub fn builtinDocOf(self: *const TypeInterner, id: TypeId) ?InternedId {
        return switch (self.get(id)) {
            .prim => |k| self.getPrimDoc(k),
            .varray => self.varray_doc,
            .cpointer => self.cpointer_doc,
            else => null,
        };
    }

    /// 驻留单个 `TypeData` 并返回规范化 `TypeId`。
    pub fn intern(self: *TypeInterner, data: TypeData) std.mem.Allocator.Error!TypeId {
        if (self.type_map.get(data)) |existing| return existing;
        const id = TypeId.fromIndex(@intCast(self.types.items.len));
        try self.types.ensureUnusedCapacity(self.gpa, 1);
        try self.type_map.put(self.gpa, data, id);
        self.types.appendAssumeCapacity(data);
        return id;
    }

    /// 驻留有序 `TypeId` 切片并返回 `TypeListId`（空切片返回 `TypeListId.empty`）。
    pub fn internList(self: *TypeInterner, elems: []const TypeId) std.mem.Allocator.Error!TypeListId {
        if (elems.len == 0 and self.lists.items.len > 0) return TypeListId.empty;
        if (self.list_map.get(elems)) |existing| return existing;
        const owned = if (elems.len == 0)
            &[_]TypeId{}
        else
            try self.arena.allocator().dupe(TypeId, elems);
        const id = TypeListId.fromIndex(@intCast(self.lists.items.len));
        try self.lists.ensureUnusedCapacity(self.gpa, 1);
        try self.list_map.put(self.gpa, owned, id);
        self.lists.appendAssumeCapacity(owned);
        return id;
    }

    /// 快捷获取 `PrimKind` 对应的固定 `TypeId`。
    pub inline fn prim(kind: PrimKind) TypeId {
        return switch (kind) {
            .unit => unit_ty,
            .nothing => nothing_ty,
            .bool_ => bool_ty,
            .rune => rune_ty,
            .int8 => int8_ty,
            .int16 => int16_ty,
            .int32 => int32_ty,
            .int64 => int64_ty,
            .int_native => int_native_ty,
            .uint8 => uint8_ty,
            .uint16 => uint16_ty,
            .uint32 => uint32_ty,
            .uint64 => uint64_ty,
            .uint_native => uint_native_ty,
            .float16 => float16_ty,
            .float32 => float32_ty,
            .float64 => float64_ty,
            .cstring => cstring_ty,
        };
    }

    /// 快捷构造 `Option<inner>` 类型（未绑定 `known.option_enum` 时返回 `err_ty`）。
    pub fn internOption(self: *TypeInterner, inner: TypeId) std.mem.Allocator.Error!TypeId {
        const opt_def = self.known.option_enum orelse return err_ty;
        const args = try self.internList(&.{inner});
        return self.intern(.{ .nominal = .{ .def = opt_def, .args = args } });
    }

    /// 快捷构造 `Array<elem>` 类型（未绑定 `known.array_struct` 时返回 `err_ty`）。
    pub fn internArray(self: *TypeInterner, elem: TypeId) std.mem.Allocator.Error!TypeId {
        const arr_def = self.known.array_struct orelse return err_ty;
        const args = try self.internList(&.{elem});
        return self.intern(.{ .nominal = .{ .def = arr_def, .args = args } });
    }

    /// 快捷构造 `String` 类型（未绑定 `known.string_struct` 时返回 `err_ty`）。
    pub fn internString(self: *TypeInterner) std.mem.Allocator.Error!TypeId {
        const str_def = self.known.string_struct orelse return err_ty;
        return self.intern(.{ .nominal = .{ .def = str_def, .args = TypeListId.empty } });
    }

    /// 快捷构造 `Any` 接口对应的名义类型 `TypeId`（未绑定 `known.any_iface` 时返回 `err_ty`）。
    pub fn internAny(self: *TypeInterner) std.mem.Allocator.Error!TypeId {
        const any_def = self.known.any_iface orelse return err_ty;
        return self.intern(.{ .nominal = .{ .def = any_def, .args = TypeListId.empty } });
    }

    /// 快捷构造 `Object` 类对应的名义类型 `TypeId`（未绑定 `known.object_class` 时返回 `err_ty`）。
    pub fn internObject(self: *TypeInterner) std.mem.Allocator.Error!TypeId {
        const obj_def = self.known.object_class orelse return err_ty;
        return self.intern(.{ .nominal = .{ .def = obj_def, .args = TypeListId.empty } });
    }

    /// 按 `TypeId` 获取只读类型载荷。
    pub inline fn get(self: *const TypeInterner, id: TypeId) TypeData {
        return self.types.items[id.index()];
    }

    /// 按 `TypeListId` 获取只读类型切片；返回切片借用自内部 `arena`，在 `resetKeepingBuiltins` 或 `deinit` 前有效，调用者不得释放。
    pub inline fn getList(self: *const TypeInterner, id: TypeListId) []const TypeId {
        return self.lists.items[id.index()];
    }

    /// 递归判定 `id` 及其内部参数是否包含 `TypeData.quest`。
    pub fn hasQuest(self: *const TypeInterner, id: TypeId) bool {
        return switch (self.get(id)) {
            .quest => true,
            .err, .ideal_int, .ideal_float, .prim, .type_param, .class_this => false,
            .nominal => |n| {
                for (self.getList(n.args)) |a| {
                    if (self.hasQuest(a)) return true;
                }
                return false;
            },
            .cpointer => |c| self.hasQuest(c),
            .varray => |v| self.hasQuest(v.elem),
            .tuple => |t| {
                for (self.getList(t)) |e| {
                    if (self.hasQuest(e)) return true;
                }
                return false;
            },
            .func => |f| {
                if (self.hasQuest(f.ret)) return true;
                for (self.getList(f.params)) |p| {
                    if (self.hasQuest(p)) return true;
                }
                return false;
            },
        };
    }

    /// 递归判定 `id` 及其内部参数是否包含 `ideal_int` 或 `ideal_float`。
    pub fn hasIdeal(self: *const TypeInterner, id: TypeId) bool {
        return switch (self.get(id)) {
            .ideal_int, .ideal_float => true,
            .err, .quest, .prim, .type_param, .class_this => false,
            .nominal => |n| {
                for (self.getList(n.args)) |a| {
                    if (self.hasIdeal(a)) return true;
                }
                return false;
            },
            .cpointer => |c| self.hasIdeal(c),
            .varray => |v| self.hasIdeal(v.elem),
            .tuple => |t| {
                for (self.getList(t)) |e| {
                    if (self.hasIdeal(e)) return true;
                }
                return false;
            },
            .func => |f| {
                if (self.hasIdeal(f.ret)) return true;
                for (self.getList(f.params)) |p| {
                    if (self.hasIdeal(p)) return true;
                }
                return false;
            },
        };
    }

    /// 递归判定 `id` 及其内部参数是否包含 `TypeData.err`。
    pub fn hasErr(self: *const TypeInterner, id: TypeId) bool {
        return switch (self.get(id)) {
            .err => true,
            .quest, .ideal_int, .ideal_float, .prim, .type_param, .class_this => false,
            .nominal => |n| {
                for (self.getList(n.args)) |a| {
                    if (self.hasErr(a)) return true;
                }
                return false;
            },
            .cpointer => |c| self.hasErr(c),
            .varray => |v| self.hasErr(v.elem),
            .tuple => |t| {
                for (self.getList(t)) |e| {
                    if (self.hasErr(e)) return true;
                }
                return false;
            },
            .func => |f| {
                if (self.hasErr(f.ret)) return true;
                for (self.getList(f.params)) |p| {
                    if (self.hasErr(p)) return true;
                }
                return false;
            },
        };
    }

    /// 递归将 `ideal_int -> int64`、`ideal_float -> float64` 替换为具体类型。
    pub fn replaceIdeal(self: *TypeInterner, id: TypeId) std.mem.Allocator.Error!TypeId {
        if (!self.hasIdeal(id)) return id;
        return switch (self.get(id)) {
            .ideal_int => int64_ty,
            .ideal_float => float64_ty,
            .nominal => |n| blk: {
                const old_args = self.getList(n.args);
                const buf = try self.gpa.alloc(TypeId, old_args.len);
                defer self.gpa.free(buf);
                for (old_args, 0..) |a, i| buf[i] = try self.replaceIdeal(a);
                const new_list = try self.internList(buf);
                break :blk try self.intern(.{ .nominal = .{ .def = n.def, .args = new_list } });
            },
            .cpointer => |c| try self.intern(.{ .cpointer = try self.replaceIdeal(c) }),
            .varray => |v| try self.intern(.{ .varray = .{ .elem = try self.replaceIdeal(v.elem), .len = v.len } }),
            .tuple => |t| blk: {
                const old_elems = self.getList(t);
                const buf = try self.gpa.alloc(TypeId, old_elems.len);
                defer self.gpa.free(buf);
                for (old_elems, 0..) |e, i| buf[i] = try self.replaceIdeal(e);
                const new_list = try self.internList(buf);
                break :blk try self.intern(.{ .tuple = new_list });
            },
            .func => |f| blk: {
                const old_params = self.getList(f.params);
                const buf = try self.gpa.alloc(TypeId, old_params.len);
                defer self.gpa.free(buf);
                for (old_params, 0..) |p, i| buf[i] = try self.replaceIdeal(p);
                const new_params = try self.internList(buf);
                const new_ret = try self.replaceIdeal(f.ret);
                break :blk try self.intern(.{ .func = .{ .params = new_params, .ret = new_ret, .is_cfunc = f.is_cfunc } });
            },
            else => id,
        };
    }

    /// 移除最外层单个 `Option<T>` 并返回 `T`；非 `Option` 返回 `null`。
    pub inline fn unwrapOptionOnce(self: *const TypeInterner, id: TypeId) ?TypeId {
        const opt_def = self.known.option_enum orelse return null;
        return switch (self.get(id)) {
            .nominal => |n| blk: {
                if (!DefId.eql(n.def, opt_def)) break :blk null;
                const args = self.getList(n.args);
                break :blk if (args.len == 1) args[0] else null;
            },
            else => null,
        };
    }

    /// 计算 `Option` 外壳嵌套层数（非 `Option` 返回 `0`）。
    pub fn optionDepth(self: *const TypeInterner, id: TypeId) u32 {
        var depth: u32 = 0;
        var cur = id;
        while (self.unwrapOptionOnce(cur)) |inner| {
            depth += 1;
            cur = inner;
        }
        return depth;
    }

    /// 循环移除所有外层 `Option` 外壳，返回最内层载荷类型。
    pub fn unboxOption(self: *const TypeInterner, id: TypeId) TypeId {
        var cur = id;
        while (self.unwrapOptionOnce(cur)) |inner| {
            cur = inner;
        }
        return cur;
    }
};

test "TypeInterner 预置槽位、去重、replaceIdeal 与内建文档表" {
    const gpa = std.testing.allocator;
    var types = try TypeInterner.init(gpa, .{});
    defer types.deinit();

    try std.testing.expectEqual(TypeInterner.int64_ty, TypeInterner.prim(.int64));
    try std.testing.expectEqual(TypeInterner.cstring_ty, TypeInterner.prim(.cstring));

    const opt_def: DefId = .{ .pkg = .fromIndex(0), .pkg_gen = 1, .idx = 10 };
    types.known.option_enum = opt_def;

    const opt_ideal = try types.internOption(TypeInterner.ideal_int_ty);
    try std.testing.expect(types.hasIdeal(opt_ideal));
    try std.testing.expectEqual(@as(u32, 1), types.optionDepth(opt_ideal));
    try std.testing.expectEqual(TypeInterner.ideal_int_ty, types.unboxOption(opt_ideal));

    const opt_i64 = try types.replaceIdeal(opt_ideal);
    try std.testing.expect(!types.hasIdeal(opt_i64));
    try std.testing.expectEqual(TypeInterner.int64_ty, types.unwrapOptionOnce(opt_i64).?);

    const doc_id = InternedId.fromIndex(42);
    types.setPrimDoc(.int64, doc_id);
    try std.testing.expectEqual(doc_id, types.builtinDocOf(TypeInterner.int64_ty).?);

    try types.resetKeepingBuiltins();
    try std.testing.expectEqual(@as(u32, 22), types.count());
    try std.testing.expectEqual(doc_id, types.builtinDocOf(TypeInterner.int64_ty).?);
}
