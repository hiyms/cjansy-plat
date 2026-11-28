// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 顶层声明项双向类型检查、晚绑定决议与按需省略类型推导（`typeCheckItem`、`ItemChecker`）。

const std = @import("std");
const common = @import("common");
const frontend = @import("frontend");
const ids = @import("../ids.zig");
const file_state_mod = @import("../db/FileState.zig");
const pkg_state_mod = @import("../db/PackageState.zig");
const db_mod = @import("../db/Database.zig");
const scope_mod = @import("../resolve/scope.zig");
const access_mod = @import("../resolve/access.zig");
const package_mod = @import("../resolve/package.zig");
const type_interner_mod = @import("../interner/TypeInterner.zig");
const subtype_mod = @import("subtype.zig");
const join_meet_mod = @import("join_meet.zig");
const literal_mod = @import("literal.zig");
const overload_mod = @import("overload.zig");
const lambda_mod = @import("lambda.zig");
const builtin_expr_mod = @import("builtin_expr.zig");

const AccessContext = ids.AccessContext;
const Database = db_mod.Database;
const DefId = ids.DefId;
const EarlyCandidate = scope_mod.EarlyCandidate;
const FileResolveData = scope_mod.FileResolveData;
const GlobalItemId = ids.GlobalItemId;
const InferredDep = db_mod.InferredDep;
const InternedId = ids.InternedId;
const LocalSymId = ids.LocalSymId;
const PackageState = pkg_state_mod.PackageState;
const PlatformError = file_state_mod.PlatformError;
const PrimKind = ids.PrimKind;
const ReferenceKind = ids.ReferenceKind;
const ResolvedIdentOccurrence = scope_mod.ResolvedIdentOccurrence;
const SymbolRef = ids.SymbolRef;
const TypeId = ids.TypeId;
const TypeInterner = type_interner_mod.TypeInterner;
const TypeListId = ids.TypeListId;

/// 表达式综合推导位置标记（与 `cangjie_compiler` 的 `SynPos` 一致）。
pub const SynPos = enum(u8) {
    none,
    expr_arg,
    /// 语句或 `Unit` 目标位置：`if`/`try` 分支值不参与消费，整体类型为 `Unit`。
    unused,
    /// 语句块末尾表达式位置。
    implicit_return,
    /// 赋值左值位置。
    left_value,
};

/// 跨项对外引用边（供 `references`、`rename`、`callHierarchy` 与静态检查使用）。
pub const OutgoingSymbolRef = struct {
    target: DefId,
    range: common.TextRange,
    kind: ReferenceKind,
};

/// 单个顶层声明项类型检查与晚绑定的不可变只读产物（分配于 `FileQueryState.sema_arena`）。
pub const ItemTypeckData = struct {
    global_item: GlobalItemId,
    file_version: u32,
    /// 记录最后一次核验 `inferred_deps` 通过时的 `Database.revision`。
    verified_revision: u64,

    /// 长度等于 `LoweredItem.nodes.len`，按 `HirId.index()` 以 `O(1)` 查询项内任意节点的最终 `TypeId`。
    node_types: []const TypeId,
    /// 晚绑定决议出的节点目标（成员字段/方法、重载函数、运算符重载、无限定枚举构造器）。
    late_bindings: std.AutoHashMapUnmanaged(common.HirId, SymbolRef) = .empty,
    /// 泛型调用或构造表达式推导出的最终类型参数列表（按调用点 `HirId` 查询）。
    instantiated_type_args: std.AutoHashMapUnmanaged(common.HirId, TypeListId) = .empty,
    /// 本项内全部晚绑定段级定位记录（按 `range.start` 升序）。
    late_occurrences: []const ResolvedIdentOccurrence = &.{},
    /// 按目标 `DefId` 记录的对外引用边。
    outgoing_refs: []const OutgoingSymbolRef = &.{},
    /// 检查本项期间实际观测过的跨项省略类型推导依赖列表。
    inferred_deps: []const InferredDep = &.{},
    diagnostics: []const common.Diagnostic = &.{},

    /// 按项内 `HirId` 在 `O(1)` 时间内获取节点类型。
    pub inline fn typeOf(self: *const ItemTypeckData, hir: common.HirId) ?TypeId {
        const idx = hir.index();
        return if (idx < self.node_types.len) self.node_types[idx] else null;
    }
};

/// 单个顶层声明项的双向类型检查器上下文。
pub const ItemChecker = struct {
    db: *Database,
    arena: std.mem.Allocator,
    scratch: std.heap.ArenaAllocator,
    global_item: GlobalItemId,
    resolve_data: *const FileResolveData,
    pkg_state: *const PackageState,
    lowered_item: *const frontend.LoweredItem,

    node_types: []TypeId,
    local_types: std.AutoHashMapUnmanaged(u32, TypeId) = .empty,
    local_ret_types: std.AutoHashMapUnmanaged(u32, TypeId) = .empty,
    late_bindings: std.AutoHashMapUnmanaged(common.HirId, SymbolRef) = .empty,
    instantiated_type_args: std.AutoHashMapUnmanaged(common.HirId, TypeListId) = .empty,
    late_occurrences: std.ArrayListUnmanaged(ResolvedIdentOccurrence) = .empty,
    outgoing_refs: std.ArrayListUnmanaged(OutgoingSymbolRef) = .empty,
    inferred_deps: std.ArrayListUnmanaged(InferredDep) = .empty,
    diagnostics: std.ArrayListUnmanaged(common.Diagnostic) = .empty,

    /// 当前所处的封闭名义类型或扩展定义（用于 `this`、`super` 与可见性检查）。
    enclosing_nominal: ?DefId = null,
    /// 当前被检查可调用体的返回类型目标（`null` 表示正在推导省略返回类型）。
    current_expected_ret: ?TypeId = null,
    /// 当前省略返回类型函数体收集到的全部 `return` 表达式类型。
    collected_returns: ?*std.ArrayListUnmanaged(TypeId) = null,
    /// 当前是否正处于函数实参位置的 Lambda 检查深度。
    in_func_arg_lambda_depth: u32 = 0,
    /// 当前是否在循环体内（检查 `break`/`continue`）。
    loop_depth: u32 = 0,

    /// 初始化项级检查器；返回后须调用 `deinit` 释放临时缓冲。
    pub fn init(
        db: *Database,
        arena: std.mem.Allocator,
        global_item: GlobalItemId,
        resolve_data: *const FileResolveData,
        pkg_state: *const PackageState,
        lowered_item: *const frontend.LoweredItem,
    ) std.mem.Allocator.Error!ItemChecker {
        const node_types = try arena.alloc(TypeId, lowered_item.nodes.len);
        @memset(node_types, TypeInterner.err_ty);
        return .{
            .db = db,
            .arena = arena,
            .scratch = .init(db.gpa),
            .global_item = global_item,
            .resolve_data = resolve_data,
            .pkg_state = pkg_state,
            .lowered_item = lowered_item,
            .node_types = node_types,
        };
    }

    /// 释放检查器内部临时容器（写入 `arena` 的只读产物不在此释放）。
    pub fn deinit(self: *ItemChecker) void {
        self.local_types.deinit(self.db.gpa);
        self.local_ret_types.deinit(self.db.gpa);
        self.scratch.deinit();
    }

    /// 写入指定项内 `HirId` 的最终语义类型。
    pub inline fn setNodeType(self: *ItemChecker, hir: common.HirId, ty: TypeId) void {
        const idx = hir.index();
        if (idx < self.node_types.len) {
            self.node_types[idx] = ty;
        }
    }

    /// 记录局部符号声明 `HirId` 对应的推导类型（同步映射至 `LocalSymbol.id.idx`）。
    pub fn setLocalTypeByDeclHir(self: *ItemChecker, decl_hir: common.HirId, ty: TypeId) std.mem.Allocator.Error!void {
        const key: common.HirKey = .{ .item = self.global_item.item, .hir = decl_hir };
        for (self.resolve_data.locals) |loc| {
            if (common.HirKey.eql(loc.decl_key, key)) {
                try self.local_types.put(self.db.gpa, loc.id.idx, ty);
            }
        }
    }

    /// 获取局部符号当前已知类型（优先推导结果，其次显式注解，局部函数返回对应 `FuncTy`）。
    pub fn getLocalType(self: *ItemChecker, loc_id: LocalSymId) PlatformError!TypeId {
        if (self.local_types.get(loc_id.idx)) |ty| return ty;
        const loc = self.resolve_data.getLocal(loc_id.idx) orelse return TypeInterner.err_ty;
        if (loc.annotated_ty) |aty| return aty;
        if (loc.kind == .func_) {
            if (loc.callable_sig_idx) |sidx| {
                if (self.resolve_data.getLocalCallable(sidx)) |sig| {
                    return try self.funcTypeFromCallableSig(sig, self.local_ret_types.get(loc_id.idx));
                }
            }
        }
        return TypeInterner.err_ty;
    }

    /// 获取局部函数的返回类型（显式返回类型或已推导返回类型）。
    pub fn getLocalReturnType(self: *ItemChecker, loc_id: LocalSymId) PlatformError!TypeId {
        if (self.local_ret_types.get(loc_id.idx)) |r| return r;
        const loc = self.resolve_data.getLocal(loc_id.idx) orelse return TypeInterner.err_ty;
        if (loc.callable_sig_idx) |sidx| {
            if (self.resolve_data.getLocalCallable(sidx)) |sig| {
                if (sig.explicit_ret) |er| return er;
            }
        }
        return TypeInterner.unit_ty;
    }

    /// 发射一条类型检查诊断并写入本项诊断列表。
    pub fn emitDiag(
        self: *ItemChecker,
        range: common.TextRange,
        severity: common.Severity,
        message: []const u8,
    ) std.mem.Allocator.Error!void {
        try self.diagnostics.append(self.arena, .{
            .file = self.global_item.file,
            .range = range,
            .severity = severity,
            .source = .typeck,
            .message = message,
        });
    }

    /// 记录晚绑定段级定位并按需登记跨项引用边。
    pub fn recordLateRef(
        self: *ItemChecker,
        hir: ?common.HirId,
        range: common.TextRange,
        target: SymbolRef,
        kind: ReferenceKind,
    ) std.mem.Allocator.Error!void {
        if (hir) |h| {
            try self.late_bindings.put(self.arena, h, target);
        }
        if (!range.isEmpty()) {
            try self.late_occurrences.append(self.arena, .{
                .range = range,
                .target = target,
                .kind = kind,
                .owner_def = self.enclosing_nominal,
            });
            if (target == .def) {
                try self.outgoing_refs.append(self.arena, .{
                    .target = target.def,
                    .range = range,
                    .kind = kind,
                });
            }
        }
    }

    /// 构造当前位置的访问权限上下文 `AccessContext`。
    pub fn currentAccessContext(self: *const ItemChecker) AccessContext {
        return .{
            .module_id = self.pkg_state.module_id,
            .pkg_id = self.pkg_state.pkg_id,
            .file_id = self.global_item.file,
            .enclosing_defs = if (self.enclosing_nominal != null) @as(*const [1]DefId, &self.enclosing_nominal.?) else &.{},
        };
    }

    /// 查询可调用声明的返回类型，并自动向当前项的 `inferred_deps` 登记省略类型依赖。
    pub fn queryReturnType(self: *ItemChecker, def_id: DefId) PlatformError!TypeId {
        const ret = try self.db.returnTypeOf(def_id);
        const ps = self.db.packageState(def_id.pkg) catch return ret;
        if (ps.callable_headers.get(def_id.idx)) |sig| {
            if (sig.explicit_ret == null) {
                try self.inferred_deps.append(self.arena, .{
                    .def = def_id,
                    .observed_ty = ret,
                    .kind = .return_ty,
                });
            }
        }
        return ret;
    }

    /// 查询顶层或成员变量的类型，并自动向当前项的 `inferred_deps` 登记省略类型依赖。
    pub fn queryVarType(self: *ItemChecker, def_id: DefId) PlatformError!TypeId {
        const ty = try self.db.varTypeOf(def_id);
        const ps = self.db.packageState(def_id.pkg) catch return ty;
        if (!ps.explicit_var_types.contains(def_id.idx)) {
            try self.inferred_deps.append(self.arena, .{
                .def = def_id,
                .observed_ty = ty,
                .kind = .var_ty,
            });
        }
        return ty;
    }

    /// 由 `CallableHeaderSig` 构造对应 `FuncTy`。
    fn funcTypeFromCallableSig(self: *ItemChecker, sig: *const pkg_state_mod.CallableHeaderSig, ret_override: ?TypeId) PlatformError!TypeId {
        const p_tys = try self.db.gpa.alloc(TypeId, sig.params.len);
        defer self.db.gpa.free(p_tys);
        for (sig.params, 0..) |p, i| p_tys[i] = p.ty;
        const p_list = try self.db.types.internList(p_tys);
        const ret = ret_override orelse sig.explicit_ret orelse switch (sig.owner) {
            .def => |d| try self.queryReturnType(d),
            .local => |l| try self.getLocalReturnType(l),
        };
        return self.db.types.intern(.{ .func = .{
            .params = p_list,
            .ret = ret,
            .is_cfunc = false,
        } });
    }

    /// 综合检查表达式并返回其推导出的 `TypeId`（对应 `cangjie_compiler` 的 `Synthesize`）。
    pub fn synthExpr(self: *ItemChecker, expr: *const common.HirExpr, pos: SynPos) PlatformError!TypeId {
        const ty = try self.synthExprInner(expr, pos);
        self.setNodeType(expr.id(), ty);
        return ty;
    }

    /// 带上下文期望类型的双向检查入口（对应 `cangjie_compiler` 的 `Check`）。
    pub fn checkExpr(self: *ItemChecker, expr: *const common.HirExpr, expected: TypeId) PlatformError!TypeId {
        if (expected == TypeInterner.err_ty or expected == TypeInterner.quest_ty) {
            return self.synthExpr(expr, .none);
        }
        const ty = try self.checkExprInner(expr, expected);
        self.setNodeType(expr.id(), ty);
        return ty;
    }

    /// `checkExpr` 内部实现：按节点类型分派向下检查、字面量窄化、Lambda 形参注入与子类型校验。
    fn checkExprInner(self: *ItemChecker, expr: *const common.HirExpr, expected: TypeId) PlatformError!TypeId {
        const db = self.db;
        const unboxed_exp = db.types.unboxOption(expected);

        switch (expr.*) {
            .int_lit => |il| {
                if (il.suffix != null) {
                    const syn = try self.synthIntLit(il);
                    try self.checkAssignable(expr.range(), syn, expected);
                    return syn;
                }
                const target_ty = switch (db.types.get(unboxed_exp)) {
                    .prim => |pk| if (pk.isInteger()) unboxed_exp else TypeInterner.int64_ty,
                    else => TypeInterner.int64_ty,
                };
                if (literal_mod.checkNumericLiteralRange(db.config.target, il.text, false, target_ty) != .ok) {
                    try self.emitDiag(il.range, .err, "整数字面量超出目标整数类型表示范围");
                }
                if (db.types.get(unboxed_exp) == .prim and db.types.get(unboxed_exp).prim.isInteger()) {
                    return expected;
                }
                try self.checkAssignable(il.range, TypeInterner.ideal_int_ty, expected);
                return target_ty;
            },
            .float_lit => |fl| {
                if (fl.suffix != null) {
                    const syn = try self.synthFloatLit(fl);
                    try self.checkAssignable(expr.range(), syn, expected);
                    return syn;
                }
                const target_ty = switch (db.types.get(unboxed_exp)) {
                    .prim => |pk| if (pk.isFloat()) unboxed_exp else TypeInterner.float64_ty,
                    else => TypeInterner.float64_ty,
                };
                const st = literal_mod.checkNumericLiteralRange(db.config.target, fl.text, false, target_ty);
                if (st == .float_overflow) {
                    try self.emitDiag(fl.range, .err, "浮点字面量超出目标浮点类型范围");
                }
                if (db.types.get(unboxed_exp) == .prim and db.types.get(unboxed_exp).prim.isFloat()) {
                    return expected;
                }
                try self.checkAssignable(fl.range, TypeInterner.ideal_float_ty, expected);
                return target_ty;
            },
            .unary => |u| {
                // 处理负数字面量 `-128i8` / `-128` 以保证最小值不误报溢出
                if (u.op == .neg and u.operand.* == .int_lit and u.operand.int_lit.suffix == null) {
                    if (db.types.get(unboxed_exp) == .prim and db.types.get(unboxed_exp).prim.isInteger()) {
                        const st = literal_mod.checkNumericLiteralRange(db.config.target, u.operand.int_lit.text, true, unboxed_exp);
                        if (st != .ok) {
                            try self.emitDiag(u.range, .err, "负整数字面量超出目标整数类型表示范围");
                        }
                        self.setNodeType(u.operand.id(), unboxed_exp);
                        return expected;
                    }
                }
                const syn = try self.synthExpr(expr, .none);
                try self.checkAssignable(u.range, syn, expected);
                return syn;
            },
            .lambda => |lam| return lambda_mod.checkLambda(self, &lam, expected),
            .array_lit => |al| return builtin_expr_mod.checkArrayLit(self, &al, expected),
            .range_expr => |re| return builtin_expr_mod.checkRangeExpr(self, &re, expected),
            .try_expr => |te| return builtin_expr_mod.checkTryExpr(self, &te, expected, .none),
            .spawn => |sp| return builtin_expr_mod.checkSpawnExpr(self, &sp, expected),
            .synchronized => |sy| return builtin_expr_mod.checkSynchronizedExpr(self, &sy, expected, .none),
            .block => |*blk| return self.checkBlock(blk, expected),
            .if_expr => |ie| return self.checkIfExpr(&ie, expected, .none),
            .match_expr => |me| return self.checkMatchExpr(&me, expected, .none),
            .call => |c| return self.checkCallExpr(&c, expected),
            .tuple_lit => |t| {
                if (db.types.get(unboxed_exp) == .tuple) {
                    const exp_elems = db.types.getList(db.types.get(unboxed_exp).tuple);
                    if (exp_elems.len == t.elements.len) {
                        for (t.elements, exp_elems) |*el, ety| {
                            _ = try self.checkExpr(el, ety);
                        }
                        return expected;
                    }
                }
                const syn = try self.synthExpr(expr, .none);
                try self.checkAssignable(t.range, syn, expected);
                return syn;
            },
            .binary => |b| {
                if (b.op == .coalescing) {
                    return builtin_expr_mod.checkCoalescing(self, &b, expected);
                }
                const syn = try self.checkBinaryExpr(&b, expected);
                try self.checkAssignable(b.range, syn, expected);
                return syn;
            },
            .path => |p| {
                const syn = try self.resolvePathExpr(&p, expected);
                try self.checkAssignable(p.range, syn, expected);
                return syn;
            },
            else => {
                const syn = try self.synthExpr(expr, if (expected == TypeInterner.unit_ty) .unused else .none);
                try self.checkAssignable(expr.range(), syn, expected);
                return syn;
            },
        }
    }

    /// 校验 `actual <: expected` 并在失败时发射诊断。
    fn checkAssignable(self: *ItemChecker, range: common.TextRange, actual: TypeId, expected: TypeId) PlatformError!void {
        if (actual == TypeInterner.err_ty or expected == TypeInterner.err_ty or expected == TypeInterner.quest_ty) return;
        if (!try subtype_mod.isSubtype(self.db, self.global_item.file, actual, expected, .{})) {
            try self.emitDiag(range, .err, "表达式类型与期望类型不兼容");
        }
    }

    /// `synthExpr` 内部分派实现。
    fn synthExprInner(self: *ItemChecker, expr: *const common.HirExpr, pos: SynPos) PlatformError!TypeId {
        const db = self.db;
        switch (expr.*) {
            .int_lit => |il| return self.synthIntLit(il),
            .float_lit => |fl| return self.synthFloatLit(fl),
            .rune_lit => |rl| return if (rl.is_byte) TypeInterner.uint8_ty else TypeInterner.rune_ty,
            .string_lit => return db.types.internString(),
            .str_interp => |si| return builtin_expr_mod.checkStrInterp(self, &si),
            .bool_lit => return TypeInterner.bool_ty,
            .unit_lit => return TypeInterner.unit_ty,
            .wildcard => return TypeInterner.err_ty,
            .path => |p| return self.resolvePathExpr(&p, null),
            .field => |f| return self.resolveFieldExpr(&f, null),
            .optional => |o| {
                const op_ty = try self.synthExpr(o.operand, .none);
                return db.types.unwrapOptionOnce(op_ty) orelse op_ty;
            },
            .call => |c| return self.checkCallExpr(&c, null),
            .index => |idx| return self.checkIndexExpr(&idx),
            .inc_dec => |id_e| {
                const op_ty = try self.synthExpr(id_e.operand, .left_value);
                if (op_ty != TypeInterner.err_ty) {
                    const d = db.types.get(op_ty);
                    if (d != .prim or !d.prim.isInteger()) {
                        try self.emitDiag(id_e.range, .err, "自增自减运算符仅适用于整数类型");
                    }
                }
                return TypeInterner.unit_ty;
            },
            .unary => |u| return self.checkUnaryExpr(&u),
            .binary => |b| {
                if (b.op == .coalescing) {
                    return builtin_expr_mod.checkCoalescing(self, &b, null);
                }
                return self.checkBinaryExpr(&b, null);
            },
            .assign => |asg| {
                const lhs_ty = try self.synthExpr(asg.lhs, .left_value);
                if (asg.op == .assign) {
                    if (lhs_ty != TypeInterner.err_ty) {
                        _ = try self.checkExpr(asg.rhs, lhs_ty);
                    } else {
                        _ = try self.synthExpr(asg.rhs, .none);
                    }
                } else {
                    _ = try self.checkCompoundAssignOp(asg.op, lhs_ty, asg.rhs, asg.range);
                }
                return TypeInterner.unit_ty;
            },
            .range_expr => |re| return builtin_expr_mod.checkRangeExpr(self, &re, null),
            .is_expr => |is_e| {
                _ = try self.synthExpr(is_e.operand, .none);
                return TypeInterner.bool_ty;
            },
            .as_expr => |as_e| {
                _ = try self.synthExpr(as_e.operand, .none);
                const target = self.resolve_data.resolved_types.get(.{ .item = self.global_item.item, .hir = as_e.ty.id() }) orelse TypeInterner.err_ty;
                return db.types.internOption(target);
            },
            .type_conv => |tc| {
                _ = try self.synthExpr(tc.value, .none);
                return self.resolve_data.resolved_types.get(.{ .item = self.global_item.item, .hir = tc.ty.id() }) orelse TypeInterner.err_ty;
            },
            .varray => |va| {
                const va_ty = self.resolve_data.resolved_types.get(.{ .item = self.global_item.item, .hir = va.ty.id() }) orelse TypeInterner.err_ty;
                for (va.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
                if (va.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
                return va_ty;
            },
            .tuple_lit => |t| {
                const elem_tys = try db.gpa.alloc(TypeId, t.elements.len);
                defer db.gpa.free(elem_tys);
                for (t.elements, 0..) |*el, i| {
                    elem_tys[i] = try db.types.replaceIdeal(try self.synthExpr(el, .none));
                }
                const list = try db.types.internList(elem_tys);
                return db.types.intern(.{ .tuple = list });
            },
            .array_lit => |al| return builtin_expr_mod.checkArrayLit(self, &al, null),
            .block => |*blk| return self.synthBlock(blk, pos),
            .if_expr => |ie| return self.checkIfExpr(&ie, null, pos),
            .match_expr => |me| return self.checkMatchExpr(&me, null, pos),
            .while_expr => |we| {
                try self.checkCondition(we.condition);
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                _ = try self.synthBlock(we.body, .unused);
                return TypeInterner.unit_ty;
            },
            .do_while_expr => |dw| {
                self.loop_depth += 1;
                _ = try self.synthBlock(dw.body, .unused);
                self.loop_depth -= 1;
                _ = try self.checkExpr(dw.condition, TypeInterner.bool_ty);
                return TypeInterner.unit_ty;
            },
            .for_in_expr => |fi| {
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                return builtin_expr_mod.checkForInExpr(self, &fi);
            },
            .try_expr => |te| return builtin_expr_mod.checkTryExpr(self, &te, null, pos),
            .throw_expr => |th| {
                const v_ty = try self.synthExpr(th.value, .none);
                if (v_ty != TypeInterner.err_ty) {
                    const is_exc = if (db.types.known.exception_class) |ed|
                        try subtype_mod.isSubtype(db, self.global_item.file, v_ty, try db.types.intern(.{ .nominal = .{ .def = ed, .args = TypeListId.empty } }), .{})
                    else
                        true;
                    const is_err = if (db.types.known.error_class) |ed|
                        try subtype_mod.isSubtype(db, self.global_item.file, v_ty, try db.types.intern(.{ .nominal = .{ .def = ed, .args = TypeListId.empty } }), .{})
                    else
                        false;
                    if (!is_exc and !is_err) {
                        try self.emitDiag(th.value.range(), .err, "throw 表达式抛出值必须为 Exception 或 Error 子类型");
                    }
                }
                return TypeInterner.nothing_ty;
            },
            .return_expr => |ret| {
                const ret_ty = if (ret.value) |v| blk: {
                    if (self.current_expected_ret) |exp| {
                        break :blk try self.checkExpr(v, exp);
                    }
                    break :blk try db.types.replaceIdeal(try self.synthExpr(v, .none));
                } else blk: {
                    if (self.current_expected_ret) |exp| {
                        try self.checkAssignable(ret.range, TypeInterner.unit_ty, exp);
                    }
                    break :blk TypeInterner.unit_ty;
                };
                if (self.collected_returns) |list| {
                    try list.append(db.gpa, ret_ty);
                }
                return TypeInterner.nothing_ty;
            },
            .jump => |jp| {
                if (self.loop_depth == 0) {
                    try self.emitDiag(jp.range, .err, "break 或 continue 只能出现在循环体内");
                }
                return TypeInterner.nothing_ty;
            },
            .lambda => |lam| return lambda_mod.synthLambda(self, &lam),
            .spawn => |sp| return builtin_expr_mod.checkSpawnExpr(self, &sp, null),
            .synchronized => |sy| return builtin_expr_mod.checkSynchronizedExpr(self, &sy, null, pos),
            .unsafe => |us| return self.synthBlock(us.body, pos),
            .quote => |q| {
                for (q.parts) |part| {
                    if (part == .interpolation) _ = try self.synthExpr(part.interpolation, .none);
                }
                return TypeInterner.err_ty;
            },
            .macro_call => return TypeInterner.err_ty,
            .if_available => |ia| {
                for (ia.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
                return TypeInterner.unit_ty;
            },
            .perform => |pf| {
                _ = try self.synthExpr(pf.value, .none);
                return TypeInterner.err_ty;
            },
            .resume_expr => |re| {
                if (re.value) |v| _ = try self.synthExpr(v, .none);
                if (re.modifier_value) |mv| _ = try self.synthExpr(mv, .none);
                return TypeInterner.nothing_ty;
            },
        }
    }

    /// 推导整数字面量类型（带后缀直接具体化并校验范围；无后缀返回 `IdealInt`）。
    fn synthIntLit(self: *ItemChecker, il: common.IntLit) PlatformError!TypeId {
        if (il.suffix) |suf| {
            const ty: TypeId = switch (suf) {
                .i8 => TypeInterner.int8_ty,
                .i16 => TypeInterner.int16_ty,
                .i32 => TypeInterner.int32_ty,
                .i64 => TypeInterner.int64_ty,
                .u8 => TypeInterner.uint8_ty,
                .u16 => TypeInterner.uint16_ty,
                .u32 => TypeInterner.uint32_ty,
                .u64 => TypeInterner.uint64_ty,
            };
            if (literal_mod.checkNumericLiteralRange(self.db.config.target, il.text, false, ty) != .ok) {
                try self.emitDiag(il.range, .err, "带后缀整数字面量超出目标类型范围");
            }
            return ty;
        }
        if (literal_mod.checkNumericLiteralRange(self.db.config.target, il.text, false, TypeInterner.ideal_int_ty) != .ok) {
            try self.emitDiag(il.range, .err, "整数字面量超出 64 位整数宽范围");
        }
        return TypeInterner.ideal_int_ty;
    }

    /// 推导浮点字面量类型（带后缀直接具体化；无后缀返回 `IdealFloat`）。
    fn synthFloatLit(self: *ItemChecker, fl: common.FloatLit) PlatformError!TypeId {
        if (fl.suffix) |suf| {
            const ty: TypeId = switch (suf) {
                .f16 => TypeInterner.float16_ty,
                .f32 => TypeInterner.float32_ty,
                .f64 => TypeInterner.float64_ty,
            };
            if (literal_mod.checkNumericLiteralRange(self.db.config.target, fl.text, false, ty) == .float_overflow) {
                try self.emitDiag(fl.range, .err, "浮点字面量超出目标类型范围");
            }
            return ty;
        }
        return TypeInterner.ideal_float_ty;
    }

    /// 检查单目运算表达式 `-x` 与 `!x`（支持数值/布尔内置、负字面量边界校验与 `operator func` 重载）。
    fn checkUnaryExpr(self: *ItemChecker, u: *const common.UnaryExpr) PlatformError!TypeId {
        const db = self.db;
        // 负整数字面量统一按 `is_negated = true` 执行范围校验（支持 `-128i8` 与 `-9223372036854775808`）
        if (u.op == .neg) {
            if (u.operand.* == .int_lit) {
                const il = u.operand.int_lit;
                if (il.suffix) |suf| {
                    const ty: TypeId = switch (suf) {
                        .i8 => TypeInterner.int8_ty,
                        .i16 => TypeInterner.int16_ty,
                        .i32 => TypeInterner.int32_ty,
                        .i64 => TypeInterner.int64_ty,
                        .u8 => TypeInterner.uint8_ty,
                        .u16 => TypeInterner.uint16_ty,
                        .u32 => TypeInterner.uint32_ty,
                        .u64 => TypeInterner.uint64_ty,
                    };
                    if (literal_mod.checkNumericLiteralRange(db.config.target, il.text, true, ty) != .ok) {
                        try self.emitDiag(u.range, .err, "负整数字面量超出目标整数类型表示范围");
                    }
                    self.setNodeType(u.operand.id(), ty);
                    return ty;
                }
                if (literal_mod.checkNumericLiteralRange(db.config.target, il.text, true, TypeInterner.ideal_int_ty) != .ok) {
                    try self.emitDiag(u.range, .err, "负整数字面量超出 64 位整数宽范围");
                }
                self.setNodeType(u.operand.id(), TypeInterner.ideal_int_ty);
                return TypeInterner.ideal_int_ty;
            }
            if (u.operand.* == .float_lit and u.operand.float_lit.suffix == null) {
                self.setNodeType(u.operand.id(), TypeInterner.ideal_float_ty);
                return TypeInterner.ideal_float_ty;
            }
        }
        const op_ty = try self.synthExpr(u.operand, .none);
        if (op_ty == TypeInterner.err_ty) return TypeInterner.err_ty;
        const d = db.types.get(op_ty);
        switch (u.op) {
            .neg => {
                if (d == .ideal_int or d == .ideal_float or (d == .prim and (d.prim.isSignedInt() or d.prim.isFloat()))) {
                    return op_ty;
                }
                return self.resolveUnaryOperatorOverload(op_ty, "-", u.range);
            },
            .not => {
                if (d == .ideal_int or (d == .prim and (d.prim == .bool_ or d.prim.isInteger()))) return op_ty;
                return self.resolveUnaryOperatorOverload(op_ty, "!", u.range);
            },
        }
    }

    /// 检查二元运算表达式：遵循 `cangjie_compiler` 算术运算“先右向传播再左向传播”字面量规则与运算符重载。
    fn checkBinaryExpr(self: *ItemChecker, b: *const common.BinaryExpr, expected: ?TypeId) PlatformError!TypeId {
        const db = self.db;
        switch (b.op) {
            .logical_and, .logical_or => {
                _ = try self.checkExpr(b.lhs, TypeInterner.bool_ty);
                _ = try self.checkExpr(b.rhs, TypeInterner.bool_ty);
                return TypeInterner.bool_ty;
            },
            .pipeline => {
                const synth_arg = [_]common.HirCallArg{.{
                    .name = null,
                    .is_inout = false,
                    .value = b.lhs,
                    .range = b.lhs.range(),
                }};
                const synth_call: common.CallExpr = .{
                    .id = b.id,
                    .callee = b.rhs,
                    .args = &synth_arg,
                    .trailing_lambda = null,
                    .range = b.range,
                };
                return self.checkCallExpr(&synth_call, expected);
            },
            .composition => {
                const l_ty = try self.synthExpr(b.lhs, .none);
                const r_ty = try self.synthExpr(b.rhs, .none);
                if (db.types.get(l_ty) == .func and db.types.get(r_ty) == .func) {
                    return db.types.intern(.{ .func = .{
                        .params = db.types.get(l_ty).func.params,
                        .ret = db.types.get(r_ty).func.ret,
                        .is_cfunc = false,
                    } });
                }
                return TypeInterner.err_ty;
            },
            .add, .sub, .mul, .div, .mod, .exp, .bit_and, .bit_or, .bit_xor, .lshift, .rshift, .eq, .ne, .lt, .le, .gt, .ge => {
                const is_cmp = switch (b.op) {
                    .eq, .ne, .lt, .le, .gt, .ge => true,
                    else => false,
                };
                const is_shift = b.op == .lshift or b.op == .rshift;

                // 算术/位运算优先将上下文期望数值类型向下传播给两侧
                if (!is_cmp and !is_shift) {
                    if (expected) |exp| {
                        const u_exp = db.types.unboxOption(exp);
                        if (db.types.get(u_exp) == .prim and db.types.get(u_exp).prim.isNumeric()) {
                            _ = try self.checkExpr(b.lhs, u_exp);
                            _ = try self.checkExpr(b.rhs, u_exp);
                            return u_exp;
                        }
                    }
                }

                // 仓颉二元字面量双向传播：先右侧后左侧，再左侧后右侧
                const lhs_raw = try self.synthExpr(b.lhs, .none);
                const rhs_raw = try self.synthExpr(b.rhs, .none);

                if (lhs_raw == TypeInterner.err_ty or rhs_raw == TypeInterner.err_ty) {
                    return if (is_cmp) TypeInterner.bool_ty else TypeInterner.err_ty;
                }

                var lhs_ty = lhs_raw;
                var rhs_ty = rhs_raw;
                if (db.types.hasIdeal(lhs_ty) and !db.types.hasIdeal(rhs_ty) and !is_shift) {
                    lhs_ty = try self.checkExpr(b.lhs, rhs_ty);
                } else if (!db.types.hasIdeal(lhs_ty) and db.types.hasIdeal(rhs_ty) and !is_shift) {
                    rhs_ty = try self.checkExpr(b.rhs, lhs_ty);
                }

                const ld = db.types.get(lhs_ty);
                const rd = db.types.get(rhs_ty);

                if (is_shift) {
                    const lhs_int = ld == .ideal_int or (ld == .prim and ld.prim.isInteger());
                    const rhs_int = rd == .ideal_int or (rd == .prim and rd.prim.isInteger());
                    if (lhs_int and rhs_int) {
                        return lhs_ty;
                    }
                } else {
                    const lhs_num = ld == .ideal_int or ld == .ideal_float or (ld == .prim and ld.prim.isNumeric());
                    const rhs_num = rd == .ideal_int or rd == .ideal_float or (rd == .prim and rd.prim.isNumeric());
                    if (lhs_num and rhs_num) {
                        if (is_cmp) return TypeInterner.bool_ty;
                        if (lhs_ty == rhs_ty) return lhs_ty;
                        if (ld == .ideal_int and rd == .prim and rd.prim.isInteger()) return rhs_ty;
                        if (rd == .ideal_int and ld == .prim and ld.prim.isInteger()) return lhs_ty;
                        if (ld == .ideal_float and rd == .prim and rd.prim.isFloat()) return rhs_ty;
                        if (rd == .ideal_float and ld == .prim and ld.prim.isFloat()) return lhs_ty;
                    }
                    if (ld == .prim and rd == .prim and is_cmp and lhs_ty == rhs_ty and (ld.prim == .bool_ or ld.prim == .rune or ld.prim == .unit)) {
                        return TypeInterner.bool_ty;
                    }
                }

                // String 拼接与比较等通过成员或扩展 `operator func` 重载决议
                const op_name = binaryOpName(b.op);
                if (try self.resolveBinaryOperatorOverload(lhs_ty, rhs_ty, op_name, b.range)) |res_ty| {
                    return res_ty;
                }

                // 字符串内置 `+`、`==`、`!=` 快捷支持（最小内置核心包无完整 operator func 时）
                if (db.types.known.string_struct) |sdef| {
                    if (ld == .nominal and rd == .nominal and DefId.eql(ld.nominal.def, sdef) and DefId.eql(rd.nominal.def, sdef)) {
                        if (b.op == .add) return lhs_ty;
                        if (is_cmp) return TypeInterner.bool_ty;
                    }
                }

                // 同类型或 Option 等值比较放行
                if ((b.op == .eq or b.op == .ne) and (try subtype_mod.isTypeEqual(db, self.global_item.file, lhs_ty, rhs_ty))) {
                    return TypeInterner.bool_ty;
                }

                try self.emitDiag(b.range, .err, "未找到匹配的二元运算符实现");
                return TypeInterner.err_ty;
            },
            .coalescing => unreachable,
        }
    }

    /// 检查复合赋值运算符右侧与目标类型的兼容性。
    fn checkCompoundAssignOp(
        self: *ItemChecker,
        op: common.AssignOp,
        lhs_ty: TypeId,
        rhs: *const common.HirExpr,
        range: common.TextRange,
    ) PlatformError!void {
        _ = range;
        if (lhs_ty == TypeInterner.err_ty) {
            _ = try self.synthExpr(rhs, .none);
            return;
        }
        if (op == .lshift_assign or op == .rshift_assign) {
            _ = try self.synthExpr(rhs, .none);
            return;
        }
        _ = try self.checkExpr(rhs, lhs_ty);
    }

    /// 在目标类型成员与当前文件可见 `extend` 中查找一元运算符重载 `operator func op()`。
    fn resolveUnaryOperatorOverload(self: *ItemChecker, recv_ty: TypeId, op_text: []const u8, range: common.TextRange) PlatformError!TypeId {
        const op_id = try self.db.strings.intern(op_text);
        const cands = try self.collectMemberCandidates(recv_ty, op_id, true);
        if (cands.len == 0) {
            try self.emitDiag(range, .err, "该类型未定义对应的一元运算符");
            return TypeInterner.err_ty;
        }
        const outcome = try overload_mod.resolveCallOverload(self, .{
            .file = self.global_item.file,
            .access_ctx = self.currentAccessContext(),
            .call_range = range,
            .candidates = cands,
            .args = &.{},
            .receiver_ty = recv_ty,
        });
        return switch (outcome) {
            .resolved => |r| r.ret_ty,
            else => TypeInterner.err_ty,
        };
    }

    /// 在左操作数类型成员与当前文件可见 `extend` 中查找二元运算符重载 `operator func op(rhs)`。
    fn resolveBinaryOperatorOverload(
        self: *ItemChecker,
        lhs_ty: TypeId,
        rhs_ty: TypeId,
        op_text: []const u8,
        range: common.TextRange,
    ) PlatformError!?TypeId {
        const op_id = try self.db.strings.intern(op_text);
        const cands = try self.collectMemberCandidates(lhs_ty, op_id, true);
        if (cands.len == 0) return null;
        for (cands) |c| {
            if (c.ref != .def) continue;
            const sig = self.db.callableHeaderSig(.{ .def = c.ref.def }) catch continue;
            if (sig.params.len != 1) continue;
            if (try subtype_mod.isSubtype(self.db, self.global_item.file, rhs_ty, sig.params[0].ty, .{})) {
                try self.recordLateRef(null, range, c.ref, .call);
                return sig.explicit_ret orelse try self.queryReturnType(c.ref.def);
            }
        }
        return null;
    }

    /// 检查下标索引表达式 `base[idx...]`（内置支持 `Array<T>`、`VArray<T, $N>`、`String`、`CPointer<T>` 与 `operator func []`）。
    fn checkIndexExpr(self: *ItemChecker, idx: *const common.IndexExpr) PlatformError!TypeId {
        const db = self.db;
        const raw_base = try self.synthExpr(idx.base, .none);
        const base_ty = try db.types.replaceIdeal(raw_base);
        for (idx.indices) |*i_expr| {
            _ = try self.synthExpr(i_expr, .none);
        }
        if (base_ty == TypeInterner.err_ty) return TypeInterner.err_ty;

        switch (db.types.get(base_ty)) {
            .varray => |va| return va.elem,
            .cpointer => |elem| return elem,
            .nominal => |nom| {
                if (db.types.known.array_struct != null and DefId.eql(nom.def, db.types.known.array_struct.?)) {
                    const args = db.types.getList(nom.args);
                    if (idx.indices.len == 1 and idx.indices[0] == .range_expr) return base_ty;
                    return if (args.len == 1) args[0] else TypeInterner.err_ty;
                }
                if (db.types.known.string_struct != null and DefId.eql(nom.def, db.types.known.string_struct.?)) {
                    if (idx.indices.len == 1 and idx.indices[0] == .range_expr) return base_ty;
                    return TypeInterner.uint8_ty;
                }
                const op_id = try db.strings.intern("[]");
                const cands = try self.collectMemberCandidates(base_ty, op_id, true);
                if (cands.len > 0 and cands[0].ref == .def) {
                    const sig = db.callableHeaderSig(.{ .def = cands[0].ref.def }) catch return TypeInterner.err_ty;
                    return sig.explicit_ret orelse try self.queryReturnType(cands[0].ref.def);
                }
                return TypeInterner.err_ty;
            },
            else => return TypeInterner.err_ty,
        }
    }

    /// 解析路径表达式 `a`、`a.b.c`、`this.x`、`T.static_m` 与无限定枚举构造器糖。
    fn resolvePathExpr(self: *ItemChecker, p: *const common.PathExpr, expected: ?TypeId) PlatformError!TypeId {
        const db = self.db;
        if (p.segments.len == 0) return TypeInterner.err_ty;
        const key: common.HirKey = .{ .item = self.global_item.item, .hir = p.id };

        const seg0 = p.segments[0];
        if (!seg0.name.is_raw) {
            if (std.mem.eql(u8, seg0.name.text, "this")) {
                const this_ty = try self.enclosingSelfType();
                return self.resolveRemainingSegments(p.id, this_ty, p.segments[1..], expected);
            }
            if (std.mem.eql(u8, seg0.name.text, "super")) {
                const super_ty = try self.enclosingSuperType();
                return self.resolveRemainingSegments(p.id, super_ty, p.segments[1..], expected);
            }
        }

        if (self.resolve_data.early_bindings.get(key)) |sym| {
            var cur_ty = try self.typeOfSymbolRef(sym, seg0.type_args, expected);
            if (p.segments.len == 1) {
                if (sym == .def) {
                    try self.outgoing_refs.append(self.arena, .{
                        .target = sym.def,
                        .range = seg0.name.range,
                        .kind = .read,
                    });
                }
                return cur_ty;
            }
            // 多段路径：支持 `pkg.Item`、`Type.member`、`val.field.sub`
            var seg_start: usize = 1;
            if (sym == .pkg and p.segments.len >= 2) {
                const seg1 = p.segments[1];
                const seg1_id = try db.strings.intern(seg1.name.text);
                if (db.packageState(sym.pkg)) |ps| {
                    const exps = ps.lookupTop(seg1_id);
                    if (exps.len > 0) {
                        const target_sym: SymbolRef = .{ .def = exps[0].def };
                        try self.recordLateRef(p.id, seg1.name.range, target_sym, .read);
                        cur_ty = try self.typeOfSymbolRef(target_sym, seg1.type_args, expected);
                        seg_start = 2;
                    }
                } else |_| {}
            }
            return self.resolveRemainingSegments(p.id, cur_ty, p.segments[seg_start..], expected);
        }

        // 若为重载函数组（作为高阶函数值使用）
        if (self.resolve_data.early_overloads.get(key)) |ov| {
            if (ov.candidates.len > 0) {
                const chosen = try self.pickFunctionValueCandidate(ov.candidates, expected);
                if (chosen) |c_ref| {
                    try self.recordLateRef(p.id, seg0.name.range, c_ref, .read);
                    const fn_ty = try self.typeOfSymbolRef(c_ref, seg0.type_args, expected);
                    return self.resolveRemainingSegments(p.id, fn_ty, p.segments[1..], expected);
                }
            }
            return TypeInterner.err_ty;
        }

        // 未命中常规声明时尝试无限定无参枚举构造器（如 `None`）
        if (p.segments.len == 1) {
            const name_id = try db.strings.intern(seg0.name.text);
            const enum_cands = try overload_mod.findEnumSugarCandidates(self, db.gpa, name_id, null, expected);
            defer db.gpa.free(enum_cands);
            if (enum_cands.len == 1) {
                const cdef = enum_cands[0];
                try self.recordLateRef(p.id, seg0.name.range, .{ .def = cdef }, .read);
                return self.instantiateEnumCtorValueType(cdef, expected);
            } else if (enum_cands.len > 1) {
                try self.emitDiag(seg0.name.range, .err, "无限定枚举构造器存在二义性");
                return TypeInterner.err_ty;
            }
        }

        return TypeInterner.err_ty;
    }

    /// 沿路径后续点分段逐段解析成员字段、属性、枚举构造器或方法。
    fn resolveRemainingSegments(
        self: *ItemChecker,
        hir_id: common.HirId,
        start_ty: TypeId,
        segs: []const common.ExprPathSegment,
        expected: ?TypeId,
    ) PlatformError!TypeId {
        var cur_ty = start_ty;
        for (segs) |seg| {
            cur_ty = try self.lookupMemberType(hir_id, cur_ty, seg.name, seg.type_args, expected);
        }
        return cur_ty;
    }

    /// 解析显式 `FieldExpr`（`base.name`）。
    fn resolveFieldExpr(self: *ItemChecker, f: *const common.FieldExpr, expected: ?TypeId) PlatformError!TypeId {
        const raw_base = try self.synthExpr(f.base, .none);
        const base_ty = try self.db.types.replaceIdeal(raw_base);
        return self.lookupMemberType(f.id, base_ty, f.name, f.type_args, expected);
    }

    /// 按接收者类型与成员名称查找字段、属性、方法或枚举构造器并记录晚绑定。
    fn lookupMemberType(
        self: *ItemChecker,
        hir_id: common.HirId,
        recv_ty: TypeId,
        member_name: common.Name,
        type_args: []const common.HirType,
        expected: ?TypeId,
    ) PlatformError!TypeId {
        const db = self.db;
        if (recv_ty == TypeInterner.err_ty) return TypeInterner.err_ty;

        // 支持元组索引 `t[0]` / 命名字段
        const name_id = try db.strings.intern(member_name.text);
        const unboxed_recv = db.types.unboxOption(recv_ty);

        // 先尝试查找非可调用字段、属性或无参枚举构造器，其次查找方法
        const cands = try self.collectMemberCandidates(unboxed_recv, name_id, false);
        if (cands.len == 0) return TypeInterner.err_ty;

        for (cands) |cand| {
            if (cand.ref != .def) continue;
            const entry = db.getDef(cand.ref.def) catch continue;
            if (!try access_mod.checkAccess(db, cand.ref.def, unboxed_recv, self.currentAccessContext())) continue;
            try self.recordLateRef(hir_id, member_name.range, cand.ref, .read);

            var raw_ty: TypeId = switch (entry.kind) {
                .field, .variable, .constant => try self.queryVarType(cand.ref.def),
                .prop => try db.propTypeOf(cand.ref.def),
                .enum_variant => try self.instantiateEnumCtorValueType(cand.ref.def, expected),
                .method, .func_, .constructor, .primary_ctor => blk: {
                    const sig = db.callableHeaderSig(.{ .def = cand.ref.def }) catch break :blk TypeInterner.err_ty;
                    break :blk try self.funcTypeFromCallableSig(sig, null);
                },
                else => TypeInterner.err_ty,
            };

            // 使用接收者名义类型的类型实参替换成员签名中的宿主泛型形参
            if (db.types.get(unboxed_recv) == .nominal) {
                const nom = db.types.get(unboxed_recv).nominal;
                if (db.nominalHeaderOf(nom.def)) |nh| {
                    raw_ty = try subtype_mod.substituteNominalParams(db, raw_ty, nh.type_params, db.types.getList(nom.args));
                } else |_| {}
            }
            _ = type_args;
            return raw_ty;
        }
        return TypeInterner.err_ty;
    }

    /// 检查调用表达式 `callee(args)`（统一覆盖函数调用、方法调用、类型构造器调用、带参枚举构造器与高阶函数值调用）。
    fn checkCallExpr(self: *ItemChecker, c: *const common.CallExpr, expected: ?TypeId) PlatformError!TypeId {
        const db = self.db;
        const scratch = self.scratch.allocator();
        const key_callee: common.HirKey = .{ .item = self.global_item.item, .hir = c.callee.id() };

        var explicit_targs: std.ArrayListUnmanaged(TypeId) = .empty;
        var receiver_ty: ?TypeId = null;
        var candidates: std.ArrayListUnmanaged(EarlyCandidate) = .empty;
        var callee_range = c.callee.range();

        switch (c.callee.*) {
            .path => |p| {
                if (p.segments.len == 1) {
                    const seg0 = p.segments[0];
                    callee_range = seg0.name.range;
                    for (seg0.type_args) |*ta| {
                        const t = self.resolve_data.resolved_types.get(.{ .item = self.global_item.item, .hir = ta.id() }) orelse TypeInterner.err_ty;
                        try explicit_targs.append(scratch, t);
                    }
                    // 检查是否为无限定类型名或类型别名调用构造器（例如 `Foo(1)` / `Array<Int64>(10, repeat: 0)`）
                    if (self.resolve_data.early_bindings.get(key_callee)) |sym| {
                        if (sym == .def) {
                            const de = db.getDef(sym.def) catch null;
                            if (de != null and (de.?.kind == .class_ or de.?.kind == .struct_)) {
                                return self.checkConstructorCall(c, sym.def, explicit_targs.items, expected);
                            }
                            if (de != null and de.?.kind == .type_alias) {
                                const target_ty = db.typeAliasTargetOf(sym.def) catch TypeInterner.err_ty;
                                if (db.types.get(target_ty) == .nominal) {
                                    return self.checkConstructorCall(c, db.types.get(target_ty).nominal.def, explicit_targs.items, expected);
                                }
                            }
                        }
                    }
                    if (self.resolve_data.early_overloads.get(key_callee)) |ov| {
                        try candidates.appendSlice(scratch, ov.candidates);
                    } else if (self.resolve_data.early_bindings.get(key_callee)) |sym| {
                        if (sym == .def) {
                            const de = db.getDef(sym.def) catch null;
                            if (de != null and (de.?.kind == .func_ or de.?.kind == .method or de.?.kind == .constructor or de.?.kind == .primary_ctor)) {
                                try candidates.append(scratch, .{ .ref = sym, .scope_level = 0, .is_reexport = false });
                            }
                        } else if (sym == .local) {
                            const loc = self.resolve_data.getLocal(sym.local.idx);
                            if (loc != null and loc.?.kind == .func_) {
                                try candidates.append(scratch, .{ .ref = sym, .scope_level = 2, .is_reexport = false });
                            }
                        }
                    }
                    // 若未命中常规候选，尝试无限定带参枚举构造器（如 `Some(42)`）
                    if (candidates.items.len == 0) {
                        const name_id = try db.strings.intern(seg0.name.text);
                        const total_args = c.args.len + @as(usize, if (c.trailing_lambda != null) 1 else 0);
                        const ecands = try overload_mod.findEnumSugarCandidates(self, db.gpa, name_id, total_args, expected);
                        defer db.gpa.free(ecands);
                        for (ecands) |edef| {
                            try candidates.append(scratch, .{ .ref = .{ .def = edef }, .scope_level = -1, .is_reexport = false });
                        }
                    }
                } else if (p.segments.len >= 2) {
                    const last = p.segments[p.segments.len - 1];
                    callee_range = last.name.range;
                    for (last.type_args) |*ta| {
                        const t = self.resolve_data.resolved_types.get(.{ .item = self.global_item.item, .hir = ta.id() }) orelse TypeInterner.err_ty;
                        try explicit_targs.append(scratch, t);
                    }
                    // 构造前缀类型或包前缀
                    const prefix_path: common.PathExpr = .{
                        .id = p.id,
                        .segments = p.segments[0 .. p.segments.len - 1],
                        .range = p.range,
                    };
                    if (self.resolve_data.early_bindings.get(key_callee)) |sym0| {
                        if (sym0 == .pkg and p.segments.len == 2) {
                            const m_id = try db.strings.intern(last.name.text);
                            if (db.packageState(sym0.pkg)) |ps| {
                                for (ps.lookupTop(m_id)) |exp| {
                                    const de = db.getDef(exp.def) catch continue;
                                    if (de.kind == .class_ or de.kind == .struct_) {
                                        return self.checkConstructorCall(c, exp.def, explicit_targs.items, expected);
                                    }
                                    try candidates.append(scratch, .{ .ref = .{ .def = exp.def }, .scope_level = 0, .is_reexport = exp.is_reexport });
                                }
                            } else |_| {}
                        } else {
                            const rty = try self.resolvePathExpr(&prefix_path, null);
                            receiver_ty = try db.types.replaceIdeal(rty);
                            const m_id = try db.strings.intern(last.name.text);
                            const mcands = try self.collectMemberCandidates(receiver_ty.?, m_id, false);
                            try candidates.appendSlice(scratch, mcands);
                        }
                    } else {
                        const rty = try self.resolvePathExpr(&prefix_path, null);
                        receiver_ty = try db.types.replaceIdeal(rty);
                        const m_id = try db.strings.intern(last.name.text);
                        const mcands = try self.collectMemberCandidates(receiver_ty.?, m_id, false);
                        try candidates.appendSlice(scratch, mcands);
                    }
                }
            },
            .field => |f| {
                callee_range = f.name.range;
                for (f.type_args) |*ta| {
                    const t = self.resolve_data.resolved_types.get(.{ .item = self.global_item.item, .hir = ta.id() }) orelse TypeInterner.err_ty;
                    try explicit_targs.append(scratch, t);
                }
                const raw_recv = try self.synthExpr(f.base, .none);
                receiver_ty = try db.types.replaceIdeal(raw_recv);
                const m_id = try db.strings.intern(f.name.text);
                const mcands = try self.collectMemberCandidates(receiver_ty.?, m_id, false);
                try candidates.appendSlice(scratch, mcands);
            },
            else => {},
        }

        if (candidates.items.len > 0) {
            self.in_func_arg_lambda_depth += 1;
            defer self.in_func_arg_lambda_depth -= 1;

            const outcome = try overload_mod.resolveCallOverload(self, .{
                .file = self.global_item.file,
                .access_ctx = self.currentAccessContext(),
                .call_range = c.range,
                .candidates = candidates.items,
                .args = c.args,
                .trailing_lambda = c.trailing_lambda,
                .explicit_type_args = explicit_targs.items,
                .expected_ret = expected,
                .receiver_ty = receiver_ty,
            });
            switch (outcome) {
                .resolved => |res| {
                    try self.recordLateRef(c.id, callee_range, res.target, .call);
                    if (res.type_args != TypeListId.empty) {
                        try self.instantiated_type_args.put(self.arena, c.id, res.type_args);
                    }
                    return res.ret_ty;
                },
                .ambiguous => {
                    try self.emitDiag(c.range, .err, "调用命中多个同等具体的重载候选，存在二义性");
                    return TypeInterner.err_ty;
                },
                .no_match => |nm| {
                    if (nm.inaccessible_candidates.len > 0) {
                        try self.emitDiag(c.range, .err, "目标可调用声明在当前作用域不可访问");
                    }
                    return TypeInterner.err_ty;
                },
            }
        }

        // 回退至高阶函数值直接调用（`fn_val(a, b)`）
        self.in_func_arg_lambda_depth += 1;
        defer self.in_func_arg_lambda_depth -= 1;

        const callee_ty = try self.synthExpr(c.callee, .none);
        const unboxed_callee = db.types.unboxOption(callee_ty);
        if (db.types.get(unboxed_callee) == .func) {
            const f = db.types.get(unboxed_callee).func;
            const p_tys = db.types.getList(f.params);
            for (c.args, 0..) |arg, i| {
                if (i < p_tys.len) {
                    _ = try self.checkExpr(arg.value, p_tys[i]);
                } else {
                    _ = try self.synthExpr(arg.value, .expr_arg);
                }
            }
            if (c.trailing_lambda) |tl| {
                if (c.args.len < p_tys.len) {
                    _ = try self.checkExpr(tl, p_tys[c.args.len]);
                } else {
                    _ = try self.synthExpr(tl, .expr_arg);
                }
            }
            return f.ret;
        }

        for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
        if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
        return TypeInterner.err_ty;
    }

    /// 检查类型构造器调用 `TypeName<Args>(call_args)`。
    fn checkConstructorCall(
        self: *ItemChecker,
        c: *const common.CallExpr,
        type_def: DefId,
        explicit_targs: []const TypeId,
        expected: ?TypeId,
    ) PlatformError!TypeId {
        const db = self.db;
        const scratch = self.scratch.allocator();
        const entry = db.getDef(type_def) catch return TypeInterner.err_ty;
        const nh = db.nominalHeaderOf(type_def) catch return TypeInterner.err_ty;

        var ctors: std.ArrayListUnmanaged(EarlyCandidate) = .empty;
        for (entry.members) |m_def| {
            const me = db.getDef(m_def) catch continue;
            if (me.kind == .constructor or me.kind == .primary_ctor) {
                try ctors.append(scratch, .{ .ref = .{ .def = m_def }, .scope_level = 1, .is_reexport = false });
            }
        }

        const targs_id: TypeListId = if (explicit_targs.len == nh.type_params.len)
            try db.types.internList(explicit_targs)
        else if (nh.type_params.len == 0)
            TypeListId.empty
        else blk: {
            if (expected) |exp| {
                const u = db.types.unboxOption(exp);
                if (db.types.get(u) == .nominal and DefId.eql(db.types.get(u).nominal.def, type_def)) {
                    break :blk db.types.get(u).nominal.args;
                }
            }
            break :blk TypeListId.empty;
        };

        const constructed_ty = try db.types.intern(.{ .nominal = .{ .def = type_def, .args = targs_id } });

        if (ctors.items.len > 0) {
            const outcome = try overload_mod.resolveCallOverload(self, .{
                .file = self.global_item.file,
                .access_ctx = self.currentAccessContext(),
                .call_range = c.range,
                .candidates = ctors.items,
                .args = c.args,
                .trailing_lambda = c.trailing_lambda,
                .explicit_type_args = explicit_targs,
                .expected_ret = expected,
                .receiver_ty = if (targs_id != TypeListId.empty) constructed_ty else null,
            });
            switch (outcome) {
                .resolved => |res| {
                    try self.recordLateRef(c.id, c.callee.range(), res.target, .call);
                    return res.ret_ty;
                },
                else => {},
            }
        } else {
            for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
            if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
        }
        try self.recordLateRef(c.id, c.callee.range(), .{ .def = type_def }, .call);
        return constructed_ty;
    }

    /// 收集指定接收者类型（自身成员、继承链成员及当前文件 `VisibleExtendIndex` 扩展成员）中匹配名称的候选列表。
    /// 返回切片借用自 `self.scratch`，在当前声明项检查结束前有效，调用者不得释放。
    fn collectMemberCandidates(
        self: *ItemChecker,
        recv_ty: TypeId,
        member_name: InternedId,
        operators_only: bool,
    ) PlatformError![]const EarlyCandidate {
        const db = self.db;
        const scratch = self.scratch.allocator();
        var list: std.ArrayListUnmanaged(EarlyCandidate) = .empty;
        var seen: std.AutoHashMapUnmanaged(DefId, void) = .empty;

        const addFromDef = struct {
            /// 将指定容器声明中匹配名称的成员追加至候选列表并去重。
            fn call(
                db_in: *Database,
                alloc: std.mem.Allocator,
                out: *std.ArrayListUnmanaged(EarlyCandidate),
                visited: *std.AutoHashMapUnmanaged(DefId, void),
                owner_def: DefId,
                name: InternedId,
                ops_only: bool,
            ) std.mem.Allocator.Error!void {
                const oe = db_in.getDef(owner_def) catch return;
                for (oe.members) |m_def| {
                    const me = db_in.getDef(m_def) catch continue;
                    if (me.name != name) continue;
                    if (ops_only and !me.flags.is_operator) continue;
                    if (visited.contains(m_def)) continue;
                    try visited.put(alloc, m_def, {});
                    try out.append(alloc, .{ .ref = .{ .def = m_def }, .scope_level = 1, .is_reexport = false });
                }
            }
        }.call;

        switch (db.types.get(recv_ty)) {
            .nominal => |nom| {
                try addFromDef(db, scratch, &list, &seen, nom.def, member_name, operators_only);
                // 沿继承链收集父类与接口成员
                const supers = try subtype_mod.collectAllSupertypes(db, db.gpa, self.global_item.file, recv_ty);
                defer db.gpa.free(supers);
                for (supers) |st| {
                    if (db.types.get(st) == .nominal) {
                        try addFromDef(db, scratch, &list, &seen, db.types.get(st).nominal.def, member_name, operators_only);
                    }
                }
                // 收集当前文件可见的 extend 成员
                for (self.resolve_data.visible_extends.getForNominal(nom.def)) |ext_def| {
                    const ps = db.packageState(ext_def.pkg) catch continue;
                    for (ps.extends) |ext| {
                        if (!DefId.eql(ext.def, ext_def)) continue;
                        const ext_targs = (try subtype_mod.matchExtendTarget(db, db.gpa, self.global_item.file, recv_ty, ext)) orelse break;
                        defer db.gpa.free(ext_targs);
                        const oe = db.getDef(ext_def) catch break;
                        for (oe.members) |m_def| {
                            const me = db.getDef(m_def) catch continue;
                            if (me.name != member_name) continue;
                            if (operators_only and !me.flags.is_operator) continue;
                            if (!try access_mod.isExtendMemberAccessible(db, self.global_item.file, ext_def, m_def)) continue;
                            if (seen.contains(m_def)) continue;
                            try seen.put(scratch, m_def, {});
                            try list.append(scratch, .{ .ref = .{ .def = m_def }, .scope_level = 1, .is_reexport = false });
                        }
                        break;
                    }
                }
            },
            .prim => |pk| {
                for (self.resolve_data.visible_extends.getForPrim(pk)) |ext_def| {
                    const oe = db.getDef(ext_def) catch continue;
                    for (oe.members) |m_def| {
                        const me = db.getDef(m_def) catch continue;
                        if (me.name != member_name) continue;
                        if (operators_only and !me.flags.is_operator) continue;
                        if (!try access_mod.isExtendMemberAccessible(db, self.global_item.file, ext_def, m_def)) continue;
                        if (seen.contains(m_def)) continue;
                        try seen.put(scratch, m_def, {});
                        try list.append(scratch, .{ .ref = .{ .def = m_def }, .scope_level = 1, .is_reexport = false });
                    }
                }
            },
            .type_param => |tp| {
                const bounds = try subtype_mod.getTypeParamUpperBounds(db, db.gpa, tp);
                defer db.gpa.free(bounds);
                for (bounds) |bty| {
                    const sub_cands = try self.collectMemberCandidates(bty, member_name, operators_only);
                    for (sub_cands) |sc| {
                        if (sc.ref == .def and !seen.contains(sc.ref.def)) {
                            try seen.put(scratch, sc.ref.def, {});
                            try list.append(scratch, sc);
                        }
                    }
                }
            },
            else => {},
        }
        return list.items;
    }

    /// 检查 `if` 表达式（含 `if-let`、省略 `else` 固定为 `Unit` 与多分支 `computeJoin`）。
    fn checkIfExpr(self: *ItemChecker, ie: *const common.IfExpr, expected: ?TypeId, pos: SynPos) PlatformError!TypeId {
        try self.checkCondition(ie.condition);

        if (ie.else_branch == null) {
            _ = try self.synthBlock(ie.then_branch, .unused);
            return TypeInterner.unit_ty;
        }
        const else_e = ie.else_branch.?;

        if (expected) |exp| {
            _ = try self.checkBlock(ie.then_branch, exp);
            _ = try self.checkExpr(else_e, exp);
            return exp;
        }

        if (pos == .unused) {
            _ = try self.synthBlock(ie.then_branch, .unused);
            _ = try self.synthExpr(else_e, .unused);
            return TypeInterner.unit_ty;
        }

        const then_ty = try self.db.types.replaceIdeal(try self.synthBlock(ie.then_branch, .none));
        const else_ty = try self.db.types.replaceIdeal(try self.synthExpr(else_e, .none));
        return switch (try join_meet_mod.computeJoin(self.db, self.global_item.file, &.{ then_ty, else_ty })) {
            .ok => |j| j,
            .ambiguous_or_none => blk: {
                try self.emitDiag(ie.range, .err, "if 与 else 分支不存在唯一最小公共父类型");
                break :blk TypeInterner.err_ty;
            },
            .has_error => TypeInterner.err_ty,
        };
    }

    /// 检查 `match` 表达式（支持有选择器模式匹配与无选择器布尔分支匹配）。
    fn checkMatchExpr(self: *ItemChecker, me: *const common.MatchExpr, expected: ?TypeId, pos: SynPos) PlatformError!TypeId {
        const db = self.db;
        const sel_ty: ?TypeId = if (me.selector) |sel| try db.types.replaceIdeal(try self.synthExpr(sel, .none)) else null;

        var branch_tys: std.ArrayListUnmanaged(TypeId) = .empty;
        defer branch_tys.deinit(db.gpa);

        for (me.cases) |mc| {
            switch (mc) {
                .pattern => |pc| {
                    for (pc.patterns) |*pat| {
                        try self.checkPattern(pat, sel_ty orelse TypeInterner.err_ty);
                    }
                    if (pc.guard) |g| _ = try self.checkExpr(g, TypeInterner.bool_ty);
                    if (expected) |exp| {
                        _ = try self.checkBlock(pc.body, exp);
                    } else if (pos == .unused) {
                        _ = try self.synthBlock(pc.body, .unused);
                    } else {
                        try branch_tys.append(db.gpa, try db.types.replaceIdeal(try self.synthBlock(pc.body, .none)));
                    }
                },
                .expr => |ec| {
                    if (ec.value.* != .wildcard) {
                        _ = try self.checkExpr(ec.value, TypeInterner.bool_ty);
                    }
                    if (expected) |exp| {
                        _ = try self.checkBlock(ec.body, exp);
                    } else if (pos == .unused) {
                        _ = try self.synthBlock(ec.body, .unused);
                    } else {
                        try branch_tys.append(db.gpa, try db.types.replaceIdeal(try self.synthBlock(ec.body, .none)));
                    }
                },
            }
        }

        if (expected) |exp| return exp;
        if (pos == .unused) return TypeInterner.unit_ty;
        if (branch_tys.items.len == 0) return TypeInterner.unit_ty;

        return switch (try join_meet_mod.computeJoin(db, self.global_item.file, branch_tys.items)) {
            .ok => |j| j,
            .ambiguous_or_none => blk: {
                try self.emitDiag(me.range, .err, "match 各分支不存在唯一最小公共父类型");
                break :blk TypeInterner.err_ty;
            },
            .has_error => TypeInterner.err_ty,
        };
    }

    /// 检查 `if`/`while` 条件（普通布尔表达式或 `let pat <- expr` 模式解构）。
    fn checkCondition(self: *ItemChecker, cond: common.HirCondition) PlatformError!void {
        switch (cond) {
            .expr => |ce| _ = try self.checkExpr(ce, TypeInterner.bool_ty),
            .let_destructor => |ld| {
                const v_ty = try self.db.types.replaceIdeal(try self.synthExpr(ld.value, .none));
                for (ld.patterns) |*pat| {
                    try self.checkPattern(pat, v_ty);
                }
            },
        }
    }

    /// 检查模式并向下绑定模式内各局部变量的类型。
    pub fn checkPattern(self: *ItemChecker, pat: *const common.HirPattern, target_ty: TypeId) PlatformError!void {
        const db = self.db;
        switch (pat.*) {
            .wildcard => {},
            .binding => |bp| {
                try self.setLocalTypeByDeclHir(bp.id, target_ty);
                self.setNodeType(bp.id, target_ty);
            },
            .const_ => |cp| {
                if (target_ty != TypeInterner.err_ty) {
                    _ = try self.checkExpr(cp.value, target_ty);
                } else {
                    _ = try self.synthExpr(cp.value, .none);
                }
            },
            .tuple => |tp| {
                if (db.types.get(target_ty) == .tuple) {
                    const elem_tys = db.types.getList(db.types.get(target_ty).tuple);
                    for (tp.elements, 0..) |*el, i| {
                        const et = if (i < elem_tys.len) elem_tys[i] else TypeInterner.err_ty;
                        try self.checkPattern(el, et);
                    }
                } else {
                    for (tp.elements) |*el| try self.checkPattern(el, TypeInterner.err_ty);
                }
            },
            .enum_ => |ep| {
                // 匹配枚举构造器（含 Option::Some(x)）并展开荷载类型
                const ctor_name = if (ep.path.segments.len > 0) ep.path.segments[ep.path.segments.len - 1].name.text else "";
                var payload_tys: []const TypeId = &.{};
                var payload_buf: [8]TypeId = undefined;

                if (db.types.get(target_ty) == .nominal) {
                    const nom = db.types.get(target_ty).nominal;
                    if (db.getDef(nom.def)) |enum_entry| {
                        const ctor_id = try db.strings.intern(ctor_name);
                        for (enum_entry.members) |m_def| {
                            const me = db.getDef(m_def) catch continue;
                            if (me.kind == .enum_variant and me.name == ctor_id) {
                                if (db.callableHeaderSig(.{ .def = m_def })) |sig| {
                                    const nh = db.nominalHeaderOf(nom.def) catch null;
                                    const targs = db.types.getList(nom.args);
                                    const n = @min(sig.params.len, payload_buf.len);
                                    for (0..n) |i| {
                                        payload_buf[i] = if (nh) |h|
                                            try subtype_mod.substituteNominalParams(db, sig.params[i].ty, h.type_params, targs)
                                        else
                                            sig.params[i].ty;
                                    }
                                    payload_tys = payload_buf[0..n];
                                } else |_| {}
                                break;
                            }
                        }
                    } else |_| {}
                }
                for (ep.args, 0..) |*arg, i| {
                    const pt = if (i < payload_tys.len) payload_tys[i] else TypeInterner.err_ty;
                    try self.checkPattern(arg, pt);
                }
            },
            .typed => |tp| {
                const ann = self.resolve_data.resolved_types.get(.{ .item = self.global_item.item, .hir = tp.ty.id() }) orelse TypeInterner.err_ty;
                try self.setLocalTypeByDeclHir(tp.id, ann);
                self.setNodeType(tp.id, ann);
            },
            .except_type, .command_type => try self.checkClausePattern(pat),
        }
    }

    /// 检查 `catch`/`handle` 异常模式并绑定异常变量类型。
    pub fn checkClausePattern(self: *ItemChecker, pat: *const common.HirPattern) PlatformError!void {
        switch (pat.*) {
            .except_type, .command_type => |cp| {
                var ty: TypeId = TypeInterner.err_ty;
                if (cp.types.len > 0) {
                    ty = self.resolve_data.resolved_types.get(.{ .item = self.global_item.item, .hir = cp.types[0].id() }) orelse TypeInterner.err_ty;
                } else if (self.db.types.known.exception_class) |ed| {
                    ty = try self.db.types.intern(.{ .nominal = .{ .def = ed, .args = TypeListId.empty } });
                }
                try self.setLocalTypeByDeclHir(cp.id, ty);
                self.setNodeType(cp.id, ty);
            },
            else => try self.checkPattern(pat, TypeInterner.err_ty),
        }
    }

    /// 综合推导语句块类型，维护控制流 `diverged` 可达性追踪。
    pub fn synthBlock(self: *ItemChecker, blk: *const common.BlockExpr, pos: SynPos) PlatformError!TypeId {
        var diverged = false;
        for (blk.stmts) |*stmt| {
            const st_ty = try self.checkStmt(stmt);
            if (st_ty == TypeInterner.nothing_ty) diverged = true;
        }
        const res_ty = if (blk.tail) |tail| blk_res: {
            const t_ty = try self.synthExpr(tail, pos);
            if (t_ty == TypeInterner.nothing_ty) diverged = true;
            break :blk_res if (diverged) TypeInterner.nothing_ty else t_ty;
        } else if (diverged) TypeInterner.nothing_ty else TypeInterner.unit_ty;

        self.setNodeType(blk.id, res_ty);
        return res_ty;
    }

    /// 带上下文期望类型检查语句块，维持 `diverged` 可达性追踪。
    pub fn checkBlock(self: *ItemChecker, blk: *const common.BlockExpr, expected: TypeId) PlatformError!TypeId {
        var diverged = false;
        for (blk.stmts) |*stmt| {
            const st_ty = try self.checkStmt(stmt);
            if (st_ty == TypeInterner.nothing_ty) diverged = true;
        }
        if (blk.tail) |tail| {
            const t_ty = try self.checkExpr(tail, expected);
            if (t_ty == TypeInterner.nothing_ty) diverged = true;
            const out_ty = if (diverged) TypeInterner.nothing_ty else t_ty;
            self.setNodeType(blk.id, out_ty);
            return out_ty;
        }
        if (!diverged and expected != TypeInterner.unit_ty and expected != TypeInterner.err_ty and expected != TypeInterner.quest_ty) {
            try self.checkAssignable(blk.range, TypeInterner.unit_ty, expected);
        }
        const out_ty = if (diverged) TypeInterner.nothing_ty else TypeInterner.unit_ty;
        self.setNodeType(blk.id, out_ty);
        return out_ty;
    }

    /// 推导可调用体（函数或 Lambda）的返回类型（汇总显式 `return` 与末尾隐式返回并计算 `computeJoin`）。
    pub fn synthCallableBody(self: *ItemChecker, blk: *const common.BlockExpr) PlatformError!TypeId {
        const db = self.db;
        const prev_exp = self.current_expected_ret;
        const prev_col = self.collected_returns;
        var returns: std.ArrayListUnmanaged(TypeId) = .empty;
        defer returns.deinit(db.gpa);

        self.current_expected_ret = null;
        self.collected_returns = &returns;
        defer {
            self.current_expected_ret = prev_exp;
            self.collected_returns = prev_col;
        }

        const tail_ty = try db.types.replaceIdeal(try self.synthBlock(blk, .implicit_return));
        if (tail_ty != TypeInterner.nothing_ty or returns.items.len == 0) {
            try returns.append(db.gpa, tail_ty);
        }
        if (returns.items.len == 1) return returns.items[0];
        return switch (try join_meet_mod.computeJoin(db, self.global_item.file, returns.items)) {
            .ok => |j| j,
            .ambiguous_or_none => blk_j: {
                try self.emitDiag(blk.range, .err, "函数体多个返回路径不存在唯一最小公共父类型");
                break :blk_j TypeInterner.err_ty;
            },
            .has_error => TypeInterner.err_ty,
        };
    }

    /// 使用给定返回类型检查可调用体（设置 `current_expected_ret` 以校验所有内部 `return` 语句）。
    pub fn checkCallableBody(self: *ItemChecker, blk: *const common.BlockExpr, expected_ret: TypeId) PlatformError!TypeId {
        const prev_exp = self.current_expected_ret;
        const prev_col = self.collected_returns;
        self.current_expected_ret = expected_ret;
        self.collected_returns = null;
        defer {
            self.current_expected_ret = prev_exp;
            self.collected_returns = prev_col;
        }
        return self.checkBlock(blk, expected_ret);
    }

    /// 检查单条语句并返回其类型（发散语句返回 `Nothing`，常规语句返回 `Unit`）。
    fn checkStmt(self: *ItemChecker, stmt: *const common.HirStmt) PlatformError!TypeId {
        const db = self.db;
        switch (stmt.*) {
            .binding => |b| {
                var var_ty: TypeId = TypeInterner.err_ty;
                if (b.ty) |t| {
                    var_ty = self.resolve_data.resolved_types.get(.{ .item = self.global_item.item, .hir = t.id() }) orelse TypeInterner.err_ty;
                    if (b.init) |ie| _ = try self.checkExpr(ie, var_ty);
                } else if (b.init) |ie| {
                    var_ty = try db.types.replaceIdeal(try self.synthExpr(ie, .none));
                }
                try self.checkPattern(b.pattern, var_ty);
                self.setNodeType(b.id, var_ty);
                return TypeInterner.unit_ty;
            },
            .expr => |es| {
                const ty = try self.synthExpr(es.value, .unused);
                return if (ty == TypeInterner.nothing_ty) TypeInterner.nothing_ty else TypeInterner.unit_ty;
            },
            .item => |*local_item| {
                if (local_item.* == .func) {
                    try self.checkLocalFunc(&local_item.func);
                }
                return TypeInterner.unit_ty;
            },
        }
    }

    /// 检查局部函数定义（含形参默认值检查、返回类型推导与递归状态记录）。
    fn checkLocalFunc(self: *ItemChecker, f: *const common.FuncItem) PlatformError!void {
        const key: common.HirKey = .{ .item = self.global_item.item, .hir = f.id };
        var loc_opt: ?*const scope_mod.LocalSymbol = null;
        for (self.resolve_data.locals) |*loc| {
            if (common.HirKey.eql(loc.decl_key, key)) {
                loc_opt = loc;
                break;
            }
        }
        const loc = loc_opt orelse return;
        const sig = if (loc.callable_sig_idx) |sidx| self.resolve_data.getLocalCallable(sidx) else null;

        try self.bindFuncParamTypes(f.params, sig);
        if (f.body) |body| {
            const ret_ty = if (sig != null and sig.?.explicit_ret != null)
                try self.checkCallableBody(body, sig.?.explicit_ret.?)
            else
                try self.synthCallableBody(body);
            try self.local_ret_types.put(self.db.gpa, loc.id.idx, ret_ty);
            if (sig) |s| {
                const fn_ty = try self.funcTypeFromCallableSig(s, ret_ty);
                self.setNodeType(f.id, fn_ty);
            }
        }
    }

    /// 为函数或构造器形参绑定局部符号类型并检查默认实参表达式。
    fn bindFuncParamTypes(
        self: *ItemChecker,
        params: []const common.Param,
        sig: ?*const pkg_state_mod.CallableHeaderSig,
    ) PlatformError!void {
        var idx: usize = 0;
        for (params) |param| {
            if (package_mod.unwrapHirParam(param)) |hp| {
                const p_ty = if (sig != null and idx < sig.?.params.len)
                    sig.?.params[idx].ty
                else if (hp.ty) |ht|
                    self.resolve_data.resolved_types.get(.{ .item = self.global_item.item, .hir = ht.id() }) orelse TypeInterner.err_ty
                else
                    TypeInterner.err_ty;
                try self.setLocalTypeByDeclHir(hp.id, p_ty);
                self.setNodeType(hp.id, p_ty);
                if (hp.default_value) |dv| {
                    _ = try self.checkExpr(dv, p_ty);
                }
                idx += 1;
            }
        }
    }

    /// 获取当前封闭名义类型或 `extend` 的 `This` 类型。
    fn enclosingSelfType(self: *ItemChecker) PlatformError!TypeId {
        const db = self.db;
        const enc = self.enclosing_nominal orelse return TypeInterner.err_ty;
        const entry = db.getDef(enc) catch return TypeInterner.err_ty;
        if (entry.kind == .extend_) {
            const ps = try db.packageState(enc.pkg);
            for (ps.extends) |ext| {
                if (DefId.eql(ext.def, enc)) return ext.target_ty;
            }
            return TypeInterner.err_ty;
        }
        const nh = db.nominalHeaderOf(enc) catch return TypeInterner.err_ty;
        const arg_tys = try db.gpa.alloc(TypeId, nh.type_params.len);
        defer db.gpa.free(arg_tys);
        for (nh.type_params, 0..) |tp, i| {
            arg_tys[i] = try db.types.intern(.{ .type_param = tp });
        }
        const args = try db.types.internList(arg_tys);
        return db.types.intern(.{ .nominal = .{ .def = enc, .args = args } });
    }

    /// 获取当前封闭类的直接父类类型（用于 `super`）。
    fn enclosingSuperType(self: *ItemChecker) PlatformError!TypeId {
        const enc = self.enclosing_nominal orelse return TypeInterner.err_ty;
        const nh = self.db.nominalHeaderOf(enc) catch return TypeInterner.err_ty;
        return if (nh.supertypes.len > 0) nh.supertypes[0] else TypeInterner.err_ty;
    }

    /// 计算单个 `SymbolRef` 作为表达式值使用时的语义类型。
    fn typeOfSymbolRef(
        self: *ItemChecker,
        sym: SymbolRef,
        type_args: []const common.HirType,
        expected: ?TypeId,
    ) PlatformError!TypeId {
        const db = self.db;
        return switch (sym) {
            .local => |l| self.getLocalType(l),
            .prim => |pk| TypeInterner.prim(pk),
            .type_param => |tp| db.types.intern(.{ .type_param = tp }),
            .pkg => TypeInterner.err_ty,
            .def => |d| {
                const entry = db.getDef(d) catch return TypeInterner.err_ty;
                return switch (entry.kind) {
                    .variable, .field, .constant => self.queryVarType(d),
                    .prop => db.propTypeOf(d),
                    .func_, .method, .constructor, .primary_ctor => blk: {
                        const sig = db.callableHeaderSig(.{ .def = d }) catch break :blk TypeInterner.err_ty;
                        break :blk try self.funcTypeFromCallableSig(sig, null);
                    },
                    .enum_variant => self.instantiateEnumCtorValueType(d, expected),
                    .class_, .struct_, .enum_, .interface_ => blk: {
                        const targs = try db.gpa.alloc(TypeId, type_args.len);
                        defer db.gpa.free(targs);
                        for (type_args, 0..) |*ta, i| {
                            targs[i] = self.resolve_data.resolved_types.get(.{ .item = self.global_item.item, .hir = ta.id() }) orelse TypeInterner.err_ty;
                        }
                        const list = try db.types.internList(targs);
                        break :blk try db.types.intern(.{ .nominal = .{ .def = d, .args = list } });
                    },
                    .type_alias => db.typeAliasTargetOf(d),
                    else => TypeInterner.err_ty,
                };
            },
        };
    }

    /// 实例化无参枚举构造器（如 `None`）的值类型，优先借助上下文期望类型推导泛型实参。
    fn instantiateEnumCtorValueType(self: *ItemChecker, ctor_def: DefId, expected: ?TypeId) PlatformError!TypeId {
        const db = self.db;
        const entry = db.getDef(ctor_def) catch return TypeInterner.err_ty;
        const owner = entry.owner orelse return TypeInterner.err_ty;
        if (expected) |exp| {
            const u = db.types.unboxOption(exp);
            if (db.types.get(u) == .nominal and DefId.eql(db.types.get(u).nominal.def, owner)) {
                return u;
            }
        }
        return db.types.intern(.{ .nominal = .{ .def = owner, .args = TypeListId.empty } });
    }

    /// 从重载候选组中根据上下文期望函数类型选取唯一匹配的函数值。
    fn pickFunctionValueCandidate(
        self: *ItemChecker,
        candidates: []const EarlyCandidate,
        expected: ?TypeId,
    ) PlatformError!?SymbolRef {
        if (candidates.len == 1) return candidates[0].ref;
        if (expected) |exp| {
            const u = self.db.types.unboxOption(exp);
            if (self.db.types.get(u) == .func) {
                var matched: ?SymbolRef = null;
                for (candidates) |c| {
                    const fty = try self.typeOfSymbolRef(c.ref, &.{}, null);
                    if (try subtype_mod.isSubtype(self.db, self.global_item.file, fty, u, .{})) {
                        if (matched != null) return null;
                        matched = c.ref;
                    }
                }
                if (matched != null) return matched;
            }
        }
        return candidates[0].ref;
    }

    /// 对声明签名执行低可见性类型暴露检查并在违规时发射诊断。
    fn checkDeclVisibilityExposure(self: *ItemChecker, decl_def: DefId, ty: TypeId, range: common.TextRange) PlatformError!void {
        if (try access_mod.checkVisibilityExposure(self.db, decl_def, ty)) |_| {
            try self.emitDiag(range, .err, "公开声明签名中暴露了低可见性类型");
        }
    }

    /// 检查顶层声明项及其递归成员。
    fn checkTopItem(self: *ItemChecker, item: *const common.HirItem) PlatformError!void {
        const item_id = self.global_item.item;
        const def_opt = findDefForTopItem(self.pkg_state, self.global_item.file, item_id);

        switch (item.*) {
            .func => |f| {
                const def_id = def_opt orelse return;
                const sig = self.db.callableHeaderSig(.{ .def = def_id }) catch null;
                try self.bindFuncParamTypes(f.params, sig);
                if (sig) |s| {
                    for (s.params) |p| try self.checkDeclVisibilityExposure(def_id, p.ty, f.range);
                    if (s.explicit_ret) |er| try self.checkDeclVisibilityExposure(def_id, er, f.range);
                }
                if (f.body) |body| {
                    const ret = if (sig != null and sig.?.explicit_ret != null)
                        try self.checkCallableBody(body, sig.?.explicit_ret.?)
                    else
                        try self.synthCallableBody(body);
                    try self.checkDeclVisibilityExposure(def_id, ret, f.range);
                }
            },
            .main => |m| {
                try self.bindFuncParamTypes(m.params, null);
                if (m.ret_type) |rt| {
                    const rty = self.resolve_data.resolved_types.get(.{ .item = item_id, .hir = rt.id() }) orelse TypeInterner.unit_ty;
                    _ = try self.checkCallableBody(m.body, rty);
                } else {
                    _ = try self.synthCallableBody(m.body);
                }
            },
            .binding => |b| {
                var var_ty: TypeId = TypeInterner.err_ty;
                if (b.ty) |t| {
                    var_ty = self.resolve_data.resolved_types.get(.{ .item = item_id, .hir = t.id() }) orelse TypeInterner.err_ty;
                    if (b.init) |ie| _ = try self.checkExpr(ie, var_ty);
                } else if (b.init) |ie| {
                    var_ty = try self.db.types.replaceIdeal(try self.synthExpr(ie, .none));
                }
                self.setNodeType(b.id, var_ty);
                if (findFirstBindingDef(self.pkg_state, self.global_item.file, item_id, null)) |vdef| {
                    try self.checkDeclVisibilityExposure(vdef, var_ty, b.range);
                }
            },
            .class => |c| if (def_opt) |d| try self.checkContainerMembers(d, c.members),
            .struct_ => |s| if (def_opt) |d| try self.checkContainerMembers(d, s.members),
            .enum_ => |e| if (def_opt) |d| try self.checkContainerMembers(d, e.members),
            .interface => |i| if (def_opt) |d| try self.checkContainerMembers(d, i.members),
            .extend_ => |ex| if (def_opt) |d| try self.checkContainerMembers(d, ex.members),
            .type_alias => |ta| {
                if (def_opt) |d| {
                    const target = try self.db.typeAliasTargetOf(d);
                    try self.checkDeclVisibilityExposure(d, target, ta.range);
                }
            },
            else => {},
        }
    }

    /// 检查容器声明内部全部成员的方法体、构造器体、属性访问器与字段初始化表达式。
    fn checkContainerMembers(self: *ItemChecker, owner_def: DefId, members: []const common.HirItem) PlatformError!void {
        const prev_enc = self.enclosing_nominal;
        self.enclosing_nominal = owner_def;
        defer self.enclosing_nominal = prev_enc;

        const item_id = self.global_item.item;
        for (members, 0..) |*mem, m_idx| {
            const m_def = findDefForMember(self.pkg_state, self.global_item.file, item_id, @intCast(m_idx));
            switch (mem.*) {
                .func => |f| {
                    const sig = if (m_def) |md| self.db.callableHeaderSig(.{ .def = md }) catch null else null;
                    try self.bindFuncParamTypes(f.params, sig);
                    if (m_def) |md| {
                        if (sig) |s| {
                            for (s.params) |p| try self.checkDeclVisibilityExposure(md, p.ty, f.range);
                            if (s.explicit_ret) |er| try self.checkDeclVisibilityExposure(md, er, f.range);
                        }
                    }
                    if (f.body) |body| {
                        const ret = if (sig != null and sig.?.explicit_ret != null)
                            try self.checkCallableBody(body, sig.?.explicit_ret.?)
                        else
                            try self.synthCallableBody(body);
                        if (m_def) |md| try self.checkDeclVisibilityExposure(md, ret, f.range);
                    }
                },
                .init => |in| {
                    const sig = if (m_def) |md| self.db.callableHeaderSig(.{ .def = md }) catch null else null;
                    try self.bindFuncParamTypes(in.params, sig);
                    _ = try self.checkCallableBody(in.body, TypeInterner.unit_ty);
                },
                .primary_ctor => |pc| {
                    const sig = if (m_def) |md| self.db.callableHeaderSig(.{ .def = md }) catch null else null;
                    try self.bindFuncParamTypes(pc.params, sig);
                    _ = try self.checkCallableBody(pc.body, TypeInterner.unit_ty);
                },
                .finalizer => |fin| {
                    try self.bindFuncParamTypes(fin.params, null);
                    _ = try self.checkCallableBody(fin.body, TypeInterner.unit_ty);
                },
                .prop => |p| {
                    const pty = if (m_def) |md| try self.db.propTypeOf(md) else TypeInterner.err_ty;
                    if (m_def) |md| try self.checkDeclVisibilityExposure(md, pty, p.range);
                    for (p.accessors) |acc| {
                        if (std.mem.eql(u8, acc.name.text, "get")) {
                            _ = try self.checkCallableBody(acc.body, pty);
                        } else {
                            for (acc.params) |param| {
                                if (package_mod.unwrapHirParam(param)) |hp| {
                                    try self.setLocalTypeByDeclHir(hp.id, pty);
                                    self.setNodeType(hp.id, pty);
                                }
                            }
                            _ = try self.checkCallableBody(acc.body, TypeInterner.unit_ty);
                        }
                    }
                },
                .binding => |b| {
                    var f_ty: TypeId = TypeInterner.err_ty;
                    if (b.ty) |t| {
                        f_ty = self.resolve_data.resolved_types.get(.{ .item = item_id, .hir = t.id() }) orelse TypeInterner.err_ty;
                        if (b.init) |ie| _ = try self.checkExpr(ie, f_ty);
                    } else if (b.init) |ie| {
                        f_ty = try self.db.types.replaceIdeal(try self.synthExpr(ie, .none));
                    }
                    self.setNodeType(b.id, f_ty);
                    if (findFirstBindingDef(self.pkg_state, self.global_item.file, item_id, @intCast(m_idx))) |fdef| {
                        try self.checkDeclVisibilityExposure(fdef, f_ty, b.range);
                    }
                },
                else => {},
            }
        }
    }
};

/// 将二元运算符标签映射为仓颉 `operator func` 符号文本。
fn binaryOpName(op: common.BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
        .exp => "**",
        .eq => "==",
        .ne => "!=",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .bit_and => "&",
        .bit_or => "|",
        .bit_xor => "^",
        .lshift => "<<",
        .rshift => ">>",
        else => "",
    };
}

/// 按 `(file, item_id)` 查找顶层声明对应的 `DefId`。
fn findDefForTopItem(ps: *const PackageState, file: common.FileId, item_id: common.ItemId) ?DefId {
    const file_defs = ps.file_defs.get(file) orelse return null;
    for (file_defs) |def_id| {
        const entry = ps.getDef(def_id.idx) orelse continue;
        if (entry.origin) |orig| {
            if (orig == .top_item and orig.top_item.item == item_id) return def_id;
        }
    }
    return null;
}

/// 按 `(file, item_id, member_idx)` 查找容器成员对应的 `DefId`。
fn findDefForMember(ps: *const PackageState, file: common.FileId, item_id: common.ItemId, member_idx: u32) ?DefId {
    const file_defs = ps.file_defs.get(file) orelse return null;
    for (file_defs) |def_id| {
        const entry = ps.getDef(def_id.idx) orelse continue;
        if (entry.origin) |orig| {
            if (orig == .member and orig.member.item == item_id and orig.member.member_idx == member_idx) return def_id;
        }
    }
    return null;
}

/// 查找顶层或成员绑定声明对应的首个变量 `DefId`。
fn findFirstBindingDef(ps: *const PackageState, file: common.FileId, item_id: common.ItemId, member_idx: ?u32) ?DefId {
    const file_defs = ps.file_defs.get(file) orelse return null;
    for (file_defs) |def_id| {
        const entry = ps.getDef(def_id.idx) orelse continue;
        if (entry.origin) |orig| {
            if (orig == .binding_var and orig.binding_var.item == item_id and orig.binding_var.member_idx == member_idx) {
                return def_id;
            }
        }
    }
    return null;
}

/// 执行单个顶层声明项的双向类型检查与晚绑定。
/// 返回指针借用自 `FileQueryState.sema_arena`，在下次文件编辑或包失效前有效，调用者不得释放。
pub fn typeCheckItem(db: *Database, global_item: GlobalItemId) PlatformError!*const ItemTypeckData {
    const fstate = db.file_states.get(global_item.file) orelse return error.InvalidFileId;
    const lowered = try db.lower(global_item.file);
    const idx = global_item.item.index();
    if (idx >= lowered.lowered_items.len) return error.InvalidItemId;

    const resolve_data = try db.resolve(global_item.file);
    const pkg_state = try db.packageState(resolve_data.pkg_id);
    const a = fstate.sema_arena.allocator();

    var checker = try ItemChecker.init(db, a, global_item, resolve_data, pkg_state, &lowered.lowered_items[idx]);
    defer checker.deinit();

    const item = package_mod.unwrapMacroItem(lowered.lowered_items[idx].item);
    try checker.checkTopItem(item);

    std.mem.sort(ResolvedIdentOccurrence, checker.late_occurrences.items, {}, ResolvedIdentOccurrence.lessThan);

    const out = try a.create(ItemTypeckData);
    out.* = .{
        .global_item = global_item,
        .file_version = lowered.hir_file.version,
        .verified_revision = db.revision,
        .node_types = checker.node_types,
        .late_bindings = checker.late_bindings,
        .instantiated_type_args = checker.instantiated_type_args,
        .late_occurrences = try checker.late_occurrences.toOwnedSlice(a),
        .outgoing_refs = try checker.outgoing_refs.toOwnedSlice(a),
        .inferred_deps = try checker.inferred_deps.toOwnedSlice(a),
        .diagnostics = try checker.diagnostics.toOwnedSlice(a),
    };
    return out;
}

/// 按需推导省略返回类型函数或方法的最终返回类型（供 `Database.returnTypeOf` 调用）。
pub fn inferFuncReturnType(db: *Database, def_id: DefId) PlatformError!TypeId {
    const entry = try db.getDef(def_id);
    const origin = entry.origin orelse return TypeInterner.unit_ty;
    const file = origin.fileId();
    const item_id = origin.itemId();
    const lowered = try db.lower(file);
    if (item_id.index() >= lowered.lowered_items.len) return TypeInterner.err_ty;

    const resolve_data = try db.resolve(file);
    const pkg_state = try db.packageState(def_id.pkg);

    var tmp_arena = std.heap.ArenaAllocator.init(db.gpa);
    defer tmp_arena.deinit();

    var checker = try ItemChecker.init(db, tmp_arena.allocator(), .{ .file = file, .item = item_id }, resolve_data, pkg_state, &lowered.lowered_items[item_id.index()]);
    defer checker.deinit();
    checker.enclosing_nominal = entry.owner;

    const top = package_mod.unwrapMacroItem(lowered.lowered_items[item_id.index()].item);
    const fn_item: ?*const common.FuncItem = switch (origin) {
        .top_item => if (top.* == .func) &top.func else null,
        .member => |m| blk: {
            const mem = package_mod.getContainerMember(top, m.member_idx) orelse break :blk null;
            break :blk if (mem.* == .func) &mem.func else null;
        },
        else => null,
    };
    const f = fn_item orelse return TypeInterner.unit_ty;
    const sig = db.callableHeaderSig(.{ .def = def_id }) catch null;
    try checker.bindFuncParamTypes(f.params, sig);
    const body = f.body orelse return TypeInterner.unit_ty;
    return checker.synthCallableBody(body);
}

/// 按需推导省略类型注解的顶层或成员 `let`/`var`/`const` 变量类型（供 `Database.varTypeOf` 调用）。
pub fn inferVarType(db: *Database, def_id: DefId) PlatformError!TypeId {
    const entry = try db.getDef(def_id);
    const origin = entry.origin orelse return TypeInterner.err_ty;
    if (origin != .binding_var) return TypeInterner.err_ty;
    const bv = origin.binding_var;
    const lowered = try db.lower(bv.file);
    if (bv.item.index() >= lowered.lowered_items.len) return TypeInterner.err_ty;

    const resolve_data = try db.resolve(bv.file);
    const pkg_state = try db.packageState(def_id.pkg);

    var tmp_arena = std.heap.ArenaAllocator.init(db.gpa);
    defer tmp_arena.deinit();

    var checker = try ItemChecker.init(db, tmp_arena.allocator(), .{ .file = bv.file, .item = bv.item }, resolve_data, pkg_state, &lowered.lowered_items[bv.item.index()]);
    defer checker.deinit();
    checker.enclosing_nominal = entry.owner;

    const top = package_mod.unwrapMacroItem(lowered.lowered_items[bv.item.index()].item);
    const b_item = if (bv.member_idx) |midx|
        package_mod.getContainerMember(top, midx) orelse return TypeInterner.err_ty
    else
        top;
    if (b_item.* != .binding) return TypeInterner.err_ty;
    const init_e = b_item.binding.init orelse return TypeInterner.err_ty;
    const init_ty = try db.types.replaceIdeal(try checker.synthExpr(init_e, .none));
    return extractPatternTypeAt(db, b_item.binding.pattern, init_ty, bv.pat_ordinal);
}

/// 从解构绑定模式中按第 `target` 个绑定位置提取对应的元素类型。
fn extractPatternTypeAt(
    db: *Database,
    pat: *const common.HirPattern,
    whole_ty: TypeId,
    target: u32,
) TypeId {
    var cursor: u32 = 0;
    return extractPatternTypeRec(db, pat, whole_ty, target, &cursor) orelse whole_ty;
}

/// 递归查找模式中第 `target` 个绑定对应的子类型。
fn extractPatternTypeRec(
    db: *Database,
    pat: *const common.HirPattern,
    cur_ty: TypeId,
    target: u32,
    cursor: *u32,
) ?TypeId {
    switch (pat.*) {
        .binding => {
            const c = cursor.*;
            cursor.* += 1;
            return if (c == target) cur_ty else null;
        },
        .typed => |tp| {
            if (tp.name != null) {
                const c = cursor.*;
                cursor.* += 1;
                return if (c == target) cur_ty else null;
            }
            return null;
        },
        .tuple => |tup| {
            const elems = if (db.types.get(cur_ty) == .tuple) db.types.getList(db.types.get(cur_ty).tuple) else &.{};
            for (tup.elements, 0..) |*el, i| {
                const sub_ty = if (i < elems.len) elems[i] else TypeInterner.err_ty;
                if (extractPatternTypeRec(db, el, sub_ty, target, cursor)) |found| return found;
            }
            return null;
        },
        else => return null,
    }
}
