// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 支持嵌套占位符类型变量的局部约束求解器（对应 `cangjie_compiler` 的 `LocalTypeArgumentSynthesis`）。

const std = @import("std");
const common = @import("common");
const ids = @import("../ids.zig");
const file_state_mod = @import("../db/FileState.zig");
const pkg_state_mod = @import("../db/PackageState.zig");
const db_mod = @import("../db/Database.zig");
const type_interner_mod = @import("../interner/TypeInterner.zig");
const subtype_mod = @import("subtype.zig");
const join_meet_mod = @import("join_meet.zig");
const literal_mod = @import("literal.zig");

const Database = db_mod.Database;
const DefId = ids.DefId;
const GenericBoundSig = pkg_state_mod.GenericBoundSig;
const PlatformError = file_state_mod.PlatformError;
const TypeId = ids.TypeId;
const TypeInterner = type_interner_mod.TypeInterner;
const TypeParamRef = ids.TypeParamRef;

/// 求解器内部临时占位符类型变量句柄（不进入 `TypeInterner`）。
pub const TyVarId = enum(u32) {
    _,

    /// 由 0-based 整数序号构造 `TyVarId`。
    pub inline fn fromIndex(idx: u32) TyVarId {
        return @fromBackingInt(idx);
    }

    /// 获取底层 0-based 整数序号。
    pub inline fn index(self: TyVarId) u32 {
        return @backingInt(self);
    }
};

/// 局部求解器内部递归类型句柄（存活于 `LocalSolver.arena`，允许任意层级嵌套 `TyVarId`）。
pub const SolverTyId = enum(u32) {
    _,

    /// 由 0-based 整数序号构造 `SolverTyId`。
    pub inline fn fromIndex(idx: u32) SolverTyId {
        return @fromBackingInt(idx);
    }

    /// 获取底层 0-based 整数序号。
    pub inline fn index(self: SolverTyId) u32 {
        return @backingInt(self);
    }
};

/// 局部求解器内部递归类型载荷。
pub const SolverTyData = union(enum) {
    /// 不含任何占位符的规范化 `TypeId`。
    concrete: TypeId,
    /// 待求解占位符类型变量。
    ty_var: TyVarId,
    /// 部分未知目标哨兵（用于 `unsolvedAsQuest` 迭代推导）。
    quest: void,
    err: void,
    nominal: struct { def: DefId, args: []const SolverTyId },
    cpointer: SolverTyId,
    varray: struct { elem: SolverTyId, len: u64 },
    tuple: []const SolverTyId,
    func: struct { params: []const SolverTyId, ret: SolverTyId, is_cfunc: bool = false },
};

/// 单个占位符类型变量的约束集合（基于 `SolverTyId`，支持类型变量之间的双向依赖图 `TyVarConstraintGraph`）。
pub const TyVarBounds = struct {
    /// 下界集合 `lbs`。
    lbs: std.ArrayListUnmanaged(SolverTyId) = .empty,
    /// 上界集合 `ubs`（含初始化的泛型 `where` 约束上界）。
    ubs: std.ArrayListUnmanaged(SolverTyId) = .empty,
    /// 候选和集 `sum`（无上下文 Lambda 参数从成员反向索引推导时使用）。
    sum: ?[]const SolverTyId = null,
    /// 贪婪等式解 `eq`。
    eq: ?SolverTyId = null,
};

/// 单条多分支求解状态（对应 `cangjie_compiler` 的 `ConstraintWithMemo`）。
pub const ConstraintBranch = struct {
    bounds: std.AutoHashMapUnmanaged(TyVarId, TyVarBounds) = .empty,
    /// 已访问的 `(sub, sup)` 统一化对集合，防止递归泛型上界引发无限循环。
    unified_memo: std.AutoHashMapUnmanaged(u64, void) = .empty,
    has_nothing: bool = false,
    has_any: bool = false,
    failed: bool = false,
};

/// 两层泛型替换映射（避免 `func f<T>(x: Array<T>) { f(x) }` 同名泛型形参域值重叠）。
/// `inst` 中的候选解切片 `[]const SolverTyId` 统一借用自所属 `LocalSolver.arena`，随 `LocalSolver.deinit` 统一回收。
pub const SubstPack = struct {
    /// 通用类型形参 `TypeParamRef` -> 局部占位符 `TyVarId`。
    u2i: std.AutoHashMapUnmanaged(TypeParamRef, TyVarId) = .empty,
    /// 占位符 `TyVarId` -> 一对多候选解集合（支持多路径 `promote` 如 `C<T, V> <: I<T> & I<V>`；切片分配于 `LocalSolver.arena`）。
    inst: std.AutoHashMapUnmanaged(TyVarId, []const SolverTyId) = .empty,

    /// 释放 `u2i` 与 `inst` 哈希表自身桶内存（不释放借用自 `LocalSolver.arena` 的值切片）。
    pub fn deinit(self: *SubstPack, gpa: std.mem.Allocator) void {
        self.u2i.deinit(gpa);
        self.inst.deinit(gpa);
        self.* = undefined;
    }
};

/// 约束回滚快照点（供重载候选试探与多分支求解回滚）。
pub const SolverSnapshot = struct {
    var_count: u32,
    branch_count: u32,
    ty_count: u32,
};

/// 求解状态结果。
pub const SolveStatus = enum(u8) {
    solved,
    partial,
    conflict,
    ambiguous,
};

/// 局部类型参数约束求解器（对应 `cangjie_compiler` 的 `LocalTypeArgumentSynthesis`）。
pub const LocalSolver = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    db: *Database,
    file: common.FileId,
    solver_tys: std.ArrayListUnmanaged(SolverTyData) = .empty,
    var_origins: std.ArrayListUnmanaged(?TypeParamRef) = .empty,
    branches: std.ArrayListUnmanaged(ConstraintBranch) = .empty,

    /// 初始化局部约束求解器及其专属临时内存池。
    pub fn init(gpa: std.mem.Allocator, db: *Database, file: common.FileId) LocalSolver {
        return .{
            .gpa = gpa,
            .arena = .init(gpa),
            .db = db,
            .file = file,
        };
    }

    /// 释放求解器全部分支状态与临时 `SolverTyData` 内存池。
    pub fn deinit(self: *LocalSolver) void {
        self.solver_tys.deinit(self.gpa);
        self.var_origins.deinit(self.gpa);
        self.branches.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// 确保至少存在一条初始约束分支。
    fn ensureInitialBranch(self: *LocalSolver) std.mem.Allocator.Error!void {
        if (self.branches.items.len == 0) {
            try self.branches.append(self.gpa, .{});
        }
    }

    /// 在局部求解器中新增一条 `SolverTyData` 并返回其句柄。
    pub fn addSolverTy(self: *LocalSolver, data: SolverTyData) std.mem.Allocator.Error!SolverTyId {
        const id = SolverTyId.fromIndex(@intCast(self.solver_tys.items.len));
        try self.solver_tys.append(self.gpa, data);
        return id;
    }

    /// 按 `SolverTyId` 获取载荷。
    pub inline fn getSolverTy(self: *const LocalSolver, id: SolverTyId) SolverTyData {
        return self.solver_tys.items[id.index()];
    }

    /// 分配新的局部占位符类型变量。
    pub fn allocTyVar(self: *LocalSolver, origin: ?TypeParamRef) std.mem.Allocator.Error!TyVarId {
        const id = TyVarId.fromIndex(@intCast(self.var_origins.items.len));
        try self.var_origins.append(self.gpa, origin);
        return id;
    }

    /// 记录当前约束快照，配合 `rollback` 实现试探回滚。
    pub fn snapshot(self: *const LocalSolver) SolverSnapshot {
        return .{
            .var_count = @intCast(self.var_origins.items.len),
            .branch_count = @intCast(self.branches.items.len),
            .ty_count = @intCast(self.solver_tys.items.len),
        };
    }

    /// 回滚至指定快照，撤销期间新增的变量与分支。
    pub fn rollback(self: *LocalSolver, snap: SolverSnapshot) void {
        self.var_origins.shrinkRetainingCapacity(snap.var_count);
        self.branches.shrinkRetainingCapacity(snap.branch_count);
        self.solver_tys.shrinkRetainingCapacity(snap.ty_count);
    }

    /// 将规范化 `TypeId` 按 `u2i` 提升为嵌套含 `TyVarId` 的 `SolverTyId`。
    pub fn liftFromTypeId(
        self: *LocalSolver,
        ty: TypeId,
        u2i: *const std.AutoHashMapUnmanaged(TypeParamRef, TyVarId),
    ) std.mem.Allocator.Error!SolverTyId {
        const a = self.arena.allocator();
        return switch (self.db.types.get(ty)) {
            .err => self.addSolverTy(.{ .err = {} }),
            .quest => self.addSolverTy(.{ .quest = {} }),
            .type_param => |tp| if (u2i.get(tp)) |tv|
                self.addSolverTy(.{ .ty_var = tv })
            else
                self.addSolverTy(.{ .concrete = ty }),
            .nominal => |n| blk: {
                const old_args = self.db.types.getList(n.args);
                if (old_args.len == 0) break :blk try self.addSolverTy(.{ .concrete = ty });
                const new_args = try a.alloc(SolverTyId, old_args.len);
                var has_var = false;
                for (old_args, 0..) |arg, i| {
                    new_args[i] = try self.liftFromTypeId(arg, u2i);
                    if (self.containsTyVar(new_args[i])) has_var = true;
                }
                break :blk if (!has_var)
                    try self.addSolverTy(.{ .concrete = ty })
                else
                    try self.addSolverTy(.{ .nominal = .{ .def = n.def, .args = new_args } });
            },
            .cpointer => |c| blk: {
                const inner = try self.liftFromTypeId(c, u2i);
                break :blk if (!self.containsTyVar(inner))
                    try self.addSolverTy(.{ .concrete = ty })
                else
                    try self.addSolverTy(.{ .cpointer = inner });
            },
            .varray => |v| blk: {
                const inner = try self.liftFromTypeId(v.elem, u2i);
                break :blk if (!self.containsTyVar(inner))
                    try self.addSolverTy(.{ .concrete = ty })
                else
                    try self.addSolverTy(.{ .varray = .{ .elem = inner, .len = v.len } });
            },
            .tuple => |t| blk: {
                const elems = self.db.types.getList(t);
                const new_elems = try a.alloc(SolverTyId, elems.len);
                var has_var = false;
                for (elems, 0..) |e, i| {
                    new_elems[i] = try self.liftFromTypeId(e, u2i);
                    if (self.containsTyVar(new_elems[i])) has_var = true;
                }
                break :blk if (!has_var)
                    try self.addSolverTy(.{ .concrete = ty })
                else
                    try self.addSolverTy(.{ .tuple = new_elems });
            },
            .func => |f| blk: {
                const params = self.db.types.getList(f.params);
                const new_params = try a.alloc(SolverTyId, params.len);
                var has_var = false;
                for (params, 0..) |p, i| {
                    new_params[i] = try self.liftFromTypeId(p, u2i);
                    if (self.containsTyVar(new_params[i])) has_var = true;
                }
                const new_ret = try self.liftFromTypeId(f.ret, u2i);
                if (self.containsTyVar(new_ret)) has_var = true;
                break :blk if (!has_var)
                    try self.addSolverTy(.{ .concrete = ty })
                else
                    try self.addSolverTy(.{ .func = .{ .params = new_params, .ret = new_ret, .is_cfunc = f.is_cfunc } });
            },
            else => self.addSolverTy(.{ .concrete = ty }),
        };
    }

    /// 递归判定 `SolverTyId` 内部是否包含待解 `TyVarId`。
    pub fn containsTyVar(self: *const LocalSolver, id: SolverTyId) bool {
        return switch (self.getSolverTy(id)) {
            .ty_var => true,
            .concrete, .quest, .err => false,
            .nominal => |n| {
                for (n.args) |a| if (self.containsTyVar(a)) return true;
                return false;
            },
            .cpointer => |c| self.containsTyVar(c),
            .varray => |v| self.containsTyVar(v.elem),
            .tuple => |elems| {
                for (elems) |e| if (self.containsTyVar(e)) return true;
                return false;
            },
            .func => |f| {
                if (self.containsTyVar(f.ret)) return true;
                for (f.params) |p| if (self.containsTyVar(p)) return true;
                return false;
            },
        };
    }

    /// 将 `SolverTyId` 按 `pack.inst` 展开并降回规范化 `TypeId`（若仍有未解 `TyVarId` 返回 `TypeInterner.err_ty`）。
    pub fn lowerToTypeId(self: *LocalSolver, st: SolverTyId, pack: *const SubstPack) std.mem.Allocator.Error!TypeId {
        return switch (self.getSolverTy(st)) {
            .concrete => |t| t,
            .quest => TypeInterner.quest_ty,
            .err => TypeInterner.err_ty,
            .ty_var => |tv| if (pack.inst.get(tv)) |sols|
                if (sols.len > 0) try self.lowerToTypeId(sols[0], pack) else TypeInterner.err_ty
            else
                TypeInterner.err_ty,
            .nominal => |n| blk: {
                const args = try self.gpa.alloc(TypeId, n.args.len);
                defer self.gpa.free(args);
                for (n.args, 0..) |a, i| args[i] = try self.lowerToTypeId(a, pack);
                const list = try self.db.types.internList(args);
                break :blk try self.db.types.intern(.{ .nominal = .{ .def = n.def, .args = list } });
            },
            .cpointer => |c| try self.db.types.intern(.{ .cpointer = try self.lowerToTypeId(c, pack) }),
            .varray => |v| try self.db.types.intern(.{ .varray = .{ .elem = try self.lowerToTypeId(v.elem, pack), .len = v.len } }),
            .tuple => |elems| blk: {
                const buf = try self.gpa.alloc(TypeId, elems.len);
                defer self.gpa.free(buf);
                for (elems, 0..) |e, i| buf[i] = try self.lowerToTypeId(e, pack);
                break :blk try self.db.types.intern(.{ .tuple = try self.db.types.internList(buf) });
            },
            .func => |f| blk: {
                const buf = try self.gpa.alloc(TypeId, f.params.len);
                defer self.gpa.free(buf);
                for (f.params, 0..) |p, i| buf[i] = try self.lowerToTypeId(p, pack);
                const ret = try self.lowerToTypeId(f.ret, pack);
                break :blk try self.db.types.intern(.{ .func = .{
                    .params = try self.db.types.internList(buf),
                    .ret = ret,
                    .is_cfunc = f.is_cfunc,
                } });
            },
        };
    }

    /// 注入泛型声明的初始 `where` 上界约束到所有活跃分支。
    pub fn initUpperBounds(
        self: *LocalSolver,
        pack: *const SubstPack,
        where_bounds: []const GenericBoundSig,
    ) PlatformError!void {
        try self.ensureInitialBranch();
        const a = self.arena.allocator();
        for (where_bounds) |wb| {
            const subj = try self.liftFromTypeId(wb.subject, &pack.u2i);
            if (self.getSolverTy(subj) != .ty_var) continue;
            const tv = self.getSolverTy(subj).ty_var;
            for (wb.upper_bounds) |ub| {
                const lifted_ub = try self.liftFromTypeId(ub, &pack.u2i);
                for (self.branches.items) |*br| {
                    const gop = try br.bounds.getOrPut(a, tv);
                    if (!gop.found_existing) gop.value_ptr.* = .{};
                    try gop.value_ptr.ubs.append(a, lifted_ub);
                }
            }
        }
    }

    /// 将 `(arg_ty, param_ty)` 按 `Option` 嵌套层数降序、非 `Ideal` 优先、`Ideal` 置后排序，
    /// 并连同可选返回上界 `expected_ret` 依次在所有活跃 `ConstraintBranch` 上执行 `unify`。
    pub fn unifyCallArgs(
        self: *LocalSolver,
        pack: *SubstPack,
        arg_tys: []const SolverTyId,
        param_tys: []const SolverTyId,
        func_ret_ty: SolverTyId,
        expected_ret: ?SolverTyId,
    ) PlatformError!bool {
        _ = pack;
        try self.ensureInitialBranch();
        const count = @min(arg_tys.len, param_tys.len);
        const order = try self.gpa.alloc(usize, count);
        defer self.gpa.free(order);
        for (0..count) |i| order[i] = i;

        // 排序策略：Option 层数降序 -> 非 Ideal 优先 -> Ideal 置后
        var i: usize = 0;
        while (i < count) : (i += 1) {
            var best = i;
            var j: usize = i + 1;
            while (j < count) : (j += 1) {
                if (self.argCheckPriority(arg_tys[order[j]]) > self.argCheckPriority(arg_tys[order[best]])) {
                    best = j;
                }
            }
            std.mem.swap(usize, &order[i], &order[best]);
        }

        for (order) |idx| {
            const ok = try self.unifyAllBranches(arg_tys[idx], param_tys[idx]);
            if (!ok) return false;
        }
        if (expected_ret) |ret_ub| {
            if (self.containsTyVar(func_ret_ty)) {
                const ok = try self.unifyAllBranches(func_ret_ty, ret_ub);
                if (!ok) return false;
            }
        }
        return true;
    }

    /// 计算单个实参在统一化排序中的优先级数值。
    fn argCheckPriority(self: *const LocalSolver, st: SolverTyId) i32 {
        return switch (self.getSolverTy(st)) {
            .concrete => |t| blk: {
                if (self.db.types.hasIdeal(t)) break :blk -10;
                const d = self.db.types.optionDepth(t);
                break :blk @intCast(d + 1);
            },
            else => 0,
        };
    }

    /// 在所有未失败分支上统一 `sub <: sup`；若所有分支均失败返回 `false`。
    fn unifyAllBranches(self: *LocalSolver, sub: SolverTyId, sup: SolverTyId) PlatformError!bool {
        var any_alive = false;
        var br_idx: usize = 0;
        while (br_idx < self.branches.items.len) : (br_idx += 1) {
            if (self.branches.items[br_idx].failed) continue;
            const ok = try self.unifyInBranch(br_idx, sub, sup, 0);
            if (!ok) {
                self.branches.items[br_idx].failed = true;
            } else {
                any_alive = true;
            }
        }
        return any_alive;
    }

    /// 在指定分支中执行单对 `(sub, sup)` 约束收集（支持 `Option` 剥离、名义不变双向约束、函数逆变与 `promote`）。
    fn unifyInBranch(
        self: *LocalSolver,
        br_idx: usize,
        sub: SolverTyId,
        sup: SolverTyId,
        depth: u32,
    ) PlatformError!bool {
        if (depth > 32) return true;
        const a = self.arena.allocator();
        const memo_key: u64 = (@as(u64, sub.index()) << 32) | sup.index();
        if (self.branches.items[br_idx].unified_memo.contains(memo_key)) return true;
        try self.branches.items[br_idx].unified_memo.put(a, memo_key, {});

        const s_data = self.getSolverTy(sub);
        const t_data = self.getSolverTy(sup);

        if (s_data == .quest or t_data == .quest) return true;
        if (s_data == .err or t_data == .err) return false;

        // 左侧为占位符：记录上界 sup
        if (s_data == .ty_var) {
            const tv = s_data.ty_var;
            const gop = try self.branches.items[br_idx].bounds.getOrPut(a, tv);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            try gop.value_ptr.ubs.append(a, sup);
            return true;
        }
        // 右侧为占位符：记录下界 sub
        if (t_data == .ty_var) {
            const tv = t_data.ty_var;
            const gop = try self.branches.items[br_idx].bounds.getOrPut(a, tv);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            if (s_data == .concrete and s_data.concrete == TypeInterner.nothing_ty) {
                self.branches.items[br_idx].has_nothing = true;
            } else {
                try gop.value_ptr.lbs.append(a, sub);
            }
            return true;
        }

        // 两侧均为 concrete 直接走标准 isSubtype
        if (s_data == .concrete and t_data == .concrete) {
            return subtype_mod.isSubtype(self.db, self.file, s_data.concrete, t_data.concrete, .{});
        }

        // 右侧为 Option<...> 且嵌套层数严格大于左侧时剥离外层 Option（支持 T -> Option<TyVar> 装箱）
        if (self.db.types.known.option_enum) |opt_def| {
            if (t_data == .nominal and DefId.eql(t_data.nominal.def, opt_def) and t_data.nominal.args.len == 1) {
                if (s_data == .concrete) {
                    if (self.db.types.unwrapOptionOnce(s_data.concrete)) |s_inner| {
                        const lifted_inner = try self.addSolverTy(.{ .concrete = s_inner });
                        return self.unifyInBranch(br_idx, lifted_inner, t_data.nominal.args[0], depth + 1);
                    }
                    return self.unifyInBranch(br_idx, sub, t_data.nominal.args[0], depth + 1);
                }
            }
        }

        // 左侧为 concrete 名义类型、右侧为含变量的 nominal（按名义不变性双向统一，支持 promote 提升）
        if (s_data == .concrete and t_data == .nominal) {
            const promoted = try subtype_mod.promote(self.db, self.gpa, self.file, s_data.concrete, t_data.nominal.def);
            defer self.gpa.free(promoted);
            if (promoted.len == 0) return false;
            const p_nom = self.db.types.get(promoted[0]).nominal;
            const p_args = self.db.types.getList(p_nom.args);
            if (p_args.len != t_data.nominal.args.len) return false;
            for (p_args, t_data.nominal.args) |pa, ta| {
                const s_pa = try self.addSolverTy(.{ .concrete = pa });
                if (!try self.unifyInBranch(br_idx, s_pa, ta, depth + 1)) return false;
                if (!try self.unifyInBranch(br_idx, ta, s_pa, depth + 1)) return false;
            }
            return true;
        }

        // 两侧均为 nominal：同名按实参不变双向统一
        if (s_data == .nominal and t_data == .nominal) {
            if (!DefId.eql(s_data.nominal.def, t_data.nominal.def)) return false;
            if (s_data.nominal.args.len != t_data.nominal.args.len) return false;
            for (s_data.nominal.args, t_data.nominal.args) |sa, ta| {
                if (!try self.unifyInBranch(br_idx, sa, ta, depth + 1)) return false;
                if (!try self.unifyInBranch(br_idx, ta, sa, depth + 1)) return false;
            }
            return true;
        }

        // 两侧为函数类型（含 concrete 函数与嵌套变量函数）：参数逆变，返回协变
        if ((s_data == .func or (s_data == .concrete and self.db.types.get(s_data.concrete) == .func)) and
            (t_data == .func or (t_data == .concrete and self.db.types.get(t_data.concrete) == .func)))
        {
            const s_params = try self.extractFuncParams(sub);
            const t_params = try self.extractFuncParams(sup);
            if (s_params.len != t_params.len) return false;
            for (s_params, t_params) |sp, tp| {
                if (!try self.unifyInBranch(br_idx, tp, sp, depth + 1)) return false;
            }
            const s_ret = try self.extractFuncRet(sub);
            const t_ret = try self.extractFuncRet(sup);
            return self.unifyInBranch(br_idx, s_ret, t_ret, depth + 1);
        }

        // 两侧为元组类型：元素逐位协变
        if ((s_data == .tuple or (s_data == .concrete and self.db.types.get(s_data.concrete) == .tuple)) and
            (t_data == .tuple or (t_data == .concrete and self.db.types.get(t_data.concrete) == .tuple)))
        {
            const s_elems = try self.extractTupleElems(sub);
            const t_elems = try self.extractTupleElems(sup);
            if (s_elems.len != t_elems.len) return false;
            for (s_elems, t_elems) |se, te| {
                if (!try self.unifyInBranch(br_idx, se, te, depth + 1)) return false;
            }
            return true;
        }

        // 两侧为 CPointer<T>：元素类型双向不变统一
        if ((s_data == .cpointer or (s_data == .concrete and self.db.types.get(s_data.concrete) == .cpointer)) and
            (t_data == .cpointer or (t_data == .concrete and self.db.types.get(t_data.concrete) == .cpointer)))
        {
            const s_elem = switch (s_data) {
                .cpointer => |e| e,
                .concrete => |t| try self.addSolverTy(.{ .concrete = self.db.types.get(t).cpointer }),
                else => unreachable,
            };
            const t_elem = switch (t_data) {
                .cpointer => |e| e,
                .concrete => |t| try self.addSolverTy(.{ .concrete = self.db.types.get(t).cpointer }),
                else => unreachable,
            };
            if (!try self.unifyInBranch(br_idx, s_elem, t_elem, depth + 1)) return false;
            return self.unifyInBranch(br_idx, t_elem, s_elem, depth + 1);
        }

        // 两侧为 VArray<T, $N>：长度相等且元素类型双向不变统一
        if ((s_data == .varray or (s_data == .concrete and self.db.types.get(s_data.concrete) == .varray)) and
            (t_data == .varray or (t_data == .concrete and self.db.types.get(t_data.concrete) == .varray)))
        {
            const s_len: u64 = switch (s_data) {
                .varray => |v| v.len,
                .concrete => |t| self.db.types.get(t).varray.len,
                else => unreachable,
            };
            const t_len: u64 = switch (t_data) {
                .varray => |v| v.len,
                .concrete => |t| self.db.types.get(t).varray.len,
                else => unreachable,
            };
            if (s_len != t_len) return false;
            const s_elem = switch (s_data) {
                .varray => |v| v.elem,
                .concrete => |t| try self.addSolverTy(.{ .concrete = self.db.types.get(t).varray.elem }),
                else => unreachable,
            };
            const t_elem = switch (t_data) {
                .varray => |v| v.elem,
                .concrete => |t| try self.addSolverTy(.{ .concrete = self.db.types.get(t).varray.elem }),
                else => unreachable,
            };
            if (!try self.unifyInBranch(br_idx, s_elem, t_elem, depth + 1)) return false;
            return self.unifyInBranch(br_idx, t_elem, s_elem, depth + 1);
        }

        return false;
    }

    /// 提取函数类型（concrete 或 solver）的形参切片（借用自 `arena`）。
    fn extractFuncParams(self: *LocalSolver, id: SolverTyId) std.mem.Allocator.Error![]const SolverTyId {
        return switch (self.getSolverTy(id)) {
            .func => |f| f.params,
            .concrete => |t| blk: {
                const ps = self.db.types.getList(self.db.types.get(t).func.params);
                const out = try self.arena.allocator().alloc(SolverTyId, ps.len);
                for (ps, 0..) |p, i| out[i] = try self.addSolverTy(.{ .concrete = p });
                break :blk out;
            },
            else => &.{},
        };
    }

    /// 提取函数类型（concrete 或 solver）的返回类型。
    fn extractFuncRet(self: *LocalSolver, id: SolverTyId) std.mem.Allocator.Error!SolverTyId {
        return switch (self.getSolverTy(id)) {
            .func => |f| f.ret,
            .concrete => |t| self.addSolverTy(.{ .concrete = self.db.types.get(t).func.ret }),
            else => self.addSolverTy(.{ .err = {} }),
        };
    }

    /// 提取元组类型的元素切片（借用自 `arena`）。
    fn extractTupleElems(self: *LocalSolver, id: SolverTyId) std.mem.Allocator.Error![]const SolverTyId {
        return switch (self.getSolverTy(id)) {
            .tuple => |elems| elems,
            .concrete => |t| blk: {
                const es = self.db.types.getList(self.db.types.get(t).tuple);
                const out = try self.arena.allocator().alloc(SolverTyId, es.len);
                for (es, 0..) |e, i| out[i] = try self.addSolverTy(.{ .concrete = e });
                break :blk out;
            },
            else => &.{},
        };
    }

    /// 对每个有效分支求解约束，按优先级（合法非 `Ideal` 下界 `Join` -> 具体化含 `Ideal` 下界 -> 上界 `Meet`）产出结果并消除残留 `Ideal` 类型。
    pub fn solve(
        self: *LocalSolver,
        pack: *SubstPack,
        allow_partial: bool,
    ) PlatformError!SolveStatus {
        const a = self.arena.allocator();
        var best_branch: ?usize = null;
        for (self.branches.items, 0..) |br, idx| {
            if (!br.failed) {
                best_branch = idx;
                break;
            }
        }
        const br_idx = best_branch orelse return .conflict;
        const br = &self.branches.items[br_idx];

        var all_solved = true;
        var iter = pack.u2i.valueIterator();
        while (iter.next()) |tv_ptr| {
            const tv = tv_ptr.*;
            if (pack.inst.contains(tv)) continue;
            const b = br.bounds.get(tv) orelse {
                all_solved = false;
                continue;
            };

            if (b.eq) |eq_ty| {
                const concrete = try self.lowerToTypeId(eq_ty, pack);
                if (concrete != TypeInterner.err_ty) {
                    const final_ty = try self.db.types.replaceIdeal(concrete);
                    const sol = try self.addSolverTy(.{ .concrete = final_ty });
                    try pack.inst.put(self.gpa, tv, try a.dupe(SolverTyId, &.{sol}));
                    continue;
                }
            }

            // 收集具体下界并计算 Join
            var concrete_lbs: std.ArrayListUnmanaged(TypeId) = .empty;
            defer concrete_lbs.deinit(self.gpa);
            for (b.lbs.items) |lb| {
                if (!self.containsTyVar(lb)) {
                    const c = try self.lowerToTypeId(lb, pack);
                    if (c != TypeInterner.err_ty and c != TypeInterner.quest_ty) {
                        try concrete_lbs.append(self.gpa, c);
                    }
                }
            }

            var chosen: ?TypeId = null;
            if (concrete_lbs.items.len > 0) {
                switch (try join_meet_mod.computeJoin(self.db, self.file, concrete_lbs.items)) {
                    .ok => |j| chosen = try self.db.types.replaceIdeal(j),
                    else => {},
                }
            }

            // 无有效下界时尝试从具体上界计算 Meet
            if (chosen == null) {
                var concrete_ubs: std.ArrayListUnmanaged(TypeId) = .empty;
                defer concrete_ubs.deinit(self.gpa);
                for (b.ubs.items) |ub| {
                    if (!self.containsTyVar(ub)) {
                        const c = try self.lowerToTypeId(ub, pack);
                        if (c != TypeInterner.err_ty and c != TypeInterner.quest_ty) {
                            try concrete_ubs.append(self.gpa, c);
                        }
                    }
                }
                if (concrete_ubs.items.len > 0) {
                    switch (try join_meet_mod.computeMeet(self.db, self.file, concrete_ubs.items)) {
                        .ok => |m| chosen = try self.db.types.replaceIdeal(m),
                        else => {},
                    }
                }
            }

            if (chosen) |c_ty| {
                const sol = try self.addSolverTy(.{ .concrete = c_ty });
                try pack.inst.put(self.gpa, tv, try a.dupe(SolverTyId, &.{sol}));
            } else {
                all_solved = false;
            }
        }

        if (all_solved) return .solved;
        return if (allow_partial) .partial else .conflict;
    }

    /// 使用最终具体化映射校验泛型声明、宿主名义类型及宿主 `extend` 的全部 `where` 约束（`allow_option_box = false`）。
    pub fn checkWhereConstraints(
        self: *LocalSolver,
        bounds: []const GenericBoundSig,
        pack: *const SubstPack,
        diagnostics: ?*std.ArrayListUnmanaged(common.Diagnostic),
        diag_arena: ?std.mem.Allocator,
        call_range: common.TextRange,
    ) PlatformError!bool {
        const opts: subtype_mod.SubtypeOptions = .{ .implicit_boxed = true, .allow_option_box = false };
        var all_ok = true;
        for (bounds) |wb| {
            const subj_st = try self.liftFromTypeId(wb.subject, &pack.u2i);
            const subj_ty = try self.lowerToTypeId(subj_st, pack);
            if (subj_ty == TypeInterner.err_ty) continue;
            for (wb.upper_bounds) |ub| {
                const ub_st = try self.liftFromTypeId(ub, &pack.u2i);
                const ub_ty = try self.lowerToTypeId(ub_st, pack);
                if (ub_ty == TypeInterner.err_ty) continue;
                if (!try subtype_mod.isSubtype(self.db, self.file, subj_ty, ub_ty, opts)) {
                    all_ok = false;
                    if (diagnostics) |diags| {
                        try diags.append(diag_arena orelse self.gpa, .{
                            .file = self.file,
                            .range = call_range,
                            .severity = .err,
                            .source = .typeck,
                            .message = "泛型类型参数不满足 where 约束上界",
                        });
                    }
                }
            }
        }
        return all_ok;
    }

    /// 在泛型多轮迭代中将嵌套求解函数类型 `func_ty` 中尚未解出的返回位置 `TyVarId` 替换为 `SolverTyData.quest`。
    /// 仅当全部形参类型均不含未解 `TyVarId` 时返回转换后的 `SolverTyId`；否则返回 `null`。
    pub fn unsolvedAsQuest(
        self: *LocalSolver,
        func_ty: SolverTyId,
        pack: *const SubstPack,
    ) std.mem.Allocator.Error!?SolverTyId {
        const data = self.getSolverTy(func_ty);
        if (data != .func) return null;
        const a = self.arena.allocator();
        const params_out = try a.alloc(SolverTyId, data.func.params.len);
        for (data.func.params, 0..) |p, i| {
            const sub_p = try self.substituteSolved(p, pack);
            if (self.containsTyVar(sub_p)) return null;
            params_out[i] = sub_p;
        }
        const sub_ret = try self.substituteSolved(data.func.ret, pack);
        const quest_ret = if (self.containsTyVar(sub_ret))
            try self.addSolverTy(.{ .quest = {} })
        else
            sub_ret;
        return try self.addSolverTy(.{ .func = .{
            .params = params_out,
            .ret = quest_ret,
            .is_cfunc = data.func.is_cfunc,
        } });
    }

    /// 将 `SolverTyId` 中已在 `pack.inst` 中解出的 `TyVarId` 替换为对应解，未解变量保持原状。
    fn substituteSolved(self: *LocalSolver, id: SolverTyId, pack: *const SubstPack) std.mem.Allocator.Error!SolverTyId {
        const a = self.arena.allocator();
        return switch (self.getSolverTy(id)) {
            .ty_var => |tv| if (pack.inst.get(tv)) |sols|
                if (sols.len > 0) sols[0] else id
            else
                id,
            .nominal => |n| blk: {
                const args = try a.alloc(SolverTyId, n.args.len);
                for (n.args, 0..) |arg, i| args[i] = try self.substituteSolved(arg, pack);
                break :blk try self.addSolverTy(.{ .nominal = .{ .def = n.def, .args = args } });
            },
            .cpointer => |elem| try self.addSolverTy(.{ .cpointer = try self.substituteSolved(elem, pack) }),
            .varray => |v| try self.addSolverTy(.{ .varray = .{
                .elem = try self.substituteSolved(v.elem, pack),
                .len = v.len,
            } }),
            .tuple => |elems| blk: {
                const buf = try a.alloc(SolverTyId, elems.len);
                for (elems, 0..) |e, i| buf[i] = try self.substituteSolved(e, pack);
                break :blk try self.addSolverTy(.{ .tuple = buf });
            },
            .func => |f| blk: {
                const buf = try a.alloc(SolverTyId, f.params.len);
                for (f.params, 0..) |p, i| buf[i] = try self.substituteSolved(p, pack);
                break :blk try self.addSolverTy(.{ .func = .{
                    .params = buf,
                    .ret = try self.substituteSolved(f.ret, pack),
                    .is_cfunc = f.is_cfunc,
                } });
            },
            else => id,
        };
    }

    /// 供重载多分支比较数值类型优先级的辅助转发。
    pub inline fn compareNumPriority(a: ids.PrimKind, b: ids.PrimKind) std.math.Order {
        return literal_mod.compareNumericPriority(a, b);
    }
};
