// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 包级声明汇聚（`buildPackageState`）：声明登记、重导出不动点、循环依赖/别名/继承拦截、
//! 包级声明头构建与文档注释提取。

const std = @import("std");
const common = @import("common");
const frontend = @import("frontend");
const ids = @import("../ids.zig");
const file_state_mod = @import("../db/FileState.zig");
const pkg_state_mod = @import("../db/PackageState.zig");
const db_mod = @import("../db/Database.zig");
const type_interner_mod = @import("../interner/TypeInterner.zig");
const access_mod = @import("access.zig");
const subtype_mod = @import("../typeck/subtype.zig");
const literal_mod = @import("../typeck/literal.zig");

const CallableHeaderSig = pkg_state_mod.CallableHeaderSig;
const CallableParamSig = pkg_state_mod.CallableParamSig;
const Database = db_mod.Database;
const DefEntry = pkg_state_mod.DefEntry;
const DefFlags = pkg_state_mod.DefFlags;
const DefId = ids.DefId;
const DefOrigin = pkg_state_mod.DefOrigin;
const ExportEntry = pkg_state_mod.ExportEntry;
const ExtendEntry = pkg_state_mod.ExtendEntry;
const ExtendMemberIface = pkg_state_mod.ExtendMemberIface;
const ExtendTargetKind = pkg_state_mod.ExtendTargetKind;
const GenericBoundSig = pkg_state_mod.GenericBoundSig;
const InternedId = ids.InternedId;
const NominalHeader = pkg_state_mod.NominalHeader;
const PackageId = ids.PackageId;
const PackageState = pkg_state_mod.PackageState;
const PlatformError = file_state_mod.PlatformError;
const PrimKind = ids.PrimKind;
const SymbolKind = ids.SymbolKind;
const TypeAliasHeader = pkg_state_mod.TypeAliasHeader;
const TypeId = ids.TypeId;
const TypeInterner = type_interner_mod.TypeInterner;
const TypeListId = ids.TypeListId;
const TypeParamRef = ids.TypeParamRef;
const Visibility = ids.Visibility;

/// 类型消解环境（供 `package.zig` 与 `file.zig` 共用）。
pub const TypeResolveEnv = struct {
    db: *Database,
    pkg_state: *const PackageState,
    file: common.FileId,
    /// 当前文件显式导入符号（含具名与别名）。
    explicit_imports: *const std.AutoHashMapUnmanaged(InternedId, []const ExportEntry),
    /// 当前文件显式导入包前缀。
    explicit_pkg_imports: *const std.AutoHashMapUnmanaged(InternedId, PackageId),
    /// 当前文件通配符导入包列表（含隐式 `std.core`）。
    glob_import_pkgs: []const PackageId,
    /// 当前封闭名义类型或 `extend`（用于消解 `This`）。
    enclosing_this: ?DefId = null,
    /// 从内向外排列的可见泛型形参表（每层包含形参名与对应 `TypeParamRef`）。
    type_param_scopes: []const TypeParamScope = &.{},
    /// 包构建期间用于按需求值前向引用同包 `type_alias` 的回调上下文（包外或常规查询时为 `null`）。
    local_alias_ctx: ?*anyopaque = null,
    local_alias_eval: ?*const fn (ctx: *anyopaque, def: DefId) PlatformError!TypeId = null,
};

/// 单个源文件展平后的导入信息集合（仅在 `buildPackageState` 内部使用）。
const FileImportBundle = struct {
    explicit: std.AutoHashMapUnmanaged(InternedId, []const ExportEntry) = .empty,
    explicit_pkgs: std.AutoHashMapUnmanaged(InternedId, PackageId) = .empty,
    globs: std.ArrayListUnmanaged(PackageId) = .empty,
};

/// 包构建阶段按需求值同包 `type_alias` 的上下文。
const LocalAliasEvalCtx = struct {
    db: *Database,
    arena: std.mem.Allocator,
    state: *PackageState,
    file_imports: *std.AutoHashMapUnmanaged(common.FileId, FileImportBundle),
    extends_buf: *std.ArrayListUnmanaged(ExtendEntry),
    diags: *std.ArrayListUnmanaged(common.Diagnostic),
    reported_cycles: std.AutoHashMapUnmanaged(DefId, void) = .empty,
};

/// 按需求值本包内的 `type_alias` 声明（支持前向引用并接入 `db.type_alias_cache` 三色环路截断）。
fn evalLocalTypeAlias(raw_ctx: *anyopaque, def_id: DefId) PlatformError!TypeId {
    const ctx: *LocalAliasEvalCtx = @ptrCast(@alignCast(raw_ctx));
    if (ctx.state.type_alias_headers.get(def_id.idx)) |tah| return tah.target;
    if (ctx.db.type_alias_cache.get(def_id)) |st| {
        return switch (st) {
            .computed => |ty| ty,
            .computing => blk: {
                if (!ctx.reported_cycles.contains(def_id)) {
                    try ctx.reported_cycles.put(ctx.arena, def_id, {});
                    if (ctx.state.getDef(def_id.idx)) |entry| {
                        if (entry.origin) |origin| {
                            const fid = origin.fileId();
                            const lowered = try ctx.db.lower(fid);
                            const idx = origin.itemId().index();
                            const r = if (idx < lowered.lowered_items.len)
                                unwrapMacroItem(lowered.lowered_items[idx].item).range()
                            else
                                common.TextRange.zero;
                            try ctx.diags.append(ctx.arena, .{
                                .file = fid,
                                .range = r,
                                .severity = .err,
                                .source = .typeck,
                                .message = "检测到循环类型别名定义",
                            });
                        }
                    }
                }
                break :blk TypeInterner.err_ty;
            },
            .uncomputed => unreachable,
        };
    }
    const entry = ctx.state.getDef(def_id.idx) orelse return TypeInterner.err_ty;
    if (entry.kind != .type_alias) return TypeInterner.err_ty;
    const origin = entry.origin orelse return TypeInterner.err_ty;
    const fid = origin.fileId();
    const bundle = ctx.file_imports.getPtr(fid) orelse return TypeInterner.err_ty;
    const lowered = try ctx.db.lower(fid);

    try buildHeaderForDef(
        ctx.db,
        ctx.arena,
        ctx.state,
        entry.*,
        lowered,
        &bundle.explicit,
        &bundle.explicit_pkgs,
        bundle.globs.items,
        ctx.extends_buf,
        ctx.diags,
        ctx,
    );
    return if (ctx.state.type_alias_headers.get(def_id.idx)) |tah| tah.target else TypeInterner.err_ty;
}

/// 单层泛型形参查找表。
pub const TypeParamScope = struct {
    names: []const InternedId,
    refs: []const TypeParamRef,
};

/// 临时收集文件导入展开条目。
pub const FlatImport = struct {
    modifier: ?common.Modifier,
    org: ?InternedId,
    prefix: []const InternedId,
    kind: enum(u8) { single, alias, glob },
    target_name: InternedId = .invalid,
    alias_name: InternedId = .invalid,
    range: common.TextRange,
};

/// 递归展平单条 `ImportItem`（展开 `ImportKind.group` 并继承外层 `modifier` 与 `org`）。
/// 返回结果追加至调用者传入的 `out` 列表，内部 `prefix` 切片分配于 `arena`。
pub fn flattenImportItem(
    db: *Database,
    arena: std.mem.Allocator,
    imp: common.ImportItem,
    parent_mod: ?common.Modifier,
    parent_org: ?InternedId,
    parent_prefix: []const InternedId,
    out: *std.ArrayListUnmanaged(FlatImport),
) std.mem.Allocator.Error!void {
    const eff_mod = imp.modifier orelse parent_mod;
    const eff_org = if (imp.org) |o| try db.strings.intern(o.text) else parent_org;
    const combined = try arena.alloc(InternedId, parent_prefix.len + imp.prefix.len);
    @memcpy(combined[0..parent_prefix.len], parent_prefix);
    for (imp.prefix, 0..) |seg, i| {
        combined[parent_prefix.len + i] = try db.strings.intern(seg.text);
    }

    switch (imp.kind) {
        .single => |n| {
            try out.append(arena, .{
                .modifier = eff_mod,
                .org = eff_org,
                .prefix = combined,
                .kind = .single,
                .target_name = try db.strings.intern(n.text),
                .range = imp.range,
            });
        },
        .alias => |al| {
            try out.append(arena, .{
                .modifier = eff_mod,
                .org = eff_org,
                .prefix = combined,
                .kind = .alias,
                .target_name = try db.strings.intern(al.name.text),
                .alias_name = try db.strings.intern(al.alias.text),
                .range = imp.range,
            });
        },
        .glob => {
            try out.append(arena, .{
                .modifier = eff_mod,
                .org = eff_org,
                .prefix = combined,
                .kind = .glob,
                .range = imp.range,
            });
        },
        .group => |items| {
            for (items) |sub| {
                try flattenImportItem(db, arena, sub, eff_mod, eff_org, combined, out);
            }
        },
    }
}

/// 在绿树中按声明字节区间定位对应 `GreenNode` 并提取其前导文档注释驻留句柄。
pub fn extractDocAtRange(
    db: *Database,
    syntax_tree: common.SyntaxTree,
    decl_range: common.TextRange,
) std.mem.Allocator.Error!?InternedId {
    const node = findGreenNodeBySpan(syntax_tree.tree.root, 0, decl_range) orelse return null;
    const cleaned = (try file_state_mod.extractLeadingDocComment(db.gpa, node)) orelse return null;
    defer db.gpa.free(cleaned);
    return try db.strings.intern(cleaned);
}

/// 在绿树中查找精确覆盖目标声明区间的非叶子声明节点。
fn findGreenNodeBySpan(
    node: *const common.GreenNode,
    offset: u32,
    target: common.TextRange,
) ?*const common.GreenNode {
    const end = offset + node.text_len;
    if (target.start < offset or target.end > end) return null;
    if (node.isLeaf()) return null;

    var cur_offset = offset;
    for (node.children()) |child| {
        const child_end = cur_offset + child.text_len;
        if (!child.isLeaf() and target.start >= cur_offset and target.end <= child_end) {
            if (findGreenNodeBySpan(child, cur_offset, target)) |found| return found;
            // 命中带前导 trivia 的声明节点（绿树节点包含前导空白与文档注释，故起止区间略宽于 HIR 有效区间）
            if (isDeclSyntaxKind(child.kind)) return child;
        }
        cur_offset = child_end;
    }
    return if (isDeclSyntaxKind(node.kind)) node else null;
}

/// 判定 CST 标签是否属于可挂载前导 `doc_comment` 的声明节点。
fn isDeclSyntaxKind(kind: common.SyntaxKind) bool {
    return switch (kind) {
        .class_decl,
        .struct_decl,
        .enum_decl,
        .interface_decl,
        .extend_decl,
        .type_alias_decl,
        .func_decl,
        .main_decl,
        .var_decl,
        .prop_decl,
        .init_decl,
        .finalizer_decl,
        .primary_ctor_decl,
        .enum_constructor,
        .macro_decl,
        .foreign_decl,
        => true,
        else => false,
    };
}

/// 包级声明汇聚入口：使用 `db.gpa` 分配并构建 `*PackageState`（包含全部包级声明头、重导出不动点与扩展目录），
/// 返回指针所有权移交 `Database` 托管。
pub fn buildPackageState(db: *Database, pkg: PackageId) PlatformError!*PackageState {
    const pkg_info = db.pkg_interner.tryGetPackage(pkg) orelse return error.InvalidPackageId;
    const next_gen: u32 = (db.pkg_generations.get(pkg) orelse 0) + 1;
    try db.pkg_generations.put(db.gpa, pkg, next_gen);

    const state = try db.gpa.create(PackageState);
    errdefer db.gpa.destroy(state);
    state.* = .{
        .pkg_id = pkg,
        .module_id = pkg_info.module_id,
        .pkg_vis = .public,
        .generation = next_gen,
        .arena = .init(db.gpa),
    };
    errdefer state.deinit();

    const a = state.arena.allocator();

    // 1. 收集归属当前包的全部源文件
    var pkg_files: std.ArrayListUnmanaged(common.FileId) = .empty;
    var it = db.source.iterator();
    while (it.next()) |entry| {
        const f_pkg = try db.packageOfFile(entry.id);
        if (f_pkg == pkg) {
            try pkg_files.append(a, entry.id);
        }
    }
    state.files = try pkg_files.toOwnedSlice(a);

    var diags: std.ArrayListUnmanaged(common.Diagnostic) = .empty;
    var defs_buf: std.ArrayListUnmanaged(DefEntry) = .empty;
    var top_export_lists: std.AutoHashMapUnmanaged(InternedId, std.ArrayListUnmanaged(ExportEntry)) = .empty;
    var enum_ctor_lists: std.AutoHashMapUnmanaged(InternedId, std.ArrayListUnmanaged(DefId)) = .empty;
    var member_owner_lists: std.AutoHashMapUnmanaged(InternedId, std.ArrayListUnmanaged(DefId)) = .empty;

    // 2. 校验包声明头一致性并登记全部顶层与容器成员 DefId
    var header_vis_seen: ?Visibility = null;
    var header_macro_seen: ?bool = null;

    for (state.files) |fid| {
        const lowered = try db.lower(fid);
        const st = try db.parse(fid);
        const file_obj = db.source.get(fid) orelse return error.InvalidFileId;
        const is_header_file = file_obj.extra.typ == .Header;

        if (lowered.hir_file.package) |ph| {
            const mod_vis = if (ph.modifier) |m| Visibility.fromModifiers(&.{m}, .public) else .public;
            if (pkg_info.parent == null and mod_vis != .public) {
                try diags.append(a, .{
                    .file = fid,
                    .range = ph.range,
                    .severity = .err,
                    .source = .name_res,
                    .message = "根包声明不允许使用 internal 或 protected 修饰符",
                });
            }
            if (header_vis_seen) |prev_v| {
                if (prev_v != mod_vis) {
                    try diags.append(a, .{
                        .file = fid,
                        .range = ph.range,
                        .severity = .err,
                        .source = .name_res,
                        .message = "同一包不同源文件的 package 可见性修饰符不一致",
                    });
                }
            } else {
                header_vis_seen = mod_vis;
                state.pkg_vis = mod_vis;
            }
            if (header_macro_seen) |prev_m| {
                if (prev_m != ph.is_macro) {
                    try diags.append(a, .{
                        .file = fid,
                        .range = ph.range,
                        .severity = .err,
                        .source = .name_res,
                        .message = "同一包不同源文件的 macro package 声明不一致",
                    });
                }
            } else {
                header_macro_seen = ph.is_macro;
                state.is_macro_pkg = ph.is_macro;
            }
        }

        var file_def_list: std.ArrayListUnmanaged(DefId) = .empty;
        for (lowered.hir_file.items, 0..) |*item, item_idx| {
            try registerTopItem(
                db,
                a,
                state,
                fid,
                st,
                common.ItemId.fromIndex(@intCast(item_idx)),
                item,
                is_header_file,
                &defs_buf,
                &file_def_list,
                &top_export_lists,
                &enum_ctor_lists,
                &member_owner_lists,
            );
        }
        try state.file_defs.put(a, fid, try file_def_list.toOwnedSlice(a));
    }

    state.defs = defs_buf.items;

    // 先写入本包顶层声明映射（供后续导入解析与头部消解使用）
    {
        var exp_it = top_export_lists.iterator();
        while (exp_it.next()) |kv| {
            try state.top_exports.put(a, kv.key_ptr.*, kv.value_ptr.items);
        }
    }

    // 3. 收集依赖包与非私有重导出（单轮 + 环路检测）
    var deps_set: std.AutoHashMapUnmanaged(PackageId, void) = .empty;
    var deps_list: std.ArrayListUnmanaged(PackageId) = .empty;

    // 暂存每个文件展平后的导入表，供步骤 4 消解包级声明头使用
    var file_imports: std.AutoHashMapUnmanaged(common.FileId, FileImportBundle) = .empty;

    // 标记当前包正在构建中，阻断相互循环 import 并允许本包声明头查询当前状态
    try db.building_pkgs.put(db.gpa, pkg, {});
    defer _ = db.building_pkgs.remove(pkg);
    try db.building_pkg_states.put(db.gpa, pkg, state);
    defer _ = db.building_pkg_states.remove(pkg);

    for (state.files) |fid| {
        const lowered = try db.lower(fid);
        var bundle: FileImportBundle = .{};
        if (db.config.target.implicit_prelude) {
            if (db.types.known.std_core_pkg) |core_pkg| {
                if (core_pkg != pkg) try bundle.globs.append(a, core_pkg);
            }
        }

        var flat_imps: std.ArrayListUnmanaged(FlatImport) = .empty;
        for (lowered.hir_file.imports) |imp| {
            try flattenImportItem(db, a, imp, null, null, &.{}, &flat_imps);
        }

        var explicit_acc: std.AutoHashMapUnmanaged(InternedId, std.ArrayListUnmanaged(ExportEntry)) = .empty;

        for (flat_imps.items) |fi| {
            const imp_vis = if (fi.modifier) |m| Visibility.fromModifiers(&.{m}, .private) else .private;
            const is_reexport = imp_vis != .private;

            // 尝试解析导入目标为“包名”或“包.成员”
            const full_segs = if (fi.kind == .glob)
                fi.prefix
            else blk: {
                const tmp = try a.alloc(InternedId, fi.prefix.len + 1);
                @memcpy(tmp[0..fi.prefix.len], fi.prefix);
                tmp[fi.prefix.len] = fi.target_name;
                break :blk tmp;
            };

            const as_pkg_opt = resolveImportPackage(db, fi.org, full_segs);
            const parent_pkg_opt = if (fi.prefix.len > 0) resolveImportPackage(db, fi.org, fi.prefix) else null;

            if (fi.kind == .glob) {
                if (as_pkg_opt) |tgt_pkg| {
                    if (tgt_pkg == pkg) {
                        try diags.append(a, .{
                            .file = fid,
                            .range = fi.range,
                            .severity = .err,
                            .source = .name_res,
                            .message = "禁止使用 import 导入当前包自身",
                        });
                        continue;
                    }
                    if (!deps_set.contains(tgt_pkg)) {
                        try deps_set.put(a, tgt_pkg, {});
                        try deps_list.append(a, tgt_pkg);
                    }
                    if (db.building_pkgs.contains(tgt_pkg)) {
                        try diags.append(a, .{
                            .file = fid,
                            .range = fi.range,
                            .severity = .err,
                            .source = .name_res,
                            .message = "检测到包间循环 import 依赖",
                        });
                        continue;
                    }
                    const tgt_state = db.packageState(tgt_pkg) catch continue;
                    if (!access_mod.canImportPackage(&db.pkg_interner, pkg, tgt_pkg, tgt_state.pkg_vis)) {
                        try diags.append(a, .{
                            .file = fid,
                            .range = fi.range,
                            .severity = .err,
                            .source = .name_res,
                            .message = "目标包访问级别不足，无法导入",
                        });
                        continue;
                    }
                    try bundle.globs.append(a, tgt_pkg);

                    // 重导出通配符成员（仅导出可见性不低于导入修饰符且未被当前包声明遮蔽的符号）
                    if (is_reexport) {
                        const rel = db.pkg_interner.relation(pkg, tgt_pkg);
                        var te_it = tgt_state.top_exports.iterator();
                        while (te_it.next()) |kv| {
                            if (top_export_lists.contains(kv.key_ptr.*)) continue;
                            for (kv.value_ptr.*) |entry| {
                                if (!access_mod.isVisibleInRelation(entry.vis, rel)) continue;
                                if (!imp_vis.isNoMoreOpenThan(entry.vis)) continue;
                                const gop = try top_export_lists.getOrPut(a, kv.key_ptr.*);
                                if (!gop.found_existing) gop.value_ptr.* = .empty;
                                try gop.value_ptr.append(a, .{
                                    .def = entry.def,
                                    .exported_name = kv.key_ptr.*,
                                    .vis = imp_vis,
                                    .is_reexport = true,
                                    .source_file = fid,
                                });
                            }
                        }
                    }
                } else {
                    try diags.append(a, .{
                        .file = fid,
                        .range = fi.range,
                        .severity = .err,
                        .source = .name_res,
                        .message = "找不到要导入的包",
                    });
                }
                continue;
            }

            // 单导入或别名导入：优先匹配包成员，其次匹配子包本身
            const bind_name = if (fi.kind == .alias) fi.alias_name else fi.target_name;
            var resolved_member = false;
            var import_diag_emitted = false;
            if (parent_pkg_opt) |tgt_pkg| {
                if (tgt_pkg == pkg) {
                    try diags.append(a, .{
                        .file = fid,
                        .range = fi.range,
                        .severity = .err,
                        .source = .name_res,
                        .message = "禁止使用 import 导入当前包中的成员",
                    });
                    continue;
                }
                if (!deps_set.contains(tgt_pkg)) {
                    try deps_set.put(a, tgt_pkg, {});
                    try deps_list.append(a, tgt_pkg);
                }
                if (db.building_pkgs.contains(tgt_pkg)) {
                    try diags.append(a, .{
                        .file = fid,
                        .range = fi.range,
                        .severity = .err,
                        .source = .name_res,
                        .message = "检测到包间循环 import 依赖",
                    });
                    continue;
                }
                if (db.packageState(tgt_pkg)) |tgt_state| {
                    if (access_mod.canImportPackage(&db.pkg_interner, pkg, tgt_pkg, tgt_state.pkg_vis)) {
                        const rel = db.pkg_interner.relation(pkg, tgt_pkg);
                        const entries = tgt_state.lookupTop(fi.target_name);
                        if (entries.len > 0) {
                            var visible_count: usize = 0;
                            var reexport_ok_count: usize = 0;
                            for (entries) |entry| {
                                if (!access_mod.isVisibleInRelation(entry.vis, rel)) continue;
                                visible_count += 1;
                                const gop = try explicit_acc.getOrPut(a, bind_name);
                                if (!gop.found_existing) gop.value_ptr.* = .empty;
                                try gop.value_ptr.append(a, .{
                                    .def = entry.def,
                                    .exported_name = bind_name,
                                    .vis = imp_vis,
                                    .is_reexport = is_reexport,
                                    .source_file = fid,
                                });
                                if (is_reexport and imp_vis.isNoMoreOpenThan(entry.vis)) {
                                    reexport_ok_count += 1;
                                    const tgop = try top_export_lists.getOrPut(a, bind_name);
                                    if (!tgop.found_existing) tgop.value_ptr.* = .empty;
                                    try tgop.value_ptr.append(a, .{
                                        .def = entry.def,
                                        .exported_name = bind_name,
                                        .vis = imp_vis,
                                        .is_reexport = true,
                                        .source_file = fid,
                                    });
                                }
                            }
                            if (visible_count > 0) {
                                resolved_member = true;
                                if (is_reexport and reexport_ok_count == 0) {
                                    try diags.append(a, .{
                                        .file = fid,
                                        .range = fi.range,
                                        .severity = .err,
                                        .source = .name_res,
                                        .message = "重导出可见性高于被导入符号的可见性",
                                    });
                                }
                            } else if (as_pkg_opt == null) {
                                resolved_member = true;
                                try diags.append(a, .{
                                    .file = fid,
                                    .range = fi.range,
                                    .severity = .err,
                                    .source = .name_res,
                                    .message = "导入的符号在当前包不可访问",
                                });
                            }
                        }
                    } else if (as_pkg_opt == null) {
                        import_diag_emitted = true;
                        try diags.append(a, .{
                            .file = fid,
                            .range = fi.range,
                            .severity = .err,
                            .source = .name_res,
                            .message = "目标包访问级别不足，无法导入",
                        });
                    }
                } else |_| {}
            }

            if (!resolved_member) {
                if (as_pkg_opt) |imp_pkg| {
                    if (imp_pkg == pkg) {
                        try diags.append(a, .{
                            .file = fid,
                            .range = fi.range,
                            .severity = .err,
                            .source = .name_res,
                            .message = "禁止使用 import 导入当前包自身",
                        });
                        continue;
                    }
                    if (is_reexport) {
                        try diags.append(a, .{
                            .file = fid,
                            .range = fi.range,
                            .severity = .err,
                            .source = .name_res,
                            .message = "不允许使用 public、protected 或 internal 重导出包名本身",
                        });
                    }
                    if (!deps_set.contains(imp_pkg)) {
                        try deps_set.put(a, imp_pkg, {});
                        try deps_list.append(a, imp_pkg);
                    }
                    if (db.building_pkgs.contains(imp_pkg)) {
                        try diags.append(a, .{
                            .file = fid,
                            .range = fi.range,
                            .severity = .err,
                            .source = .name_res,
                            .message = "检测到包间循环 import 依赖",
                        });
                        continue;
                    }
                    if (db.packageState(imp_pkg)) |imp_state| {
                        if (!access_mod.canImportPackage(&db.pkg_interner, pkg, imp_pkg, imp_state.pkg_vis)) {
                            try diags.append(a, .{
                                .file = fid,
                                .range = fi.range,
                                .severity = .err,
                                .source = .name_res,
                                .message = "目标包访问级别不足，无法导入",
                            });
                            continue;
                        }
                    } else |_| {}
                    try bundle.explicit_pkgs.put(a, bind_name, imp_pkg);
                } else if (!import_diag_emitted) {
                    try diags.append(a, .{
                        .file = fid,
                        .range = fi.range,
                        .severity = .err,
                        .source = .name_res,
                        .message = "找不到要导入的包或符号",
                    });
                }
            }
        }

        var ex_it = explicit_acc.iterator();
        while (ex_it.next()) |kv| {
            try bundle.explicit.put(a, kv.key_ptr.*, kv.value_ptr.items);
        }
        try file_imports.put(a, fid, bundle);
    }

    // 写回合并重导出后的顶层符号表、枚举构造器表与成员反向索引
    {
        var exp_it = top_export_lists.iterator();
        while (exp_it.next()) |kv| {
            try state.top_exports.put(a, kv.key_ptr.*, kv.value_ptr.items);
        }
        var ec_it = enum_ctor_lists.iterator();
        while (ec_it.next()) |kv| {
            try state.enum_ctors.put(a, kv.key_ptr.*, kv.value_ptr.items);
        }
        var mo_it = member_owner_lists.iterator();
        while (mo_it.next()) |kv| {
            try state.member_to_owners.put(a, kv.key_ptr.*, kv.value_ptr.items);
        }
    }
    state.direct_deps = try deps_list.toOwnedSlice(a);

    // 4. 先按需求值本包全部 type_alias 头（支持任意前向引用并接入三色缓存拦截循环别名），再消解其余声明头
    var extends_buf: std.ArrayListUnmanaged(ExtendEntry) = .empty;
    var alias_ctx: LocalAliasEvalCtx = .{
        .db = db,
        .arena = a,
        .state = state,
        .file_imports = &file_imports,
        .extends_buf = &extends_buf,
        .diags = &diags,
    };
    for (state.defs) |entry| {
        if (entry.kind != .type_alias) continue;
        _ = try evalLocalTypeAlias(&alias_ctx, entry.id);
    }
    for (state.defs) |entry| {
        if (entry.kind == .type_alias) continue;
        const origin = entry.origin orelse continue;
        const fid = origin.fileId();
        const bundle = file_imports.getPtr(fid) orelse continue;
        const lowered = try db.lower(fid);

        try buildHeaderForDef(
            db,
            a,
            state,
            entry,
            lowered,
            &bundle.explicit,
            &bundle.explicit_pkgs,
            bundle.globs.items,
            &extends_buf,
            &diags,
            null,
        );
    }

    state.extends = try extends_buf.toOwnedSlice(a);

    // 5. 校验本包名义类型的继承合法性与循环继承
    try validateNominalInheritance(db, a, state, &diags);

    state.diagnostics = try diags.toOwnedSlice(a);

    // 将本包依赖登记到 Database 反向依赖图
    for (state.direct_deps) |dep_pkg| {
        try db.registerReversePkgDep(dep_pkg, pkg);
    }
    return state;
}

/// 尝试将导入路径解析为已知工作区包或预编译索引包 `PackageId`。
pub fn resolveImportPackage(
    db: *Database,
    org: ?InternedId,
    segments: []const InternedId,
) ?PackageId {
    if (segments.len == 0) return null;
    if (db.pkg_interner.lookupPackage(org, segments)) |existing| {
        if (db.packages.contains(existing)) return existing;
        if (db.config.preload_provider) |prov| {
            if (prov.vtable.hasPackage(prov.ptr, db, existing)) return existing;
        }
        // 检查是否存在工作区文件归属该包
        var it = db.source.iterator();
        while (it.next()) |item| {
            const fp = db.packageOfFile(item.id) catch continue;
            if (fp == existing) return existing;
        }
    }
    // 尝试向预编译索引查询未驻留路径
    if (db.config.preload_provider) |prov| {
        const cand = db.pkg_interner.internPackage(org, segments) catch return null;
        if (prov.vtable.hasPackage(prov.ptr, db, cand)) return cand;
    }
    return null;
}

/// 登记单个顶层声明项及其内部成员的 `DefEntry`。
fn registerTopItem(
    db: *Database,
    a: std.mem.Allocator,
    state: *PackageState,
    fid: common.FileId,
    st: common.SyntaxTree,
    item_id: common.ItemId,
    item: *const common.HirItem,
    is_header_file: bool,
    defs_buf: *std.ArrayListUnmanaged(DefEntry),
    file_def_list: *std.ArrayListUnmanaged(DefId),
    top_exports: *std.AutoHashMapUnmanaged(InternedId, std.ArrayListUnmanaged(ExportEntry)),
    enum_ctors: *std.AutoHashMapUnmanaged(InternedId, std.ArrayListUnmanaged(DefId)),
    member_owners: *std.AutoHashMapUnmanaged(InternedId, std.ArrayListUnmanaged(DefId)),
) PlatformError!void {
    switch (item.*) {
        .macro_expand => |me| {
            if (me.wrapped) |w| {
                try registerTopItem(db, a, state, fid, st, item_id, w, is_header_file, defs_buf, file_def_list, top_exports, enum_ctors, member_owners);
            }
        },
        .class => |c| {
            const vis = Visibility.fromModifiers(c.modifiers, .internal);
            const name_id = try db.strings.intern(c.name.text);
            const tps = try internNames(db, a, c.type_params);
            const doc = try extractDocAtRange(db, st, c.range);
            const def_id = try appendDef(a, state, defs_buf, file_def_list, .{
                .id = undefined,
                .kind = .class_,
                .name = name_id,
                .origin = .{ .top_item = .{ .file = fid, .item = item_id } },
                .source_file = fid,
                .declared_vis = vis,
                .effective_vis = vis,
                .doc = doc,
                .flags = DefFlags.fromModifiers(c.modifiers, true, false),
                .type_param_names = tps,
                .is_header_decl = is_header_file,
            });
            try addTopExport(a, top_exports, name_id, def_id, vis, fid);
            const members = try registerContainerMembers(db, a, state, fid, st, item_id, def_id, vis, false, c.members, is_header_file, defs_buf, file_def_list, member_owners);
            defs_buf.items[def_id.idx].members = members;
        },
        .struct_ => |s| {
            const vis = Visibility.fromModifiers(s.modifiers, .internal);
            const name_id = try db.strings.intern(s.name.text);
            const tps = try internNames(db, a, s.type_params);
            const doc = try extractDocAtRange(db, st, s.range);
            const def_id = try appendDef(a, state, defs_buf, file_def_list, .{
                .id = undefined,
                .kind = .struct_,
                .name = name_id,
                .origin = .{ .top_item = .{ .file = fid, .item = item_id } },
                .source_file = fid,
                .declared_vis = vis,
                .effective_vis = vis,
                .doc = doc,
                .flags = DefFlags.fromModifiers(s.modifiers, true, false),
                .type_param_names = tps,
                .is_header_decl = is_header_file,
            });
            try addTopExport(a, top_exports, name_id, def_id, vis, fid);
            const members = try registerContainerMembers(db, a, state, fid, st, item_id, def_id, vis, false, s.members, is_header_file, defs_buf, file_def_list, member_owners);
            defs_buf.items[def_id.idx].members = members;
        },
        .interface => |i| {
            const vis = Visibility.fromModifiers(i.modifiers, .internal);
            const name_id = try db.strings.intern(i.name.text);
            const tps = try internNames(db, a, i.type_params);
            const doc = try extractDocAtRange(db, st, i.range);
            const def_id = try appendDef(a, state, defs_buf, file_def_list, .{
                .id = undefined,
                .kind = .interface_,
                .name = name_id,
                .origin = .{ .top_item = .{ .file = fid, .item = item_id } },
                .source_file = fid,
                .declared_vis = vis,
                .effective_vis = vis,
                .doc = doc,
                .flags = DefFlags.fromModifiers(i.modifiers, true, false),
                .type_param_names = tps,
                .is_header_decl = is_header_file,
            });
            try addTopExport(a, top_exports, name_id, def_id, vis, fid);
            const members = try registerContainerMembers(db, a, state, fid, st, item_id, def_id, vis, true, i.members, is_header_file, defs_buf, file_def_list, member_owners);
            defs_buf.items[def_id.idx].members = members;
        },
        .enum_ => |e| {
            const vis = Visibility.fromModifiers(e.modifiers, .internal);
            const name_id = try db.strings.intern(e.name.text);
            const tps = try internNames(db, a, e.type_params);
            const doc = try extractDocAtRange(db, st, e.range);
            const def_id = try appendDef(a, state, defs_buf, file_def_list, .{
                .id = undefined,
                .kind = .enum_,
                .name = name_id,
                .origin = .{ .top_item = .{ .file = fid, .item = item_id } },
                .source_file = fid,
                .declared_vis = vis,
                .effective_vis = vis,
                .doc = doc,
                .flags = DefFlags.fromModifiers(e.modifiers, true, false),
                .type_param_names = tps,
                .is_header_decl = is_header_file,
            });
            try addTopExport(a, top_exports, name_id, def_id, vis, fid);
            var all_members: std.ArrayListUnmanaged(DefId) = .empty;
            for (e.variants, 0..) |*v, v_idx| {
                if (unwrapEnumCtor(v)) |ctor| {
                    const v_name = try db.strings.intern(ctor.name.text);
                    const v_doc = try extractDocAtRange(db, st, ctor.range);
                    const v_def = try appendDef(a, state, defs_buf, file_def_list, .{
                        .id = undefined,
                        .kind = .enum_variant,
                        .name = v_name,
                        .origin = .{ .enum_variant = .{ .file = fid, .item = item_id, .variant_idx = @intCast(v_idx) } },
                        .source_file = fid,
                        .declared_vis = .public,
                        .effective_vis = vis,
                        .owner = def_id,
                        .doc = v_doc,
                        .is_header_decl = is_header_file,
                    });
                    try all_members.append(a, v_def);
                    const cgop = try enum_ctors.getOrPut(a, v_name);
                    if (!cgop.found_existing) cgop.value_ptr.* = .empty;
                    try cgop.value_ptr.append(a, v_def);
                }
            }
            const extra_members = try registerContainerMembers(db, a, state, fid, st, item_id, def_id, vis, false, e.members, is_header_file, defs_buf, file_def_list, member_owners);
            try all_members.appendSlice(a, extra_members);
            defs_buf.items[def_id.idx].members = try all_members.toOwnedSlice(a);
        },
        .extend_ => |ex| {
            const tps = try internNames(db, a, ex.type_params);
            const doc = try extractDocAtRange(db, st, ex.range);
            const ext_name = try db.strings.intern("extend");
            const def_id = try appendDef(a, state, defs_buf, file_def_list, .{
                .id = undefined,
                .kind = .extend_,
                .name = ext_name,
                .origin = .{ .top_item = .{ .file = fid, .item = item_id } },
                .source_file = fid,
                .declared_vis = .public,
                .effective_vis = .public,
                .doc = doc,
                .type_param_names = tps,
                .is_header_decl = is_header_file,
            });
            const members = try registerContainerMembers(db, a, state, fid, st, item_id, def_id, .public, false, ex.members, is_header_file, defs_buf, file_def_list, member_owners);
            defs_buf.items[def_id.idx].members = members;
        },
        .type_alias => |ta| {
            const vis = Visibility.fromModifiers(ta.modifiers, .internal);
            const name_id = try db.strings.intern(ta.name.text);
            const tps = try internNames(db, a, ta.type_params);
            const doc = try extractDocAtRange(db, st, ta.range);
            const def_id = try appendDef(a, state, defs_buf, file_def_list, .{
                .id = undefined,
                .kind = .type_alias,
                .name = name_id,
                .origin = .{ .top_item = .{ .file = fid, .item = item_id } },
                .source_file = fid,
                .declared_vis = vis,
                .effective_vis = vis,
                .doc = doc,
                .type_param_names = tps,
                .is_header_decl = is_header_file,
            });
            try addTopExport(a, top_exports, name_id, def_id, vis, fid);
        },
        .func => |f| {
            const vis = Visibility.fromModifiers(f.modifiers, .internal);
            const fn_name_raw = switch (f.name) {
                .ident, .operator => |n| n.text,
            };
            const name_id = try db.strings.intern(fn_name_raw);
            const tps = try internNames(db, a, f.type_params);
            const doc = try extractDocAtRange(db, st, f.range);
            const def_id = try appendDef(a, state, defs_buf, file_def_list, .{
                .id = undefined,
                .kind = .func_,
                .name = name_id,
                .origin = .{ .top_item = .{ .file = fid, .item = item_id } },
                .source_file = fid,
                .declared_vis = vis,
                .effective_vis = vis,
                .doc = doc,
                .flags = DefFlags.fromModifiers(f.modifiers, f.body != null, f.is_variadic),
                .type_param_names = tps,
                .is_header_decl = is_header_file,
            });
            try addTopExport(a, top_exports, name_id, def_id, vis, fid);
        },
        .main => |m| {
            const name_id = try db.strings.intern("main");
            const doc = try extractDocAtRange(db, st, m.range);
            _ = try appendDef(a, state, defs_buf, file_def_list, .{
                .id = undefined,
                .kind = .func_,
                .name = name_id,
                .origin = .{ .top_item = .{ .file = fid, .item = item_id } },
                .source_file = fid,
                .declared_vis = .private,
                .effective_vis = .private,
                .doc = doc,
                .flags = DefFlags.fromModifiers(m.modifiers, true, m.is_variadic),
                .is_header_decl = is_header_file,
            });
        },
        .binding => |b| {
            const vis = Visibility.fromModifiers(b.modifiers, .internal);
            const doc = try extractDocAtRange(db, st, b.range);
            var ordinal: u32 = 0;
            try registerBindingPatternDefs(db, a, state, fid, item_id, null, null, vis, vis, b.kind, b.modifiers, doc, b.pattern, is_header_file, &ordinal, defs_buf, file_def_list, top_exports, null, null);
        },
        .foreign => |fg| {
            for (fg.members, 0..) |*mem, m_idx| {
                if (mem.* == .func) {
                    const f = mem.func;
                    const fn_name_raw = switch (f.name) {
                        .ident, .operator => |n| n.text,
                    };
                    const name_id = try db.strings.intern(fn_name_raw);
                    const doc = try extractDocAtRange(db, st, f.range);
                    var flags = DefFlags.fromModifiers(f.modifiers, false, f.is_variadic);
                    flags.is_foreign = true;
                    const def_id = try appendDef(a, state, defs_buf, file_def_list, .{
                        .id = undefined,
                        .kind = .func_,
                        .name = name_id,
                        .origin = .{ .foreign_member = .{ .file = fid, .item = item_id, .member_idx = @intCast(m_idx) } },
                        .source_file = fid,
                        .declared_vis = .internal,
                        .effective_vis = .internal,
                        .doc = doc,
                        .flags = flags,
                        .is_header_decl = true,
                    });
                    try addTopExport(a, top_exports, name_id, def_id, .internal, fid);
                }
            }
        },
        .macro_ => |mc| {
            const vis = Visibility.fromModifiers(mc.modifiers, .public);
            const name_id = try db.strings.intern(mc.name.text);
            const doc = try extractDocAtRange(db, st, mc.range);
            const def_id = try appendDef(a, state, defs_buf, file_def_list, .{
                .id = undefined,
                .kind = .macro_,
                .name = name_id,
                .origin = .{ .top_item = .{ .file = fid, .item = item_id } },
                .source_file = fid,
                .declared_vis = vis,
                .effective_vis = vis,
                .doc = doc,
                .flags = DefFlags.fromModifiers(mc.modifiers, true, mc.is_variadic),
                .is_header_decl = is_header_file,
            });
            try addTopExport(a, top_exports, name_id, def_id, vis, fid);
        },
        else => {},
    }
}

/// 登记容器（`class`/`struct`/`enum`/`interface`/`extend`）内部成员的 `DefEntry`。
fn registerContainerMembers(
    db: *Database,
    a: std.mem.Allocator,
    state: *PackageState,
    fid: common.FileId,
    st: common.SyntaxTree,
    item_id: common.ItemId,
    owner_def: DefId,
    owner_vis: Visibility,
    is_interface: bool,
    members: []const common.HirItem,
    is_header_file: bool,
    defs_buf: *std.ArrayListUnmanaged(DefEntry),
    file_def_list: *std.ArrayListUnmanaged(DefId),
    member_owners: *std.AutoHashMapUnmanaged(InternedId, std.ArrayListUnmanaged(DefId)),
) PlatformError![]const DefId {
    var out: std.ArrayListUnmanaged(DefId) = .empty;
    for (members, 0..) |*mem, m_idx| {
        const default_vis: Visibility = if (is_interface) .public else .internal;
        switch (mem.*) {
            .func => |f| {
                const vis = if (is_interface) .public else Visibility.fromModifiers(f.modifiers, default_vis);
                const eff = Visibility.min(vis, owner_vis);
                const fn_name_raw = switch (f.name) {
                    .ident, .operator => |n| n.text,
                };
                const name_id = try db.strings.intern(fn_name_raw);
                const tps = try internNames(db, a, f.type_params);
                const doc = try extractDocAtRange(db, st, f.range);
                const d = try appendDef(a, state, defs_buf, file_def_list, .{
                    .id = undefined,
                    .kind = .method,
                    .name = name_id,
                    .origin = .{ .member = .{ .file = fid, .item = item_id, .member_idx = @intCast(m_idx) } },
                    .source_file = fid,
                    .declared_vis = vis,
                    .effective_vis = eff,
                    .owner = owner_def,
                    .doc = doc,
                    .flags = DefFlags.fromModifiers(f.modifiers, f.body != null, f.is_variadic),
                    .type_param_names = tps,
                    .is_header_decl = is_header_file,
                });
                try out.append(a, d);
                try addMemberOwner(a, member_owners, name_id, owner_def);
            },
            .prop => |p| {
                const vis = if (is_interface) .public else Visibility.fromModifiers(p.modifiers, default_vis);
                const eff = Visibility.min(vis, owner_vis);
                const name_id = try db.strings.intern(p.name.text);
                const doc = try extractDocAtRange(db, st, p.range);
                const d = try appendDef(a, state, defs_buf, file_def_list, .{
                    .id = undefined,
                    .kind = .prop,
                    .name = name_id,
                    .origin = .{ .member = .{ .file = fid, .item = item_id, .member_idx = @intCast(m_idx) } },
                    .source_file = fid,
                    .declared_vis = vis,
                    .effective_vis = eff,
                    .owner = owner_def,
                    .doc = doc,
                    .flags = DefFlags.fromModifiers(p.modifiers, p.accessors.len > 0, false),
                    .is_header_decl = is_header_file,
                });
                try out.append(a, d);
                try addMemberOwner(a, member_owners, name_id, owner_def);
            },
            .init => |in| {
                const vis = Visibility.fromModifiers(in.modifiers, default_vis);
                const eff = Visibility.min(vis, owner_vis);
                const name_id = try db.strings.intern("init");
                const doc = try extractDocAtRange(db, st, in.range);
                const d = try appendDef(a, state, defs_buf, file_def_list, .{
                    .id = undefined,
                    .kind = .constructor,
                    .name = name_id,
                    .origin = .{ .member = .{ .file = fid, .item = item_id, .member_idx = @intCast(m_idx) } },
                    .source_file = fid,
                    .declared_vis = vis,
                    .effective_vis = eff,
                    .owner = owner_def,
                    .doc = doc,
                    .flags = DefFlags.fromModifiers(in.modifiers, true, in.is_variadic),
                    .is_header_decl = is_header_file,
                });
                try out.append(a, d);
            },
            .primary_ctor => |pc| {
                const vis = Visibility.fromModifiers(pc.modifiers, default_vis);
                const eff = Visibility.min(vis, owner_vis);
                const name_id = try db.strings.intern(pc.name.text);
                const doc = try extractDocAtRange(db, st, pc.range);
                const d = try appendDef(a, state, defs_buf, file_def_list, .{
                    .id = undefined,
                    .kind = .primary_ctor,
                    .name = name_id,
                    .origin = .{ .member = .{ .file = fid, .item = item_id, .member_idx = @intCast(m_idx) } },
                    .source_file = fid,
                    .declared_vis = vis,
                    .effective_vis = eff,
                    .owner = owner_def,
                    .doc = doc,
                    .flags = DefFlags.fromModifiers(pc.modifiers, true, pc.is_variadic),
                    .is_header_decl = is_header_file,
                });
                try out.append(a, d);

                // 主构造器带 let/var 绑定的参数自动注册为所属容器的成员字段
                for (pc.params, 0..) |param, p_idx| {
                    if (unwrapHirParam(param)) |hp| {
                        if (hp.binding) |bk| {
                            if (hp.name) |pn| {
                                const f_vis = Visibility.fromModifiers(hp.modifiers, .internal);
                                const f_eff = Visibility.min(f_vis, owner_vis);
                                const f_name = try db.strings.intern(pn.text);
                                var f_flags = DefFlags.fromModifiers(hp.modifiers, false, false);
                                if (bk == .var_) f_flags.is_mut = true;
                                if (bk == .const_) f_flags.is_const = true;
                                const f_def = try appendDef(a, state, defs_buf, file_def_list, .{
                                    .id = undefined,
                                    .kind = .field,
                                    .name = f_name,
                                    .origin = .{ .primary_ctor_field = .{
                                        .file = fid,
                                        .item = item_id,
                                        .member_idx = @intCast(m_idx),
                                        .param_idx = @intCast(p_idx),
                                    } },
                                    .source_file = fid,
                                    .declared_vis = f_vis,
                                    .effective_vis = f_eff,
                                    .owner = owner_def,
                                    .flags = f_flags,
                                    .is_header_decl = is_header_file,
                                });
                                try out.append(a, f_def);
                                try addMemberOwner(a, member_owners, f_name, owner_def);
                            }
                        }
                    }
                }
            },
            .finalizer => |fin| {
                const name_id = try db.strings.intern("~init");
                const doc = try extractDocAtRange(db, st, fin.range);
                const d = try appendDef(a, state, defs_buf, file_def_list, .{
                    .id = undefined,
                    .kind = .finalizer,
                    .name = name_id,
                    .origin = .{ .member = .{ .file = fid, .item = item_id, .member_idx = @intCast(m_idx) } },
                    .source_file = fid,
                    .declared_vis = .private,
                    .effective_vis = .private,
                    .owner = owner_def,
                    .doc = doc,
                    .flags = DefFlags.fromModifiers(fin.modifiers, true, false),
                    .is_header_decl = is_header_file,
                });
                try out.append(a, d);
            },
            .binding => |b| {
                const vis = Visibility.fromModifiers(b.modifiers, default_vis);
                const eff = Visibility.min(vis, owner_vis);
                const doc = try extractDocAtRange(db, st, b.range);
                var ordinal: u32 = 0;
                try registerBindingPatternDefs(db, a, state, fid, item_id, @intCast(m_idx), owner_def, vis, eff, b.kind, b.modifiers, doc, b.pattern, is_header_file, &ordinal, defs_buf, file_def_list, null, &out, member_owners);
            },
            else => {},
        }
    }
    return try out.toOwnedSlice(a);
}

/// 递归登记绑定模式中引入的变量声明（支持单名绑定、元组解构与带类型模式）。
fn registerBindingPatternDefs(
    db: *Database,
    a: std.mem.Allocator,
    state: *PackageState,
    fid: common.FileId,
    item_id: common.ItemId,
    member_idx: ?u32,
    owner_def: ?DefId,
    declared_vis: Visibility,
    effective_vis: Visibility,
    kind: common.BindingKind,
    modifiers: []const common.Modifier,
    doc: ?InternedId,
    pat: *const common.HirPattern,
    is_header_file: bool,
    ordinal: *u32,
    defs_buf: *std.ArrayListUnmanaged(DefEntry),
    file_def_list: *std.ArrayListUnmanaged(DefId),
    top_exports: ?*std.AutoHashMapUnmanaged(InternedId, std.ArrayListUnmanaged(ExportEntry)),
    member_out: ?*std.ArrayListUnmanaged(DefId),
    member_owners: ?*std.AutoHashMapUnmanaged(InternedId, std.ArrayListUnmanaged(DefId)),
) PlatformError!void {
    switch (pat.*) {
        .binding => |bp| {
            const ord = ordinal.*;
            ordinal.* += 1;
            const name_id = try db.strings.intern(bp.name.text);
            var flags = DefFlags.fromModifiers(modifiers, false, false);
            if (kind == .var_) flags.is_mut = true;
            if (kind == .const_) flags.is_const = true;
            const sym_kind: SymbolKind = if (owner_def != null)
                .field
            else if (kind == .const_)
                .constant
            else
                .variable;
            const def_id = try appendDef(a, state, defs_buf, file_def_list, .{
                .id = undefined,
                .kind = sym_kind,
                .name = name_id,
                .origin = .{ .binding_var = .{
                    .file = fid,
                    .item = item_id,
                    .member_idx = member_idx,
                    .pat_ordinal = ord,
                } },
                .source_file = fid,
                .declared_vis = declared_vis,
                .effective_vis = effective_vis,
                .owner = owner_def,
                .doc = doc,
                .flags = flags,
                .is_header_decl = is_header_file,
            });
            if (top_exports) |te| try addTopExport(a, te, name_id, def_id, declared_vis, fid);
            if (member_out) |mo| try mo.append(a, def_id);
            if (member_owners) |m_map| {
                if (owner_def) |od| try addMemberOwner(a, m_map, name_id, od);
            }
        },
        .tuple => |tp| {
            for (tp.elements) |*el| {
                try registerBindingPatternDefs(db, a, state, fid, item_id, member_idx, owner_def, declared_vis, effective_vis, kind, modifiers, doc, el, is_header_file, ordinal, defs_buf, file_def_list, top_exports, member_out, member_owners);
            }
        },
        .typed => |tpat| {
            if (tpat.name) |n| {
                const ord = ordinal.*;
                ordinal.* += 1;
                const name_id = try db.strings.intern(n.text);
                var flags = DefFlags.fromModifiers(modifiers, false, false);
                if (kind == .var_) flags.is_mut = true;
                if (kind == .const_) flags.is_const = true;
                const def_id = try appendDef(a, state, defs_buf, file_def_list, .{
                    .id = undefined,
                    .kind = if (owner_def != null) .field else .variable,
                    .name = name_id,
                    .origin = .{ .binding_var = .{
                        .file = fid,
                        .item = item_id,
                        .member_idx = member_idx,
                        .pat_ordinal = ord,
                    } },
                    .source_file = fid,
                    .declared_vis = declared_vis,
                    .effective_vis = effective_vis,
                    .owner = owner_def,
                    .doc = doc,
                    .flags = flags,
                    .is_header_decl = is_header_file,
                });
                if (top_exports) |te| try addTopExport(a, te, name_id, def_id, declared_vis, fid);
                if (member_out) |mo| try mo.append(a, def_id);
                if (member_owners) |m_map| {
                    if (owner_def) |od| try addMemberOwner(a, m_map, name_id, od);
                }
            }
        },
        else => {},
    }
}

/// 为单个 `DefEntry` 消解其声明头（`NominalHeader`、`TypeAliasHeader`、`CallableHeaderSig`、`prop_types`、`explicit_var_types`、`ExtendEntry`）。
fn buildHeaderForDef(
    db: *Database,
    a: std.mem.Allocator,
    state: *PackageState,
    entry: DefEntry,
    lowered: *const frontend.LoweredFile,
    explicit_imports: *const std.AutoHashMapUnmanaged(InternedId, []const ExportEntry),
    explicit_pkg_imports: *const std.AutoHashMapUnmanaged(InternedId, PackageId),
    glob_import_pkgs: []const PackageId,
    extends_buf: *std.ArrayListUnmanaged(ExtendEntry),
    diags: *std.ArrayListUnmanaged(common.Diagnostic),
    alias_ctx: ?*LocalAliasEvalCtx,
) PlatformError!void {
    const origin = entry.origin orelse return;
    const fid = origin.fileId();

    // 构造最多两层泛型形参查找作用域（声明自身 + 封闭宿主容器）
    var scope_buf: [2]TypeParamScope = undefined;
    var scope_len: usize = 0;

    const self_refs = try makeTypeParamRefs(a, .{ .def = entry.id }, entry.type_param_names.len);
    if (entry.type_param_names.len > 0) {
        scope_buf[scope_len] = .{ .names = entry.type_param_names, .refs = self_refs };
        scope_len += 1;
    }

    var owner_refs: []const TypeParamRef = &.{};
    if (entry.owner) |owner_def| {
        if (state.getDef(owner_def.idx)) |owner_entry| {
            owner_refs = try makeTypeParamRefs(a, .{ .def = owner_def }, owner_entry.type_param_names.len);
            if (owner_entry.type_param_names.len > 0) {
                scope_buf[scope_len] = .{ .names = owner_entry.type_param_names, .refs = owner_refs };
                scope_len += 1;
            }
        }
    }

    const enclosing_this: ?DefId = switch (entry.kind) {
        .class_, .struct_, .enum_, .interface_, .extend_ => entry.id,
        else => entry.owner,
    };

    const env: TypeResolveEnv = .{
        .db = db,
        .pkg_state = state,
        .file = fid,
        .explicit_imports = explicit_imports,
        .explicit_pkg_imports = explicit_pkg_imports,
        .glob_import_pkgs = glob_import_pkgs,
        .enclosing_this = enclosing_this,
        .type_param_scopes = scope_buf[0..scope_len],
        .local_alias_ctx = if (alias_ctx) |ac| @ptrCast(ac) else null,
        .local_alias_eval = if (alias_ctx != null) evalLocalTypeAlias else null,
    };

    switch (origin) {
        .top_item => |ti| {
            const top = unwrapMacroItem(lowered.lowered_items[ti.item.index()].item);
            switch (top.*) {
                .class => |c| {
                    var supers: std.ArrayListUnmanaged(TypeId) = .empty;
                    for (c.supertypes) |*st_ty| {
                        try supers.append(a, try resolveHirTypeInEnv(&env, st_ty));
                    }
                    // 未显式指定父类时默认继承 Object（Object 自身除外）
                    if (db.types.known.object_class) |obj_def| {
                        if (!DefId.eql(entry.id, obj_def)) {
                            const has_class_super = if (supers.items.len > 0) blk: {
                                if (db.types.get(supers.items[0]) == .nominal) {
                                    const d = db.getDef(db.types.get(supers.items[0]).nominal.def) catch break :blk false;
                                    break :blk d.kind == .class_;
                                }
                                break :blk false;
                            } else false;
                            if (!has_class_super) {
                                const obj_ty = try db.types.internObject();
                                try supers.insert(a, 0, obj_ty);
                            }
                        }
                    }
                    const nh = try a.create(NominalHeader);
                    nh.* = .{
                        .def = entry.id,
                        .type_params = self_refs,
                        .supertypes = try supers.toOwnedSlice(a),
                        .where_bounds = try resolveWhereBounds(&env, a, c.where_clause),
                        .doc = entry.doc,
                    };
                    try state.nominal_headers.put(a, entry.id.idx, nh);
                },
                .struct_ => |s| {
                    var supers = try a.alloc(TypeId, s.interfaces.len);
                    for (s.interfaces, 0..) |*it_ty, i| supers[i] = try resolveHirTypeInEnv(&env, it_ty);
                    const nh = try a.create(NominalHeader);
                    nh.* = .{
                        .def = entry.id,
                        .type_params = self_refs,
                        .supertypes = supers,
                        .where_bounds = try resolveWhereBounds(&env, a, s.where_clause),
                        .doc = entry.doc,
                    };
                    try state.nominal_headers.put(a, entry.id.idx, nh);
                },
                .enum_ => |e| {
                    var supers = try a.alloc(TypeId, e.interfaces.len);
                    for (e.interfaces, 0..) |*it_ty, i| supers[i] = try resolveHirTypeInEnv(&env, it_ty);
                    const nh = try a.create(NominalHeader);
                    nh.* = .{
                        .def = entry.id,
                        .type_params = self_refs,
                        .supertypes = supers,
                        .where_bounds = try resolveWhereBounds(&env, a, e.where_clause),
                        .doc = entry.doc,
                    };
                    try state.nominal_headers.put(a, entry.id.idx, nh);
                },
                .interface => |i| {
                    var supers = try a.alloc(TypeId, i.interfaces.len);
                    for (i.interfaces, 0..) |*it_ty, idx| supers[idx] = try resolveHirTypeInEnv(&env, it_ty);
                    const nh = try a.create(NominalHeader);
                    nh.* = .{
                        .def = entry.id,
                        .type_params = self_refs,
                        .supertypes = supers,
                        .where_bounds = try resolveWhereBounds(&env, a, i.where_clause),
                        .doc = entry.doc,
                    };
                    try state.nominal_headers.put(a, entry.id.idx, nh);
                },
                .type_alias => |ta| {
                    try db.type_alias_cache.put(db.gpa, entry.id, .computing);
                    errdefer _ = db.type_alias_cache.fetchRemove(entry.id);
                    const target_ty = try resolveHirTypeInEnv(&env, ta.target);
                    try db.type_alias_cache.put(db.gpa, entry.id, .{ .computed = target_ty });
                    const tah = try a.create(TypeAliasHeader);
                    tah.* = .{
                        .def = entry.id,
                        .type_params = self_refs,
                        .target = target_ty,
                        .doc = entry.doc,
                    };
                    try state.type_alias_headers.put(a, entry.id.idx, tah);
                },
                .func => |f| {
                    const sig = try buildFuncHeaderSig(&env, a, .{ .def = entry.id }, self_refs, f, entry.is_header_decl, diags, fid);
                    try state.callable_headers.put(a, entry.id.idx, sig);
                },
                .main => |m| {
                    const params = try resolveCallableParams(&env, a, m.params, diags, fid);
                    const ret = if (m.ret_type) |rt| try resolveHirTypeInEnv(&env, rt) else null;
                    const sig = try a.create(CallableHeaderSig);
                    sig.* = .{
                        .owner = .{ .def = entry.id },
                        .type_params = &.{},
                        .where_bounds = &.{},
                        .params = params,
                        .is_variadic = m.is_variadic,
                        .explicit_ret = ret,
                    };
                    try state.callable_headers.put(a, entry.id.idx, sig);
                },
                .extend_ => |ex| {
                    const target_ty = try resolveHirTypeInEnv(&env, ex.target);
                    const target_kind: ?ExtendTargetKind = switch (db.types.get(target_ty)) {
                        .nominal => |n| blk: {
                            const te = db.getDef(n.def) catch break :blk null;
                            break :blk if (te.kind == .interface_) null else .{ .nominal = n.def };
                        },
                        .prim => |p| .{ .prim = p },
                        else => null,
                    };
                    if (target_kind) |tk| {
                        var ifaces = try a.alloc(TypeId, ex.interfaces.len);
                        for (ex.interfaces, 0..) |*it_ty, idx| ifaces[idx] = try resolveHirTypeInEnv(&env, it_ty);
                        const wbs = try resolveWhereBounds(&env, a, ex.where_clause);

                        // 计算扩展导出可见性（SetExtendExternalAttr）
                        const is_direct = ifaces.len == 0;
                        var is_exported = false;
                        var export_vis: Visibility = .public;
                        var ct_buf: std.ArrayListUnmanaged(DefId) = .empty;
                        for (wbs) |wb| {
                            for (wb.upper_bounds) |ub| {
                                if (db.types.get(ub) == .nominal) {
                                    const d = db.types.get(ub).nominal.def;
                                    try ct_buf.append(a, d);
                                    if (db.getDef(d)) |de| {
                                        export_vis = Visibility.min(export_vis, de.effective_vis);
                                    } else |_| {}
                                }
                            }
                        }
                        switch (tk) {
                            .nominal => |tdef| {
                                const same_pkg = tdef.pkg == state.pkg_id;
                                if (db.getDef(tdef)) |t_entry| {
                                    export_vis = Visibility.min(export_vis, t_entry.effective_vis);
                                } else |_| {}
                                if (is_direct) {
                                    is_exported = same_pkg or (db.types.known.std_core_pkg == state.pkg_id);
                                } else {
                                    is_exported = true;
                                    // 孤儿规则检查
                                    if (!same_pkg) {
                                        var any_local_iface = false;
                                        for (ifaces) |it_ty| {
                                            if (db.types.get(it_ty) == .nominal and db.types.get(it_ty).nominal.def.pkg == state.pkg_id) {
                                                any_local_iface = true;
                                                break;
                                            }
                                        }
                                        if (!any_local_iface) {
                                            try diags.append(a, .{
                                                .file = fid,
                                                .range = ex.range,
                                                .severity = .err,
                                                .source = .name_res,
                                                .message = "违反孤儿规则：无法在外部包中为外部类型实现外部接口",
                                            });
                                        }
                                    }
                                }
                            },
                            .prim => {
                                is_exported = (!is_direct) or (db.types.known.std_core_pkg == state.pkg_id);
                            },
                        }

                        // 记录成员与实现接口的对应关系
                        var mem_ifaces: std.ArrayListUnmanaged(ExtendMemberIface) = .empty;
                        for (entry.members) |m_def| {
                            const m_entry = state.getDef(m_def.idx) orelse continue;
                            var matched_iface: ?DefId = null;
                            for (ifaces) |iface_ty| {
                                if (db.types.get(iface_ty) == .nominal) {
                                    const iface_def = db.types.get(iface_ty).nominal.def;
                                    if (db.getDef(iface_def)) |ie| {
                                        for (ie.members) |im_def| {
                                            if (db.getDef(im_def)) |ime| {
                                                if (ime.name == m_entry.name) {
                                                    matched_iface = iface_def;
                                                    break;
                                                }
                                            } else |_| {}
                                        }
                                    } else |_| {}
                                    if (matched_iface != null) break;
                                }
                            }
                            try mem_ifaces.append(a, .{ .member = m_def, .implemented_iface = matched_iface });
                        }

                        try extends_buf.append(a, .{
                            .def = entry.id,
                            .target_kind = tk,
                            .target_ty = target_ty,
                            .type_params = self_refs,
                            .where_bounds = wbs,
                            .implemented_interfaces = ifaces,
                            .member_ifaces = try mem_ifaces.toOwnedSlice(a),
                            .export_vis = export_vis,
                            .is_direct = is_direct,
                            .is_exported = is_exported,
                            .constraint_types = try ct_buf.toOwnedSlice(a),
                            .doc = entry.doc,
                        });
                    } else if (target_ty != TypeInterner.err_ty) {
                        try diags.append(a, .{
                            .file = fid,
                            .range = ex.target.range(),
                            .severity = .err,
                            .source = .typeck,
                            .message = "该类型不支持 extend 扩展声明",
                        });
                    }
                },
                else => {},
            }
        },
        .member => |mi| {
            const top = unwrapMacroItem(lowered.lowered_items[mi.item.index()].item);
            const mem = getContainerMember(top, mi.member_idx) orelse return;
            switch (mem.*) {
                .func => |f| {
                    const sig = try buildFuncHeaderSig(&env, a, .{ .def = entry.id }, self_refs, f, entry.is_header_decl, diags, fid);
                    try state.callable_headers.put(a, entry.id.idx, sig);
                },
                .prop => |p| {
                    const pty = try resolveHirTypeInEnv(&env, p.ty);
                    try state.prop_types.put(a, entry.id.idx, pty);
                },
                .init => |in| {
                    const params = try resolveCallableParams(&env, a, in.params, diags, fid);
                    const ret_ty = if (entry.flags.is_static)
                        TypeInterner.unit_ty
                    else
                        try makeOwnerSelfType(db, entry.owner.?, owner_refs);
                    const sig = try a.create(CallableHeaderSig);
                    sig.* = .{
                        .owner = .{ .def = entry.id },
                        .type_params = owner_refs,
                        .where_bounds = &.{},
                        .params = params,
                        .is_variadic = in.is_variadic,
                        .explicit_ret = ret_ty,
                        .is_ctor = !entry.flags.is_static,
                    };
                    try state.callable_headers.put(a, entry.id.idx, sig);
                },
                .primary_ctor => |pc| {
                    const params = try resolveCallableParams(&env, a, pc.params, diags, fid);
                    const ret_ty = try makeOwnerSelfType(db, entry.owner.?, owner_refs);
                    const sig = try a.create(CallableHeaderSig);
                    sig.* = .{
                        .owner = .{ .def = entry.id },
                        .type_params = owner_refs,
                        .where_bounds = &.{},
                        .params = params,
                        .is_variadic = pc.is_variadic,
                        .explicit_ret = ret_ty,
                        .is_ctor = true,
                    };
                    try state.callable_headers.put(a, entry.id.idx, sig);
                },
                .finalizer => {
                    const sig = try a.create(CallableHeaderSig);
                    sig.* = .{
                        .owner = .{ .def = entry.id },
                        .type_params = &.{},
                        .where_bounds = &.{},
                        .params = &.{},
                        .is_variadic = false,
                        .explicit_ret = TypeInterner.unit_ty,
                    };
                    try state.callable_headers.put(a, entry.id.idx, sig);
                },
                else => {},
            }
        },
        .enum_variant => |ev| {
            const top = unwrapMacroItem(lowered.lowered_items[ev.item.index()].item);
            if (top.* == .enum_ and ev.variant_idx < top.enum_.variants.len) {
                if (unwrapEnumCtor(&top.enum_.variants[ev.variant_idx])) |ctor| {
                    const owner_ty = try makeOwnerSelfType(db, entry.owner.?, owner_refs);
                    if (ctor.payload.len == 0) {
                        try state.explicit_var_types.put(a, entry.id.idx, owner_ty);
                    } else {
                        var params = try a.alloc(CallableParamSig, ctor.payload.len);
                        for (ctor.payload, 0..) |pl, i| {
                            const pty = switch (pl) {
                                .ty => |pt| try resolveHirTypeInEnv(&env, pt.ty),
                                .macro_call => TypeInterner.err_ty,
                            };
                            params[i] = .{ .name = null, .ty = pty, .is_named = false, .has_default = false };
                        }
                        const sig = try a.create(CallableHeaderSig);
                        sig.* = .{
                            .owner = .{ .def = entry.id },
                            .type_params = owner_refs,
                            .where_bounds = &.{},
                            .params = params,
                            .is_variadic = false,
                            .explicit_ret = owner_ty,
                            .is_enum_ctor = true,
                        };
                        try state.callable_headers.put(a, entry.id.idx, sig);
                    }
                }
            }
        },
        .primary_ctor_field => |pcf| {
            const top = unwrapMacroItem(lowered.lowered_items[pcf.item.index()].item);
            if (getContainerMember(top, pcf.member_idx)) |mem| {
                if (mem.* == .primary_ctor and pcf.param_idx < mem.primary_ctor.params.len) {
                    if (unwrapHirParam(mem.primary_ctor.params[pcf.param_idx])) |hp| {
                        if (hp.ty) |ht| {
                            try state.explicit_var_types.put(a, entry.id.idx, try resolveHirTypeInEnv(&env, ht));
                        }
                    }
                }
            }
        },
        .foreign_member => |fm| {
            const top = unwrapMacroItem(lowered.lowered_items[fm.item.index()].item);
            if (top.* == .foreign and fm.member_idx < top.foreign.members.len) {
                const mem = &top.foreign.members[fm.member_idx];
                if (mem.* == .func) {
                    const sig = try buildFuncHeaderSig(&env, a, .{ .def = entry.id }, self_refs, mem.func, true, diags, fid);
                    try state.callable_headers.put(a, entry.id.idx, sig);
                }
            }
        },
        .binding_var => |bv| {
            const top = unwrapMacroItem(lowered.lowered_items[bv.item.index()].item);
            const binding_opt: ?common.Binding = if (bv.member_idx) |midx| blk: {
                const mem = getContainerMember(top, midx) orelse break :blk null;
                break :blk if (mem.* == .binding) mem.binding else null;
            } else if (top.* == .binding) top.binding else null;

            if (binding_opt) |b| {
                if (b.ty) |ht| {
                    const ann = try resolveHirTypeInEnv(&env, ht);
                    const extracted = extractPatternTypeAt(db, b.pattern, ann, bv.pat_ordinal);
                    if (extracted) |et| try state.explicit_var_types.put(a, entry.id.idx, et);
                }
            }
        },
    }
}

/// 校验本包名义类型的直接父类型种类合法性与循环继承关系。
fn validateNominalInheritance(
    db: *Database,
    a: std.mem.Allocator,
    state: *const PackageState,
    diags: *std.ArrayListUnmanaged(common.Diagnostic),
) PlatformError!void {
    for (state.defs) |entry| {
        if (entry.kind != .class_ and entry.kind != .struct_ and entry.kind != .enum_ and entry.kind != .interface_) continue;
        const nh = state.nominal_headers.get(entry.id.idx) orelse continue;
        const origin = entry.origin orelse continue;
        const fid = origin.fileId();
        const lowered = try db.lower(fid);
        const item_idx = origin.itemId().index();
        const decl_range = if (item_idx < lowered.lowered_items.len)
            unwrapMacroItem(lowered.lowered_items[item_idx].item).range()
        else
            common.TextRange.zero;

        var class_super_count: usize = 0;
        for (nh.supertypes) |st_ty| {
            if (st_ty == TypeInterner.err_ty) continue;
            const st_data = db.types.get(st_ty);
            if (st_data != .nominal) {
                try diags.append(a, .{
                    .file = fid,
                    .range = decl_range,
                    .severity = .err,
                    .source = .typeck,
                    .message = "父类型列表中只允许出现类或接口类型",
                });
                continue;
            }
            const super_entry = db.getDef(st_data.nominal.def) catch continue;
            switch (entry.kind) {
                .class_ => {
                    if (super_entry.kind == .class_) {
                        class_super_count += 1;
                        if (class_super_count > 1) {
                            try diags.append(a, .{
                                .file = fid,
                                .range = decl_range,
                                .severity = .err,
                                .source = .typeck,
                                .message = "类声明最多只能继承一个直接父类",
                            });
                        }
                        const is_object = db.types.known.object_class != null and DefId.eql(super_entry.id, db.types.known.object_class.?);
                        if (!is_object) {
                            if (!super_entry.flags.is_open and !super_entry.flags.is_abstract) {
                                try diags.append(a, .{
                                    .file = fid,
                                    .range = decl_range,
                                    .severity = .err,
                                    .source = .typeck,
                                    .message = "不能继承未声明 open 或 abstract 的类",
                                });
                            } else if (super_entry.flags.is_sealed and super_entry.id.pkg != state.pkg_id) {
                                try diags.append(a, .{
                                    .file = fid,
                                    .range = decl_range,
                                    .severity = .err,
                                    .source = .typeck,
                                    .message = "不能在包外继承 sealed 类",
                                });
                            }
                        }
                    } else if (super_entry.kind != .interface_) {
                        try diags.append(a, .{
                            .file = fid,
                            .range = decl_range,
                            .severity = .err,
                            .source = .typeck,
                            .message = "类声明只能继承类或实现接口",
                        });
                    }
                },
                .struct_, .enum_, .interface_ => {
                    if (super_entry.kind != .interface_) {
                        try diags.append(a, .{
                            .file = fid,
                            .range = decl_range,
                            .severity = .err,
                            .source = .typeck,
                            .message = "结构体、枚举与接口只能继承或实现接口类型",
                        });
                    }
                },
                else => {},
            }
        }

        // 检测继承链环路（沿 NominalHeader.supertypes 遍历判断是否回到 entry.id）
        var visited: std.AutoHashMapUnmanaged(DefId, void) = .empty;
        defer visited.deinit(db.gpa);
        var worklist: std.ArrayListUnmanaged(DefId) = .empty;
        defer worklist.deinit(db.gpa);

        for (nh.supertypes) |st_ty| {
            if (db.types.get(st_ty) == .nominal) {
                try worklist.append(db.gpa, db.types.get(st_ty).nominal.def);
            }
        }
        var has_cycle = false;
        while (worklist.items.len > 0) {
            const cur = worklist.pop().?;
            if (DefId.eql(cur, entry.id)) {
                has_cycle = true;
                break;
            }
            if (visited.contains(cur)) continue;
            try visited.put(db.gpa, cur, {});
            const cur_nh = if (cur.pkg == state.pkg_id)
                state.nominal_headers.get(cur.idx)
            else
                db.nominalHeaderOf(cur) catch null;
            if (cur_nh) |cnh| {
                for (cnh.supertypes) |st_ty| {
                    if (db.types.get(st_ty) == .nominal) {
                        try worklist.append(db.gpa, db.types.get(st_ty).nominal.def);
                    }
                }
            }
        }
        if (has_cycle) {
            try diags.append(a, .{
                .file = fid,
                .range = decl_range,
                .severity = .err,
                .source = .typeck,
                .message = "检测到循环继承关系",
            });
        }
    }
}

/// 单层显式类型消解结果（区分成功、静默传递错误与各类具体诊断错误）。
pub const TypeResolveResult = union(enum) {
    ok: TypeId,
    /// 子节点已出错或循环别名已产生诊断，不再重复报错。
    err_silent,
    this_outside_type,
    invalid_varray_size,
    invalid_cpointer_args,
    invalid_cfunc_args,
    unexpected_type_args,
    wrong_type_arg_count,
    not_a_type,
    inaccessible_type,
    unknown_type,

    /// 返回当前消解结果对应的规范化 `TypeId`（非 `.ok` 时返回 `TypeInterner.err_ty`）。
    pub inline fn typeId(self: TypeResolveResult) TypeId {
        return switch (self) {
            .ok => |t| t,
            else => TypeInterner.err_ty,
        };
    }

    /// 返回对应的中文诊断提示；成功或静默传递错误返回 `null`。
    pub fn diagnosticMessage(self: TypeResolveResult) ?[]const u8 {
        return switch (self) {
            .ok, .err_silent => null,
            .this_outside_type => "This 类型只能出现在类型或 extend 声明内部",
            .invalid_varray_size => "VArray 长度必须为合法非负整数",
            .invalid_cpointer_args => "CPointer 必须恰好包含 1 个类型实参",
            .invalid_cfunc_args => "CFunc 必须恰好包含 1 个函数类型实参",
            .unexpected_type_args => "非泛型类型不允许提供类型实参",
            .wrong_type_arg_count => "泛型类型实参个数与声明不匹配",
            .not_a_type => "该标识符不是类型声明",
            .inaccessible_type => "目标类型在当前作用域不可访问",
            .unknown_type => "未找到指定的类型名称",
        };
    }
};

/// 构造 `FuncItem` 的头部签名 `CallableHeaderSig`（含无函数体返回类型强校验）。
pub fn buildFuncHeaderSig(
    env: *const TypeResolveEnv,
    a: std.mem.Allocator,
    owner: ids.CallableRef,
    type_params: []const TypeParamRef,
    f: common.FuncItem,
    is_header_decl: bool,
    diags: *std.ArrayListUnmanaged(common.Diagnostic),
    fid: common.FileId,
) PlatformError!*const CallableHeaderSig {
    const params = try resolveCallableParams(env, a, f.params, diags, fid);
    const wbs = try resolveWhereBounds(env, a, f.where_clause);
    var explicit_ret: ?TypeId = null;
    if (f.ret_type) |rt| {
        explicit_ret = try resolveHirTypeInEnv(env, rt);
    } else if (f.body == null) {
        if (!is_header_decl) {
            try diags.append(a, .{
                .file = fid,
                .range = f.range,
                .severity = .err,
                .source = .name_res,
                .message = "无函数体声明必须显式标注返回类型",
            });
        }
        explicit_ret = TypeInterner.err_ty;
    }

    const sig = try a.create(CallableHeaderSig);
    sig.* = .{
        .owner = owner,
        .type_params = type_params,
        .where_bounds = wbs,
        .params = params,
        .is_variadic = f.is_variadic,
        .explicit_ret = explicit_ret,
    };
    return sig;
}

/// 消解形参列表为 `CallableParamSig` 切片（形参省略显式类型标注时发射诊断）。
pub fn resolveCallableParams(
    env: *const TypeResolveEnv,
    a: std.mem.Allocator,
    params: []const common.Param,
    diags: ?*std.ArrayListUnmanaged(common.Diagnostic),
    fid: common.FileId,
) PlatformError![]const CallableParamSig {
    var out: std.ArrayListUnmanaged(CallableParamSig) = .empty;
    for (params) |param| {
        if (unwrapHirParam(param)) |hp| {
            const name_id = if (hp.name) |n| try env.db.strings.intern(n.text) else null;
            const pty = if (hp.ty) |t|
                try resolveHirTypeInEnv(env, t)
            else blk: {
                if (diags) |d_list| {
                    try d_list.append(a, .{
                        .file = fid,
                        .range = hp.range,
                        .severity = .err,
                        .source = .typeck,
                        .message = "函数或构造器形参缺少显式类型标注",
                    });
                }
                break :blk TypeInterner.err_ty;
            };
            try out.append(a, .{
                .name = name_id,
                .ty = pty,
                .is_named = hp.is_named,
                .has_default = hp.default_value != null,
            });
        }
    }
    return try out.toOwnedSlice(a);
}

/// 消解可选 `WhereClause` 为 `GenericBoundSig` 切片。
pub fn resolveWhereBounds(
    env: *const TypeResolveEnv,
    a: std.mem.Allocator,
    wc: ?*const common.WhereClause,
) PlatformError![]const GenericBoundSig {
    const w = wc orelse return &.{};
    var out = try a.alloc(GenericBoundSig, w.constraints.len);
    for (w.constraints, 0..) |c, i| {
        const subj = try resolveHirTypeInEnv(env, c.subject);
        const bounds = try a.alloc(TypeId, c.bounds.len);
        for (c.bounds, 0..) |*b, j| {
            bounds[j] = try resolveHirTypeInEnv(env, b);
        }
        out[i] = .{ .subject = subj, .upper_bounds = bounds };
    }
    return out;
}

/// 在给定 `TypeResolveEnv` 下消解任意显式 `HirType` 节点为规范化 `TypeId`。
pub fn resolveHirTypeInEnv(env: *const TypeResolveEnv, ht: *const common.HirType) PlatformError!TypeId {
    return switch (ht.*) {
        .this => if (env.enclosing_this) |owner_def|
            try env.db.types.intern(.{ .class_this = owner_def })
        else
            TypeInterner.err_ty,
        .option => |opt| blk: {
            const inner = try resolveHirTypeInEnv(env, opt.inner);
            break :blk if (inner == TypeInterner.err_ty) TypeInterner.err_ty else try env.db.types.internOption(inner);
        },
        .tuple => |tup| blk: {
            const elems = try env.db.gpa.alloc(TypeId, tup.elements.len);
            defer env.db.gpa.free(elems);
            for (tup.elements, 0..) |el, i| {
                elems[i] = try resolveHirTypeInEnv(env, el.ty);
            }
            const list = try env.db.types.internList(elems);
            break :blk try env.db.types.intern(.{ .tuple = list });
        },
        .func => |f| blk: {
            const params = try env.db.gpa.alloc(TypeId, f.params.len);
            defer env.db.gpa.free(params);
            for (f.params, 0..) |p, i| {
                params[i] = try resolveHirTypeInEnv(env, p.ty);
            }
            const ret = try resolveHirTypeInEnv(env, f.ret);
            const list = try env.db.types.internList(params);
            break :blk try env.db.types.intern(.{ .func = .{ .params = list, .ret = ret, .is_cfunc = false } });
        },
        .varray => |va| blk: {
            const elem = try resolveHirTypeInEnv(env, va.elem);
            const mag = literal_mod.parseIntegerMagnitude(va.size) orelse break :blk TypeInterner.err_ty;
            if (mag > @as(u128, @intCast(std.math.maxInt(i64)))) break :blk TypeInterner.err_ty;
            break :blk try env.db.types.intern(.{ .varray = .{ .elem = elem, .len = @intCast(mag) } });
        },
        .path => |p| blk: {
            if (p.segments.len == 0) break :blk TypeInterner.err_ty;
            const last_seg = p.segments[p.segments.len - 1];
            const args = try env.db.gpa.alloc(TypeId, last_seg.type_args.len);
            defer env.db.gpa.free(args);
            for (last_seg.type_args, 0..) |*ta, i| {
                args[i] = try resolveHirTypeInEnv(env, ta);
            }
            break :blk (try resolvePathTypeSingleLayer(env, p, args)).typeId();
        },
    };
}

/// 单层路径类型消解（调用方先消解末段类型实参 `resolved_args`），返回带精确失败原因的 `TypeResolveResult`。
pub fn resolvePathTypeSingleLayer(
    env: *const TypeResolveEnv,
    p: common.PathType,
    resolved_args: []const TypeId,
) PlatformError!TypeResolveResult {
    if (p.segments.len == 0) return .err_silent;
    const first = p.segments[0];

    // 1. 单段内建关键字与特殊互操作泛型
    if (p.segments.len == 1 and !first.name.is_raw) {
        if (PrimKind.fromKeyword(first.name.text)) |pk| {
            if (resolved_args.len > 0) return .unexpected_type_args;
            return .{ .ok = TypeInterner.prim(pk) };
        }
        if (std.mem.eql(u8, first.name.text, "CPointer")) {
            if (resolved_args.len != 1) return .invalid_cpointer_args;
            if (resolved_args[0] == TypeInterner.err_ty) return .err_silent;
            return .{ .ok = try env.db.types.intern(.{ .cpointer = resolved_args[0] }) };
        }
        if (std.mem.eql(u8, first.name.text, "CFunc")) {
            if (resolved_args.len != 1) return .invalid_cfunc_args;
            if (resolved_args[0] == TypeInterner.err_ty) return .err_silent;
            if (env.db.types.get(resolved_args[0]) != .func) return .invalid_cfunc_args;
            const fd = env.db.types.get(resolved_args[0]).func;
            return .{ .ok = try env.db.types.intern(.{ .func = .{ .params = fd.params, .ret = fd.ret, .is_cfunc = true } }) };
        }
        if (std.mem.eql(u8, first.name.text, "This")) {
            if (resolved_args.len > 0) return .unexpected_type_args;
            return if (env.enclosing_this) |owner_def|
                .{ .ok = try env.db.types.intern(.{ .class_this = owner_def }) }
            else
                .this_outside_type;
        }
    }

    const first_id = try env.db.strings.intern(first.name.text);

    // 2. 单段：优先查找泛型形参
    if (p.segments.len == 1) {
        for (env.type_param_scopes) |tps| {
            for (tps.names, 0..) |nm, idx| {
                if (nm == first_id) {
                    if (resolved_args.len > 0) return .unexpected_type_args;
                    return .{ .ok = try env.db.types.intern(.{ .type_param = tps.refs[idx] }) };
                }
            }
        }
    }

    // 3. 解析目标类型 DefId（区分未找到、不可访问与非类型符号）
    var target_def: ?DefId = null;
    var found_inaccessible = false;
    var found_non_type = false;

    if (p.segments.len == 1) {
        const lookup = try lookupTypeDefDetailedInEnv(env, first_id);
        target_def = lookup.def;
        found_inaccessible = lookup.inaccessible;
        found_non_type = lookup.non_type;
    } else if (p.segments.len == 2) {
        const last_seg = p.segments[1];
        if (env.explicit_pkg_imports.get(first_id)) |tgt_pkg| {
            if (env.db.packageState(tgt_pkg)) |ps| {
                const rel = env.db.pkg_interner.relation(env.pkg_state.pkg_id, tgt_pkg);
                const type_name = try env.db.strings.intern(last_seg.name.text);
                for (ps.lookupTop(type_name)) |exp| {
                    if (!access_mod.isVisibleInRelation(exp.vis, rel)) {
                        if (isTypeDefKind(env.db, exp.def)) found_inaccessible = true;
                        continue;
                    }
                    if (isTypeDefKind(env.db, exp.def)) {
                        target_def = exp.def;
                        break;
                    }
                    found_non_type = true;
                }
            } else |_| {}
        }
    }

    const def = target_def orelse {
        if (found_inaccessible) return .inaccessible_type;
        if (found_non_type) return .not_a_type;
        return .unknown_type;
    };

    const def_entry = env.db.getDef(def) catch return .err_silent;
    const expected_tparams = def_entry.type_param_names.len;
    if (resolved_args.len != expected_tparams) {
        return if (expected_tparams == 0) .unexpected_type_args else .wrong_type_arg_count;
    }

    // 若目标是 type_alias，则按需展开目标类型并替换泛型形参（支持同包前向引用并截断循环别名）
    if (def_entry.kind == .type_alias) {
        const alias_target = if (def.pkg == env.pkg_state.pkg_id and env.local_alias_eval != null and env.local_alias_ctx != null)
            try env.local_alias_eval.?(env.local_alias_ctx.?, def)
        else
            env.db.typeAliasTargetOf(def) catch return .err_silent;
        if (alias_target == TypeInterner.err_ty) return .err_silent;
        if (resolved_args.len == 0) return .{ .ok = alias_target };
        const tah = env.db.typeAliasHeaderOf(def) catch return .{ .ok = alias_target };
        return .{ .ok = try subtype_mod.substituteNominalParams(env.db, alias_target, tah.type_params, resolved_args) };
    }

    const arg_list = try env.db.types.internList(resolved_args);
    return .{ .ok = try env.db.types.intern(.{ .nominal = .{ .def = def, .args = arg_list } }) };
}

/// 详细查找类型声明返回结果。
const TypeLookupDetail = struct {
    def: ?DefId = null,
    inaccessible: bool = false,
    non_type: bool = false,
};

/// 在 `TypeResolveEnv` 中查找类型声明，同时区分“不可访问”和“同名非类型符号”。
fn lookupTypeDefDetailedInEnv(env: *const TypeResolveEnv, name: InternedId) PlatformError!TypeLookupDetail {
    var detail: TypeLookupDetail = .{};
    // 1. 当前包顶层（含本文件 private 与包内非私有声明）
    for (env.pkg_state.lookupTop(name)) |exp| {
        if (exp.vis == .private) {
            if (exp.source_file == null or !common.FileId.eql(exp.source_file.?, env.file)) {
                if (isTypeDefKind(env.db, exp.def)) detail.inaccessible = true;
                continue;
            }
        }
        if (isTypeDefKind(env.db, exp.def)) {
            detail.def = exp.def;
            return detail;
        }
        detail.non_type = true;
    }
    // 2. 当前文件显式具名/别名导入
    if (env.explicit_imports.get(name)) |entries| {
        for (entries) |exp| {
            if (isTypeDefKind(env.db, exp.def)) {
                detail.def = exp.def;
                return detail;
            }
            detail.non_type = true;
        }
    }
    // 3. 当前文件通配符导入（含隐式 std.core）
    for (env.glob_import_pkgs) |gp| {
        const ps = env.db.packageState(gp) catch continue;
        const rel = env.db.pkg_interner.relation(env.pkg_state.pkg_id, gp);
        for (ps.lookupTop(name)) |exp| {
            if (!access_mod.isVisibleInRelation(exp.vis, rel)) {
                if (isTypeDefKind(env.db, exp.def)) detail.inaccessible = true;
                continue;
            }
            if (isTypeDefKind(env.db, exp.def)) {
                detail.def = exp.def;
                return detail;
            }
            detail.non_type = true;
        }
    }
    return detail;
}

/// 在 `TypeResolveEnv` 的作用域链（本包顶层 -> 显式导入 -> 通配符导入与 `std.core`）中查找首个可见类型声明 `DefId`。
pub fn lookupTypeDefInEnv(env: *const TypeResolveEnv, name: InternedId) PlatformError!?DefId {
    return (try lookupTypeDefDetailedInEnv(env, name)).def;
}

/// 判定给定 `DefId` 是否属于类型声明（`class`/`struct`/`enum`/`interface`/`type_alias`）。
fn isTypeDefKind(db: *Database, def: DefId) bool {
    const entry = db.getDef(def) catch return false;
    return switch (entry.kind) {
        .class_, .struct_, .enum_, .interface_, .type_alias => true,
        else => false,
    };
}

/// 构造宿主名义类型的自身模板类型 `Owner<T0, T1, ...>`（用于构造器返回类型）。
fn makeOwnerSelfType(db: *Database, owner_def: DefId, owner_refs: []const TypeParamRef) PlatformError!TypeId {
    if (owner_refs.len == 0) {
        return try db.types.intern(.{ .nominal = .{ .def = owner_def, .args = .empty } });
    }
    const arg_tys = try db.gpa.alloc(TypeId, owner_refs.len);
    defer db.gpa.free(arg_tys);
    for (owner_refs, 0..) |ref, i| {
        arg_tys[i] = try db.types.intern(.{ .type_param = ref });
    }
    const list = try db.types.internList(arg_tys);
    return try db.types.intern(.{ .nominal = .{ .def = owner_def, .args = list } });
}

/// 从带类型注解的绑定模式中提取第 `target_ordinal` 个绑定变量对应的子类型。
fn extractPatternTypeAt(db: *const Database, pat: *const common.HirPattern, ty: TypeId, target_ordinal: u32) ?TypeId {
    var cursor: u32 = 0;
    return extractPatternTypeRec(db, pat, ty, target_ordinal, &cursor);
}

/// 递归提取模式中第 `target` 个绑定变量对应的子类型。
fn extractPatternTypeRec(db: *const Database, pat: *const common.HirPattern, ty: TypeId, target: u32, cursor: *u32) ?TypeId {
    switch (pat.*) {
        .binding => {
            const cur = cursor.*;
            cursor.* += 1;
            return if (cur == target) ty else null;
        },
        .typed => |tp| {
            if (tp.name != null) {
                const cur = cursor.*;
                cursor.* += 1;
                return if (cur == target) ty else null;
            }
            return null;
        },
        .tuple => |tup| {
            const elems = if (db.types.get(ty) == .tuple) db.types.getList(db.types.get(ty).tuple) else &[_]TypeId{};
            for (tup.elements, 0..) |*el, i| {
                const sub_ty = if (i < elems.len) elems[i] else TypeInterner.err_ty;
                if (extractPatternTypeRec(db, el, sub_ty, target, cursor)) |found| return found;
            }
            return null;
        },
        else => return null,
    }
}

/// 构造 `TypeParamRef` 切片。
pub fn makeTypeParamRefs(a: std.mem.Allocator, owner: ids.CallableOrTypeOwner, count: usize) std.mem.Allocator.Error![]const TypeParamRef {
    if (count == 0) return &.{};
    const out = try a.alloc(TypeParamRef, count);
    for (0..count) |i| {
        out[i] = .{ .owner = owner, .index = @intCast(i) };
    }
    return out;
}

/// 将 `Name` 切片批量驻留为 `InternedId` 切片。
pub fn internNames(db: *Database, a: std.mem.Allocator, names: []const common.Name) std.mem.Allocator.Error![]const InternedId {
    if (names.len == 0) return &.{};
    const out = try a.alloc(InternedId, names.len);
    for (names, 0..) |n, i| {
        out[i] = try db.strings.intern(n.text);
    }
    return out;
}

/// 向 `defs_buf` 与 `file_def_list` 登记单个 `DefEntry` 并返回分配的 `DefId`。
fn appendDef(
    a: std.mem.Allocator,
    state: *PackageState,
    defs_buf: *std.ArrayListUnmanaged(DefEntry),
    file_def_list: *std.ArrayListUnmanaged(DefId),
    raw_entry: DefEntry,
) std.mem.Allocator.Error!DefId {
    var entry = raw_entry;
    const idx: u32 = @intCast(defs_buf.items.len);
    const id: DefId = .{ .pkg = state.pkg_id, .pkg_gen = state.generation, .idx = idx };
    entry.id = id;
    try defs_buf.append(a, entry);
    try file_def_list.append(a, id);
    return id;
}

/// 添加包顶层导出记录。
fn addTopExport(
    a: std.mem.Allocator,
    map: *std.AutoHashMapUnmanaged(InternedId, std.ArrayListUnmanaged(ExportEntry)),
    name: InternedId,
    def: DefId,
    vis: Visibility,
    file: common.FileId,
) std.mem.Allocator.Error!void {
    const gop = try map.getOrPut(a, name);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(a, .{
        .def = def,
        .exported_name = name,
        .vis = vis,
        .is_reexport = false,
        .source_file = file,
    });
}

/// 添加成员名称到宿主容器的反向索引记录。
fn addMemberOwner(
    a: std.mem.Allocator,
    map: *std.AutoHashMapUnmanaged(InternedId, std.ArrayListUnmanaged(DefId)),
    member_name: InternedId,
    owner_def: DefId,
) std.mem.Allocator.Error!void {
    const gop = try map.getOrPut(a, member_name);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    for (gop.value_ptr.items) |existing| {
        if (DefId.eql(existing, owner_def)) return;
    }
    try gop.value_ptr.append(a, owner_def);
}

/// 剥离外层宏包裹获取实际 `HirItem`；返回指针借用自入参 `item` 所属内存池，调用者不得释放。
pub fn unwrapMacroItem(item: *const common.HirItem) *const common.HirItem {
    var cur = item;
    while (cur.* == .macro_expand) {
        cur = cur.macro_expand.wrapped orelse break;
    }
    return cur;
}

/// 剥离外层参数宏获取底层 `HirParam`。
pub fn unwrapHirParam(param: common.Param) ?common.HirParam {
    var cur = param;
    while (cur == .macro_call) {
        const inner = cur.macro_call.param orelse return null;
        cur = inner.*;
    }
    return cur.param;
}

/// 剥离外层枚举变体宏获取底层 `EnumConstructor`；返回指针借用自入参 `variant` 所属内存池，调用者不得释放。
pub fn unwrapEnumCtor(variant: *const common.EnumVariant) ?*const common.EnumConstructor {
    var cur = variant;
    while (cur.* == .macro_call) {
        cur = cur.macro_call.constructor orelse return null;
    }
    return &cur.constructor;
}

/// 从容器顶层 `HirItem` 按下标获取第 `member_idx` 个成员；返回指针借用自入参 `top` 所属内存池，调用者不得释放。
pub fn getContainerMember(top: *const common.HirItem, member_idx: u32) ?*const common.HirItem {
    const list: []const common.HirItem = switch (top.*) {
        .class => |c| c.members,
        .struct_ => |s| s.members,
        .enum_ => |e| e.members,
        .interface => |i| i.members,
        .extend_ => |ex| ex.members,
        else => return null,
    };
    return if (member_idx < list.len) &list[member_idx] else null;
}
