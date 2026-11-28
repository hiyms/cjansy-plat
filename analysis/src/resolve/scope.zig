// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 文件内九级词法作用域树、局部符号表、可见扩展索引与文件级早绑定只读产物（`FileResolveData`）。

const std = @import("std");
const common = @import("common");
const ids = @import("../ids.zig");
const pkg_state_mod = @import("../db/PackageState.zig");

const CallableHeaderSig = pkg_state_mod.CallableHeaderSig;
const DefId = ids.DefId;
const ExportEntry = pkg_state_mod.ExportEntry;
const InternedId = ids.InternedId;
const LocalSymId = ids.LocalSymId;
const ModuleId = ids.ModuleId;
const PackageId = ids.PackageId;
const PrimKind = ids.PrimKind;
const ReferenceKind = ids.ReferenceKind;
const ScopeId = ids.ScopeId;
const SymbolKind = ids.SymbolKind;
const SymbolRef = ids.SymbolRef;
const TypeId = ids.TypeId;

/// 九级词法作用域种类与重载分级 `scope_level` 约定：
/// - `std_core_prelude` / `file_glob_import` / `file_explicit_import`：普通导入 `scope_level = -1`
/// - `package_top`（含重导出项与外部枚举构造器）：`scope_level = 0`
/// - `type_or_extend_type_params` / `type_or_extend_body`：`scope_level = 1`（父类、子类、接口与 `extend` 成员同级）
/// - `callable_type_params` / `param_list` / `local_block`：`scope_level >= 2` 随嵌套递增
pub const ScopeKind = enum(u8) {
    std_core_prelude,
    file_glob_import,
    file_explicit_import,
    package_top,
    type_or_extend_type_params,
    type_or_extend_body,
    callable_type_params,
    param_list,
    local_block,
    if_let_branch,
    while_let_branch,
    for_in_body,
    match_case,
    try_resources,
    catch_or_handle_clause,
};

/// 单个局部符号定义（分配于 `FileQueryState.sema_arena`）。
pub const LocalSymbol = struct {
    id: LocalSymId,
    kind: SymbolKind,
    name: InternedId,
    decl_key: common.HirKey,
    name_range: common.TextRange,
    /// 定义位置顺序可见起点：局部 `let`/`var`/`const` 与局部 `func` 均从定义位置之后生效；
    /// 局部 `func` 在自身函数体内可见以支持单函数自递归，禁止局部函数之间相互递归。
    visible_from: u32,
    is_mut: bool,
    /// 非函数局部绑定的显式类型注解（省略时为 `null`，由 `typeck` 推导）。
    annotated_ty: ?TypeId = null,
    /// 局部 `func` 对应的头部签名索引（非函数为 `null`，指向 `FileResolveData.local_callables`）。
    callable_sig_idx: ?u32 = null,
    /// 是否属于形参、条件模式或资源声明引入（用于检测紧跟语句块内同级重定义）。
    is_block_head_binding: bool = false,
};

/// 当前文件版本中包级声明的易漂移源码位置信息（分配于 `FileQueryState.sema_arena`，随单文件编辑自动刷新）。
pub const DefSourceInfo = struct {
    hir_key: common.HirKey,
    name_range: common.TextRange,
    decl_range: common.TextRange,
};

/// 文件词法作用域树中的单个作用域节点。
pub const Scope = struct {
    id: ScopeId,
    kind: ScopeKind,
    parent: ?ScopeId,
    owner_def: ?DefId,
    range: common.TextRange,
    scope_level: i32,
    /// 子作用域下标区间（指向 `FileResolveData.scopes`，按 `(range.start, range.end desc, kind)` 排序以支持二分查找）。
    children_start: u32,
    children_len: u32,
    /// 本层直接引入的局部符号下标区间（指向 `FileResolveData.scope_local_indices`，元素为 `FileResolveData.locals` 下标）。
    locals_start: u32,
    locals_len: u32,
};

/// 标识符段级绑定记录（支持 `HirExpr.path`、`HirType.path`、`ImportItem`、`Annotation`、`FieldExpr` 与命名参数标签的精确二分定位）。
pub const ResolvedIdentOccurrence = struct {
    range: common.TextRange,
    target: SymbolRef,
    kind: ReferenceKind,
    owner_def: ?DefId,

    /// 供 `std.mem.sort` 按区间起点升序排列的比较函数。
    pub fn lessThan(_: void, a: ResolvedIdentOccurrence, b: ResolvedIdentOccurrence) bool {
        if (a.range.start != b.range.start) return a.range.start < b.range.start;
        return a.range.end < b.range.end;
    }
};

/// 早绑定阶段收集的单个重载候选。
pub const EarlyCandidate = struct {
    ref: SymbolRef,
    scope_level: i32,
    is_reexport: bool,
};

/// 早绑定阶段为无限定调用或路径首段记录的重载候选集合。
pub const EarlyOverloadSet = struct {
    candidates: []const EarlyCandidate,
};

/// 单文件可见扩展索引（按被扩展主类型归类当前文件可访问的全部 `ExtendEntry`）。
pub const VisibleExtendIndex = struct {
    by_nominal: std.AutoHashMapUnmanaged(DefId, []const DefId) = .empty,
    by_prim: [@typeInfo(PrimKind).@"enum".field_names.len][]const DefId = @splat(&.{}),

    /// 获取目标名义类型在当前文件可见的全部 `extend` 句柄切片；借用自 `FileQueryState.sema_arena`，调用者不得释放。
    pub inline fn getForNominal(self: *const VisibleExtendIndex, def: DefId) []const DefId {
        return self.by_nominal.get(def) orelse &.{};
    }

    /// 获取目标基础类型在当前文件可见的全部 `extend` 句柄切片；借用自 `FileQueryState.sema_arena`，调用者不得释放。
    pub inline fn getForPrim(self: *const VisibleExtendIndex, prim: PrimKind) []const DefId {
        return self.by_prim[@backingInt(prim)];
    }
};

/// 文件级词法早绑定只读产物（分配于 `FileQueryState.sema_arena`，构造完成后完全不可变）。
pub const FileResolveData = struct {
    file: common.FileId,
    version: u32,
    pkg_id: PackageId,
    module_id: ModuleId,

    scopes: []const Scope,
    locals: []const LocalSymbol,
    /// 各作用域直属局部符号的扁平下标索引表（`Scope.locals_start..locals_start+locals_len` 索引此切片，每个元素指向 `locals` 下标）。
    scope_local_indices: []const u32 = &.{},
    /// 本文件全部局部 `func` 的头部签名列表（含泛型形参、`where` 约束、命名与默认参数及显式返回类型）。
    local_callables: []const CallableHeaderSig = &.{},
    /// 本文件内各包级 `DefId` 在当前文件版本中的精确 `HirKey` 与源码区间映射。
    def_source_infos: std.AutoHashMapUnmanaged(DefId, DefSourceInfo) = .empty,

    /// 当前文件显式导入映射（具名与别名导入，支持同名重载函数列表）。
    explicit_imports: std.AutoHashMapUnmanaged(InternedId, []const ExportEntry) = .empty,
    /// 当前文件显式导入的包名或包别名映射。
    explicit_pkg_imports: std.AutoHashMapUnmanaged(InternedId, PackageId) = .empty,
    /// 当前文件通配符导入来源包列表（含隐式 `std.core.*`）。
    glob_import_pkgs: []const PackageId = &.{},
    visible_extends: VisibleExtendIndex = .{},

    /// 显式 `HirType` 节点的消解结果表（按 `HirKey` 查询）。
    resolved_types: std.AutoHashMapUnmanaged(common.HirKey, TypeId) = .empty,
    /// 早绑定确定目标（局部变量、确定类型/包前缀、单一非重载符号）。
    early_bindings: std.AutoHashMapUnmanaged(common.HirKey, SymbolRef) = .empty,
    /// 早绑定阶段收集的重载候选集，移交 `typeck` 执行晚绑定决议。
    early_overloads: std.AutoHashMapUnmanaged(common.HirKey, EarlyOverloadSet) = .empty,
    /// 本文件全部早绑定段级定位记录（按 `range.start` 升序互不重叠）。
    early_occurrences: []const ResolvedIdentOccurrence = &.{},
    diagnostics: []const common.Diagnostic = &.{},

    /// 定位包含字节位置 `offset` 的最内层词法作用域；返回指针借用自 `FileQueryState.sema_arena`，调用者不得释放。
    pub fn scopeAt(self: *const FileResolveData, offset: u32) ?*const Scope {
        if (self.scopes.len == 0) return null;
        var best: ?*const Scope = null;
        for (self.scopes) |*s| {
            if (s.range.start <= offset and offset <= s.range.end) {
                if (best) |b| {
                    const s_len = s.range.len();
                    const b_len = b.range.len();
                    if (s_len < b_len or (s_len == b_len and s.scope_level >= b.scope_level)) {
                        best = s;
                    }
                } else {
                    best = s;
                }
            }
        }
        return best;
    }

    /// 按 `ScopeId` 获取作用域只读指针；越界返回 `null`。返回指针借用自 `FileQueryState.sema_arena`，调用者不得释放。
    pub inline fn getScope(self: *const FileResolveData, id: ScopeId) ?*const Scope {
        if (!common.FileId.eql(id.file, self.file)) return null;
        return if (id.idx < self.scopes.len) &self.scopes[id.idx] else null;
    }

    /// 按 `LocalSymId.idx` 获取局部符号元信息；返回指针借用自 `FileQueryState.sema_arena`，调用者不得释放。
    pub inline fn getLocal(self: *const FileResolveData, idx: u32) ?*const LocalSymbol {
        return if (idx < self.locals.len) &self.locals[idx] else null;
    }

    /// 获取局部 `func` 的头部签名；返回指针借用自 `FileQueryState.sema_arena`，调用者不得释放。
    pub inline fn getLocalCallable(self: *const FileResolveData, idx: u32) ?*const CallableHeaderSig {
        return if (idx < self.local_callables.len) &self.local_callables[idx] else null;
    }

    /// 在有序 `early_occurrences` 表上二分定位覆盖 `offset` 的早绑定标识符记录。
    pub fn occurrenceAt(self: *const FileResolveData, offset: u32) ?ResolvedIdentOccurrence {
        return binarySearchOccurrence(self.early_occurrences, offset);
    }
};

/// 在按 `range.start` 升序排列的 `ResolvedIdentOccurrence` 切片中二分查找包含 `offset` 的记录。
pub fn binarySearchOccurrence(
    list: []const ResolvedIdentOccurrence,
    offset: u32,
) ?ResolvedIdentOccurrence {
    var lo: usize = 0;
    var hi: usize = list.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const item = list[mid];
        if (offset < item.range.start) {
            hi = mid;
        } else if (offset >= item.range.end and !item.range.isEmpty()) {
            lo = mid + 1;
        } else {
            return item;
        }
    }
    return null;
}

test "binarySearchOccurrence 精确定位有序区间" {
    const occs = [_]ResolvedIdentOccurrence{
        .{ .range = .{ .start = 0, .end = 3 }, .target = .{ .prim = .int64 }, .kind = .type_ref, .owner_def = null },
        .{ .range = .{ .start = 5, .end = 9 }, .target = .{ .prim = .bool_ }, .kind = .type_ref, .owner_def = null },
        .{ .range = .{ .start = 12, .end = 15 }, .target = .{ .prim = .unit }, .kind = .type_ref, .owner_def = null },
    };
    try std.testing.expectEqual(PrimKind.int64, binarySearchOccurrence(&occs, 0).?.target.prim);
    try std.testing.expectEqual(PrimKind.bool_, binarySearchOccurrence(&occs, 7).?.target.prim);
    try std.testing.expect(binarySearchOccurrence(&occs, 4) == null);
    try std.testing.expect(binarySearchOccurrence(&occs, 20) == null);
}
