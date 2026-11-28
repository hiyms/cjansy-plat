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
    /// 当前是否位于构造器体内部（允许对当前类型的 `let` 字段执行初始化赋值）。
    in_ctor: bool = false,
    /// 当前是否位于静态初始化器 `static init` 内部。
    in_static_ctor: bool = false,
    /// 当前是否位于 `mut` 实例方法内部（允许在 `struct` 中修改实例字段）。
    in_mut_method: bool = false,
    /// 当前是否处于可选链接收者中间求值过程（仅在最外层包裹唯一一层 `Option`）。
    in_optional_chain: bool = false,
    /// 当前被检查可调用体的返回类型目标（`null` 表示正在推导省略返回类型）。
    current_expected_ret: ?TypeId = null,
    /// 当前省略返回类型函数体收集到的全部 `return` 表达式类型。
    collected_returns: ?*std.ArrayListUnmanaged(TypeId) = null,
    /// 当前正在推导省略返回类型的包级函数或方法定义与声明区间（用于检测无标注递归并产生诊断）。
    current_inferring_ret_def: ?DefId = null,
    current_inferring_ret_range: common.TextRange = common.TextRange.zero,
    /// 当前正在推导省略类型的包级变量或字段定义与声明区间（用于检测循环初始化并产生诊断）。
    current_inferring_var_def: ?DefId = null,
    current_inferring_var_range: common.TextRange = common.TextRange.zero,
    /// 当前正在推导省略返回类型的局部函数符号与声明区间。
    current_inferring_local_fn: ?LocalSymId = null,
    current_inferring_local_range: common.TextRange = common.TextRange.zero,
    /// 标记当前正在推导的声明是否已发射过递归截断诊断，避免单函数体内多次递归调用重复报错。
    reported_infer_cycle: bool = false,
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
        if (self.current_inferring_local_fn) |cur_loc| {
            if (LocalSymId.eql(cur_loc, loc_id)) {
                if (!self.reported_infer_cycle) {
                    self.reported_infer_cycle = true;
                    try self.emitDiag(self.current_inferring_local_range, .err, "无显式返回类型标注的递归局部函数无法推导返回类型");
                }
                return TypeInterner.err_ty;
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
        if (self.current_inferring_ret_def) |cur_def| {
            if (DefId.eql(cur_def, def_id)) {
                try self.db.cyclic_inferred_defs.put(self.db.gpa, def_id, {});
                if (!self.reported_infer_cycle) {
                    self.reported_infer_cycle = true;
                    try self.emitDiag(self.current_inferring_ret_range, .err, "无显式返回类型标注的递归函数无法推导返回类型");
                }
                return TypeInterner.err_ty;
            }
        }
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
        if (self.current_inferring_var_def) |cur_def| {
            if (DefId.eql(cur_def, def_id)) {
                try self.db.cyclic_inferred_defs.put(self.db.gpa, def_id, {});
                if (!self.reported_infer_cycle) {
                    self.reported_infer_cycle = true;
                    try self.emitDiag(self.current_inferring_var_range, .err, "无显式类型标注的变量存在循环初始化依赖，无法推导类型");
                }
                return TypeInterner.err_ty;
            }
        }
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
                if (u.op == .neg and u.operand.* == .float_lit and u.operand.float_lit.suffix == null) {
                    if (db.types.get(unboxed_exp) == .prim and db.types.get(unboxed_exp).prim.isFloat()) {
                        const st = literal_mod.checkNumericLiteralRange(db.config.target, u.operand.float_lit.text, true, unboxed_exp);
                        if (st == .float_overflow) {
                            try self.emitDiag(u.range, .err, "负浮点字面量超出目标浮点类型范围");
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
            .call => |c| return self.checkCallExpr(&c, expected, .none),
            .field => |f| {
                const syn = try self.resolveFieldExpr(&f, expected, .none);
                try self.checkAssignable(f.range, syn, expected);
                return syn;
            },
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
                const syn = try self.resolvePathExpr(&p, expected, false);
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
    pub fn checkAssignable(self: *ItemChecker, range: common.TextRange, actual: TypeId, expected: TypeId) PlatformError!void {
        if (self.db.types.hasErr(actual) or self.db.types.hasErr(expected) or expected == TypeInterner.quest_ty) return;
        if (!try subtype_mod.isSubtype(self.db, self.global_item.file, actual, expected, .{})) {
            try self.emitDiag(range, .err, "表达式类型与期望类型不兼容");
        }
    }

    /// 在可选链中间求值上下文中综合操作数类型，使嵌套成员/调用/下标不重复包裹 `Option`。
    fn synthOptionalChainOperand(self: *ItemChecker, expr: *const common.HirExpr) PlatformError!TypeId {
        const prev = self.in_optional_chain;
        self.in_optional_chain = true;
        defer self.in_optional_chain = prev;
        return self.synthExpr(expr, .none);
    }

    /// 判定基础类型显式转换 `Target(val)` 是否符合仓颉语言规范。
    fn isValidPrimTypeConv(target_data: type_interner_mod.TypeData, val_data: type_interner_mod.TypeData) bool {
        if (target_data != .prim or val_data != .prim) return false;
        const is_nothing = (target_data.prim == .rune or target_data.prim.isNumeric()) and val_data.prim == .nothing;
        const is_rune_to_u32 = target_data.prim == .uint32 and val_data.prim == .rune;
        const is_int_to_rune = target_data.prim == .rune and val_data.prim.isInteger();
        const is_num_to_num = target_data.prim.isNumeric() and val_data.prim.isNumeric();
        return is_nothing or is_rune_to_u32 or is_int_to_rune or is_num_to_num;
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
            .wildcard => |w| {
                if (pos != .left_value) {
                    try self.emitDiag(w.range, .err, "通配符 _ 不能作为表达式值使用");
                }
                return TypeInterner.err_ty;
            },
            .path => |p| return self.resolvePathExpr(&p, null, false),
            .field => |f| return self.resolveFieldExpr(&f, null, pos),
            .optional => |o| {
                const op_ty = try self.synthOptionalChainOperand(o.operand);
                if (op_ty == TypeInterner.err_ty) return TypeInterner.err_ty;
                return db.types.unwrapOptionOnce(op_ty) orelse blk: {
                    try self.emitDiag(o.range, .err, "可选链运算符 ? 的操作数必须为 Option<T> 类型");
                    break :blk TypeInterner.err_ty;
                };
            },
            .call => |c| return self.checkCallExpr(&c, null, pos),
            .index => |idx| return self.checkIndexExpr(&idx, pos),
            .inc_dec => |id_e| {
                const op_ty = try self.synthExpr(id_e.operand, .left_value);
                try self.checkAssignableLValue(id_e.operand, false);
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
                if (asg.lhs.* == .wildcard) {
                    if (asg.op != .assign) {
                        try self.emitDiag(asg.range, .err, "通配符 _ 不支持复合赋值运算");
                    }
                    _ = try self.synthExpr(asg.rhs, .none);
                    return TypeInterner.unit_ty;
                }
                if (asg.lhs.* == .tuple_lit) {
                    if (asg.op != .assign) {
                        try self.emitDiag(asg.range, .err, "多赋值表达式不支持复合赋值运算符");
                    }
                    const rhs_ty = try db.types.replaceIdeal(try self.synthExpr(asg.rhs, .none));
                    try self.checkMultiAssignTuple(&asg.lhs.tuple_lit, rhs_ty);
                    self.setNodeType(asg.lhs.id(), rhs_ty);
                    return TypeInterner.unit_ty;
                }
                const lhs_ty = try self.synthExpr(asg.lhs, .left_value);
                try self.checkAssignableLValue(asg.lhs, asg.op == .assign);
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
                if (target == TypeInterner.err_ty) return TypeInterner.err_ty;
                return db.types.internOption(target);
            },
            .type_conv => |tc| {
                const raw_val = try self.synthExpr(tc.value, .none);
                const val_ty = try db.types.replaceIdeal(raw_val);
                const target_ty = self.resolve_data.resolved_types.get(.{ .item = self.global_item.item, .hir = tc.ty.id() }) orelse TypeInterner.err_ty;
                if (val_ty == TypeInterner.err_ty or target_ty == TypeInterner.err_ty) return target_ty;

                if (!isValidPrimTypeConv(db.types.get(target_ty), db.types.get(val_ty))) {
                    try self.emitDiag(tc.range, .err, "不支持将该类型转换为目标基础类型");
                    return TypeInterner.err_ty;
                }
                return target_ty;
            },
            .varray => |va| {
                const va_ty = self.resolve_data.resolved_types.get(.{ .item = self.global_item.item, .hir = va.ty.id() }) orelse TypeInterner.err_ty;
                if (va_ty != TypeInterner.err_ty and db.types.get(va_ty) == .varray) {
                    const elem_ty = db.types.get(va_ty).varray.elem;
                    const init_fn_ty = try db.types.intern(.{ .func = .{
                        .params = try db.types.internList(&.{TypeInterner.int64_ty}),
                        .ret = elem_ty,
                        .is_cfunc = false,
                    } });
                    if (va.args.len == 1 and va.trailing_lambda == null) {
                        const arg = va.args[0];
                        if (arg.name) |an| {
                            if (std.mem.eql(u8, an.text, "repeat") or std.mem.eql(u8, an.text, "item")) {
                                _ = try self.checkExpr(arg.value, elem_ty);
                            } else {
                                try self.emitDiag(an.range, .err, "VArray 构造器不识别该命名实参");
                                _ = try self.synthExpr(arg.value, .expr_arg);
                            }
                        } else {
                            _ = try self.checkExpr(arg.value, init_fn_ty);
                        }
                    } else if (va.args.len == 0 and va.trailing_lambda != null) {
                        _ = try self.checkExpr(va.trailing_lambda.?, init_fn_ty);
                    } else {
                        try self.emitDiag(va.range, .err, "VArray 构造器实参个数不合法");
                        for (va.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
                        if (va.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
                    }
                    return va_ty;
                }
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

    /// 递归检查多赋值表达式左侧元组与右侧元组类型的元素个数、左值可变性及逐位兼容性。
    fn checkMultiAssignTuple(
        self: *ItemChecker,
        lhs_tuple: *const common.TupleLit,
        rhs_ty: TypeId,
    ) PlatformError!void {
        const db = self.db;
        const rhs_elems: ?[]const TypeId = if (rhs_ty == TypeInterner.err_ty)
            null
        else if (db.types.get(rhs_ty) == .tuple)
            db.types.getList(db.types.get(rhs_ty).tuple)
        else blk: {
            try self.emitDiag(lhs_tuple.range, .err, "多赋值右侧表达式必须为元组类型");
            break :blk null;
        };

        if (rhs_elems) |re| {
            if (re.len != lhs_tuple.elements.len) {
                try self.emitDiag(lhs_tuple.range, .err, "多赋值左侧与右侧元组元素个数不匹配");
            }
        }

        for (lhs_tuple.elements, 0..) |*el, i| {
            const elem_rhs_ty: TypeId = if (rhs_elems) |re|
                (if (i < re.len) re[i] else TypeInterner.err_ty)
            else
                TypeInterner.err_ty;
            switch (el.*) {
                .wildcard => {
                    self.setNodeType(el.id(), elem_rhs_ty);
                },
                .tuple_lit => |*sub_tup| {
                    try self.checkMultiAssignTuple(sub_tup, elem_rhs_ty);
                    self.setNodeType(el.id(), elem_rhs_ty);
                },
                else => {
                    const el_ty = try self.synthExpr(el, .left_value);
                    try self.checkAssignableLValue(el, true);
                    if (el_ty != TypeInterner.err_ty and elem_rhs_ty != TypeInterner.err_ty) {
                        try self.checkAssignable(el.range(), elem_rhs_ty, el_ty);
                    }
                },
            }
        }
    }

    /// 判定语义类型是否为值类型（基础类型、`struct`、`enum`、`VArray`、元组）。
    fn isValueType(self: *ItemChecker, ty: TypeId) bool {
        return switch (self.db.types.get(ty)) {
            .prim, .varray, .tuple => true,
            .nominal => |nom| blk: {
                const de = self.db.getDef(nom.def) catch break :blk false;
                break :blk de.kind == .struct_ or de.kind == .enum_;
            },
            else => false,
        };
    }

    /// 校验可选链赋值中所有 `?` 解包接收者均为引用类型（仓颉禁止对值类型的可选链表达式赋值）。
    fn checkOptionalChainRefReceivers(self: *ItemChecker, expr: *const common.HirExpr) PlatformError!void {
        switch (expr.*) {
            .optional => |o| {
                const idx = o.id.index();
                const unwrapped_ty = if (idx < self.node_types.len) self.node_types[idx] else TypeInterner.err_ty;
                if (unwrapped_ty != TypeInterner.err_ty and self.isValueType(unwrapped_ty)) {
                    try self.emitDiag(o.range, .err, "值类型的可选链表达式不能作为赋值左值");
                }
                try self.checkOptionalChainRefReceivers(o.operand);
            },
            .field => |f| try self.checkOptionalChainRefReceivers(f.base),
            .call => |c| try self.checkOptionalChainRefReceivers(c.callee),
            .index => |i| try self.checkOptionalChainRefReceivers(i.base),
            else => {},
        }
    }

    /// 判定容器定义是否为 `struct` 值类型。
    fn isStructDef(self: *ItemChecker, def_id: DefId) bool {
        const de = self.db.getDef(def_id) catch return false;
        return de.kind == .struct_;
    }

    /// 校验赋值或自增自减的左值表达式合法性与可变性。
    fn checkAssignableLValue(self: *ItemChecker, lhs: *const common.HirExpr, is_plain_assign: bool) PlatformError!void {
        const db = self.db;
        switch (lhs.*) {
            .index => |idx| {
                if (isOptionalChainBase(idx.base)) {
                    try self.checkOptionalChainRefReceivers(idx.base);
                }
                const b_idx = idx.base.id().index();
                var base_ty = if (b_idx < self.node_types.len) self.node_types[b_idx] else TypeInterner.err_ty;
                if (base_ty == TypeInterner.err_ty) return;
                if (isOptionalChainBase(idx.base) and idx.base.* != .optional) {
                    base_ty = db.types.unwrapOptionOnce(base_ty) orelse base_ty;
                }
                switch (db.types.get(base_ty)) {
                    .tuple => {
                        try self.emitDiag(idx.range, .err, "元组元素不可通过下标修改");
                    },
                    .varray => {
                        try self.checkAssignableLValue(idx.base, is_plain_assign);
                    },
                    .cpointer => {},
                    .nominal => |nom| {
                        if (db.types.known.array_struct != null and DefId.eql(nom.def, db.types.known.array_struct.?)) {
                            return;
                        }
                        if (db.types.known.string_struct != null and DefId.eql(nom.def, db.types.known.string_struct.?)) {
                            try self.emitDiag(idx.range, .err, "String 字符不可通过下标修改");
                            return;
                        }
                        // 检查名义类型是否定义了 set 形式的 `operator func [](idx..., value!: V)`
                        const op_id = try db.strings.intern("[]");
                        const cands = try self.collectMemberCandidates(base_ty, op_id, true);
                        const access_ctx = self.currentAccessContext();
                        var has_setter = false;
                        for (cands) |c| {
                            if (c.ref != .def) continue;
                            if (!try access_mod.checkAccess(db, c.ref.def, base_ty, access_ctx)) continue;
                            const sig = db.callableHeaderSig(.{ .def = c.ref.def }) catch continue;
                            if (sig.params.len == idx.indices.len + 1) {
                                has_setter = true;
                                break;
                            }
                        }
                        if (!has_setter) {
                            try self.emitDiag(idx.range, .err, "该类型未定义可写下标运算符 []");
                        }
                    },
                    else => {},
                }
            },
            .path => |p| {
                const key: common.HirKey = .{ .item = self.global_item.item, .hir = p.id };
                const sym_opt: ?SymbolRef = if (p.segments.len == 1)
                    self.resolve_data.early_bindings.get(key)
                else
                    self.late_bindings.get(p.id);
                const sym = sym_opt orelse return;
                const is_this_prefix = p.segments.len >= 2 and !p.segments[0].name.is_raw and std.mem.eql(u8, p.segments[0].name.text, "this");
                const is_this_member = p.segments.len == 1 or (p.segments.len == 2 and is_this_prefix);
                try self.checkSymbolMutable(lhs.range(), sym, is_this_member, is_plain_assign);

                // 校验 struct 值类型实例字段的接收者可变性
                if (sym == .def) {
                    const entry = db.getDef(sym.def) catch return;
                    if (entry.kind == .field and !entry.flags.is_static) {
                        if (is_this_member) {
                            if (entry.owner != null and self.isStructDef(entry.owner.?) and !self.in_ctor and !self.in_mut_method) {
                                try self.emitDiag(lhs.range(), .err, "在 struct 非 mut 方法中不能修改实例字段");
                            }
                        } else if (p.segments.len >= 2 and entry.owner != null and self.isStructDef(entry.owner.?)) {
                            if (self.resolve_data.early_bindings.get(key)) |root_sym| {
                                const root_ty = try self.typeOfSymbolRef(root_sym, p.segments[0].type_args, null);
                                if (root_ty != TypeInterner.err_ty and self.isValueType(root_ty)) {
                                    const root_mut = switch (root_sym) {
                                        .local => |lid| if (self.resolve_data.getLocal(lid.idx)) |loc| loc.is_mut else true,
                                        .def => |did| if (db.getDef(did)) |de| switch (de.kind) {
                                            .variable, .constant, .field => de.flags.is_mut,
                                            else => true,
                                        } else |_| true,
                                        else => true,
                                    };
                                    if (!root_mut) {
                                        try self.emitDiag(lhs.range(), .err, "不能修改不可变值类型的字段");
                                    }
                                }
                            }
                        }
                    }
                }
            },
            .field => |f| {
                if (isOptionalChainBase(f.base)) {
                    try self.checkOptionalChainRefReceivers(f.base);
                }
                const sym = self.late_bindings.get(f.id) orelse return;
                try self.checkSymbolMutable(lhs.range(), sym, false, is_plain_assign);
                if (sym == .def) {
                    const entry = db.getDef(sym.def) catch return;
                    if (entry.kind == .field and !entry.flags.is_static and !isOptionalChainBase(f.base)) {
                        const b_idx = f.base.id().index();
                        const base_ty = if (b_idx < self.node_types.len) self.node_types[b_idx] else TypeInterner.err_ty;
                        if (base_ty != TypeInterner.err_ty and self.isValueType(base_ty)) {
                            try self.checkAssignableLValue(f.base, is_plain_assign);
                        }
                    }
                }
            },
            else => {
                const lhs_ty = if (lhs.id().index() < self.node_types.len) self.node_types[lhs.id().index()] else TypeInterner.err_ty;
                if (lhs_ty != TypeInterner.err_ty) {
                    try self.emitDiag(lhs.range(), .err, "赋值左侧必须为可修改的左值表达式");
                }
            },
        }
    }

    /// 校验目标符号是否允许作为赋值或自增自减目标。
    fn checkSymbolMutable(
        self: *ItemChecker,
        range: common.TextRange,
        sym: SymbolRef,
        is_this_member: bool,
        is_plain_assign: bool,
    ) PlatformError!void {
        switch (sym) {
            .local => |loc_id| {
                const loc = self.resolve_data.getLocal(loc_id.idx) orelse return;
                if (!loc.is_mut) {
                    try self.emitDiag(range, .err, "不能对不可变局部变量或形参赋值");
                }
            },
            .def => |def_id| {
                const entry = self.db.getDef(def_id) catch return;
                switch (entry.kind) {
                    .variable, .constant => {
                        if (!entry.flags.is_mut) {
                            try self.emitDiag(range, .err, "不能对不可变变量或常量赋值");
                        }
                    },
                    .field => {
                        if (!entry.flags.is_mut) {
                            // 仅允许在对应静态/实例构造器体内以普通赋值 `=` 对自身 `let` 字段执行初始化
                            const ctor_match = if (entry.flags.is_static)
                                self.in_static_ctor
                            else
                                self.in_ctor and !self.in_static_ctor;
                            const ctor_init_ok = is_plain_assign and ctor_match and is_this_member and
                                self.enclosing_nominal != null and entry.owner != null and
                                DefId.eql(self.enclosing_nominal.?, entry.owner.?);
                            if (!ctor_init_ok) {
                                try self.emitDiag(range, .err, "不能对不可变字段赋值");
                            }
                        }
                    },
                    .prop => {
                        if (!entry.flags.is_mut) {
                            try self.emitDiag(range, .err, "不能对只读属性赋值");
                        }
                    },
                    else => {
                        try self.emitDiag(range, .err, "赋值左侧必须为可修改的左值表达式");
                    },
                }
            },
            else => {
                try self.emitDiag(range, .err, "赋值左侧必须为可修改的左值表达式");
            },
        }
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
        if (literal_mod.checkNumericLiteralRange(self.db.config.target, fl.text, false, TypeInterner.ideal_float_ty) == .float_overflow) {
            try self.emitDiag(fl.range, .err, "浮点字面量超出 Float64 表示范围");
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
                if (literal_mod.checkNumericLiteralRange(db.config.target, u.operand.float_lit.text, true, TypeInterner.ideal_float_ty) == .float_overflow) {
                    try self.emitDiag(u.range, .err, "负浮点字面量超出 Float64 表示范围");
                }
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

    /// 单参数可调用对象的参数与返回类型对。
    const UnaryCallableSig = struct {
        param: TypeId,
        ret: TypeId,
    };

    /// 单参数可调用对象的签名提取结果（覆盖函数类型与单参数 `operator func ()`）。
    const UnaryCallableResult = union(enum) {
        ok: UnaryCallableSig,
        wrong_arity,
        not_callable,
    };

    /// 提取单参数函数类型或单参数 `operator func ()` 重载的参数与返回类型。
    fn extractUnaryCallableSig(self: *ItemChecker, ty: TypeId) PlatformError!UnaryCallableResult {
        const db = self.db;
        if (db.types.get(ty) == .func) {
            const f = db.types.get(ty).func;
            const ps = db.types.getList(f.params);
            if (ps.len != 1) return .wrong_arity;
            return .{ .ok = .{ .param = ps[0], .ret = f.ret } };
        }
        const call_op_id = try db.strings.intern("()");
        const cands = try self.collectMemberCandidates(ty, call_op_id, true);
        if (cands.len == 0) return .not_callable;
        const access_ctx = self.currentAccessContext();
        var saw_any_visible = false;
        var matched: ?UnaryCallableSig = null;
        for (cands) |c| {
            if (c.ref != .def) continue;
            if (!try access_mod.checkAccess(db, c.ref.def, ty, access_ctx)) continue;
            saw_any_visible = true;
            const sig = db.callableHeaderSig(.{ .def = c.ref.def }) catch continue;
            if (sig.params.len != 1) continue;
            var p_ty = sig.params[0].ty;
            var r_ty = sig.explicit_ret orelse try self.queryReturnType(c.ref.def);
            if (db.types.get(ty) == .nominal) {
                const nom = db.types.get(ty).nominal;
                if (db.nominalHeaderOf(nom.def)) |nh| {
                    const targs = db.types.getList(nom.args);
                    p_ty = try subtype_mod.substituteNominalParams(db, p_ty, nh.type_params, targs);
                    r_ty = try subtype_mod.substituteNominalParams(db, r_ty, nh.type_params, targs);
                } else |_| {}
            }
            if (matched != null) return .not_callable;
            matched = .{ .param = p_ty, .ret = r_ty };
        }
        if (matched) |m| return .{ .ok = m };
        return if (saw_any_visible) .wrong_arity else .not_callable;
    }

    /// 判定两类型是否支持内建等值比较（数值、基础类型、`String`、`Range<T>`、`Option<T>`/裸 `None` 及同维度元组递归）。
    fn supportsBuiltinEquality(self: *ItemChecker, lhs_ty: TypeId, rhs_ty: TypeId) PlatformError!bool {
        const db = self.db;
        if (lhs_ty == TypeInterner.err_ty or rhs_ty == TypeInterner.err_ty) return false;
        const ld = db.types.get(lhs_ty);
        const rd = db.types.get(rhs_ty);

        // 相同基础类型（含 Ideal 与数值类型配对）
        const lhs_int = ld == .ideal_int or (ld == .prim and ld.prim.isInteger());
        const rhs_int = rd == .ideal_int or (rd == .prim and rd.prim.isInteger());
        if (lhs_int and rhs_int) {
            return lhs_ty == rhs_ty or ld == .ideal_int or rd == .ideal_int;
        }
        const lhs_flt = ld == .ideal_float or (ld == .prim and ld.prim.isFloat());
        const rhs_flt = rd == .ideal_float or (rd == .prim and rd.prim.isFloat());
        if (lhs_flt and rhs_flt) {
            return lhs_ty == rhs_ty or ld == .ideal_float or rd == .ideal_float;
        }
        if (ld == .prim and rd == .prim and lhs_ty == rhs_ty) {
            return ld.prim == .bool_ or ld.prim == .rune or ld.prim == .unit;
        }

        // String 内建相等比较
        if (db.types.known.string_struct) |sdef| {
            if (ld == .nominal and rd == .nominal and DefId.eql(ld.nominal.def, sdef) and DefId.eql(rd.nominal.def, sdef)) {
                return true;
            }
        }

        // Range<T> 内建相等比较
        if (db.types.known.range_struct) |rdef| {
            if (ld == .nominal and rd == .nominal and DefId.eql(ld.nominal.def, rdef) and DefId.eql(rd.nominal.def, rdef)) {
                return subtype_mod.isTypeEqual(db, self.global_item.file, lhs_ty, rhs_ty);
            }
        }

        // Option<T> 等值比较（支持无期望类型时的裸 None，其类型为 Option<> 且 args 为空）
        if (db.types.known.option_enum) |odef| {
            if (ld == .nominal and rd == .nominal and DefId.eql(ld.nominal.def, odef) and DefId.eql(rd.nominal.def, odef)) {
                if (ld.nominal.args == TypeListId.empty or rd.nominal.args == TypeListId.empty) {
                    return true;
                }
                return subtype_mod.isTypeEqual(db, self.global_item.file, lhs_ty, rhs_ty);
            }
        }

        // 元组按逐元素等值性递归判定
        if (ld == .tuple and rd == .tuple) {
            const le = db.types.getList(ld.tuple);
            const re = db.types.getList(rd.tuple);
            if (le.len != re.len) return false;
            const eq_id = try db.strings.intern("==");
            for (le, re) |lt, rt| {
                if (try self.supportsBuiltinEquality(lt, rt)) continue;
                // 若元素类型自身重载了 `operator func ==`，亦允许元组等值比较
                const cands = try self.collectMemberCandidates(lt, eq_id, true);
                var elem_eq = false;
                for (cands) |c| {
                    if (c.ref != .def) continue;
                    const sig = db.callableHeaderSig(.{ .def = c.ref.def }) catch continue;
                    if (sig.params.len == 1 and try subtype_mod.isSubtype(db, self.global_item.file, rt, sig.params[0].ty, .{})) {
                        elem_eq = true;
                        break;
                    }
                }
                if (!elem_eq) return false;
            }
            return true;
        }

        return false;
    }

    /// 检查二元运算表达式：遵循仓颉算术运算字面量双向窄化、求幂规则、内置等值比较与运算符重载。
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
                return self.checkCallExpr(&synth_call, expected, .none);
            },
            .composition => {
                const l_ty = try self.synthExpr(b.lhs, .none);
                const r_ty = try self.synthExpr(b.rhs, .none);
                if (l_ty == TypeInterner.err_ty or r_ty == TypeInterner.err_ty) return TypeInterner.err_ty;
                const l_res = try self.extractUnaryCallableSig(l_ty);
                const r_res = try self.extractUnaryCallableSig(r_ty);
                if (l_res == .not_callable or r_res == .not_callable) {
                    try self.emitDiag(b.range, .err, "函数组合运算符 ~> 两侧必须为函数类型或可调用类型");
                    return TypeInterner.err_ty;
                }
                if (l_res == .wrong_arity or r_res == .wrong_arity) {
                    try self.emitDiag(b.range, .err, "函数组合运算符 ~> 两侧必须为单参数函数或可调用类型");
                    return TypeInterner.err_ty;
                }
                const l_sig = l_res.ok;
                const r_sig = r_res.ok;
                if (!try subtype_mod.isSubtype(db, self.global_item.file, l_sig.ret, r_sig.param, .{})) {
                    try self.emitDiag(b.range, .err, "函数组合运算符 ~> 左侧返回类型与右侧形参类型不兼容");
                    return TypeInterner.err_ty;
                }
                return db.types.intern(.{ .func = .{
                    .params = try db.types.internList(&.{l_sig.param}),
                    .ret = r_sig.ret,
                    .is_cfunc = false,
                } });
            },
            .add, .sub, .mul, .div, .mod, .exp, .bit_and, .bit_or, .bit_xor, .lshift, .rshift, .eq, .ne, .lt, .le, .gt, .ge => {
                const is_eq_op = b.op == .eq or b.op == .ne;
                const is_ord_op = b.op == .lt or b.op == .le or b.op == .gt or b.op == .ge;
                const is_cmp = is_eq_op or is_ord_op;
                const is_shift = b.op == .lshift or b.op == .rshift;
                const is_exp = b.op == .exp;
                const is_int_only = b.op == .mod or b.op == .bit_and or b.op == .bit_or or b.op == .bit_xor;

                // 先综合两侧实际类型，避免对返回数值的自定义运算符重载错误传播期望类型
                const lhs_raw = try self.synthExpr(b.lhs, .none);
                const rhs_raw = try self.synthExpr(b.rhs, .none);

                if (lhs_raw == TypeInterner.err_ty or rhs_raw == TypeInterner.err_ty) {
                    return if (is_cmp) TypeInterner.bool_ty else TypeInterner.err_ty;
                }

                var lhs_ty = lhs_raw;
                var rhs_ty = rhs_raw;

                // 仅当两侧均属于上下文数值期望类型或可窄化 Ideal 字面量时，执行期望数值类型窄化与范围检查
                if (!is_cmp and !is_shift and !is_exp) {
                    if (expected) |exp| {
                        const u_exp = db.types.unboxOption(exp);
                        if (db.types.get(u_exp) == .prim) {
                            const pk = db.types.get(u_exp).prim;
                            const op_supported = if (is_int_only) pk.isInteger() else pk.isNumeric();
                            if (op_supported) {
                                const lhs_ok = lhs_ty == u_exp or isIdealCompatible(db, lhs_ty, u_exp);
                                const rhs_ok = rhs_ty == u_exp or isIdealCompatible(db, rhs_ty, u_exp);
                                if (lhs_ok and rhs_ok) {
                                    if (db.types.hasIdeal(lhs_ty)) lhs_ty = try self.checkExpr(b.lhs, u_exp);
                                    if (db.types.hasIdeal(rhs_ty)) rhs_ty = try self.checkExpr(b.rhs, u_exp);
                                    return u_exp;
                                }
                            }
                        }
                    }
                }

                // 仓颉求幂 `**` 仅内置支持 Int64 ** UInt64 -> Int64、Float64 ** Int64 -> Float64 与 Float64 ** Float64 -> Float64
                if (is_exp) {
                    const lhs_i64 = lhs_ty == TypeInterner.int64_ty or lhs_ty == TypeInterner.ideal_int_ty;
                    const rhs_u64 = rhs_ty == TypeInterner.uint64_ty or rhs_ty == TypeInterner.ideal_int_ty;
                    if (lhs_i64 and rhs_u64) {
                        if (lhs_ty == TypeInterner.ideal_int_ty) _ = try self.checkExpr(b.lhs, TypeInterner.int64_ty);
                        if (rhs_ty == TypeInterner.ideal_int_ty) _ = try self.checkExpr(b.rhs, TypeInterner.uint64_ty);
                        return TypeInterner.int64_ty;
                    }
                    const lhs_f64 = lhs_ty == TypeInterner.float64_ty or lhs_ty == TypeInterner.ideal_float_ty;
                    const rhs_i64 = rhs_ty == TypeInterner.int64_ty or rhs_ty == TypeInterner.ideal_int_ty;
                    const rhs_f64 = rhs_ty == TypeInterner.float64_ty or rhs_ty == TypeInterner.ideal_float_ty;
                    if (lhs_f64 and (rhs_i64 or rhs_f64)) {
                        if (lhs_ty == TypeInterner.ideal_float_ty) _ = try self.checkExpr(b.lhs, TypeInterner.float64_ty);
                        if (rhs_ty == TypeInterner.ideal_int_ty) _ = try self.checkExpr(b.rhs, TypeInterner.int64_ty);
                        if (rhs_ty == TypeInterner.ideal_float_ty) _ = try self.checkExpr(b.rhs, TypeInterner.float64_ty);
                        return TypeInterner.float64_ty;
                    }
                }

                // 仓颉二元字面量双向传播：先右侧后左侧，再左侧后右侧
                if (!is_shift and !is_exp) {
                    if (db.types.hasIdeal(lhs_ty) and !db.types.hasIdeal(rhs_ty)) {
                        if (isIdealCompatible(db, lhs_ty, rhs_ty)) {
                            lhs_ty = try self.checkExpr(b.lhs, rhs_ty);
                        }
                    } else if (!db.types.hasIdeal(lhs_ty) and db.types.hasIdeal(rhs_ty)) {
                        if (isIdealCompatible(db, rhs_ty, lhs_ty)) {
                            rhs_ty = try self.checkExpr(b.rhs, lhs_ty);
                        }
                    }
                }

                const ld = db.types.get(lhs_ty);
                const rd = db.types.get(rhs_ty);

                if (is_shift) {
                    const lhs_int = ld == .ideal_int or (ld == .prim and ld.prim.isInteger());
                    const rhs_int = rd == .ideal_int or (rd == .prim and rd.prim.isInteger());
                    if (lhs_int and rhs_int) {
                        return lhs_ty;
                    }
                } else if (!is_exp) {
                    const same_numeric_ty: ?TypeId = blk: {
                        const lhs_int = ld == .ideal_int or (ld == .prim and ld.prim.isInteger());
                        const rhs_int = rd == .ideal_int or (rd == .prim and rd.prim.isInteger());
                        if (lhs_int and rhs_int) {
                            if (lhs_ty == rhs_ty) break :blk lhs_ty;
                            if (ld == .ideal_int and rd == .prim) break :blk rhs_ty;
                            if (rd == .ideal_int and ld == .prim) break :blk lhs_ty;
                            break :blk null;
                        }
                        if (!is_int_only) {
                            const lhs_flt = ld == .ideal_float or (ld == .prim and ld.prim.isFloat());
                            const rhs_flt = rd == .ideal_float or (rd == .prim and rd.prim.isFloat());
                            if (lhs_flt and rhs_flt) {
                                if (lhs_ty == rhs_ty) break :blk lhs_ty;
                                if (ld == .ideal_float and rd == .prim) break :blk rhs_ty;
                                if (rd == .ideal_float and ld == .prim) break :blk lhs_ty;
                                break :blk null;
                            }
                        }
                        break :blk null;
                    };

                    if (same_numeric_ty) |num_ty| {
                        return if (is_cmp) TypeInterner.bool_ty else num_ty;
                    }

                    if (ld == .prim and rd == .prim and lhs_ty == rhs_ty) {
                        if (is_eq_op and (ld.prim == .bool_ or ld.prim == .rune or ld.prim == .unit)) {
                            return TypeInterner.bool_ty;
                        }
                        if (is_ord_op and ld.prim == .rune) {
                            return TypeInterner.bool_ty;
                        }
                    }
                }

                // 通过成员或扩展 `operator func` 重载决议（支持泛型替换、访问控制与最具体消歧）
                const op_name = binaryOpName(b.op);
                const ov_res = try self.resolveBinaryOperatorOverload(lhs_ty, b.rhs, rhs_ty, op_name, b.range);
                switch (ov_res) {
                    .resolved => |res_ty| return res_ty,
                    .diagnosed_err => return TypeInterner.err_ty,
                    .not_found => {},
                }

                // 字符串内置 `+`、`==`、`!=`、`<`、`<=`、`>`、`>=` 快捷支持（最小内置核心包无完整 operator func 时）
                if (db.types.known.string_struct) |sdef| {
                    if (ld == .nominal and rd == .nominal and DefId.eql(ld.nominal.def, sdef) and DefId.eql(rd.nominal.def, sdef)) {
                        if (b.op == .add) return lhs_ty;
                        if (is_cmp) return TypeInterner.bool_ty;
                    }
                }

                // Option / Range / Tuple 等内建等值比较
                if (is_eq_op and try self.supportsBuiltinEquality(lhs_ty, rhs_ty)) {
                    return TypeInterner.bool_ty;
                }

                try self.emitDiag(b.range, .err, "未找到匹配的二元运算符实现");
                return TypeInterner.err_ty;
            },
            .coalescing => unreachable,
        }
    }

    /// 判定未加后缀数值字面量中间类型是否可窄化至目标基础类型。
    fn isIdealCompatible(db: *const Database, ideal_ty: TypeId, target_ty: TypeId) bool {
        const td = db.types.get(target_ty);
        if (td != .prim) return false;
        if (ideal_ty == TypeInterner.ideal_int_ty) return td.prim.isInteger();
        if (ideal_ty == TypeInterner.ideal_float_ty) return td.prim.isFloat();
        return false;
    }

    /// 检查复合赋值运算符右侧与目标类型的兼容性及运算符是否适用。
    fn checkCompoundAssignOp(
        self: *ItemChecker,
        op: common.AssignOp,
        lhs_ty: TypeId,
        rhs: *const common.HirExpr,
        range: common.TextRange,
    ) PlatformError!void {
        const db = self.db;
        if (lhs_ty == TypeInterner.err_ty) {
            _ = try self.synthExpr(rhs, .none);
            return;
        }
        const ld = db.types.get(lhs_ty);
        switch (op) {
            .logical_and_assign, .logical_or_assign => {
                if (ld != .prim or ld.prim != .bool_) {
                    try self.emitDiag(range, .err, "逻辑复合赋值运算符仅适用于 Bool 类型");
                }
                _ = try self.checkExpr(rhs, TypeInterner.bool_ty);
            },
            .lshift_assign, .rshift_assign => {
                const rhs_ty = try self.synthExpr(rhs, .none);
                const lhs_int = ld == .prim and ld.prim.isInteger();
                const rd = db.types.get(rhs_ty);
                const rhs_int = rhs_ty == TypeInterner.err_ty or rd == .ideal_int or (rd == .prim and rd.prim.isInteger());
                if (!lhs_int or !rhs_int) {
                    const op_name = if (op == .lshift_assign) "<<" else ">>";
                    switch (try self.resolveBinaryOperatorOverload(lhs_ty, rhs, rhs_ty, op_name, range)) {
                        .resolved => |res_ty| try self.checkAssignable(range, res_ty, lhs_ty),
                        .diagnosed_err => {},
                        .not_found => try self.emitDiag(range, .err, "移位复合赋值运算符仅适用于整数类型"),
                    }
                }
            },
            .mod_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign => {
                const rhs_ty = if (ld == .prim and ld.prim.isInteger())
                    try self.checkExpr(rhs, lhs_ty)
                else
                    try self.synthExpr(rhs, .none);
                if (ld == .prim and ld.prim.isInteger()) return;
                if (rhs_ty == TypeInterner.err_ty) return;
                const op_name = switch (op) {
                    .mod_assign => "%",
                    .bit_and_assign => "&",
                    .bit_or_assign => "|",
                    .bit_xor_assign => "^",
                    else => "",
                };
                switch (try self.resolveBinaryOperatorOverload(lhs_ty, rhs, rhs_ty, op_name, range)) {
                    .resolved => |res_ty| try self.checkAssignable(range, res_ty, lhs_ty),
                    .diagnosed_err => {},
                    .not_found => try self.emitDiag(range, .err, "该类型不支持对应的复合赋值运算符"),
                }
            },
            .exp_assign => {
                if (lhs_ty == TypeInterner.int64_ty) {
                    _ = try self.checkExpr(rhs, TypeInterner.uint64_ty);
                    return;
                }
                const rhs_ty = try self.synthExpr(rhs, .none);
                if (rhs_ty == TypeInterner.err_ty) return;
                if (lhs_ty == TypeInterner.float64_ty) {
                    if (rhs_ty == TypeInterner.int64_ty or rhs_ty == TypeInterner.ideal_int_ty) {
                        if (rhs_ty == TypeInterner.ideal_int_ty) _ = try self.checkExpr(rhs, TypeInterner.int64_ty);
                        return;
                    }
                    if (rhs_ty == TypeInterner.float64_ty or rhs_ty == TypeInterner.ideal_float_ty) {
                        if (rhs_ty == TypeInterner.ideal_float_ty) _ = try self.checkExpr(rhs, TypeInterner.float64_ty);
                        return;
                    }
                }
                switch (try self.resolveBinaryOperatorOverload(lhs_ty, rhs, rhs_ty, "**", range)) {
                    .resolved => |res_ty| try self.checkAssignable(range, res_ty, lhs_ty),
                    .diagnosed_err => {},
                    .not_found => try self.emitDiag(range, .err, "该类型不支持对应的复合赋值运算符"),
                }
            },
            .add_assign, .sub_assign, .mul_assign, .div_assign => {
                const is_string_add = op == .add_assign and db.types.known.string_struct != null and
                    ld == .nominal and DefId.eql(ld.nominal.def, db.types.known.string_struct.?);
                if ((ld == .prim and ld.prim.isNumeric()) or is_string_add) {
                    _ = try self.checkExpr(rhs, lhs_ty);
                    return;
                }
                const rhs_ty = try self.synthExpr(rhs, .none);
                if (rhs_ty == TypeInterner.err_ty) return;
                const op_name = switch (op) {
                    .add_assign => "+",
                    .sub_assign => "-",
                    .mul_assign => "*",
                    .div_assign => "/",
                    else => "",
                };
                switch (try self.resolveBinaryOperatorOverload(lhs_ty, rhs, rhs_ty, op_name, range)) {
                    .resolved => |res_ty| try self.checkAssignable(range, res_ty, lhs_ty),
                    .diagnosed_err => {},
                    .not_found => try self.emitDiag(range, .err, "该类型不支持对应的复合赋值运算符"),
                }
            },
            .assign => unreachable,
        }
    }

    /// 二元运算符重载决议结果。
    const BinaryOverloadRes = union(enum) {
        resolved: TypeId,
        diagnosed_err,
        not_found,
    };

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
            .resolved => |r| blk: {
                try self.recordLateRef(null, range, r.target, .call);
                break :blk r.ret_ty;
            },
            .ambiguous => blk: {
                try self.emitDiag(range, .err, "一元运算符重载命中多个候选，存在二义性");
                break :blk TypeInterner.err_ty;
            },
            .no_match => |nm| blk: {
                if (nm.inaccessible_candidates.len > 0) {
                    try self.emitDiag(range, .err, "对应的一元运算符重载在当前作用域不可访问");
                } else {
                    try self.emitDiag(range, .err, "未找到匹配的一元运算符重载实现");
                }
                break :blk TypeInterner.err_ty;
            },
        };
    }

    /// 在左操作数类型成员与当前文件可见 `extend` 中查找二元运算符重载 `operator func op(rhs)`。
    fn resolveBinaryOperatorOverload(
        self: *ItemChecker,
        lhs_ty: TypeId,
        rhs_expr: *const common.HirExpr,
        rhs_ty: TypeId,
        op_text: []const u8,
        range: common.TextRange,
    ) PlatformError!BinaryOverloadRes {
        const op_id = try self.db.strings.intern(op_text);
        const cands = try self.collectMemberCandidates(lhs_ty, op_id, true);
        if (cands.len == 0) return .not_found;
        const synth_args = [_]common.HirCallArg{.{
            .name = null,
            .is_inout = false,
            .value = rhs_expr,
            .range = rhs_expr.range(),
        }};
        const pre_tys = [_]TypeId{rhs_ty};
        const outcome = try overload_mod.resolveCallOverload(self, .{
            .file = self.global_item.file,
            .access_ctx = self.currentAccessContext(),
            .call_range = range,
            .candidates = cands,
            .args = &synth_args,
            .receiver_ty = lhs_ty,
            .precomputed_arg_tys = &pre_tys,
        });
        return switch (outcome) {
            .resolved => |r| blk: {
                try self.recordLateRef(null, range, r.target, .call);
                break :blk .{ .resolved = r.ret_ty };
            },
            .ambiguous => blk: {
                try self.emitDiag(range, .err, "二元运算符重载命中多个候选，存在二义性");
                break :blk .diagnosed_err;
            },
            .no_match => |nm| blk: {
                if (nm.inaccessible_candidates.len > 0) {
                    try self.emitDiag(range, .err, "目标二元运算符重载在当前作用域不可访问");
                    break :blk .diagnosed_err;
                }
                break :blk .not_found;
            },
        };
    }

    /// 检查下标索引表达式 `base[idx...]`（内置支持元组、`Array<T>`、`VArray<T, $N>`、`String`、`CPointer<T>` 与 `operator func []`）。
    fn checkIndexExpr(self: *ItemChecker, idx: *const common.IndexExpr, pos: SynPos) PlatformError!TypeId {
        const db = self.db;
        const is_opt_chain = isOptionalChainBase(idx.base);
        const raw_base = if (is_opt_chain)
            try self.synthOptionalChainOperand(idx.base)
        else
            try self.synthExpr(idx.base, .none);
        const base_ty = try db.types.replaceIdeal(raw_base);
        if (base_ty == TypeInterner.err_ty) {
            for (idx.indices) |*i_expr| _ = try self.synthExpr(i_expr, .none);
            return TypeInterner.err_ty;
        }

        const elem_res: TypeId = switch (db.types.get(base_ty)) {
            .tuple => |list_id| blk: {
                const elems = db.types.getList(list_id);
                if (idx.indices.len != 1) {
                    try self.emitDiag(idx.range, .err, "元组下标索引必须恰好提供 1 个整数字面量");
                    for (idx.indices) |*i_expr| _ = try self.synthExpr(i_expr, .none);
                    break :blk TypeInterner.err_ty;
                }
                const idx0 = &idx.indices[0];
                _ = try self.checkExpr(idx0, TypeInterner.int64_ty);
                if (idx0.* != .int_lit) {
                    try self.emitDiag(idx0.range(), .err, "元组下标索引必须为非负整数字面量");
                    break :blk TypeInterner.err_ty;
                }
                const mag = literal_mod.parseIntegerMagnitude(idx0.int_lit.text) orelse {
                    try self.emitDiag(idx0.range(), .err, "元组下标索引必须为合法非负整数字面量");
                    break :blk TypeInterner.err_ty;
                };
                if (mag >= elems.len) {
                    try self.emitDiag(idx0.range(), .err, "元组下标索引越界");
                    break :blk TypeInterner.err_ty;
                }
                break :blk elems[@intCast(mag)];
            },
            .varray => |va| blk: {
                if (idx.indices.len != 1) {
                    try self.emitDiag(idx.range, .err, "VArray 下标索引必须恰好提供 1 个 Int64 参数");
                    for (idx.indices) |*i_expr| _ = try self.synthExpr(i_expr, .none);
                    break :blk TypeInterner.err_ty;
                }
                _ = try self.checkExpr(&idx.indices[0], TypeInterner.int64_ty);
                break :blk va.elem;
            },
            .cpointer => |elem| blk: {
                if (idx.indices.len != 1) {
                    try self.emitDiag(idx.range, .err, "CPointer 下标索引必须恰好提供 1 个 Int64 参数");
                    for (idx.indices) |*i_expr| _ = try self.synthExpr(i_expr, .none);
                    break :blk TypeInterner.err_ty;
                }
                _ = try self.checkExpr(&idx.indices[0], TypeInterner.int64_ty);
                break :blk elem;
            },
            .nominal => |nom| blk: {
                if (db.types.known.array_struct != null and DefId.eql(nom.def, db.types.known.array_struct.?)) {
                    const args = db.types.getList(nom.args);
                    if (idx.indices.len != 1) {
                        try self.emitDiag(idx.range, .err, "Array 下标索引必须恰好提供 1 个索引或区间参数");
                        for (idx.indices) |*i_expr| _ = try self.synthExpr(i_expr, .none);
                        break :blk TypeInterner.err_ty;
                    }
                    if (idx.indices[0] == .range_expr) {
                        const range_i64 = if (db.types.known.range_struct) |rdef|
                            try db.types.intern(.{ .nominal = .{ .def = rdef, .args = try db.types.internList(&.{TypeInterner.int64_ty}) } })
                        else
                            TypeInterner.err_ty;
                        _ = try self.checkExpr(&idx.indices[0], range_i64);
                        break :blk base_ty;
                    }
                    _ = try self.checkExpr(&idx.indices[0], TypeInterner.int64_ty);
                    break :blk if (args.len == 1) args[0] else TypeInterner.err_ty;
                }
                if (db.types.known.string_struct != null and DefId.eql(nom.def, db.types.known.string_struct.?)) {
                    if (idx.indices.len != 1) {
                        try self.emitDiag(idx.range, .err, "String 下标索引必须恰好提供 1 个索引或区间参数");
                        for (idx.indices) |*i_expr| _ = try self.synthExpr(i_expr, .none);
                        break :blk TypeInterner.err_ty;
                    }
                    if (idx.indices[0] == .range_expr) {
                        const range_i64 = if (db.types.known.range_struct) |rdef|
                            try db.types.intern(.{ .nominal = .{ .def = rdef, .args = try db.types.internList(&.{TypeInterner.int64_ty}) } })
                        else
                            TypeInterner.err_ty;
                        _ = try self.checkExpr(&idx.indices[0], range_i64);
                        break :blk base_ty;
                    }
                    _ = try self.checkExpr(&idx.indices[0], TypeInterner.int64_ty);
                    break :blk TypeInterner.uint8_ty;
                }
                const op_id = try db.strings.intern("[]");
                const cands = try self.collectMemberCandidates(base_ty, op_id, true);
                if (cands.len == 0) {
                    for (idx.indices) |*i_expr| _ = try self.synthExpr(i_expr, .none);
                    try self.emitDiag(idx.range, .err, "该类型未定义下标索引运算符 []");
                    break :blk TypeInterner.err_ty;
                }
                const scratch = self.scratch.allocator();
                const call_args = try scratch.alloc(common.HirCallArg, idx.indices.len);
                for (idx.indices, 0..) |*i_expr, i| {
                    call_args[i] = .{ .name = null, .is_inout = false, .value = i_expr, .range = i_expr.range() };
                }
                const outcome = try overload_mod.resolveCallOverload(self, .{
                    .file = self.global_item.file,
                    .access_ctx = self.currentAccessContext(),
                    .call_range = idx.range,
                    .candidates = cands,
                    .args = call_args,
                    .receiver_ty = base_ty,
                });
                break :blk switch (outcome) {
                    .resolved => |r| r_blk: {
                        try self.recordLateRef(idx.id, idx.range, r.target, .call);
                        break :r_blk r.ret_ty;
                    },
                    .ambiguous => a_blk: {
                        try self.emitDiag(idx.range, .err, "下标运算符 [] 命中多个重载候选，存在二义性");
                        break :a_blk TypeInterner.err_ty;
                    },
                    .no_match => |nm| n_blk: {
                        try self.emitCallNoMatchDiag(idx.range, nm, "未找到匹配的下标运算符 [] 实现");
                        break :n_blk TypeInterner.err_ty;
                    },
                };
            },
            else => blk: {
                for (idx.indices) |*i_expr| _ = try self.synthExpr(i_expr, .none);
                try self.emitDiag(idx.range, .err, "该类型不支持下标索引运算");
                break :blk TypeInterner.err_ty;
            },
        };

        if (elem_res == TypeInterner.err_ty) return TypeInterner.err_ty;
        const wrap_opt = is_opt_chain and !self.in_optional_chain and pos != .left_value;
        return if (wrap_opt) try db.types.internOption(elem_res) else elem_res;
    }

    /// 判定接收者表达式是否源自可选链（`a?`、`a?.b`、`a?(x)`、`a?[0]`）。
    fn isOptionalChainBase(expr: *const common.HirExpr) bool {
        return switch (expr.*) {
            .optional => true,
            .field => |f| isOptionalChainBase(f.base),
            .call => |c| isOptionalChainBase(c.callee),
            .index => |i| isOptionalChainBase(i.base),
            else => false,
        };
    }

    /// 根据重载决议 `.no_match` 的详细原因发射诊断（若仅因实参本身含 `err_ty` 导致则不产生重复级联诊断）。
    fn emitCallNoMatchDiag(
        self: *ItemChecker,
        range: common.TextRange,
        nm: anytype,
        fallback_msg: []const u8,
    ) PlatformError!void {
        if (nm.inaccessible_candidates.len > 0) {
            try self.emitDiag(range, .err, "目标可调用声明在当前作用域不可访问");
            return;
        }
        if (nm.has_err_arg) return;
        if (nm.matched_ignoring_expected_ret) {
            try self.emitDiag(range, .err, "函数调用返回类型与期望类型不兼容");
        } else if (nm.where_constraint_failed) {
            try self.emitDiag(range, .err, "泛型类型实参不满足 where 约束上界");
        } else if (nm.wrong_type_arg_count) {
            try self.emitDiag(range, .err, "泛型类型实参个数与目标声明不匹配");
        } else {
            try self.emitDiag(range, .err, fallback_msg);
        }
    }

    /// 解析路径表达式 `a`、`a.b.c`、`this.x`、`T.static_m` 与无限定枚举构造器糖。
    fn resolvePathExpr(
        self: *ItemChecker,
        p: *const common.PathExpr,
        expected: ?TypeId,
        allow_type_or_pkg: bool,
    ) PlatformError!TypeId {
        const db = self.db;
        if (p.segments.len == 0) return TypeInterner.err_ty;
        const key: common.HirKey = .{ .item = self.global_item.item, .hir = p.id };

        const seg0 = p.segments[0];
        if (!seg0.name.is_raw) {
            if (std.mem.eql(u8, seg0.name.text, "this")) {
                const this_ty = try self.enclosingSelfType();
                if (this_ty == TypeInterner.err_ty) {
                    try self.emitDiag(seg0.name.range, .err, "this 只能在类型或 extend 声明内部使用");
                    return TypeInterner.err_ty;
                }
                return self.resolveRemainingSegments(p.id, this_ty, p.segments[1..], expected);
            }
            if (std.mem.eql(u8, seg0.name.text, "super")) {
                const super_ty = try self.enclosingSuperType();
                if (super_ty == TypeInterner.err_ty) {
                    try self.emitDiag(seg0.name.range, .err, "super 只能在存在父类的 class 声明内部使用");
                    return TypeInterner.err_ty;
                }
                return self.resolveRemainingSegments(p.id, super_ty, p.segments[1..], expected);
            }
        }

        if (self.resolve_data.early_bindings.get(key)) |sym| {
            if (sym == .def) {
                if (!try access_mod.checkAccess(db, sym.def, null, self.currentAccessContext())) {
                    try self.emitDiag(seg0.name.range, .err, "目标标识符在当前作用域不可访问");
                    return TypeInterner.err_ty;
                }
            }
            if (p.segments.len == 1) {
                if (!allow_type_or_pkg and try self.isTypeOrPkgSymbol(sym)) {
                    try self.emitDiag(seg0.name.range, .err, "类型名或包名不能直接作为表达式值使用");
                    return TypeInterner.err_ty;
                }
                const cur_ty = try self.typeOfSymbolRef(sym, seg0.type_args, expected);
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
            var cur_ty = try self.typeOfSymbolRef(sym, seg0.type_args, expected);
            var seg_start: usize = 1;
            if (sym == .pkg and p.segments.len >= 2) {
                const seg1 = p.segments[1];
                const seg1_id = try db.strings.intern(seg1.name.text);
                const ps = db.packageState(sym.pkg) catch {
                    try self.emitDiag(seg1.name.range, .err, "无法解析目标包中的符号");
                    return TypeInterner.err_ty;
                };
                const exps = ps.lookupTop(seg1_id);
                if (exps.len == 0) {
                    try self.emitDiag(seg1.name.range, .err, "目标包中未找到指定符号");
                    return TypeInterner.err_ty;
                }
                const rel = db.pkg_interner.relation(self.pkg_state.pkg_id, sym.pkg);
                var visible_cands: std.ArrayListUnmanaged(EarlyCandidate) = .empty;
                const scratch = self.scratch.allocator();
                for (exps) |exp| {
                    if (!access_mod.isVisibleInRelation(exp.vis, rel)) continue;
                    try visible_cands.append(scratch, .{ .ref = .{ .def = exp.def }, .scope_level = 0, .is_reexport = exp.is_reexport });
                }
                if (visible_cands.items.len == 0) {
                    try self.emitDiag(seg1.name.range, .err, "目标包中的该符号在当前作用域不可访问");
                    return TypeInterner.err_ty;
                }
                const target_sym: SymbolRef = if (visible_cands.items.len == 1)
                    visible_cands.items[0].ref
                else switch (try self.pickFunctionValueCandidate(visible_cands.items, expected)) {
                    .resolved => |r| r,
                    .ambiguous => {
                        try self.emitDiag(seg1.name.range, .err, "重载函数作为值使用时存在二义性");
                        return TypeInterner.err_ty;
                    },
                    .no_match => {
                        try self.emitDiag(seg1.name.range, .err, "没有与期望函数类型匹配的重载函数");
                        return TypeInterner.err_ty;
                    },
                };
                if (p.segments.len == 2 and !allow_type_or_pkg and try self.isTypeOrPkgSymbol(target_sym)) {
                    try self.emitDiag(seg1.name.range, .err, "类型名或包名不能直接作为表达式值使用");
                    return TypeInterner.err_ty;
                }
                try self.recordLateRef(p.id, seg1.name.range, target_sym, .read);
                cur_ty = try self.typeOfSymbolRef(target_sym, seg1.type_args, expected);
                seg_start = 2;
            }
            return self.resolveRemainingSegments(p.id, cur_ty, p.segments[seg_start..], expected);
        }

        // 若为重载函数组（作为高阶函数值使用）
        if (self.resolve_data.early_overloads.get(key)) |ov| {
            if (ov.candidates.len > 0) {
                switch (try self.pickFunctionValueCandidate(ov.candidates, expected)) {
                    .resolved => |c_ref| {
                        try self.recordLateRef(p.id, seg0.name.range, c_ref, .read);
                        const fn_ty = try self.typeOfSymbolRef(c_ref, seg0.type_args, expected);
                        return self.resolveRemainingSegments(p.id, fn_ty, p.segments[1..], expected);
                    },
                    .ambiguous => {
                        try self.emitDiag(seg0.name.range, .err, "重载函数作为值使用时存在二义性");
                        return TypeInterner.err_ty;
                    },
                    .no_match => {
                        try self.emitDiag(seg0.name.range, .err, "没有与期望函数类型匹配的重载函数");
                        return TypeInterner.err_ty;
                    },
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

        try self.emitDiag(seg0.name.range, .err, "未定义的标识符");
        return TypeInterner.err_ty;
    }

    /// 判定符号是否为不能直接充当普通表达式值的类型名或包名。
    fn isTypeOrPkgSymbol(self: *ItemChecker, sym: SymbolRef) PlatformError!bool {
        return switch (sym) {
            .pkg, .prim, .type_param => true,
            .def => |d| blk: {
                const entry = self.db.getDef(d) catch break :blk false;
                break :blk switch (entry.kind) {
                    .class_, .struct_, .enum_, .interface_, .type_alias, .extend_ => true,
                    else => false,
                };
            },
            .local => false,
        };
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
            cur_ty = try self.lookupMemberType(hir_id, cur_ty, seg.name, seg.type_args, expected, false);
        }
        return cur_ty;
    }

    /// 解析显式 `FieldExpr`（`base.name` 或可选链 `base?.name`）。
    fn resolveFieldExpr(self: *ItemChecker, f: *const common.FieldExpr, expected: ?TypeId, pos: SynPos) PlatformError!TypeId {
        const is_opt_chain = isOptionalChainBase(f.base);
        const raw_base = if (is_opt_chain)
            try self.synthOptionalChainOperand(f.base)
        else
            try self.synthExpr(f.base, .none);
        const base_ty = try self.db.types.replaceIdeal(raw_base);
        const wrap_opt = is_opt_chain and !self.in_optional_chain and pos != .left_value;
        return self.lookupMemberType(f.id, base_ty, f.name, f.type_args, expected, wrap_opt);
    }

    /// 按接收者类型与成员名称查找字段、属性、方法或枚举构造器并记录晚绑定。
    fn lookupMemberType(
        self: *ItemChecker,
        hir_id: common.HirId,
        recv_ty: TypeId,
        member_name: common.Name,
        type_args: []const common.HirType,
        expected: ?TypeId,
        wrap_option_result: bool,
    ) PlatformError!TypeId {
        const db = self.db;
        if (recv_ty == TypeInterner.err_ty) return TypeInterner.err_ty;

        // 内建类型成员：`VArray<T, $N>.size` 与 `CPointer<T>` 常用内建方法值
        switch (db.types.get(recv_ty)) {
            .varray => {
                if (std.mem.eql(u8, member_name.text, "size")) {
                    const ty = TypeInterner.int64_ty;
                    return if (wrap_option_result) try db.types.internOption(ty) else ty;
                }
            },
            .cpointer => |elem_ty| {
                const builtin_fn: ?TypeId = if (std.mem.eql(u8, member_name.text, "isNull") or std.mem.eql(u8, member_name.text, "isNotNull"))
                    try db.types.intern(.{ .func = .{ .params = TypeListId.empty, .ret = TypeInterner.bool_ty, .is_cfunc = false } })
                else if (std.mem.eql(u8, member_name.text, "read"))
                    try db.types.intern(.{ .func = .{ .params = TypeListId.empty, .ret = elem_ty, .is_cfunc = false } })
                else if (std.mem.eql(u8, member_name.text, "write"))
                    try db.types.intern(.{ .func = .{ .params = try db.types.internList(&.{elem_ty}), .ret = TypeInterner.unit_ty, .is_cfunc = false } })
                else
                    null;
                if (builtin_fn) |bf| {
                    return if (wrap_option_result) try db.types.internOption(bf) else bf;
                }
            },
            else => {},
        }

        const name_id = try db.strings.intern(member_name.text);
        const cands = try self.collectMemberCandidates(recv_ty, name_id, false);
        if (cands.len == 0) {
            try self.emitDiag(member_name.range, .err, "该类型不存在指定成员");
            return TypeInterner.err_ty;
        }

        const access_ctx = self.currentAccessContext();
        var visible_cands: std.ArrayListUnmanaged(EarlyCandidate) = .empty;
        const scratch = self.scratch.allocator();
        for (cands) |cand| {
            if (cand.ref != .def) continue;
            if (!try access_mod.checkAccess(db, cand.ref.def, recv_ty, access_ctx)) continue;
            try visible_cands.append(scratch, cand);
        }
        if (visible_cands.items.len == 0) {
            try self.emitDiag(member_name.range, .err, "目标成员在当前作用域不可访问");
            return TypeInterner.err_ty;
        }

        const chosen_ref: SymbolRef = if (visible_cands.items.len == 1)
            visible_cands.items[0].ref
        else blk: {
            // 若存在非方法成员（字段/属性/枚举变体）优先选择
            for (visible_cands.items) |vc| {
                const ve = db.getDef(vc.ref.def) catch continue;
                if (ve.kind != .method and ve.kind != .func_) break :blk vc.ref;
            }
            // 按接收者替换后的形参签名去重，使子类 override/redef 覆写方法遮蔽父类同签名方法而不触发二义性
            var dedup_cands: std.ArrayListUnmanaged(EarlyCandidate) = .empty;
            var seen_param_lists: std.ArrayListUnmanaged(TypeListId) = .empty;
            for (visible_cands.items) |vc| {
                const sig = db.callableHeaderSig(.{ .def = vc.ref.def }) catch {
                    try dedup_cands.append(scratch, vc);
                    continue;
                };
                const inst_ps = try scratch.alloc(TypeId, sig.params.len);
                for (sig.params, 0..) |p, pi| {
                    var p_ty = p.ty;
                    if (db.types.get(recv_ty) == .nominal) {
                        const nom = db.types.get(recv_ty).nominal;
                        if (db.nominalHeaderOf(nom.def)) |nh| {
                            p_ty = try subtype_mod.substituteNominalParams(db, p_ty, nh.type_params, db.types.getList(nom.args));
                        } else |_| {}
                    }
                    inst_ps[pi] = p_ty;
                }
                const p_list = try db.types.internList(inst_ps);
                var dup_sig = false;
                for (seen_param_lists.items) |existing_pl| {
                    if (existing_pl == p_list) {
                        dup_sig = true;
                        break;
                    }
                }
                if (!dup_sig) {
                    try seen_param_lists.append(scratch, p_list);
                    try dedup_cands.append(scratch, vc);
                }
            }
            if (dedup_cands.items.len == 1) break :blk dedup_cands.items[0].ref;
            const expected_inner = if (wrap_option_result and expected != null) db.types.unwrapOptionOnce(expected.?) else expected;
            break :blk switch (try self.pickFunctionValueCandidate(dedup_cands.items, expected_inner)) {
                .resolved => |r| r,
                .ambiguous => {
                    try self.emitDiag(member_name.range, .err, "成员重载方法作为值使用时存在二义性");
                    return TypeInterner.err_ty;
                },
                .no_match => {
                    try self.emitDiag(member_name.range, .err, "没有与期望函数类型匹配的成员方法");
                    return TypeInterner.err_ty;
                },
            };
        };

        const entry = db.getDef(chosen_ref.def) catch return TypeInterner.err_ty;
        try self.recordLateRef(hir_id, member_name.range, chosen_ref, .read);

        var raw_ty: TypeId = switch (entry.kind) {
            .field, .variable, .constant => try self.queryVarType(chosen_ref.def),
            .prop => try db.propTypeOf(chosen_ref.def),
            .enum_variant => try self.instantiateEnumCtorValueType(chosen_ref.def, expected),
            .method, .func_, .constructor, .primary_ctor => blk: {
                const sig = db.callableHeaderSig(.{ .def = chosen_ref.def }) catch break :blk TypeInterner.err_ty;
                break :blk try self.funcTypeFromCallableSig(sig, null);
            },
            else => TypeInterner.err_ty,
        };

        // 使用接收者名义类型的类型实参替换成员签名中的宿主泛型形参
        if (db.types.get(recv_ty) == .nominal) {
            const nom = db.types.get(recv_ty).nominal;
            if (db.nominalHeaderOf(nom.def)) |nh| {
                raw_ty = try subtype_mod.substituteNominalParams(db, raw_ty, nh.type_params, db.types.getList(nom.args));
            } else |_| {}
        }
        _ = type_args;
        if (raw_ty == TypeInterner.err_ty) return TypeInterner.err_ty;
        return if (wrap_option_result) try db.types.internOption(raw_ty) else raw_ty;
    }

    /// 检查 `CPointer<T>` 内建成员方法调用（`isNull`、`isNotNull`、`read`、`write`）。
    fn checkCPointerMethodCall(
        self: *ItemChecker,
        c: *const common.CallExpr,
        elem_ty: TypeId,
        method_name: []const u8,
        expected: ?TypeId,
        wrap_opt: bool,
    ) PlatformError!?TypeId {
        const db = self.db;
        const ret_inner: TypeId = if (std.mem.eql(u8, method_name, "isNull") or std.mem.eql(u8, method_name, "isNotNull")) blk: {
            if (c.args.len != 0 or c.trailing_lambda != null) {
                try self.emitDiag(c.range, .err, "CPointer 判空方法不接受任何实参");
                for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
                if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
            }
            break :blk TypeInterner.bool_ty;
        } else if (std.mem.eql(u8, method_name, "read")) blk: {
            if (c.trailing_lambda != null or c.args.len > 1) {
                try self.emitDiag(c.range, .err, "CPointer.read 仅接受 0 个或 1 个 Int64 偏移参数");
                for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
                if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
            } else if (c.args.len == 1) {
                _ = try self.checkExpr(c.args[0].value, TypeInterner.int64_ty);
            }
            break :blk elem_ty;
        } else if (std.mem.eql(u8, method_name, "write")) blk: {
            if (c.trailing_lambda == null and c.args.len == 1) {
                _ = try self.checkExpr(c.args[0].value, elem_ty);
            } else if (c.trailing_lambda == null and c.args.len == 2) {
                _ = try self.checkExpr(c.args[0].value, TypeInterner.int64_ty);
                _ = try self.checkExpr(c.args[1].value, elem_ty);
            } else {
                try self.emitDiag(c.range, .err, "CPointer.write 实参个数不合法");
                for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
                if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
            }
            break :blk TypeInterner.unit_ty;
        } else return null;

        const final_ret = if (wrap_opt and ret_inner != TypeInterner.err_ty)
            try db.types.internOption(ret_inner)
        else
            ret_inner;
        if (expected) |exp| {
            try self.checkAssignable(c.range, final_ret, exp);
        }
        return final_ret;
    }

    /// 检查类型别名调用（覆盖基础类型转换如 `Byte(65)`、`Int(3.14)` 与泛型/非泛型构造器别名如 `IntEmpty()`）。
    fn checkTypeAliasCall(
        self: *ItemChecker,
        c: *const common.CallExpr,
        alias_def: DefId,
        explicit_targs: []const TypeId,
        expected: ?TypeId,
    ) PlatformError!TypeId {
        const db = self.db;
        const tah = db.typeAliasHeaderOf(alias_def) catch return TypeInterner.err_ty;
        if (explicit_targs.len > 0 and explicit_targs.len != tah.type_params.len) {
            try self.emitDiag(c.range, .err, "类型别名泛型类型实参个数不匹配");
            for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
            if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
            return TypeInterner.err_ty;
        }

        const inst_target = if (tah.type_params.len > 0 and explicit_targs.len == tah.type_params.len)
            try subtype_mod.substituteNominalParams(db, tah.target, tah.type_params, explicit_targs)
        else
            tah.target;

        if (inst_target == TypeInterner.err_ty) {
            for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
            if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
            return TypeInterner.err_ty;
        }

        switch (db.types.get(inst_target)) {
            .prim => {
                if (c.args.len != 1 or c.trailing_lambda != null or c.args[0].name != null) {
                    try self.emitDiag(c.range, .err, "基础类型转换仅接受 1 个位置实参");
                    for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
                    if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
                    return TypeInterner.err_ty;
                }
                const raw_val = try self.synthExpr(c.args[0].value, .expr_arg);
                const val_ty = try db.types.replaceIdeal(raw_val);
                if (val_ty == TypeInterner.err_ty) return inst_target;
                if (!isValidPrimTypeConv(db.types.get(inst_target), db.types.get(val_ty))) {
                    try self.emitDiag(c.range, .err, "不支持将该类型转换为目标基础类型");
                    return TypeInterner.err_ty;
                }
                try self.recordLateRef(c.id, c.callee.range(), .{ .def = alias_def }, .call);
                if (expected) |exp| {
                    try self.checkAssignable(c.range, inst_target, exp);
                }
                return inst_target;
            },
            .nominal => |nom| {
                const de = db.getDef(nom.def) catch return TypeInterner.err_ty;
                if (de.kind == .class_ or de.kind == .struct_) {
                    const fwd_targs: []const TypeId = if (tah.type_params.len > 0 and explicit_targs.len == 0)
                        &.{}
                    else
                        db.types.getList(nom.args);
                    return self.checkConstructorCall(c, nom.def, fwd_targs, expected, false);
                }
                try self.emitDiag(c.callee.range(), .err, "目标类型别名不是可构造类型");
                for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
                if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
                return TypeInterner.err_ty;
            },
            else => {
                try self.emitDiag(c.callee.range(), .err, "目标类型别名不支持直接调用");
                for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
                if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
                return TypeInterner.err_ty;
            },
        }
    }

    /// 检查调用表达式 `callee(args)`（统一覆盖函数调用、方法调用、构造器与 `this`/`super` 委托调用、类型别名、枚举构造器与高阶函数值）。
    fn checkCallExpr(self: *ItemChecker, c: *const common.CallExpr, expected: ?TypeId, pos: SynPos) PlatformError!TypeId {
        const db = self.db;
        const scratch = self.scratch.allocator();
        const key_callee: common.HirKey = .{ .item = self.global_item.item, .hir = c.callee.id() };
        const is_opt_chain = isOptionalChainBase(c.callee);
        const wrap_opt = is_opt_chain and !self.in_optional_chain and pos != .left_value;
        const call_expected = if (wrap_opt and expected != null) db.types.unwrapOptionOnce(expected.?) else expected;

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
                    // 构造器内委托调用 `this(...)` / `super(...)`
                    if (!seg0.name.is_raw and (std.mem.eql(u8, seg0.name.text, "this") or std.mem.eql(u8, seg0.name.text, "super"))) {
                        const is_super = std.mem.eql(u8, seg0.name.text, "super");
                        if (!self.in_ctor or self.in_static_ctor) {
                            try self.emitDiag(c.range, .err, "this(...) 或 super(...) 构造器委托调用只能出现在实例构造器内部");
                            for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
                            if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
                            return TypeInterner.err_ty;
                        }
                        const target_ty = if (is_super) try self.enclosingSuperType() else try self.enclosingSelfType();
                        if (target_ty == TypeInterner.err_ty or db.types.get(target_ty) != .nominal) {
                            try self.emitDiag(c.range, .err, if (is_super)
                                "super(...) 只能在存在父类的 class 构造器内部使用"
                            else
                                "this(...) 只能在 class 或 struct 构造器内部使用");
                            for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
                            if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
                            return TypeInterner.err_ty;
                        }
                        const nom = db.types.get(target_ty).nominal;
                        _ = try self.checkConstructorCall(c, nom.def, db.types.getList(nom.args), null, true);
                        return TypeInterner.unit_ty;
                    }
                    // 内建 `CPointer<T>(...)` 与 `CFunc<Fn>(...)` 构造调用
                    if (!seg0.name.is_raw and self.resolve_data.early_bindings.get(key_callee) == null and self.resolve_data.early_overloads.get(key_callee) == null) {
                        if (std.mem.eql(u8, seg0.name.text, "CPointer")) {
                            if (explicit_targs.items.len != 1) {
                                try self.emitDiag(c.range, .err, "CPointer 构造调用必须恰好提供 1 个类型实参");
                                for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
                                return TypeInterner.err_ty;
                            }
                            if (c.args.len > 1 or c.trailing_lambda != null) {
                                try self.emitDiag(c.range, .err, "CPointer 构造器实参个数不合法");
                            }
                            for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
                            const cp_ty = try db.types.intern(.{ .cpointer = explicit_targs.items[0] });
                            if (expected) |exp| try self.checkAssignable(c.range, cp_ty, exp);
                            return cp_ty;
                        }
                        if (std.mem.eql(u8, seg0.name.text, "CFunc")) {
                            if (explicit_targs.items.len != 1 or db.types.get(explicit_targs.items[0]) != .func) {
                                try self.emitDiag(c.range, .err, "CFunc 构造调用必须提供 1 个函数类型实参");
                                for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
                                return TypeInterner.err_ty;
                            }
                            for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
                            const f_info = db.types.get(explicit_targs.items[0]).func;
                            const cf_ty = try db.types.intern(.{ .func = .{
                                .params = f_info.params,
                                .ret = f_info.ret,
                                .is_cfunc = true,
                            } });
                            if (expected) |exp| try self.checkAssignable(c.range, cf_ty, exp);
                            return cf_ty;
                        }
                    }
                    // 检查是否为无限定类型名或类型别名调用构造器/基础类型转换（如 `Foo(1)` / `Byte(65)` / `IntEmpty()`）
                    if (self.resolve_data.early_bindings.get(key_callee)) |sym| {
                        if (sym == .def) {
                            const de = db.getDef(sym.def) catch null;
                            if (de != null and (de.?.kind == .class_ or de.?.kind == .struct_)) {
                                return self.checkConstructorCall(c, sym.def, explicit_targs.items, expected, false);
                            }
                            if (de != null and de.?.kind == .type_alias) {
                                return self.checkTypeAliasCall(c, sym.def, explicit_targs.items, expected);
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
                                const rel = db.pkg_interner.relation(self.pkg_state.pkg_id, sym0.pkg);
                                for (ps.lookupTop(m_id)) |exp| {
                                    if (!access_mod.isVisibleInRelation(exp.vis, rel)) continue;
                                    const de = db.getDef(exp.def) catch continue;
                                    if (de.kind == .class_ or de.kind == .struct_) {
                                        return self.checkConstructorCall(c, exp.def, explicit_targs.items, expected, false);
                                    }
                                    if (de.kind == .type_alias) {
                                        return self.checkTypeAliasCall(c, exp.def, explicit_targs.items, expected);
                                    }
                                    if (de.kind == .func_ or de.kind == .method) {
                                        try candidates.append(scratch, .{ .ref = .{ .def = exp.def }, .scope_level = 0, .is_reexport = exp.is_reexport });
                                    }
                                }
                            } else |_| {}
                        } else {
                            const rty = try self.resolvePathExpr(&prefix_path, null, true);
                            if (rty == TypeInterner.err_ty) {
                                for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
                                if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
                                return TypeInterner.err_ty;
                            }
                            receiver_ty = try db.types.replaceIdeal(rty);
                            if (db.types.get(receiver_ty.?) == .cpointer) {
                                if (try self.checkCPointerMethodCall(c, db.types.get(receiver_ty.?).cpointer, last.name.text, expected, wrap_opt)) |cp_res| {
                                    return cp_res;
                                }
                            }
                            const m_id = try db.strings.intern(last.name.text);
                            const mcands = try self.collectMemberCandidates(receiver_ty.?, m_id, false);
                            for (mcands) |mc| {
                                if (mc.ref == .def) {
                                    const mde = db.getDef(mc.ref.def) catch continue;
                                    if (mde.kind == .method or mde.kind == .func_ or mde.kind == .enum_variant) {
                                        try candidates.append(scratch, mc);
                                    }
                                }
                            }
                        }
                    } else {
                        const rty = try self.resolvePathExpr(&prefix_path, null, true);
                        if (rty == TypeInterner.err_ty) {
                            for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
                            if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
                            return TypeInterner.err_ty;
                        }
                        receiver_ty = try db.types.replaceIdeal(rty);
                        if (db.types.get(receiver_ty.?) == .cpointer) {
                            if (try self.checkCPointerMethodCall(c, db.types.get(receiver_ty.?).cpointer, last.name.text, expected, wrap_opt)) |cp_res| {
                                return cp_res;
                            }
                        }
                        const m_id = try db.strings.intern(last.name.text);
                        const mcands = try self.collectMemberCandidates(receiver_ty.?, m_id, false);
                        for (mcands) |mc| {
                            if (mc.ref == .def) {
                                const mde = db.getDef(mc.ref.def) catch continue;
                                if (mde.kind == .method or mde.kind == .func_ or mde.kind == .enum_variant) {
                                    try candidates.append(scratch, mc);
                                }
                            }
                        }
                    }
                }
            },
            .field => |f| {
                callee_range = f.name.range;
                for (f.type_args) |*ta| {
                    const t = self.resolve_data.resolved_types.get(.{ .item = self.global_item.item, .hir = ta.id() }) orelse TypeInterner.err_ty;
                    try explicit_targs.append(scratch, t);
                }
                const raw_recv = if (isOptionalChainBase(f.base))
                    try self.synthOptionalChainOperand(f.base)
                else
                    try self.synthExpr(f.base, .none);
                const rty = try db.types.replaceIdeal(raw_recv);
                if (rty == TypeInterner.err_ty) {
                    for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
                    if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
                    return TypeInterner.err_ty;
                }
                receiver_ty = rty;
                if (db.types.get(rty) == .cpointer) {
                    if (try self.checkCPointerMethodCall(c, db.types.get(rty).cpointer, f.name.text, expected, wrap_opt)) |cp_res| {
                        return cp_res;
                    }
                }
                const m_id = try db.strings.intern(f.name.text);
                const mcands = try self.collectMemberCandidates(rty, m_id, false);
                for (mcands) |mc| {
                    if (mc.ref == .def) {
                        const mde = db.getDef(mc.ref.def) catch continue;
                        if (mde.kind == .method or mde.kind == .func_ or mde.kind == .enum_variant) {
                            try candidates.append(scratch, mc);
                        }
                    }
                }
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
                .expected_ret = call_expected,
                .receiver_ty = receiver_ty,
            });
            switch (outcome) {
                .resolved => |res| {
                    try self.recordLateRef(c.id, callee_range, res.target, .call);
                    if (res.type_args != TypeListId.empty) {
                        try self.instantiated_type_args.put(self.arena, c.id, res.type_args);
                    }
                    const final_ret = if (wrap_opt and res.ret_ty != TypeInterner.err_ty)
                        try db.types.internOption(res.ret_ty)
                    else
                        res.ret_ty;
                    if (expected) |exp| {
                        try self.checkAssignable(c.range, final_ret, exp);
                    }
                    return final_ret;
                },
                .ambiguous => {
                    try self.emitDiag(c.range, .err, "调用命中多个同等具体的重载候选，存在二义性");
                    return TypeInterner.err_ty;
                },
                .no_match => |nm| {
                    try self.emitCallNoMatchDiag(c.range, nm, "未找到匹配实参列表的函数重载");
                    return TypeInterner.err_ty;
                },
            }
        }

        // 回退至高阶函数值直接调用（`fn_val(a, b)`）或自定义 `operator func ()` 重载
        self.in_func_arg_lambda_depth += 1;
        defer self.in_func_arg_lambda_depth -= 1;

        const callee_ty = if (is_opt_chain)
            try self.synthOptionalChainOperand(c.callee)
        else
            try self.synthExpr(c.callee, .none);
        if (callee_ty == TypeInterner.err_ty) {
            for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
            if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
            return TypeInterner.err_ty;
        }

        if (db.types.get(callee_ty) == .func) {
            const f = db.types.get(callee_ty).func;
            const p_tys = db.types.getList(f.params);
            const total_args = c.args.len + @as(usize, if (c.trailing_lambda != null) 1 else 0);
            if (total_args != p_tys.len) {
                try self.emitDiag(c.range, .err, "函数调用实参个数与形参个数不匹配");
            }
            for (c.args, 0..) |arg, i| {
                if (arg.name != null) {
                    try self.emitDiag(arg.range, .err, "函数类型值调用不支持命名实参");
                }
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
            const final_ret = if (wrap_opt and f.ret != TypeInterner.err_ty)
                try db.types.internOption(f.ret)
            else
                f.ret;
            if (expected) |exp| {
                try self.checkAssignable(c.range, final_ret, exp);
            }
            return final_ret;
        }

        // 尝试查找自定义类型的 `operator func ()` 重载
        const call_op_id = try db.strings.intern("()");
        const call_op_cands = try self.collectMemberCandidates(callee_ty, call_op_id, true);
        if (call_op_cands.len > 0) {
            const outcome = try overload_mod.resolveCallOverload(self, .{
                .file = self.global_item.file,
                .access_ctx = self.currentAccessContext(),
                .call_range = c.range,
                .candidates = call_op_cands,
                .args = c.args,
                .trailing_lambda = c.trailing_lambda,
                .explicit_type_args = explicit_targs.items,
                .expected_ret = call_expected,
                .receiver_ty = callee_ty,
            });
            switch (outcome) {
                .resolved => |res| {
                    try self.recordLateRef(c.id, callee_range, res.target, .call);
                    const final_ret = if (wrap_opt and res.ret_ty != TypeInterner.err_ty)
                        try db.types.internOption(res.ret_ty)
                    else
                        res.ret_ty;
                    if (expected) |exp| {
                        try self.checkAssignable(c.range, final_ret, exp);
                    }
                    return final_ret;
                },
                .ambiguous => {
                    try self.emitDiag(c.range, .err, "调用运算符 () 命中多个重载候选，存在二义性");
                    return TypeInterner.err_ty;
                },
                .no_match => |nm| {
                    try self.emitCallNoMatchDiag(c.range, nm, "未找到匹配的调用运算符 () 重载实现");
                    return TypeInterner.err_ty;
                },
            }
        }

        try self.emitDiag(c.callee.range(), .err, "目标表达式不是可调用类型");
        for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
        if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
        return TypeInterner.err_ty;
    }

    /// 检查类型构造器调用 `TypeName<Args>(call_args)`（`allow_abstract` 仅在 `super(...)` 委托时置 `true`）。
    fn checkConstructorCall(
        self: *ItemChecker,
        c: *const common.CallExpr,
        type_def: DefId,
        explicit_targs: []const TypeId,
        expected: ?TypeId,
        allow_abstract: bool,
    ) PlatformError!TypeId {
        const db = self.db;
        const scratch = self.scratch.allocator();
        const entry = db.getDef(type_def) catch return TypeInterner.err_ty;
        const nh = db.nominalHeaderOf(type_def) catch return TypeInterner.err_ty;

        if (!allow_abstract and entry.kind == .class_ and entry.flags.is_abstract) {
            try self.emitDiag(c.range, .err, "不能直接实例化抽象类");
            for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
            if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
            return TypeInterner.err_ty;
        }

        if (explicit_targs.len > 0 and explicit_targs.len != nh.type_params.len) {
            try self.emitDiag(c.range, .err, "构造器泛型类型实参个数与类型声明不匹配");
            for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
            if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
            return TypeInterner.err_ty;
        }

        var ctors: std.ArrayListUnmanaged(EarlyCandidate) = .empty;
        for (entry.members) |m_def| {
            const me = db.getDef(m_def) catch continue;
            if ((me.kind == .constructor and !me.flags.is_static) or me.kind == .primary_ctor) {
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
            self.in_func_arg_lambda_depth += 1;
            defer self.in_func_arg_lambda_depth -= 1;

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
                    if (expected) |exp| {
                        try self.checkAssignable(c.range, res.ret_ty, exp);
                    }
                    return res.ret_ty;
                },
                .ambiguous => {
                    try self.emitDiag(c.range, .err, "构造器调用命中多个同等具体的重载候选，存在二义性");
                    return TypeInterner.err_ty;
                },
                .no_match => |nm| {
                    try self.emitCallNoMatchDiag(c.range, nm, "未找到匹配实参列表的构造器");
                    return TypeInterner.err_ty;
                },
            }
        }

        // 无显式构造器时使用默认无参构造器
        if (c.args.len > 0 or c.trailing_lambda != null) {
            try self.emitDiag(c.range, .err, "默认无参构造器不接受任何实参");
            for (c.args) |arg| _ = try self.synthExpr(arg.value, .expr_arg);
            if (c.trailing_lambda) |tl| _ = try self.synthExpr(tl, .expr_arg);
            return TypeInterner.err_ty;
        }
        if (nh.type_params.len > 0 and targs_id == TypeListId.empty) {
            try self.emitDiag(c.range, .err, "无法推导泛型构造器的类型实参，请显式指定类型参数");
            return TypeInterner.err_ty;
        }
        if (expected) |exp| {
            try self.checkAssignable(c.range, constructed_ty, exp);
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
            if (expected) |exp| {
                try self.checkAssignable(ie.range, TypeInterner.unit_ty, exp);
            }
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

        if (me.cases.len == 0) {
            if (expected) |exp| {
                try self.checkAssignable(me.range, TypeInterner.unit_ty, exp);
            }
            return TypeInterner.unit_ty;
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
                    if (elem_tys.len != tp.elements.len) {
                        try self.emitDiag(tp.range, .err, "元组模式元素个数与目标元组类型不匹配");
                    }
                    for (tp.elements, 0..) |*el, i| {
                        const et = if (i < elem_tys.len) elem_tys[i] else TypeInterner.err_ty;
                        try self.checkPattern(el, et);
                    }
                } else {
                    if (target_ty != TypeInterner.err_ty) {
                        try self.emitDiag(tp.range, .err, "元组模式只能匹配元组类型");
                    }
                    for (tp.elements) |*el| try self.checkPattern(el, TypeInterner.err_ty);
                }
            },
            .enum_ => |ep| {
                // 匹配枚举构造器（含 Option::Some(x) 与同名重载构造器）并展开荷载类型
                const ctor_seg = if (ep.path.segments.len > 0) &ep.path.segments[ep.path.segments.len - 1] else null;
                const ctor_name = if (ctor_seg) |cs| cs.name.text else "";
                var payload_tys: []const TypeId = &.{};
                var payload_buf: [16]TypeId = undefined;
                var found_ctor = false;
                var matched_arity = false;

                if (target_ty != TypeInterner.err_ty) {
                    if (db.types.get(target_ty) == .nominal) {
                        const nom = db.types.get(target_ty).nominal;
                        if (db.getDef(nom.def)) |enum_entry| {
                            if (enum_entry.kind != .enum_) {
                                try self.emitDiag(ep.range, .err, "枚举模式只能匹配枚举类型");
                            } else {
                                const ctor_id = try db.strings.intern(ctor_name);
                                for (enum_entry.members) |m_def| {
                                    const me = db.getDef(m_def) catch continue;
                                    if (me.kind != .enum_variant or me.name != ctor_id) continue;
                                    found_ctor = true;
                                    const sig_opt = db.callableHeaderSig(.{ .def = m_def }) catch null;
                                    const arity: usize = if (sig_opt) |s| s.params.len else 0;
                                    if (arity != ep.args.len) continue;

                                    matched_arity = true;
                                    if (ctor_seg) |cs| {
                                        try self.recordLateRef(ep.id, cs.name.range, .{ .def = m_def }, .read);
                                    }
                                    if (sig_opt) |sig| {
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
                                    }
                                    break;
                                }
                                if (!found_ctor) {
                                    try self.emitDiag(ep.range, .err, "目标枚举类型中不存在该构造器");
                                } else if (!matched_arity) {
                                    try self.emitDiag(ep.range, .err, "枚举模式参数个数与构造器定义不匹配");
                                }
                            }
                        } else |_| {}
                    } else {
                        try self.emitDiag(ep.range, .err, "枚举模式只能匹配枚举类型");
                    }
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
        const db = self.db;
        switch (pat.*) {
            .except_type => |cp| {
                var ty: TypeId = TypeInterner.err_ty;
                if (cp.types.len > 0) {
                    ty = self.resolve_data.resolved_types.get(.{ .item = self.global_item.item, .hir = cp.types[0].id() }) orelse TypeInterner.err_ty;
                    for (cp.types) |*ct| {
                        const c_ty = self.resolve_data.resolved_types.get(.{ .item = self.global_item.item, .hir = ct.id() }) orelse TypeInterner.err_ty;
                        if (c_ty == TypeInterner.err_ty) continue;
                        const is_exc = if (db.types.known.exception_class) |ed|
                            try subtype_mod.isSubtype(db, self.global_item.file, c_ty, try db.types.intern(.{ .nominal = .{ .def = ed, .args = TypeListId.empty } }), .{})
                        else
                            true;
                        const is_err = if (db.types.known.error_class) |ed|
                            try subtype_mod.isSubtype(db, self.global_item.file, c_ty, try db.types.intern(.{ .nominal = .{ .def = ed, .args = TypeListId.empty } }), .{})
                        else
                            false;
                        if (!is_exc and !is_err) {
                            try self.emitDiag(ct.range(), .err, "catch 子句捕获的类型必须为 Exception 或 Error 子类型");
                        }
                    }
                } else if (db.types.known.exception_class) |ed| {
                    ty = try db.types.intern(.{ .nominal = .{ .def = ed, .args = TypeListId.empty } });
                }
                try self.setLocalTypeByDeclHir(cp.id, ty);
                self.setNodeType(cp.id, ty);
            },
            .command_type => |cp| {
                var ty: TypeId = TypeInterner.err_ty;
                if (cp.types.len > 0) {
                    ty = self.resolve_data.resolved_types.get(.{ .item = self.global_item.item, .hir = cp.types[0].id() }) orelse TypeInterner.err_ty;
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
                } else {
                    try self.emitDiag(b.range, .err, "局部变量声明缺少类型标注或初始化表达式");
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
            else blk: {
                const prev_fn = self.current_inferring_local_fn;
                const prev_range = self.current_inferring_local_range;
                const prev_rep = self.reported_infer_cycle;
                self.current_inferring_local_fn = loc.id;
                self.current_inferring_local_range = f.range;
                self.reported_infer_cycle = false;
                defer {
                    self.current_inferring_local_fn = prev_fn;
                    self.current_inferring_local_range = prev_range;
                    self.reported_infer_cycle = prev_rep;
                }
                break :blk try self.synthCallableBody(body);
            };
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

    /// 获取当前封闭类的直接父类类型（仅当封闭类型为 `class` 且存在 `class` 直接父类时合法）。
    fn enclosingSuperType(self: *ItemChecker) PlatformError!TypeId {
        const db = self.db;
        const enc = self.enclosing_nominal orelse return TypeInterner.err_ty;
        const enc_entry = db.getDef(enc) catch return TypeInterner.err_ty;
        if (enc_entry.kind != .class_) return TypeInterner.err_ty;
        const nh = db.nominalHeaderOf(enc) catch return TypeInterner.err_ty;
        if (nh.supertypes.len == 0) return TypeInterner.err_ty;
        const super_ty = nh.supertypes[0];
        if (db.types.get(super_ty) != .nominal) return TypeInterner.err_ty;
        const super_entry = db.getDef(db.types.get(super_ty).nominal.def) catch return TypeInterner.err_ty;
        if (super_entry.kind != .class_) return TypeInterner.err_ty;
        return super_ty;
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
            // 优先直接匹配 `exp` 自身（避免 `Option<T>` 被 `unboxOption` 剥去外层导致 `None` 丢失泛型实参 `T`）
            if (db.types.get(exp) == .nominal and DefId.eql(db.types.get(exp).nominal.def, owner)) {
                return exp;
            }
            const u = db.types.unboxOption(exp);
            if (db.types.get(u) == .nominal and DefId.eql(db.types.get(u).nominal.def, owner)) {
                return u;
            }
        }
        return db.types.intern(.{ .nominal = .{ .def = owner, .args = TypeListId.empty } });
    }

    /// 重载函数值消歧结果。
    const FuncValuePickResult = union(enum) {
        resolved: SymbolRef,
        ambiguous,
        no_match,
    };

    /// 从重载候选组中根据上下文期望函数类型选取唯一匹配的函数值。
    fn pickFunctionValueCandidate(
        self: *ItemChecker,
        candidates: []const EarlyCandidate,
        expected: ?TypeId,
    ) PlatformError!FuncValuePickResult {
        if (candidates.len == 0) return .no_match;
        if (candidates.len == 1) return .{ .resolved = candidates[0].ref };
        if (expected) |exp| {
            const u = self.db.types.unboxOption(exp);
            if (self.db.types.get(u) == .func) {
                var matched: ?SymbolRef = null;
                for (candidates) |c| {
                    const fty = try self.typeOfSymbolRef(c.ref, &.{}, null);
                    if (try subtype_mod.isSubtype(self.db, self.global_item.file, fty, u, .{})) {
                        if (matched != null) return .ambiguous;
                        matched = c.ref;
                    }
                }
                if (matched) |m| return .{ .resolved = m };
                return .no_match;
            }
        }
        return .ambiguous;
    }

    /// 对声明签名执行低可见性类型暴露检查并在违规时发射诊断。
    fn checkDeclVisibilityExposure(self: *ItemChecker, decl_def: DefId, ty: TypeId, range: common.TextRange) PlatformError!void {
        if (try access_mod.checkVisibilityExposure(self.db, decl_def, ty)) |_| {
            try self.emitDiag(range, .err, "公开声明签名中暴露了低可见性类型");
        }
    }

    /// 检查顶层或容器成员绑定声明（按各绑定变量的 `pat_ordinal` 精准写入推导缓存并执行可见性检查）。
    fn checkBindingItem(
        self: *ItemChecker,
        b: *const common.Binding,
        member_idx: ?u32,
    ) PlatformError!void {
        const scratch = self.scratch.allocator();
        const item_id = self.global_item.item;
        const b_defs = try collectBindingDefs(self.pkg_state, scratch, self.global_item.file, item_id, member_idx);

        var var_ty: TypeId = TypeInterner.err_ty;
        if (b.ty) |t| {
            var_ty = self.resolve_data.resolved_types.get(.{ .item = item_id, .hir = t.id() }) orelse TypeInterner.err_ty;
            if (b.init) |ie| _ = try self.checkExpr(ie, var_ty);
        } else if (b.init) |ie| {
            const prev_def = self.current_inferring_var_def;
            const prev_range = self.current_inferring_var_range;
            const prev_rep = self.reported_infer_cycle;
            self.current_inferring_var_def = if (b_defs.len == 1) b_defs[0] else null;
            self.current_inferring_var_range = b.range;
            self.reported_infer_cycle = false;

            var inserted: std.ArrayListUnmanaged(DefId) = .empty;
            for (b_defs) |bd| {
                if (!self.db.inferred_var_cache.contains(bd)) {
                    try self.db.inferred_var_cache.put(self.db.gpa, bd, .computing);
                    try self.db.active_infer_chain.append(self.db.gpa, bd);
                    try inserted.append(scratch, bd);
                }
            }
            defer {
                for (inserted.items) |bd| {
                    if (self.db.inferred_var_cache.get(bd)) |st| {
                        if (st == .computing) {
                            _ = self.db.inferred_var_cache.fetchRemove(bd);
                        }
                    }
                    _ = self.db.active_infer_chain.pop();
                }
                self.current_inferring_var_def = prev_def;
                self.current_inferring_var_range = prev_range;
                self.reported_infer_cycle = prev_rep;
            }

            var_ty = try self.db.types.replaceIdeal(try self.synthExpr(ie, .none));
            for (inserted.items) |bd| {
                const de = self.db.getDef(bd) catch continue;
                const ord: u32 = if (de.origin != null and de.origin.? == .binding_var) de.origin.?.binding_var.pat_ordinal else 0;
                const sub_ty = extractPatternTypeAt(self.db, b.pattern, var_ty, ord);
                try self.db.inferred_var_cache.put(self.db.gpa, bd, .{ .computed = sub_ty });
            }
            for (b_defs) |bd| {
                if (!self.reported_infer_cycle and self.db.cyclic_inferred_defs.contains(bd)) {
                    self.reported_infer_cycle = true;
                    try self.emitDiag(b.range, .err, "无显式类型标注的变量存在循环初始化依赖，无法推导类型");
                    break;
                }
            }
        } else {
            try self.emitDiag(b.range, .err, if (member_idx != null) "成员变量声明缺少类型标注或初始化表达式" else "变量声明缺少类型标注或初始化表达式");
        }

        try self.checkPattern(b.pattern, var_ty);
        self.setNodeType(b.id, var_ty);
        for (b_defs) |bd| {
            const de = self.db.getDef(bd) catch continue;
            const ord: u32 = if (de.origin != null and de.origin.? == .binding_var) de.origin.?.binding_var.pat_ordinal else 0;
            const sub_ty = extractPatternTypeAt(self.db, b.pattern, var_ty, ord);
            try self.checkDeclVisibilityExposure(bd, sub_ty, b.range);
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
                    else blk: {
                        const prev_def = self.current_inferring_ret_def;
                        const prev_range = self.current_inferring_ret_range;
                        const prev_rep = self.reported_infer_cycle;
                        self.current_inferring_ret_def = def_id;
                        self.current_inferring_ret_range = f.range;
                        self.reported_infer_cycle = false;
                        const inserted_computing = !self.db.inferred_ret_cache.contains(def_id);
                        if (inserted_computing) {
                            try self.db.inferred_ret_cache.put(self.db.gpa, def_id, .computing);
                            try self.db.active_infer_chain.append(self.db.gpa, def_id);
                        }
                        defer {
                            if (inserted_computing) {
                                if (self.db.inferred_ret_cache.get(def_id) != null and self.db.inferred_ret_cache.get(def_id).? == .computing) {
                                    _ = self.db.inferred_ret_cache.fetchRemove(def_id);
                                }
                                _ = self.db.active_infer_chain.pop();
                            }
                            self.current_inferring_ret_def = prev_def;
                            self.current_inferring_ret_range = prev_range;
                            self.reported_infer_cycle = prev_rep;
                        }
                        const r = try self.synthCallableBody(body);
                        if (inserted_computing) {
                            try self.db.inferred_ret_cache.put(self.db.gpa, def_id, .{ .computed = r });
                        }
                        if (!self.reported_infer_cycle and self.db.cyclic_inferred_defs.contains(def_id)) {
                            self.reported_infer_cycle = true;
                            try self.emitDiag(f.range, .err, "无显式返回类型标注的递归函数无法推导返回类型");
                        }
                        break :blk r;
                    };
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
            .binding => |b| try self.checkBindingItem(&b, null),
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
                    const prev_mut_method = self.in_mut_method;
                    self.in_mut_method = if (m_def) |md| (if (self.db.getDef(md)) |de| de.flags.is_mut else |_| false) else false;
                    defer self.in_mut_method = prev_mut_method;

                    if (f.body) |body| {
                        const ret = if (sig != null and sig.?.explicit_ret != null)
                            try self.checkCallableBody(body, sig.?.explicit_ret.?)
                        else blk: {
                            const prev_def = self.current_inferring_ret_def;
                            const prev_range = self.current_inferring_ret_range;
                            const prev_rep = self.reported_infer_cycle;
                            self.current_inferring_ret_def = m_def;
                            self.current_inferring_ret_range = f.range;
                            self.reported_infer_cycle = false;
                            const inserted_computing = if (m_def) |md| !self.db.inferred_ret_cache.contains(md) else false;
                            if (inserted_computing) {
                                try self.db.inferred_ret_cache.put(self.db.gpa, m_def.?, .computing);
                                try self.db.active_infer_chain.append(self.db.gpa, m_def.?);
                            }
                            defer {
                                if (inserted_computing) {
                                    const md = m_def.?;
                                    if (self.db.inferred_ret_cache.get(md) != null and self.db.inferred_ret_cache.get(md).? == .computing) {
                                        _ = self.db.inferred_ret_cache.fetchRemove(md);
                                    }
                                    _ = self.db.active_infer_chain.pop();
                                }
                                self.current_inferring_ret_def = prev_def;
                                self.current_inferring_ret_range = prev_range;
                                self.reported_infer_cycle = prev_rep;
                            }
                            const r = try self.synthCallableBody(body);
                            if (inserted_computing) {
                                try self.db.inferred_ret_cache.put(self.db.gpa, m_def.?, .{ .computed = r });
                            }
                            if (m_def) |md| {
                                if (!self.reported_infer_cycle and self.db.cyclic_inferred_defs.contains(md)) {
                                    self.reported_infer_cycle = true;
                                    try self.emitDiag(f.range, .err, "无显式返回类型标注的递归函数无法推导返回类型");
                                }
                            }
                            break :blk r;
                        };
                        if (m_def) |md| try self.checkDeclVisibilityExposure(md, ret, f.range);
                    }
                },
                .init => |in| {
                    const sig = if (m_def) |md| self.db.callableHeaderSig(.{ .def = md }) catch null else null;
                    try self.bindFuncParamTypes(in.params, sig);
                    const is_static_init = if (m_def) |md| (if (self.db.getDef(md)) |de| de.flags.is_static else |_| false) else false;
                    const prev_ctor = self.in_ctor;
                    const prev_static_ctor = self.in_static_ctor;
                    self.in_ctor = true;
                    self.in_static_ctor = is_static_init;
                    defer {
                        self.in_ctor = prev_ctor;
                        self.in_static_ctor = prev_static_ctor;
                    }
                    _ = try self.checkCallableBody(in.body, TypeInterner.unit_ty);
                },
                .primary_ctor => |pc| {
                    const sig = if (m_def) |md| self.db.callableHeaderSig(.{ .def = md }) catch null else null;
                    try self.bindFuncParamTypes(pc.params, sig);
                    const prev_ctor = self.in_ctor;
                    const prev_static_ctor = self.in_static_ctor;
                    self.in_ctor = true;
                    self.in_static_ctor = false;
                    defer {
                        self.in_ctor = prev_ctor;
                        self.in_static_ctor = prev_static_ctor;
                    }
                    _ = try self.checkCallableBody(pc.body, TypeInterner.unit_ty);
                },
                .finalizer => |fin| {
                    try self.bindFuncParamTypes(fin.params, null);
                    _ = try self.checkCallableBody(fin.body, TypeInterner.unit_ty);
                },
                .prop => |p| {
                    const pty = if (m_def) |md| try self.db.propTypeOf(md) else TypeInterner.err_ty;
                    if (m_def) |md| try self.checkDeclVisibilityExposure(md, pty, p.range);
                    const prev_mut_method = self.in_mut_method;
                    self.in_mut_method = if (m_def) |md| (if (self.db.getDef(md)) |de| de.flags.is_mut else |_| false) else false;
                    defer self.in_mut_method = prev_mut_method;
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
                .binding => |b| try self.checkBindingItem(&b, @intCast(m_idx)),
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

/// 收集顶层或成员绑定声明对应的全部变量 `DefId`（支持解构模式绑定多个变量）。
/// 返回切片由调用者传入的 `alloc` 分配，使用结束后由调用者负责释放。
fn collectBindingDefs(
    ps: *const PackageState,
    alloc: std.mem.Allocator,
    file: common.FileId,
    item_id: common.ItemId,
    member_idx: ?u32,
) std.mem.Allocator.Error![]const DefId {
    var list: std.ArrayListUnmanaged(DefId) = .empty;
    const file_defs = ps.file_defs.get(file) orelse return list.items;
    for (file_defs) |def_id| {
        const entry = ps.getDef(def_id.idx) orelse continue;
        if (entry.origin) |orig| {
            if (orig == .binding_var and orig.binding_var.item == item_id and orig.binding_var.member_idx == member_idx) {
                try list.append(alloc, def_id);
            }
        }
    }
    return list.items;
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
