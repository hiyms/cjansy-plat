// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 增量按需语义分析数据库（`Database`）：三级内存池管理、两级增量失效编排、
//! 传递下游包失效、三色环路截断推导与对外聚合视图查询入口。

const std = @import("std");
const common = @import("common");
const frontend = @import("frontend");
const ids = @import("../ids.zig");
const string_interner_mod = @import("../interner/StringInterner.zig");
const type_interner_mod = @import("../interner/TypeInterner.zig");
const file_state_mod = @import("FileState.zig");
const pkg_state_mod = @import("PackageState.zig");
const preload_mod = @import("PreloadIndex.zig");
const scope_mod = @import("../resolve/scope.zig");
const package_mod = @import("../resolve/package.zig");
const file_resolve_mod = @import("../resolve/file.zig");
const checker_mod = @import("../typeck/checker.zig");
const syntax_node_mod = @import("../view/SyntaxNode.zig");
const symbol_view_mod = @import("../view/SymbolView.zig");
const scope_view_mod = @import("../view/ScopeView.zig");
const queries_mod = @import("../view/Queries.zig");

const CallableHeaderSig = pkg_state_mod.CallableHeaderSig;
const CallableRef = ids.CallableRef;
const CompletionCandidate = queries_mod.CompletionCandidate;
const DefEntry = pkg_state_mod.DefEntry;
const DefId = ids.DefId;
const FileQueryState = file_state_mod.FileQueryState;
const FileResolveData = scope_mod.FileResolveData;
const GlobalItemId = ids.GlobalItemId;
const InternedId = ids.InternedId;
const ItemTypeckData = checker_mod.ItemTypeckData;
const Location = queries_mod.Location;
const NominalHeader = pkg_state_mod.NominalHeader;
const PackageId = ids.PackageId;
const PackageIndexProvider = preload_mod.PackageIndexProvider;
const PackageInterner = string_interner_mod.PackageInterner;
const PackageState = pkg_state_mod.PackageState;
const PlatformError = file_state_mod.PlatformError;
const ScopeView = scope_view_mod.ScopeView;
const StringInterner = string_interner_mod.StringInterner;
const SymbolRef = ids.SymbolRef;
const SymbolView = symbol_view_mod.SymbolView;
const SyntaxNode = syntax_node_mod.SyntaxNode;
const TargetConfig = type_interner_mod.TargetConfig;
const TypeAliasHeader = pkg_state_mod.TypeAliasHeader;
const TypeId = ids.TypeId;
const TypeInterner = type_interner_mod.TypeInterner;
const TypeView = symbol_view_mod.TypeView;

/// 跨项按需推导三色状态机，截断未标注类型的直接递归与相互递归环路。
pub const InferState = union(enum) {
    uncomputed,
    computing,
    computed: TypeId,
};

/// 跨项省略类型依赖观测记录，供 `typeCheckItem` 执行按需依赖校验。
pub const InferredDep = struct {
    def: DefId,
    observed_ty: TypeId,
    kind: enum(u8) { return_ty, var_ty },
};

/// `Database` 初始化配置。
pub const DatabaseConfig = struct {
    target: TargetConfig = .{},
    default_pkg_name: []const u8 = "default",
    /// 外部预编译标准库索引加载器；在 `Database.init` 阶段一次性挂载 `std.core` 并固定 `KnownDefs`。
    preload_provider: ?PackageIndexProvider = null,
    /// 单文件跨项重算超过该次数时自动重置该文件 `sema_arena` 以控制内存水位。
    sema_recheck_reset_threshold: u32 = 32,
    /// `TypeInterner` 驻留类型数超过该上限时自动在下次 `updateFile` 边界触发 `gcTypes` 回收历史世代类型。
    type_interner_gc_threshold: u32 = 131072,
};

/// 面向 LSP、格式化与静态检查平台的增量按需语义分析数据库。
pub const Database = struct {
    gpa: std.mem.Allocator,
    config: DatabaseConfig,
    source: common.Source,
    strings: StringInterner,
    pkg_interner: PackageInterner,
    types: TypeInterner,

    file_states: std.AutoHashMapUnmanaged(common.FileId, *FileQueryState) = .empty,
    packages: std.AutoHashMapUnmanaged(PackageId, *PackageState) = .empty,
    /// 记录各包的最新世代号（即使旧 `PackageState` 已销毁仍单调递增，避免重建复用旧世代号）。
    pkg_generations: std.AutoHashMapUnmanaged(PackageId, u32) = .empty,
    /// 反向依赖图：上游 `PackageId` -> 直接导入它的下游 `PackageId` 列表（结构变更执行传递闭包失效）。
    reverse_pkg_deps: std.AutoHashMapUnmanaged(PackageId, std.ArrayListUnmanaged(PackageId)) = .empty,
    /// 正在构建中的包集合与临时状态指针（用于检测跨包循环依赖并避免本包声明头消解重入 `buildPackageState`）。
    building_pkgs: std.AutoHashMapUnmanaged(PackageId, void) = .empty,
    building_pkg_states: std.AutoHashMapUnmanaged(PackageId, *PackageState) = .empty,

    /// 跨文件省略返回类型与省略绑定类型的记忆化推导缓存（键含 `DefId.pkg_gen`）。
    inferred_ret_cache: std.AutoHashMapUnmanaged(DefId, InferState) = .empty,
    inferred_var_cache: std.AutoHashMapUnmanaged(DefId, InferState) = .empty,
    /// 类型别名展开三色缓存（拦截循环 `type A = B; type B = A`）。
    type_alias_cache: std.AutoHashMapUnmanaged(DefId, InferState) = .empty,

    /// 递增修订版本号，标记工作区发生过修改，避免同一查询周期内重复遍历 `inferred_deps`。
    revision: u64 = 0,

    // --- 生命周期管理 ---

    /// 初始化分析数据库与三级内存基础设施；挂载预编译或内置最小 `std.core` 并绑定 `types.known`。
    pub fn init(gpa: std.mem.Allocator, config: DatabaseConfig) PlatformError!Database {
        var db: Database = .{
            .gpa = gpa,
            .config = config,
            .source = common.Source.init(gpa),
            .strings = StringInterner.init(gpa),
            .pkg_interner = PackageInterner.init(gpa),
            .types = try TypeInterner.init(gpa, config.target),
        };
        errdefer db.deinit();

        try db.mountStdCore();
        return db;
    }

    /// 释放全部文件状态、包状态、驻留池与 `common.Source`。
    pub fn deinit(self: *Database) void {
        var fs_it = self.file_states.valueIterator();
        while (fs_it.next()) |fs| {
            fs.*.deinit();
            self.gpa.destroy(fs.*);
        }
        self.file_states.deinit(self.gpa);

        var pkg_it = self.packages.valueIterator();
        while (pkg_it.next()) |ps| {
            ps.*.deinit();
            self.gpa.destroy(ps.*);
        }
        self.packages.deinit(self.gpa);
        self.pkg_generations.deinit(self.gpa);

        var rev_it = self.reverse_pkg_deps.valueIterator();
        while (rev_it.next()) |list| list.deinit(self.gpa);
        self.reverse_pkg_deps.deinit(self.gpa);

        self.building_pkgs.deinit(self.gpa);
        self.building_pkg_states.deinit(self.gpa);
        self.inferred_ret_cache.deinit(self.gpa);
        self.inferred_var_cache.deinit(self.gpa);
        self.type_alias_cache.deinit(self.gpa);

        self.types.deinit();
        self.pkg_interner.deinit();
        self.strings.deinit();
        self.source.deinit();
        self.* = undefined;
    }

    /// 挂载 `std.core`（优先调用外部 `preload_provider`，否则使用内置最小引导包）。
    fn mountStdCore(self: *Database) PlatformError!void {
        if (self.config.preload_provider) |prov| {
            const s_std = try self.strings.intern("std");
            const s_core = try self.strings.intern("core");
            const core_pkg = try self.pkg_interner.internPackage(null, &.{ s_std, s_core });
            if (prov.vtable.hasPackage(prov.ptr, self, core_pkg)) {
                if (try prov.vtable.loadPackage(prov.ptr, self, core_pkg)) |ps| {
                    errdefer {
                        ps.deinit();
                        self.gpa.destroy(ps);
                    }
                    try self.pkg_generations.put(self.gpa, core_pkg, ps.generation);
                    try self.packages.put(self.gpa, core_pkg, ps);
                    self.bindKnownDefsFromPackage(ps);
                    return;
                }
            }
        }
        try preload_mod.bootstrapBuiltinCore(self);
    }

    /// 从已加载的 `std.core` 或 `std.sync` 预编译包中按标准名称绑定 `types.known` 句柄。
    fn bindKnownDefsFromPackage(self: *Database, ps: *const PackageState) void {
        const info = self.pkg_interner.getPackage(ps.pkg_id);
        if (info.segments.len == 2 and
            std.mem.eql(u8, self.strings.get(info.segments[0]), "std") and
            std.mem.eql(u8, self.strings.get(info.segments[1]), "core"))
        {
            self.types.known.std_core_pkg = ps.pkg_id;
            for (ps.defs) |de| {
                if (de.owner != null) continue;
                const nm = self.strings.get(de.name);
                if (std.mem.eql(u8, nm, "Any")) self.types.known.any_iface = de.id else if (std.mem.eql(u8, nm, "CType")) self.types.known.ctype_iface = de.id else if (std.mem.eql(u8, nm, "Object")) self.types.known.object_class = de.id else if (std.mem.eql(u8, nm, "String")) self.types.known.string_struct = de.id else if (std.mem.eql(u8, nm, "Array")) self.types.known.array_struct = de.id else if (std.mem.eql(u8, nm, "Option")) self.types.known.option_enum = de.id else if (std.mem.eql(u8, nm, "Range")) self.types.known.range_struct = de.id else if (std.mem.eql(u8, nm, "Iterable")) self.types.known.iterable_iface = de.id else if (std.mem.eql(u8, nm, "Iterator")) self.types.known.iterator_iface = de.id else if (std.mem.eql(u8, nm, "ToString")) self.types.known.to_string_iface = de.id else if (std.mem.eql(u8, nm, "Equatable")) self.types.known.equatable_iface = de.id else if (std.mem.eql(u8, nm, "Comparable")) self.types.known.comparable_iface = de.id else if (std.mem.eql(u8, nm, "Countable")) self.types.known.countable_iface = de.id else if (std.mem.eql(u8, nm, "Resource")) self.types.known.resource_iface = de.id else if (std.mem.eql(u8, nm, "Exception")) self.types.known.exception_class = de.id else if (std.mem.eql(u8, nm, "Error")) self.types.known.error_class = de.id else if (std.mem.eql(u8, nm, "ThreadContext")) self.types.known.thread_context_iface = de.id else if (std.mem.eql(u8, nm, "Future")) self.types.known.future_class = de.id;
            }
            if (self.types.known.option_enum) |opt_def| {
                if (ps.getDef(opt_def.idx)) |oe| {
                    for (oe.members) |m| {
                        if (ps.getDef(m.idx)) |me| {
                            const nm = self.strings.get(me.name);
                            if (std.mem.eql(u8, nm, "Some")) self.types.known.option_some = m;
                            if (std.mem.eql(u8, nm, "None")) self.types.known.option_none = m;
                        }
                    }
                }
            }
        } else if (info.segments.len == 2 and
            std.mem.eql(u8, self.strings.get(info.segments[0]), "std") and
            std.mem.eql(u8, self.strings.get(info.segments[1]), "sync") and
            self.types.known.lock_iface == null)
        {
            for (ps.defs) |de| {
                if (de.owner == null and std.mem.eql(u8, self.strings.get(de.name), "Lock")) {
                    self.types.known.lock_iface = de.id;
                    break;
                }
            }
        }
    }

    /// 回收历史世代残留类型，依次执行四步清理：
    /// 1. 清空推导与别名缓存，对全部活动文件调用 `invalidateSemaAndView()`；
    /// 2. 销毁 `Database.packages` 中全部 `PackageState` 并对非预编译包递增 `pkg_generations`；
    /// 3. 调用 `types.resetKeepingBuiltins()` 并重置 `types.known`；
    /// 4. 重新挂载 `std.core` 并重新绑定核心 `types.known` 句柄。
    pub fn gcTypes(self: *Database) PlatformError!void {
        // 1. 清空推导缓存并失效全部文件语义层与视图层
        self.inferred_ret_cache.clearRetainingCapacity();
        self.inferred_var_cache.clearRetainingCapacity();
        self.type_alias_cache.clearRetainingCapacity();

        var fs_it = self.file_states.valueIterator();
        while (fs_it.next()) |fs| fs.*.invalidateSemaAndView();

        // 2. 先预留并更新全部非预编译包的世代号，再无失败地销毁全部 PackageState 与反向依赖图
        try self.pkg_generations.ensureUnusedCapacity(self.gpa, @intCast(self.packages.count()));
        var pkg_it = self.packages.iterator();
        while (pkg_it.next()) |kv| {
            const ps = kv.value_ptr.*;
            if (!ps.is_preloaded) {
                const next_gen = (self.pkg_generations.get(kv.key_ptr.*) orelse ps.generation) + 1;
                self.pkg_generations.putAssumeCapacity(kv.key_ptr.*, next_gen);
            }
        }
        var destroy_it = self.packages.valueIterator();
        while (destroy_it.next()) |ps_ptr| {
            ps_ptr.*.deinit();
            self.gpa.destroy(ps_ptr.*);
        }
        self.packages.clearRetainingCapacity();

        var rev_it = self.reverse_pkg_deps.valueIterator();
        while (rev_it.next()) |list| list.deinit(self.gpa);
        self.reverse_pkg_deps.clearRetainingCapacity();

        // 3. 重置 TypeInterner（仅保留固定基础类型槽位）并复位 KnownDefs
        try self.types.resetKeepingBuiltins();
        self.types.known = .{};

        // 4. 重新挂载 std.core 并重新绑定核心 KnownDefs
        try self.mountStdCore();
        self.revision +%= 1;
    }

    /// 注册反向包依赖边：`downstream` 直接依赖 `upstream`。
    pub fn registerReversePkgDep(self: *Database, upstream: PackageId, downstream: PackageId) std.mem.Allocator.Error!void {
        if (upstream == downstream) return;
        const gop = try self.reverse_pkg_deps.getOrPut(self.gpa, upstream);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |existing| {
            if (existing == downstream) return;
        }
        try gop.value_ptr.append(self.gpa, downstream);
    }

    // --- 文件同步 ---

    /// 注册可编辑工作区文件，返回带代次校验的 `FileId`。
    pub fn addWorkspaceFile(
        self: *Database,
        path: ?[]const u8,
        text: []const u8,
        extra: common.FileExtraInfo,
    ) PlatformError!common.FileId {
        const fid = try self.source.addWorkspace(path, text, extra);
        errdefer self.source.remove(fid) catch {};
        try self.attachNewFileState(fid);
        return fid;
    }

    /// 注册只读外部文件（如依赖包源码或 `.cj.d` 声明文件）。
    pub fn addExternalFile(
        self: *Database,
        path: []const u8,
        text: []const u8,
        extra: common.FileExtraInfo,
    ) PlatformError!common.FileId {
        const fid = try self.source.addExternal(path, text, extra);
        errdefer self.source.remove(fid) catch {};
        try self.attachNewFileState(fid);
        return fid;
    }

    /// 为新加入文件创建 `FileQueryState` 并对其所属包及其下游执行结构失效。
    fn attachNewFileState(self: *Database, fid: common.FileId) PlatformError!void {
        const fs = try self.gpa.create(FileQueryState);
        fs.* = FileQueryState.init(self.gpa, fid);
        errdefer {
            fs.deinit();
            self.gpa.destroy(fs);
        }
        try self.file_states.put(self.gpa, fid, fs);
        errdefer _ = self.file_states.fetchRemove(fid);

        const pkg = try self.packageOfFile(fid);
        fs.last_pkg = pkg;
        const st = try self.parse(fid);
        const lowered = try self.lower(fid);
        fs.last_decl_fp = file_state_mod.computeDeclFingerprint(st, lowered);

        try self.invalidatePackageTransitive(pkg);
        self.revision +%= 1;
    }

    /// 移除文件，清理其推导缓存、文件状态并对受影响包及其传递下游包执行失效。
    pub fn removeFile(self: *Database, file: common.FileId) PlatformError!void {
        const fs = self.file_states.get(file) orelse return error.InvalidFileId;
        const old_pkg = fs.last_pkg;
        if (old_pkg) |op| {
            self.purgeFileInferredCaches(op, file);
        }
        _ = self.file_states.fetchRemove(file);
        fs.deinit();
        self.gpa.destroy(fs);

        try self.source.remove(file);
        if (old_pkg) |op| {
            try self.invalidatePackageTransitive(op);
        }
        self.revision +%= 1;
    }

    /// 应用一批按 `start` 升序且互不重叠的增量编辑并执行两级增量失效。
    pub fn updateFile(
        self: *Database,
        file: common.FileId,
        edits: []const common.Edit,
    ) PlatformError!void {
        if (edits.len == 0) return;
        const fs = self.file_states.get(file) orelse return error.InvalidFileId;
        const cur_text = try self.source.content(file);

        // 1. 前置原文等值短路
        var all_same = true;
        for (edits) |e| {
            if (e.range.start > e.range.end or e.range.end > cur_text.len) {
                all_same = false;
                break;
            }
            if (!std.mem.eql(u8, cur_text[e.range.start..e.range.end], e.new_text)) {
                all_same = false;
                break;
            }
        }
        if (all_same) return;

        // 2. 清理本文件在推导缓存中的旧条目
        const old_pkg = fs.last_pkg;
        const old_fp = fs.last_decl_fp;
        if (old_pkg) |op| {
            self.purgeFileInferredCaches(op, file);
        }

        // 3. 写入源码并重置本文件三级隔离内存池
        try self.source.applyEdits(file, edits);
        fs.invalidateAll();
        self.revision +%= 1;

        // 4. 触发类型池阈值回收（如超过配置上限）
        if (self.types.count() > self.config.type_interner_gc_threshold) {
            try self.gcTypes();
        }

        // 5. 比较新旧包归属与声明头摘要指纹，执行快速路径或结构变更路径
        const new_st = try self.parse(file);
        const new_lowered = try self.lower(file);
        const new_pkg = try self.packageOfFile(file);
        const new_fp = file_state_mod.computeDeclFingerprint(new_st, new_lowered);

        fs.last_pkg = new_pkg;
        fs.last_decl_fp = new_fp;

        const same_pkg = old_pkg != null and old_pkg.? == new_pkg;
        const same_fp = old_fp != null and old_fp.? == new_fp;

        if (!same_pkg or !same_fp) {
            if (old_pkg) |op| try self.invalidatePackageTransitive(op);
            if (!same_pkg) try self.invalidatePackageTransitive(new_pkg);
        } else if (old_pkg) |op| {
            // 快速路径：PackageState 与 DefId 保持有效，但清理本包及下游包的省略类型推导缓存，
            // 使跨文件引用被修改函数体的省略类型声明在下次查询时能观察到最新推导结果。
            try self.purgeTransitiveInferredCaches(op);
        }
    }

    /// 清理指定包及沿 `reverse_pkg_deps` 传递可达下游包中全部声明在省略类型推导缓存中的条目
    /// （不销毁 `PackageState`、不失效 `FileResolveData`，供快速路径维持跨文件推导一致性）。
    fn purgeTransitiveInferredCaches(self: *Database, root_pkg: PackageId) std.mem.Allocator.Error!void {
        var affected: std.AutoHashMapUnmanaged(PackageId, void) = .empty;
        defer affected.deinit(self.gpa);
        var queue: std.ArrayListUnmanaged(PackageId) = .empty;
        defer queue.deinit(self.gpa);

        try affected.put(self.gpa, root_pkg, {});
        try queue.append(self.gpa, root_pkg);

        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const cur = queue.items[head];
            if (self.reverse_pkg_deps.get(cur)) |downstream| {
                for (downstream.items) |dp| {
                    if (!affected.contains(dp)) {
                        try affected.put(self.gpa, dp, {});
                        try queue.append(self.gpa, dp);
                    }
                }
            }
        }

        var it = affected.keyIterator();
        while (it.next()) |pkg_ptr| {
            const ps = self.packages.get(pkg_ptr.*) orelse continue;
            if (ps.is_preloaded) continue;
            for (ps.defs) |de| {
                _ = self.inferred_ret_cache.fetchRemove(de.id);
                _ = self.inferred_var_cache.fetchRemove(de.id);
            }
        }
    }

    /// 清理指定文件在跨项推导缓存中的全部条目（按存活 `PackageState.file_defs` 精确删除）。
    fn purgeFileInferredCaches(self: *Database, pkg: PackageId, file: common.FileId) void {
        const ps = self.packages.get(pkg) orelse return;
        const defs = ps.file_defs.get(file) orelse return;
        for (defs) |def_id| {
            _ = self.inferred_ret_cache.fetchRemove(def_id);
            _ = self.inferred_var_cache.fetchRemove(def_id);
            _ = self.type_alias_cache.fetchRemove(def_id);
        }
    }

    /// 沿 `reverse_pkg_deps` 计算传递可达下游包集合，销毁其中全部非预编译 `PackageState`、
    /// 清理相关推导缓存并对其下所有文件调用 `invalidateSemaAndView()`。
    fn invalidatePackageTransitive(self: *Database, root_pkg: PackageId) std.mem.Allocator.Error!void {
        var affected: std.AutoHashMapUnmanaged(PackageId, void) = .empty;
        defer affected.deinit(self.gpa);
        var queue: std.ArrayListUnmanaged(PackageId) = .empty;
        defer queue.deinit(self.gpa);

        try affected.put(self.gpa, root_pkg, {});
        try queue.append(self.gpa, root_pkg);

        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const cur = queue.items[head];
            if (self.reverse_pkg_deps.get(cur)) |downstream| {
                for (downstream.items) |dp| {
                    if (!affected.contains(dp)) {
                        try affected.put(self.gpa, dp, {});
                        try queue.append(self.gpa, dp);
                    }
                }
            }
        }

        // 销毁受影响非预编译包并清理对应推导缓存
        var aff_it = affected.keyIterator();
        while (aff_it.next()) |pkg_ptr| {
            const pkg = pkg_ptr.*;
            if (self.packages.get(pkg)) |ps| {
                if (ps.is_preloaded) continue;
                for (ps.defs) |de| {
                    _ = self.inferred_ret_cache.fetchRemove(de.id);
                    _ = self.inferred_var_cache.fetchRemove(de.id);
                    _ = self.type_alias_cache.fetchRemove(de.id);
                }
                _ = self.packages.fetchRemove(pkg);
                ps.deinit();
                self.gpa.destroy(ps);
            }
        }

        // 对受影响包下的所有文件执行语义层与视图层失效
        var fs_it = self.file_states.valueIterator();
        while (fs_it.next()) |fs_ptr| {
            const fs = fs_ptr.*;
            if (fs.last_pkg) |lp| {
                if (affected.contains(lp)) {
                    fs.invalidateSemaAndView();
                }
            }
        }
    }

    // --- 源码与语法树只读透传 API ---

    /// 获取文件当前只读文本切片；借用自 `Database.source`，在下次 `updateFile`/`removeFile` 前有效，调用者不得释放。
    pub fn fileContent(self: *Database, file: common.FileId) PlatformError![]const u8 {
        return self.source.content(file);
    }

    /// 获取文件根只读 `SyntaxNode` 视图；底层 `GreenNode` 借用自 `FileQueryState.ast_hir_arena`，调用者不得释放。
    pub fn syntaxRoot(self: *Database, file: common.FileId) PlatformError!SyntaxNode {
        const st = try self.parse(file);
        return .{
            .green = st.tree.root,
            .file = file,
            .version = st.version,
            .offset = 0,
        };
    }

    /// 字节位置转行列号（列号按 UTF-8 字节计数）。
    pub fn positionOf(self: *Database, file: common.FileId, offset: u32) PlatformError!common.Position {
        return self.source.positionOf(file, offset);
    }

    /// 行列号转字节位置。
    pub fn offsetOf(self: *Database, file: common.FileId, pos: common.Position) PlatformError!u32 {
        return self.source.offsetOf(file, pos);
    }

    /// 获取指定行的半开字节区间（含末尾换行符）。
    pub fn lineRange(self: *Database, file: common.FileId, line: u32) PlatformError!common.TextRange {
        return self.source.lineRange(file, line);
    }

    // --- 核心按需查询 API ---

    /// 解析单文件为无损 `SyntaxTree`；底层绿树借用自 `FileQueryState.ast_hir_arena`，在下次编辑或移除该文件前有效，调用者不得释放。
    pub fn parse(self: *Database, file: common.FileId) PlatformError!common.SyntaxTree {
        const fs = self.file_states.get(file) orelse return error.InvalidFileId;
        const src_file = self.source.get(file) orelse return error.InvalidFileId;
        if (fs.cached_version == src_file.version) {
            if (fs.syntax_tree) |st| return st;
        } else {
            fs.invalidateAll();
        }

        const text = src_file.content();
        const a = fs.ast_hir_arena.allocator();

        var tokens: std.ArrayListUnmanaged(common.Token) = .empty;
        defer tokens.deinit(self.gpa);

        var lex = try frontend.lexer.Lexer.new(text);
        while (true) {
            const tok = try lex.gen();
            try tokens.append(self.gpa, tok);
            if (tok.tag == .end) break;
        }

        var parser = frontend.parser.Parser.new(self.gpa, text, tokens.items);
        defer parser.deinit();
        try parser.parse();

        const green = try frontend.treeBuild(self.gpa, a, text, parser.events.items);
        const st: common.SyntaxTree = .{
            .file = file,
            .version = src_file.version,
            .tree = green,
        };

        var diags: std.ArrayListUnmanaged(common.Diagnostic) = .empty;
        for (parser.errors.items) |perr| {
            try diags.append(a, try perr.toDiagnostic(a, file, text));
        }

        fs.cached_version = src_file.version;
        fs.syntax_tree = st;
        fs.parse_diagnostics = try diags.toOwnedSlice(a);
        return st;
    }

    /// 将单文件降低为 `LoweredFile` 并填充 `GreenToHirMap`；返回指针借用自 `FileQueryState.ast_hir_arena`，调用者不得释放。
    pub fn lower(self: *Database, file: common.FileId) PlatformError!*const frontend.LoweredFile {
        const st = try self.parse(file);
        const fs = self.file_states.get(file) orelse return error.InvalidFileId;
        if (fs.lowered) |*lf| return lf;

        const a = fs.ast_hir_arena.allocator();
        fs.green_to_hir = .empty;
        fs.lowered = try frontend.lowerFile(self.gpa, a, st, &fs.green_to_hir);
        return &fs.lowered.?;
    }

    /// 获取单文件 `GreenToHirMap` 只读指针；借用自 `FileQueryState.ast_hir_arena`，调用者不得释放。
    pub fn greenToHir(self: *Database, file: common.FileId) PlatformError!*const common.GreenToHirMap {
        _ = try self.lower(file);
        const fs = self.file_states.get(file) orelse return error.InvalidFileId;
        return &fs.green_to_hir;
    }

    /// 查询文件所属 `PackageId`（无 `package` 头时归入 `config.default_pkg_name`）。
    pub fn packageOfFile(self: *Database, file: common.FileId) PlatformError!PackageId {
        const lowered = try self.lower(file);
        if (lowered.hir_file.package) |ph| {
            const org_id: ?InternedId = if (ph.org) |o| try self.strings.intern(o.text) else null;
            const segs = try self.gpa.alloc(InternedId, ph.name.len);
            defer self.gpa.free(segs);
            for (ph.name, 0..) |seg, i| {
                segs[i] = try self.strings.intern(seg.text);
            }
            return self.pkg_interner.internPackage(org_id, segs);
        }
        const def_seg = try self.strings.intern(self.config.default_pkg_name);
        return self.pkg_interner.internPackage(null, &.{def_seg});
    }

    /// 构建或获取包级世代状态 `PackageState`（支持经 `preload_provider` 懒加载预编译包）；
    /// 返回指针借用自 `Database.packages`，在该包重建前有效，调用者不得释放。
    pub fn packageState(self: *Database, pkg: PackageId) PlatformError!*const PackageState {
        if (self.packages.get(pkg)) |ps| return ps;
        if (self.building_pkg_states.get(pkg)) |ps| return ps;

        // 优先尝试从外部预编译索引懒加载
        if (self.config.preload_provider) |prov| {
            if (prov.vtable.hasPackage(prov.ptr, self, pkg)) {
                if (try prov.vtable.loadPackage(prov.ptr, self, pkg)) |ps| {
                    errdefer {
                        ps.deinit();
                        self.gpa.destroy(ps);
                    }
                    try self.pkg_generations.put(self.gpa, pkg, ps.generation);
                    try self.packages.put(self.gpa, pkg, ps);
                    self.bindKnownDefsFromPackage(ps);
                    return ps;
                }
            }
        }

        const ps = try package_mod.buildPackageState(self, pkg);
        errdefer {
            ps.deinit();
            self.gpa.destroy(ps);
        }
        try self.packages.put(self.gpa, pkg, ps);
        return ps;
    }

    /// 获取单文件词法早绑定产物 `FileResolveData`；返回指针借用自 `FileQueryState.sema_arena`，调用者不得释放。
    pub fn resolve(self: *Database, file: common.FileId) PlatformError!*const FileResolveData {
        _ = try self.lower(file);
        const fs = self.file_states.get(file) orelse return error.InvalidFileId;
        if (fs.resolve_data) |rd| return rd;
        const rd = try file_resolve_mod.resolveFile(self, file);
        fs.resolve_data = rd;
        return rd;
    }

    /// 校验 `def.pkg_gen` 与 `def.idx` 后返回只读 `DefEntry`；借用自所属 `PackageState.arena`，调用者不得释放。
    /// 世代不符或索引越界返回 `error.InvalidDefId`。
    pub fn getDef(self: *Database, def: DefId) PlatformError!*const DefEntry {
        const ps = try self.packageState(def.pkg);
        if (ps.generation != def.pkg_gen) return error.InvalidDefId;
        return ps.getDef(def.idx) orelse error.InvalidDefId;
    }

    /// 获取名义类型的继承、泛型约束与文档注释头 `NominalHeader`；借用自所属 `PackageState.arena`，调用者不得释放。
    pub fn nominalHeaderOf(self: *Database, def: DefId) PlatformError!*const NominalHeader {
        const ps = try self.packageState(def.pkg);
        if (ps.generation != def.pkg_gen) return error.InvalidDefId;
        return ps.nominal_headers.get(def.idx) orelse error.InvalidDefId;
    }

    /// 获取类型别名的完整头信息 `TypeAliasHeader`（含展开目标与文档注释）；借用自所属 `PackageState.arena`，调用者不得释放。
    pub fn typeAliasHeaderOf(self: *Database, def: DefId) PlatformError!*const TypeAliasHeader {
        const ps = try self.packageState(def.pkg);
        if (ps.generation != def.pkg_gen) return error.InvalidDefId;
        return ps.type_alias_headers.get(def.idx) orelse error.InvalidDefId;
    }

    /// 获取包级或局部可调用声明的头部签名 `CallableHeaderSig`；
    /// 包级借用自 `PackageState.arena`，局部借用自 `FileQueryState.sema_arena`，调用者不得释放。
    pub fn callableHeaderSig(self: *Database, ref: CallableRef) PlatformError!*const CallableHeaderSig {
        switch (ref) {
            .def => |d| {
                const ps = try self.packageState(d.pkg);
                if (ps.generation != d.pkg_gen) return error.InvalidDefId;
                return ps.callable_headers.get(d.idx) orelse error.InvalidDefId;
            },
            .local => |l| {
                const rd = try self.resolve(l.global_item.file);
                const loc = rd.getLocal(l.idx) orelse return error.InvalidDefId;
                const sidx = loc.callable_sig_idx orelse return error.InvalidDefId;
                return rd.getLocalCallable(sidx) orelse error.InvalidDefId;
            },
        }
    }

    /// 获取属性声明 `prop` 的显式类型 `TypeId`。
    pub fn propTypeOf(self: *Database, def: DefId) PlatformError!TypeId {
        const ps = try self.packageState(def.pkg);
        if (ps.generation != def.pkg_gen) return error.InvalidDefId;
        return ps.prop_types.get(def.idx) orelse error.InvalidDefId;
    }

    /// 按需获取函数、方法或构造器的返回类型：显式标注时 `O(1)` 返回；
    /// 省略返回类型时触发按需推导与三色环路截断。
    pub fn returnTypeOf(self: *Database, def: DefId) PlatformError!TypeId {
        const sig = try self.callableHeaderSig(.{ .def = def });
        if (sig.explicit_ret) |er| return er;

        if (self.inferred_ret_cache.get(def)) |st| {
            return switch (st) {
                .computed => |ty| ty,
                .computing => TypeInterner.err_ty,
                .uncomputed => unreachable,
            };
        }

        try self.inferred_ret_cache.put(self.gpa, def, .computing);
        const inferred = checker_mod.inferFuncReturnType(self, def) catch |err| {
            _ = self.inferred_ret_cache.fetchRemove(def);
            return err;
        };
        try self.inferred_ret_cache.put(self.gpa, def, .{ .computed = inferred });
        return inferred;
    }

    /// 按需获取顶层或成员 `let`/`var`/`const` 的类型：显式标注时 `O(1)` 返回；
    /// 省略类型时触发按需推导与环路截断。
    pub fn varTypeOf(self: *Database, def: DefId) PlatformError!TypeId {
        const ps = try self.packageState(def.pkg);
        if (ps.generation != def.pkg_gen) return error.InvalidDefId;
        if (ps.explicit_var_types.get(def.idx)) |et| return et;

        if (self.inferred_var_cache.get(def)) |st| {
            return switch (st) {
                .computed => |ty| ty,
                .computing => TypeInterner.err_ty,
                .uncomputed => unreachable,
            };
        }

        try self.inferred_var_cache.put(self.gpa, def, .computing);
        const inferred = checker_mod.inferVarType(self, def) catch |err| {
            _ = self.inferred_var_cache.fetchRemove(def);
            return err;
        };
        try self.inferred_var_cache.put(self.gpa, def, .{ .computed = inferred });
        return inferred;
    }

    /// 解析类型别名目标类型（优先读取三色缓存或已冻结的 `TypeAliasHeader.target`）。
    pub fn typeAliasTargetOf(self: *Database, def: DefId) PlatformError!TypeId {
        if (self.type_alias_cache.get(def)) |st| {
            return switch (st) {
                .computed => |ty| ty,
                .computing => TypeInterner.err_ty,
                .uncomputed => unreachable,
            };
        }
        const tah = try self.typeAliasHeaderOf(def);
        return tah.target;
    }

    /// 查询语义类型 `ty` 对应的文档注释正文（名义类型与 `ClassThisTy` 读取 `NominalHeader.doc`，
    /// 基础类型、`VArray` 与 `CPointer` 读取 `TypeInterner.builtinDocOf`）。
    /// 返回切片借用自 `StringInterner`，调用者不得释放；无文档注释返回 `null`。
    pub fn typeDocOf(self: *Database, ty: TypeId) PlatformError!?[]const u8 {
        switch (self.types.get(ty)) {
            .nominal => |n| {
                const nh = self.nominalHeaderOf(n.def) catch return null;
                const doc_id = nh.doc orelse return null;
                return self.strings.get(doc_id);
            },
            .class_this => |def| {
                const nh = self.nominalHeaderOf(def) catch return null;
                const doc_id = nh.doc orelse return null;
                return self.strings.get(doc_id);
            },
            else => {
                const doc_id = self.types.builtinDocOf(ty) orelse return null;
                return self.strings.get(doc_id);
            },
        }
    }

    /// 构造语义类型 `ty` 的只读展示视图 `TypeView`（包含格式化名称 `display`、`nominal_def`、`alias_def` 与文档注释 `doc`）。
    /// `display` 借用自 `file` 对应的 `view_arena`，`doc` 借用自 `StringInterner`，调用者不得释放。
    pub fn typeViewOf(self: *Database, file: common.FileId, ty: TypeId, alias_def: ?DefId) PlatformError!TypeView {
        return symbol_view_mod.buildTypeView(self, file, ty, alias_def);
    }

    /// 对单个顶层声明项执行双向类型检查与晚绑定（缓存命中前校验全部 `inferred_deps`）。
    /// 返回指针借用自所属 `FileQueryState.sema_arena`，调用者不得释放。
    pub fn typeCheckItem(self: *Database, global_item: GlobalItemId) PlatformError!*const ItemTypeckData {
        const lowered = try self.lower(global_item.file);
        const fs = self.file_states.get(global_item.file) orelse return error.InvalidFileId;
        const idx = global_item.item.index();
        if (idx >= lowered.lowered_items.len) return error.InvalidItemId;

        if (fs.item_typeck.len != lowered.lowered_items.len) {
            const slots = try fs.sema_arena.allocator().alloc(?*const ItemTypeckData, lowered.lowered_items.len);
            @memset(slots, null);
            fs.item_typeck = slots;
        }

        if (fs.item_typeck[idx]) |cached| {
            if (cached.verified_revision == self.revision) return cached;
            if (try self.verifyInferredDeps(cached.inferred_deps)) {
                @constCast(cached).verified_revision = self.revision;
                return cached;
            }
            // 跨项省略类型发生变化，局部重算；若累计次数超过阈值则重置整文件 sema_arena 控制水位
            fs.sema_recheck_count += 1;
            if (fs.sema_recheck_count > self.config.sema_recheck_reset_threshold) {
                fs.invalidateSemaAndView();
                const slots = try fs.sema_arena.allocator().alloc(?*const ItemTypeckData, lowered.lowered_items.len);
                @memset(slots, null);
                fs.item_typeck = slots;
            }
        }

        const data = try checker_mod.typeCheckItem(self, global_item);
        fs.item_typeck[idx] = data;
        return data;
    }

    /// 核验缓存声明项记录的全部 `inferred_deps` 是否仍与最新推导结果一致。
    fn verifyInferredDeps(self: *Database, deps: []const InferredDep) PlatformError!bool {
        for (deps) |dep| {
            const latest = switch (dep.kind) {
                .return_ty => self.returnTypeOf(dep.def) catch return false,
                .var_ty => self.varTypeOf(dep.def) catch return false,
            };
            if (latest != dep.observed_ty) return false;
        }
        return true;
    }

    // --- 面向消费端的聚合视图查询 API ---

    /// 定位单文件字节位置 `offset` 处的符号并返回只读 `SymbolView`。
    /// 返回值内部字符串与切片借用自 `StringInterner` 或当前文件 `view_arena`，调用者不得释放。
    pub fn symbolAt(self: *Database, file: common.FileId, offset: u32) PlatformError!?SymbolView {
        return queries_mod.symbolAt(self, file, offset);
    }

    /// 定位单文件字节位置 `offset` 处的最内层词法作用域视图 `ScopeView`。
    pub fn scopeAt(self: *Database, file: common.FileId, offset: u32) PlatformError!?ScopeView {
        const rd = try self.resolve(file);
        const s = rd.scopeAt(offset) orelse return null;
        return .{
            .db = self,
            .scope_id = s.id,
            .kind = s.kind,
            .range = s.range,
        };
    }

    /// 按目标符号的 `AccessDomain` 精准限定候选文件范围，扫描对应引用并按 `(file, range.start, range.end)` 排序返回。
    /// 返回切片由调用者传入的 `alloc` 分配，结束后须由调用者通过 `alloc.free` 释放。
    pub fn references(
        self: *Database,
        alloc: std.mem.Allocator,
        target: SymbolRef,
        include_decl: bool,
    ) PlatformError![]Location {
        return queries_mod.references(self, alloc, target, include_decl);
    }

    /// 收集指定位置的补全候选列表。
    /// 返回切片由调用者传入的 `alloc` 分配，结束后须由调用者释放；条目内文本切片借用自 `StringInterner` 与 `view_arena`。
    pub fn completionsAt(
        self: *Database,
        alloc: std.mem.Allocator,
        file: common.FileId,
        offset: u32,
    ) PlatformError![]CompletionCandidate {
        return queries_mod.completionsAt(self, alloc, file, offset);
    }

    /// 聚合单文件全部阶段诊断并按文件内位置优先稳定排序。
    /// 返回切片由调用者传入的 `alloc` 分配，结束后须由调用者释放；每条诊断的 `message` 与 `related` 借用自对应阶段内存池。
    pub fn allDiagnostics(
        self: *Database,
        alloc: std.mem.Allocator,
        file: common.FileId,
    ) PlatformError![]common.Diagnostic {
        return queries_mod.allDiagnostics(self, alloc, file);
    }
};
