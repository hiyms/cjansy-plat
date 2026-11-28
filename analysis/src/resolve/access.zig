// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 四级可见性判定、跨包导入权限、`extend` 成员可见性、公开签名低可见性暴露检查与引用范围域计算。

const std = @import("std");
const common = @import("common");
const ids = @import("../ids.zig");
const str_interner = @import("../interner/StringInterner.zig");
const type_interner = @import("../interner/TypeInterner.zig");
const file_state_mod = @import("../db/FileState.zig");
const db_mod = @import("../db/Database.zig");
const subtype_mod = @import("../typeck/subtype.zig");

const AccessContext = ids.AccessContext;
const AccessDomain = ids.AccessDomain;
const Database = db_mod.Database;
const DefId = ids.DefId;
const PackageId = ids.PackageId;
const PackageInterner = str_interner.PackageInterner;
const PackageRelation = str_interner.PackageRelation;
const PlatformError = file_state_mod.PlatformError;
const TypeId = ids.TypeId;
const Visibility = ids.Visibility;

/// 判定 `src_pkg` 能否导入访问级别为 `target_pkg_vis` 的目标包 `target_pkg`：
/// - `public`：任意包可导入；
/// - `protected`：同模块内可导入；
/// - `internal`：本包、后代子包以及直接上一层父包可导入。
pub fn canImportPackage(
    pkg_interner: *const PackageInterner,
    src_pkg: PackageId,
    target_pkg: PackageId,
    target_pkg_vis: Visibility,
) bool {
    const rel = pkg_interner.relation(src_pkg, target_pkg);
    return switch (target_pkg_vis) {
        .public => true,
        .protected => rel != .unrelated,
        .internal => rel == .same_package or rel == .child_of_target or rel == .direct_parent_of_target,
        .private => rel == .same_package,
    };
}

/// 判定给定包层级关系下，非私有声明访问级别 `vis` 是否对调用方包可见（对应 `Modules::IsVisible`）。
pub inline fn isVisibleInRelation(vis: Visibility, rel: PackageRelation) bool {
    return switch (vis) {
        .public => true,
        .protected => rel != .unrelated,
        .internal => rel == .same_package or rel == .child_of_target,
        .private => false,
    };
}

/// 统一访问权限检查：判定 `ctx` 能否访问目标声明 `target_def`（非静态 `protected` 成员访问额外校验 `receiver_ty` 子类约束）。
pub fn checkAccess(
    db: *Database,
    target_def: DefId,
    receiver_ty: ?TypeId,
    ctx: AccessContext,
) PlatformError!bool {
    const entry = try db.getDef(target_def);
    const rel = db.pkg_interner.relation(ctx.pkg_id, target_def.pkg);

    // 顶层声明或扩展块本身
    if (entry.owner == null) {
        if (entry.declared_vis == .private) {
            return if (entry.source_file) |sf| common.FileId.eql(sf, ctx.file_id) else false;
        }
        return isVisibleInRelation(entry.declared_vis, rel);
    }

    // 容器成员或扩展成员
    const owner_def = entry.owner.?;
    const owner_entry = try db.getDef(owner_def);
    if (owner_entry.kind == .extend_) {
        if (entry.declared_vis == .private) {
            return containsDef(ctx.enclosing_defs, owner_def);
        }
        if (rel != .same_package) {
            return try isExtendMemberAccessible(db, ctx.file_id, owner_def, target_def);
        }
        return true;
    }

    // 普通名义类型成员（class / struct / enum / interface）
    switch (entry.declared_vis) {
        .public => return true,
        .private => return containsDef(ctx.enclosing_defs, owner_def),
        .internal => return isVisibleInRelation(.internal, rel),
        .protected => {
            if (rel != .unrelated) return true;
            // 跨模块子类内部访问父类 protected 成员
            for (ctx.enclosing_defs) |enc| {
                if (try isSubclassOf(db, ctx.file_id, enc, owner_def)) {
                    if (receiver_ty) |rty| {
                        const enc_ty = try db.types.intern(.{ .nominal = .{ .def = enc, .args = .empty } });
                        if (try subtype_mod.isSubtype(db, ctx.file_id, rty, enc_ty, .{})) return true;
                    } else {
                        return true;
                    }
                }
            }
            return false;
        },
    }
}

/// 判定某 `extend` 块及其成员 `member_def` 对 `file_id` 是否可见：
/// - 同包扩展总是可见；
/// - `std.core` 对包外可见类型的直接扩展在隐式导入下可见；
/// - 跨包扩展须满足四项条件：扩展已导出、被扩展类型与全部约束上界在 `file_id` 可见、成员已导出、跨包接口扩展中声明该成员的具体接口在 `file_id` 已导入/可见。
pub fn isExtendMemberAccessible(
    db: *Database,
    file_id: common.FileId,
    extend_def: DefId,
    member_def: DefId,
) PlatformError!bool {
    const file_pkg = try db.packageOfFile(file_id);
    if (file_pkg == extend_def.pkg) return true;

    const ext_pkg = try db.packageState(extend_def.pkg);
    const member_entry = try db.getDef(member_def);
    if (member_entry.declared_vis == .private) return false;

    const ext_entry = blk: {
        for (ext_pkg.extends) |*e| {
            if (DefId.eql(e.def, extend_def)) break :blk e;
        }
        return false;
    };

    // 1. 扩展本身与成员导出级别检查
    const rel = db.pkg_interner.relation(file_pkg, extend_def.pkg);
    if (!ext_entry.is_exported) {
        // std.core 对包外可见类型的直接扩展默认导出
        if (db.types.known.std_core_pkg != extend_def.pkg or !ext_entry.is_direct) return false;
    }
    if (!isVisibleInRelation(ext_entry.export_vis, rel)) return false;
    if (!isVisibleInRelation(member_entry.declared_vis, rel)) return false;

    // 2. 校验被扩展类型与泛型约束上界对当前文件可见
    const resolve_data = try db.resolve(file_id);
    for (ext_entry.constraint_types) |ct_def| {
        if (!try isTypeVisibleInFile(db, file_id, resolve_data, ct_def)) return false;
    }

    // 3. 跨包接口扩展校验具体实现接口已在当前文件可见
    if (!ext_entry.is_direct and ext_entry.implemented_interfaces.len > 0) {
        if (ext_pkg.findImplementingInterface(extend_def, member_def)) |impl_iface| {
            if (!try isTypeVisibleInFile(db, file_id, resolve_data, impl_iface)) return false;
        } else {
            var any_iface_visible = false;
            for (ext_entry.implemented_interfaces) |iface_ty| {
                if (db.types.get(iface_ty) == .nominal) {
                    const iface_def = db.types.get(iface_ty).nominal.def;
                    if (try isTypeVisibleInFile(db, file_id, resolve_data, iface_def)) {
                        any_iface_visible = true;
                        break;
                    }
                }
            }
            if (!any_iface_visible) return false;
        }
    }
    return true;
}

/// 公开签名低可见性类型暴露检查（对应 `cangjie_compiler` 的 `CheckAccessLevelValidity`）：
/// 递归遍历 `referenced_ty` 中的全部名义类型 `T`，按外层名义类型封顶后的四级 `effective_vis` 标量序校验
/// `decl.effective_vis.isNoMoreOpenThan(T.effective_vis)`。
/// 遵循规范豁免：跳过 `extend` 本体以及类型声明的直接父类与父接口列表。
/// 若发现低可见性暴露，返回首个违规类型 `DefId`；合法返回 `null`。
pub fn checkVisibilityExposure(
    db: *Database,
    decl_def: DefId,
    referenced_ty: TypeId,
) PlatformError!?DefId {
    const decl = try db.getDef(decl_def);
    if (decl.effective_vis == .private or decl.kind == .extend_) return null;
    return checkTyExposureRecursive(db, decl.effective_vis, referenced_ty);
}

/// 递归检查语义类型子树中是否引用了可见性低于 `src_vis` 的名义类型。
fn checkTyExposureRecursive(
    db: *Database,
    src_vis: Visibility,
    ty: TypeId,
) PlatformError!?DefId {
    return switch (db.types.get(ty)) {
        .err, .quest, .ideal_int, .ideal_float, .prim, .type_param => null,
        .class_this => |def_id| blk: {
            const target = try db.getDef(def_id);
            break :blk if (!src_vis.isNoMoreOpenThan(target.effective_vis)) def_id else null;
        },
        .cpointer => |inner| checkTyExposureRecursive(db, src_vis, inner),
        .varray => |v| checkTyExposureRecursive(db, src_vis, v.elem),
        .tuple => |list_id| blk: {
            for (db.types.getList(list_id)) |elem| {
                if (try checkTyExposureRecursive(db, src_vis, elem)) |bad| break :blk bad;
            }
            break :blk null;
        },
        .func => |f| blk: {
            for (db.types.getList(f.params)) |p| {
                if (try checkTyExposureRecursive(db, src_vis, p)) |bad| break :blk bad;
            }
            break :blk try checkTyExposureRecursive(db, src_vis, f.ret);
        },
        .nominal => |n| blk: {
            const target = try db.getDef(n.def);
            if (!src_vis.isNoMoreOpenThan(target.effective_vis)) break :blk n.def;
            for (db.types.getList(n.args)) |arg| {
                if (try checkTyExposureRecursive(db, src_vis, arg)) |bad| break :blk bad;
            }
            break :blk null;
        },
    };
}

/// 计算声明 `def` 的可达文件范围域 `AccessDomain`，专用于 `Database.references` 缩小跨文件扫描范围。
pub fn effectiveDomain(db: *Database, def: DefId) PlatformError!AccessDomain {
    const entry = try db.getDef(def);
    const pkg_state = try db.packageState(def.pkg);
    const vis = Visibility.min(entry.effective_vis, pkg_state.pkg_vis);

    if (entry.declared_vis == .private) {
        if (entry.owner) |owner_def| return .{ .def_body = owner_def };
        if (entry.source_file) |sf| return .{ .file_only = sf };
    }
    return switch (vis) {
        .private => if (entry.source_file) |sf| .{ .file_only = sf } else .{ .package_subtree = def.pkg },
        .internal => if (pkg_state.pkg_vis == .internal)
            .{ .package_subtree_and_parent = def.pkg }
        else
            .{ .package_subtree = def.pkg },
        .protected => if (entry.owner) |owner_def|
            .{ .module_and_subclasses = .{ .module = pkg_state.module_id, .owner = owner_def } }
        else
            .{ .module_only = pkg_state.module_id },
        .public => .everywhere,
    };
}

/// 判定切片中是否包含目标 `DefId`。
fn containsDef(slice: []const DefId, target: DefId) bool {
    for (slice) |d| {
        if (DefId.eql(d, target)) return true;
    }
    return false;
}

/// 判定类型声明 `sub_def` 是否等于 `super_def` 或为其后代子类。
fn isSubclassOf(
    db: *Database,
    file_id: common.FileId,
    sub_def: DefId,
    super_def: DefId,
) PlatformError!bool {
    if (DefId.eql(sub_def, super_def)) return true;
    var cur = sub_def;
    var guard: u32 = 0;
    while (guard < 64) : (guard += 1) {
        const entry = try db.getDef(cur);
        if (entry.kind != .class_) return false;
        const header = db.nominalHeaderOf(cur) catch return false;
        if (header.supertypes.len == 0) return false;
        const first_super = db.types.get(header.supertypes[0]);
        if (first_super != .nominal) return false;
        const parent_def = first_super.nominal.def;
        if (DefId.eql(parent_def, super_def)) return true;
        const parent_entry = db.getDef(parent_def) catch return false;
        if (parent_entry.kind != .class_) return false;
        cur = parent_def;
        _ = file_id;
    }
    return false;
}

/// 判定名义类型 `target_def` 在指定文件 `file_id` 中是否处于可见或已导入状态。
fn isTypeVisibleInFile(
    db: *Database,
    file_id: common.FileId,
    resolve_data: *const @import("scope.zig").FileResolveData,
    target_def: DefId,
) PlatformError!bool {
    if (resolve_data.pkg_id == target_def.pkg) return true;
    if (db.types.known.std_core_pkg == target_def.pkg) return true;
    for (resolve_data.glob_import_pkgs) |gp| {
        if (gp == target_def.pkg) return true;
    }
    var it = resolve_data.explicit_imports.valueIterator();
    while (it.next()) |entries| {
        for (entries.*) |exp| {
            if (DefId.eql(exp.def, target_def)) return true;
        }
    }
    var pkg_it = resolve_data.explicit_pkg_imports.valueIterator();
    while (pkg_it.next()) |pkg| {
        if (pkg.* == target_def.pkg) return true;
    }
    _ = file_id;
    return false;
}
