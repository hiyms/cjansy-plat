// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Lambda 表达式双向类型推导与泛型调用多轮迭代 `unsolvedAsQuest` 适配。

const std = @import("std");
const common = @import("common");
const ids = @import("../ids.zig");
const file_state_mod = @import("../db/FileState.zig");
const type_interner_mod = @import("../interner/TypeInterner.zig");
const solver_mod = @import("solver.zig");
const subtype_mod = @import("subtype.zig");
const package_mod = @import("../resolve/package.zig");

const LocalSolver = solver_mod.LocalSolver;
const PlatformError = file_state_mod.PlatformError;
const SolverTyId = solver_mod.SolverTyId;
const SubstPack = solver_mod.SubstPack;
const TypeId = ids.TypeId;
const TypeInterner = type_interner_mod.TypeInterner;

/// 在泛型多轮迭代中将嵌套求解函数类型 `func_ty` 中尚未解出的返回位置 `TyVarId` 替换为 `SolverTyData.quest`。
/// 仅当全部形参类型均不含未解 `TyVarId` 时返回转换后的 `SolverTyId`（供 `(Int64) -> ?` 向下检查省略参数注解的 Lambda 表达式），否则返回 `null`。
pub fn unsolvedAsQuest(
    solver: *LocalSolver,
    func_ty: SolverTyId,
    pack: *const SubstPack,
) std.mem.Allocator.Error!?SolverTyId {
    return solver.unsolvedAsQuest(func_ty, pack);
}

/// 在 Check 模式下检查 Lambda 表达式：剥离外层 `Option` 提取期望 `FuncTy`，
/// 为省略注解的形参注入目标形参类型，对显式注解形参校验逆变子类型（禁用装箱），
/// 再以目标返回类型（含 `QuestTy` 迭代中间态）检查 Lambda 语句块。
pub fn checkLambda(
    checker: anytype,
    lam: *const common.LambdaExpr,
    target_ty: TypeId,
) PlatformError!TypeId {
    const db = checker.db;
    const unboxed = db.types.unboxOption(target_ty);
    const t_data = db.types.get(unboxed);
    if (t_data != .func) {
        const syn = try synthLambda(checker, lam);
        try checker.checkAssignable(lam.range, syn, target_ty);
        return syn;
    }

    const tgt_params = db.types.getList(t_data.func.params);
    const param_count = lam.params.len;
    const final_params = try db.gpa.alloc(TypeId, param_count);
    defer db.gpa.free(final_params);

    const no_box: subtype_mod.SubtypeOptions = .{ .implicit_boxed = false, .allow_option_box = false };
    var idx: usize = 0;
    for (lam.params) |param| {
        if (package_mod.unwrapHirParam(param)) |hp| {
            const p_ty: TypeId = if (hp.ty) |ht| blk: {
                const ann = checker.resolve_data.resolved_types.get(.{ .item = checker.global_item.item, .hir = ht.id() }) orelse TypeInterner.err_ty;
                if (idx < tgt_params.len and ann != TypeInterner.err_ty and tgt_params[idx] != TypeInterner.quest_ty) {
                    if (!try subtype_mod.isSubtype(db, checker.global_item.file, tgt_params[idx], ann, no_box)) {
                        try checker.emitDiag(hp.range, .err, "Lambda 显式形参类型与期望函数形参类型不兼容");
                    }
                }
                break :blk ann;
            } else if (idx < tgt_params.len)
                tgt_params[idx]
            else
                TypeInterner.err_ty;

            final_params[idx] = p_ty;
            try checker.setLocalTypeByDeclHir(hp.id, p_ty);
            checker.setNodeType(hp.id, p_ty);
            idx += 1;
        }
    }

    if (idx != tgt_params.len) {
        try checker.emitDiag(lam.range, .err, "Lambda 表达式形参个数与期望函数类型不匹配");
    }

    const tgt_ret = t_data.func.ret;
    const body_ret = if (tgt_ret == TypeInterner.quest_ty)
        try checker.synthCallableBody(lam.body)
    else
        try checker.checkCallableBody(lam.body, tgt_ret);

    const param_list = try db.types.internList(final_params[0..idx]);
    const fn_ty = try db.types.intern(.{ .func = .{
        .params = param_list,
        .ret = if (tgt_ret == TypeInterner.quest_ty) body_ret else tgt_ret,
        .is_cfunc = t_data.func.is_cfunc,
    } });
    checker.setNodeType(lam.id, fn_ty);
    return fn_ty;
}

/// 在 Synthesize 模式下推导 Lambda 表达式：读取显式形参注解，无注解时尝试在语句块中按成员用法反向推导，
/// 最后综合推导 Lambda 语句块返回类型。
pub fn synthLambda(
    checker: anytype,
    lam: *const common.LambdaExpr,
) PlatformError!TypeId {
    const db = checker.db;
    const param_count = lam.params.len;
    const final_params = try db.gpa.alloc(TypeId, param_count);
    defer db.gpa.free(final_params);

    var idx: usize = 0;
    for (lam.params) |param| {
        if (package_mod.unwrapHirParam(param)) |hp| {
            const p_ty = if (hp.ty) |ht|
                checker.resolve_data.resolved_types.get(.{ .item = checker.global_item.item, .hir = ht.id() }) orelse TypeInterner.err_ty
            else blk: {
                if (checker.in_func_arg_lambda_depth == 0) {
                    try checker.emitDiag(hp.range, .err, "无上下文目标类型的 Lambda 形参缺少显式类型标注");
                }
                break :blk TypeInterner.err_ty;
            };
            final_params[idx] = p_ty;
            try checker.setLocalTypeByDeclHir(hp.id, p_ty);
            checker.setNodeType(hp.id, p_ty);
            idx += 1;
        }
    }

    const ret_ty = try checker.synthCallableBody(lam.body);
    const param_list = try db.types.internList(final_params[0..idx]);
    const fn_ty = try db.types.intern(.{ .func = .{
        .params = param_list,
        .ret = ret_ty,
        .is_cfunc = false,
    } });
    checker.setNodeType(lam.id, fn_ty);
    return fn_ty;
}
