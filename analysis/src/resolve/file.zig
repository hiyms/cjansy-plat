// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 文件级词法早绑定（`resolveFile`）：构建九级词法作用域树、可见扩展索引、
//! 当前版本声明位置映射、显式类型消解与有序早绑定段级定位表。

const std = @import("std");
const common = @import("common");
const frontend = @import("frontend");
const ids = @import("../ids.zig");
const file_state_mod = @import("../db/FileState.zig");
const pkg_state_mod = @import("../db/PackageState.zig");
const db_mod = @import("../db/Database.zig");
const scope_mod = @import("scope.zig");
const package_mod = @import("package.zig");
const access_mod = @import("access.zig");
const type_interner_mod = @import("../interner/TypeInterner.zig");

const CallableHeaderSig = pkg_state_mod.CallableHeaderSig;
const Database = db_mod.Database;
const DefId = ids.DefId;
const DefSourceInfo = scope_mod.DefSourceInfo;
const EarlyCandidate = scope_mod.EarlyCandidate;
const ExportEntry = pkg_state_mod.ExportEntry;
const FileResolveData = scope_mod.FileResolveData;
const InternedId = ids.InternedId;
const LocalSymId = ids.LocalSymId;
const LocalSymbol = scope_mod.LocalSymbol;
const PackageId = ids.PackageId;
const PackageState = pkg_state_mod.PackageState;
const PlatformError = file_state_mod.PlatformError;
const PrimKind = ids.PrimKind;
const ReferenceKind = ids.ReferenceKind;
const ResolvedIdentOccurrence = scope_mod.ResolvedIdentOccurrence;
const Scope = scope_mod.Scope;
const ScopeId = ids.ScopeId;
const ScopeKind = scope_mod.ScopeKind;
const SymbolKind = ids.SymbolKind;
const SymbolRef = ids.SymbolRef;
const TypeId = ids.TypeId;
const TypeInterner = type_interner_mod.TypeInterner;
const TypeParamRef = ids.TypeParamRef;
const TypeParamScope = package_mod.TypeParamScope;
const TypeResolveEnv = package_mod.TypeResolveEnv;
const VisibleExtendIndex = scope_mod.VisibleExtendIndex;

/// 文件级早绑定构建上下文（临时缓冲分配于 `db.gpa`，最终产物全部写入 `FileQueryState.sema_arena`）。
const FileResolver = struct {
    db: *Database,
    arena: std.mem.Allocator,
    file: common.FileId,
    pkg_state: *const PackageState,
    lowered: *const frontend.LoweredFile,

    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    /// 各作用域直属局部符号索引列表（与 `scopes` 下标一一对应，避免嵌套子作用域破坏父作用域局部符号区间）。
    scope_local_lists: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u32)) = .empty,
    locals: std.ArrayListUnmanaged(LocalSymbol) = .empty,
    local_callables: std.ArrayListUnmanaged(CallableHeaderSig) = .empty,
    def_source_infos: std.AutoHashMapUnmanaged(DefId, DefSourceInfo) = .empty,

    explicit_imports: std.AutoHashMapUnmanaged(InternedId, []const ExportEntry) = .empty,
    explicit_pkg_imports: std.AutoHashMapUnmanaged(InternedId, PackageId) = .empty,
    glob_import_pkgs: std.ArrayListUnmanaged(PackageId) = .empty,
    visible_extends: VisibleExtendIndex = .{},

    resolved_types: std.AutoHashMapUnmanaged(common.HirKey, TypeId) = .empty,
    early_bindings: std.AutoHashMapUnmanaged(common.HirKey, SymbolRef) = .empty,
    early_overloads: std.AutoHashMapUnmanaged(common.HirKey, scope_mod.EarlyOverloadSet) = .empty,
    occurrences: std.ArrayListUnmanaged(ResolvedIdentOccurrence) = .empty,
    diagnostics: std.ArrayListUnmanaged(common.Diagnostic) = .empty,

    /// 活跃泛型形参作用域链表（内层在尾部，查找时逆序匹配）。
    tp_scopes: std.ArrayListUnmanaged(TypeParamScope) = .empty,
    /// 当前封闭名义类型或扩展链（内层在尾部）。
    enclosing_defs: std.ArrayListUnmanaged(DefId) = .empty,

    /// 释放临时缓冲容器（不释放已写入 `arena` 的产物）。
    fn deinit(self: *FileResolver) void {
        for (self.scope_local_lists.items) |*list| list.deinit(self.db.gpa);
        self.scope_local_lists.deinit(self.db.gpa);
        self.tp_scopes.deinit(self.db.gpa);
        self.enclosing_defs.deinit(self.db.gpa);
    }

    /// 压入新的词法作用域并返回其 `ScopeId`。
    fn pushScope(
        self: *FileResolver,
        kind: ScopeKind,
        parent: ?ScopeId,
        owner_def: ?DefId,
        range: common.TextRange,
        scope_level: i32,
    ) std.mem.Allocator.Error!ScopeId {
        const idx: u32 = @intCast(self.scopes.items.len);
        const sid: ScopeId = .{ .file = self.file, .idx = idx };
        try self.scope_local_lists.append(self.db.gpa, .empty);
        try self.scopes.append(self.arena, .{
            .id = sid,
            .kind = kind,
            .parent = parent,
            .owner_def = owner_def,
            .range = range,
            .scope_level = scope_level,
            .children_start = 0,
            .children_len = 0,
            .locals_start = 0,
            .locals_len = 0,
        });
        return sid;
    }

    /// 构造当前上下文的 `TypeResolveEnv`。
    fn currentTypeEnv(self: *const FileResolver) TypeResolveEnv {
        const enc = if (self.enclosing_defs.items.len > 0)
            self.enclosing_defs.items[self.enclosing_defs.items.len - 1]
        else
            null;
        return .{
            .db = self.db,
            .pkg_state = self.pkg_state,
            .file = self.file,
            .explicit_imports = &self.explicit_imports,
            .explicit_pkg_imports = &self.explicit_pkg_imports,
            .glob_import_pkgs = self.glob_import_pkgs.items,
            .enclosing_this = enc,
            .type_param_scopes = self.tp_scopes.items,
        };
    }

    /// 登记单条标识符段级定位记录（跳过空区间）。
    fn recordOcc(
        self: *FileResolver,
        range: common.TextRange,
        target: SymbolRef,
        kind: ReferenceKind,
        owner_def: ?DefId,
    ) std.mem.Allocator.Error!void {
        if (range.isEmpty()) return;
        try self.occurrences.append(self.arena, .{
            .range = range,
            .target = target,
            .kind = kind,
            .owner_def = owner_def,
        });
    }

    /// 消解单个 `HirType` 并写入 `resolved_types` 同时记录类型路径段定位。
    fn resolveTypeNode(self: *FileResolver, item_id: common.ItemId, ht: *const common.HirType) PlatformError!TypeId {
        const env = self.currentTypeEnv();
        const ty = try package_mod.resolveHirTypeInEnv(&env, ht);
        try self.resolved_types.put(self.arena, .{ .item = item_id, .hir = ht.id() }, ty);

        switch (ht.*) {
            .path => |p| {
                if (p.segments.len == 1) {
                    const seg = p.segments[0];
                    const seg_id = try self.db.strings.intern(seg.name.text);
                    const alias_hit: ?DefId = blk: {
                        if (try package_mod.lookupTypeDefInEnv(&env, seg_id)) |td| {
                            if (self.db.getDef(td)) |de| {
                                if (de.kind == .type_alias) break :blk td;
                            } else |_| {}
                        }
                        break :blk null;
                    };
                    if (alias_hit) |ad| {
                        try self.recordOcc(seg.name.range, .{ .def = ad }, .type_ref, null);
                    } else switch (self.db.types.get(ty)) {
                        .prim => |pk| try self.recordOcc(seg.name.range, .{ .prim = pk }, .type_ref, null),
                        .nominal => |n| try self.recordOcc(seg.name.range, .{ .def = n.def }, .type_ref, null),
                        .type_param => |tp| try self.recordOcc(seg.name.range, .{ .type_param = tp }, .type_ref, null),
                        else => {},
                    }
                    for (seg.type_args) |*ta| _ = try self.resolveTypeNode(item_id, ta);
                } else if (p.segments.len >= 2) {
                    const first_id = try self.db.strings.intern(p.segments[0].name.text);
                    if (self.explicit_pkg_imports.get(first_id)) |tgt_pkg| {
                        try self.recordOcc(p.segments[0].name.range, .{ .pkg = tgt_pkg }, .type_ref, null);
                    }
                    const last = p.segments[p.segments.len - 1];
                    if (self.db.types.get(ty) == .nominal) {
                        try self.recordOcc(last.name.range, .{ .def = self.db.types.get(ty).nominal.def }, .type_ref, null);
                    }
                    for (last.type_args) |*ta| _ = try self.resolveTypeNode(item_id, ta);
                }
            },
            .option => |o| _ = try self.resolveTypeNode(item_id, o.inner),
            .tuple => |t| {
                for (t.elements) |el| _ = try self.resolveTypeNode(item_id, el.ty);
            },
            .func => |f| {
                for (f.params) |param| _ = try self.resolveTypeNode(item_id, param.ty);
                _ = try self.resolveTypeNode(item_id, f.ret);
            },
            .varray => |v| _ = try self.resolveTypeNode(item_id, v.elem),
            .this => {},
        }
        return ty;
    }

    /// 在给定局部作用域链中按定义点顺序查找同名局部符号（检查重定义与可见位置）。
    fn addLocal(
        self: *FileResolver,
        scope_id: ScopeId,
        global_item: ids.GlobalItemId,
        kind: SymbolKind,
        name: common.Name,
        decl_key: common.HirKey,
        visible_from: u32,
        is_mut: bool,
        annotated_ty: ?TypeId,
        callable_sig_idx: ?u32,
        is_block_head: bool,
    ) PlatformError!LocalSymId {
        const name_id = try self.db.strings.intern(name.text);
        // 检查同一作用域内（或紧跟语句块头绑定）是否已声明同名非函数局部符号
        const loc_list = &self.scope_local_lists.items[scope_id.idx];
        for (loc_list.items) |prev_idx| {
            const prev = self.locals.items[prev_idx];
            if (prev.name == name_id and (kind != .func_ or prev.kind != .func_)) {
                try self.diagnostics.append(self.arena, .{
                    .file = self.file,
                    .range = name.range,
                    .severity = .err,
                    .source = .name_res,
                    .message = "同一作用域内重复定义标识符",
                    .related = try self.arena.dupe(common.RelatedInfo, &.{.{
                        .file = self.file,
                        .range = prev.name_range,
                        .message = "此前已在此处定义",
                    }}),
                });
                break;
            }
        }

        const idx: u32 = @intCast(self.locals.items.len);
        const sym_id: LocalSymId = .{ .global_item = global_item, .idx = idx };
        try self.locals.append(self.arena, .{
            .id = sym_id,
            .kind = kind,
            .name = name_id,
            .decl_key = decl_key,
            .name_range = name.range,
            .visible_from = visible_from,
            .is_mut = is_mut,
            .annotated_ty = annotated_ty,
            .callable_sig_idx = callable_sig_idx,
            .is_block_head_binding = is_block_head,
        });
        try loc_list.append(self.db.gpa, idx);
        try self.recordOcc(name.range, .{ .local = sym_id }, .decl, null);
        return sym_id;
    }

    /// 沿九级作用域链执行无限定名称查找，返回早绑定结果（确定符号或重载候选集）。
    fn lookupUnqualified(
        self: *FileResolver,
        scope_id: ScopeId,
        name_id: InternedId,
        use_offset: u32,
    ) PlatformError!struct { single: ?SymbolRef = null, candidates: []const EarlyCandidate = &.{} } {
        var cands: std.ArrayListUnmanaged(EarlyCandidate) = .empty;
        defer cands.deinit(self.db.gpa);

        // 1. 沿局部作用域链自内向外查找
        var cur_opt: ?ScopeId = scope_id;
        while (cur_opt) |cur_id| {
            const s = self.scopes.items[cur_id.idx];
            const loc_indices = self.scope_local_lists.items[cur_id.idx].items;
            var i: usize = loc_indices.len;
            while (i > 0) {
                i -= 1;
                const loc = self.locals.items[loc_indices[i]];
                if (loc.name != name_id) continue;
                if (use_offset < loc.visible_from) continue;
                if (loc.kind == .func_) {
                    try cands.append(self.db.gpa, .{
                        .ref = .{ .local = loc.id },
                        .scope_level = s.scope_level,
                        .is_reexport = false,
                    });
                } else {
                    if (cands.items.len == 0) {
                        return .{ .single = .{ .local = loc.id } };
                    }
                    return .{ .candidates = try self.arena.dupe(EarlyCandidate, cands.items) };
                }
            }

            // 经过类型或扩展体作用域时收集封闭类型及继承链中的可见成员（仅在 extend 内查找其他 extend 成员）
            if (s.kind == .type_or_extend_body) {
                if (s.owner_def) |owner_def| {
                    const owner_entry = self.db.getDef(owner_def) catch null;
                    if (owner_entry) |oe| {
                        var found_non_fn: ?DefId = null;
                        for (oe.members) |m_def| {
                            const me = self.db.getDef(m_def) catch continue;
                            if (me.kind == .primary_ctor or me.kind == .constructor or me.kind == .finalizer) continue;
                            if (me.name != name_id) continue;
                            if (me.kind == .method or me.kind == .func_) {
                                try cands.append(self.db.gpa, .{
                                    .ref = .{ .def = m_def },
                                    .scope_level = 1,
                                    .is_reexport = false,
                                });
                            } else if (found_non_fn == null) {
                                found_non_fn = m_def;
                            }
                        }
                        if (found_non_fn) |nf| {
                            if (cands.items.len == 0) return .{ .single = .{ .def = nf } };
                            return .{ .candidates = try self.arena.dupe(EarlyCandidate, cands.items) };
                        }
                        // 在 extend 体内部时，同时查找被扩展目标名义类型自身成员（支持无限定访问字段与方法）
                        if (oe.kind == .extend_) {
                            for (self.pkg_state.extends) |ext| {
                                if (!DefId.eql(ext.def, owner_def)) continue;
                                if (ext.target_kind == .nominal) {
                                    if (self.db.getDef(ext.target_kind.nominal)) |target_oe| {
                                        for (target_oe.members) |tm_def| {
                                            const tme = self.db.getDef(tm_def) catch continue;
                                            if (tme.kind == .primary_ctor or tme.kind == .constructor or tme.kind == .finalizer) continue;
                                            if (tme.name != name_id) continue;
                                            if (tme.kind == .method or tme.kind == .func_) {
                                                try cands.append(self.db.gpa, .{
                                                    .ref = .{ .def = tm_def },
                                                    .scope_level = 1,
                                                    .is_reexport = false,
                                                });
                                            } else if (found_non_fn == null) {
                                                found_non_fn = tm_def;
                                            }
                                        }
                                        if (found_non_fn) |nf| {
                                            if (cands.items.len == 0) return .{ .single = .{ .def = nf } };
                                            return .{ .candidates = try self.arena.dupe(EarlyCandidate, cands.items) };
                                        }
                                    } else |_| {}
                                }
                                break;
                            }
                        }
                    }
                }
            }
            cur_opt = s.parent;
        }

        // 2. 当前包顶层作用域（scope_level = 0，本文件 private 与本包非私有共同参与重载）
        {
            var found_non_fn: ?DefId = null;
            for (self.pkg_state.lookupTop(name_id)) |exp| {
                if (exp.vis == .private) {
                    if (exp.source_file == null or !common.FileId.eql(exp.source_file.?, self.file)) continue;
                }
                const de = self.db.getDef(exp.def) catch continue;
                if (de.kind == .func_ or de.kind == .method) {
                    try cands.append(self.db.gpa, .{
                        .ref = .{ .def = exp.def },
                        .scope_level = 0,
                        .is_reexport = exp.is_reexport,
                    });
                } else if (found_non_fn == null) {
                    found_non_fn = exp.def;
                }
            }
            if (found_non_fn) |nf| {
                if (cands.items.len == 0) return .{ .single = .{ .def = nf } };
                return .{ .candidates = try self.arena.dupe(EarlyCandidate, cands.items) };
            }
        }

        // 3. 当前文件显式导入包名
        if (self.explicit_pkg_imports.get(name_id)) |imp_pkg| {
            if (cands.items.len == 0) return .{ .single = .{ .pkg = imp_pkg } };
        }

        // 4. 当前文件显式具名/别名导入（普通导入 scope_level = -1）
        if (self.explicit_imports.get(name_id)) |entries| {
            var found_non_fn: ?DefId = null;
            for (entries) |exp| {
                const de = self.db.getDef(exp.def) catch continue;
                if (de.kind == .func_ or de.kind == .method) {
                    try cands.append(self.db.gpa, .{
                        .ref = .{ .def = exp.def },
                        .scope_level = if (exp.is_reexport) 0 else -1,
                        .is_reexport = exp.is_reexport,
                    });
                } else if (found_non_fn == null) {
                    found_non_fn = exp.def;
                }
            }
            if (found_non_fn) |nf| {
                if (cands.items.len == 0) return .{ .single = .{ .def = nf } };
                return .{ .candidates = try self.arena.dupe(EarlyCandidate, cands.items) };
            }
        }

        // 5. 当前文件通配符导入（含隐式 std.core，scope_level = -1）
        {
            var found_non_fn: ?DefId = null;
            for (self.glob_import_pkgs.items) |gp| {
                const ps = self.db.packageState(gp) catch continue;
                const rel = self.db.pkg_interner.relation(self.pkg_state.pkg_id, gp);
                for (ps.lookupTop(name_id)) |exp| {
                    if (!access_mod.isVisibleInRelation(exp.vis, rel)) continue;
                    const de = self.db.getDef(exp.def) catch continue;
                    if (de.kind == .func_ or de.kind == .method) {
                        try cands.append(self.db.gpa, .{
                            .ref = .{ .def = exp.def },
                            .scope_level = -1,
                            .is_reexport = false,
                        });
                    } else if (found_non_fn == null) {
                        found_non_fn = exp.def;
                    }
                }
            }
            if (found_non_fn) |nf| {
                if (cands.items.len == 0) return .{ .single = .{ .def = nf } };
            }
        }

        if (cands.items.len == 1) {
            return .{ .single = cands.items[0].ref, .candidates = try self.arena.dupe(EarlyCandidate, cands.items) };
        }
        if (cands.items.len > 1) {
            return .{ .candidates = try self.arena.dupe(EarlyCandidate, cands.items) };
        }
        return .{};
    }

    /// 递归遍历表达式构建局部作用域、消解显式类型并记录早绑定。
    fn walkExpr(
        self: *FileResolver,
        item_id: common.ItemId,
        scope_id: ScopeId,
        expr: *const common.HirExpr,
    ) PlatformError!void {
        const global_item: ids.GlobalItemId = .{ .file = self.file, .item = item_id };
        switch (expr.*) {
            .path => |p| {
                if (p.segments.len == 0) return;
                const seg0 = p.segments[0];
                for (p.segments) |seg| {
                    for (seg.type_args) |*ta| _ = try self.resolveTypeNode(item_id, ta);
                }
                if (!seg0.name.is_raw) {
                    if (PrimKind.fromKeyword(seg0.name.text)) |pk| {
                        try self.early_bindings.put(self.arena, .{ .item = item_id, .hir = p.id }, .{ .prim = pk });
                        try self.recordOcc(seg0.name.range, .{ .prim = pk }, .type_ref, null);
                        return;
                    }
                    if (std.mem.eql(u8, seg0.name.text, "this") or std.mem.eql(u8, seg0.name.text, "super") or std.mem.eql(u8, seg0.name.text, "This")) {
                        if (self.enclosing_defs.items.len > 0) {
                            const enc = self.enclosing_defs.items[self.enclosing_defs.items.len - 1];
                            var target_ref: SymbolRef = .{ .def = enc };
                            // 若位于 extend 体中，`this` 指向被扩展目标类型以便 `this.` 补全与 `symbolAt` 定位准确识别接收者
                            if (self.db.getDef(enc)) |ee| {
                                if (ee.kind == .extend_) {
                                    for (self.pkg_state.extends) |ext| {
                                        if (DefId.eql(ext.def, enc)) {
                                            target_ref = switch (ext.target_kind) {
                                                .nominal => |td| .{ .def = td },
                                                .prim => |pk| .{ .prim = pk },
                                            };
                                            break;
                                        }
                                    }
                                }
                            } else |_| {}
                            try self.early_bindings.put(self.arena, .{ .item = item_id, .hir = p.id }, .{ .def = enc });
                            try self.recordOcc(seg0.name.range, target_ref, .read, enc);
                        }
                        return;
                    }
                }
                const seg0_id = try self.db.strings.intern(seg0.name.text);
                const res = try self.lookupUnqualified(scope_id, seg0_id, seg0.name.range.start);
                if (res.single) |sym| {
                    try self.early_bindings.put(self.arena, .{ .item = item_id, .hir = p.id }, sym);
                    try self.recordOcc(seg0.name.range, sym, .read, null);
                    // 包限定路径继续向后消解第 2 段
                    if (sym == .pkg and p.segments.len >= 2) {
                        const seg1 = p.segments[1];
                        const seg1_id = try self.db.strings.intern(seg1.name.text);
                        if (self.db.packageState(sym.pkg)) |ps| {
                            const exps = ps.lookupTop(seg1_id);
                            if (exps.len == 1) {
                                try self.recordOcc(seg1.name.range, .{ .def = exps[0].def }, .read, null);
                            }
                        } else |_| {}
                    }
                }
                if (res.candidates.len > 0) {
                    try self.early_overloads.put(self.arena, .{ .item = item_id, .hir = p.id }, .{ .candidates = res.candidates });
                }
            },
            .field => |f| {
                try self.walkExpr(item_id, scope_id, f.base);
                for (f.type_args) |*ta| _ = try self.resolveTypeNode(item_id, ta);
            },
            .optional => |o| try self.walkExpr(item_id, scope_id, o.operand),
            .call => |c| {
                try self.walkExpr(item_id, scope_id, c.callee);
                for (c.args) |arg| try self.walkExpr(item_id, scope_id, arg.value);
                if (c.trailing_lambda) |tl| try self.walkExpr(item_id, scope_id, tl);
            },
            .index => |idx| {
                try self.walkExpr(item_id, scope_id, idx.base);
                for (idx.indices) |*i| try self.walkExpr(item_id, scope_id, i);
            },
            .inc_dec => |id_expr| try self.walkExpr(item_id, scope_id, id_expr.operand),
            .unary => |u| try self.walkExpr(item_id, scope_id, u.operand),
            .binary => |b| {
                try self.walkExpr(item_id, scope_id, b.lhs);
                try self.walkExpr(item_id, scope_id, b.rhs);
            },
            .assign => |asg| {
                try self.walkExpr(item_id, scope_id, asg.lhs);
                try self.walkExpr(item_id, scope_id, asg.rhs);
            },
            .range_expr => |r| {
                if (r.start) |s| try self.walkExpr(item_id, scope_id, s);
                if (r.end) |e| try self.walkExpr(item_id, scope_id, e);
                if (r.step) |st| try self.walkExpr(item_id, scope_id, st);
            },
            .is_expr => |is_e| {
                try self.walkExpr(item_id, scope_id, is_e.operand);
                _ = try self.resolveTypeNode(item_id, is_e.ty);
            },
            .as_expr => |as_e| {
                try self.walkExpr(item_id, scope_id, as_e.operand);
                _ = try self.resolveTypeNode(item_id, as_e.ty);
            },
            .type_conv => |tc| {
                _ = try self.resolveTypeNode(item_id, tc.ty);
                try self.walkExpr(item_id, scope_id, tc.value);
            },
            .varray => |va| {
                _ = try self.resolveTypeNode(item_id, va.ty);
                for (va.args) |arg| try self.walkExpr(item_id, scope_id, arg.value);
                if (va.trailing_lambda) |tl| try self.walkExpr(item_id, scope_id, tl);
            },
            .tuple_lit => |t| {
                for (t.elements) |*el| try self.walkExpr(item_id, scope_id, el);
            },
            .array_lit => |al| {
                for (al.elements) |el| try self.walkExpr(item_id, scope_id, el.value);
            },
            .str_interp => |si| {
                for (si.parts) |part| {
                    if (part == .interpolation) {
                        try self.walkBlock(item_id, scope_id, part.interpolation.body, false);
                    }
                }
            },
            .block => |*blk| try self.walkBlock(item_id, scope_id, blk, true),
            .if_expr => |ie| {
                switch (ie.condition) {
                    .expr => |ce| {
                        try self.walkExpr(item_id, scope_id, ce);
                        try self.walkBlock(item_id, scope_id, ie.then_branch, true);
                    },
                    .let_destructor => |ld| {
                        try self.walkExpr(item_id, scope_id, ld.value);
                        const parent_level = self.scopes.items[scope_id.idx].scope_level;
                        const branch_scope = try self.pushScope(.if_let_branch, scope_id, null, ie.then_branch.range, parent_level + 1);
                        for (ld.patterns) |*pat| {
                            try self.bindPatternLocals(item_id, branch_scope, pat, false, ld.range.end, true);
                        }
                        try self.walkBlock(item_id, branch_scope, ie.then_branch, false);
                    },
                }
                if (ie.else_branch) |eb| try self.walkExpr(item_id, scope_id, eb);
            },
            .match_expr => |me| {
                if (me.selector) |sel| try self.walkExpr(item_id, scope_id, sel);
                const parent_level = self.scopes.items[scope_id.idx].scope_level;
                for (me.cases) |mc| {
                    switch (mc) {
                        .pattern => |pc| {
                            const case_scope = try self.pushScope(.match_case, scope_id, null, pc.range, parent_level + 1);
                            for (pc.patterns) |*pat| {
                                try self.bindPatternLocals(item_id, case_scope, pat, false, pat.range().end, true);
                            }
                            if (pc.guard) |g| try self.walkExpr(item_id, case_scope, g);
                            try self.walkBlock(item_id, case_scope, pc.body, false);
                        },
                        .expr => |ec| {
                            try self.walkExpr(item_id, scope_id, ec.value);
                            try self.walkBlock(item_id, scope_id, ec.body, true);
                        },
                    }
                }
            },
            .while_expr => |we| {
                switch (we.condition) {
                    .expr => |ce| {
                        try self.walkExpr(item_id, scope_id, ce);
                        try self.walkBlock(item_id, scope_id, we.body, true);
                    },
                    .let_destructor => |ld| {
                        try self.walkExpr(item_id, scope_id, ld.value);
                        const parent_level = self.scopes.items[scope_id.idx].scope_level;
                        const loop_scope = try self.pushScope(.while_let_branch, scope_id, null, we.body.range, parent_level + 1);
                        for (ld.patterns) |*pat| {
                            try self.bindPatternLocals(item_id, loop_scope, pat, false, ld.range.end, true);
                        }
                        try self.walkBlock(item_id, loop_scope, we.body, false);
                    },
                }
            },
            .do_while_expr => |dw| {
                try self.walkBlock(item_id, scope_id, dw.body, true);
                try self.walkExpr(item_id, scope_id, dw.condition);
            },
            .for_in_expr => |fi| {
                try self.walkExpr(item_id, scope_id, fi.iterable);
                const parent_level = self.scopes.items[scope_id.idx].scope_level;
                const for_scope = try self.pushScope(.for_in_body, scope_id, null, fi.range, parent_level + 1);
                try self.bindPatternLocals(item_id, for_scope, fi.pattern, false, fi.iterable.range().end, true);
                if (fi.guard) |g| try self.walkExpr(item_id, for_scope, g);
                try self.walkBlock(item_id, for_scope, fi.body, false);
            },
            .try_expr => |te| {
                const parent_level = self.scopes.items[scope_id.idx].scope_level;
                if (te.resources.len > 0) {
                    const res_scope = try self.pushScope(.try_resources, scope_id, null, te.body.range, parent_level + 1);
                    for (te.resources) |r| {
                        var ann_ty: ?TypeId = null;
                        if (r.ty) |rt| ann_ty = try self.resolveTypeNode(item_id, rt);
                        if (r.init) |init_e| try self.walkExpr(item_id, res_scope, init_e);
                        _ = try self.addLocal(res_scope, global_item, .variable, r.name, .{ .item = item_id, .hir = r.id }, r.range.end, false, ann_ty, null, true);
                    }
                    try self.walkBlock(item_id, res_scope, te.body, false);
                } else {
                    try self.walkBlock(item_id, scope_id, te.body, true);
                }
                for (te.clauses) |cl| {
                    switch (cl) {
                        .catch_ => |cc| {
                            const c_scope = try self.pushScope(.catch_or_handle_clause, scope_id, null, cc.range, parent_level + 1);
                            try self.bindPatternLocals(item_id, c_scope, cc.pattern, false, cc.pattern.range().end, true);
                            try self.walkBlock(item_id, c_scope, cc.body, false);
                        },
                        .handle => |hc| {
                            const h_scope = try self.pushScope(.catch_or_handle_clause, scope_id, null, hc.range, parent_level + 1);
                            try self.bindPatternLocals(item_id, h_scope, hc.pattern, false, hc.pattern.range().end, true);
                            try self.walkBlock(item_id, h_scope, hc.body, false);
                        },
                    }
                }
                if (te.finally) |fin| try self.walkBlock(item_id, scope_id, fin, true);
            },
            .throw_expr => |th| try self.walkExpr(item_id, scope_id, th.value),
            .return_expr => |ret| if (ret.value) |v| try self.walkExpr(item_id, scope_id, v),
            .lambda => |lam| {
                const parent_level = self.scopes.items[scope_id.idx].scope_level;
                const lam_scope = try self.pushScope(.param_list, scope_id, null, lam.range, parent_level + 1);
                for (lam.params) |param| {
                    if (package_mod.unwrapHirParam(param)) |hp| {
                        var ann_ty: ?TypeId = null;
                        if (hp.ty) |pt| ann_ty = try self.resolveTypeNode(item_id, pt);
                        if (hp.name) |pn| {
                            _ = try self.addLocal(lam_scope, global_item, .param, pn, .{ .item = item_id, .hir = hp.id }, pn.range.end, false, ann_ty, null, true);
                        }
                    }
                }
                try self.walkBlock(item_id, lam_scope, lam.body, false);
            },
            .spawn => |sp| {
                if (sp.context) |ctx_e| try self.walkExpr(item_id, scope_id, ctx_e);
                try self.walkExpr(item_id, scope_id, sp.task);
            },
            .synchronized => |sy| {
                try self.walkExpr(item_id, scope_id, sy.mutex);
                try self.walkBlock(item_id, scope_id, sy.body, true);
            },
            .unsafe => |us| try self.walkBlock(item_id, scope_id, us.body, true),
            .quote => |q| {
                for (q.parts) |part| {
                    if (part == .interpolation) try self.walkExpr(item_id, scope_id, part.interpolation);
                }
            },
            .if_available => |ia| {
                for (ia.args) |arg| try self.walkExpr(item_id, scope_id, arg.value);
            },
            .perform => |pf| try self.walkExpr(item_id, scope_id, pf.value),
            .resume_expr => |re| {
                if (re.value) |v| try self.walkExpr(item_id, scope_id, v);
                if (re.modifier_value) |mv| try self.walkExpr(item_id, scope_id, mv);
            },
            else => {},
        }
    }

    /// 遍历语句块（`create_new_scope == false` 时与外层形参或模式条件共享同一作用域级别以检测同级重定义）。
    fn walkBlock(
        self: *FileResolver,
        item_id: common.ItemId,
        parent_scope: ScopeId,
        blk: *const common.BlockExpr,
        create_new_scope: bool,
    ) PlatformError!void {
        const global_item: ids.GlobalItemId = .{ .file = self.file, .item = item_id };
        const block_scope = if (create_new_scope) blk_s: {
            const parent_level = self.scopes.items[parent_scope.idx].scope_level;
            break :blk_s try self.pushScope(.local_block, parent_scope, null, blk.range, parent_level + 1);
        } else parent_scope;

        for (blk.stmts) |*stmt| {
            switch (stmt.*) {
                .binding => |b| {
                    var ann_ty: ?TypeId = null;
                    if (b.ty) |t| ann_ty = try self.resolveTypeNode(item_id, t);
                    if (b.init) |ie| try self.walkExpr(item_id, block_scope, ie);
                    // 绑定在初始化表达式结束后生效，避免 `let x = x + 1` 自绑定
                    try self.bindPatternLocals(item_id, block_scope, b.pattern, b.kind == .var_, b.range.end, false);
                    if (ann_ty) |aty| {
                        // 单名绑定回填显式类型注解
                        if (b.pattern.* == .binding and self.locals.items.len > 0) {
                            self.locals.items[self.locals.items.len - 1].annotated_ty = aty;
                        }
                    }
                },
                .expr => |es| try self.walkExpr(item_id, block_scope, es.value),
                .item => |*local_item| {
                    if (local_item.* == .func) {
                        const f = local_item.func;
                        const fn_name = switch (f.name) {
                            .ident, .operator => |n| n,
                        };
                        const sig_idx: u32 = @intCast(self.local_callables.items.len);
                        // 局部函数从定义位置之后可见，在自身函数体内支持单函数自递归，禁止局部互递归
                        const fn_sym = try self.addLocal(block_scope, global_item, .func_, fn_name, .{ .item = item_id, .hir = f.id }, f.range.start, false, null, sig_idx, false);
                        const tp_names = try package_mod.internNames(self.db, self.arena, f.type_params);
                        const tp_refs = try package_mod.makeTypeParamRefs(self.arena, .{ .local = fn_sym }, tp_names.len);
                        if (tp_names.len > 0) {
                            try self.tp_scopes.append(self.db.gpa, .{ .names = tp_names, .refs = tp_refs });
                        }
                        defer if (tp_names.len > 0) {
                            _ = self.tp_scopes.pop();
                        };

                        const env = self.currentTypeEnv();
                        const sig = try package_mod.buildFuncHeaderSig(&env, self.arena, .{ .local = fn_sym }, tp_refs, f, false, &self.diagnostics, self.file);
                        try self.local_callables.append(self.arena, sig.*);

                        try self.walkFuncBody(item_id, block_scope, f.params, f.ret_type, f.body);
                    }
                },
            }
        }
        if (blk.tail) |tail| {
            try self.walkExpr(item_id, block_scope, tail);
        }
    }

    /// 遍历函数/构造器/入口形参表与函数体（形参按从左向右顺序可见，支持 `func f(x: Int64, y!: Int64 = x)`）。
    fn walkFuncBody(
        self: *FileResolver,
        item_id: common.ItemId,
        parent_scope: ScopeId,
        params: []const common.Param,
        ret_type: ?*const common.HirType,
        body: ?*const common.BlockExpr,
    ) PlatformError!void {
        const global_item: ids.GlobalItemId = .{ .file = self.file, .item = item_id };
        if (ret_type) |rt| _ = try self.resolveTypeNode(item_id, rt);
        const body_range = if (body) |b| b.range else common.TextRange.zero;
        const parent_level = self.scopes.items[parent_scope.idx].scope_level;
        const param_scope = try self.pushScope(.param_list, parent_scope, null, body_range, parent_level + 1);

        for (params) |param| {
            if (package_mod.unwrapHirParam(param)) |hp| {
                var ann_ty: ?TypeId = null;
                if (hp.ty) |pt| ann_ty = try self.resolveTypeNode(item_id, pt);
                if (hp.default_value) |dv| try self.walkExpr(item_id, param_scope, dv);
                if (hp.name) |pn| {
                    _ = try self.addLocal(param_scope, global_item, .param, pn, .{ .item = item_id, .hir = hp.id }, pn.range.end, false, ann_ty, null, true);
                }
            }
        }
        if (body) |b| {
            try self.walkBlock(item_id, param_scope, b, false);
        }
    }

    /// 递归绑定模式中的局部变量。
    fn bindPatternLocals(
        self: *FileResolver,
        item_id: common.ItemId,
        scope_id: ScopeId,
        pat: *const common.HirPattern,
        is_mut: bool,
        visible_from: u32,
        is_block_head: bool,
    ) PlatformError!void {
        const global_item: ids.GlobalItemId = .{ .file = self.file, .item = item_id };
        switch (pat.*) {
            .binding => |bp| {
                _ = try self.addLocal(scope_id, global_item, .variable, bp.name, .{ .item = item_id, .hir = bp.id }, visible_from, is_mut, null, null, is_block_head);
            },
            .tuple => |tp| {
                for (tp.elements) |*el| {
                    try self.bindPatternLocals(item_id, scope_id, el, is_mut, visible_from, is_block_head);
                }
            },
            .enum_ => |ep| {
                for (ep.args) |*arg| {
                    try self.bindPatternLocals(item_id, scope_id, arg, is_mut, visible_from, is_block_head);
                }
            },
            .typed => |tp| {
                const ty = try self.resolveTypeNode(item_id, tp.ty);
                if (tp.name) |n| {
                    _ = try self.addLocal(scope_id, global_item, .variable, n, .{ .item = item_id, .hir = tp.id }, visible_from, is_mut, ty, null, is_block_head);
                }
            },
            .except_type, .command_type => |cp| {
                var first_ty: ?TypeId = null;
                for (cp.types) |*t| {
                    const rt = try self.resolveTypeNode(item_id, t);
                    if (first_ty == null) first_ty = rt;
                }
                if (cp.name) |n| {
                    _ = try self.addLocal(scope_id, global_item, .variable, n, .{ .item = item_id, .hir = cp.id }, visible_from, false, first_ty, null, is_block_head);
                }
            },
            .const_ => |cp| try self.walkExpr(item_id, scope_id, cp.value),
            .wildcard => {},
        }
    }
};

/// 文件级词法早绑定入口：在 `FileQueryState.sema_arena` 中构建不可变 `FileResolveData`，返回指针借用自 `sema_arena`。
pub fn resolveFile(db: *Database, file: common.FileId) PlatformError!*const FileResolveData {
    const fstate = db.file_states.get(file) orelse return error.InvalidFileId;
    const lowered = try db.lower(file);
    const pkg_id = try db.packageOfFile(file);
    const pkg_state = try db.packageState(pkg_id);
    const a = fstate.sema_arena.allocator();

    var resolver: FileResolver = .{
        .db = db,
        .arena = a,
        .file = file,
        .pkg_state = pkg_state,
        .lowered = lowered,
    };
    defer resolver.deinit();

    // 1. 收集文件级显式与通配符导入（含隐式 std.core.*）并记录导入段定位
    if (db.config.target.implicit_prelude) {
        if (db.types.known.std_core_pkg) |core_pkg| {
            if (core_pkg != pkg_id) try resolver.glob_import_pkgs.append(a, core_pkg);
        }
    }
    var flat_imps: std.ArrayListUnmanaged(package_mod.FlatImport) = .empty;
    for (lowered.hir_file.imports) |imp| {
        try package_mod.flattenImportItem(db, a, imp, null, null, &.{}, &flat_imps);
    }

    var exp_acc: std.AutoHashMapUnmanaged(InternedId, std.ArrayListUnmanaged(ExportEntry)) = .empty;
    for (flat_imps.items) |fi| {
        const full_segs = if (fi.kind == .glob)
            fi.prefix
        else blk: {
            const tmp = try a.alloc(InternedId, fi.prefix.len + 1);
            @memcpy(tmp[0..fi.prefix.len], fi.prefix);
            tmp[fi.prefix.len] = fi.target_name;
            break :blk tmp;
        };
        const as_pkg = package_mod.resolveImportPackage(db, fi.org, full_segs);
        const parent_pkg = if (fi.prefix.len > 0) package_mod.resolveImportPackage(db, fi.org, fi.prefix) else null;

        if (fi.kind == .glob) {
            if (as_pkg) |tp| {
                if (tp != pkg_id) try resolver.glob_import_pkgs.append(a, tp);
            }
            continue;
        }
        const bind_name = if (fi.kind == .alias) fi.alias_name else fi.target_name;
        var matched_member = false;
        if (parent_pkg) |tp| {
            if (tp != pkg_id) {
                if (db.packageState(tp)) |ts| {
                    const rel = db.pkg_interner.relation(pkg_id, tp);
                    const entries = ts.lookupTop(fi.target_name);
                    if (entries.len > 0) {
                        matched_member = true;
                        for (entries) |e| {
                            if (!access_mod.isVisibleInRelation(e.vis, rel)) continue;
                            const gop = try exp_acc.getOrPut(a, bind_name);
                            if (!gop.found_existing) gop.value_ptr.* = .empty;
                            try gop.value_ptr.append(a, .{
                                .def = e.def,
                                .exported_name = bind_name,
                                .vis = e.vis,
                                .is_reexport = fi.modifier != null and fi.modifier.? != .private,
                                .source_file = file,
                            });
                        }
                    }
                } else |_| {}
            }
        }
        if (!matched_member) {
            if (as_pkg) |ip| {
                if (ip != pkg_id) try resolver.explicit_pkg_imports.put(a, bind_name, ip);
            }
        }
    }
    {
        var it = exp_acc.iterator();
        while (it.next()) |kv| {
            try resolver.explicit_imports.put(a, kv.key_ptr.*, kv.value_ptr.items);
        }
    }

    // 2. 构建当前文件 VisibleExtendIndex（本包 + 导入包 + 已引入类型所属包）
    try buildVisibleExtendIndex(&resolver);

    // 3. 建立本文件所有包级 DefId 的当前版本 DefSourceInfo 与声明标识符定位
    try collectFileDefSourceInfos(&resolver);

    // 4. 创建文件根包顶层作用域并遍历全部顶层声明项
    const content = try db.fileContent(file);
    const root_scope = try resolver.pushScope(.package_top, null, null, .{ .start = 0, .end = @intCast(content.len) }, 0);

    for (lowered.hir_file.items, 0..) |*item, idx| {
        const item_id = common.ItemId.fromIndex(@intCast(idx));
        try resolveTopItem(&resolver, root_scope, item_id, package_mod.unwrapMacroItem(item));
    }

    // 展平各作用域直属局部符号索引并回填精确的 locals_start / locals_len 连续区间
    var flat_indices: std.ArrayListUnmanaged(u32) = .empty;
    for (resolver.scopes.items, 0..) |*sc, s_idx| {
        const list = resolver.scope_local_lists.items[s_idx].items;
        sc.locals_start = @intCast(flat_indices.items.len);
        sc.locals_len = @intCast(list.len);
        try flat_indices.appendSlice(a, list);
    }

    // 对早绑定段级定位表按区间起点升序排列
    std.mem.sort(ResolvedIdentOccurrence, resolver.occurrences.items, {}, ResolvedIdentOccurrence.lessThan);

    const out = try a.create(FileResolveData);
    out.* = .{
        .file = file,
        .version = lowered.hir_file.version,
        .pkg_id = pkg_id,
        .module_id = pkg_state.module_id,
        .scopes = try resolver.scopes.toOwnedSlice(a),
        .locals = try resolver.locals.toOwnedSlice(a),
        .scope_local_indices = try flat_indices.toOwnedSlice(a),
        .local_callables = try resolver.local_callables.toOwnedSlice(a),
        .def_source_infos = resolver.def_source_infos,
        .explicit_imports = resolver.explicit_imports,
        .explicit_pkg_imports = resolver.explicit_pkg_imports,
        .glob_import_pkgs = try resolver.glob_import_pkgs.toOwnedSlice(a),
        .visible_extends = resolver.visible_extends,
        .resolved_types = resolver.resolved_types,
        .early_bindings = resolver.early_bindings,
        .early_overloads = resolver.early_overloads,
        .early_occurrences = try resolver.occurrences.toOwnedSlice(a),
        .diagnostics = try resolver.diagnostics.toOwnedSlice(a),
    };
    return out;
}

/// 收集当前文件可见扩展并按目标类型分组写入 `VisibleExtendIndex`。
fn buildVisibleExtendIndex(r: *FileResolver) PlatformError!void {
    const a = r.arena;
    var candidate_pkgs: std.AutoHashMapUnmanaged(PackageId, void) = .empty;
    defer candidate_pkgs.deinit(r.db.gpa);

    try candidate_pkgs.put(r.db.gpa, r.pkg_state.pkg_id, {});
    for (r.glob_import_pkgs.items) |gp| try candidate_pkgs.put(r.db.gpa, gp, {});
    var pkg_it = r.explicit_pkg_imports.valueIterator();
    while (pkg_it.next()) |p| try candidate_pkgs.put(r.db.gpa, p.*, {});
    var exp_it = r.explicit_imports.valueIterator();
    while (exp_it.next()) |entries| {
        for (entries.*) |e| try candidate_pkgs.put(r.db.gpa, e.def.pkg, {});
    }

    var nom_acc: std.AutoHashMapUnmanaged(DefId, std.ArrayListUnmanaged(DefId)) = .empty;
    defer {
        var it = nom_acc.valueIterator();
        while (it.next()) |list| list.deinit(r.db.gpa);
        nom_acc.deinit(r.db.gpa);
    }
    var prim_acc: [@typeInfo(PrimKind).@"enum".field_names.len]std.ArrayListUnmanaged(DefId) = @splat(.empty);
    defer {
        for (&prim_acc) |*list| list.deinit(r.db.gpa);
    }

    var p_it = candidate_pkgs.keyIterator();
    while (p_it.next()) |p_ptr| {
        const ps = r.db.packageState(p_ptr.*) catch continue;
        const is_same = p_ptr.* == r.pkg_state.pkg_id;
        for (ps.extends) |ext| {
            if (!is_same and !ext.is_exported) continue;
            switch (ext.target_kind) {
                .nominal => |tdef| {
                    const gop = try nom_acc.getOrPut(r.db.gpa, tdef);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(r.db.gpa, ext.def);
                },
                .prim => |pk| {
                    try prim_acc[@backingInt(pk)].append(r.db.gpa, ext.def);
                },
            }
        }
    }

    var na_it = nom_acc.iterator();
    while (na_it.next()) |kv| {
        try r.visible_extends.by_nominal.put(a, kv.key_ptr.*, try a.dupe(DefId, kv.value_ptr.items));
    }
    for (prim_acc, 0..) |list, idx| {
        if (list.items.len > 0) {
            r.visible_extends.by_prim[idx] = try a.dupe(DefId, list.items);
        }
    }
}

/// 为当前文件内的每个包级 `DefId` 建立精确的当前版本 `DefSourceInfo` 并写入声明标识符定位。
fn collectFileDefSourceInfos(r: *FileResolver) PlatformError!void {
    const file_defs = r.pkg_state.file_defs.get(r.file) orelse return;
    for (file_defs) |def_id| {
        const entry = r.pkg_state.getDef(def_id.idx) orelse continue;
        const origin = entry.origin orelse continue;
        const info = extractDefSourceInfo(r.lowered, origin) orelse continue;
        try r.def_source_infos.put(r.arena, def_id, info);
        try r.recordOcc(info.name_range, .{ .def = def_id }, .decl, entry.owner);
    }
}

/// 通过稳定结构路径 `DefOrigin` 从当前版本 `LoweredFile` 提取 `DefSourceInfo`。
pub fn extractDefSourceInfo(lowered: *const frontend.LoweredFile, origin: pkg_state_mod.DefOrigin) ?DefSourceInfo {
    switch (origin) {
        .top_item => |ti| {
            if (ti.item.index() >= lowered.lowered_items.len) return null;
            const item = package_mod.unwrapMacroItem(lowered.lowered_items[ti.item.index()].item);
            return .{
                .hir_key = .{ .item = ti.item, .hir = item.id() },
                .name_range = itemNameRange(item),
                .decl_range = item.range(),
            };
        },
        .member => |mi| {
            if (mi.item.index() >= lowered.lowered_items.len) return null;
            const top = package_mod.unwrapMacroItem(lowered.lowered_items[mi.item.index()].item);
            const mem = package_mod.getContainerMember(top, mi.member_idx) orelse return null;
            return .{
                .hir_key = .{ .item = mi.item, .hir = mem.id() },
                .name_range = itemNameRange(mem),
                .decl_range = mem.range(),
            };
        },
        .enum_variant => |ev| {
            if (ev.item.index() >= lowered.lowered_items.len) return null;
            const top = package_mod.unwrapMacroItem(lowered.lowered_items[ev.item.index()].item);
            if (top.* != .enum_ or ev.variant_idx >= top.enum_.variants.len) return null;
            const ctor = package_mod.unwrapEnumCtor(&top.enum_.variants[ev.variant_idx]) orelse return null;
            return .{
                .hir_key = .{ .item = ev.item, .hir = ctor.id },
                .name_range = ctor.name.range,
                .decl_range = ctor.range,
            };
        },
        .primary_ctor_field => |pcf| {
            if (pcf.item.index() >= lowered.lowered_items.len) return null;
            const top = package_mod.unwrapMacroItem(lowered.lowered_items[pcf.item.index()].item);
            const mem = package_mod.getContainerMember(top, pcf.member_idx) orelse return null;
            if (mem.* != .primary_ctor or pcf.param_idx >= mem.primary_ctor.params.len) return null;
            const hp = package_mod.unwrapHirParam(mem.primary_ctor.params[pcf.param_idx]) orelse return null;
            return .{
                .hir_key = .{ .item = pcf.item, .hir = hp.id },
                .name_range = if (hp.name) |n| n.range else hp.range,
                .decl_range = hp.range,
            };
        },
        .foreign_member => |fm| {
            if (fm.item.index() >= lowered.lowered_items.len) return null;
            const top = package_mod.unwrapMacroItem(lowered.lowered_items[fm.item.index()].item);
            if (top.* != .foreign or fm.member_idx >= top.foreign.members.len) return null;
            const mem = &top.foreign.members[fm.member_idx];
            return .{
                .hir_key = .{ .item = fm.item, .hir = mem.id() },
                .name_range = itemNameRange(mem),
                .decl_range = mem.range(),
            };
        },
        .binding_var => |bv| {
            if (bv.item.index() >= lowered.lowered_items.len) return null;
            const top = package_mod.unwrapMacroItem(lowered.lowered_items[bv.item.index()].item);
            const b_item = if (bv.member_idx) |midx|
                package_mod.getContainerMember(top, midx) orelse return null
            else
                top;
            if (b_item.* != .binding) return null;
            var cursor: u32 = 0;
            const name_r = findPatternNameRangeAt(b_item.binding.pattern, bv.pat_ordinal, &cursor) orelse b_item.range();
            return .{
                .hir_key = .{ .item = bv.item, .hir = b_item.id() },
                .name_range = name_r,
                .decl_range = b_item.range(),
            };
        },
    }
}

/// 提取单个 `HirItem` 的名称区间。
fn itemNameRange(item: *const common.HirItem) common.TextRange {
    return switch (item.*) {
        .class => |c| c.name.range,
        .struct_ => |s| s.name.range,
        .enum_ => |e| e.name.range,
        .interface => |i| i.name.range,
        .type_alias => |ta| ta.name.range,
        .prop => |p| p.name.range,
        .func => |f| switch (f.name) {
            .ident, .operator => |n| n.range,
        },
        .primary_ctor => |pc| pc.name.range,
        .macro_ => |mc| mc.name.range,
        else => item.range(),
    };
}

/// 查找绑定模式中第 `target` 个绑定名称的源码区间。
fn findPatternNameRangeAt(pat: *const common.HirPattern, target: u32, cursor: *u32) ?common.TextRange {
    switch (pat.*) {
        .binding => |bp| {
            const c = cursor.*;
            cursor.* += 1;
            return if (c == target) bp.name.range else null;
        },
        .typed => |tp| {
            if (tp.name) |n| {
                const c = cursor.*;
                cursor.* += 1;
                return if (c == target) n.range else null;
            }
            return null;
        },
        .tuple => |tup| {
            for (tup.elements) |*el| {
                if (findPatternNameRangeAt(el, target, cursor)) |r| return r;
            }
            return null;
        },
        else => return null,
    }
}

/// 递归早绑定单个顶层声明项及其内部成员与函数体。
fn resolveTopItem(
    r: *FileResolver,
    root_scope: ScopeId,
    item_id: common.ItemId,
    item: *const common.HirItem,
) PlatformError!void {
    const def_opt = findDefForTopItem(r.pkg_state, r.file, item_id);

    switch (item.*) {
        .class => |c| {
            const def_id = def_opt orelse return;
            try resolveContainerItem(r, root_scope, item_id, def_id, c.range, null, c.supertypes, c.where_clause, c.members);
        },
        .struct_ => |s| {
            const def_id = def_opt orelse return;
            try resolveContainerItem(r, root_scope, item_id, def_id, s.range, null, s.interfaces, s.where_clause, s.members);
        },
        .enum_ => |e| {
            const def_id = def_opt orelse return;
            try resolveContainerItem(r, root_scope, item_id, def_id, e.range, null, e.interfaces, e.where_clause, e.members);
        },
        .interface => |i| {
            const def_id = def_opt orelse return;
            try resolveContainerItem(r, root_scope, item_id, def_id, i.range, null, i.interfaces, i.where_clause, i.members);
        },
        .extend_ => |ex| {
            const def_id = def_opt orelse return;
            try resolveContainerItem(r, root_scope, item_id, def_id, ex.range, ex.target, ex.interfaces, ex.where_clause, ex.members);
        },
        .type_alias => |ta| {
            const def_id = def_opt orelse return;
            const entry = r.pkg_state.getDef(def_id.idx) orelse return;
            const refs = try package_mod.makeTypeParamRefs(r.arena, .{ .def = def_id }, entry.type_param_names.len);
            if (entry.type_param_names.len > 0) {
                try r.tp_scopes.append(r.db.gpa, .{ .names = entry.type_param_names, .refs = refs });
            }
            defer if (entry.type_param_names.len > 0) {
                _ = r.tp_scopes.pop();
            };
            _ = try r.resolveTypeNode(item_id, ta.target);
        },
        .func => |f| {
            const def_id = def_opt orelse return;
            const entry = r.pkg_state.getDef(def_id.idx) orelse return;
            const refs = try package_mod.makeTypeParamRefs(r.arena, .{ .def = def_id }, entry.type_param_names.len);
            if (entry.type_param_names.len > 0) {
                try r.tp_scopes.append(r.db.gpa, .{ .names = entry.type_param_names, .refs = refs });
            }
            defer if (entry.type_param_names.len > 0) {
                _ = r.tp_scopes.pop();
            };
            if (f.where_clause) |wc| {
                for (wc.constraints) |c| {
                    _ = try r.resolveTypeNode(item_id, c.subject);
                    for (c.bounds) |*b| _ = try r.resolveTypeNode(item_id, b);
                }
            }
            try r.walkFuncBody(item_id, root_scope, f.params, f.ret_type, f.body);
        },
        .main => |m| {
            try r.walkFuncBody(item_id, root_scope, m.params, m.ret_type, m.body);
        },
        .binding => |b| {
            if (b.ty) |t| _ = try r.resolveTypeNode(item_id, t);
            if (b.init) |ie| try r.walkExpr(item_id, root_scope, ie);
        },
        else => {},
    }
}

/// 递归早绑定容器（`class`/`struct`/`enum`/`interface`/`extend`）及其全部成员。
fn resolveContainerItem(
    r: *FileResolver,
    root_scope: ScopeId,
    item_id: common.ItemId,
    def_id: DefId,
    range: common.TextRange,
    extend_target: ?*const common.HirType,
    supers: []const common.HirType,
    where_clause: ?*const common.WhereClause,
    members: []const common.HirItem,
) PlatformError!void {
    const entry = r.pkg_state.getDef(def_id.idx) orelse return;
    const refs = try package_mod.makeTypeParamRefs(r.arena, .{ .def = def_id }, entry.type_param_names.len);
    if (entry.type_param_names.len > 0) {
        try r.tp_scopes.append(r.db.gpa, .{ .names = entry.type_param_names, .refs = refs });
    }
    defer if (entry.type_param_names.len > 0) {
        _ = r.tp_scopes.pop();
    };

    try r.enclosing_defs.append(r.db.gpa, def_id);
    defer _ = r.enclosing_defs.pop();

    if (extend_target) |et| _ = try r.resolveTypeNode(item_id, et);

    const body_scope = try r.pushScope(.type_or_extend_body, root_scope, def_id, range, 1);

    for (supers) |*st_ty| _ = try r.resolveTypeNode(item_id, st_ty);
    if (where_clause) |wc| {
        for (wc.constraints) |c| {
            _ = try r.resolveTypeNode(item_id, c.subject);
            for (c.bounds) |*b| _ = try r.resolveTypeNode(item_id, b);
        }
    }

    for (members, 0..) |*mem, m_idx| {
        switch (mem.*) {
            .func => |f| {
                const m_def = findDefForMember(r.pkg_state, r.file, item_id, @intCast(m_idx));
                var pushed = false;
                if (m_def) |md| {
                    if (r.pkg_state.getDef(md.idx)) |me| {
                        if (me.type_param_names.len > 0) {
                            const m_refs = try package_mod.makeTypeParamRefs(r.arena, .{ .def = md }, me.type_param_names.len);
                            try r.tp_scopes.append(r.db.gpa, .{ .names = me.type_param_names, .refs = m_refs });
                            pushed = true;
                        }
                    }
                }
                defer if (pushed) {
                    _ = r.tp_scopes.pop();
                };
                try r.walkFuncBody(item_id, body_scope, f.params, f.ret_type, f.body);
            },
            .init => |in| try r.walkFuncBody(item_id, body_scope, in.params, null, in.body),
            .primary_ctor => |pc| try r.walkFuncBody(item_id, body_scope, pc.params, null, pc.body),
            .finalizer => |fin| try r.walkFuncBody(item_id, body_scope, fin.params, null, fin.body),
            .prop => |p| {
                const pty = try r.resolveTypeNode(item_id, p.ty);
                for (p.accessors) |acc| {
                    const global_item: ids.GlobalItemId = .{ .file = r.file, .item = item_id };
                    const acc_scope = try r.pushScope(.param_list, body_scope, null, acc.range, 2);
                    for (acc.params) |param| {
                        if (package_mod.unwrapHirParam(param)) |hp| {
                            if (hp.name) |pn| {
                                _ = try r.addLocal(acc_scope, global_item, .param, pn, .{ .item = item_id, .hir = hp.id }, pn.range.end, false, pty, null, true);
                            }
                        }
                    }
                    try r.walkBlock(item_id, acc_scope, acc.body, false);
                }
            },
            .binding => |b| {
                if (b.ty) |t| _ = try r.resolveTypeNode(item_id, t);
                if (b.init) |ie| try r.walkExpr(item_id, body_scope, ie);
            },
            else => {},
        }
    }
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
