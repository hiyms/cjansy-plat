// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 仓颉核心语法糖类型检查：数组字面量、`?T`/`?.`/`??`、`Range`、`for-in`、
//! 字符串插值、`try-with-resources`、`spawn` 与 `synchronized`。

const std = @import("std");
const common = @import("common");
const ids = @import("../ids.zig");
const file_state_mod = @import("../db/FileState.zig");
const type_interner_mod = @import("../interner/TypeInterner.zig");
const subtype_mod = @import("subtype.zig");
const join_meet_mod = @import("join_meet.zig");
const literal_mod = @import("literal.zig");

const PlatformError = file_state_mod.PlatformError;
const TypeId = ids.TypeId;
const TypeInterner = type_interner_mod.TypeInterner;

/// 检查数组字面量 `[e1, e2, ...]`（与 `cangjie_compiler` 的 `ChkArrayLit` / `SynArrayLit` 一致）：
/// - 有目标类型时：剥离外层 `Option`；接口目标通过 `downgrade(Array, target)` 反推元素类型；
///   支持 `Array<T>` 与 `VArray<T, $N>`（校验长度严格一致）；
/// - 无目标类型时：空数组报错；非空数组逐元素 `synth` + `replaceIdeal` 后计算 `computeJoin` 得 `Array<T>`。
pub fn checkArrayLit(
    checker: anytype,
    al: *const common.ArrayLit,
    expected: ?TypeId,
) PlatformError!TypeId {
    const db = checker.db;
    const file = checker.global_item.file;

    if (expected) |raw_tgt| {
        const tgt = db.types.unboxOption(raw_tgt);
        switch (db.types.get(tgt)) {
            .varray => |va| {
                if (al.elements.len != va.len) {
                    try checker.emitDiag(al.range, .err, "数组字面量元素个数与 VArray 固定长度不匹配");
                }
                for (al.elements) |el| {
                    _ = try checker.checkExpr(el.value, va.elem);
                }
                checker.setNodeType(al.id, tgt);
                return tgt;
            },
            .nominal => |nom| {
                if (db.types.known.array_struct) |arr_def| {
                    if (ids.DefId.eql(nom.def, arr_def)) {
                        const args = db.types.getList(nom.args);
                        const elem_ty = if (args.len == 1) args[0] else TypeInterner.err_ty;
                        for (al.elements) |el| {
                            _ = try checker.checkExpr(el.value, elem_ty);
                        }
                        checker.setNodeType(al.id, tgt);
                        return tgt;
                    }
                    // 若目标为接口，尝试将 Array 向下反推匹配接口
                    const tgt_def = db.getDef(nom.def) catch null;
                    if (tgt_def != null and tgt_def.?.kind == .interface_) {
                        if (try subtype_mod.downgrade(db, file, arr_def, tgt)) |down_arr| {
                            const args = db.types.getList(db.types.get(down_arr).nominal.args);
                            const elem_ty = if (args.len == 1) args[0] else TypeInterner.err_ty;
                            for (al.elements) |el| {
                                _ = try checker.checkExpr(el.value, elem_ty);
                            }
                            checker.setNodeType(al.id, down_arr);
                            return down_arr;
                        }
                    }
                }
            },
            else => {},
        }
    }

    // 无目标类型或目标回退至综合路径
    if (al.elements.len == 0) {
        try checker.emitDiag(al.range, .err, "空数组字面量缺少上下文目标类型，无法推导元素类型");
        checker.setNodeType(al.id, TypeInterner.err_ty);
        return TypeInterner.err_ty;
    }

    const elem_tys = try db.gpa.alloc(TypeId, al.elements.len);
    defer db.gpa.free(elem_tys);
    for (al.elements, 0..) |el, i| {
        const raw_ty = try checker.synthExpr(el.value, .expr_arg);
        elem_tys[i] = try db.types.replaceIdeal(raw_ty);
    }
    const joined = switch (try join_meet_mod.computeJoin(db, file, elem_tys)) {
        .ok => |j| j,
        .ambiguous_or_none => blk: {
            try checker.emitDiag(al.range, .err, "数组字面量元素不存在唯一最小公共父类型");
            break :blk TypeInterner.err_ty;
        },
        .has_error => TypeInterner.err_ty,
    };
    const arr_ty = try db.types.internArray(joined);
    checker.setNodeType(al.id, arr_ty);
    return arr_ty;
}

/// 检查空合并运算 `lhs ?? rhs`（左侧必须为 `Option<T>`，右侧按期望类型或载荷类型 `T` 检查）。
pub fn checkCoalescing(
    checker: anytype,
    bin: *const common.BinaryExpr,
    expected: ?TypeId,
) PlatformError!TypeId {
    const db = checker.db;
    const file = checker.global_item.file;
    const lhs_ty = try checker.synthExpr(bin.lhs, .none);
    if (lhs_ty == TypeInterner.err_ty) {
        _ = try checker.synthExpr(bin.rhs, .none);
        return TypeInterner.err_ty;
    }

    const payload = db.types.unwrapOptionOnce(lhs_ty) orelse {
        try checker.emitDiag(bin.lhs.range(), .err, "空合并运算符 ?? 的左侧操作数必须为 Option<T> 类型");
        _ = try checker.synthExpr(bin.rhs, .none);
        return TypeInterner.err_ty;
    };

    const rhs_target = if (expected) |exp| blk: {
        if (try subtype_mod.isSubtype(db, file, payload, exp, .{})) break :blk exp;
        break :blk payload;
    } else payload;

    _ = try checker.checkExpr(bin.rhs, rhs_target);
    return rhs_target;
}

/// 检查区间表达式 `a..b:step` / `a..=b:step` 并绑定至 `std.core.Range<T>`。
pub fn checkRangeExpr(
    checker: anytype,
    re: *const common.RangeExpr,
    expected: ?TypeId,
) PlatformError!TypeId {
    const db = checker.db;
    const file = checker.global_item.file;
    var elem_ty: ?TypeId = null;

    if (expected) |raw_exp| {
        const unboxed = db.types.unboxOption(raw_exp);
        if (db.types.known.range_struct) |range_def| {
            if (db.types.get(unboxed) == .nominal) {
                if (ids.DefId.eql(db.types.get(unboxed).nominal.def, range_def)) {
                    const args = db.types.getList(db.types.get(unboxed).nominal.args);
                    if (args.len == 1) elem_ty = args[0];
                } else if (try subtype_mod.downgrade(db, file, range_def, unboxed)) |down| {
                    const args = db.types.getList(db.types.get(down).nominal.args);
                    if (args.len == 1) elem_ty = args[0];
                }
            }
        }
    }

    if (elem_ty == null) {
        const start_ty = if (re.start) |s| try checker.synthExpr(s, .none) else null;
        const end_ty = if (re.end) |e| try checker.synthExpr(e, .none) else null;
        if (start_ty != null and start_ty.? != TypeInterner.nothing_ty and !db.types.hasIdeal(start_ty.?)) {
            elem_ty = start_ty.?;
        } else if (end_ty != null and end_ty.? != TypeInterner.nothing_ty and !db.types.hasIdeal(end_ty.?)) {
            elem_ty = end_ty.?;
        } else {
            elem_ty = TypeInterner.int64_ty;
        }
    } else {
        if (re.start) |s| _ = try checker.checkExpr(s, elem_ty.?);
        if (re.end) |e| _ = try checker.checkExpr(e, elem_ty.?);
    }

    if (re.step) |st| {
        _ = try checker.checkExpr(st, TypeInterner.int64_ty);
        if (st.* == .int_lit) {
            if (literal_mod.parseIntegerMagnitude(st.int_lit.text)) |mag| {
                if (mag == 0) try checker.emitDiag(st.range(), .err, "区间步长不能为 0");
            }
        }
    }

    if (db.types.known.range_struct) |range_def| {
        const args = try db.types.internList(&.{elem_ty.?});
        const range_ty = try db.types.intern(.{ .nominal = .{ .def = range_def, .args = args } });
        checker.setNodeType(re.id, range_ty);
        return range_ty;
    }
    return TypeInterner.err_ty;
}

/// 检查 `for (pattern in iterable) where guard { body }`（返回类型恒为 `Unit`）。
pub fn checkForInExpr(
    checker: anytype,
    fi: *const common.ForInExpr,
) PlatformError!TypeId {
    const db = checker.db;
    const file = checker.global_item.file;
    const raw_iter = try checker.synthExpr(fi.iterable, .none);
    const iter_ty = try db.types.replaceIdeal(raw_iter);

    var elem_ty: TypeId = TypeInterner.err_ty;
    if (iter_ty == TypeInterner.nothing_ty) {
        try checker.emitDiag(fi.iterable.range(), .err, "for-in 迭代源表达式类型不能为 Nothing");
    } else if (iter_ty != TypeInterner.err_ty) {
        // 优先直接识别 Array<T> / Range<T> / VArray<T, $N> / String，再按 Iterable<E> 提升
        switch (db.types.get(iter_ty)) {
            .varray => |va| elem_ty = va.elem,
            .nominal => |nom| {
                if (db.types.known.array_struct != null and ids.DefId.eql(nom.def, db.types.known.array_struct.?)) {
                    const args = db.types.getList(nom.args);
                    if (args.len == 1) elem_ty = args[0];
                } else if (db.types.known.range_struct != null and ids.DefId.eql(nom.def, db.types.known.range_struct.?)) {
                    const args = db.types.getList(nom.args);
                    if (args.len == 1) elem_ty = args[0];
                } else if (db.types.known.string_struct != null and ids.DefId.eql(nom.def, db.types.known.string_struct.?)) {
                    elem_ty = TypeInterner.uint8_ty;
                } else if (db.types.known.iterable_iface) |it_def| {
                    const promoted = try subtype_mod.promote(db, db.gpa, file, iter_ty, it_def);
                    defer db.gpa.free(promoted);
                    if (promoted.len > 0) {
                        const args = db.types.getList(db.types.get(promoted[0]).nominal.args);
                        if (args.len == 1) elem_ty = args[0];
                    }
                }
            },
            else => {},
        }
    }

    try checker.checkPattern(fi.pattern, elem_ty);
    if (fi.guard) |g| _ = try checker.checkExpr(g, TypeInterner.bool_ty);
    _ = try checker.synthBlock(fi.body, .unused);
    checker.setNodeType(fi.id, TypeInterner.unit_ty);
    return TypeInterner.unit_ty;
}

/// 检查字符串插值 `"${expr}"`（返回类型恒为 `std.core.String`）。
pub fn checkStrInterp(checker: anytype, si: *const common.StrInterp) PlatformError!TypeId {
    const db = checker.db;
    for (si.parts) |part| {
        if (part == .interpolation) {
            const part_ty = try checker.synthBlock(part.interpolation.body, .none);
            if (part_ty == TypeInterner.nothing_ty) {
                try checker.emitDiag(part.interpolation.range, .err, "字符串插值表达式类型不能为 Nothing");
            }
        }
    }
    const str_ty = try db.types.internString();
    checker.setNodeType(si.id, str_ty);
    return str_ty;
}

/// 检查 `try` 与 `try-with-resources` 表达式：
/// 带资源声明时资源类型须实现 `Resource` 且整体表达式类型恒为 `Unit`；
/// 普通 `try-catch` 按期望类型检查或求各分支最小公共父类型，`finally` 块恒为 `Unit`。
pub fn checkTryExpr(
    checker: anytype,
    te: *const common.TryExpr,
    expected: ?TypeId,
    pos: anytype,
) PlatformError!TypeId {
    const db = checker.db;
    const file = checker.global_item.file;

    // 1. 检查资源声明
    if (te.resources.len > 0) {
        const res_ty_opt: ?TypeId = if (db.types.known.resource_iface) |rd|
            try db.types.intern(.{ .nominal = .{ .def = rd, .args = .empty } })
        else
            null;

        for (te.resources) |res| {
            var r_ty: TypeId = TypeInterner.err_ty;
            if (res.ty) |rt| {
                r_ty = checker.resolve_data.resolved_types.get(.{ .item = checker.global_item.item, .hir = rt.id() }) orelse TypeInterner.err_ty;
                if (res.init) |ie| _ = try checker.checkExpr(ie, r_ty);
            } else if (res.init) |ie| {
                r_ty = try db.types.replaceIdeal(try checker.synthExpr(ie, .none));
            }
            if (res_ty_opt) |res_iface_ty| {
                if (r_ty != TypeInterner.err_ty and !try subtype_mod.isSubtype(db, file, r_ty, res_iface_ty, .{})) {
                    try checker.emitDiag(res.range, .err, "try-with-resources 资源类型必须实现 Resource 接口");
                }
            }
            try checker.setLocalTypeByDeclHir(res.id, r_ty);
            checker.setNodeType(res.id, r_ty);
        }

        _ = try checker.synthBlock(te.body, .unused);
        for (te.clauses) |cl| {
            switch (cl) {
                .catch_ => |cc| {
                    try checker.checkClausePattern(cc.pattern);
                    _ = try checker.synthBlock(cc.body, .unused);
                },
                .handle => |hc| {
                    try checker.checkClausePattern(hc.pattern);
                    _ = try checker.synthBlock(hc.body, .unused);
                },
            }
        }
        if (te.finally) |fin| _ = try checker.synthBlock(fin, .unused);
        checker.setNodeType(te.id, TypeInterner.unit_ty);
        return TypeInterner.unit_ty;
    }

    // 2. 普通 try-catch-finally
    if (expected) |exp| {
        _ = try checker.checkBlock(te.body, exp);
        for (te.clauses) |cl| {
            switch (cl) {
                .catch_ => |cc| {
                    try checker.checkClausePattern(cc.pattern);
                    _ = try checker.checkBlock(cc.body, exp);
                },
                .handle => |hc| {
                    try checker.checkClausePattern(hc.pattern);
                    _ = try checker.checkBlock(hc.body, exp);
                },
            }
        }
        if (te.finally) |fin| _ = try checker.synthBlock(fin, .unused);
        checker.setNodeType(te.id, exp);
        return exp;
    }

    if (pos == .unused) {
        _ = try checker.synthBlock(te.body, .unused);
        for (te.clauses) |cl| {
            switch (cl) {
                .catch_ => |cc| {
                    try checker.checkClausePattern(cc.pattern);
                    _ = try checker.synthBlock(cc.body, .unused);
                },
                .handle => |hc| {
                    try checker.checkClausePattern(hc.pattern);
                    _ = try checker.synthBlock(hc.body, .unused);
                },
            }
        }
        if (te.finally) |fin| _ = try checker.synthBlock(fin, .unused);
        checker.setNodeType(te.id, TypeInterner.unit_ty);
        return TypeInterner.unit_ty;
    }

    var branch_tys: std.ArrayListUnmanaged(TypeId) = .empty;
    defer branch_tys.deinit(db.gpa);
    try branch_tys.append(db.gpa, try db.types.replaceIdeal(try checker.synthBlock(te.body, .none)));
    for (te.clauses) |cl| {
        switch (cl) {
            .catch_ => |cc| {
                try checker.checkClausePattern(cc.pattern);
                try branch_tys.append(db.gpa, try db.types.replaceIdeal(try checker.synthBlock(cc.body, .none)));
            },
            .handle => |hc| {
                try checker.checkClausePattern(hc.pattern);
                try branch_tys.append(db.gpa, try db.types.replaceIdeal(try checker.synthBlock(hc.body, .none)));
            },
        }
    }
    if (te.finally) |fin| _ = try checker.synthBlock(fin, .unused);

    const res_ty = switch (try join_meet_mod.computeJoin(db, file, branch_tys.items)) {
        .ok => |j| j,
        .ambiguous_or_none => blk: {
            try checker.emitDiag(te.range, .err, "try 与 catch 分支不存在唯一最小公共父类型");
            break :blk TypeInterner.err_ty;
        },
        .has_error => TypeInterner.err_ty,
    };
    checker.setNodeType(te.id, res_ty);
    return res_ty;
}

/// 检查 `spawn (ctx) { ... }` 并推导返回类型 `std.core.Future<R>`。
pub fn checkSpawnExpr(
    checker: anytype,
    sp: *const common.SpawnExpr,
    expected: ?TypeId,
) PlatformError!TypeId {
    const db = checker.db;
    const file = checker.global_item.file;

    if (sp.context) |ctx_e| {
        const ctx_ty = try checker.synthExpr(ctx_e, .none);
        if (db.types.known.thread_context_iface) |tc_def| {
            const tc_ty = try db.types.intern(.{ .nominal = .{ .def = tc_def, .args = .empty } });
            if (ctx_ty != TypeInterner.err_ty and !try subtype_mod.isSubtype(db, file, ctx_ty, tc_ty, .{})) {
                try checker.emitDiag(ctx_e.range(), .err, "spawn 上下文参数必须实现 ThreadContext 接口");
            }
        }
    }

    var ret_target: ?TypeId = null;
    if (expected) |raw_exp| {
        if (db.types.known.future_class) |fut_def| {
            const unboxed = db.types.unboxOption(raw_exp);
            if (try subtype_mod.downgrade(db, file, fut_def, unboxed)) |down| {
                const args = db.types.getList(db.types.get(down).nominal.args);
                if (args.len == 1) ret_target = args[0];
            }
        }
    }

    const task_ret = if (ret_target) |rt| blk: {
        const fn_tgt = try db.types.intern(.{ .func = .{ .params = .empty, .ret = rt, .is_cfunc = false } });
        _ = try checker.checkExpr(sp.task, fn_tgt);
        break :blk rt;
    } else blk: {
        const task_ty = try checker.synthExpr(sp.task, .none);
        break :blk if (db.types.get(task_ty) == .func) db.types.get(task_ty).func.ret else TypeInterner.unit_ty;
    };

    if (db.types.known.future_class) |fut_def| {
        const args = try db.types.internList(&.{task_ret});
        const fut_ty = try db.types.intern(.{ .nominal = .{ .def = fut_def, .args = args } });
        checker.setNodeType(sp.id, fut_ty);
        return fut_ty;
    }
    return TypeInterner.err_ty;
}

/// 检查 `synchronized (mutex) { ... }`（类型等于其受保护语句块类型）。
pub fn checkSynchronizedExpr(
    checker: anytype,
    sy: *const common.SynchronizedExpr,
    expected: ?TypeId,
    pos: anytype,
) PlatformError!TypeId {
    const db = checker.db;
    const file = checker.global_item.file;
    const mtx_ty = try checker.synthExpr(sy.mutex, .none);
    if (db.types.known.lock_iface) |lock_def| {
        const lock_ty = try db.types.intern(.{ .nominal = .{ .def = lock_def, .args = .empty } });
        if (mtx_ty != TypeInterner.err_ty and !try subtype_mod.isSubtype(db, file, mtx_ty, lock_ty, .{})) {
            try checker.emitDiag(sy.mutex.range(), .err, "synchronized 参数必须实现 Lock 接口");
        }
    }
    const body_ty = if (expected) |exp|
        try checker.checkBlock(sy.body, exp)
    else
        try checker.synthBlock(sy.body, pos);
    checker.setNodeType(sy.id, body_ty);
    return body_ty;
}
