// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 分级重载决议（`scope_level` 分批、位置/命名/默认/变长参数与尾随闭包匹配、
//! 泛型部分实例化、最具体排序、无限定枚举构造器过滤与运算符重载）。

const std = @import("std");
const common = @import("common");
const ids = @import("../ids.zig");
const file_state_mod = @import("../db/FileState.zig");
const pkg_state_mod = @import("../db/PackageState.zig");
const scope_mod = @import("../resolve/scope.zig");
const access_mod = @import("../resolve/access.zig");
const type_interner_mod = @import("../interner/TypeInterner.zig");
const subtype_mod = @import("subtype.zig");
const solver_mod = @import("solver.zig");
const literal_mod = @import("literal.zig");

const AccessContext = ids.AccessContext;
const CallableHeaderSig = pkg_state_mod.CallableHeaderSig;
const CallableRef = ids.CallableRef;
const DefId = ids.DefId;
const EarlyCandidate = scope_mod.EarlyCandidate;
const InternedId = ids.InternedId;
const LocalSolver = solver_mod.LocalSolver;
const PlatformError = file_state_mod.PlatformError;
const SubstPack = solver_mod.SubstPack;
const SymbolRef = ids.SymbolRef;
const TypeId = ids.TypeId;
const TypeInterner = type_interner_mod.TypeInterner;
const TypeListId = ids.TypeListId;

/// 重载决议输入描述（统一覆盖包级函数、局部函数、方法、构造器、带参枚举构造器与运算符重载）。
pub const CallResolveRequest = struct {
    file: common.FileId,
    access_ctx: AccessContext,
    call_range: common.TextRange,
    candidates: []const EarlyCandidate,
    args: []const common.HirCallArg,
    trailing_lambda: ?*const common.HirExpr = null,
    explicit_type_args: []const TypeId = &.{},
    /// 非空时参与泛型返回类型推导，并对形参匹配通过的候选执行返回类型子类型过滤。
    expected_ret: ?TypeId = null,
    /// 成员调用或扩展调用时的接收者类型。
    receiver_ty: ?TypeId = null,
    /// 可选预计算实参类型切片（用于二元运算符重载等已提前求值实参的场景，避免重复综合与重复诊断）。
    precomputed_arg_tys: ?[]const TypeId = null,
};

/// 重载决议结果（所有切片均借用自 `checker` 临时内存池，在当前声明项检查结束前有效，调用者不得释放）。
pub const CallResolveOutcome = union(enum) {
    resolved: struct {
        target: SymbolRef,
        type_args: TypeListId,
        ret_ty: TypeId,
        /// `arg_to_param[i]` 记录第 `i` 个调用参数匹配的目标形参下标（变长打包参数统一映射到最后一个 `Array<T>` 形参）。
        arg_to_param: []const u32,
        is_variadic_desugar: bool,
    },
    no_match: struct {
        inaccessible_candidates: []const DefId,
        /// 接收者、显式类型实参或任一实参已含错误类型（用于避免产生重复的级联噪音诊断）。
        has_err_arg: bool = false,
        /// 存在形参完全匹配、仅返回类型不满足外层期望类型的候选。
        matched_ignoring_expected_ret: bool = false,
        /// 显式类型实参个数与候选泛型形参个数不匹配。
        wrong_type_arg_count: bool = false,
        /// 泛型类型实参不满足候选的 `where` 约束上界。
        where_constraint_failed: bool = false,
    },
    /// 最高 `scope_level` 下存在多个同等具体候选（或存在多个合法枚举构造器）导致二义性。
    ambiguous: []const SymbolRef,
};

/// 单候选匹配失败时记录的诊断辅助原因。
const MatchFailureStats = struct {
    matched_ignoring_expected_ret: bool = false,
    wrong_type_arg_count: bool = false,
    where_constraint_failed: bool = false,
};

const MatchedCandidate = struct {
    cand: EarlyCandidate,
    sig: *const CallableHeaderSig,
    inst_param_tys: []const TypeId,
    type_args: TypeListId,
    ret_ty: TypeId,
    arg_to_param: []const u32,
    is_variadic_desugar: bool,
};

/// 执行分级重载决议：
/// 1. 阶段一仅读取 `CallableHeaderSig` 执行可见性过滤与位置/命名/默认参数匹配；
/// 2. 按 `scope_level` 降序分批检查：高优先级作用域一旦命中合法候选即停止考察更外层；
/// 3. 对形参匹配通过且存在 `req.expected_ret` 的候选，按需调用 `returnTypeOf` 完成返回类型过滤；
/// 4. 普通调用无匹配时回退尝试仓颉变长参数 `Array<T>` 打包；
/// 5. 多合法候选按最具体排序规则选出唯一胜出者，若含枚举构造器或同等具体则报二义性。
/// 返回结果中的切片借用自 `checker.scratch` 临时内存池，调用者不得单独释放。
pub fn resolveCallOverload(
    checker: anytype,
    req: CallResolveRequest,
) PlatformError!CallResolveOutcome {
    const db = checker.db;
    const scratch = checker.scratch.allocator();

    // 1. 可见性过滤与同符号去重（同符号保留最高 scope_level）
    var visible: std.ArrayListUnmanaged(EarlyCandidate) = .empty;
    var inaccessible: std.ArrayListUnmanaged(DefId) = .empty;
    for (req.candidates) |c| {
        var dup_idx: ?usize = null;
        for (visible.items, 0..) |existing, ei| {
            if (SymbolRef.eql(existing.ref, c.ref)) {
                dup_idx = ei;
                break;
            }
        }
        if (dup_idx) |di| {
            if (c.scope_level > visible.items[di].scope_level) {
                visible.items[di] = c;
            }
            continue;
        }
        switch (c.ref) {
            .def => |d| {
                if (try access_mod.checkAccess(db, d, req.receiver_ty, req.access_ctx)) {
                    try visible.append(scratch, c);
                } else {
                    try inaccessible.append(scratch, d);
                }
            },
            .local => try visible.append(scratch, c),
            else => {},
        }
    }

    if (visible.items.len == 0) {
        return .{ .no_match = .{ .inaccessible_candidates = try inaccessible.toOwnedSlice(scratch) } };
    }

    // 2. 按 scope_level 降序排列
    std.mem.sort(EarlyCandidate, visible.items, {}, struct {
        /// 按作用域优先级 `scope_level` 降序排列重载候选。
        fn cmp(_: void, a: EarlyCandidate, b: EarlyCandidate) bool {
            return a.scope_level > b.scope_level;
        }
    }.cmp);

    // 构造完整实参列表（含未标注形参的 Lambda 与空数组字面量延迟到形参匹配或重检阶段）
    const total_args = req.args.len + @as(usize, if (req.trailing_lambda != null) 1 else 0);
    const arg_tys = try scratch.alloc(TypeId, total_args);
    if (req.precomputed_arg_tys) |pre| {
        for (0..total_args) |i| {
            arg_tys[i] = if (i < pre.len) pre[i] else TypeInterner.err_ty;
        }
    } else {
        for (req.args, 0..) |arg, i| {
            arg_tys[i] = if ((arg.value.* == .array_lit and arg.value.array_lit.elements.len == 0) or
                (arg.value.* == .lambda and lambdaHasUnannotatedParam(arg.value.lambda)))
                TypeInterner.quest_ty
            else
                try checker.synthExpr(arg.value, .expr_arg);
        }
        if (req.trailing_lambda) |tl| {
            arg_tys[req.args.len] = if (tl.* == .lambda and lambdaHasUnannotatedParam(tl.lambda))
                TypeInterner.quest_ty
            else
                try checker.synthExpr(tl, .expr_arg);
        }
    }

    var has_err_arg = false;
    if (req.receiver_ty) |rty| {
        if (db.types.hasErr(rty)) has_err_arg = true;
    }
    for (req.explicit_type_args) |eta| {
        if (db.types.hasErr(eta)) has_err_arg = true;
    }
    for (arg_tys) |aty| {
        if (db.types.hasErr(aty)) has_err_arg = true;
    }

    var fail_stats: MatchFailureStats = .{};

    // 3. 普通调用匹配 -> 无匹配时回退变长参数打包匹配
    for ([_]bool{ false, true }) |variadic_mode| {
        var legals: std.ArrayListUnmanaged(MatchedCandidate) = .empty;
        var matched_level: ?i32 = null;

        for (visible.items) |cand| {
            if (matched_level) |lvl| {
                if (cand.scope_level < lvl) break;
            }
            const cref: CallableRef = switch (cand.ref) {
                .def => |d| .{ .def = d },
                .local => |l| .{ .local = l },
                else => continue,
            };
            const sig = db.callableHeaderSig(cref) catch continue;
            if (try matchSingleCandidate(checker, scratch, req, cand, sig, arg_tys, variadic_mode, &fail_stats)) |m| {
                try legals.append(scratch, m);
                if (matched_level == null) matched_level = cand.scope_level;
            }
        }

        if (legals.items.len == 0) continue;
        if (legals.items.len == 1) {
            const best = legals.items[0];
            const final_ret = try finalizeCandidateReturn(checker, best);
            try recheckCallArguments(checker, req, best, arg_tys);
            return .{ .resolved = .{
                .target = best.cand.ref,
                .type_args = best.type_args,
                .ret_ty = final_ret,
                .arg_to_param = best.arg_to_param,
                .is_variadic_desugar = best.is_variadic_desugar,
            } };
        }

        // 含枚举构造器不走最具体排序，直接报二义性
        for (legals.items) |m| {
            if (m.sig.is_enum_ctor) {
                const refs = try scratch.alloc(SymbolRef, legals.items.len);
                for (legals.items, 0..) |item, i| refs[i] = item.cand.ref;
                return .{ .ambiguous = refs };
            }
        }

        // 最具体候选淘汰排序
        if (try selectMostSpecific(db, req.file, legals.items)) |best| {
            const final_ret = try finalizeCandidateReturn(checker, best);
            try recheckCallArguments(checker, req, best, arg_tys);
            return .{ .resolved = .{
                .target = best.cand.ref,
                .type_args = best.type_args,
                .ret_ty = final_ret,
                .arg_to_param = best.arg_to_param,
                .is_variadic_desugar = best.is_variadic_desugar,
            } };
        }

        const refs = try scratch.alloc(SymbolRef, legals.items.len);
        for (legals.items, 0..) |item, i| refs[i] = item.cand.ref;
        return .{ .ambiguous = refs };
    }

    return .{ .no_match = .{
        .inaccessible_candidates = try inaccessible.toOwnedSlice(scratch),
        .has_err_arg = has_err_arg,
        .matched_ignoring_expected_ret = fail_stats.matched_ignoring_expected_ret,
        .wrong_type_arg_count = fail_stats.wrong_type_arg_count,
        .where_constraint_failed = fail_stats.where_constraint_failed,
    } };
}

/// 判定 Lambda 表达式是否存在省略类型标注的形参。
fn lambdaHasUnannotatedParam(lam: common.LambdaExpr) bool {
    const package_mod = @import("../resolve/package.zig");
    for (lam.params) |param| {
        if (package_mod.unwrapHirParam(param)) |hp| {
            if (hp.ty == null) return true;
        }
    }
    return false;
}

/// 匹配单个可调用候选（支持位置/命名/默认参数、尾随闭包、变长参数与泛型实参约束求解）。
fn matchSingleCandidate(
    checker: anytype,
    scratch: std.mem.Allocator,
    req: CallResolveRequest,
    cand: EarlyCandidate,
    sig: *const CallableHeaderSig,
    arg_tys: []const TypeId,
    variadic_mode: bool,
    fail_stats: *MatchFailureStats,
) PlatformError!?MatchedCandidate {
    const db = checker.db;
    const params = sig.params;
    const total_args = arg_tys.len;

    // 显式类型实参个数检查
    if (req.explicit_type_args.len > 0 and req.explicit_type_args.len != sig.type_params.len) {
        fail_stats.wrong_type_arg_count = true;
        return null;
    }

    // 校验并映射位置实参与命名实参到形参下标（禁止重复传入同一命名参数）
    const arg_to_param = try scratch.alloc(u32, total_args);
    const param_filled = try scratch.alloc(bool, params.len);
    const param_assigned = try scratch.alloc(bool, params.len);
    for (params, 0..) |p, i| {
        param_filled[i] = p.has_default;
        param_assigned[i] = false;
    }

    var positional_count: usize = 0;
    for (params) |p| {
        if (!p.is_named) positional_count += 1;
    }

    // 变长参数模式要求最后一个位置形参为 Array<T>
    var variadic_elem_ty: ?TypeId = null;
    if (variadic_mode) {
        if (sig.is_enum_ctor or positional_count == 0) return null;
        const last_pos_ty = params[positional_count - 1].ty;
        if (db.types.known.array_struct) |arr_def| {
            if (db.types.get(last_pos_ty) == .nominal and DefId.eql(db.types.get(last_pos_ty).nominal.def, arr_def)) {
                const a_args = db.types.getList(db.types.get(last_pos_ty).nominal.args);
                if (a_args.len == 1) variadic_elem_ty = a_args[0];
            }
        }
        if (variadic_elem_ty == null) return null;
    }

    var seen_named = false;
    var pos_cursor: usize = 0;
    for (req.args, 0..) |arg, i| {
        if (arg.name) |an| {
            seen_named = true;
            const an_id = try db.strings.intern(an.text);
            var matched_idx: ?usize = null;
            for (params, 0..) |p, p_idx| {
                if (p.is_named and p.name == an_id) {
                    matched_idx = p_idx;
                    break;
                }
            }
            const p_idx = matched_idx orelse return null;
            if (param_assigned[p_idx]) return null;
            arg_to_param[i] = @intCast(p_idx);
            param_filled[p_idx] = true;
            param_assigned[p_idx] = true;
        } else {
            if (seen_named) return null;
            if (variadic_mode and pos_cursor >= positional_count - 1) {
                arg_to_param[i] = @intCast(positional_count - 1);
                param_filled[positional_count - 1] = true;
            } else {
                if (pos_cursor >= positional_count) return null;
                if (param_assigned[pos_cursor]) return null;
                arg_to_param[i] = @intCast(pos_cursor);
                param_filled[pos_cursor] = true;
                param_assigned[pos_cursor] = true;
                pos_cursor += 1;
            }
        }
    }

    if (req.trailing_lambda != null) {
        if (params.len == 0) return null;
        const last_idx = params.len - 1;
        if (param_assigned[last_idx]) return null;
        arg_to_param[req.args.len] = @intCast(last_idx);
        param_filled[last_idx] = true;
        param_assigned[last_idx] = true;
    }

    // 变长模式下最后一个位置形参允许 0 个变长实参
    if (variadic_mode and positional_count > 0) {
        param_filled[positional_count - 1] = true;
    }

    for (param_filled) |ok| {
        if (!ok) return null;
    }

    // 提取接收者所属名义类型已具体化的类型实参（方法/构造器调用）
    var receiver_tps: []const ids.TypeParamRef = &.{};
    var receiver_targs: []const TypeId = &.{};
    if (req.receiver_ty) |rty| {
        if (db.types.get(rty) == .nominal) {
            const rn = db.types.get(rty).nominal;
            if (db.nominalHeaderOf(rn.def)) |nh| {
                receiver_tps = nh.type_params;
                receiver_targs = db.types.getList(rn.args);
            } else |_| {}
        }
    }

    // 构建形参具体化映射（无泛型直查，有泛型调用 LocalSolver 求解）
    const inst_param_tys = try scratch.alloc(TypeId, total_args);
    var resolved_type_args: TypeListId = .empty;
    var ret_ty: TypeId = sig.explicit_ret orelse TypeInterner.quest_ty;

    if (sig.type_params.len == 0) {
        for (0..total_args) |i| {
            const p_idx = arg_to_param[i];
            const raw_p = if (variadic_mode and p_idx == positional_count - 1) variadic_elem_ty.? else params[p_idx].ty;
            inst_param_tys[i] = try subtype_mod.substituteNominalParams(db, raw_p, receiver_tps, receiver_targs);
            if (!try argMatchesParam(db, req, i, arg_tys[i], inst_param_tys[i])) return null;
        }
        if (sig.explicit_ret) |er| {
            ret_ty = try subtype_mod.substituteNominalParams(db, er, receiver_tps, receiver_targs);
        }
    } else if (req.explicit_type_args.len == sig.type_params.len) {
        // 校验显式类型实参是否满足 where 上界约束
        const no_opt_box: subtype_mod.SubtypeOptions = .{ .implicit_boxed = true, .allow_option_box = false };
        for (sig.where_bounds) |wb| {
            const subj1 = try subtype_mod.substituteNominalParams(db, wb.subject, receiver_tps, receiver_targs);
            const subj = try subtype_mod.substituteNominalParams(db, subj1, sig.type_params, req.explicit_type_args);
            if (subj == TypeInterner.err_ty) continue;
            for (wb.upper_bounds) |ub| {
                const ub1 = try subtype_mod.substituteNominalParams(db, ub, receiver_tps, receiver_targs);
                const ub_inst = try subtype_mod.substituteNominalParams(db, ub1, sig.type_params, req.explicit_type_args);
                if (ub_inst == TypeInterner.err_ty) continue;
                if (!try subtype_mod.isSubtype(db, req.file, subj, ub_inst, no_opt_box)) {
                    fail_stats.where_constraint_failed = true;
                    return null;
                }
            }
        }
        resolved_type_args = try db.types.internList(req.explicit_type_args);
        for (0..total_args) |i| {
            const p_idx = arg_to_param[i];
            const raw_p = if (variadic_mode and p_idx == positional_count - 1) variadic_elem_ty.? else params[p_idx].ty;
            const step1 = try subtype_mod.substituteNominalParams(db, raw_p, receiver_tps, receiver_targs);
            inst_param_tys[i] = try subtype_mod.substituteNominalParams(db, step1, sig.type_params, req.explicit_type_args);
            if (!try argMatchesParam(db, req, i, arg_tys[i], inst_param_tys[i])) return null;
        }
        if (sig.explicit_ret) |er| {
            const step1 = try subtype_mod.substituteNominalParams(db, er, receiver_tps, receiver_targs);
            ret_ty = try subtype_mod.substituteNominalParams(db, step1, sig.type_params, req.explicit_type_args);
        }
    } else {
        // 自动泛型类型参数推导
        var solver = LocalSolver.init(db.gpa, db, req.file);
        defer solver.deinit();
        var pack: SubstPack = .{};
        defer pack.deinit(db.gpa);

        const tv_list = try scratch.alloc(solver_mod.TyVarId, sig.type_params.len);
        for (sig.type_params, 0..) |tp, i| {
            const tv = try solver.allocTyVar(tp);
            tv_list[i] = tv;
            try pack.u2i.put(db.gpa, tp, tv);
        }
        try solver.initUpperBounds(&pack, sig.where_bounds);

        const s_args = try scratch.alloc(solver_mod.SolverTyId, total_args);
        const s_params = try scratch.alloc(solver_mod.SolverTyId, total_args);
        for (0..total_args) |i| {
            s_args[i] = try solver.addSolverTy(.{ .concrete = arg_tys[i] });
            const p_idx = arg_to_param[i];
            const raw_p = if (variadic_mode and p_idx == positional_count - 1) variadic_elem_ty.? else params[p_idx].ty;
            const step1 = try subtype_mod.substituteNominalParams(db, raw_p, receiver_tps, receiver_targs);
            s_params[i] = try solver.liftFromTypeId(step1, &pack.u2i);
        }
        const s_ret = try solver.liftFromTypeId(ret_ty, &pack.u2i);
        const s_exp = if (req.expected_ret) |er| try solver.addSolverTy(.{ .concrete = er }) else null;

        if (!try solver.unifyCallArgs(&pack, s_args, s_params, s_ret, s_exp)) return null;
        const status = try solver.solve(&pack, false);
        if (status != .solved) return null;

        const solved_args = try scratch.alloc(TypeId, sig.type_params.len);
        for (tv_list, 0..) |tv, i| {
            const st_tv = try solver.addSolverTy(.{ .ty_var = tv });
            solved_args[i] = try solver.lowerToTypeId(st_tv, &pack);
        }
        if (!try solver.checkWhereConstraints(sig.where_bounds, &pack, null, null, req.call_range)) {
            fail_stats.where_constraint_failed = true;
            return null;
        }

        resolved_type_args = try db.types.internList(solved_args);
        for (0..total_args) |i| {
            inst_param_tys[i] = try solver.lowerToTypeId(s_params[i], &pack);
        }
        if (sig.explicit_ret != null) {
            ret_ty = try solver.lowerToTypeId(s_ret, &pack);
        }
    }

    // 对形参匹配通过且存在外层期望返回类型的候选，按需推导返回类型并做子类型过滤
    if (req.expected_ret) |exp_ret| {
        if (ret_ty == TypeInterner.quest_ty and cand.ref == .def) {
            ret_ty = try checker.queryReturnType(cand.ref.def);
        }
        if (ret_ty != TypeInterner.quest_ty and ret_ty != TypeInterner.err_ty) {
            if (!try subtype_mod.isSubtype(db, req.file, ret_ty, exp_ret, .{})) {
                fail_stats.matched_ignoring_expected_ret = true;
                return null;
            }
        }
    }

    return .{
        .cand = cand,
        .sig = sig,
        .inst_param_tys = inst_param_tys,
        .type_args = resolved_type_args,
        .ret_ty = ret_ty,
        .arg_to_param = arg_to_param,
        .is_variadic_desugar = variadic_mode,
    };
}

/// 在多个同等优先级合法候选中按 `CompareFuncCandidates` 选择唯一最具体候选。
fn selectMostSpecific(
    db: *db_mod.Database,
    file: common.FileId,
    legals: []const MatchedCandidate,
) PlatformError!?MatchedCandidate {
    var best_idx: ?usize = null;
    for (legals, 0..) |cand_i, i| {
        var beats_all = true;
        for (legals, 0..) |cand_j, j| {
            if (i == j) continue;
            const i_to_j = try isMoreSpecific(db, file, cand_i, cand_j);
            const j_to_i = try isMoreSpecific(db, file, cand_j, cand_i);
            if (!i_to_j or j_to_i) {
                beats_all = false;
                break;
            }
        }
        if (beats_all) {
            if (best_idx != null) return null;
            best_idx = i;
        }
    }
    return if (best_idx) |idx| legals[idx] else null;
}

/// 判定候选 `a` 是否比候选 `b` 更具体（对应 `CompareFuncCandidates` 与 `CompareParamTys`）。
fn isMoreSpecific(
    db: *db_mod.Database,
    file: common.FileId,
    a: MatchedCandidate,
    b: MatchedCandidate,
) PlatformError!bool {
    if (a.inst_param_tys.len != b.inst_param_tys.len) return false;
    var strictly_better = false;
    for (a.inst_param_tys, b.inst_param_tys) |ta, tb| {
        if (ta == tb) continue;
        const da = db.types.get(ta);
        const db_t = db.types.get(tb);
        if (da == .prim and db_t == .prim and da.prim.isNumeric() and db_t.prim.isNumeric()) {
            const ord = literal_mod.compareNumericPriority(da.prim, db_t.prim);
            if (ord == .gt) return false;
            if (ord == .lt) strictly_better = true;
            continue;
        }
        if (!try subtype_mod.isSubtype(db, file, ta, tb, .{})) return false;
        if (!try subtype_mod.isSubtype(db, file, tb, ta, .{})) strictly_better = true;
    }
    if (strictly_better) return true;

    // 签名完全一致时：具体实现优于接口或抽象方法
    if (a.cand.ref == .def and b.cand.ref == .def) {
        const ea = db.getDef(a.cand.ref.def) catch return false;
        const eb = db.getDef(b.cand.ref.def) catch return false;
        if (!ea.flags.is_abstract and eb.flags.is_abstract) return true;
    }
    return false;
}

/// 校验第 `arg_idx` 个调用实参是否兼容目标形参类型 `param_ty`（支持数组字面量双向适配 `VArray<T, $N>` 与延迟 Lambda/空数组形参结构校验）。
fn argMatchesParam(
    db: *db_mod.Database,
    req: CallResolveRequest,
    arg_idx: usize,
    arg_ty: TypeId,
    param_ty: TypeId,
) PlatformError!bool {
    if (arg_ty == TypeInterner.quest_ty) {
        const arg_expr: ?*const common.HirExpr = if (arg_idx < req.args.len)
            req.args[arg_idx].value
        else
            req.trailing_lambda;
        if (arg_expr) |ae| {
            const unboxed_p = db.types.unboxOption(param_ty);
            switch (ae.*) {
                .lambda => |lam| {
                    if (db.types.get(unboxed_p) != .func) return false;
                    const p_list = db.types.getList(db.types.get(unboxed_p).func.params);
                    const package_mod = @import("../resolve/package.zig");
                    var lam_arity: usize = 0;
                    for (lam.params) |p| {
                        if (package_mod.unwrapHirParam(p) != null) lam_arity += 1;
                    }
                    return lam_arity == p_list.len;
                },
                .array_lit => |al| {
                    if (al.elements.len == 0) {
                        return switch (db.types.get(unboxed_p)) {
                            .varray => |va| va.len == 0,
                            .nominal => |nom| blk: {
                                if (db.types.known.array_struct) |arr_def| {
                                    if (DefId.eql(nom.def, arr_def)) break :blk true;
                                    const tgt_def = db.getDef(nom.def) catch break :blk false;
                                    if (tgt_def.kind == .interface_) {
                                        break :blk (try subtype_mod.downgrade(db, req.file, arr_def, unboxed_p)) != null;
                                    }
                                }
                                break :blk false;
                            },
                            else => false,
                        };
                    }
                },
                else => {},
            }
        }
        return true;
    }
    if (try subtype_mod.isSubtype(db, req.file, arg_ty, param_ty, .{})) return true;

    // 数组字面量无目标类型综合时默认产出 Array<T>，目标形参为 VArray<T, $N> 时检查长度与元素兼容性
    if (arg_idx < req.args.len and req.args[arg_idx].value.* == .array_lit) {
        const al = req.args[arg_idx].value.array_lit;
        const unboxed_p = db.types.unboxOption(param_ty);
        if (db.types.get(unboxed_p) == .varray) {
            const va = db.types.get(unboxed_p).varray;
            if (al.elements.len != va.len) return false;
            if (db.types.known.array_struct) |arr_def| {
                if (db.types.get(arg_ty) == .nominal and DefId.eql(db.types.get(arg_ty).nominal.def, arr_def)) {
                    const a_args = db.types.getList(db.types.get(arg_ty).nominal.args);
                    if (a_args.len == 1) {
                        return subtype_mod.isSubtype(db, req.file, a_args[0], va.elem, .{});
                    }
                }
            }
        }
    }
    return false;
}

/// 唯一胜出后按需获取最终返回类型（若尚未求得则调用 `queryReturnType`）。
fn finalizeCandidateReturn(checker: anytype, best: MatchedCandidate) PlatformError!TypeId {
    if (best.ret_ty != TypeInterner.quest_ty) return best.ret_ty;
    return switch (best.cand.ref) {
        .def => |d| checker.queryReturnType(d),
        .local => |l| checker.getLocalReturnType(l),
        else => TypeInterner.err_ty,
    };
}

/// 唯一胜出后仅对需要上下文窄化或参数注入的实参执行重检，避免对已定型的嵌套调用产生重复诊断与指数级重算。
fn recheckCallArguments(
    checker: anytype,
    req: CallResolveRequest,
    best: MatchedCandidate,
    arg_tys: []const TypeId,
) PlatformError!void {
    for (req.args, 0..) |arg, i| {
        if (needsContextualRecheck(checker.db, arg.value, arg_tys[i])) {
            _ = try checker.checkExpr(arg.value, best.inst_param_tys[i]);
        }
    }
    if (req.trailing_lambda) |tl| {
        if (needsContextualRecheck(checker.db, tl, arg_tys[req.args.len])) {
            _ = try checker.checkExpr(tl, best.inst_param_tys[req.args.len]);
        }
    }
}

/// 判定实参表达式是否依赖目标形参类型完成字面量窄化、`VArray` 构造、Lambda 形参注入或未定型 `quest`/`Ideal` 传播。
fn needsContextualRecheck(db: *const db_mod.Database, expr: *const common.HirExpr, prev_ty: TypeId) bool {
    if (prev_ty == TypeInterner.quest_ty or db.types.hasIdeal(prev_ty)) return true;
    return switch (expr.*) {
        .lambda, .array_lit, .int_lit, .float_lit => true,
        .unary => |u| u.op == .neg and (u.operand.* == .int_lit or u.operand.* == .float_lit),
        else => false,
    };
}

/// 针对无限定名称查找未命中常规声明时，按 `(name, arg_count)` 搜索并按外层目标类型过滤无限定枚举构造器候选。
/// 返回切片由调用者传入的 `alloc` 分配，结束后须由调用者通过 `alloc.free` 释放。
pub fn findEnumSugarCandidates(
    checker: anytype,
    alloc: std.mem.Allocator,
    name: InternedId,
    arg_count: ?usize,
    expected_ty: ?TypeId,
) PlatformError![]DefId {
    const db = checker.db;
    const rd = checker.resolve_data;

    var local_pkg_hits: std.ArrayListUnmanaged(DefId) = .empty;
    defer local_pkg_hits.deinit(alloc);
    var imported_hits: std.ArrayListUnmanaged(DefId) = .empty;
    defer imported_hits.deinit(alloc);

    // 1. 当前包内枚举构造器
    if (checker.pkg_state.enum_ctors.get(name)) |ctors| {
        for (ctors) |cdef| {
            if (try matchEnumCtorArity(db, cdef, arg_count)) {
                try local_pkg_hits.append(alloc, cdef);
            }
        }
    }

    // 2. 通配符导入包（含 std.core 的 Some/None）
    for (rd.glob_import_pkgs) |gp| {
        const ps = db.packageState(gp) catch continue;
        if (ps.enum_ctors.get(name)) |ctors| {
            for (ctors) |cdef| {
                if (try matchEnumCtorArity(db, cdef, arg_count)) {
                    try imported_hits.append(alloc, cdef);
                }
            }
        }
    }

    // 有期望类型时合并筛选；无期望类型时当前包优先
    var pool: std.ArrayListUnmanaged(DefId) = .empty;
    errdefer pool.deinit(alloc);
    if (expected_ty) |raw_exp| {
        const unboxed = db.types.unboxOption(raw_exp);
        const expected_owner: ?DefId = if (db.types.get(unboxed) == .nominal) db.types.get(unboxed).nominal.def else null;
        for ([_][]const DefId{ local_pkg_hits.items, imported_hits.items }) |group| {
            for (group) |cdef| {
                const entry = db.getDef(cdef) catch continue;
                if (expected_owner == null or (entry.owner != null and DefId.eql(entry.owner.?, expected_owner.?))) {
                    try pool.append(alloc, cdef);
                }
            }
        }
    }
    if (pool.items.len == 0) {
        if (local_pkg_hits.items.len > 0) {
            try pool.appendSlice(alloc, local_pkg_hits.items);
        } else {
            try pool.appendSlice(alloc, imported_hits.items);
        }
    }
    return pool.toOwnedSlice(alloc);
}

/// 校验枚举构造器是否匹配期望的实参个数（无参枚举构造器 `arg_count == null` 或 `0`）。
fn matchEnumCtorArity(db: *db_mod.Database, cdef: DefId, arg_count: ?usize) PlatformError!bool {
    const ps = try db.packageState(cdef.pkg);
    if (ps.callable_headers.get(cdef.idx)) |sig| {
        return if (arg_count) |n| sig.params.len == n else false;
    }
    return arg_count == null or arg_count.? == 0;
}

const db_mod = @import("../db/Database.zig");
