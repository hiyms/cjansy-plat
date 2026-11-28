// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 面向消费端的聚合查询实现（`symbolAt`、`references`、`completionsAt`、`allDiagnostics`）。

const std = @import("std");
const common = @import("common");
const ids = @import("../ids.zig");
const file_state_mod = @import("../db/FileState.zig");
const db_mod = @import("../db/Database.zig");
const scope_mod = @import("../resolve/scope.zig");
const access_mod = @import("../resolve/access.zig");
const subtype_mod = @import("../typeck/subtype.zig");
const symbol_view_mod = @import("SymbolView.zig");

const Database = db_mod.Database;
const DefId = ids.DefId;
const PackageId = ids.PackageId;
const PlatformError = file_state_mod.PlatformError;
const SymbolKind = ids.SymbolKind;
const SymbolRef = ids.SymbolRef;
const SymbolView = symbol_view_mod.SymbolView;

/// 跨文件源码定位坐标。
pub const Location = struct {
    file: common.FileId,
    range: common.TextRange,

    /// 供 `std.mem.sort` 按 `(file.index, file.generation, range.start, range.end)` 升序排序的比较函数。
    pub fn lessThan(_: void, a: Location, b: Location) bool {
        if (a.file.index != b.file.index) return a.file.index < b.file.index;
        if (a.file.generation != b.file.generation) return a.file.generation < b.file.generation;
        if (a.range.start != b.range.start) return a.range.start < b.range.start;
        return a.range.end < b.range.end;
    }
};

/// 补全候选条目（文本切片借用自 `StringInterner` 与 `view_arena`，调用者不得单独释放）。
pub const CompletionCandidate = struct {
    target: SymbolRef,
    kind: SymbolKind,
    label: []const u8,
    detail: ?[]const u8 = null,
    doc: ?[]const u8 = null,
    /// 来自 `extend` 扩展方法时为 `true`。
    is_extension_member: bool = false,
    /// 若该符号来自尚未导入的外部包（含预编译 `std` 子包），给出建议补充的包路径。
    auto_import_pkg: ?PackageId = null,
};

/// 定位单文件字节位置 `offset` 处的符号并返回只读 `SymbolView`（仅按需触发所在单个顶层声明项的 `typeCheckItem`）。
/// 返回值内部字符串与切片借用自 `StringInterner` 或当前文件 `view_arena`，调用者不得释放。
pub fn symbolAt(db: *Database, file: common.FileId, offset: u32) PlatformError!?SymbolView {
    const lowered = try db.lower(file);
    const rd = try db.resolve(file);

    // 1. 定位包含 offset 的单个顶层声明项，优先查找该项晚绑定记录（精确覆盖成员、重载与运算符）
    for (lowered.hir_file.items, 0..) |*item, idx| {
        const r = item.range();
        if (offset >= r.start and offset <= r.end) {
            const tc = try db.typeCheckItem(.{ .file = file, .item = common.ItemId.fromIndex(@intCast(idx)) });
            if (scope_mod.binarySearchOccurrence(tc.late_occurrences, offset)) |occ| {
                return try symbol_view_mod.buildSymbolView(db, file, occ.target);
            }
            break;
        }
    }

    // 2. 回退到文件级有序早绑定段定位表
    if (rd.occurrenceAt(offset)) |occ| {
        return try symbol_view_mod.buildSymbolView(db, file, occ.target);
    }
    return null;
}

/// 按目标符号的 `AccessDomain` 精准限定候选文件范围，扫描对应引用并按 `(file, range.start, range.end)` 排序返回。
/// 返回切片由调用者传入的 `alloc` 分配，结束后须由调用者通过 `alloc.free` 释放。
pub fn references(
    db: *Database,
    alloc: std.mem.Allocator,
    target: SymbolRef,
    include_decl: bool,
) PlatformError![]Location {
    var locs: std.ArrayListUnmanaged(Location) = .empty;
    errdefer locs.deinit(alloc);

    switch (target) {
        .local => |loc_id| {
            const file = loc_id.global_item.file;
            const rd = try db.resolve(file);
            for (rd.early_occurrences) |occ| {
                if (!SymbolRef.eql(occ.target, target)) continue;
                if (!include_decl and occ.kind == .decl) continue;
                try locs.append(alloc, .{ .file = file, .range = occ.range });
            }
            const tc = try db.typeCheckItem(loc_id.global_item);
            for (tc.late_occurrences) |occ| {
                if (!SymbolRef.eql(occ.target, target)) continue;
                if (!include_decl and occ.kind == .decl) continue;
                try locs.append(alloc, .{ .file = file, .range = occ.range });
            }
        },
        .def => |def_id| {
            const domain = try access_mod.effectiveDomain(db, def_id);
            // 收集受 AccessDomain 约束的候选文件集合
            var candidate_files: std.ArrayListUnmanaged(common.FileId) = .empty;
            defer candidate_files.deinit(db.gpa);

            var it = db.source.iterator();
            while (it.next()) |entry| {
                const fid = entry.id;
                const match = switch (domain) {
                    .file_only => |f| common.FileId.eql(fid, f),
                    .def_body => |d| blk: {
                        const de = db.getDef(d) catch break :blk false;
                        break :blk de.source_file != null and common.FileId.eql(fid, de.source_file.?);
                    },
                    .package_subtree => |p| blk: {
                        const fp = try db.packageOfFile(fid);
                        const rel = db.pkg_interner.relation(fp, p);
                        break :blk rel == .same_package or rel == .child_of_target;
                    },
                    .package_subtree_and_parent => |p| blk: {
                        const fp = try db.packageOfFile(fid);
                        const rel = db.pkg_interner.relation(fp, p);
                        break :blk rel == .same_package or rel == .child_of_target or rel == .direct_parent_of_target;
                    },
                    .module_only => |m| blk: {
                        const fp = try db.packageOfFile(fid);
                        break :blk db.pkg_interner.getPackage(fp).module_id == m;
                    },
                    .module_and_subclasses => true,
                    .everywhere => true,
                };
                if (match) try candidate_files.append(db.gpa, fid);
            }

            for (candidate_files.items) |fid| {
                const rd = try db.resolve(fid);
                for (rd.early_occurrences) |occ| {
                    if (!SymbolRef.eql(occ.target, target)) continue;
                    if (!include_decl and occ.kind == .decl) continue;
                    try locs.append(alloc, .{ .file = fid, .range = occ.range });
                }
                const lowered = try db.lower(fid);
                for (0..lowered.lowered_items.len) |i| {
                    const tc = try db.typeCheckItem(.{ .file = fid, .item = common.ItemId.fromIndex(@intCast(i)) });
                    for (tc.outgoing_refs) |oref| {
                        if (!DefId.eql(oref.target, def_id)) continue;
                        try locs.append(alloc, .{ .file = fid, .range = oref.range });
                    }
                }
            }
        },
        else => {},
    }

    // 排序并去重（避免同一位置在早绑定与晚绑定中重复输出）
    std.mem.sort(Location, locs.items, {}, Location.lessThan);
    var write: usize = 0;
    for (locs.items) |loc| {
        if (write == 0 or
            !common.FileId.eql(locs.items[write - 1].file, loc.file) or
            locs.items[write - 1].range.start != loc.range.start or
            locs.items[write - 1].range.end != loc.range.end)
        {
            locs.items[write] = loc;
            write += 1;
        }
    }
    locs.shrinkRetainingCapacity(write);
    return locs.toOwnedSlice(alloc);
}

/// 收集指定位置的补全候选列表（自动区分点分成员补全、包/导入路径补全与无限定作用域补全）。
/// 返回切片由调用者传入的 `alloc` 分配，结束后须由调用者释放；条目内文本切片借用自 `StringInterner` 与 `view_arena`。
pub fn completionsAt(
    db: *Database,
    alloc: std.mem.Allocator,
    file: common.FileId,
    offset: u32,
) PlatformError![]CompletionCandidate {
    const content = try db.fileContent(file);
    const safe_off = @min(offset, @as(u32, @intCast(content.len)));

    // 探测光标前最近非空白字符是否为 '.'（点分成员或子包补全）
    var cur = safe_off;
    while (cur > 0 and (content[cur - 1] == ' ' or content[cur - 1] == '\t')) cur -= 1;
    // 回退已输入的标识符前缀
    const prefix_end = cur;
    while (cur > 0 and isIdentChar(content[cur - 1])) cur -= 1;
    const prefix = content[cur..prefix_end];

    var dot_pos = cur;
    while (dot_pos > 0 and (content[dot_pos - 1] == ' ' or content[dot_pos - 1] == '\t')) dot_pos -= 1;

    if (dot_pos > 0 and content[dot_pos - 1] == '.') {
        const before_dot = dot_pos - 1;
        if (before_dot > 0) {
            if (try symbolAt(db, file, before_dot - 1)) |recv_view| {
                if (recv_view.target == .pkg) {
                    return collectPackageMemberCompletions(db, alloc, file, recv_view.target.pkg, prefix);
                }
                return collectReceiverMemberCompletions(db, alloc, file, recv_view.type_view.id, prefix);
            }
        }
    }

    // 无限定作用域补全
    const sv_opt = try db.scopeAt(file, safe_off);
    var out: std.ArrayListUnmanaged(CompletionCandidate) = .empty;
    errdefer out.deinit(alloc);

    if (sv_opt) |sv| {
        const visible = try sv.collectVisibleSymbols(db.gpa, safe_off);
        defer db.gpa.free(visible);
        for (visible) |cand| {
            if (prefix.len == 0 or std.mem.startsWith(u8, cand.label, prefix)) {
                try out.append(alloc, cand);
            }
        }
    }

    // 若配置了外部预编译索引且输入了非空前缀，附带可自动导入的标准库符号候选
    if (prefix.len > 0) {
        if (db.config.preload_provider) |prov| {
            const matches = try prov.vtable.searchExportedSymbols(prov.ptr, db, prefix, db.gpa);
            defer db.gpa.free(matches);
            for (matches) |m| {
                try out.append(alloc, .{
                    .target = .{ .pkg = m.pkg },
                    .kind = m.kind,
                    .label = db.strings.get(m.name),
                    .auto_import_pkg = m.pkg,
                });
            }
        }
    }

    return out.toOwnedSlice(alloc);
}

/// 收集包限定路径 `pkg.` 后的直接导出符号与预编译子包补全候选。
fn collectPackageMemberCompletions(
    db: *Database,
    alloc: std.mem.Allocator,
    file: common.FileId,
    pkg_id: PackageId,
    prefix: []const u8,
) PlatformError![]CompletionCandidate {
    var out: std.ArrayListUnmanaged(CompletionCandidate) = .empty;
    errdefer out.deinit(alloc);

    const rd = try db.resolve(file);
    const rel = db.pkg_interner.relation(rd.pkg_id, pkg_id);

    if (db.packageState(pkg_id)) |ps| {
        var it = ps.top_exports.iterator();
        while (it.next()) |kv| {
            const label = db.strings.get(kv.key_ptr.*);
            if (prefix.len > 0 and !std.mem.startsWith(u8, label, prefix)) continue;
            for (kv.value_ptr.*) |exp| {
                if (!access_mod.isVisibleInRelation(exp.vis, rel)) continue;
                const de = db.getDef(exp.def) catch continue;
                try out.append(alloc, .{
                    .target = .{ .def = exp.def },
                    .kind = de.kind,
                    .label = label,
                    .doc = if (de.doc) |d| db.strings.get(d) else null,
                });
            }
        }
    } else |_| {}

    if (db.config.preload_provider) |prov| {
        const subpkgs = try prov.vtable.listSubpackages(prov.ptr, db, pkg_id, db.gpa);
        defer db.gpa.free(subpkgs);
        for (subpkgs) |sp| {
            const info = db.pkg_interner.getPackage(sp);
            if (info.segments.len == 0) continue;
            const seg = db.strings.get(info.segments[info.segments.len - 1]);
            if (prefix.len > 0 and !std.mem.startsWith(u8, seg, prefix)) continue;
            try out.append(alloc, .{
                .target = .{ .pkg = sp },
                .kind = .package,
                .label = seg,
            });
        }
    }
    return out.toOwnedSlice(alloc);
}

/// 收集接收者类型 `recv_ty` 的成员与可见 `extend` 扩展方法补全候选。
fn collectReceiverMemberCompletions(
    db: *Database,
    alloc: std.mem.Allocator,
    file: common.FileId,
    recv_ty: ids.TypeId,
    prefix: []const u8,
) PlatformError![]CompletionCandidate {
    var out: std.ArrayListUnmanaged(CompletionCandidate) = .empty;
    errdefer out.deinit(alloc);
    var seen: std.AutoHashMapUnmanaged(DefId, void) = .empty;
    defer seen.deinit(db.gpa);

    const rd = try db.resolve(file);
    const unboxed = db.types.unboxOption(recv_ty);
    const ctx: ids.AccessContext = .{
        .module_id = rd.module_id,
        .pkg_id = rd.pkg_id,
        .file_id = file,
    };

    switch (db.types.get(unboxed)) {
        .nominal => |nom| {
            try appendMembersOfDef(db, alloc, &out, &seen, nom.def, unboxed, ctx, prefix, false);
            const supers = try subtype_mod.collectAllSupertypes(db, db.gpa, file, unboxed);
            defer db.gpa.free(supers);
            for (supers) |st| {
                if (db.types.get(st) == .nominal) {
                    try appendMembersOfDef(db, alloc, &out, &seen, db.types.get(st).nominal.def, unboxed, ctx, prefix, false);
                }
            }
            for (rd.visible_extends.getForNominal(nom.def)) |ext_def| {
                const eps = db.packageState(ext_def.pkg) catch continue;
                for (eps.extends) |ext| {
                    if (!DefId.eql(ext.def, ext_def)) continue;
                    const matched = (try subtype_mod.matchExtendTarget(db, db.gpa, file, unboxed, ext)) orelse break;
                    defer db.gpa.free(matched);
                    try appendMembersOfDef(db, alloc, &out, &seen, ext_def, unboxed, ctx, prefix, true);
                    break;
                }
            }
        },
        .prim => |pk| {
            for (rd.visible_extends.getForPrim(pk)) |ext_def| {
                try appendMembersOfDef(db, alloc, &out, &seen, ext_def, unboxed, ctx, prefix, true);
            }
        },
        else => {},
    }

    return out.toOwnedSlice(alloc);
}

/// 将指定容器或扩展定义中的可访问成员追加到补全列表。
fn appendMembersOfDef(
    db: *Database,
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(CompletionCandidate),
    seen: *std.AutoHashMapUnmanaged(DefId, void),
    owner_def: DefId,
    recv_ty: ids.TypeId,
    ctx: ids.AccessContext,
    prefix: []const u8,
    is_ext: bool,
) PlatformError!void {
    const oe = db.getDef(owner_def) catch return;
    for (oe.members) |m_def| {
        if (seen.contains(m_def)) continue;
        const me = db.getDef(m_def) catch continue;
        if (me.kind == .constructor or me.kind == .finalizer) continue;
        const label = db.strings.get(me.name);
        if (prefix.len > 0 and !std.mem.startsWith(u8, label, prefix)) continue;
        if (is_ext) {
            if (!try access_mod.isExtendMemberAccessible(db, ctx.file_id, owner_def, m_def)) continue;
        } else {
            if (!try access_mod.checkAccess(db, m_def, recv_ty, ctx)) continue;
        }
        try seen.put(db.gpa, m_def, {});
        try out.append(alloc, .{
            .target = .{ .def = m_def },
            .kind = me.kind,
            .label = label,
            .doc = if (me.doc) |d| db.strings.get(d) else null,
            .is_extension_member = is_ext,
        });
    }
}

/// 聚合单文件全部阶段诊断（词法、语法、`lower`、包级、`resolve` 与本文件全部声明项 `typeck`），
/// 按文件内位置优先 `(range.start, range.end, severity, source_order)` 稳定排序。
/// 返回切片由调用者传入的 `alloc` 分配，结束后须由调用者通过 `alloc.free` 释放。
pub fn allDiagnostics(
    db: *Database,
    alloc: std.mem.Allocator,
    file: common.FileId,
) PlatformError![]common.Diagnostic {
    _ = try db.parse(file);
    const lowered = try db.lower(file);

    // 先触发本文件所有声明项的类型检查，确保可能出现的 sema_arena 阈值重置全部稳定完成后再收集诊断借用切片。
    for (0..lowered.lowered_items.len) |i| {
        _ = try db.typeCheckItem(.{ .file = file, .item = common.ItemId.fromIndex(@intCast(i)) });
    }

    const rd = try db.resolve(file);
    const ps = try db.packageState(rd.pkg_id);
    const fs = db.file_states.get(file) orelse return error.InvalidFileId;

    var out: std.ArrayListUnmanaged(common.Diagnostic) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, fs.parse_diagnostics);
    try out.appendSlice(alloc, lowered.diagnostics);
    for (lowered.lowered_items) |li| {
        try out.appendSlice(alloc, li.diagnostics);
    }
    for (ps.diagnostics) |d| {
        if (common.FileId.eql(d.file, file)) try out.append(alloc, d);
    }
    try out.appendSlice(alloc, rd.diagnostics);

    for (0..lowered.lowered_items.len) |i| {
        const tc = try db.typeCheckItem(.{ .file = file, .item = common.ItemId.fromIndex(@intCast(i)) });
        try out.appendSlice(alloc, tc.diagnostics);
    }

    std.mem.sort(common.Diagnostic, out.items, {}, diagnosticPosLessThan);
    return out.toOwnedSlice(alloc);
}

/// 文件内诊断位置优先比较器：依次按 `range.start`、`range.end`、`severity`、来源阶段序号比较。
fn diagnosticPosLessThan(_: void, a: common.Diagnostic, b: common.Diagnostic) bool {
    if (a.range.start != b.range.start) return a.range.start < b.range.start;
    if (a.range.end != b.range.end) return a.range.end < b.range.end;
    if (@backingInt(a.severity) != @backingInt(b.severity)) {
        return @backingInt(a.severity) < @backingInt(b.severity);
    }
    return sourceOrder(a.source) < sourceOrder(b.source);
}

/// 将诊断来源阶段映射为稳定排序序号。
inline fn sourceOrder(src: common.DiagnosticSource) u8 {
    return switch (src) {
        .lexer => 0,
        .parser => 1,
        .name_res => 2,
        .typeck => 3,
        .linter => 4,
    };
}

/// 判定字节是否属于 ASCII 标识符字符。
inline fn isIdentChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
}
