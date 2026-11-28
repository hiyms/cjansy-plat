// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 符号、语义类型与可调用签名的对外只读展示视图（`SymbolView`、`TypeView`、`ParamView`、`FnSigView`）。

const std = @import("std");
const common = @import("common");
const ids = @import("../ids.zig");
const file_state_mod = @import("../db/FileState.zig");
const pkg_state_mod = @import("../db/PackageState.zig");
const db_mod = @import("../db/Database.zig");
const type_interner_mod = @import("../interner/TypeInterner.zig");
const queries_mod = @import("Queries.zig");

const CallableHeaderSig = pkg_state_mod.CallableHeaderSig;
const Database = db_mod.Database;
const DefId = ids.DefId;
const Location = queries_mod.Location;
const PlatformError = file_state_mod.PlatformError;
const SymbolKind = ids.SymbolKind;
const SymbolRef = ids.SymbolRef;
const TypeId = ids.TypeId;
const TypeInterner = type_interner_mod.TypeInterner;
const Visibility = ids.Visibility;

/// 语义类型的只读展示视图。
pub const TypeView = struct {
    id: TypeId,
    /// 可读格式化文本（如 `Array<Option<Int64>>`、`(Int64, String) -> Bool`），借用自 `view_arena`。
    display: []const u8,
    /// 若该类型本身指向一个名义类型声明，提供其跳转目标 `DefId`（供 LSP `typeDefinition` 使用）。
    nominal_def: ?DefId = null,
    /// 若该类型经由类型别名引用，提供对应类型别名声明 `DefId`（便于展示别名文档与跳转别名定义）。
    alias_def: ?DefId = null,
    /// 该类型对应的文档注释正文（已去除注释定界符，借用自 `StringInterner`，调用者不得释放）：
    /// 优先读取 `alias_def` 对应 `TypeAliasHeader.doc`（为 `null` 时回退底层展开类型），
    /// 名义类型与 `ClassThisTy` 读取 `NominalHeader.doc`，内建基础类型、`VArray` 与 `CPointer` 读取 `TypeInterner.builtinDocOf`。
    doc: ?[]const u8 = null,
};

/// 函数或构造器形参的只读展示视图。
pub const ParamView = struct {
    name: ?[]const u8,
    ty: TypeView,
    is_named: bool,
    has_default: bool,
};

/// 可调用声明完整签名的只读视图（支持省略返回类型推导后的精确返回值展示）。
pub const FnSigView = struct {
    type_params: []const []const u8,
    params: []const ParamView,
    ret: TypeView,
    is_variadic: bool,
    /// 完整可读签名（如 `public func map<T, R>(transform: (T) -> R): Array<R>`），借用自 `view_arena`。
    display: []const u8,
};

/// 符号的对外只读视图（支撑 `hover`、`definition`、`typeDefinition`、`DocsGen`）。
pub const SymbolView = struct {
    target: SymbolRef,
    kind: SymbolKind,
    name: []const u8,
    /// 完整限定路径（如 `std.core.String.size`），借用自 `view_arena`。
    qualified_name: []const u8,
    visibility: Visibility,
    is_mut: bool,
    /// 声明定义所在源文件与字节区间（对预编译索引符号按需经 `materializeHeaderSource` 获取；基础类型返回 `null`）。
    def_location: ?Location,
    /// 符号所属或推导出的语义类型视图。
    type_view: TypeView,
    /// 可调用符号的完整签名视图；非可调用符号为 `null`。
    signature_view: ?FnSigView = null,
    /// 前导文档注释正文（已去除注释定界符）；无文档注释为 `null`。
    doc: ?[]const u8 = null,
};

/// 构造语义类型 `ty` 的只读展示视图 `TypeView`（格式化文本分配于 `file` 的 `view_arena`，文档注释借用自 `StringInterner`）。
pub fn buildTypeView(
    db: *Database,
    file: common.FileId,
    ty: TypeId,
    alias_def: ?DefId,
) PlatformError!TypeView {
    const fs = db.file_states.get(file) orelse return error.InvalidFileId;
    const va = fs.view_arena.allocator();
    const display = try formatType(db, va, ty);

    const nominal_def: ?DefId = switch (db.types.get(ty)) {
        .nominal => |n| n.def,
        .class_this => |d| d,
        else => null,
    };

    var doc: ?[]const u8 = null;
    if (alias_def) |ad| {
        if (db.typeAliasHeaderOf(ad)) |tah| {
            if (tah.doc) |d_id| doc = db.strings.get(d_id);
        } else |_| {}
    }
    if (doc == null) {
        doc = try db.typeDocOf(ty);
    }

    return .{
        .id = ty,
        .display = display,
        .nominal_def = nominal_def,
        .alias_def = alias_def,
        .doc = doc,
    };
}

/// 将 `TypeId` 格式化为可读仓颉类型文本，结果分配于 `alloc`（调用者负责管理或由 `view_arena` 统一回收）。
pub fn formatType(db: *Database, alloc: std.mem.Allocator, ty: TypeId) PlatformError![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    try writeType(db, alloc, &buf, ty);
    return buf.toOwnedSlice(alloc);
}

/// 递归向字节缓冲区写入可读类型表示。
fn writeType(db: *Database, alloc: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), ty: TypeId) PlatformError!void {
    switch (db.types.get(ty)) {
        .err => try buf.appendSlice(alloc, "<error>"),
        .quest => try buf.appendSlice(alloc, "?"),
        .ideal_int => try buf.appendSlice(alloc, "IdealInt"),
        .ideal_float => try buf.appendSlice(alloc, "IdealFloat"),
        .prim => |pk| try buf.appendSlice(alloc, pk.displayName()),
        .nominal => |n| {
            const de = db.getDef(n.def) catch null;
            const name = if (de) |e| db.strings.get(e.name) else "<unknown>";
            try buf.appendSlice(alloc, name);
            const args = db.types.getList(n.args);
            if (args.len > 0) {
                try buf.append(alloc, '<');
                for (args, 0..) |a, i| {
                    if (i > 0) try buf.appendSlice(alloc, ", ");
                    try writeType(db, alloc, buf, a);
                }
                try buf.append(alloc, '>');
            }
        },
        .type_param => |tp| {
            const name = lookupTypeParamName(db, tp) orelse "T";
            try buf.appendSlice(alloc, name);
        },
        .class_this => try buf.appendSlice(alloc, "This"),
        .cpointer => |elem| {
            try buf.appendSlice(alloc, "CPointer<");
            try writeType(db, alloc, buf, elem);
            try buf.append(alloc, '>');
        },
        .varray => |v| {
            try buf.appendSlice(alloc, "VArray<");
            try writeType(db, alloc, buf, v.elem);
            try buf.appendSlice(alloc, ", $");
            var num_buf: [32]u8 = undefined;
            const len_str = std.fmt.bufPrint(&num_buf, "{d}", .{v.len}) catch "0";
            try buf.appendSlice(alloc, len_str);
            try buf.append(alloc, '>');
        },
        .tuple => |list_id| {
            const elems = db.types.getList(list_id);
            try buf.append(alloc, '(');
            for (elems, 0..) |el, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try writeType(db, alloc, buf, el);
            }
            try buf.append(alloc, ')');
        },
        .func => |f| {
            if (f.is_cfunc) try buf.appendSlice(alloc, "CFunc<");
            try buf.append(alloc, '(');
            const params = db.types.getList(f.params);
            for (params, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try writeType(db, alloc, buf, p);
            }
            try buf.appendSlice(alloc, ") -> ");
            try writeType(db, alloc, buf, f.ret);
            if (f.is_cfunc) try buf.append(alloc, '>');
        },
    }
}

/// 根据 `TypeParamRef` 查找对应泛型形参的原始名称；返回切片借用自 `StringInterner`。
fn lookupTypeParamName(db: *Database, tp: ids.TypeParamRef) ?[]const u8 {
    switch (tp.owner) {
        .def => |d| {
            const de = db.getDef(d) catch return null;
            if (tp.index < de.type_param_names.len) {
                return db.strings.get(de.type_param_names[tp.index]);
            }
            return null;
        },
        .local => return null,
    }
}

/// 构造可调用声明的 `FnSigView`（文本与切片分配于 `file` 的 `view_arena`）。
pub fn buildFnSigView(
    db: *Database,
    file: common.FileId,
    vis: Visibility,
    name: []const u8,
    sig: *const CallableHeaderSig,
    ret_ty: TypeId,
) PlatformError!FnSigView {
    const fs = db.file_states.get(file) orelse return error.InvalidFileId;
    const va = fs.view_arena.allocator();

    const tp_names = try va.alloc([]const u8, sig.type_params.len);
    for (sig.type_params, 0..) |tp, i| {
        tp_names[i] = lookupTypeParamName(db, tp) orelse "T";
    }

    const p_views = try va.alloc(ParamView, sig.params.len);
    for (sig.params, 0..) |p, i| {
        p_views[i] = .{
            .name = if (p.name) |nid| db.strings.get(nid) else null,
            .ty = try buildTypeView(db, file, p.ty, null),
            .is_named = p.is_named,
            .has_default = p.has_default,
        };
    }

    const ret_view = try buildTypeView(db, file, ret_ty, null);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const vis_str: []const u8 = switch (vis) {
        .public => "public ",
        .protected => "protected ",
        .internal => "internal ",
        .private => "private ",
    };
    try buf.appendSlice(va, vis_str);
    try buf.appendSlice(va, if (sig.is_ctor) "init" else "func ");
    if (!sig.is_ctor) try buf.appendSlice(va, name);
    if (tp_names.len > 0) {
        try buf.append(va, '<');
        for (tp_names, 0..) |tn, i| {
            if (i > 0) try buf.appendSlice(va, ", ");
            try buf.appendSlice(va, tn);
        }
        try buf.append(va, '>');
    }
    try buf.append(va, '(');
    for (p_views, 0..) |pv, i| {
        if (i > 0) try buf.appendSlice(va, ", ");
        if (pv.name) |pn| {
            try buf.appendSlice(va, pn);
            if (pv.is_named) try buf.append(va, '!');
            try buf.appendSlice(va, ": ");
        }
        try buf.appendSlice(va, pv.ty.display);
    }
    try buf.appendSlice(va, "): ");
    try buf.appendSlice(va, ret_view.display);

    return .{
        .type_params = tp_names,
        .params = p_views,
        .ret = ret_view,
        .is_variadic = sig.is_variadic,
        .display = try buf.toOwnedSlice(va),
    };
}

/// 格式化包完整限定路径（如 `std.core`），结果分配于 `alloc`。
pub fn formatPackagePath(db: *Database, alloc: std.mem.Allocator, pkg: ids.PackageId) std.mem.Allocator.Error![]const u8 {
    const info = db.pkg_interner.getPackage(pkg);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    if (info.org) |org| {
        try buf.appendSlice(alloc, db.strings.get(org));
        try buf.appendSlice(alloc, "::");
    }
    for (info.segments, 0..) |seg, i| {
        if (i > 0) try buf.append(alloc, '.');
        try buf.appendSlice(alloc, db.strings.get(seg));
    }
    return buf.toOwnedSlice(alloc);
}

/// 构造 `SymbolRef` 的完整对外只读 `SymbolView`（展示切片分配于 `query_file` 的 `view_arena`）。
pub fn buildSymbolView(db: *Database, query_file: common.FileId, target: SymbolRef) PlatformError!SymbolView {
    const fs = db.file_states.get(query_file) orelse return error.InvalidFileId;
    const va = fs.view_arena.allocator();

    switch (target) {
        .prim => |pk| {
            const pty = TypeInterner.prim(pk);
            const tv = try buildTypeView(db, query_file, pty, null);
            return .{
                .target = target,
                .kind = .struct_,
                .name = pk.displayName(),
                .qualified_name = pk.displayName(),
                .visibility = .public,
                .is_mut = false,
                .def_location = null,
                .type_view = tv,
                .signature_view = null,
                .doc = tv.doc,
            };
        },
        .pkg => |pkg_id| {
            const qn = try formatPackagePath(db, va, pkg_id);
            const info = db.pkg_interner.getPackage(pkg_id);
            const short_name = if (info.segments.len > 0) db.strings.get(info.segments[info.segments.len - 1]) else qn;
            return .{
                .target = target,
                .kind = .package,
                .name = short_name,
                .qualified_name = qn,
                .visibility = .public,
                .is_mut = false,
                .def_location = null,
                .type_view = try buildTypeView(db, query_file, TypeInterner.unit_ty, null),
                .signature_view = null,
                .doc = null,
            };
        },
        .type_param => |tp| {
            const name = lookupTypeParamName(db, tp) orelse "T";
            const ty = try db.types.intern(.{ .type_param = tp });
            return .{
                .target = target,
                .kind = .type_param,
                .name = name,
                .qualified_name = name,
                .visibility = .private,
                .is_mut = false,
                .def_location = null,
                .type_view = try buildTypeView(db, query_file, ty, null),
                .signature_view = null,
                .doc = null,
            };
        },
        .local => |loc_id| {
            const rd = try db.resolve(loc_id.global_item.file);
            const loc = rd.getLocal(loc_id.idx) orelse return error.InvalidDefId;
            const name = db.strings.get(loc.name);
            const item_tc = try db.typeCheckItem(loc_id.global_item);
            const raw_ty = item_tc.typeOf(loc.decl_key.hir) orelse TypeInterner.err_ty;
            var ty: TypeId = if (raw_ty != TypeInterner.err_ty) raw_ty else (loc.annotated_ty orelse TypeInterner.err_ty);
            var fn_sig_view: ?FnSigView = null;
            if (loc.callable_sig_idx) |sidx| {
                if (rd.getLocalCallable(sidx)) |sig| {
                    const ret = if (db.types.get(ty) == .func)
                        db.types.get(ty).func.ret
                    else
                        (sig.explicit_ret orelse TypeInterner.unit_ty);
                    fn_sig_view = try buildFnSigView(db, query_file, .private, name, sig, ret);
                    if (ty == TypeInterner.err_ty) {
                        const p_tys = try db.gpa.alloc(TypeId, sig.params.len);
                        defer db.gpa.free(p_tys);
                        for (sig.params, 0..) |p, i| p_tys[i] = p.ty;
                        const p_list = try db.types.internList(p_tys);
                        ty = try db.types.intern(.{ .func = .{ .params = p_list, .ret = ret, .is_cfunc = false } });
                    }
                }
            }
            return .{
                .target = target,
                .kind = loc.kind,
                .name = name,
                .qualified_name = name,
                .visibility = .private,
                .is_mut = loc.is_mut,
                .def_location = .{ .file = loc_id.global_item.file, .range = loc.name_range },
                .type_view = try buildTypeView(db, query_file, ty, null),
                .signature_view = fn_sig_view,
                .doc = null,
            };
        },
        .def => |def_id| {
            const entry = try db.getDef(def_id);
            const name = db.strings.get(entry.name);
            const pkg_path = try formatPackagePath(db, va, def_id.pkg);
            const qn = if (entry.owner) |ow| blk: {
                const ow_name = if (db.getDef(ow)) |oe| db.strings.get(oe.name) else |_| "";
                break :blk try std.fmt.allocPrint(va, "{s}.{s}.{s}", .{ pkg_path, ow_name, name });
            } else try std.fmt.allocPrint(va, "{s}.{s}", .{ pkg_path, name });

            const def_loc = try resolveDefLocation(db, def_id, entry);
            const doc: ?[]const u8 = if (entry.doc) |d_id| db.strings.get(d_id) else null;

            var fn_sig_view: ?FnSigView = null;
            var alias_ref: ?DefId = null;
            const sym_ty: TypeId = switch (entry.kind) {
                .class_, .struct_, .enum_, .interface_ => blk: {
                    const nh = db.nominalHeaderOf(def_id) catch break :blk TypeInterner.err_ty;
                    const targs = try db.gpa.alloc(TypeId, nh.type_params.len);
                    defer db.gpa.free(targs);
                    for (nh.type_params, 0..) |tp, i| {
                        targs[i] = try db.types.intern(.{ .type_param = tp });
                    }
                    const list = try db.types.internList(targs);
                    break :blk try db.types.intern(.{ .nominal = .{ .def = def_id, .args = list } });
                },
                .type_alias => blk: {
                    alias_ref = def_id;
                    break :blk try db.typeAliasTargetOf(def_id);
                },
                .func_, .method, .constructor, .primary_ctor => blk: {
                    const sig = db.callableHeaderSig(.{ .def = def_id }) catch break :blk TypeInterner.err_ty;
                    const ret = try db.returnTypeOf(def_id);
                    fn_sig_view = try buildFnSigView(db, query_file, entry.declared_vis, name, sig, ret);
                    const p_tys = try db.gpa.alloc(TypeId, sig.params.len);
                    defer db.gpa.free(p_tys);
                    for (sig.params, 0..) |p, i| p_tys[i] = p.ty;
                    const p_list = try db.types.internList(p_tys);
                    break :blk try db.types.intern(.{ .func = .{ .params = p_list, .ret = ret, .is_cfunc = false } });
                },
                .enum_variant => blk: {
                    if (db.callableHeaderSig(.{ .def = def_id })) |sig| {
                        const ret = sig.explicit_ret orelse TypeInterner.err_ty;
                        fn_sig_view = try buildFnSigView(db, query_file, entry.declared_vis, name, sig, ret);
                        const p_tys = try db.gpa.alloc(TypeId, sig.params.len);
                        defer db.gpa.free(p_tys);
                        for (sig.params, 0..) |p, i| p_tys[i] = p.ty;
                        const p_list = try db.types.internList(p_tys);
                        break :blk try db.types.intern(.{ .func = .{ .params = p_list, .ret = ret, .is_cfunc = false } });
                    } else |_| {
                        break :blk db.varTypeOf(def_id) catch TypeInterner.err_ty;
                    }
                },
                .prop => try db.propTypeOf(def_id),
                .field, .variable, .constant => try db.varTypeOf(def_id),
                else => TypeInterner.unit_ty,
            };

            const tv = try buildTypeView(db, query_file, sym_ty, alias_ref);
            return .{
                .target = target,
                .kind = entry.kind,
                .name = name,
                .qualified_name = qn,
                .visibility = entry.declared_vis,
                .is_mut = entry.flags.is_mut,
                .def_location = def_loc,
                .type_view = tv,
                .signature_view = fn_sig_view,
                .doc = doc orelse tv.doc,
            };
        },
    }
}

/// 解析包级声明的精确定义位置（源码声明读取当前版本 `DefSourceInfo`，预编译声明调用 `preload_provider.materializeHeaderSource`）。
pub fn resolveDefLocation(db: *Database, def_id: DefId, entry: *const pkg_state_mod.DefEntry) PlatformError!?Location {
    if (entry.source_file) |sf| {
        const rd = try db.resolve(sf);
        if (rd.def_source_infos.get(def_id)) |info| {
            return .{ .file = sf, .range = info.name_range };
        }
    }
    if (db.config.preload_provider) |prov| {
        return prov.vtable.materializeHeaderSource(prov.ptr, db, def_id);
    }
    return null;
}
