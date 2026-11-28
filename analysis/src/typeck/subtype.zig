// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 子类型判定（`isSubtype`）、`Option` 自动装箱、`CType` 约束判定与泛型接口提升/反推（`promote` / `downgrade`）。

const std = @import("std");
const common = @import("common");
const ids = @import("../ids.zig");
const file_state_mod = @import("../db/FileState.zig");
const db_mod = @import("../db/Database.zig");
const type_interner_mod = @import("../interner/TypeInterner.zig");
const access_mod = @import("../resolve/access.zig");

const Database = db_mod.Database;
const DefId = ids.DefId;
const PlatformError = file_state_mod.PlatformError;
const PrimKind = ids.PrimKind;
const TypeId = ids.TypeId;
const TypeInterner = type_interner_mod.TypeInterner;
const TypeListId = ids.TypeListId;
const TypeParamRef = ids.TypeParamRef;

/// 子类型判定控制选项（与 `cangjie_compiler` 的 `IsSubtype` 开关一致）。
pub const SubtypeOptions = struct {
    /// 是否允许值类型到接口的隐式装箱及值类型到 `Any` 的隐式装箱（函数类型子类型、元组子类型与类型相等判定时置 `false`）。
    implicit_boxed: bool = true,
    /// 是否允许 `T <: Option<T>` 多层自动装箱（生效须同时满足 `implicit_boxed == true`；`where` 约束校验、泛型类型参数相等判定与显式 lambda 参数检查时置 `false`）。
    allow_option_box: bool = true,
};

/// 判定给定类型是否为类或接口（`class` / `interface` / `ClassThisTy`），不需要值装箱即可作为 `Any` 子类型。
pub fn isClassLike(db: *Database, ty: TypeId) PlatformError!bool {
    return switch (db.types.get(ty)) {
        .class_this => true,
        .nominal => |n| blk: {
            const def = db.getDef(n.def) catch break :blk false;
            break :blk def.kind == .class_ or def.kind == .interface_;
        },
        else => false,
    };
}

/// 判定 `ty` 是否满足仓颉 `CType` 约束（数值类型、`Bool`、`Unit`、`CString`、`CPointer<T>`、`CFunc` 及 `@C` 结构体）。
pub fn isCType(db: *Database, ty: TypeId) PlatformError!bool {
    return switch (db.types.get(ty)) {
        .prim => |p| p.isNumeric() or p == .bool_ or p == .unit or p == .cstring,
        .cpointer => true,
        .func => |f| f.is_cfunc,
        .varray => |v| try isCType(db, v.elem),
        .nominal => |n| blk: {
            if (db.types.known.ctype_iface) |ct| {
                if (DefId.eql(n.def, ct)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// 判定 `sub <: sup` 是否在 `file` 的可见扩展上下文下成立。
pub fn isSubtype(
    db: *Database,
    file: common.FileId,
    sub: TypeId,
    sup: TypeId,
    opts: SubtypeOptions,
) PlatformError!bool {
    return isSubtypeDepth(db, file, sub, sup, opts, 0);
}

/// 带递归深度保护的子类型判定实现。
fn isSubtypeDepth(
    db: *Database,
    file: common.FileId,
    sub: TypeId,
    sup: TypeId,
    opts: SubtypeOptions,
    depth: u32,
) PlatformError!bool {
    if (depth > 48) return false;
    const sub_data = db.types.get(sub);
    const sup_data = db.types.get(sup);

    // 1. 错误类型返回 false，防止重载决议把错误实参匹配到全部候选；QuestTy 对任意类型返回 true
    if (sub_data == .err or sup_data == .err) return false;
    if (sub_data == .quest or sup_data == .quest) return true;
    if (sub == sup) return true;

    // 2. 底类型 Nothing <: 任意类型
    if (sub == TypeInterner.nothing_ty) return true;

    // 3. 顶层接口 Any 与 CType
    if (sup_data == .nominal) {
        if (db.types.known.any_iface) |any_def| {
            if (DefId.eql(sup_data.nominal.def, any_def)) {
                return opts.implicit_boxed or try isClassLike(db, sub);
            }
        }
        if (db.types.known.ctype_iface) |ctype_def| {
            if (DefId.eql(sup_data.nominal.def, ctype_def)) {
                return try isCType(db, sub);
            }
        }
        if (db.types.known.object_class) |obj_def| {
            if (DefId.eql(sup_data.nominal.def, obj_def)) {
                if (sub_data == .class_this) return true;
                if (sub_data == .nominal) {
                    const sub_def = db.getDef(sub_data.nominal.def) catch return false;
                    if (sub_def.kind == .class_) return true;
                }
            }
        }
    }

    // 4. Option<T> 多层自动装箱：仅在 implicit_boxed && allow_option_box 且目标嵌套层数严格更大时生效
    if (opts.implicit_boxed and opts.allow_option_box) {
        const sup_depth = db.types.optionDepth(sup);
        if (sup_depth > 0 and db.types.optionDepth(sub) < sup_depth) {
            if (db.types.unwrapOptionOnce(sup)) |inner| {
                return isSubtypeDepth(db, file, sub, inner, opts, depth + 1);
            }
        }
    }

    // 5. IdealInt / IdealFloat 子类型规则
    if (sub == TypeInterner.ideal_int_ty) {
        if (sup_data == .prim and sup_data.prim.isInteger()) return true;
        if (sup_data == .nominal and opts.implicit_boxed) {
            const int_candidates = [_]TypeId{
                TypeInterner.int64_ty,
                TypeInterner.uint64_ty,
                TypeInterner.int32_ty,
                TypeInterner.uint32_ty,
                TypeInterner.int16_ty,
                TypeInterner.uint16_ty,
                TypeInterner.int8_ty,
                TypeInterner.uint8_ty,
            };
            for (int_candidates) |cand| {
                if (try isSubtypeDepth(db, file, cand, sup, opts, depth + 1)) return true;
            }
        }
        return false;
    }
    if (sub == TypeInterner.ideal_float_ty) {
        if (sup_data == .prim and sup_data.prim.isFloat()) return true;
        if (sup_data == .nominal and opts.implicit_boxed) {
            const float_candidates = [_]TypeId{
                TypeInterner.float64_ty,
                TypeInterner.float32_ty,
                TypeInterner.float16_ty,
            };
            for (float_candidates) |cand| {
                if (try isSubtypeDepth(db, file, cand, sup, opts, depth + 1)) return true;
            }
        }
        return false;
    }

    // 6. ClassThisTy 退化为其所属名义类型（保留泛型形参列表）再继续检查
    if (sub_data == .class_this) {
        if (sup_data == .class_this and DefId.eql(sub_data.class_this, sup_data.class_this)) return true;
        const targs_id: TypeListId = if (db.nominalHeaderOf(sub_data.class_this)) |nh| blk: {
            if (nh.type_params.len == 0) break :blk TypeListId.empty;
            const buf = try db.gpa.alloc(TypeId, nh.type_params.len);
            defer db.gpa.free(buf);
            for (nh.type_params, 0..) |tp, i| buf[i] = try db.types.intern(.{ .type_param = tp });
            break :blk try db.types.internList(buf);
        } else |_| TypeListId.empty;
        const as_nom = try db.types.intern(.{ .nominal = .{ .def = sub_data.class_this, .args = targs_id } });
        return isSubtypeDepth(db, file, as_nom, sup, opts, depth + 1);
    }

    // 7. 复合结构子类型判定（Tuple 协变、Func 逆变/协变、VArray 与 CPointer 严格不变）
    switch (sub_data) {
        .tuple => |sub_list| {
            if (sup_data != .tuple) return false;
            const s_elems = db.types.getList(sub_list);
            const t_elems = db.types.getList(sup_data.tuple);
            if (s_elems.len != t_elems.len) return false;
            const no_box: SubtypeOptions = .{ .implicit_boxed = false, .allow_option_box = false };
            for (s_elems, t_elems) |se, te| {
                if (!try isSubtypeDepth(db, file, se, te, no_box, depth + 1)) return false;
            }
            return true;
        },
        .func => |sf| {
            if (sup_data != .func) return false;
            const tf = sup_data.func;
            if (sf.is_cfunc != tf.is_cfunc) return false;
            const s_params = db.types.getList(sf.params);
            const t_params = db.types.getList(tf.params);
            if (s_params.len != t_params.len) return false;
            const no_box: SubtypeOptions = .{ .implicit_boxed = false, .allow_option_box = false };
            for (s_params, t_params) |sp, tp| {
                if (!try isSubtypeDepth(db, file, tp, sp, no_box, depth + 1)) return false;
            }
            return isSubtypeDepth(db, file, sf.ret, tf.ret, no_box, depth + 1);
        },
        .varray => |sv| {
            if (sup_data != .varray) return false;
            return sv.len == sup_data.varray.len and try isTypeEqual(db, file, sv.elem, sup_data.varray.elem);
        },
        .cpointer => |sc| {
            if (sup_data != .cpointer) return false;
            return isTypeEqual(db, file, sc, sup_data.cpointer);
        },
        .type_param => |tp_ref| {
            // 沿泛型形参上界传递检查
            const bounds = try getTypeParamUpperBounds(db, db.gpa, tp_ref);
            defer db.gpa.free(bounds);
            for (bounds) |ub| {
                if (try isSubtypeDepth(db, file, ub, sup, opts, depth + 1)) return true;
            }
            return false;
        },
        .nominal, .prim => {},
        else => return false,
    }

    // 8. 名义类型不变性检查、继承链与可见 extend 实现接口传递闭包
    if (sup_data != .nominal) return false;
    const sup_nom = sup_data.nominal;

    if (sub_data == .nominal) {
        const sub_nom = sub_data.nominal;
        if (DefId.eql(sub_nom.def, sup_nom.def)) {
            const s_args = db.types.getList(sub_nom.args);
            const t_args = db.types.getList(sup_nom.args);
            if (s_args.len != t_args.len) return false;
            for (s_args, t_args) |sa, ta| {
                if (!try isTypeEqual(db, file, sa, ta)) return false;
            }
            return true;
        }
    }

    // 沿直接父类型与可见 extend 实现接口展开
    var supers = try collectDirectSupertypes(db, db.gpa, file, sub);
    defer supers.deinit(db.gpa);
    for (supers.items) |direct_sup| {
        if (try isSubtypeDepth(db, file, direct_sup, sup, opts, depth + 1)) return true;
    }
    return false;
}

/// 严格类型相等判定（关闭值装箱与 `Option` 装箱的双向 `isSubtype`）。
pub fn isTypeEqual(db: *Database, file: common.FileId, a: TypeId, b: TypeId) PlatformError!bool {
    if (a == b) return a != TypeInterner.err_ty;
    const no_box: SubtypeOptions = .{ .implicit_boxed = false, .allow_option_box = false };
    return (try isSubtype(db, file, a, b, no_box)) and (try isSubtype(db, file, b, a, no_box));
}

/// 收集类型 `ty` 在当前文件 `file` 视角下的所有直接父类型（含名义继承头与可见 `extend` 实现的接口，已执行泛型参数替换）。
/// 返回列表由调用者传入的 `alloc` 分配，结束后须由调用者调用 `deinit(alloc)` 释放。
pub fn collectDirectSupertypes(
    db: *Database,
    alloc: std.mem.Allocator,
    file: common.FileId,
    ty: TypeId,
) PlatformError!std.ArrayListUnmanaged(TypeId) {
    var out: std.ArrayListUnmanaged(TypeId) = .empty;
    errdefer out.deinit(alloc);

    const resolve_data = db.resolve(file) catch null;
    switch (db.types.get(ty)) {
        .nominal => |nom| {
            if (db.nominalHeaderOf(nom.def)) |nh| {
                const args = db.types.getList(nom.args);
                for (nh.supertypes) |st| {
                    const inst = try substituteNominalParams(db, st, nh.type_params, args);
                    try out.append(alloc, inst);
                }
            } else |_| {}

            if (resolve_data) |rd| {
                const exts = rd.visible_extends.getForNominal(nom.def);
                for (exts) |ext_def| {
                    const ext_pkg = db.packageState(ext_def.pkg) catch continue;
                    const rel = db.pkg_interner.relation(rd.pkg_id, ext_def.pkg);
                    for (ext_pkg.extends) |ext| {
                        if (!DefId.eql(ext.def, ext_def)) continue;
                        if (rel != .same_package) {
                            if (!ext.is_exported or !access_mod.isVisibleInRelation(ext.export_vis, rel)) break;
                        }
                        const matched = try matchExtendTarget(db, alloc, file, ty, ext);
                        if (matched) |m_args| {
                            defer alloc.free(m_args);
                            for (ext.implemented_interfaces) |iface| {
                                const inst = try substituteNominalParams(db, iface, ext.type_params, m_args);
                                try out.append(alloc, inst);
                            }
                        }
                        break;
                    }
                }
            }
        },
        .prim => |p| {
            if (resolve_data) |rd| {
                const exts = rd.visible_extends.getForPrim(p);
                for (exts) |ext_def| {
                    const ext_pkg = db.packageState(ext_def.pkg) catch continue;
                    const rel = db.pkg_interner.relation(rd.pkg_id, ext_def.pkg);
                    for (ext_pkg.extends) |ext| {
                        if (!DefId.eql(ext.def, ext_def)) continue;
                        if (rel != .same_package) {
                            if (!ext.is_exported or !access_mod.isVisibleInRelation(ext.export_vis, rel)) break;
                        }
                        for (ext.implemented_interfaces) |iface| {
                            try out.append(alloc, iface);
                        }
                        break;
                    }
                }
            }
        },
        else => {},
    }
    return out;
}

/// 收集类型 `ty` 在 `file` 视角下的全部传递父类型闭包（包含自身，供 `computeJoin` 求交集使用）。
/// 返回切片由调用者传入的 `alloc` 分配，结束后须由调用者通过 `alloc.free` 释放。
pub fn collectAllSupertypes(
    db: *Database,
    alloc: std.mem.Allocator,
    file: common.FileId,
    ty: TypeId,
) PlatformError![]TypeId {
    var visited: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
    defer visited.deinit(alloc);
    var queue: std.ArrayListUnmanaged(TypeId) = .empty;
    errdefer queue.deinit(alloc);

    try visited.put(alloc, ty, {});
    try queue.append(alloc, ty);

    var cursor: usize = 0;
    while (cursor < queue.items.len and queue.items.len < 256) : (cursor += 1) {
        const cur = queue.items[cursor];
        var directs = try collectDirectSupertypes(db, alloc, file, cur);
        defer directs.deinit(alloc);
        for (directs.items) |d| {
            if (!visited.contains(d)) {
                try visited.put(alloc, d, {});
                try queue.append(alloc, d);
            }
        }
    }
    return queue.toOwnedSlice(alloc);
}

/// 泛型提升（`Promotion::Promote`）：将具体类型 `src` 沿类继承、接口继承与当前文件可见 `extend` 提升为目标泛型声明 `target_def` 的具体化类型列表。
/// 返回切片由调用者传入的 `alloc` 分配，结束后须由调用者释放。
pub fn promote(
    db: *Database,
    alloc: std.mem.Allocator,
    file: common.FileId,
    src: TypeId,
    target_def: DefId,
) PlatformError![]TypeId {
    const all_supers = try collectAllSupertypes(db, alloc, file, src);
    defer alloc.free(all_supers);

    var out: std.ArrayListUnmanaged(TypeId) = .empty;
    errdefer out.deinit(alloc);
    for (all_supers) |s| {
        if (db.types.get(s) == .nominal and DefId.eql(db.types.get(s).nominal.def, target_def)) {
            try out.append(alloc, s);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// 泛型反推（`Promotion::Downgrade`）：给定目标接口 `target_iface`（如 `Iterable<Int64>` 或 `Collection<String>`），
/// 反推具体构造声明 `ctor_def`（如 `Array`、`Range`、`Future` 或某 `enum`）应具体化的类型。
pub fn downgrade(
    db: *Database,
    file: common.FileId,
    ctor_def: DefId,
    target_iface: TypeId,
) PlatformError!?TypeId {
    const target_data = db.types.get(target_iface);
    if (target_data != .nominal) return null;
    if (DefId.eql(ctor_def, target_data.nominal.def)) return target_iface;

    const nh = db.nominalHeaderOf(ctor_def) catch return null;
    const tp_count = nh.type_params.len;
    if (tp_count == 0) {
        const concrete = try db.types.intern(.{ .nominal = .{ .def = ctor_def, .args = .empty } });
        return if (try isSubtype(db, file, concrete, target_iface, .{})) concrete else null;
    }

    // 构造 `Ctor<P0, P1, ...>` 并提升至目标接口，再从目标接口实参反解 `P0, P1, ...`
    const param_tys = try db.gpa.alloc(TypeId, tp_count);
    defer db.gpa.free(param_tys);
    for (nh.type_params, 0..) |tp, i| {
        param_tys[i] = try db.types.intern(.{ .type_param = tp });
    }
    const self_args = try db.types.internList(param_tys);
    const self_ty = try db.types.intern(.{ .nominal = .{ .def = ctor_def, .args = self_args } });

    const promoted = try promote(db, db.gpa, file, self_ty, target_data.nominal.def);
    defer db.gpa.free(promoted);

    const resolved = try db.gpa.alloc(?TypeId, tp_count);
    defer db.gpa.free(resolved);
    for (promoted) |p_ty| {
        @memset(resolved, null);
        if (try unifyPatternArgs(db, p_ty, target_iface, nh.type_params, resolved)) {
            var all_bound = true;
            const final_args = try db.gpa.alloc(TypeId, tp_count);
            defer db.gpa.free(final_args);
            for (resolved, 0..) |r, i| {
                if (r) |val| {
                    final_args[i] = val;
                } else {
                    all_bound = false;
                    break;
                }
            }
            if (all_bound) {
                const list = try db.types.internList(final_args);
                return try db.types.intern(.{ .nominal = .{ .def = ctor_def, .args = list } });
            }
        }
    }
    return null;
}

/// 将类型表达式 `ty` 中出现的 `type_params[i]` 替换为对应的 `args[i]`。
pub fn substituteNominalParams(
    db: *Database,
    ty: TypeId,
    type_params: []const TypeParamRef,
    args: []const TypeId,
) PlatformError!TypeId {
    if (type_params.len == 0 or args.len == 0) return ty;
    return switch (db.types.get(ty)) {
        .type_param => |tp| blk: {
            for (type_params, 0..) |param, i| {
                if (i < args.len and TypeParamRef.eql(tp, param)) break :blk args[i];
            }
            break :blk ty;
        },
        .nominal => |n| blk: {
            const old_args = db.types.getList(n.args);
            if (old_args.len == 0) break :blk ty;
            const buf = try db.gpa.alloc(TypeId, old_args.len);
            defer db.gpa.free(buf);
            var changed = false;
            for (old_args, 0..) |a, i| {
                buf[i] = try substituteNominalParams(db, a, type_params, args);
                if (buf[i] != a) changed = true;
            }
            if (!changed) break :blk ty;
            const new_list = try db.types.internList(buf);
            break :blk try db.types.intern(.{ .nominal = .{ .def = n.def, .args = new_list } });
        },
        .cpointer => |c| blk: {
            const nc = try substituteNominalParams(db, c, type_params, args);
            break :blk if (nc == c) ty else try db.types.intern(.{ .cpointer = nc });
        },
        .varray => |v| blk: {
            const ne = try substituteNominalParams(db, v.elem, type_params, args);
            break :blk if (ne == v.elem) ty else try db.types.intern(.{ .varray = .{ .elem = ne, .len = v.len } });
        },
        .tuple => |t| blk: {
            const old_elems = db.types.getList(t);
            const buf = try db.gpa.alloc(TypeId, old_elems.len);
            defer db.gpa.free(buf);
            var changed = false;
            for (old_elems, 0..) |e, i| {
                buf[i] = try substituteNominalParams(db, e, type_params, args);
                if (buf[i] != e) changed = true;
            }
            if (!changed) break :blk ty;
            break :blk try db.types.intern(.{ .tuple = try db.types.internList(buf) });
        },
        .func => |f| blk: {
            const old_params = db.types.getList(f.params);
            const buf = try db.gpa.alloc(TypeId, old_params.len);
            defer db.gpa.free(buf);
            var changed = false;
            for (old_params, 0..) |p, i| {
                buf[i] = try substituteNominalParams(db, p, type_params, args);
                if (buf[i] != p) changed = true;
            }
            const new_ret = try substituteNominalParams(db, f.ret, type_params, args);
            if (!changed and new_ret == f.ret) break :blk ty;
            break :blk try db.types.intern(.{ .func = .{
                .params = try db.types.internList(buf),
                .ret = new_ret,
                .is_cfunc = f.is_cfunc,
            } });
        },
        else => ty,
    };
}

/// 匹配具体类型 `actual` 与 `extend` 目标模板并校验扩展 `where` 约束（`allow_option_box = false`）。
/// 匹配成功时返回绑定到 `ext.type_params` 的类型切片（由 `alloc` 分配，调用者释放）；不匹配返回 `null`。
pub fn matchExtendTarget(
    db: *Database,
    alloc: std.mem.Allocator,
    file: common.FileId,
    actual: TypeId,
    ext: @import("../db/PackageState.zig").ExtendEntry,
) PlatformError!?[]TypeId {
    const tp_count = ext.type_params.len;
    const resolved = try alloc.alloc(?TypeId, tp_count);
    defer alloc.free(resolved);
    @memset(resolved, null);

    if (!try unifyPatternArgs(db, ext.target_ty, actual, ext.type_params, resolved)) {
        return null;
    }

    const args = try alloc.alloc(TypeId, tp_count);
    errdefer alloc.free(args);
    for (resolved, 0..) |r, i| {
        args[i] = r orelse {
            alloc.free(args);
            return null;
        };
    }

    // 校验 extend 自身 where 约束（禁用 Option 自动装箱）
    const no_opt_box: SubtypeOptions = .{ .implicit_boxed = true, .allow_option_box = false };
    for (ext.where_bounds) |wb| {
        const subj = try substituteNominalParams(db, wb.subject, ext.type_params, args);
        for (wb.upper_bounds) |ub| {
            const inst_ub = try substituteNominalParams(db, ub, ext.type_params, args);
            if (!try isSubtype(db, file, subj, inst_ub, no_opt_box)) {
                alloc.free(args);
                return null;
            }
        }
    }
    return args;
}

/// 结构化模式匹配，将模板类型 `pattern` 中的 `type_params` 绑定到具体类型 `actual`。
fn unifyPatternArgs(
    db: *Database,
    pattern: TypeId,
    actual: TypeId,
    type_params: []const TypeParamRef,
    resolved: []?TypeId,
) PlatformError!bool {
    const p_data = db.types.get(pattern);
    const a_data = db.types.get(actual);
    if (p_data == .type_param) {
        for (type_params, 0..) |tp, i| {
            if (TypeParamRef.eql(p_data.type_param, tp)) {
                if (resolved[i]) |prev| {
                    return prev == actual;
                }
                resolved[i] = actual;
                return true;
            }
        }
        return pattern == actual;
    }
    if (pattern == actual) return true;
    if (std.meta.activeTag(p_data) != std.meta.activeTag(a_data)) return false;

    return switch (p_data) {
        .nominal => |pn| blk: {
            const an = a_data.nominal;
            if (!DefId.eql(pn.def, an.def)) break :blk false;
            const p_args = db.types.getList(pn.args);
            const a_args = db.types.getList(an.args);
            if (p_args.len != a_args.len) break :blk false;
            for (p_args, a_args) |pa, aa| {
                if (!try unifyPatternArgs(db, pa, aa, type_params, resolved)) break :blk false;
            }
            break :blk true;
        },
        .cpointer => |pc| unifyPatternArgs(db, pc, a_data.cpointer, type_params, resolved),
        .varray => |pv| pv.len == a_data.varray.len and try unifyPatternArgs(db, pv.elem, a_data.varray.elem, type_params, resolved),
        .tuple => |pt| blk: {
            const pe = db.types.getList(pt);
            const ae = db.types.getList(a_data.tuple);
            if (pe.len != ae.len) break :blk false;
            for (pe, ae) |p_item, a_item| {
                if (!try unifyPatternArgs(db, p_item, a_item, type_params, resolved)) break :blk false;
            }
            break :blk true;
        },
        .func => |pf| blk: {
            const af = a_data.func;
            if (pf.is_cfunc != af.is_cfunc) break :blk false;
            const pp = db.types.getList(pf.params);
            const ap = db.types.getList(af.params);
            if (pp.len != ap.len) break :blk false;
            for (pp, ap) |p_item, a_item| {
                if (!try unifyPatternArgs(db, p_item, a_item, type_params, resolved)) break :blk false;
            }
            break :blk try unifyPatternArgs(db, pf.ret, af.ret, type_params, resolved);
        },
        else => false,
    };
}

/// 查询泛型形参在所属声明（名义类型、可调用声明或 `extend`）全部 `where` 子句中的显式上界合并列表。
/// 返回切片由调用者传入的 `alloc` 分配，结束后须由调用者通过 `alloc.free` 释放。
pub fn getTypeParamUpperBounds(
    db: *Database,
    alloc: std.mem.Allocator,
    tp: TypeParamRef,
) PlatformError![]TypeId {
    const tp_ty = try db.types.intern(.{ .type_param = tp });
    var out: std.ArrayListUnmanaged(TypeId) = .empty;
    errdefer out.deinit(alloc);

    switch (tp.owner) {
        .def => |owner_def| {
            if (db.nominalHeaderOf(owner_def)) |nh| {
                for (nh.where_bounds) |wb| {
                    if (wb.subject == tp_ty) try out.appendSlice(alloc, wb.upper_bounds);
                }
            } else |_| {}
            if (db.callableHeaderSig(.{ .def = owner_def })) |sig| {
                for (sig.where_bounds) |wb| {
                    if (wb.subject == tp_ty) try out.appendSlice(alloc, wb.upper_bounds);
                }
            } else |_| {}
            if (db.packageState(owner_def.pkg)) |ps| {
                for (ps.extends) |ext| {
                    if (!DefId.eql(ext.def, owner_def)) continue;
                    for (ext.where_bounds) |wb| {
                        if (wb.subject == tp_ty) try out.appendSlice(alloc, wb.upper_bounds);
                    }
                    break;
                }
            } else |_| {}
        },
        .local => |local_id| {
            if (db.callableHeaderSig(.{ .local = local_id })) |sig| {
                for (sig.where_bounds) |wb| {
                    if (wb.subject == tp_ty) try out.appendSlice(alloc, wb.upper_bounds);
                }
            } else |_| {}
        },
    }
    return out.toOwnedSlice(alloc);
}
