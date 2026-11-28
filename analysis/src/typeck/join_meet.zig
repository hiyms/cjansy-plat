// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 最小公共父类型（LUB / `computeJoin`）与最大公共子类型（GLB / `computeMeet`）求解算法。

const std = @import("std");
const common = @import("common");
const ids = @import("../ids.zig");
const file_state_mod = @import("../db/FileState.zig");
const db_mod = @import("../db/Database.zig");
const type_interner_mod = @import("../interner/TypeInterner.zig");
const subtype_mod = @import("subtype.zig");
const access_mod = @import("../resolve/access.zig");

const Database = db_mod.Database;
const PlatformError = file_state_mod.PlatformError;
const TypeId = ids.TypeId;
const TypeInterner = type_interner_mod.TypeInterner;

/// `computeJoin` 与 `computeMeet` 的求解结果。
pub const JoinMeetResult = union(enum) {
    ok: TypeId,
    /// 非空公共超类型交集中存在多个互不统属的极小公共接口，或 `computeMeet` 无可见公共子类型。
    ambiguous_or_none: void,
    /// 输入包含 `TypeInterner.err_ty` 或为空切片。
    has_error: void,
};

/// 在 `file` 的可见类型与 `VisibleExtendIndex` 视角下计算 `types` 的最小公共父类型（LUB）。
///
/// 规则与 `cangjie_compiler` 的 `JoinAndMeet::BatchJoin` 保持一致：
/// 1. 输入为空或含 `err_ty` 返回 `.has_error`；
/// 2. 跳过 `Nothing`（全为 `Nothing` 时返回 `Nothing`）；
/// 3. 集合内存在涵盖其余所有类型的上界（含 `T <: Option<T>`、`Sub <: Base`、`IdealInt <: Int32`）直接返回；
/// 4. 全为同元函数类型时参数逐位计算 `meet`、返回计算 `join`（结构不兼容返回 `Any`）；
///    全为同维元组时逐位计算 `join`（结构不兼容返回 `Any`）；
/// 5. 计算全部可见公共父类型交集：交集为空返回 `Any`；交集非空时寻找唯一最小元，存在多个互不统属极小接口时返回 `.ambiguous_or_none`。
pub fn computeJoin(
    db: *Database,
    file: common.FileId,
    types: []const TypeId,
) PlatformError!JoinMeetResult {
    if (types.len == 0) return .has_error;
    for (types) |t| {
        if (db.types.hasErr(t)) return .has_error;
    }

    var real_tys: std.ArrayListUnmanaged(TypeId) = .empty;
    defer real_tys.deinit(db.gpa);
    for (types) |t| {
        if (t == TypeInterner.nothing_ty) continue;
        if (!containsTy(real_tys.items, t)) {
            try real_tys.append(db.gpa, t);
        }
    }

    if (real_tys.items.len == 0) return .{ .ok = TypeInterner.nothing_ty };
    if (real_tys.items.len == 1) return .{ .ok = real_tys.items[0] };

    // 1. 集合内直接存在涵盖所有元素的上界
    if (try findGreatest(db, file, real_tys.items)) |sup| {
        return .{ .ok = sup };
    }

    const any_ty = try db.types.internAny();

    // 2. 全为函数类型：参数逆变求 meet，返回协变求 join
    if (allFuncsSameArity(db, real_tys.items)) |arity| {
        const is_cfunc = db.types.get(real_tys.items[0]).func.is_cfunc;
        const params_out = try db.gpa.alloc(TypeId, arity);
        defer db.gpa.free(params_out);
        const col = try db.gpa.alloc(TypeId, real_tys.items.len);
        defer db.gpa.free(col);

        for (0..arity) |p_idx| {
            for (real_tys.items, 0..) |ft, i| {
                col[i] = db.types.getList(db.types.get(ft).func.params)[p_idx];
            }
            switch (try computeMeet(db, file, col)) {
                .ok => |m| params_out[p_idx] = m,
                else => return .{ .ok = any_ty },
            }
        }
        for (real_tys.items, 0..) |ft, i| {
            col[i] = db.types.get(ft).func.ret;
        }
        const ret_ty = switch (try computeJoin(db, file, col)) {
            .ok => |j| j,
            else => return .{ .ok = any_ty },
        };
        const cand = try db.types.intern(.{ .func = .{
            .params = try db.types.internList(params_out),
            .ret = ret_ty,
            .is_cfunc = is_cfunc,
        } });
        for (real_tys.items) |ft| {
            if (!try subtype_mod.isSubtype(db, file, ft, cand, .{ .implicit_boxed = false, .allow_option_box = false })) {
                return .{ .ok = any_ty };
            }
        }
        return .{ .ok = cand };
    }

    // 3. 全为同维元组类型：元素逐位协变求 join
    if (allTuplesSameArity(db, real_tys.items)) |arity| {
        const elems_out = try db.gpa.alloc(TypeId, arity);
        defer db.gpa.free(elems_out);
        const col = try db.gpa.alloc(TypeId, real_tys.items.len);
        defer db.gpa.free(col);

        for (0..arity) |e_idx| {
            for (real_tys.items, 0..) |tt, i| {
                col[i] = db.types.getList(db.types.get(tt).tuple)[e_idx];
            }
            switch (try computeJoin(db, file, col)) {
                .ok => |j| elems_out[e_idx] = j,
                else => return .{ .ok = any_ty },
            }
        }
        const cand = try db.types.intern(.{ .tuple = try db.types.internList(elems_out) });
        for (real_tys.items) |tt| {
            if (!try subtype_mod.isSubtype(db, file, tt, cand, .{ .implicit_boxed = false, .allow_option_box = false })) {
                return .{ .ok = any_ty };
            }
        }
        return .{ .ok = cand };
    }

    // 4. 计算公共超类型交集（含可见 extend 实现接口），按当前文件可见性过滤
    const first_supers = try subtype_mod.collectAllSupertypes(db, db.gpa, file, real_tys.items[0]);
    defer db.gpa.free(first_supers);

    var common_supers: std.ArrayListUnmanaged(TypeId) = .empty;
    defer common_supers.deinit(db.gpa);

    const file_pkg = try db.packageOfFile(file);
    const file_mod = db.pkg_interner.getPackage(file_pkg).module_id;
    const access_ctx: ids.AccessContext = .{ .module_id = file_mod, .pkg_id = file_pkg, .file_id = file };

    for (first_supers) |cand| {
        if (cand == any_ty) continue;
        // 过滤当前文件不可见的父类型
        if (db.types.get(cand) == .nominal) {
            if (!try access_mod.checkAccess(db, db.types.get(cand).nominal.def, null, access_ctx)) continue;
        }
        var ok_all = true;
        for (real_tys.items[1..]) |other| {
            if (!try subtype_mod.isSubtype(db, file, other, cand, .{})) {
                ok_all = false;
                break;
            }
        }
        if (ok_all) try common_supers.append(db.gpa, cand);
    }

    if (common_supers.items.len == 0) return .{ .ok = any_ty };
    if (try findSmallest(db, file, common_supers.items)) |least| {
        return .{ .ok = least };
    }
    return .ambiguous_or_none;
}

/// 计算 `types` 的最大公共子类型（GLB，用于函数参数逆变与泛型上界合并）。
pub fn computeMeet(
    db: *Database,
    file: common.FileId,
    types: []const TypeId,
) PlatformError!JoinMeetResult {
    if (types.len == 0) return .has_error;
    for (types) |t| {
        if (db.types.hasErr(t)) return .has_error;
    }

    var real_tys: std.ArrayListUnmanaged(TypeId) = .empty;
    defer real_tys.deinit(db.gpa);
    for (types) |t| {
        if (!containsTy(real_tys.items, t)) {
            try real_tys.append(db.gpa, t);
        }
    }
    if (real_tys.items.len == 1) return .{ .ok = real_tys.items[0] };

    // 1. 集合内存在涵盖所有元素的最小子类型（例如 {Base, Sub} -> Sub、{T, Any} -> T、{T, Nothing} -> Nothing）
    if (try findSmallest(db, file, real_tys.items)) |sub| {
        return .{ .ok = sub };
    }

    // 2. 全为同元函数类型：参数逆变求 join，返回协变求 meet
    if (allFuncsSameArity(db, real_tys.items)) |arity| {
        const is_cfunc = db.types.get(real_tys.items[0]).func.is_cfunc;
        const params_out = try db.gpa.alloc(TypeId, arity);
        defer db.gpa.free(params_out);
        const col = try db.gpa.alloc(TypeId, real_tys.items.len);
        defer db.gpa.free(col);

        for (0..arity) |p_idx| {
            for (real_tys.items, 0..) |ft, i| {
                col[i] = db.types.getList(db.types.get(ft).func.params)[p_idx];
            }
            switch (try computeJoin(db, file, col)) {
                .ok => |j| params_out[p_idx] = j,
                else => return .ambiguous_or_none,
            }
        }
        for (real_tys.items, 0..) |ft, i| {
            col[i] = db.types.get(ft).func.ret;
        }
        const ret_ty = switch (try computeMeet(db, file, col)) {
            .ok => |m| m,
            else => return .ambiguous_or_none,
        };
        const cand = try db.types.intern(.{ .func = .{
            .params = try db.types.internList(params_out),
            .ret = ret_ty,
            .is_cfunc = is_cfunc,
        } });
        return .{ .ok = cand };
    }

    // 3. 全为同维元组类型：元素逐位协变求 meet
    if (allTuplesSameArity(db, real_tys.items)) |arity| {
        const elems_out = try db.gpa.alloc(TypeId, arity);
        defer db.gpa.free(elems_out);
        const col = try db.gpa.alloc(TypeId, real_tys.items.len);
        defer db.gpa.free(col);

        for (0..arity) |e_idx| {
            for (real_tys.items, 0..) |tt, i| {
                col[i] = db.types.getList(db.types.get(tt).tuple)[e_idx];
            }
            switch (try computeMeet(db, file, col)) {
                .ok => |m| elems_out[e_idx] = m,
                else => return .ambiguous_or_none,
            }
        }
        return .{ .ok = try db.types.intern(.{ .tuple = try db.types.internList(elems_out) }) };
    }

    return .ambiguous_or_none;
}

/// 判定切片中是否已包含 `target`。
fn containsTy(slice: []const TypeId, target: TypeId) bool {
    for (slice) |item| {
        if (item == target) return true;
    }
    return false;
}

/// 在集合中寻找唯一最小元 `L`（满足对集合中全部元素 `C` 均有 `L <: C`）。
fn findSmallest(db: *Database, file: common.FileId, list: []const TypeId) PlatformError!?TypeId {
    if (list.len == 0) return null;
    var cand = list[0];
    for (list[1..]) |t| {
        if (try subtype_mod.isSubtype(db, file, t, cand, .{})) {
            cand = t;
        }
    }
    for (list) |t| {
        if (!try subtype_mod.isSubtype(db, file, cand, t, .{})) return null;
    }
    return cand;
}

/// 在集合中寻找唯一最大元 `U`（满足对集合中全部元素 `C` 均有 `C <: U`）。
fn findGreatest(db: *Database, file: common.FileId, list: []const TypeId) PlatformError!?TypeId {
    if (list.len == 0) return null;
    var cand = list[0];
    for (list[1..]) |t| {
        if (try subtype_mod.isSubtype(db, file, cand, t, .{})) {
            cand = t;
        }
    }
    for (list) |t| {
        if (!try subtype_mod.isSubtype(db, file, t, cand, .{})) return null;
    }
    return cand;
}

/// 检查集合中所有类型是否均为相同 `is_cfunc` 且参数个数一致的函数类型；若是则返回参数个数。
fn allFuncsSameArity(db: *const Database, list: []const TypeId) ?usize {
    const first = db.types.get(list[0]);
    if (first != .func) return null;
    const arity = db.types.getList(first.func.params).len;
    const is_c = first.func.is_cfunc;
    for (list[1..]) |t| {
        const d = db.types.get(t);
        if (d != .func or d.func.is_cfunc != is_c) return null;
        if (db.types.getList(d.func.params).len != arity) return null;
    }
    return arity;
}

/// 检查集合中所有类型是否均为维度一致的元组类型；若是则返回维度。
fn allTuplesSameArity(db: *const Database, list: []const TypeId) ?usize {
    const first = db.types.get(list[0]);
    if (first != .tuple) return null;
    const arity = db.types.getList(first.tuple).len;
    for (list[1..]) |t| {
        const d = db.types.get(t);
        if (d != .tuple) return null;
        if (db.types.getList(d.tuple).len != arity) return null;
    }
    return arity;
}
