// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 只读词法作用域视图（`ScopeView`）与作用域链可见符号枚举。

const std = @import("std");
const common = @import("common");
const ids = @import("../ids.zig");
const file_state_mod = @import("../db/FileState.zig");
const db_mod = @import("../db/Database.zig");
const scope_mod = @import("../resolve/scope.zig");
const access_mod = @import("../resolve/access.zig");
const queries_mod = @import("Queries.zig");

const CompletionCandidate = queries_mod.CompletionCandidate;
const Database = db_mod.Database;
const InternedId = ids.InternedId;
const PlatformError = file_state_mod.PlatformError;
const ScopeId = ids.ScopeId;
const ScopeKind = scope_mod.ScopeKind;

/// 只读词法作用域视图。
pub const ScopeView = struct {
    db: *Database,
    scope_id: ScopeId,
    kind: ScopeKind,
    range: common.TextRange,

    /// 获取直接外层作用域视图；到达最外层返回 `null`。
    pub fn parent(self: ScopeView) PlatformError!?ScopeView {
        const rd = try self.db.resolve(self.scope_id.file);
        const s = rd.getScope(self.scope_id) orelse return error.InvalidScopeId;
        const pid = s.parent orelse return null;
        const ps = rd.getScope(pid) orelse return null;
        return .{
            .db = self.db,
            .scope_id = pid,
            .kind = ps.kind,
            .range = ps.range,
        };
    }

    /// 枚举当前作用域链中在 `offset` 位置可见的全部无限定符号
    /// （遵循内层非函数遮蔽外层、同名函数保留可见重载与 `private` 穿透规则）。
    /// 返回切片由调用者传入的 `alloc` 分配，结束后须由调用者通过 `alloc.free` 释放。
    pub fn collectVisibleSymbols(
        self: ScopeView,
        alloc: std.mem.Allocator,
        offset: u32,
    ) PlatformError![]CompletionCandidate {
        const db = self.db;
        const rd = try db.resolve(self.scope_id.file);
        const pkg_state = try db.packageState(rd.pkg_id);

        var out: std.ArrayListUnmanaged(CompletionCandidate) = .empty;
        errdefer out.deinit(alloc);
        var shadowed_non_fn: std.AutoHashMapUnmanaged(InternedId, void) = .empty;
        defer shadowed_non_fn.deinit(db.gpa);
        var seen_defs: std.AutoHashMapUnmanaged(ids.DefId, void) = .empty;
        defer seen_defs.deinit(db.gpa);

        // 1. 沿局部作用域与封闭类型体作用域自内向外收集
        var cur_opt: ?ScopeId = self.scope_id;
        while (cur_opt) |sid| {
            const s = rd.getScope(sid) orelse break;
            const start = s.locals_start;
            const end = start + s.locals_len;
            var i: usize = end;
            while (i > start) {
                i -= 1;
                const loc = rd.locals[rd.scope_local_indices[i]];
                if (offset < loc.visible_from) continue;
                if (shadowed_non_fn.contains(loc.name)) continue;
                if (loc.kind != .func_) try shadowed_non_fn.put(db.gpa, loc.name, {});
                try out.append(alloc, .{
                    .target = .{ .local = loc.id },
                    .kind = loc.kind,
                    .label = db.strings.get(loc.name),
                });
            }

            if (s.kind == .type_or_extend_body) {
                if (s.owner_def) |owner_def| {
                    if (db.getDef(owner_def)) |oe| {
                        for (oe.members) |m_def| {
                            const me = db.getDef(m_def) catch continue;
                            if (shadowed_non_fn.contains(me.name) or seen_defs.contains(m_def)) continue;
                            try seen_defs.put(db.gpa, m_def, {});
                            if (me.kind != .method and me.kind != .func_) {
                                try shadowed_non_fn.put(db.gpa, me.name, {});
                            }
                            try out.append(alloc, .{
                                .target = .{ .def = m_def },
                                .kind = me.kind,
                                .label = db.strings.get(me.name),
                                .doc = if (me.doc) |d| db.strings.get(d) else null,
                            });
                        }
                    } else |_| {}
                }
            }
            cur_opt = s.parent;
        }

        // 2. 当前包顶层符号
        {
            var top_it = pkg_state.top_exports.iterator();
            while (top_it.next()) |kv| {
                if (shadowed_non_fn.contains(kv.key_ptr.*)) continue;
                for (kv.value_ptr.*) |exp| {
                    if (exp.vis == .private) {
                        if (exp.source_file == null or !common.FileId.eql(exp.source_file.?, self.scope_id.file)) continue;
                    }
                    if (seen_defs.contains(exp.def)) continue;
                    const de = db.getDef(exp.def) catch continue;
                    try seen_defs.put(db.gpa, exp.def, {});
                    try out.append(alloc, .{
                        .target = .{ .def = exp.def },
                        .kind = de.kind,
                        .label = db.strings.get(exp.exported_name),
                        .doc = if (de.doc) |d| db.strings.get(d) else null,
                    });
                }
            }
        }

        // 3. 当前文件显式导入符号与显式导入包名
        {
            var exp_it = rd.explicit_imports.iterator();
            while (exp_it.next()) |kv| {
                if (shadowed_non_fn.contains(kv.key_ptr.*)) continue;
                for (kv.value_ptr.*) |exp| {
                    if (seen_defs.contains(exp.def)) continue;
                    const de = db.getDef(exp.def) catch continue;
                    try seen_defs.put(db.gpa, exp.def, {});
                    try out.append(alloc, .{
                        .target = .{ .def = exp.def },
                        .kind = de.kind,
                        .label = db.strings.get(exp.exported_name),
                        .doc = if (de.doc) |d| db.strings.get(d) else null,
                    });
                }
            }
            var pkg_it = rd.explicit_pkg_imports.iterator();
            while (pkg_it.next()) |kv| {
                if (shadowed_non_fn.contains(kv.key_ptr.*)) continue;
                try out.append(alloc, .{
                    .target = .{ .pkg = kv.value_ptr.* },
                    .kind = .package,
                    .label = db.strings.get(kv.key_ptr.*),
                });
            }
        }

        // 4. 当前文件通配符导入包（含隐式 std.core）
        for (rd.glob_import_pkgs) |gp| {
            const ps = db.packageState(gp) catch continue;
            const rel = db.pkg_interner.relation(rd.pkg_id, gp);
            var it = ps.top_exports.iterator();
            while (it.next()) |kv| {
                if (shadowed_non_fn.contains(kv.key_ptr.*)) continue;
                for (kv.value_ptr.*) |exp| {
                    if (!access_mod.isVisibleInRelation(exp.vis, rel)) continue;
                    if (seen_defs.contains(exp.def)) continue;
                    const de = db.getDef(exp.def) catch continue;
                    try seen_defs.put(db.gpa, exp.def, {});
                    try out.append(alloc, .{
                        .target = .{ .def = exp.def },
                        .kind = de.kind,
                        .label = db.strings.get(exp.exported_name),
                        .doc = if (de.doc) |d| db.strings.get(d) else null,
                    });
                }
            }
        }

        return out.toOwnedSlice(alloc);
    }
};
