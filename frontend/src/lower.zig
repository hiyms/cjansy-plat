// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 将 Lossless Green CST 转换为高层中间表示（HIR）。
//!
//! 职责与设计约定：
//! 1. 内部不依赖 `RedNode` 或 `QueryContext`，通过 `GreenNode` 树的 `text_len` 现场累加计算每个节点的
//!    精确源码字节区间（自动剥离节点内部开头的前导空白、换行与注释 Trivia）。
//! 2. 项级独立分配 `HirId`：每次调用 `lowerItem` 时项内 `HirId` 从 `0` 顺序分配，产出的 `LoweredItem.nodes`
//!    严格满足 `nodes[i].id().index() == i`，可通过 `HirId` 以 `O(1)` 随机访问项内任意 HIR 节点。
//! 3. 容错降级（P0-7）：遇到缺损语法树、`error_node` 或非法字面量时，记录 `source = .parser` 的诊断并生成
//!    带有精确 `TextRange` 的占位 HIR 节点继续降低，仅在内存不足时返回 `std.mem.Allocator.Error`。
//! 4. 维护 `GreenToHirMap`：为声明项、语句、表达式（含字面量叶子）、语句块（`block` 与 `match` 分支体 `stmt_list`）、
//!    模式、类型、形参、枚举构造器、属性访问器、`try` 资源声明以及折叠/包装节点（`paren_expr`、`paren_type`、
//!    `trailing_closure_expr`、`quote_interpolation`、包裹了声明的 `error_node`）登记到 `HirKey` 的映射。

const std = @import("std");
const common = @import("common");

const FileId = common.FileId;
const TextRange = common.TextRange;
const SyntaxKind = common.SyntaxKind;
const GreenNode = common.GreenNode;
const LocatedGreen = common.LocatedGreen;
const SyntaxTree = common.SyntaxTree;
const Diagnostic = common.Diagnostic;
const ItemId = common.ItemId;
const HirId = common.HirId;
const HirKey = common.HirKey;
const HirNode = common.HirNode;
const GreenToHirMap = common.GreenToHirMap;

const Name = common.Name;
const Modifier = common.Modifier;
const Annotation = common.Annotation;
const BinaryOp = common.BinaryOp;
const AssignOp = common.AssignOp;
const UnaryOp = common.UnaryOp;
const IncDecOp = common.IncDecOp;
const JumpOp = common.JumpOp;
const IntSuffix = common.IntSuffix;
const FloatSuffix = common.FloatSuffix;
const BindingKind = common.BindingKind;
const StrKind = common.StrKind;

const TypePathSegment = common.TypePathSegment;
const PathType = common.PathType;
const HirTypeElement = common.HirTypeElement;
const HirType = common.HirType;

const StrText = common.StrText;
const StrInterpolation = common.StrInterpolation;
const StrPart = common.StrPart;
const ExprPathSegment = common.ExprPathSegment;
const HirCallArg = common.HirCallArg;
const ArrayElement = common.ArrayElement;
const BlockExpr = common.BlockExpr;
const LetDestructor = common.LetDestructor;
const HirCondition = common.HirCondition;
const PatternCase = common.PatternCase;
const ExprCase = common.ExprCase;
const MatchCase = common.MatchCase;
const Resource = common.Resource;
const CatchClause = common.CatchClause;
const HandleClause = common.HandleClause;
const TryClause = common.TryClause;
const QuotePart = common.QuotePart;
const MacroCall = common.MacroCall;
const ResumeModifier = common.ResumeModifier;
const HirExpr = common.HirExpr;

const HirPattern = common.HirPattern;
const Binding = common.Binding;
const ExprStmt = common.ExprStmt;
const HirStmt = common.HirStmt;

const HirParam = common.HirParam;
const ParamMacro = common.ParamMacro;
const Param = common.Param;
const FuncName = common.FuncName;
const GenericConstraint = common.GenericConstraint;
const WhereClause = common.WhereClause;

const EnumPayloadType = common.EnumPayloadType;
const EnumPayloadElement = common.EnumPayloadElement;
const EnumConstructor = common.EnumConstructor;
const VariantMacro = common.VariantMacro;
const EnumVariant = common.EnumVariant;
const PropAccessor = common.PropAccessor;
const ImportAlias = common.ImportAlias;
const ImportKind = common.ImportKind;
const ImportItem = common.ImportItem;
const PackageHeader = common.PackageHeader;
const FeatureId = common.FeatureId;
const FeaturesDirective = common.FeaturesDirective;
const HirItem = common.HirItem;
const HirFile = common.HirFile;

/// 单个顶层声明项（含其递归成员）的 Lowering 产物。
///
/// 不变式：
/// - `hir_id_start` 固定为 `.fromIndex(0)`，`hir_id_end` 为 `.fromIndex(@intCast(nodes.len))`。
/// - 对于任意 `0 <= i < nodes.len`，恒有 `nodes[i].id().index() == i`。
///
/// 指针内存约定：`item`、`nodes`、`exprs`、`diagnostics` 及其内部所有指针均由传入 `Lowerer` 的
/// `arena` 分配，随 `arena` 统一释放，调用者不得单独释放。
pub const LoweredItem = struct {
    /// 声明项句柄。
    id: ItemId,
    /// 转换后的 HIR 声明项根节点（借用自 `arena`）。
    item: *const HirItem,
    /// 项内起始 `HirId`（`0`）。
    hir_id_start: HirId,
    /// 项内结束 `HirId`（半开区间上界，等于 `nodes.len`）。
    hir_id_end: HirId,
    /// 项内按 `HirId.index()` 顺序排列的全部 HIR 节点池。
    nodes: []const HirNode,
    /// 项内按分配顺序排列的全部表达式节点切片。
    exprs: []const *const HirExpr,
    /// 本项 lowering 阶段产生的诊断列表。
    diagnostics: []const Diagnostic,

    /// 按项内 `HirId` 以 `O(1)` 获取对应的 `HirNode`；越界返回 `null`。
    ///
    /// 返回的 `HirNode` 内部指针借用自所属 `arena`，调用者不得单独释放。
    pub inline fn node(self: LoweredItem, id: HirId) ?HirNode {
        const idx = id.index();
        return if (idx < self.nodes.len) self.nodes[idx] else null;
    }

    /// 按项内 `HirId` 以 `O(1)` 获取对应的 `*const HirExpr`；越界或该节点非 `HirExpr` 时返回 `null`。
    ///
    /// 返回的指针借用自所属 `arena`，调用者不得单独释放。
    pub inline fn expr(self: LoweredItem, id: HirId) ?*const HirExpr {
        const n = self.node(id) orelse return null;
        return if (n == .expr) n.expr else null;
    }
};

/// 整个源文件（`source_file`）的 Lowering 产物。
///
/// 指针内存约定：`hir_file`、`lowered_items`、`diagnostics` 及其内部所有指针均由 `arena` 分配，
/// 随 `arena` 统一释放，调用者不得单独释放。
pub const LoweredFile = struct {
    /// 文件级 HIR 根节点（包含 `package`、`features`、`imports` 与顶层 `items`）。
    hir_file: HirFile,
    /// 与 `hir_file.items` 一一对应的顶层项详细产物，下标即为 `ItemId.index()`。
    lowered_items: []const LoweredItem,
    /// 文件级与全部项级按出现顺序汇总后的诊断列表。
    diagnostics: []const Diagnostic,

    /// 按 `HirKey` 以 `O(1)` 定位整份文件中的任意 `HirNode`；`item` 或 `hir` 越界时返回 `null`。
    ///
    /// 返回的 `HirNode` 内部指针借用自所属 `arena`，调用者不得单独释放。
    pub inline fn node(self: LoweredFile, key: HirKey) ?HirNode {
        const item_idx = key.item.index();
        if (item_idx >= self.lowered_items.len) return null;
        return self.lowered_items[item_idx].node(key.hir);
    }

    /// 按 `HirKey` 以 `O(1)` 获取对应的源码字节区间；越界返回 `null`。
    pub inline fn hirRange(self: LoweredFile, key: HirKey) ?TextRange {
        const n = self.node(key) orelse return null;
        return n.range();
    }
};

/// 将 Green CST 转换为 HIR 的降低器。
///
/// 内部不依赖 `RedNode` 或 `QueryContext`，通过 `GreenNode` 树的 `text_len` 现场累加计算每个节点的
/// 精确源码字节区间（自动剥离节点内部开头的前导空白、换行与注释 Trivia）。
///
/// 内存约定：
/// - `gpa`：仅用于 lowering 期间的临时可变工作缓冲（`nodes_buf`、`exprs_buf`、`diags_buf` 等），
///   由 `Lowerer.deinit` 释放。
/// - `arena`：用于分配最终产出的所有 HIR 节点指针、切片、`Diagnostic.message` 以及 `green_to_hir`
///   的哈希桶内存（通常传入 `File.allocator()`）；所有产出随 `arena` 统一释放，调用者不得单独释放。
pub const Lowerer = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    file: FileId,
    version: u32 = 0,
    green_to_hir: ?*GreenToHirMap = null,

    current_item: ItemId = .fromIndex(0),
    nodes_buf: std.ArrayListUnmanaged(HirNode) = .empty,
    exprs_buf: std.ArrayListUnmanaged(*const HirExpr) = .empty,
    diags_buf: std.ArrayListUnmanaged(Diagnostic) = .empty,

    /// 初始化 `Lowerer`。
    ///
    /// 指针内存约定：`green_to_hir` 为可选的可变借用指针；非空时在 lowering 过程中使用 `arena`
    /// 向其写入 `GreenNode -> HirKey` 映射。调用者使用完毕后须调用 `deinit` 释放 `Lowerer` 内部临时缓冲。
    pub fn init(
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        file: FileId,
        version: u32,
        green_to_hir: ?*GreenToHirMap,
    ) Lowerer {
        return .{
            .gpa = gpa,
            .arena = arena,
            .file = file,
            .version = version,
            .green_to_hir = green_to_hir,
        };
    }

    /// 释放 `Lowerer` 内部由 `gpa` 分配的临时工作缓冲；已写入 `arena` 的 HIR 数据与 `green_to_hir` 不受影响。
    pub fn deinit(self: *Lowerer) void {
        self.nodes_buf.deinit(self.gpa);
        self.exprs_buf.deinit(self.gpa);
        self.diags_buf.deinit(self.gpa);
        self.* = undefined;
    }

    /// 复位当前项的节点、表达式与诊断缓冲区，准备降低下一个顶层项。
    inline fn resetItemBuffers(self: *Lowerer, item_id: ItemId) void {
        self.current_item = item_id;
        self.nodes_buf.clearRetainingCapacity();
        self.exprs_buf.clearRetainingCapacity();
        self.diags_buf.clearRetainingCapacity();
    }

    /// 在项内预留下一个 `HirId` 槽位并在 `nodes_buf` 中占位，返回分配到的 `HirId`。
    fn reserveHirId(self: *Lowerer) std.mem.Allocator.Error!HirId {
        const idx: u32 = @intCast(self.nodes_buf.items.len);
        try self.nodes_buf.append(self.gpa, undefined);
        return HirId.fromIndex(idx);
    }

    /// 向已预留的 `id` 槽位回填构造完成的 `HirNode`，并可选登记 `GreenNode -> HirId` 映射。
    ///
    /// 指针内存约定：`node` 内部指针由 `self.arena` 持有，`green` 仅提取地址作为哈希键。
    fn commitNode(
        self: *Lowerer,
        id: HirId,
        node: HirNode,
        green: ?*const GreenNode,
    ) std.mem.Allocator.Error!void {
        std.debug.assert(node.id() == id);
        self.nodes_buf.items[id.index()] = node;
        if (green) |g| {
            try self.mapGreen(g, id);
        }
    }

    /// 在 `arena` 中复制 `HirItem` 切片，并同步更新 `nodes_buf` 中对应 `HirId` 的节点指针指向新切片元素。
    ///
    /// 指针内存约定：`items` 仅作只读借用；返回的切片由 `self.arena` 分配。
    fn dupeItemsAndSyncNodes(self: *Lowerer, items: []const HirItem) std.mem.Allocator.Error![]const HirItem {
        const slice = try self.arena.dupe(HirItem, items);
        for (slice) |*it| {
            self.nodes_buf.items[it.id().index()] = .{ .item = it };
        }
        return slice;
    }

    /// 在 `arena` 中复制 `HirStmt` 切片，并同步更新 `nodes_buf` 中对应 `HirId` 的节点指针指向新切片元素。
    ///
    /// 指针内存约定：`stmts` 仅作只读借用；返回的切片由 `self.arena` 分配。
    fn dupeStmtsAndSyncNodes(self: *Lowerer, stmts: []const HirStmt) std.mem.Allocator.Error![]const HirStmt {
        const slice = try self.arena.dupe(HirStmt, stmts);
        for (slice) |*st| {
            self.nodes_buf.items[st.id().index()] = .{ .stmt = st };
        }
        return slice;
    }

    /// 在 `arena` 中复制 `Param` 切片，并同步更新 `nodes_buf` 中对应 `HirId` 的节点指针指向新切片元素。
    ///
    /// 指针内存约定：`params` 仅作只读借用；返回的切片由 `self.arena` 分配。
    fn dupeParamsAndSyncNodes(self: *Lowerer, params: []const Param) std.mem.Allocator.Error![]const Param {
        const slice = try self.arena.dupe(Param, params);
        for (slice) |*p| {
            self.nodes_buf.items[p.id().index()] = .{ .param = p };
        }
        return slice;
    }

    /// 在 `arena` 中复制 `EnumVariant` 切片，并同步更新 `nodes_buf` 中对应 `HirId` 的节点指针指向新切片元素。
    ///
    /// 指针内存约定：`variants` 仅作只读借用；返回的切片由 `self.arena` 分配。
    fn dupeVariantsAndSyncNodes(self: *Lowerer, variants: []const EnumVariant) std.mem.Allocator.Error![]const EnumVariant {
        const slice = try self.arena.dupe(EnumVariant, variants);
        for (slice) |*v| {
            self.nodes_buf.items[v.id().index()] = .{ .variant = v };
        }
        return slice;
    }

    /// 在 `arena` 中复制 `PropAccessor` 切片，并同步更新 `nodes_buf` 中对应 `HirId` 的节点指针指向新切片元素。
    ///
    /// 指针内存约定：`accessors` 仅作只读借用；返回的切片由 `self.arena` 分配。
    fn dupeAccessorsAndSyncNodes(self: *Lowerer, accessors: []const PropAccessor) std.mem.Allocator.Error![]const PropAccessor {
        const slice = try self.arena.dupe(PropAccessor, accessors);
        for (slice) |*acc| {
            self.nodes_buf.items[acc.id.index()] = .{ .prop_accessor = acc };
        }
        return slice;
    }

    /// 在 `arena` 中复制 `Resource` 切片，并同步更新 `nodes_buf` 中对应 `HirId` 的节点指针指向新切片元素。
    ///
    /// 指针内存约定：`resources` 仅作只读借用；返回的切片由 `self.arena` 分配。
    fn dupeResourcesAndSyncNodes(self: *Lowerer, resources: []const Resource) std.mem.Allocator.Error![]const Resource {
        const slice = try self.arena.dupe(Resource, resources);
        for (slice) |*res| {
            self.nodes_buf.items[res.id.index()] = .{ .resource = res };
        }
        return slice;
    }

    /// 在 `arena` 中复制 `HirType` 切片，并同步更新 `nodes_buf` 中对应 `HirId` 的节点指针指向新切片元素。
    ///
    /// 指针内存约定：`types` 仅作只读借用；返回的切片由 `self.arena` 分配。
    fn dupeTypesAndSyncNodes(self: *Lowerer, types: []const HirType) std.mem.Allocator.Error![]const HirType {
        const slice = try self.arena.dupe(HirType, types);
        for (slice) |*ty| {
            self.nodes_buf.items[ty.id().index()] = .{ .ty = ty };
        }
        return slice;
    }

    /// 在 `arena` 中复制 `HirPattern` 切片，并同步更新 `nodes_buf` 中对应 `HirId` 的节点指针指向新切片元素。
    ///
    /// 指针内存约定：`pats` 仅作只读借用；返回的切片由 `self.arena` 分配。
    fn dupePatternsAndSyncNodes(self: *Lowerer, pats: []const HirPattern) std.mem.Allocator.Error![]const HirPattern {
        const slice = try self.arena.dupe(HirPattern, pats);
        for (slice) |*pat| {
            self.nodes_buf.items[pat.id().index()] = .{ .pattern = pat };
        }
        return slice;
    }

    /// 在 `arena` 中复制 `HirExpr` 切片，并同步更新 `nodes_buf` 中对应 `HirId` 的节点指针指向新切片元素。
    ///
    /// 指针内存约定：`exprs` 仅作只读借用；返回的切片由 `self.arena` 分配。
    fn dupeExprsAndSyncNodes(self: *Lowerer, exprs: []const HirExpr) std.mem.Allocator.Error![]const HirExpr {
        const slice = try self.arena.dupe(HirExpr, exprs);
        for (slice) |*ex| {
            self.nodes_buf.items[ex.id().index()] = .{ .expr = ex };
        }
        return slice;
    }

    /// 若配置了 `green_to_hir`，将 `green` 节点映射到当前项的 `hir_id`。
    ///
    /// 指针内存约定：`green` 仅提取地址作为哈希键，桶内存由 `self.arena` 分配。
    inline fn mapGreen(
        self: *Lowerer,
        green: *const GreenNode,
        hir_id: HirId,
    ) std.mem.Allocator.Error!void {
        if (self.green_to_hir) |m| {
            try m.put(self.arena, green, self.current_item, hir_id);
        }
    }

    /// 记录一条 lowering 阶段的诊断（`source = .parser`、`severity = .err`）。
    ///
    /// 指针内存约定：`message` 须为编译期静态字符串或由 `self.arena` 分配的切片。
    fn emitDiagnostic(
        self: *Lowerer,
        range: TextRange,
        message: []const u8,
    ) std.mem.Allocator.Error!void {
        try self.diags_buf.append(self.gpa, .{
            .file = self.file,
            .range = range,
            .severity = .err,
            .source = .parser,
            .message = message,
            .related = &.{},
        });
    }

    /// 将单个顶层或独立声明项的 `GreenNode` 子树降低为 `LoweredItem`。
    ///
    /// 每次调用都会将项内 `HirId` 计数器重置为 `0`，确保项内 `HirId` 从 `0` 顺序分配。
    /// 遇到缺损语法树、`error_node` 或非法字面量（如空十六进制 `0x`、非法字符转义）时，
    /// 记录 `source = .parser` 的诊断并生成占位 HIR 节点继续处理，仅在内存不足时返回 `Allocator.Error`。
    ///
    /// 指针内存约定：`item_green` 仅作只读借用（但其节点地址会记入 `green_to_hir`）；
    /// 返回的 `LoweredItem` 中所有指针与切片均由 `self.arena` 分配，随 `arena` 统一释放，调用者不得单独释放。
    pub fn lowerItem(
        self: *Lowerer,
        item_id: ItemId,
        item_green: *const GreenNode,
        item_start_offset: u32,
    ) std.mem.Allocator.Error!LoweredItem {
        self.resetItemBuffers(item_id);

        const item_ptr = try self.lowerItemNode(item_green, item_start_offset);
        self.exprs_buf.clearRetainingCapacity();
        for (self.nodes_buf.items) |n| {
            if (n == .expr) {
                try self.exprs_buf.append(self.gpa, n.expr);
            }
        }
        const nodes_slice = try self.arena.dupe(HirNode, self.nodes_buf.items);
        const exprs_slice = try self.arena.dupe(*const HirExpr, self.exprs_buf.items);
        const diags_slice = try self.arena.dupe(Diagnostic, self.diags_buf.items);

        return .{
            .id = item_id,
            .item = item_ptr,
            .hir_id_start = .fromIndex(0),
            .hir_id_end = .fromIndex(@intCast(nodes_slice.len)),
            .nodes = nodes_slice,
            .exprs = exprs_slice,
            .diagnostics = diags_slice,
        };
    }

    /// 将整棵 `source_file` 绿树降低为 `LoweredFile`。
    ///
    /// 指针内存约定：`root` 仅作只读借用；返回的 `LoweredFile` 中所有指针与切片均由 `self.arena` 分配，
    /// 随 `arena` 统一释放，调用者不得单独释放。
    pub fn lowerFile(
        self: *Lowerer,
        root: *const GreenNode,
    ) std.mem.Allocator.Error!LoweredFile {
        var pkg: ?PackageHeader = null;
        var feats: ?FeaturesDirective = null;
        var imports_list: std.ArrayListUnmanaged(ImportItem) = .empty;
        defer imports_list.deinit(self.gpa);

        var items_list: std.ArrayListUnmanaged(HirItem) = .empty;
        defer items_list.deinit(self.gpa);

        var lowered_items_list: std.ArrayListUnmanaged(LoweredItem) = .empty;
        defer lowered_items_list.deinit(self.gpa);

        var all_diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
        defer all_diags.deinit(self.gpa);

        var offset: u32 = 0;
        for (root.children()) |child| {
            const child_start = offset;
            offset +|= child.text_len;

            if (isTriviaOrPunct(child.kind)) continue;

            // 若顶层节点是被 error_node 包裹的错位头部指令（features/package/import），提取其内层节点
            const unwrapped = unwrapHeaderDirective(child, child_start);
            switch (unwrapped.green.kind) {
                .features_directive => {
                    self.diags_buf.clearRetainingCapacity();
                    feats = try self.lowerFeaturesDirective(unwrapped.green, unwrapped.start);
                    try all_diags.appendSlice(self.gpa, self.diags_buf.items);
                },
                .package_header => {
                    self.diags_buf.clearRetainingCapacity();
                    pkg = try self.lowerPackageHeader(unwrapped.green, unwrapped.start);
                    try all_diags.appendSlice(self.gpa, self.diags_buf.items);
                },
                .import_spec => {
                    self.diags_buf.clearRetainingCapacity();
                    const imp = try self.lowerImportSpec(unwrapped.green, unwrapped.start);
                    try imports_list.append(self.gpa, imp);
                    try all_diags.appendSlice(self.gpa, self.diags_buf.items);
                },
                else => {
                    if (isDeclOrWrappedDecl(child)) {
                        const item_id = ItemId.fromIndex(@intCast(lowered_items_list.items.len));
                        const lowered = try self.lowerItem(item_id, child, child_start);
                        try lowered_items_list.append(self.gpa, lowered);
                        try items_list.append(self.gpa, lowered.item.*);
                        try all_diags.appendSlice(self.gpa, lowered.diagnostics);
                    }
                },
            }
        }

        const imports_slice = try self.arena.dupe(ImportItem, imports_list.items);
        const items_slice = try self.arena.dupe(HirItem, items_list.items);
        // 同步更新 lowered_items[i].item 与 nodes[0] 指向 items_slice[i]
        for (lowered_items_list.items, 0..) |*li, i| {
            li.item = &items_slice[i];
            if (li.nodes.len > 0) {
                @constCast(li.nodes)[0] = .{ .item = &items_slice[i] };
            }
        }
        const lowered_items_slice = try self.arena.dupe(LoweredItem, lowered_items_list.items);
        const diags_slice = try self.arena.dupe(Diagnostic, all_diags.items);

        return .{
            .hir_file = .{
                .file = self.file,
                .version = self.version,
                .package = pkg,
                .features = feats,
                .imports = imports_slice,
                .items = items_slice,
            },
            .lowered_items = lowered_items_slice,
            .diagnostics = diags_slice,
        };
    }

    // =========================================================================
    // 文件头部：FeaturesDirective / PackageHeader / ImportItem
    // =========================================================================

    /// 降低 `features_directive` 节点。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的切片由 `self.arena` 分配。
    fn lowerFeaturesDirective(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!FeaturesDirective {
        var features: std.ArrayListUnmanaged(FeatureId) = .empty;
        defer features.deinit(self.gpa);

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .features_set) {
                var set_off = c_start;
                for (child.children()) |f_child| {
                    const f_start = set_off;
                    set_off +|= f_child.text_len;
                    if (f_child.kind == .feature_id) {
                        const fid = try self.lowerFeatureId(f_child, f_start);
                        try features.append(self.gpa, fid);
                    }
                }
            }
        }

        return .{
            .features = try self.arena.dupe(FeatureId, features.items),
            .range = trimmedRange(green, start_offset),
        };
    }

    /// 降低单个 `feature_id` 节点。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `segments` 切片由 `self.arena` 分配。
    fn lowerFeatureId(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!FeatureId {
        var segs: std.ArrayListUnmanaged(Name) = .empty;
        defer segs.deinit(self.gpa);

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (isNameTokenKind(child.kind)) {
                try segs.append(self.gpa, extractNameFromLeaf(child, c_start));
            }
        }
        const r = trimmedRange(green, start_offset);
        if (segs.items.len == 0) {
            try segs.append(self.gpa, emptyNameAt(r.start));
        }
        return .{
            .segments = try self.arena.dupe(Name, segs.items),
            .range = r,
        };
    }

    /// 降低 `package_header` 节点。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `name` 切片由 `self.arena` 分配。
    fn lowerPackageHeader(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!PackageHeader {
        var modifier: ?Modifier = null;
        var is_macro = false;
        var org: ?Name = null;
        var names: std.ArrayListUnmanaged(Name) = .empty;
        defer names.deinit(self.gpa);

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .kw_macro) {
                is_macro = true;
            } else if (modifierFromNode(child)) |m| {
                modifier = m;
            } else if (child.kind == .package_name) {
                try self.lowerPackageNameInto(child, c_start, &org, &names);
            }
        }

        const r = trimmedRange(green, start_offset);
        if (names.items.len == 0) {
            try names.append(self.gpa, emptyNameAt(r.end));
        }
        return .{
            .modifier = modifier,
            .is_macro = is_macro,
            .org = org,
            .name = try self.arena.dupe(Name, names.items),
            .range = r,
        };
    }

    /// 解析 `package_name` 内部的可选 `org::` 与点分包名序列。
    ///
    /// 指针内存约定：`green` 仅作只读借用；`org_out` 与 `names_out` 由调用者提供。
    fn lowerPackageNameInto(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
        org_out: *?Name,
        names_out: *std.ArrayListUnmanaged(Name),
    ) std.mem.Allocator.Error!void {
        var offset = start_offset;
        const kids = green.children();
        var pending_name: ?Name = null;

        for (kids) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (isNameTokenKind(child.kind)) {
                if (pending_name) |prev| {
                    try names_out.append(self.gpa, prev);
                }
                pending_name = extractNameFromLeaf(child, c_start);
            } else if (child.kind == .double_colon) {
                if (pending_name) |prev| {
                    org_out.* = prev;
                    pending_name = null;
                }
            }
        }
        if (pending_name) |last| {
            try names_out.append(self.gpa, last);
        }
    }

    /// 降低 `import_spec` 节点。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的切片由 `self.arena` 分配。
    fn lowerImportSpec(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!ImportItem {
        var modifier: ?Modifier = null;
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);

        var content_node: ?LocatedGreen = null;
        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .annotation) {
                try annos.append(self.gpa, try self.lowerAnnotation(child, c_start));
            } else if (modifierFromNode(child)) |m| {
                modifier = m;
            } else if (child.kind == .import_content) {
                content_node = .{ .green = child, .start = c_start };
            }
        }

        const r = trimmedRange(green, start_offset);
        const annos_slice = try self.arena.dupe(Annotation, annos.items);
        if (content_node) |cn| {
            var item = try self.lowerImportContent(cn.green, cn.start);
            item.modifier = modifier;
            item.annotations = annos_slice;
            item.range = r;
            return item;
        }
        return .{
            .modifier = modifier,
            .annotations = annos_slice,
            .kind = .{ .single = emptyNameAt(r.end) },
            .range = r,
        };
    }

    /// 降低 `import_content` 节点（支持 single / alias / glob / group 四种形态）。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的切片由 `self.arena` 分配。
    fn lowerImportContent(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!ImportItem {
        var org: ?Name = null;
        var segs: std.ArrayListUnmanaged(Name) = .empty;
        defer segs.deinit(self.gpa);
        var group_items: std.ArrayListUnmanaged(ImportItem) = .empty;
        defer group_items.deinit(self.gpa);

        var has_glob = false;
        var has_group = false;
        var seen_as = false;
        var alias_name: ?Name = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .double_colon) {
                if (segs.items.len > 0 and org == null) {
                    org = segs.pop().?;
                }
            } else if (child.kind == .kw_as) {
                seen_as = true;
            } else if (child.kind == .mul) {
                has_glob = true;
            } else if (child.kind == .import_content) {
                has_group = true;
                try group_items.append(self.gpa, try self.lowerImportContent(child, c_start));
            } else if (isNameTokenKind(child.kind)) {
                const nm = extractNameFromLeaf(child, c_start);
                if (seen_as and alias_name == null) {
                    alias_name = nm;
                } else {
                    try segs.append(self.gpa, nm);
                }
            }
        }

        const r = trimmedRange(green, start_offset);
        if (has_group) {
            return .{
                .org = org,
                .prefix = try self.arena.dupe(Name, segs.items),
                .kind = .{ .group = try self.arena.dupe(ImportItem, group_items.items) },
                .range = r,
            };
        }
        if (has_glob) {
            return .{
                .org = org,
                .prefix = try self.arena.dupe(Name, segs.items),
                .kind = .{ .glob = {} },
                .range = r,
            };
        }
        const target_name = if (segs.items.len > 0) segs.pop().? else emptyNameAt(r.end);
        const prefix_slice = try self.arena.dupe(Name, segs.items);
        if (alias_name) |al| {
            return .{
                .org = org,
                .prefix = prefix_slice,
                .kind = .{ .alias = .{ .name = target_name, .alias = al } },
                .range = r,
            };
        }
        return .{
            .org = org,
            .prefix = prefix_slice,
            .kind = .{ .single = target_name },
            .range = r,
        };
    }

    // =========================================================================
    // 注解与宏调用头部
    // =========================================================================

    /// 降低内置注解节点 `annotation`（`@Name` 或 `@a.b.Name[args]`）。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的切片由 `self.arena` 分配。
    fn lowerAnnotation(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!Annotation {
        var path: std.ArrayListUnmanaged(Name) = .empty;
        defer path.deinit(self.gpa);
        var args: std.ArrayListUnmanaged(HirCallArg) = .empty;
        defer args.deinit(self.gpa);

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (isNameTokenKind(child.kind)) {
                try path.append(self.gpa, extractNameFromLeaf(child, c_start));
            } else if (child.kind == .func_arg) {
                try args.append(self.gpa, try self.lowerCallArg(child, c_start));
            }
        }
        const r = trimmedRange(green, start_offset);
        if (path.items.len == 0) {
            try path.append(self.gpa, emptyNameAt(r.start));
        }
        return .{
            .path = try self.arena.dupe(Name, path.items),
            .args = try self.arena.dupe(HirCallArg, args.items),
            .range = r,
        };
    }

    // =========================================================================
    // 声明项（HirItem）
    // =========================================================================

    /// 降低单个声明项节点，分配 `HirId` 并写入 `nodes_buf` 与 `GreenToHirMap`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const HirItem` 由 `self.arena` 分配。
    fn lowerItemNode(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!*const HirItem {
        if (green.kind == .error_node) {
            if (findWrappedDeclChild(green, start_offset)) |inner| {
                const item_ptr = try self.lowerItemNode(inner.green, inner.start);
                try self.mapGreen(green, item_ptr.id());
                return item_ptr;
            }
        }

        const id = try self.reserveHirId();
        const item_val = try self.buildItemValue(id, green, start_offset);
        const item_ptr = try self.arena.create(HirItem);
        item_ptr.* = item_val;
        try self.commitNode(id, .{ .item = item_ptr }, green);
        return item_ptr;
    }

    /// 降低作为语句出现的局部声明项（`HirStmt.item`），与内层 `HirItem` 共用同一 `HirId`，
    /// 在 `nodes_buf` 中占据唯一的 `.stmt` 槽位。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const HirStmt` 由 `self.arena` 分配。
    fn lowerStmtItemNode(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!HirStmt {
        if (green.kind == .error_node) {
            if (findWrappedDeclChild(green, start_offset)) |inner| {
                const stmt = try self.lowerStmtItemNode(inner.green, inner.start);
                try self.mapGreen(green, stmt.id());
                return stmt;
            }
        }

        const id = try self.reserveHirId();
        const item_val = try self.buildItemValue(id, green, start_offset);
        const stmt_ptr = try self.arena.create(HirStmt);
        stmt_ptr.* = .{ .item = item_val };
        try self.commitNode(id, .{ .stmt = stmt_ptr }, green);
        if (green.kind != .error_node) {
            try self.mapGreen(green, id);
        }
        return stmt_ptr.*;
    }

    /// 根据 `green.kind` 构建带有指定 `id` 的 `HirItem` 值。
    ///
    /// 指针内存约定：`green` 仅作只读借用；内部所有子指针与切片由 `self.arena` 分配。
    fn buildItemValue(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!HirItem {
        return switch (green.kind) {
            .func_decl => .{ .func = try self.lowerFuncItem(id, green, start_offset) },
            .main_decl => .{ .main = try self.lowerMainItem(id, green, start_offset) },
            .class_decl => .{ .class = try self.lowerClassItem(id, green, start_offset) },
            .struct_decl => .{ .struct_ = try self.lowerStructItem(id, green, start_offset) },
            .enum_decl => .{ .enum_ = try self.lowerEnumItem(id, green, start_offset) },
            .interface_decl => .{ .interface = try self.lowerInterfaceItem(id, green, start_offset) },
            .extend_decl => .{ .extend_ = try self.lowerExtendItem(id, green, start_offset) },
            .prop_decl => .{ .prop = try self.lowerPropItem(id, green, start_offset) },
            .type_alias_decl => .{ .type_alias = try self.lowerTypeAliasItem(id, green, start_offset) },
            .init_decl => .{ .init = try self.lowerInitItem(id, green, start_offset) },
            .finalizer_decl => .{ .finalizer = try self.lowerFinalizerItem(id, green, start_offset) },
            .primary_ctor_decl => .{ .primary_ctor = try self.lowerPrimaryCtorItem(id, green, start_offset) },
            .var_decl => .{ .binding = try self.lowerBindingPayload(id, green, start_offset) },
            .foreign_decl => .{ .foreign = try self.lowerForeignItem(id, green, start_offset) },
            .macro_decl => .{ .macro_ = try self.lowerMacroItem(id, green, start_offset) },
            .macro_expand_decl => .{ .macro_expand = try self.lowerMacroExpandItem(id, green, start_offset) },
            else => blk: {
                const r = trimmedRange(green, start_offset);
                const dummy_pat = try self.allocPlaceholderPattern(r);
                break :blk .{ .binding = .{
                    .id = id,
                    .kind = .let_,
                    .pattern = dummy_pat,
                    .range = r,
                } };
            },
        };
    }

    /// 降低 `func_decl` 为 `FuncItem`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `FuncItem` 内部所有指针与切片由 `self.arena` 分配。
    fn lowerFuncItem(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.FuncItem {
        var mods: std.ArrayListUnmanaged(Modifier) = .empty;
        defer mods.deinit(self.gpa);
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);

        var seen_kw_func = false;
        var func_name: ?FuncName = null;
        var pending_op_start: ?u32 = null;
        var pending_op_kind: ?SyntaxKind = null;
        var type_params: []const Name = &.{};
        var params: []const Param = &.{};
        var is_variadic = false;
        var ret_type: ?*const HirType = null;
        var where_clause: ?*const WhereClause = null;
        var body: ?*const BlockExpr = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;

            switch (child.kind) {
                .annotation => try annos.append(self.gpa, try self.lowerAnnotation(child, c_start)),
                .kw_func => seen_kw_func = true,
                .type_parameter_list => type_params = try self.lowerTypeParameterList(child, c_start),
                .func_param_list => {
                    const pl = try self.lowerFuncParamList(child, c_start);
                    params = pl.params;
                    is_variadic = pl.is_variadic;
                },
                .ret_type => ret_type = try self.lowerRetType(child, c_start),
                .where_clause => where_clause = try self.lowerWhereClause(child, c_start),
                .block => body = try self.lowerBlockNode(child, c_start),
                else => {
                    if (!seen_kw_func) {
                        if (modifierFromNode(child)) |m| {
                            try mods.append(self.gpa, m);
                        }
                    } else if (func_name == null and child.isLeaf() and !isTriviaKind(child.kind)) {
                        if (isNameTokenKind(child.kind)) {
                            func_name = .{ .ident = extractNameFromLeaf(child, c_start) };
                        } else if (child.kind == .l_paren or child.kind == .l_square) {
                            pending_op_start = c_start;
                            pending_op_kind = child.kind;
                        } else if ((pending_op_kind == .l_paren and child.kind == .r_paren) or
                            (pending_op_kind == .l_square and child.kind == .r_square))
                        {
                            const op_text = if (pending_op_kind == .l_paren) "()" else "[]";
                            func_name = .{ .operator = .{
                                .text = op_text,
                                .is_raw = false,
                                .range = .{ .start = pending_op_start.?, .end = c_start + child.text_len },
                            } };
                            pending_op_kind = null;
                        } else if (isOverloadableOpKind(child.kind)) {
                            func_name = .{ .operator = .{
                                .text = child.tokenText() orelse "",
                                .is_raw = false,
                                .range = .{ .start = c_start, .end = c_start + child.text_len },
                            } };
                        }
                    }
                },
            }
        }

        const r = trimmedRange(green, start_offset);
        return .{
            .id = id,
            .modifiers = try self.arena.dupe(Modifier, mods.items),
            .annotations = try self.arena.dupe(Annotation, annos.items),
            .name = func_name orelse .{ .ident = emptyNameAt(r.start) },
            .type_params = type_params,
            .params = params,
            .is_variadic = is_variadic,
            .ret_type = ret_type,
            .where_clause = where_clause,
            .body = body,
            .range = r,
        };
    }

    /// 降低 `main_decl` 为 `MainItem`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `MainItem` 内部所有指针与切片由 `self.arena` 分配。
    fn lowerMainItem(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.MainItem {
        var mods: std.ArrayListUnmanaged(Modifier) = .empty;
        defer mods.deinit(self.gpa);
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);

        var params: []const Param = &.{};
        var is_variadic = false;
        var ret_type: ?*const HirType = null;
        var body: ?*const BlockExpr = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .annotation) {
                try annos.append(self.gpa, try self.lowerAnnotation(child, c_start));
            } else if (modifierFromNode(child)) |m| {
                try mods.append(self.gpa, m);
            } else switch (child.kind) {
                .func_param_list => {
                    const pl = try self.lowerFuncParamList(child, c_start);
                    params = pl.params;
                    is_variadic = pl.is_variadic;
                },
                .ret_type => ret_type = try self.lowerRetType(child, c_start),
                .block => body = try self.lowerBlockNode(child, c_start),
                else => {},
            }
        }

        const r = trimmedRange(green, start_offset);
        const body_ptr = body orelse try self.allocPlaceholderBlock(.{ .start = r.end, .end = r.end });
        return .{
            .id = id,
            .modifiers = try self.arena.dupe(Modifier, mods.items),
            .annotations = try self.arena.dupe(Annotation, annos.items),
            .params = params,
            .is_variadic = is_variadic,
            .ret_type = ret_type,
            .body = body_ptr,
            .range = r,
        };
    }

    /// 降低 `class_decl` 为 `ClassItem`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `ClassItem` 内部所有指针与切片由 `self.arena` 分配。
    fn lowerClassItem(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.ClassItem {
        var mods: std.ArrayListUnmanaged(Modifier) = .empty;
        defer mods.deinit(self.gpa);
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);
        var supertypes: std.ArrayListUnmanaged(HirType) = .empty;
        defer supertypes.deinit(self.gpa);

        var seen_kw = false;
        var seen_upperbound = false;
        var name: ?Name = null;
        var type_params: []const Name = &.{};
        var where_clause: ?*const WhereClause = null;
        var members: []const HirItem = &.{};

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            switch (child.kind) {
                .annotation => try annos.append(self.gpa, try self.lowerAnnotation(child, c_start)),
                .kw_class => seen_kw = true,
                .type_parameter_list => type_params = try self.lowerTypeParameterList(child, c_start),
                .upperbound => seen_upperbound = true,
                .where_clause => {
                    seen_upperbound = false;
                    where_clause = try self.lowerWhereClause(child, c_start);
                },
                .class_body => {
                    seen_upperbound = false;
                    members = try self.lowerMemberBody(child, c_start);
                },
                else => {
                    if (seen_upperbound and isTypeSyntaxKind(child.kind)) {
                        const ty_ptr = try self.lowerTypeNode(child, c_start);
                        try supertypes.append(self.gpa, ty_ptr.*);
                    } else if (!seen_kw) {
                        if (modifierFromNode(child)) |m| {
                            try mods.append(self.gpa, m);
                        }
                    } else if (name == null and isNameTokenKind(child.kind)) {
                        name = extractNameFromLeaf(child, c_start);
                    }
                },
            }
        }

        const r = trimmedRange(green, start_offset);
        return .{
            .id = id,
            .modifiers = try self.arena.dupe(Modifier, mods.items),
            .annotations = try self.arena.dupe(Annotation, annos.items),
            .name = name orelse emptyNameAt(r.start),
            .type_params = type_params,
            .supertypes = try self.dupeTypesAndSyncNodes(supertypes.items),
            .where_clause = where_clause,
            .members = members,
            .range = r,
        };
    }

    /// 降低 `struct_decl` 为 `StructItem`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `StructItem` 内部所有指针与切片由 `self.arena` 分配。
    fn lowerStructItem(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.StructItem {
        var mods: std.ArrayListUnmanaged(Modifier) = .empty;
        defer mods.deinit(self.gpa);
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);
        var interfaces: std.ArrayListUnmanaged(HirType) = .empty;
        defer interfaces.deinit(self.gpa);

        var seen_kw = false;
        var seen_upperbound = false;
        var name: ?Name = null;
        var type_params: []const Name = &.{};
        var where_clause: ?*const WhereClause = null;
        var members: []const HirItem = &.{};

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            switch (child.kind) {
                .annotation => try annos.append(self.gpa, try self.lowerAnnotation(child, c_start)),
                .kw_struct => seen_kw = true,
                .type_parameter_list => type_params = try self.lowerTypeParameterList(child, c_start),
                .upperbound => seen_upperbound = true,
                .where_clause => {
                    seen_upperbound = false;
                    where_clause = try self.lowerWhereClause(child, c_start);
                },
                .struct_body => {
                    seen_upperbound = false;
                    members = try self.lowerMemberBody(child, c_start);
                },
                else => {
                    if (seen_upperbound and isTypeSyntaxKind(child.kind)) {
                        const ty_ptr = try self.lowerTypeNode(child, c_start);
                        try interfaces.append(self.gpa, ty_ptr.*);
                    } else if (!seen_kw) {
                        if (modifierFromNode(child)) |m| {
                            try mods.append(self.gpa, m);
                        }
                    } else if (name == null and isNameTokenKind(child.kind)) {
                        name = extractNameFromLeaf(child, c_start);
                    }
                },
            }
        }

        const r = trimmedRange(green, start_offset);
        return .{
            .id = id,
            .modifiers = try self.arena.dupe(Modifier, mods.items),
            .annotations = try self.arena.dupe(Annotation, annos.items),
            .name = name orelse emptyNameAt(r.start),
            .type_params = type_params,
            .interfaces = try self.dupeTypesAndSyncNodes(interfaces.items),
            .where_clause = where_clause,
            .members = members,
            .range = r,
        };
    }

    /// 降低 `interface_decl` 为 `InterfaceItem`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `InterfaceItem` 内部所有指针与切片由 `self.arena` 分配。
    fn lowerInterfaceItem(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.InterfaceItem {
        var mods: std.ArrayListUnmanaged(Modifier) = .empty;
        defer mods.deinit(self.gpa);
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);
        var interfaces: std.ArrayListUnmanaged(HirType) = .empty;
        defer interfaces.deinit(self.gpa);

        var seen_kw = false;
        var seen_upperbound = false;
        var name: ?Name = null;
        var type_params: []const Name = &.{};
        var where_clause: ?*const WhereClause = null;
        var members: []const HirItem = &.{};

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            switch (child.kind) {
                .annotation => try annos.append(self.gpa, try self.lowerAnnotation(child, c_start)),
                .kw_interface => seen_kw = true,
                .type_parameter_list => type_params = try self.lowerTypeParameterList(child, c_start),
                .upperbound => seen_upperbound = true,
                .where_clause => {
                    seen_upperbound = false;
                    where_clause = try self.lowerWhereClause(child, c_start);
                },
                .interface_body => {
                    seen_upperbound = false;
                    members = try self.lowerMemberBody(child, c_start);
                },
                else => {
                    if (seen_upperbound and isTypeSyntaxKind(child.kind)) {
                        const ty_ptr = try self.lowerTypeNode(child, c_start);
                        try interfaces.append(self.gpa, ty_ptr.*);
                    } else if (!seen_kw) {
                        if (modifierFromNode(child)) |m| {
                            try mods.append(self.gpa, m);
                        }
                    } else if (name == null and isNameTokenKind(child.kind)) {
                        name = extractNameFromLeaf(child, c_start);
                    }
                },
            }
        }

        const r = trimmedRange(green, start_offset);
        return .{
            .id = id,
            .modifiers = try self.arena.dupe(Modifier, mods.items),
            .annotations = try self.arena.dupe(Annotation, annos.items),
            .name = name orelse emptyNameAt(r.start),
            .type_params = type_params,
            .interfaces = try self.dupeTypesAndSyncNodes(interfaces.items),
            .where_clause = where_clause,
            .members = members,
            .range = r,
        };
    }

    /// 降低 `enum_decl` 为 `EnumItem`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `EnumItem` 内部所有指针与切片由 `self.arena` 分配。
    fn lowerEnumItem(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.EnumItem {
        var mods: std.ArrayListUnmanaged(Modifier) = .empty;
        defer mods.deinit(self.gpa);
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);
        var interfaces: std.ArrayListUnmanaged(HirType) = .empty;
        defer interfaces.deinit(self.gpa);
        var variants: std.ArrayListUnmanaged(EnumVariant) = .empty;
        defer variants.deinit(self.gpa);
        var members: std.ArrayListUnmanaged(HirItem) = .empty;
        defer members.deinit(self.gpa);

        var seen_kw = false;
        var seen_upperbound = false;
        var name: ?Name = null;
        var type_params: []const Name = &.{};
        var where_clause: ?*const WhereClause = null;
        var is_non_exhaustive = false;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            switch (child.kind) {
                .annotation => try annos.append(self.gpa, try self.lowerAnnotation(child, c_start)),
                .kw_enum => seen_kw = true,
                .type_parameter_list => type_params = try self.lowerTypeParameterList(child, c_start),
                .upperbound => seen_upperbound = true,
                .where_clause => {
                    seen_upperbound = false;
                    where_clause = try self.lowerWhereClause(child, c_start);
                },
                .enum_body => {
                    seen_upperbound = false;
                    var body_off = c_start;
                    for (child.children()) |b_child| {
                        const b_start = body_off;
                        body_off +|= b_child.text_len;
                        if (b_child.kind == .ellipsis) {
                            is_non_exhaustive = true;
                        } else if (b_child.kind == .enum_constructor) {
                            const v_ptr = try self.lowerEnumVariantNode(b_child, b_start);
                            try variants.append(self.gpa, v_ptr.*);
                        } else if (b_child.kind == .macro_expand_decl and isVariantMacroNode(b_child)) {
                            const v_ptr = try self.lowerEnumVariantNode(b_child, b_start);
                            try variants.append(self.gpa, v_ptr.*);
                        } else if (b_child.kind == .error_node) {
                            if (findWrappedEnumConstructor(b_child, b_start)) |inner_ctor| {
                                const v_ptr = try self.lowerEnumVariantNode(inner_ctor.green, inner_ctor.start);
                                try self.mapGreen(b_child, v_ptr.id());
                                try variants.append(self.gpa, v_ptr.*);
                            } else if (isDeclOrWrappedDecl(b_child)) {
                                const item_ptr = try self.lowerItemNode(b_child, b_start);
                                try members.append(self.gpa, item_ptr.*);
                            }
                        } else if (isDeclOrWrappedDecl(b_child)) {
                            const item_ptr = try self.lowerItemNode(b_child, b_start);
                            try members.append(self.gpa, item_ptr.*);
                        }
                    }
                },
                else => {
                    if (seen_upperbound and isTypeSyntaxKind(child.kind)) {
                        const ty_ptr = try self.lowerTypeNode(child, c_start);
                        try interfaces.append(self.gpa, ty_ptr.*);
                    } else if (!seen_kw) {
                        if (modifierFromNode(child)) |m| {
                            try mods.append(self.gpa, m);
                        }
                    } else if (name == null and isNameTokenKind(child.kind)) {
                        name = extractNameFromLeaf(child, c_start);
                    }
                },
            }
        }

        const r = trimmedRange(green, start_offset);
        return .{
            .id = id,
            .modifiers = try self.arena.dupe(Modifier, mods.items),
            .annotations = try self.arena.dupe(Annotation, annos.items),
            .name = name orelse emptyNameAt(r.start),
            .type_params = type_params,
            .interfaces = try self.dupeTypesAndSyncNodes(interfaces.items),
            .where_clause = where_clause,
            .variants = try self.dupeVariantsAndSyncNodes(variants.items),
            .is_non_exhaustive = is_non_exhaustive,
            .members = try self.dupeItemsAndSyncNodes(members.items),
            .range = r,
        };
    }

    /// 降低枚举构造器或修饰构造器的宏调用节点为 `*const EnumVariant`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const EnumVariant` 由 `self.arena` 分配。
    fn lowerEnumVariantNode(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!*const EnumVariant {
        const id = try self.reserveHirId();
        const variant_val: EnumVariant = if (green.kind == .macro_expand_decl) blk: {
            var annos: std.ArrayListUnmanaged(Annotation) = .empty;
            defer annos.deinit(self.gpa);
            var call_path: std.ArrayListUnmanaged(Name) = .empty;
            defer call_path.deinit(self.gpa);
            var has_bang = false;
            var attr_range: ?TextRange = null;
            var input_range: ?TextRange = null;
            var inner_ctor: ?*const EnumVariant = null;

            var offset = start_offset;
            for (green.children()) |child| {
                const c_start = offset;
                offset +|= child.text_len;
                if (child.kind == .annotation) {
                    try annos.append(self.gpa, try self.lowerAnnotation(child, c_start));
                } else if (child.kind == .at_excl) {
                    has_bang = true;
                } else if (isNameTokenKind(child.kind)) {
                    try call_path.append(self.gpa, extractNameFromLeaf(child, c_start));
                } else if (child.kind == .macro_attributes) {
                    attr_range = trimmedRange(child, c_start);
                } else if (child.kind == .macro_input) {
                    input_range = trimmedRange(child, c_start);
                } else if (child.kind == .enum_constructor or child.kind == .macro_expand_decl) {
                    inner_ctor = try self.lowerEnumVariantNode(child, c_start);
                }
            }
            const r = trimmedRange(green, start_offset);
            if (call_path.items.len == 0) {
                try call_path.append(self.gpa, emptyNameAt(r.start));
            }
            break :blk .{ .macro_call = .{
                .id = id,
                .annotations = try self.arena.dupe(Annotation, annos.items),
                .call = .{
                    .path = try self.arena.dupe(Name, call_path.items),
                    .has_bang = has_bang,
                    .attributes = attr_range,
                    .input = input_range,
                },
                .constructor = inner_ctor,
                .range = r,
            } };
        } else blk: {
            var annos: std.ArrayListUnmanaged(Annotation) = .empty;
            defer annos.deinit(self.gpa);
            var payload: std.ArrayListUnmanaged(EnumPayloadElement) = .empty;
            defer payload.deinit(self.gpa);
            var pending_annos: std.ArrayListUnmanaged(Annotation) = .empty;
            defer pending_annos.deinit(self.gpa);

            var name: ?Name = null;
            var in_parens = false;

            var offset = start_offset;
            for (green.children()) |child| {
                const c_start = offset;
                offset +|= child.text_len;
                if (!in_parens) {
                    if (child.kind == .annotation) {
                        try annos.append(self.gpa, try self.lowerAnnotation(child, c_start));
                    } else if (name == null and isNameTokenKind(child.kind)) {
                        name = extractNameFromLeaf(child, c_start);
                    } else if (child.kind == .l_paren) {
                        in_parens = true;
                    }
                } else {
                    if (child.kind == .annotation) {
                        try pending_annos.append(self.gpa, try self.lowerAnnotation(child, c_start));
                    } else if (child.kind == .macro_expand_param) {
                        const pm_id = try self.reserveHirId();
                        var pm = try self.lowerParamMacroPayload(child, c_start);
                        pm.id = pm_id;
                        if (pending_annos.items.len > 0) {
                            var merged: std.ArrayListUnmanaged(Annotation) = .empty;
                            defer merged.deinit(self.gpa);
                            try merged.appendSlice(self.gpa, pending_annos.items);
                            try merged.appendSlice(self.gpa, pm.annotations);
                            pm.annotations = try self.arena.dupe(Annotation, merged.items);
                            pm.range.start = pending_annos.items[0].range.start;
                        }
                        const pm_ptr = try self.arena.create(Param);
                        pm_ptr.* = .{ .macro_call = pm };
                        try self.commitNode(pm_id, .{ .param = pm_ptr }, child);
                        try payload.append(self.gpa, .{ .macro_call = pm });
                        pending_annos.clearRetainingCapacity();
                    } else if (isTypeSyntaxKind(child.kind)) {
                        const ty_ptr = try self.lowerTypeNode(child, c_start);
                        const elem_start = if (pending_annos.items.len > 0)
                            pending_annos.items[0].range.start
                        else
                            ty_ptr.range().start;
                        try payload.append(self.gpa, .{ .ty = .{
                            .annotations = try self.arena.dupe(Annotation, pending_annos.items),
                            .ty = ty_ptr,
                            .range = .{ .start = elem_start, .end = ty_ptr.range().end },
                        } });
                        pending_annos.clearRetainingCapacity();
                    }
                }
            }
            const r = trimmedRange(green, start_offset);
            break :blk .{ .constructor = .{
                .id = id,
                .annotations = try self.arena.dupe(Annotation, annos.items),
                .name = name orelse emptyNameAt(r.start),
                .payload = try self.arena.dupe(EnumPayloadElement, payload.items),
                .range = r,
            } };
        };

        const v_ptr = try self.arena.create(EnumVariant);
        v_ptr.* = variant_val;
        try self.commitNode(id, .{ .variant = v_ptr }, green);
        return v_ptr;
    }

    /// 降低 `extend_decl` 为 `ExtendItem`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `ExtendItem` 内部所有指针与切片由 `self.arena` 分配。
    fn lowerExtendItem(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.ExtendItem {
        var mods: std.ArrayListUnmanaged(Modifier) = .empty;
        defer mods.deinit(self.gpa);
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);
        var interfaces: std.ArrayListUnmanaged(HirType) = .empty;
        defer interfaces.deinit(self.gpa);

        var seen_kw = false;
        var seen_upperbound = false;
        var type_params: []const Name = &.{};
        var target: ?*const HirType = null;
        var where_clause: ?*const WhereClause = null;
        var members: []const HirItem = &.{};

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            switch (child.kind) {
                .annotation => try annos.append(self.gpa, try self.lowerAnnotation(child, c_start)),
                .kw_extend => seen_kw = true,
                .type_parameter_list => type_params = try self.lowerTypeParameterList(child, c_start),
                .upperbound => seen_upperbound = true,
                .where_clause => {
                    seen_upperbound = false;
                    where_clause = try self.lowerWhereClause(child, c_start);
                },
                .extend_body => {
                    seen_upperbound = false;
                    members = try self.lowerMemberBody(child, c_start);
                },
                else => {
                    if (isTypeSyntaxKind(child.kind)) {
                        const ty_ptr = try self.lowerTypeNode(child, c_start);
                        if (!seen_upperbound and target == null) {
                            target = ty_ptr;
                        } else {
                            try interfaces.append(self.gpa, ty_ptr.*);
                        }
                    } else if (!seen_kw) {
                        if (modifierFromNode(child)) |m| {
                            try mods.append(self.gpa, m);
                        }
                    }
                },
            }
        }

        const r = trimmedRange(green, start_offset);
        const target_ptr = target orelse try self.allocPlaceholderType(.{ .start = r.start, .end = r.start });
        return .{
            .id = id,
            .modifiers = try self.arena.dupe(Modifier, mods.items),
            .annotations = try self.arena.dupe(Annotation, annos.items),
            .type_params = type_params,
            .target = target_ptr,
            .interfaces = try self.dupeTypesAndSyncNodes(interfaces.items),
            .where_clause = where_clause,
            .members = members,
            .range = r,
        };
    }

    /// 降低 `prop_decl` 为 `PropItem`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `PropItem` 内部所有指针与切片由 `self.arena` 分配。
    fn lowerPropItem(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.PropItem {
        var mods: std.ArrayListUnmanaged(Modifier) = .empty;
        defer mods.deinit(self.gpa);
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);
        var accessors: std.ArrayListUnmanaged(PropAccessor) = .empty;
        defer accessors.deinit(self.gpa);

        var seen_kw = false;
        var name: ?Name = null;
        var ty: ?*const HirType = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            switch (child.kind) {
                .annotation => try annos.append(self.gpa, try self.lowerAnnotation(child, c_start)),
                .kw_prop => seen_kw = true,
                .prop_getter, .prop_setter => {
                    const acc_ptr = try self.lowerPropAccessorNode(child, c_start);
                    try accessors.append(self.gpa, acc_ptr.*);
                },
                else => {
                    if (ty == null and isTypeSyntaxKind(child.kind)) {
                        ty = try self.lowerTypeNode(child, c_start);
                    } else if (!seen_kw) {
                        if (modifierFromNode(child)) |m| {
                            try mods.append(self.gpa, m);
                        }
                    } else if (name == null and isNameTokenKind(child.kind)) {
                        name = extractNameFromLeaf(child, c_start);
                    }
                },
            }
        }

        const r = trimmedRange(green, start_offset);
        const ty_ptr = ty orelse try self.allocPlaceholderType(.{ .start = r.end, .end = r.end });
        return .{
            .id = id,
            .modifiers = try self.arena.dupe(Modifier, mods.items),
            .annotations = try self.arena.dupe(Annotation, annos.items),
            .name = name orelse emptyNameAt(r.start),
            .ty = ty_ptr,
            .accessors = try self.dupeAccessorsAndSyncNodes(accessors.items),
            .range = r,
        };
    }

    /// 降低 `prop_getter` 或 `prop_setter` 为 `*const PropAccessor`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const PropAccessor` 由 `self.arena` 分配。
    fn lowerPropAccessorNode(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!*const PropAccessor {
        const id = try self.reserveHirId();
        var name: ?Name = null;
        var in_parens = false;
        var params: std.ArrayListUnmanaged(Param) = .empty;
        defer params.deinit(self.gpa);
        var body: ?*const BlockExpr = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (!in_parens and name == null and isNameTokenKind(child.kind)) {
                name = extractNameFromLeaf(child, c_start);
            } else if (child.kind == .l_paren) {
                in_parens = true;
            } else if (child.kind == .r_paren) {
                in_parens = false;
            } else if (in_parens and isNameTokenKind(child.kind)) {
                const param_id = try self.reserveHirId();
                const p_name = extractNameFromLeaf(child, c_start);
                const p_ptr = try self.arena.create(Param);
                p_ptr.* = .{ .param = .{
                    .id = param_id,
                    .name = p_name,
                    .range = p_name.range,
                } };
                try self.commitNode(param_id, .{ .param = p_ptr }, child);
                try params.append(self.gpa, p_ptr.*);
            } else if (child.kind == .block) {
                body = try self.lowerBlockNode(child, c_start);
            }
        }

        const r = trimmedRange(green, start_offset);
        const body_ptr = body orelse try self.allocPlaceholderBlock(.{ .start = r.end, .end = r.end });
        const acc_ptr = try self.arena.create(PropAccessor);
        acc_ptr.* = .{
            .id = id,
            .name = name orelse emptyNameAt(r.start),
            .params = try self.dupeParamsAndSyncNodes(params.items),
            .body = body_ptr,
            .range = r,
        };
        try self.commitNode(id, .{ .prop_accessor = acc_ptr }, green);
        return acc_ptr;
    }

    /// 降低 `type_alias_decl` 为 `TypeAliasItem`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `TypeAliasItem` 内部所有指针与切片由 `self.arena` 分配。
    fn lowerTypeAliasItem(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.TypeAliasItem {
        var mods: std.ArrayListUnmanaged(Modifier) = .empty;
        defer mods.deinit(self.gpa);
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);

        var seen_kw = false;
        var name: ?Name = null;
        var type_params: []const Name = &.{};
        var target: ?*const HirType = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            switch (child.kind) {
                .annotation => try annos.append(self.gpa, try self.lowerAnnotation(child, c_start)),
                .kw_type => seen_kw = true,
                .type_parameter_list => type_params = try self.lowerTypeParameterList(child, c_start),
                else => {
                    if (isTypeSyntaxKind(child.kind)) {
                        target = try self.lowerTypeNode(child, c_start);
                    } else if (!seen_kw) {
                        if (modifierFromNode(child)) |m| {
                            try mods.append(self.gpa, m);
                        }
                    } else if (name == null and isNameTokenKind(child.kind)) {
                        name = extractNameFromLeaf(child, c_start);
                    }
                },
            }
        }

        const r = trimmedRange(green, start_offset);
        const target_ptr = target orelse try self.allocPlaceholderType(.{ .start = r.end, .end = r.end });
        return .{
            .id = id,
            .modifiers = try self.arena.dupe(Modifier, mods.items),
            .annotations = try self.arena.dupe(Annotation, annos.items),
            .name = name orelse emptyNameAt(r.start),
            .type_params = type_params,
            .target = target_ptr,
            .range = r,
        };
    }

    /// 降低 `init_decl` 为 `InitItem`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `InitItem` 内部所有指针与切片由 `self.arena` 分配。
    fn lowerInitItem(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.InitItem {
        var mods: std.ArrayListUnmanaged(Modifier) = .empty;
        defer mods.deinit(self.gpa);
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);

        var params: []const Param = &.{};
        var is_variadic = false;
        var body: ?*const BlockExpr = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .annotation) {
                try annos.append(self.gpa, try self.lowerAnnotation(child, c_start));
            } else if (modifierFromNode(child)) |m| {
                try mods.append(self.gpa, m);
            } else if (child.kind == .func_param_list) {
                const pl = try self.lowerFuncParamList(child, c_start);
                params = pl.params;
                is_variadic = pl.is_variadic;
            } else if (child.kind == .block) {
                body = try self.lowerBlockNode(child, c_start);
            }
        }

        const r = trimmedRange(green, start_offset);
        const body_ptr = body orelse try self.allocPlaceholderBlock(.{ .start = r.end, .end = r.end });
        return .{
            .id = id,
            .modifiers = try self.arena.dupe(Modifier, mods.items),
            .annotations = try self.arena.dupe(Annotation, annos.items),
            .params = params,
            .is_variadic = is_variadic,
            .body = body_ptr,
            .range = r,
        };
    }

    /// 降低 `finalizer_decl` 为 `FinalizerItem`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `FinalizerItem` 内部所有指针与切片由 `self.arena` 分配。
    fn lowerFinalizerItem(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.FinalizerItem {
        const init_item = try self.lowerInitItem(id, green, start_offset);
        return .{
            .id = id,
            .modifiers = init_item.modifiers,
            .annotations = init_item.annotations,
            .params = init_item.params,
            .is_variadic = init_item.is_variadic,
            .body = init_item.body,
            .range = init_item.range,
        };
    }

    /// 降低 `primary_ctor_decl` 为 `PrimaryCtorItem`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `PrimaryCtorItem` 内部所有指针与切片由 `self.arena` 分配。
    fn lowerPrimaryCtorItem(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.PrimaryCtorItem {
        var mods: std.ArrayListUnmanaged(Modifier) = .empty;
        defer mods.deinit(self.gpa);
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);

        var name: ?Name = null;
        var params: []const Param = &.{};
        var is_variadic = false;
        var body: ?*const BlockExpr = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .annotation) {
                try annos.append(self.gpa, try self.lowerAnnotation(child, c_start));
            } else if (name == null and modifierFromNode(child) != null) {
                try mods.append(self.gpa, modifierFromNode(child).?);
            } else if (name == null and isNameTokenKind(child.kind)) {
                name = extractNameFromLeaf(child, c_start);
            } else if (child.kind == .func_param_list) {
                const pl = try self.lowerFuncParamList(child, c_start);
                params = pl.params;
                is_variadic = pl.is_variadic;
            } else if (child.kind == .block) {
                body = try self.lowerBlockNode(child, c_start);
            }
        }

        const r = trimmedRange(green, start_offset);
        const body_ptr = body orelse try self.allocPlaceholderBlock(.{ .start = r.end, .end = r.end });
        return .{
            .id = id,
            .modifiers = try self.arena.dupe(Modifier, mods.items),
            .annotations = try self.arena.dupe(Annotation, annos.items),
            .name = name orelse emptyNameAt(r.start),
            .params = params,
            .is_variadic = is_variadic,
            .body = body_ptr,
            .range = r,
        };
    }

    /// 降低 `var_decl` 为 `Binding` 载荷。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `Binding` 内部所有指针与切片由 `self.arena` 分配。
    fn lowerBindingPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!Binding {
        var mods: std.ArrayListUnmanaged(Modifier) = .empty;
        defer mods.deinit(self.gpa);
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);

        var binding_kind: ?BindingKind = null;
        var pat: ?*const HirPattern = null;
        var ty: ?*const HirType = null;
        var init_expr: ?*const HirExpr = null;
        var seen_assign = false;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            switch (child.kind) {
                .annotation => try annos.append(self.gpa, try self.lowerAnnotation(child, c_start)),
                .kw_let => if (binding_kind == null) {
                    binding_kind = .let_;
                },
                .kw_var => if (binding_kind == null) {
                    binding_kind = .var_;
                },
                .kw_const => if (binding_kind == null) {
                    binding_kind = .const_;
                },
                .assign => seen_assign = true,
                else => {
                    if (!seen_assign and pat == null and isPatternSyntaxKind(child.kind)) {
                        pat = try self.lowerPatternNode(child, c_start);
                    } else if (!seen_assign and isTypeSyntaxKind(child.kind)) {
                        ty = try self.lowerTypeNode(child, c_start);
                    } else if (seen_assign and init_expr == null and isExprSyntaxKind(child.kind)) {
                        init_expr = try self.lowerExprNode(child, c_start);
                    } else if (binding_kind == null) {
                        if (modifierFromNode(child)) |m| {
                            try mods.append(self.gpa, m);
                        }
                    }
                },
            }
        }

        const r = trimmedRange(green, start_offset);
        const pat_ptr = pat orelse try self.allocPlaceholderPattern(.{ .start = r.start, .end = r.start });
        return .{
            .id = id,
            .modifiers = try self.arena.dupe(Modifier, mods.items),
            .annotations = try self.arena.dupe(Annotation, annos.items),
            .kind = binding_kind orelse .let_,
            .pattern = pat_ptr,
            .ty = ty,
            .init = init_expr,
            .range = r,
        };
    }

    /// 降低 `foreign_decl` 为 `ForeignItem`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `ForeignItem` 内部所有指针与切片由 `self.arena` 分配。
    fn lowerForeignItem(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.ForeignItem {
        var mods: std.ArrayListUnmanaged(Modifier) = .empty;
        defer mods.deinit(self.gpa);
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);
        var members: std.ArrayListUnmanaged(HirItem) = .empty;
        defer members.deinit(self.gpa);

        var seen_kw = false;
        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            switch (child.kind) {
                .annotation => try annos.append(self.gpa, try self.lowerAnnotation(child, c_start)),
                .kw_foreign => seen_kw = true,
                .foreign_block => {
                    const block_members = try self.lowerMemberBody(child, c_start);
                    try members.appendSlice(self.gpa, block_members);
                },
                else => {
                    if (isDeclOrWrappedDecl(child)) {
                        const item_ptr = try self.lowerItemNode(child, c_start);
                        try members.append(self.gpa, item_ptr.*);
                    } else if (!seen_kw) {
                        if (modifierFromNode(child)) |m| {
                            try mods.append(self.gpa, m);
                        }
                    }
                },
            }
        }

        return .{
            .id = id,
            .modifiers = try self.arena.dupe(Modifier, mods.items),
            .annotations = try self.arena.dupe(Annotation, annos.items),
            .members = try self.dupeItemsAndSyncNodes(members.items),
            .range = trimmedRange(green, start_offset),
        };
    }

    /// 降低 `macro_decl` 为 `MacroItem`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `MacroItem` 内部所有指针与切片由 `self.arena` 分配。
    fn lowerMacroItem(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.MacroItem {
        var mods: std.ArrayListUnmanaged(Modifier) = .empty;
        defer mods.deinit(self.gpa);
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);

        var seen_kw = false;
        var name: ?Name = null;
        var params: []const Param = &.{};
        var is_variadic = false;
        var ret_type: ?*const HirType = null;
        var body: ?*const HirExpr = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            switch (child.kind) {
                .annotation => try annos.append(self.gpa, try self.lowerAnnotation(child, c_start)),
                .kw_macro => seen_kw = true,
                .func_param_list => {
                    const pl = try self.lowerFuncParamList(child, c_start);
                    params = pl.params;
                    is_variadic = pl.is_variadic;
                },
                .ret_type => ret_type = try self.lowerRetType(child, c_start),
                else => {
                    if (child.kind == .block or isExprSyntaxKind(child.kind)) {
                        body = try self.lowerExprNode(child, c_start);
                    } else if (!seen_kw) {
                        if (modifierFromNode(child)) |m| {
                            try mods.append(self.gpa, m);
                        }
                    } else if (name == null and isNameTokenKind(child.kind)) {
                        name = extractNameFromLeaf(child, c_start);
                    }
                },
            }
        }

        const r = trimmedRange(green, start_offset);
        const body_ptr = body orelse try self.allocPlaceholderExpr(.{ .start = r.end, .end = r.end });
        return .{
            .id = id,
            .modifiers = try self.arena.dupe(Modifier, mods.items),
            .annotations = try self.arena.dupe(Annotation, annos.items),
            .name = name orelse emptyNameAt(r.start),
            .params = params,
            .is_variadic = is_variadic,
            .ret_type = ret_type,
            .body = body_ptr,
            .range = r,
        };
    }

    /// 降低 `macro_expand_decl` 为 `MacroExpandItem`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `MacroExpandItem` 内部所有指针与切片由 `self.arena` 分配。
    fn lowerMacroExpandItem(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.MacroExpandItem {
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);
        var call_path: std.ArrayListUnmanaged(Name) = .empty;
        defer call_path.deinit(self.gpa);

        var has_bang = false;
        var attr_range: ?TextRange = null;
        var input_range: ?TextRange = null;
        var wrapped: ?*const HirItem = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .annotation) {
                try annos.append(self.gpa, try self.lowerAnnotation(child, c_start));
            } else if (child.kind == .at_excl) {
                has_bang = true;
            } else if (isNameTokenKind(child.kind)) {
                try call_path.append(self.gpa, extractNameFromLeaf(child, c_start));
            } else if (child.kind == .macro_attributes) {
                attr_range = trimmedRange(child, c_start);
            } else if (child.kind == .macro_input) {
                input_range = trimmedRange(child, c_start);
            } else if (isDeclOrWrappedDecl(child)) {
                wrapped = try self.lowerItemNode(child, c_start);
            }
        }

        const r = trimmedRange(green, start_offset);
        if (call_path.items.len == 0) {
            try call_path.append(self.gpa, emptyNameAt(r.start));
        }
        return .{
            .id = id,
            .annotations = try self.arena.dupe(Annotation, annos.items),
            .call = .{
                .path = try self.arena.dupe(Name, call_path.items),
                .has_bang = has_bang,
                .attributes = attr_range,
                .input = input_range,
            },
            .wrapped = wrapped,
            .range = r,
        };
    }

    /// 降低类型体、接口体、扩展体或外部块（`class_body`、`struct_body`、`interface_body`、`extend_body`、`foreign_block`）内的成员列表。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的切片由 `self.arena` 分配。
    fn lowerMemberBody(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error![]const HirItem {
        var members: std.ArrayListUnmanaged(HirItem) = .empty;
        defer members.deinit(self.gpa);

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (isDeclOrWrappedDecl(child)) {
                const item_ptr = try self.lowerItemNode(child, c_start);
                try members.append(self.gpa, item_ptr.*);
            }
        }
        return try self.dupeItemsAndSyncNodes(members.items);
    }

    // =========================================================================
    // 泛型参数、形参列表、返回类型与 WhereClause
    // =========================================================================

    /// 降低声明侧 `type_parameter_list` 为 `[]const Name`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的切片由 `self.arena` 分配。
    fn lowerTypeParameterList(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error![]const Name {
        var params: std.ArrayListUnmanaged(Name) = .empty;
        defer params.deinit(self.gpa);

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .type_parameter) {
                var tp_off = c_start;
                for (child.children()) |leaf| {
                    const l_start = tp_off;
                    tp_off +|= leaf.text_len;
                    if (isNameTokenKind(leaf.kind)) {
                        try params.append(self.gpa, extractNameFromLeaf(leaf, l_start));
                        break;
                    }
                }
            }
        }
        return try self.arena.dupe(Name, params.items);
    }

    const ParamListResult = struct {
        params: []const Param,
        is_variadic: bool,
    };

    /// 降低 `func_param_list` 为形参切片与可变参数标志。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `params` 切片由 `self.arena` 分配。
    fn lowerFuncParamList(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!ParamListResult {
        var params: std.ArrayListUnmanaged(Param) = .empty;
        defer params.deinit(self.gpa);
        var is_variadic = false;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .ellipsis) {
                is_variadic = true;
            } else if (child.kind == .func_param or child.kind == .macro_expand_param) {
                const p_ptr = try self.lowerParamNode(child, c_start);
                try params.append(self.gpa, p_ptr.*);
            }
        }
        return .{
            .params = try self.dupeParamsAndSyncNodes(params.items),
            .is_variadic = is_variadic,
        };
    }

    /// 降低 `func_param` 或 `macro_expand_param` 节点为 `*const Param`，分配 `HirId` 并记入 `nodes_buf` 与 `GreenToHirMap`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const Param` 由 `self.arena` 分配。
    fn lowerParamNode(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!*const Param {
        const id = try self.reserveHirId();
        const param_val: Param = if (green.kind == .macro_expand_param) blk: {
            var pm = try self.lowerParamMacroPayload(green, start_offset);
            pm.id = id;
            break :blk .{ .macro_call = pm };
        } else .{ .param = try self.lowerHirParamPayload(id, green, start_offset) };

        const p_ptr = try self.arena.create(Param);
        p_ptr.* = param_val;
        try self.commitNode(id, .{ .param = p_ptr }, green);
        return p_ptr;
    }

    /// 降低 `func_param` 载荷。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `HirParam` 内部所有指针与切片由 `self.arena` 分配。
    fn lowerHirParamPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!HirParam {
        var mods: std.ArrayListUnmanaged(Modifier) = .empty;
        defer mods.deinit(self.gpa);
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);

        var binding: ?BindingKind = null;
        var name: ?Name = null;
        var seen_name_or_wildcard = false;
        var is_named = false;
        var ty: ?*const HirType = null;
        var default_value: ?*const HirExpr = null;
        var seen_assign = false;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .annotation) {
                try annos.append(self.gpa, try self.lowerAnnotation(child, c_start));
            } else if (!seen_name_or_wildcard) {
                if (child.kind == .kw_let) {
                    binding = .let_;
                } else if (child.kind == .kw_var) {
                    binding = .var_;
                } else if (modifierFromNode(child)) |m| {
                    try mods.append(self.gpa, m);
                } else if (child.kind == .wildcard) {
                    seen_name_or_wildcard = true;
                } else if (isNameTokenKind(child.kind)) {
                    name = extractNameFromLeaf(child, c_start);
                    seen_name_or_wildcard = true;
                }
            } else if (child.kind == .not and !seen_assign) {
                is_named = true;
            } else if (child.kind == .assign) {
                seen_assign = true;
            } else if (!seen_assign and isTypeSyntaxKind(child.kind)) {
                ty = try self.lowerTypeNode(child, c_start);
            } else if (seen_assign and default_value == null and isExprSyntaxKind(child.kind)) {
                default_value = try self.lowerExprNode(child, c_start);
            }
        }

        return .{
            .id = id,
            .modifiers = try self.arena.dupe(Modifier, mods.items),
            .annotations = try self.arena.dupe(Annotation, annos.items),
            .binding = binding,
            .name = name,
            .is_named = is_named,
            .ty = ty,
            .default_value = default_value,
            .range = trimmedRange(green, start_offset),
        };
    }

    /// 降低 `macro_expand_param` 载荷。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `ParamMacro` 内部所有指针与切片由 `self.arena` 分配。
    fn lowerParamMacroPayload(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!ParamMacro {
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);
        var call_path: std.ArrayListUnmanaged(Name) = .empty;
        defer call_path.deinit(self.gpa);

        var has_bang = false;
        var attr_range: ?TextRange = null;
        var input_range: ?TextRange = null;
        var inner_param: ?*const Param = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .annotation) {
                try annos.append(self.gpa, try self.lowerAnnotation(child, c_start));
            } else if (child.kind == .at_excl) {
                has_bang = true;
            } else if (isNameTokenKind(child.kind)) {
                try call_path.append(self.gpa, extractNameFromLeaf(child, c_start));
            } else if (child.kind == .macro_attributes) {
                attr_range = trimmedRange(child, c_start);
            } else if (child.kind == .macro_input) {
                input_range = trimmedRange(child, c_start);
            } else if (child.kind == .func_param or child.kind == .macro_expand_param) {
                inner_param = try self.lowerParamNode(child, c_start);
            }
        }

        const r = trimmedRange(green, start_offset);
        if (call_path.items.len == 0) {
            try call_path.append(self.gpa, emptyNameAt(r.start));
        }
        return .{
            .annotations = try self.arena.dupe(Annotation, annos.items),
            .call = .{
                .path = try self.arena.dupe(Name, call_path.items),
                .has_bang = has_bang,
                .attributes = attr_range,
                .input = input_range,
            },
            .param = inner_param,
            .range = r,
        };
    }

    /// 降低 `ret_type` 包装节点，并将 `ret_type` 穿透映射到内层 `HirType.id()`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const HirType` 由 `self.arena` 分配。
    fn lowerRetType(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!*const HirType {
        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (isTypeSyntaxKind(child.kind)) {
                const ty_ptr = try self.lowerTypeNode(child, c_start);
                try self.mapGreen(green, ty_ptr.id());
                return ty_ptr;
            }
        }
        const r = trimmedRange(green, start_offset);
        const placeholder = try self.allocPlaceholderType(r);
        try self.mapGreen(green, placeholder.id());
        return placeholder;
    }

    /// 降低 `where_clause` 为 `*const WhereClause`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const WhereClause` 由 `self.arena` 分配。
    fn lowerWhereClause(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!*const WhereClause {
        var constraints: std.ArrayListUnmanaged(GenericConstraint) = .empty;
        defer constraints.deinit(self.gpa);

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .generic_constraint) {
                var subject: ?*const HirType = null;
                var bounds: std.ArrayListUnmanaged(HirType) = .empty;
                defer bounds.deinit(self.gpa);
                var seen_upper = false;

                var gc_off = c_start;
                for (child.children()) |gc_child| {
                    const gc_start = gc_off;
                    gc_off +|= gc_child.text_len;
                    if (gc_child.kind == .upperbound) {
                        seen_upper = true;
                    } else if (isTypeSyntaxKind(gc_child.kind)) {
                        const ty_ptr = try self.lowerTypeNode(gc_child, gc_start);
                        if (!seen_upper and subject == null) {
                            subject = ty_ptr;
                        } else {
                            try bounds.append(self.gpa, ty_ptr.*);
                        }
                    }
                }
                const gc_range = trimmedRange(child, c_start);
                const subj_ptr = subject orelse try self.allocPlaceholderType(.{ .start = gc_range.start, .end = gc_range.start });
                try constraints.append(self.gpa, .{
                    .subject = subj_ptr,
                    .bounds = try self.dupeTypesAndSyncNodes(bounds.items),
                    .range = gc_range,
                });
            }
        }

        const wc_ptr = try self.arena.create(WhereClause);
        wc_ptr.* = .{
            .constraints = try self.arena.dupe(GenericConstraint, constraints.items),
            .range = trimmedRange(green, start_offset),
        };
        return wc_ptr;
    }

    // =========================================================================
    // 类型（HirType）
    // =========================================================================

    /// 降低类型语法节点为 `*const HirType`。`paren_type` 折叠为内层类型并将外层节点穿透映射到内层 `HirId`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const HirType` 由 `self.arena` 分配。
    fn lowerTypeNode(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!*const HirType {
        if (green.kind == .paren_type) {
            var offset = start_offset;
            for (green.children()) |child| {
                const c_start = offset;
                offset +|= child.text_len;
                if (isTypeSyntaxKind(child.kind)) {
                    const inner_ty = try self.lowerTypeNode(child, c_start);
                    try self.mapGreen(green, inner_ty.id());
                    return inner_ty;
                }
            }
            const r = trimmedRange(green, start_offset);
            const placeholder = try self.allocPlaceholderType(r);
            try self.mapGreen(green, placeholder.id());
            return placeholder;
        }

        const id = try self.reserveHirId();
        const r = trimmedRange(green, start_offset);
        const ty_val: HirType = switch (green.kind) {
            .this_type => .{ .this = .{ .id = id, .range = r } },
            .primitive_type => blk: {
                var seg_name: ?Name = null;
                var offset = start_offset;
                for (green.children()) |child| {
                    const c_start = offset;
                    offset +|= child.text_len;
                    if (!isTriviaKind(child.kind)) {
                        seg_name = .{
                            .text = child.tokenText() orelse "",
                            .is_raw = false,
                            .range = .{ .start = c_start, .end = c_start + child.text_len },
                        };
                        break;
                    }
                }
                const nm = seg_name orelse emptyNameAt(r.start);
                const segs = try self.arena.dupe(TypePathSegment, &.{.{ .name = nm }});
                break :blk .{ .path = .{ .id = id, .segments = segs, .range = r } };
            },
            .path_type => .{ .path = try self.lowerPathTypePayload(id, green, start_offset) },
            .option_type => blk: {
                var inner: ?*const HirType = null;
                var offset = start_offset;
                for (green.children()) |child| {
                    const c_start = offset;
                    offset +|= child.text_len;
                    if (isTypeSyntaxKind(child.kind)) {
                        inner = try self.lowerTypeNode(child, c_start);
                        break;
                    }
                }
                const inner_ptr = inner orelse try self.allocPlaceholderType(.{ .start = r.end, .end = r.end });
                break :blk .{ .option = .{ .id = id, .inner = inner_ptr, .range = r } };
            },
            .tuple_type => blk: {
                const elems = try self.lowerParenTypeElements(green, start_offset, false);
                break :blk .{ .tuple = .{ .id = id, .elements = elems, .range = r } };
            },
            .func_type => blk: {
                const params = try self.lowerParenTypeElements(green, start_offset, true);
                var ret: ?*const HirType = null;
                var seen_arrow = false;
                var offset = start_offset;
                for (green.children()) |child| {
                    const c_start = offset;
                    offset +|= child.text_len;
                    if (child.kind == .arrow) {
                        seen_arrow = true;
                    } else if (seen_arrow and isTypeSyntaxKind(child.kind)) {
                        ret = try self.lowerTypeNode(child, c_start);
                        break;
                    }
                }
                const ret_ptr = ret orelse try self.allocPlaceholderType(.{ .start = r.end, .end = r.end });
                break :blk .{ .func = .{ .id = id, .params = params, .ret = ret_ptr, .range = r } };
            },
            .varray_type => .{ .varray = try self.lowerVArrayTypePayload(id, green, start_offset) },
            else => blk: {
                const segs = try self.arena.dupe(TypePathSegment, &.{.{ .name = emptyNameAt(r.start) }});
                break :blk .{ .path = .{ .id = id, .segments = segs, .range = r } };
            },
        };

        const ty_ptr = try self.arena.create(HirType);
        ty_ptr.* = ty_val;
        try self.commitNode(id, .{ .ty = ty_ptr }, green);
        return ty_ptr;
    }

    /// 降低 `path_type` 载荷。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `PathType` 内部切片由 `self.arena` 分配。
    fn lowerPathTypePayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!PathType {
        var segs: std.ArrayListUnmanaged(TypePathSegment) = .empty;
        defer segs.deinit(self.gpa);

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .path_segment) {
                try segs.append(self.gpa, try self.lowerTypePathSegment(child, c_start));
            }
        }
        const r = trimmedRange(green, start_offset);
        if (segs.items.len == 0) {
            try segs.append(self.gpa, .{ .name = emptyNameAt(r.start) });
        }
        return .{
            .id = id,
            .segments = try self.arena.dupe(TypePathSegment, segs.items),
            .range = r,
        };
    }

    /// 降低类型路径中的单个 `path_segment`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `TypePathSegment` 内部切片由 `self.arena` 分配。
    fn lowerTypePathSegment(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!TypePathSegment {
        var name: ?Name = null;
        var type_args: []const HirType = &.{};

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (name == null and isNameTokenKind(child.kind)) {
                name = extractNameFromLeaf(child, c_start);
            } else if (child.kind == .type_argument_list) {
                type_args = try self.lowerTypeArgumentList(child, c_start);
            }
        }
        const r = trimmedRange(green, start_offset);
        return .{
            .name = name orelse emptyNameAt(r.start),
            .type_args = type_args,
        };
    }

    /// 降低 `type_argument_list` 为 `[]const HirType`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的切片由 `self.arena` 分配。
    fn lowerTypeArgumentList(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error![]const HirType {
        var args: std.ArrayListUnmanaged(HirType) = .empty;
        defer args.deinit(self.gpa);

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (isTypeSyntaxKind(child.kind)) {
                const ty_ptr = try self.lowerTypeNode(child, c_start);
                try args.append(self.gpa, ty_ptr.*);
            }
        }
        return try self.dupeTypesAndSyncNodes(args.items);
    }

    /// 降低 `tuple_type` 或 `func_type` 圆括号内的元素类型序列。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的切片由 `self.arena` 分配。
    fn lowerParenTypeElements(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
        stop_at_rparen: bool,
    ) std.mem.Allocator.Error![]const HirTypeElement {
        var elems: std.ArrayListUnmanaged(HirTypeElement) = .empty;
        defer elems.deinit(self.gpa);

        var pending_label: ?Name = null;
        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (stop_at_rparen and (child.kind == .r_paren or child.kind == .arrow)) break;
            if (isNameTokenKind(child.kind)) {
                pending_label = extractNameFromLeaf(child, c_start);
            } else if (isTypeSyntaxKind(child.kind)) {
                const ty_ptr = try self.lowerTypeNode(child, c_start);
                const elem_start = if (pending_label) |lbl| lbl.range.start else ty_ptr.range().start;
                try elems.append(self.gpa, .{
                    .label = pending_label,
                    .ty = ty_ptr,
                    .range = .{ .start = elem_start, .end = ty_ptr.range().end },
                });
                pending_label = null;
            } else if (child.kind == .comma) {
                pending_label = null;
            }
        }
        return try self.arena.dupe(HirTypeElement, elems.items);
    }

    /// 降低 `varray_type` 载荷。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `VArrayType` 内部指针由 `self.arena` 分配。
    fn lowerVArrayTypePayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.VArrayType {
        var elem: ?*const HirType = null;
        var size_text: []const u8 = "";

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (elem == null and isTypeSyntaxKind(child.kind)) {
                elem = try self.lowerTypeNode(child, c_start);
            } else if (child.kind == .constant_type) {
                for (child.children()) |c_leaf| {
                    if (c_leaf.kind == .integer_literal) {
                        size_text = c_leaf.tokenText() orelse "";
                        break;
                    }
                }
            }
        }

        const r = trimmedRange(green, start_offset);
        const elem_ptr = elem orelse try self.allocPlaceholderType(.{ .start = r.start, .end = r.start });
        return .{
            .id = id,
            .elem = elem_ptr,
            .size = size_text,
            .range = r,
        };
    }

    // =========================================================================
    // 模式（HirPattern）
    // =========================================================================

    /// 降低模式节点为 `*const HirPattern`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const HirPattern` 由 `self.arena` 分配。
    fn lowerPatternNode(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!*const HirPattern {
        const id = try self.reserveHirId();
        const r = trimmedRange(green, start_offset);

        const pat_val: HirPattern = switch (green.kind) {
            .wildcard_pattern => .{ .wildcard = .{ .id = id, .range = r } },
            .var_pattern => blk: {
                var name: ?Name = null;
                var offset = start_offset;
                for (green.children()) |child| {
                    const c_start = offset;
                    offset +|= child.text_len;
                    if (isNameTokenKind(child.kind)) {
                        name = extractNameFromLeaf(child, c_start);
                        break;
                    }
                }
                break :blk .{ .binding = .{
                    .id = id,
                    .name = name orelse emptyNameAt(r.start),
                    .range = r,
                } };
            },
            .const_pattern => blk: {
                const val_expr = try self.lowerConstPatternValue(green, start_offset);
                break :blk .{ .const_ = .{
                    .id = id,
                    .value = val_expr,
                    .range = r,
                } };
            },
            .tuple_pattern => blk: {
                var elems: std.ArrayListUnmanaged(HirPattern) = .empty;
                defer elems.deinit(self.gpa);
                var offset = start_offset;
                for (green.children()) |child| {
                    const c_start = offset;
                    offset +|= child.text_len;
                    if (isPatternSyntaxKind(child.kind)) {
                        const p_ptr = try self.lowerPatternNode(child, c_start);
                        try elems.append(self.gpa, p_ptr.*);
                    }
                }
                break :blk .{ .tuple = .{
                    .id = id,
                    .elements = try self.dupePatternsAndSyncNodes(elems.items),
                    .range = r,
                } };
            },
            .enum_pattern => blk: {
                var path: ?PathType = null;
                var args: std.ArrayListUnmanaged(HirPattern) = .empty;
                defer args.deinit(self.gpa);
                var offset = start_offset;
                for (green.children()) |child| {
                    const c_start = offset;
                    offset +|= child.text_len;
                    if (child.kind == .path_expr) {
                        path = try self.lowerPathTypePayload(id, child, c_start);
                        try self.mapGreen(child, id);
                    } else if (isPatternSyntaxKind(child.kind)) {
                        const p_ptr = try self.lowerPatternNode(child, c_start);
                        try args.append(self.gpa, p_ptr.*);
                    }
                }
                const final_path = path orelse PathType{
                    .id = id,
                    .segments = try self.arena.dupe(TypePathSegment, &.{.{ .name = emptyNameAt(r.start) }}),
                    .range = .{ .start = r.start, .end = r.start },
                };
                break :blk .{ .enum_ = .{
                    .id = id,
                    .path = final_path,
                    .args = try self.dupePatternsAndSyncNodes(args.items),
                    .range = r,
                } };
            },
            .type_pattern => blk: {
                var name: ?Name = null;
                var ty: ?*const HirType = null;
                var offset = start_offset;
                for (green.children()) |child| {
                    const c_start = offset;
                    offset +|= child.text_len;
                    if (name == null and isNameTokenKind(child.kind)) {
                        name = extractNameFromLeaf(child, c_start);
                    } else if (ty == null and isTypeSyntaxKind(child.kind)) {
                        ty = try self.lowerTypeNode(child, c_start);
                    }
                }
                const ty_ptr = ty orelse try self.allocPlaceholderType(.{ .start = r.end, .end = r.end });
                break :blk .{ .typed = .{
                    .id = id,
                    .name = name,
                    .ty = ty_ptr,
                    .range = r,
                } };
            },
            .except_type_pattern, .command_type_pattern => blk: {
                var name: ?Name = null;
                var types: std.ArrayListUnmanaged(HirType) = .empty;
                defer types.deinit(self.gpa);
                var offset = start_offset;
                for (green.children()) |child| {
                    const c_start = offset;
                    offset +|= child.text_len;
                    if (name == null and isNameTokenKind(child.kind)) {
                        name = extractNameFromLeaf(child, c_start);
                    } else if (isTypeSyntaxKind(child.kind)) {
                        const ty_ptr = try self.lowerTypeNode(child, c_start);
                        try types.append(self.gpa, ty_ptr.*);
                    }
                }
                if (types.items.len == 0) {
                    const dummy = try self.allocPlaceholderType(.{ .start = r.end, .end = r.end });
                    try types.append(self.gpa, dummy.*);
                }
                const clause: common.ClausePattern = .{
                    .id = id,
                    .name = name,
                    .types = try self.dupeTypesAndSyncNodes(types.items),
                    .range = r,
                };
                break :blk if (green.kind == .except_type_pattern)
                    .{ .except_type = clause }
                else
                    .{ .command_type = clause };
            },
            else => .{ .wildcard = .{ .id = id, .range = r } },
        };

        const pat_ptr = try self.arena.create(HirPattern);
        pat_ptr.* = pat_val;
        try self.commitNode(id, .{ .pattern = pat_ptr }, green);
        return pat_ptr;
    }

    /// 降低 `const_pattern` 内部的常量字面量表达式（含带负号 `-` 的数值字面量与 `unit_literal`）。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const HirExpr` 由 `self.arena` 分配。
    fn lowerConstPatternValue(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!*const HirExpr {
        var has_neg = false;
        var val_child: ?LocatedGreen = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .sub) {
                has_neg = true;
            } else if (isExprSyntaxKind(child.kind)) {
                val_child = .{ .green = child, .start = c_start };
                break;
            }
        }

        const r = trimmedRange(green, start_offset);
        const inner_expr = if (val_child) |vc|
            try self.lowerExprNode(vc.green, vc.start)
        else
            try self.allocPlaceholderExpr(r);

        if (!has_neg) return inner_expr;

        const unary_id = try self.reserveHirId();
        const unary_ptr = try self.arena.create(HirExpr);
        unary_ptr.* = .{ .unary = .{
            .id = unary_id,
            .op = .neg,
            .operand = inner_expr,
            .range = r,
        } };
        try self.commitNode(unary_id, .{ .expr = unary_ptr }, null);
        return unary_ptr;
    }

    // =========================================================================
    // 语句块（BlockExpr）与语句（HirStmt）
    // =========================================================================

    /// 降低 `.block`（或 `match` 分支下的 `.stmt_list`）为独立的 `*const BlockExpr`，
    /// 分配 `HirId` 并记入 `nodes_buf`（`.block`）与 `GreenToHirMap`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const BlockExpr` 由 `self.arena` 分配。
    fn lowerBlockNode(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!*const BlockExpr {
        const id = try self.reserveHirId();
        const payload = try self.lowerBlockPayload(id, green, start_offset);
        const block_ptr = try self.arena.create(BlockExpr);
        block_ptr.* = payload;
        try self.commitNode(id, .{ .block = block_ptr }, green);
        return block_ptr;
    }

    /// 提取 `.block` 或 `.stmt_list` 内部的语句序列与可选尾表达式。
    ///
    /// 当最后一条语句是不带分号的 `expression_statement` 时，提取为 `BlockExpr.tail`，
    /// 并同步将该 `expression_statement` 的 `GreenNode` 映射到 `tail.id()`（P0-2）。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `BlockExpr` 内部指针与切片由 `self.arena` 分配。
    fn lowerBlockPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!BlockExpr {
        var stmt_list_node = LocatedGreen{ .green = green, .start = start_offset };
        if (green.kind == .block) {
            var offset = start_offset;
            for (green.children()) |child| {
                const c_start = offset;
                offset +|= child.text_len;
                if (child.kind == .stmt_list) {
                    stmt_list_node = .{ .green = child, .start = c_start };
                    break;
                }
            }
        }

        // 先收集 stmt_list 下的所有有效语句子节点及其起始位置
        var raw_stmts: std.ArrayListUnmanaged(LocatedGreen) = .empty;
        defer raw_stmts.deinit(self.gpa);

        var offset = stmt_list_node.start;
        for (stmt_list_node.green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (isTriviaOrPunct(child.kind)) continue;
            try raw_stmts.append(self.gpa, .{ .green = child, .start = c_start });
        }

        var stmts: std.ArrayListUnmanaged(HirStmt) = .empty;
        defer stmts.deinit(self.gpa);
        var tail: ?*const HirExpr = null;

        for (raw_stmts.items, 0..) |entry, idx| {
            const is_last = idx + 1 == raw_stmts.items.len;
            if (entry.green.kind == .expression_statement) {
                const has_semi = exprStmtHasSemi(entry.green);
                if (is_last and !has_semi) {
                    const tail_expr = try self.lowerExprStmtInner(entry.green, entry.start);
                    try self.mapGreen(entry.green, tail_expr.id());
                    tail = tail_expr;
                    continue;
                }
                const stmt_id = try self.reserveHirId();
                const val_expr = try self.lowerExprStmtInner(entry.green, entry.start);
                const stmt_ptr = try self.arena.create(HirStmt);
                stmt_ptr.* = .{ .expr = .{
                    .id = stmt_id,
                    .value = val_expr,
                    .has_semi = has_semi,
                    .range = trimmedRange(entry.green, entry.start),
                } };
                try self.commitNode(stmt_id, .{ .stmt = stmt_ptr }, entry.green);
                try stmts.append(self.gpa, stmt_ptr.*);
            } else if (entry.green.kind == .var_decl) {
                const stmt_id = try self.reserveHirId();
                const bind_payload = try self.lowerBindingPayload(stmt_id, entry.green, entry.start);
                const stmt_ptr = try self.arena.create(HirStmt);
                stmt_ptr.* = .{ .binding = bind_payload };
                try self.commitNode(stmt_id, .{ .stmt = stmt_ptr }, entry.green);
                try stmts.append(self.gpa, stmt_ptr.*);
            } else if (entry.green.kind == .error_node) {
                if (findWrappedDeclChild(entry.green, entry.start)) |inner| {
                    if (inner.green.kind == .var_decl) {
                        const stmt_id = try self.reserveHirId();
                        const bind_payload = try self.lowerBindingPayload(stmt_id, inner.green, inner.start);
                        const stmt_ptr = try self.arena.create(HirStmt);
                        stmt_ptr.* = .{ .binding = bind_payload };
                        try self.commitNode(stmt_id, .{ .stmt = stmt_ptr }, inner.green);
                        try self.mapGreen(entry.green, stmt_id);
                        try stmts.append(self.gpa, stmt_ptr.*);
                    } else {
                        const item_stmt = try self.lowerStmtItemNode(entry.green, entry.start);
                        try stmts.append(self.gpa, item_stmt);
                    }
                }
            } else if (isDeclOrWrappedDecl(entry.green)) {
                const item_stmt = try self.lowerStmtItemNode(entry.green, entry.start);
                try stmts.append(self.gpa, item_stmt);
            }
        }

        return .{
            .id = id,
            .stmts = try self.dupeStmtsAndSyncNodes(stmts.items),
            .tail = tail,
            .range = trimmedRange(green, start_offset),
        };
    }

    /// 降低 `expression_statement` 内部的表达式子节点。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const HirExpr` 由 `self.arena` 分配。
    fn lowerExprStmtInner(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!*const HirExpr {
        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (isExprSyntaxKind(child.kind)) {
                return self.lowerExprNode(child, c_start);
            }
        }
        const placeholder = try self.allocPlaceholderExpr(trimmedRange(green, start_offset));
        for (green.children()) |child| {
            if (child.kind == .error_node) {
                try self.mapGreen(child, placeholder.id());
            }
        }
        return placeholder;
    }

    // =========================================================================
    // 表达式（HirExpr）
    // =========================================================================

    /// 降低任意表达式节点或字面量叶子为 `*const HirExpr`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const HirExpr` 由 `self.arena` 分配。
    fn lowerExprNode(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!*const HirExpr {
        // 1. 括号折叠：提取内层表达式并将 paren_expr 穿透映射到内层 HirId
        if (green.kind == .paren_expr) {
            var offset = start_offset;
            for (green.children()) |child| {
                const c_start = offset;
                offset +|= child.text_len;
                if (isExprSyntaxKind(child.kind)) {
                    const inner = try self.lowerExprNode(child, c_start);
                    try self.mapGreen(green, inner.id());
                    return inner;
                }
            }
            const placeholder = try self.allocPlaceholderExpr(trimmedRange(green, start_offset));
            try self.mapGreen(green, placeholder.id());
            for (green.children()) |child| {
                if (child.kind == .error_node) {
                    try self.mapGreen(child, placeholder.id());
                }
            }
            return placeholder;
        }

        // 2. 平铺点分路径：可能降级为单个 HirExpr.path，或转换为链式 HirExpr.field / HirExpr.optional
        if (green.kind == .path_expr) {
            return self.lowerPathOrFieldChain(green, start_offset);
        }

        // 3. 尾随闭包：合并到内层 call_expr / varray_expr 或新建 HirExpr.call
        if (green.kind == .trailing_closure_expr) {
            return self.lowerTrailingClosureExpr(green, start_offset);
        }

        // 4. 复合逻辑条件内的 `let_pattern_destructor`（如 `if (let Some(v) <- opt && v > 0)`）：
        // 按源码顺序先降低内部模式列表再降低右侧被解构表达式，并将 `let_pattern_destructor` 穿透映射到右侧表达式
        if (green.kind == .let_pattern_destructor) {
            var val: ?*const HirExpr = null;
            var seen_arrow = false;
            var offset = start_offset;
            for (green.children()) |child| {
                const c_start = offset;
                offset +|= child.text_len;
                if (child.kind == .backarrow) {
                    seen_arrow = true;
                } else if (!seen_arrow and isPatternSyntaxKind(child.kind)) {
                    _ = try self.lowerPatternNode(child, c_start);
                } else if (seen_arrow and val == null and isExprSyntaxKind(child.kind)) {
                    val = try self.lowerExprNode(child, c_start);
                }
            }
            const r = trimmedRange(green, start_offset);
            const val_ptr = val orelse try self.allocPlaceholderExpr(.{ .start = r.end, .end = r.end });
            try self.mapGreen(green, val_ptr.id());
            return val_ptr;
        }

        const id = try self.reserveHirId();
        const r = trimmedRange(green, start_offset);

        const expr_val: HirExpr = switch (green.kind) {
            .integer_literal => try self.lowerIntLit(id, green.tokenText() orelse "", r),
            .float_literal => try self.lowerFloatLit(id, green.tokenText() orelse "", r),
            .rune_literal => try self.lowerRuneLit(id, green.tokenText() orelse "", false, r),
            .rune_byte_literal => try self.lowerRuneLit(id, green.tokenText() orelse "", true, r),
            .string_literal => .{ .string_lit = .{
                .id = id,
                .text = green.tokenText() orelse "",
                .kind = .single,
                .range = r,
            } },
            .multiline_string => .{ .string_lit = .{
                .id = id,
                .text = green.tokenText() orelse "",
                .kind = .multiline,
                .range = r,
            } },
            .multiline_raw_string => .{ .string_lit = .{
                .id = id,
                .text = green.tokenText() orelse "",
                .kind = .raw_multiline,
                .range = r,
            } },
            .str_interpolation_expr => .{ .str_interp = try self.lowerStrInterpPayload(id, green, start_offset) },
            .bool_literal => .{ .bool_lit = .{
                .id = id,
                .value = std.mem.eql(u8, green.tokenText() orelse "", "true"),
                .range = r,
            } },
            .unit_literal => .{ .unit_lit = .{ .id = id, .range = r } },
            .wildcard_expr => .{ .wildcard = .{ .id = id, .range = r } },
            .optional_expr => blk: {
                const operand = try self.lowerFirstChildExpr(green, start_offset, r);
                break :blk .{ .optional = .{ .id = id, .operand = operand, .range = r } };
            },
            .call_expr => .{ .call = try self.lowerCallExprPayload(id, green, start_offset, null) },
            .subscript_expr => .{ .index = try self.lowerIndexExprPayload(id, green, start_offset) },
            .inc_or_dec_expr => blk: {
                var op: IncDecOp = .incr;
                var operand: ?*const HirExpr = null;
                var offset = start_offset;
                for (green.children()) |child| {
                    const c_start = offset;
                    offset +|= child.text_len;
                    if (IncDecOp.fromSyntaxKind(child.kind)) |mapped_op| {
                        op = mapped_op;
                    } else if (operand == null and isExprSyntaxKind(child.kind)) {
                        operand = try self.lowerExprNode(child, c_start);
                    }
                }
                const op_ptr = operand orelse try self.allocPlaceholderExpr(.{ .start = r.start, .end = r.start });
                break :blk .{ .inc_dec = .{ .id = id, .op = op, .operand = op_ptr, .range = r } };
            },
            .unary_expr => blk: {
                var op: UnaryOp = .neg;
                var operand: ?*const HirExpr = null;
                var offset = start_offset;
                for (green.children()) |child| {
                    const c_start = offset;
                    offset +|= child.text_len;
                    if (UnaryOp.fromSyntaxKind(child.kind)) |mapped_op| {
                        op = mapped_op;
                    } else if (operand == null and isExprSyntaxKind(child.kind)) {
                        operand = try self.lowerExprNode(child, c_start);
                    }
                }
                const op_ptr = operand orelse try self.allocPlaceholderExpr(.{ .start = r.end, .end = r.end });
                break :blk .{ .unary = .{ .id = id, .op = op, .operand = op_ptr, .range = r } };
            },
            .binary_expr => .{ .binary = try self.lowerBinaryExprPayload(id, green, start_offset) },
            .assign_expr => .{ .assign = try self.lowerAssignExprPayload(id, green, start_offset) },
            .range_expr => .{ .range_expr = try self.lowerRangeExprPayload(id, green, start_offset) },
            .is_expr, .as_expr => blk: {
                var operand: ?*const HirExpr = null;
                var ty: ?*const HirType = null;
                var seen_kw = false;
                var offset = start_offset;
                for (green.children()) |child| {
                    const c_start = offset;
                    offset +|= child.text_len;
                    if (child.kind == .kw_is or child.kind == .kw_as) {
                        seen_kw = true;
                    } else if (!seen_kw and operand == null and isExprSyntaxKind(child.kind)) {
                        operand = try self.lowerExprNode(child, c_start);
                    } else if (seen_kw and ty == null and isTypeSyntaxKind(child.kind)) {
                        ty = try self.lowerTypeNode(child, c_start);
                    }
                }
                const op_ptr = operand orelse try self.allocPlaceholderExpr(.{ .start = r.start, .end = r.start });
                const ty_ptr = ty orelse try self.allocPlaceholderType(.{ .start = r.end, .end = r.end });
                break :blk if (green.kind == .is_expr)
                    .{ .is_expr = .{ .id = id, .operand = op_ptr, .ty = ty_ptr, .range = r } }
                else
                    .{ .as_expr = .{ .id = id, .operand = op_ptr, .ty = ty_ptr, .range = r } };
            },
            .type_conv_expr => blk: {
                var ty: ?*const HirType = null;
                var val: ?*const HirExpr = null;
                var offset = start_offset;
                for (green.children()) |child| {
                    const c_start = offset;
                    offset +|= child.text_len;
                    if (ty == null and isTypeSyntaxKind(child.kind)) {
                        ty = try self.lowerTypeNode(child, c_start);
                    } else if (val == null and isExprSyntaxKind(child.kind)) {
                        val = try self.lowerExprNode(child, c_start);
                    }
                }
                const ty_ptr = ty orelse try self.allocPlaceholderType(.{ .start = r.start, .end = r.start });
                const val_ptr = val orelse try self.allocPlaceholderExpr(.{ .start = r.end, .end = r.end });
                break :blk .{ .type_conv = .{ .id = id, .ty = ty_ptr, .value = val_ptr, .range = r } };
            },
            .varray_expr => .{ .varray = try self.lowerVArrayExprPayload(id, green, start_offset, null) },
            .tuple_lit => blk: {
                var elems: std.ArrayListUnmanaged(HirExpr) = .empty;
                defer elems.deinit(self.gpa);
                var offset = start_offset;
                for (green.children()) |child| {
                    const c_start = offset;
                    offset +|= child.text_len;
                    if (isExprSyntaxKind(child.kind)) {
                        const e_ptr = try self.lowerExprNode(child, c_start);
                        try elems.append(self.gpa, e_ptr.*);
                    }
                }
                break :blk .{ .tuple_lit = .{
                    .id = id,
                    .elements = try self.dupeExprsAndSyncNodes(elems.items),
                    .range = r,
                } };
            },
            .array_lit => .{ .array_lit = try self.lowerArrayLitPayload(id, green, start_offset) },
            .block => .{ .block = try self.lowerBlockPayload(id, green, start_offset) },
            .if_expr => .{ .if_expr = try self.lowerIfExprPayload(id, green, start_offset) },
            .match_expr => .{ .match_expr = try self.lowerMatchExprPayload(id, green, start_offset) },
            .while_expr => .{ .while_expr = try self.lowerWhileExprPayload(id, green, start_offset) },
            .do_while_expr => .{ .do_while_expr = try self.lowerDoWhileExprPayload(id, green, start_offset) },
            .for_in_expr => .{ .for_in_expr = try self.lowerForInExprPayload(id, green, start_offset) },
            .try_expr => .{ .try_expr = try self.lowerTryExprPayload(id, green, start_offset) },
            .throw_expr => blk: {
                const val = try self.lowerFirstChildExpr(green, start_offset, .{ .start = r.end, .end = r.end });
                break :blk .{ .throw_expr = .{ .id = id, .value = val, .range = r } };
            },
            .return_expr => blk: {
                var val: ?*const HirExpr = null;
                var offset = start_offset;
                for (green.children()) |child| {
                    const c_start = offset;
                    offset +|= child.text_len;
                    if (isExprSyntaxKind(child.kind)) {
                        val = try self.lowerExprNode(child, c_start);
                        break;
                    }
                }
                break :blk .{ .return_expr = .{ .id = id, .value = val, .range = r } };
            },
            .jump_expr => blk: {
                var op: JumpOp = .break_;
                for (green.children()) |child| {
                    if (JumpOp.fromSyntaxKind(child.kind)) |mapped| {
                        op = mapped;
                        break;
                    }
                }
                break :blk .{ .jump = .{ .id = id, .op = op, .range = r } };
            },
            .lambda_expr => .{ .lambda = try self.lowerLambdaExprPayload(id, green, start_offset) },
            .spawn_expr => .{ .spawn = try self.lowerSpawnExprPayload(id, green, start_offset) },
            .synchronized_expr => .{ .synchronized = try self.lowerSynchronizedExprPayload(id, green, start_offset) },
            .unsafe_expr => blk: {
                var body: ?*const BlockExpr = null;
                var offset = start_offset;
                for (green.children()) |child| {
                    const c_start = offset;
                    offset +|= child.text_len;
                    if (child.kind == .block) {
                        body = try self.lowerBlockNode(child, c_start);
                        break;
                    }
                }
                const body_ptr = body orelse try self.allocPlaceholderBlock(.{ .start = r.end, .end = r.end });
                break :blk .{ .unsafe = .{ .id = id, .body = body_ptr, .range = r } };
            },
            .quote_expr => .{ .quote = try self.lowerQuoteExprPayload(id, green, start_offset) },
            .macro_expand_expr => .{ .macro_call = try self.lowerMacroCallExprPayload(id, green, start_offset) },
            .if_available_expr => blk: {
                var args: std.ArrayListUnmanaged(HirCallArg) = .empty;
                defer args.deinit(self.gpa);
                var offset = start_offset;
                for (green.children()) |child| {
                    const c_start = offset;
                    offset +|= child.text_len;
                    if (child.kind == .func_arg) {
                        try args.append(self.gpa, try self.lowerCallArg(child, c_start));
                    }
                }
                break :blk .{ .if_available = .{
                    .id = id,
                    .args = try self.arena.dupe(HirCallArg, args.items),
                    .range = r,
                } };
            },
            .perform_expr => blk: {
                const val = try self.lowerFirstChildExpr(green, start_offset, .{ .start = r.end, .end = r.end });
                break :blk .{ .perform = .{ .id = id, .value = val, .range = r } };
            },
            .resume_expr => .{ .resume_expr = try self.lowerResumeExprPayload(id, green, start_offset) },
            else => .{ .unit_lit = .{ .id = id, .range = r } },
        };

        const expr_ptr = try self.arena.create(HirExpr);
        expr_ptr.* = expr_val;
        try self.commitNode(id, .{ .expr = expr_ptr }, green);
        return expr_ptr;
    }

    /// 降低平铺的 `path_expr` 节点：
    /// - 若首段为名称（标识符、`this`、`super`、`This` 或基础类型名）且全链不含 `?`（`quest`），
    ///   降级为单个 `HirExpr.path`，并将外层 `path_expr` 及各 `path_segment` 均映射到该 `HirId`。
    /// - 若首段包裹了非名称表达式（如 `g().b.c` 中的 `call_expr`）或链中含 `?.`（`a?.b.c`），
    ///   按左结合依次构造接收者表达式、可选 `HirExpr.optional` 与链式 `HirExpr.field`，
    ///   将每个 `path_segment` 精确映射到对应层级的 `HirId`，并将外层 `path_expr` 映射到最外层结果的 `HirId`（P0-4）。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const HirExpr` 由 `self.arena` 分配。
    fn lowerPathOrFieldChain(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!*const HirExpr {
        var has_quest = false;
        var first_seg_is_expr = false;
        var seen_first_seg = false;

        for (green.children()) |child| {
            if (child.kind == .quest) {
                has_quest = true;
            } else if (child.kind == .path_segment and !seen_first_seg) {
                seen_first_seg = true;
                first_seg_is_expr = pathSegmentContainsExpr(child);
            }
        }

        const r = trimmedRange(green, start_offset);
        if (!has_quest and !first_seg_is_expr) {
            const id = try self.reserveHirId();
            var segs: std.ArrayListUnmanaged(ExprPathSegment) = .empty;
            defer segs.deinit(self.gpa);

            var offset = start_offset;
            for (green.children()) |child| {
                const c_start = offset;
                offset +|= child.text_len;
                if (child.kind == .path_segment) {
                    try segs.append(self.gpa, try self.lowerExprPathSegment(child, c_start));
                    try self.mapGreen(child, id);
                }
            }
            if (segs.items.len == 0) {
                try segs.append(self.gpa, .{ .name = emptyNameAt(r.start) });
            }
            const expr_ptr = try self.arena.create(HirExpr);
            expr_ptr.* = .{ .path = .{
                .id = id,
                .segments = try self.arena.dupe(ExprPathSegment, segs.items),
                .range = r,
            } };
            try self.commitNode(id, .{ .expr = expr_ptr }, green);
            return expr_ptr;
        }

        // 转换为链式接收者 + optional + field
        var current_base: ?*const HirExpr = null;
        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;

            if (child.kind == .path_segment) {
                if (current_base == null) {
                    if (findExprInPathSegment(child, c_start)) |inner_expr_loc| {
                        const base_expr = try self.lowerExprNode(inner_expr_loc.green, inner_expr_loc.start);
                        try self.mapGreen(child, base_expr.id());
                        current_base = base_expr;
                    } else {
                        const base_id = try self.reserveHirId();
                        const seg = try self.lowerExprPathSegment(child, c_start);
                        const seg_range = trimmedRange(child, c_start);
                        const base_ptr = try self.arena.create(HirExpr);
                        base_ptr.* = .{ .path = .{
                            .id = base_id,
                            .segments = try self.arena.dupe(ExprPathSegment, &.{seg}),
                            .range = seg_range,
                        } };
                        try self.commitNode(base_id, .{ .expr = base_ptr }, child);
                        current_base = base_ptr;
                    }
                } else {
                    const field_id = try self.reserveHirId();
                    const seg = try self.lowerExprPathSegment(child, c_start);
                    const seg_range = trimmedRange(child, c_start);
                    const base_ptr = current_base.?;
                    const field_ptr = try self.arena.create(HirExpr);
                    field_ptr.* = .{ .field = .{
                        .id = field_id,
                        .base = base_ptr,
                        .name = seg.name,
                        .type_args = seg.type_args,
                        .range = .{ .start = base_ptr.range().start, .end = seg_range.end },
                    } };
                    try self.commitNode(field_id, .{ .expr = field_ptr }, child);
                    current_base = field_ptr;
                }
            } else if (child.kind == .quest) {
                if (current_base) |base_ptr| {
                    const opt_id = try self.reserveHirId();
                    const opt_ptr = try self.arena.create(HirExpr);
                    opt_ptr.* = .{ .optional = .{
                        .id = opt_id,
                        .operand = base_ptr,
                        .range = .{ .start = base_ptr.range().start, .end = c_start + child.text_len },
                    } };
                    try self.commitNode(opt_id, .{ .expr = opt_ptr }, null);
                    current_base = opt_ptr;
                }
            }
        }

        const final_expr = current_base orelse try self.allocPlaceholderExpr(r);
        try self.mapGreen(green, final_expr.id());
        return final_expr;
    }

    /// 降低表达式路径中的单个 `path_segment`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `ExprPathSegment` 内部切片由 `self.arena` 分配。
    fn lowerExprPathSegment(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!ExprPathSegment {
        var name: ?Name = null;
        var type_args: []const HirType = &.{};

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (name == null and isExprSegmentNameKind(child.kind)) {
                name = extractNameFromLeaf(child, c_start);
            } else if (child.kind == .type_argument_list) {
                type_args = try self.lowerTypeArgumentList(child, c_start);
            }
        }
        const r = trimmedRange(green, start_offset);
        return .{
            .name = name orelse emptyNameAt(r.start),
            .type_args = type_args,
        };
    }

    /// 降低 `trailing_closure_expr`（`f(a) { ... }` 或 `f { ... }`），
    /// 按源码顺序依次分配调用节点、被调用者、实参列表与尾随闭包的 `HirId`，
    /// 并确保外层 `trailing_closure_expr` 与被包裹的内层 `call_expr`/`varray_expr` 均映射到生成的调用节点 `HirId`（P1-3）。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const HirExpr` 由 `self.arena` 分配。
    fn lowerTrailingClosureExpr(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!*const HirExpr {
        var target_loc: ?LocatedGreen = null;
        var lambda_loc: ?LocatedGreen = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .lambda_expr and target_loc != null) {
                lambda_loc = .{ .green = child, .start = c_start };
            } else if (target_loc == null and isExprSyntaxKind(child.kind)) {
                target_loc = .{ .green = child, .start = c_start };
            }
        }

        const r = trimmedRange(green, start_offset);
        if (target_loc) |tl| {
            if (tl.green.kind == .call_expr) {
                const call_id = try self.reserveHirId();
                var payload = try self.lowerCallExprPayload(call_id, tl.green, tl.start, null);
                if (lambda_loc) |ll| {
                    payload.trailing_lambda = try self.lowerExprNode(ll.green, ll.start);
                }
                payload.range = r;
                const call_ptr = try self.arena.create(HirExpr);
                call_ptr.* = .{ .call = payload };
                try self.commitNode(call_id, .{ .expr = call_ptr }, green);
                try self.mapGreen(tl.green, call_id);
                return call_ptr;
            }
            if (tl.green.kind == .varray_expr) {
                const va_id = try self.reserveHirId();
                var payload = try self.lowerVArrayExprPayload(va_id, tl.green, tl.start, null);
                if (lambda_loc) |ll| {
                    payload.trailing_lambda = try self.lowerExprNode(ll.green, ll.start);
                }
                payload.range = r;
                const va_ptr = try self.arena.create(HirExpr);
                va_ptr.* = .{ .varray = payload };
                try self.commitNode(va_id, .{ .expr = va_ptr }, green);
                try self.mapGreen(tl.green, va_id);
                return va_ptr;
            }

            const call_id = try self.reserveHirId();
            const callee_ptr = try self.lowerExprNode(tl.green, tl.start);
            const lambda_ptr: ?*const HirExpr = if (lambda_loc) |ll|
                try self.lowerExprNode(ll.green, ll.start)
            else
                null;
            const call_ptr = try self.arena.create(HirExpr);
            call_ptr.* = .{ .call = .{
                .id = call_id,
                .callee = callee_ptr,
                .args = &.{},
                .trailing_lambda = lambda_ptr,
                .range = r,
            } };
            try self.commitNode(call_id, .{ .expr = call_ptr }, green);
            return call_ptr;
        }

        if (lambda_loc) |ll| {
            const l_ptr = try self.lowerExprNode(ll.green, ll.start);
            try self.mapGreen(green, l_ptr.id());
            return l_ptr;
        }

        const placeholder = try self.allocPlaceholderExpr(r);
        try self.mapGreen(green, placeholder.id());
        return placeholder;
    }

    /// 降低 `call_expr` 载荷。
    ///
    /// 指针内存约定：`green` 与 `trailing_lambda` 仅作只读借用；返回的 `CallExpr` 内部指针与切片由 `self.arena` 分配。
    fn lowerCallExprPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
        trailing_lambda: ?*const HirExpr,
    ) std.mem.Allocator.Error!common.CallExpr {
        var callee: ?*const HirExpr = null;
        var args: std.ArrayListUnmanaged(HirCallArg) = .empty;
        defer args.deinit(self.gpa);

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (callee == null and isExprSyntaxKind(child.kind)) {
                callee = try self.lowerExprNode(child, c_start);
            } else if (child.kind == .func_arg) {
                try args.append(self.gpa, try self.lowerCallArg(child, c_start));
            }
        }

        const r = trimmedRange(green, start_offset);
        const callee_ptr = callee orelse try self.allocPlaceholderExpr(.{ .start = r.start, .end = r.start });
        return .{
            .id = id,
            .callee = callee_ptr,
            .args = try self.arena.dupe(HirCallArg, args.items),
            .trailing_lambda = trailing_lambda,
            .range = r,
        };
    }

    /// 降低单个调用或注解实参 `func_arg`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `HirCallArg.value` 由 `self.arena` 分配。
    fn lowerCallArg(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!HirCallArg {
        var name: ?Name = null;
        var is_inout = false;
        var val: ?*const HirExpr = null;

        const has_colon = green.childOfKind(.colon) != null;
        var seen_colon = false;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (has_colon and !seen_colon) {
                if (child.kind == .colon) {
                    seen_colon = true;
                } else if (name == null and isNameTokenKind(child.kind)) {
                    name = extractNameFromLeaf(child, c_start);
                }
            } else if (child.kind == .kw_inout) {
                is_inout = true;
            } else if (val == null and isExprSyntaxKind(child.kind)) {
                val = try self.lowerExprNode(child, c_start);
            }
        }

        const r = trimmedRange(green, start_offset);
        const val_ptr = val orelse try self.allocPlaceholderExpr(.{ .start = r.end, .end = r.end });
        return .{
            .name = name,
            .is_inout = is_inout,
            .value = val_ptr,
            .range = r,
        };
    }

    /// 降低 `subscript_expr` 为 `IndexExpr`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `IndexExpr` 内部指针与切片由 `self.arena` 分配。
    fn lowerIndexExprPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.IndexExpr {
        var base: ?*const HirExpr = null;
        var indices: std.ArrayListUnmanaged(HirExpr) = .empty;
        defer indices.deinit(self.gpa);
        var in_brackets = false;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .l_square) {
                in_brackets = true;
            } else if (!in_brackets and base == null and isExprSyntaxKind(child.kind)) {
                base = try self.lowerExprNode(child, c_start);
            } else if (in_brackets and isExprSyntaxKind(child.kind)) {
                const idx_ptr = try self.lowerExprNode(child, c_start);
                try indices.append(self.gpa, idx_ptr.*);
            }
        }

        const r = trimmedRange(green, start_offset);
        const base_ptr = base orelse try self.allocPlaceholderExpr(.{ .start = r.start, .end = r.start });
        return .{
            .id = id,
            .base = base_ptr,
            .indices = try self.dupeExprsAndSyncNodes(indices.items),
            .range = r,
        };
    }

    /// 降低 `binary_expr` 为 `BinaryExpr`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `BinaryExpr` 内部指针由 `self.arena` 分配。
    fn lowerBinaryExprPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.BinaryExpr {
        var op: BinaryOp = .add;
        var lhs: ?*const HirExpr = null;
        var rhs: ?*const HirExpr = null;
        var seen_op = false;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (!seen_op and BinaryOp.fromSyntaxKind(child.kind) != null) {
                op = BinaryOp.fromSyntaxKind(child.kind).?;
                seen_op = true;
            } else if (isExprSyntaxKind(child.kind)) {
                if (lhs == null) {
                    lhs = try self.lowerExprNode(child, c_start);
                } else if (rhs == null) {
                    rhs = try self.lowerExprNode(child, c_start);
                }
            }
        }

        const r = trimmedRange(green, start_offset);
        const lhs_ptr = lhs orelse try self.allocPlaceholderExpr(.{ .start = r.start, .end = r.start });
        const rhs_ptr = rhs orelse try self.allocPlaceholderExpr(.{ .start = r.end, .end = r.end });
        return .{
            .id = id,
            .op = op,
            .lhs = lhs_ptr,
            .rhs = rhs_ptr,
            .range = r,
        };
    }

    /// 降低 `assign_expr` 为 `AssignExpr`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `AssignExpr` 内部指针由 `self.arena` 分配。
    fn lowerAssignExprPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.AssignExpr {
        var op: AssignOp = .assign;
        var lhs: ?*const HirExpr = null;
        var rhs: ?*const HirExpr = null;
        var seen_op = false;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (!seen_op and AssignOp.fromSyntaxKind(child.kind) != null) {
                op = AssignOp.fromSyntaxKind(child.kind).?;
                seen_op = true;
            } else if (isExprSyntaxKind(child.kind)) {
                if (lhs == null) {
                    lhs = try self.lowerExprNode(child, c_start);
                } else if (rhs == null) {
                    rhs = try self.lowerExprNode(child, c_start);
                }
            }
        }

        const r = trimmedRange(green, start_offset);
        const lhs_ptr = lhs orelse try self.allocPlaceholderExpr(.{ .start = r.start, .end = r.start });
        const rhs_ptr = rhs orelse try self.allocPlaceholderExpr(.{ .start = r.end, .end = r.end });
        return .{
            .id = id,
            .op = op,
            .lhs = lhs_ptr,
            .rhs = rhs_ptr,
            .range = r,
        };
    }

    /// 降低 `range_expr` 为 `RangeExpr`（支持 `a..b`、`a..=b:step`、`..b`、`a..`）。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `RangeExpr` 内部指针由 `self.arena` 分配。
    fn lowerRangeExprPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.RangeExpr {
        var start_expr: ?*const HirExpr = null;
        var end_expr: ?*const HirExpr = null;
        var step_expr: ?*const HirExpr = null;
        var inclusive = false;
        var seen_op = false;
        var seen_colon = false;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .range_op) {
                seen_op = true;
                inclusive = false;
            } else if (child.kind == .closed_range_op) {
                seen_op = true;
                inclusive = true;
            } else if (child.kind == .colon) {
                seen_colon = true;
            } else if (isExprSyntaxKind(child.kind)) {
                if (!seen_op) {
                    start_expr = try self.lowerExprNode(child, c_start);
                } else if (!seen_colon) {
                    end_expr = try self.lowerExprNode(child, c_start);
                } else {
                    step_expr = try self.lowerExprNode(child, c_start);
                }
            }
        }

        return .{
            .id = id,
            .start = start_expr,
            .end = end_expr,
            .inclusive = inclusive,
            .step = step_expr,
            .range = trimmedRange(green, start_offset),
        };
    }

    /// 降低 `varray_expr` 为 `VArrayExpr`。
    ///
    /// 指针内存约定：`green` 与 `trailing_lambda` 仅作只读借用；返回的 `VArrayExpr` 内部指针与切片由 `self.arena` 分配。
    fn lowerVArrayExprPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
        trailing_lambda: ?*const HirExpr,
    ) std.mem.Allocator.Error!common.VArrayExpr {
        var ty: ?*const HirType = null;
        var args: std.ArrayListUnmanaged(HirCallArg) = .empty;
        defer args.deinit(self.gpa);
        var lambda: ?*const HirExpr = trailing_lambda;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (ty == null and child.kind == .varray_type) {
                ty = try self.lowerTypeNode(child, c_start);
            } else if (child.kind == .func_arg) {
                try args.append(self.gpa, try self.lowerCallArg(child, c_start));
            } else if (lambda == null and child.kind == .lambda_expr) {
                lambda = try self.lowerExprNode(child, c_start);
            }
        }

        const r = trimmedRange(green, start_offset);
        const ty_ptr = ty orelse try self.allocPlaceholderType(.{ .start = r.start, .end = r.start });
        return .{
            .id = id,
            .ty = ty_ptr,
            .args = try self.arena.dupe(HirCallArg, args.items),
            .trailing_lambda = lambda,
            .range = r,
        };
    }

    /// 降低 `array_lit` 为 `ArrayLit`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `ArrayLit` 内部指针与切片由 `self.arena` 分配。
    fn lowerArrayLitPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.ArrayLit {
        var elems: std.ArrayListUnmanaged(ArrayElement) = .empty;
        defer elems.deinit(self.gpa);

        var pending_spread = false;
        var spread_start: u32 = 0;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .mul) {
                pending_spread = true;
                spread_start = c_start;
            } else if (isExprSyntaxKind(child.kind)) {
                const val_ptr = try self.lowerExprNode(child, c_start);
                const e_start = if (pending_spread) spread_start else val_ptr.range().start;
                try elems.append(self.gpa, .{
                    .spread = pending_spread,
                    .value = val_ptr,
                    .range = .{ .start = e_start, .end = val_ptr.range().end },
                });
                pending_spread = false;
            } else if (child.kind == .comma) {
                pending_spread = false;
            }
        }

        return .{
            .id = id,
            .elements = try self.arena.dupe(ArrayElement, elems.items),
            .range = trimmedRange(green, start_offset),
        };
    }

    /// 降低 `if` 或 `while` 的条件（普通表达式或 `let_pattern_destructor`）。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `HirCondition` 内部指针与切片由 `self.arena` 分配。
    fn lowerCondition(
        self: *Lowerer,
        owner_id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!HirCondition {
        if (green.kind == .paren_expr) {
            var offset = start_offset;
            for (green.children()) |child| {
                const c_start = offset;
                offset +|= child.text_len;
                if (child.kind == .let_pattern_destructor or child.kind == .paren_expr) {
                    const inner_cond = try self.lowerCondition(owner_id, child, c_start);
                    if (inner_cond == .let_destructor) {
                        try self.mapGreen(green, owner_id);
                    } else {
                        try self.mapGreen(green, inner_cond.expr.id());
                    }
                    return inner_cond;
                }
            }
        }
        if (green.kind == .let_pattern_destructor) {
            var pats: std.ArrayListUnmanaged(HirPattern) = .empty;
            defer pats.deinit(self.gpa);
            var val: ?*const HirExpr = null;
            var seen_arrow = false;

            var offset = start_offset;
            for (green.children()) |child| {
                const c_start = offset;
                offset +|= child.text_len;
                if (child.kind == .backarrow) {
                    seen_arrow = true;
                } else if (!seen_arrow and isPatternSyntaxKind(child.kind)) {
                    const p_ptr = try self.lowerPatternNode(child, c_start);
                    try pats.append(self.gpa, p_ptr.*);
                } else if (seen_arrow and val == null and isExprSyntaxKind(child.kind)) {
                    val = try self.lowerExprNode(child, c_start);
                }
            }
            const r = trimmedRange(green, start_offset);
            if (pats.items.len == 0) {
                const dummy_p = try self.allocPlaceholderPattern(.{ .start = r.start, .end = r.start });
                try pats.append(self.gpa, dummy_p.*);
            }
            const val_ptr = val orelse try self.allocPlaceholderExpr(.{ .start = r.end, .end = r.end });
            try self.mapGreen(green, owner_id);
            return .{ .let_destructor = .{
                .patterns = try self.dupePatternsAndSyncNodes(pats.items),
                .value = val_ptr,
                .range = r,
            } };
        }
        return .{ .expr = try self.lowerExprNode(green, start_offset) };
    }

    /// 降低 `if_expr` 为 `IfExpr`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `IfExpr` 内部指针与切片由 `self.arena` 分配。
    fn lowerIfExprPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.IfExpr {
        var cond: ?HirCondition = null;
        var then_branch: ?*const BlockExpr = null;
        var else_branch: ?*const HirExpr = null;
        var seen_rparen = false;
        var seen_else = false;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .r_paren) {
                seen_rparen = true;
            } else if (child.kind == .kw_else) {
                seen_else = true;
            } else if (!seen_rparen and cond == null and (child.kind == .let_pattern_destructor or isExprSyntaxKind(child.kind))) {
                cond = try self.lowerCondition(id, child, c_start);
            } else if (!seen_else and then_branch == null and child.kind == .block) {
                then_branch = try self.lowerBlockNode(child, c_start);
            } else if (seen_else and else_branch == null and (child.kind == .block or child.kind == .if_expr)) {
                else_branch = try self.lowerExprNode(child, c_start);
            }
        }

        const r = trimmedRange(green, start_offset);
        const final_cond = cond orelse HirCondition{
            .expr = try self.allocPlaceholderExpr(.{ .start = r.start, .end = r.start }),
        };
        const final_then = then_branch orelse try self.allocPlaceholderBlock(.{ .start = r.end, .end = r.end });
        return .{
            .id = id,
            .condition = final_cond,
            .then_branch = final_then,
            .else_branch = else_branch,
            .range = r,
        };
    }

    /// 降低 `match_expr` 为 `MatchExpr`。
    ///
    /// 分支下的 `stmt_list` 会降低为独立 `*const BlockExpr` 并写入 `GreenToHirMap`（P1-2）。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `MatchExpr` 内部指针与切片由 `self.arena` 分配。
    fn lowerMatchExprPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.MatchExpr {
        var selector: ?*const HirExpr = null;
        var cases: std.ArrayListUnmanaged(MatchCase) = .empty;
        defer cases.deinit(self.gpa);
        var in_braces = false;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .l_curl) {
                in_braces = true;
            } else if (!in_braces and selector == null and isExprSyntaxKind(child.kind)) {
                selector = try self.lowerExprNode(child, c_start);
            } else if (child.kind == .match_case) {
                try cases.append(self.gpa, .{ .pattern = try self.lowerPatternCase(child, c_start) });
            } else if (child.kind == .match_case_other) {
                try cases.append(self.gpa, .{ .expr = try self.lowerExprCase(child, c_start) });
            }
        }

        return .{
            .id = id,
            .selector = selector,
            .cases = try self.arena.dupe(MatchCase, cases.items),
            .range = trimmedRange(green, start_offset),
        };
    }

    /// 降低 `match_case` 为 `PatternCase`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `PatternCase` 内部指针与切片由 `self.arena` 分配。
    fn lowerPatternCase(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!PatternCase {
        var pats: std.ArrayListUnmanaged(HirPattern) = .empty;
        defer pats.deinit(self.gpa);
        var guard: ?*const HirExpr = null;
        var body: ?*const BlockExpr = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (isPatternSyntaxKind(child.kind)) {
                const p_ptr = try self.lowerPatternNode(child, c_start);
                try pats.append(self.gpa, p_ptr.*);
            } else if (child.kind == .pattern_guard) {
                guard = try self.lowerPatternGuard(child, c_start);
            } else if (child.kind == .stmt_list) {
                body = try self.lowerBlockNode(child, c_start);
            }
        }

        const r = trimmedRange(green, start_offset);
        if (pats.items.len == 0) {
            const dummy_p = try self.allocPlaceholderPattern(.{ .start = r.start, .end = r.start });
            try pats.append(self.gpa, dummy_p.*);
        }
        const body_ptr = body orelse try self.allocPlaceholderBlock(.{ .start = r.end, .end = r.end });
        return .{
            .patterns = try self.dupePatternsAndSyncNodes(pats.items),
            .guard = guard,
            .body = body_ptr,
            .range = r,
        };
    }

    /// 降低 `match_case_other` 为 `ExprCase`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `ExprCase` 内部指针由 `self.arena` 分配。
    fn lowerExprCase(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!ExprCase {
        var val: ?*const HirExpr = null;
        var body: ?*const BlockExpr = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (val == null and child.kind == .wildcard_pattern) {
                const w_id = try self.reserveHirId();
                const w_ptr = try self.arena.create(HirExpr);
                w_ptr.* = .{ .wildcard = .{
                    .id = w_id,
                    .range = trimmedRange(child, c_start),
                } };
                try self.commitNode(w_id, .{ .expr = w_ptr }, child);
                val = w_ptr;
            } else if (val == null and isExprSyntaxKind(child.kind)) {
                val = try self.lowerExprNode(child, c_start);
            } else if (child.kind == .stmt_list) {
                body = try self.lowerBlockNode(child, c_start);
            }
        }

        const r = trimmedRange(green, start_offset);
        const val_ptr = val orelse try self.allocPlaceholderExpr(.{ .start = r.start, .end = r.start });
        const body_ptr = body orelse try self.allocPlaceholderBlock(.{ .start = r.end, .end = r.end });
        return .{
            .value = val_ptr,
            .body = body_ptr,
            .range = r,
        };
    }

    /// 降低 `pattern_guard`（`where cond`）内部的守卫表达式。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const HirExpr` 由 `self.arena` 分配。
    fn lowerPatternGuard(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!*const HirExpr {
        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (isExprSyntaxKind(child.kind)) {
                const expr_ptr = try self.lowerExprNode(child, c_start);
                try self.mapGreen(green, expr_ptr.id());
                return expr_ptr;
            }
        }
        return self.allocPlaceholderExpr(trimmedRange(green, start_offset));
    }

    /// 降低 `while_expr` 为 `WhileExpr`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `WhileExpr` 内部指针与切片由 `self.arena` 分配。
    fn lowerWhileExprPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.WhileExpr {
        var cond: ?HirCondition = null;
        var body: ?*const BlockExpr = null;
        var seen_rparen = false;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .r_paren) {
                seen_rparen = true;
            } else if (!seen_rparen and cond == null and (child.kind == .let_pattern_destructor or isExprSyntaxKind(child.kind))) {
                cond = try self.lowerCondition(id, child, c_start);
            } else if (body == null and child.kind == .block) {
                body = try self.lowerBlockNode(child, c_start);
            }
        }

        const r = trimmedRange(green, start_offset);
        const final_cond = cond orelse HirCondition{
            .expr = try self.allocPlaceholderExpr(.{ .start = r.start, .end = r.start }),
        };
        const final_body = body orelse try self.allocPlaceholderBlock(.{ .start = r.end, .end = r.end });
        return .{
            .id = id,
            .condition = final_cond,
            .body = final_body,
            .range = r,
        };
    }

    /// 降低 `do_while_expr` 为 `DoWhileExpr`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `DoWhileExpr` 内部指针由 `self.arena` 分配。
    fn lowerDoWhileExprPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.DoWhileExpr {
        var body: ?*const BlockExpr = null;
        var cond: ?*const HirExpr = null;
        var seen_while = false;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .kw_while) {
                seen_while = true;
            } else if (!seen_while and body == null and child.kind == .block) {
                body = try self.lowerBlockNode(child, c_start);
            } else if (seen_while and cond == null and isExprSyntaxKind(child.kind)) {
                cond = try self.lowerExprNode(child, c_start);
            }
        }

        const r = trimmedRange(green, start_offset);
        const final_body = body orelse try self.allocPlaceholderBlock(.{ .start = r.start, .end = r.start });
        const final_cond = cond orelse try self.allocPlaceholderExpr(.{ .start = r.end, .end = r.end });
        return .{
            .id = id,
            .body = final_body,
            .condition = final_cond,
            .range = r,
        };
    }

    /// 降低 `for_in_expr` 为 `ForInExpr`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `ForInExpr` 内部指针由 `self.arena` 分配。
    fn lowerForInExprPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.ForInExpr {
        var pat: ?*const HirPattern = null;
        var iterable: ?*const HirExpr = null;
        var guard: ?*const HirExpr = null;
        var body: ?*const BlockExpr = null;
        var seen_in = false;
        var seen_rparen = false;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .kw_in) {
                seen_in = true;
            } else if (child.kind == .r_paren) {
                seen_rparen = true;
            } else if (!seen_in and pat == null and isPatternSyntaxKind(child.kind)) {
                pat = try self.lowerPatternNode(child, c_start);
            } else if (seen_in and !seen_rparen and child.kind == .pattern_guard) {
                guard = try self.lowerPatternGuard(child, c_start);
            } else if (seen_in and !seen_rparen and iterable == null and isExprSyntaxKind(child.kind)) {
                iterable = try self.lowerExprNode(child, c_start);
            } else if (body == null and child.kind == .block) {
                body = try self.lowerBlockNode(child, c_start);
            }
        }

        const r = trimmedRange(green, start_offset);
        const pat_ptr = pat orelse try self.allocPlaceholderPattern(.{ .start = r.start, .end = r.start });
        const iter_ptr = iterable orelse try self.allocPlaceholderExpr(.{ .start = r.start, .end = r.start });
        const body_ptr = body orelse try self.allocPlaceholderBlock(.{ .start = r.end, .end = r.end });
        return .{
            .id = id,
            .pattern = pat_ptr,
            .iterable = iter_ptr,
            .guard = guard,
            .body = body_ptr,
            .range = r,
        };
    }

    /// 降低 `try_expr` 为 `TryExpr`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `TryExpr` 内部指针与切片由 `self.arena` 分配。
    fn lowerTryExprPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.TryExpr {
        var resources: std.ArrayListUnmanaged(Resource) = .empty;
        defer resources.deinit(self.gpa);
        var clauses: std.ArrayListUnmanaged(TryClause) = .empty;
        defer clauses.deinit(self.gpa);
        var body: ?*const BlockExpr = null;
        var finally_block: ?*const BlockExpr = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .resource_spec) {
                const res_ptr = try self.lowerResourceNode(child, c_start);
                try resources.append(self.gpa, res_ptr.*);
            } else if (child.kind == .block and body == null) {
                body = try self.lowerBlockNode(child, c_start);
            } else if (child.kind == .catch_clause) {
                try clauses.append(self.gpa, .{ .catch_ = try self.lowerCatchClause(child, c_start) });
            } else if (child.kind == .handle_clause) {
                try clauses.append(self.gpa, .{ .handle = try self.lowerHandleClause(child, c_start) });
            } else if (child.kind == .finally_clause) {
                var fin_off = c_start;
                for (child.children()) |f_child| {
                    const f_start = fin_off;
                    fin_off +|= f_child.text_len;
                    if (f_child.kind == .block) {
                        const fb = try self.lowerBlockNode(f_child, f_start);
                        try self.mapGreen(child, fb.id);
                        finally_block = fb;
                        break;
                    }
                }
            }
        }

        const r = trimmedRange(green, start_offset);
        const body_ptr = body orelse try self.allocPlaceholderBlock(.{ .start = r.end, .end = r.end });
        return .{
            .id = id,
            .resources = try self.dupeResourcesAndSyncNodes(resources.items),
            .body = body_ptr,
            .clauses = try self.arena.dupe(TryClause, clauses.items),
            .finally = finally_block,
            .range = r,
        };
    }

    /// 降低 `resource_spec` 为 `*const Resource`，分配 `HirId` 并记入 `nodes_buf` 与 `GreenToHirMap`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const Resource` 由 `self.arena` 分配。
    fn lowerResourceNode(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!*const Resource {
        const id = try self.reserveHirId();
        var name: ?Name = null;
        var ty: ?*const HirType = null;
        var init_expr: ?*const HirExpr = null;
        var seen_assign = false;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .assign) {
                seen_assign = true;
            } else if (!seen_assign and name == null and isNameTokenKind(child.kind)) {
                name = extractNameFromLeaf(child, c_start);
            } else if (!seen_assign and ty == null and isTypeSyntaxKind(child.kind)) {
                ty = try self.lowerTypeNode(child, c_start);
            } else if (seen_assign and init_expr == null and isExprSyntaxKind(child.kind)) {
                init_expr = try self.lowerExprNode(child, c_start);
            }
        }

        const r = trimmedRange(green, start_offset);
        const res_ptr = try self.arena.create(Resource);
        res_ptr.* = .{
            .id = id,
            .name = name orelse emptyNameAt(r.start),
            .ty = ty,
            .init = init_expr,
            .range = r,
        };
        try self.commitNode(id, .{ .resource = res_ptr }, green);
        return res_ptr;
    }

    /// 降低 `catch_clause` 为 `CatchClause`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `CatchClause` 内部指针由 `self.arena` 分配。
    fn lowerCatchClause(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!CatchClause {
        var pat: ?*const HirPattern = null;
        var body: ?*const BlockExpr = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (pat == null and isPatternSyntaxKind(child.kind)) {
                pat = try self.lowerPatternNode(child, c_start);
            } else if (body == null and child.kind == .block) {
                body = try self.lowerBlockNode(child, c_start);
            }
        }
        const r = trimmedRange(green, start_offset);
        return .{
            .pattern = pat orelse try self.allocPlaceholderPattern(.{ .start = r.start, .end = r.start }),
            .body = body orelse try self.allocPlaceholderBlock(.{ .start = r.end, .end = r.end }),
            .range = r,
        };
    }

    /// 降低 `handle_clause` 为 `HandleClause`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `HandleClause` 内部指针由 `self.arena` 分配。
    fn lowerHandleClause(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!HandleClause {
        const c = try self.lowerCatchClause(green, start_offset);
        return .{
            .pattern = c.pattern,
            .body = c.body,
            .range = c.range,
        };
    }

    /// 降低 `lambda_expr` 为 `LambdaExpr`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `LambdaExpr` 内部指针与切片由 `self.arena` 分配。
    fn lowerLambdaExprPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.LambdaExpr {
        var annos: std.ArrayListUnmanaged(Annotation) = .empty;
        defer annos.deinit(self.gpa);
        var params: []const Param = &.{};
        var is_variadic = false;
        var body: ?*const BlockExpr = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .annotation) {
                try annos.append(self.gpa, try self.lowerAnnotation(child, c_start));
            } else if (child.kind == .func_param_list) {
                const pl = try self.lowerFuncParamList(child, c_start);
                params = pl.params;
                is_variadic = pl.is_variadic;
            } else if (child.kind == .block) {
                body = try self.lowerBlockNode(child, c_start);
            }
        }

        const r = trimmedRange(green, start_offset);
        const body_ptr = body orelse try self.allocPlaceholderBlock(r);
        return .{
            .id = id,
            .annotations = try self.arena.dupe(Annotation, annos.items),
            .params = params,
            .is_variadic = is_variadic,
            .body = body_ptr,
            .range = r,
        };
    }

    /// 降低 `spawn_expr` 为 `SpawnExpr`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `SpawnExpr` 内部指针由 `self.arena` 分配。
    fn lowerSpawnExprPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.SpawnExpr {
        var context: ?*const HirExpr = null;
        var task: ?*const HirExpr = null;
        var in_parens = false;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .l_paren) {
                in_parens = true;
            } else if (child.kind == .r_paren) {
                in_parens = false;
            } else if (in_parens and context == null and isExprSyntaxKind(child.kind)) {
                context = try self.lowerExprNode(child, c_start);
            } else if (!in_parens and task == null and isExprSyntaxKind(child.kind)) {
                task = try self.lowerExprNode(child, c_start);
            }
        }

        const r = trimmedRange(green, start_offset);
        const task_ptr = task orelse try self.allocPlaceholderExpr(.{ .start = r.end, .end = r.end });
        return .{
            .id = id,
            .context = context,
            .task = task_ptr,
            .range = r,
        };
    }

    /// 降低 `synchronized_expr` 为 `SynchronizedExpr`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `SynchronizedExpr` 内部指针由 `self.arena` 分配。
    fn lowerSynchronizedExprPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.SynchronizedExpr {
        var mutex: ?*const HirExpr = null;
        var body: ?*const BlockExpr = null;
        var seen_rparen = false;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .r_paren) {
                seen_rparen = true;
            } else if (!seen_rparen and mutex == null and isExprSyntaxKind(child.kind)) {
                mutex = try self.lowerExprNode(child, c_start);
            } else if (body == null and child.kind == .block) {
                body = try self.lowerBlockNode(child, c_start);
            }
        }

        const r = trimmedRange(green, start_offset);
        const mutex_ptr = mutex orelse try self.allocPlaceholderExpr(.{ .start = r.start, .end = r.start });
        const body_ptr = body orelse try self.allocPlaceholderBlock(.{ .start = r.end, .end = r.end });
        return .{
            .id = id,
            .mutex = mutex_ptr,
            .body = body_ptr,
            .range = r,
        };
    }

    /// 降低 `quote_expr` 为 `QuoteExpr`，并将 `quote_interpolation` 穿透映射到内层插值表达式 `HirId`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `QuoteExpr` 内部指针与切片由 `self.arena` 分配。
    fn lowerQuoteExprPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.QuoteExpr {
        var parts: std.ArrayListUnmanaged(QuotePart) = .empty;
        defer parts.deinit(self.gpa);

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .token_part) {
                try parts.append(self.gpa, .{ .token = trimmedRange(child, c_start) });
            } else if (child.kind == .quote_interpolation) {
                const interp_expr = try self.lowerQuoteInterpolation(child, c_start);
                try self.mapGreen(child, interp_expr.id());
                try parts.append(self.gpa, .{ .interpolation = interp_expr });
            }
        }

        return .{
            .id = id,
            .parts = try self.arena.dupe(QuotePart, parts.items),
            .range = trimmedRange(green, start_offset),
        };
    }

    /// 降低 `quote_interpolation`（`$(expr)` 或 `$name`）。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const HirExpr` 由 `self.arena` 分配。
    fn lowerQuoteInterpolation(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!*const HirExpr {
        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .dollar_identifier) {
                const raw = child.tokenText() orelse "";
                const stripped = if (std.mem.startsWith(u8, raw, "$")) raw[1..] else raw;
                const is_raw = stripped.len >= 2 and stripped[0] == '`' and stripped[stripped.len - 1] == '`';
                const clean = if (is_raw) stripped[1 .. stripped.len - 1] else stripped;
                const r = TextRange{ .start = c_start, .end = c_start + child.text_len };
                const path_id = try self.reserveHirId();
                const path_ptr = try self.arena.create(HirExpr);
                path_ptr.* = .{ .path = .{
                    .id = path_id,
                    .segments = try self.arena.dupe(ExprPathSegment, &.{.{
                        .name = .{ .text = clean, .is_raw = is_raw, .range = r },
                    }}),
                    .range = r,
                } };
                try self.commitNode(path_id, .{ .expr = path_ptr }, child);
                return path_ptr;
            } else if (isExprSyntaxKind(child.kind)) {
                return self.lowerExprNode(child, c_start);
            }
        }
        return self.allocPlaceholderExpr(trimmedRange(green, start_offset));
    }

    /// 降低 `macro_expand_expr` 为 `MacroCallExpr`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `MacroCallExpr` 内部指针与切片由 `self.arena` 分配。
    fn lowerMacroCallExprPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.MacroCallExpr {
        var call_path: std.ArrayListUnmanaged(Name) = .empty;
        defer call_path.deinit(self.gpa);

        var has_bang = false;
        var attr_range: ?TextRange = null;
        var input_range: ?TextRange = null;
        var inner: ?*const HirExpr = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .at_excl) {
                has_bang = true;
            } else if (isNameTokenKind(child.kind)) {
                try call_path.append(self.gpa, extractNameFromLeaf(child, c_start));
            } else if (child.kind == .macro_attributes) {
                attr_range = trimmedRange(child, c_start);
            } else if (child.kind == .macro_input) {
                input_range = trimmedRange(child, c_start);
            } else if (child.kind == .macro_expand_expr) {
                inner = try self.lowerExprNode(child, c_start);
            }
        }

        const r = trimmedRange(green, start_offset);
        if (call_path.items.len == 0) {
            try call_path.append(self.gpa, emptyNameAt(r.start));
        }
        return .{
            .id = id,
            .call = .{
                .path = try self.arena.dupe(Name, call_path.items),
                .has_bang = has_bang,
                .attributes = attr_range,
                .input = input_range,
            },
            .inner = inner,
            .range = r,
        };
    }

    /// 降低 `resume_expr` 为 `ResumeExpr`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `ResumeExpr` 内部指针由 `self.arena` 分配。
    fn lowerResumeExprPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.ResumeExpr {
        var value: ?*const HirExpr = null;
        var modifier: ?ResumeModifier = null;
        var modifier_value: ?*const HirExpr = null;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .kw_with) {
                modifier = .with;
            } else if (child.kind == .kw_throwing) {
                modifier = .throwing;
            } else if (isExprSyntaxKind(child.kind)) {
                if (modifier == null and value == null) {
                    value = try self.lowerExprNode(child, c_start);
                } else if (modifier != null and modifier_value == null) {
                    modifier_value = try self.lowerExprNode(child, c_start);
                }
            }
        }

        return .{
            .id = id,
            .value = value,
            .modifier = modifier,
            .modifier_value = modifier_value,
            .range = trimmedRange(green, start_offset),
        };
    }

    /// 降低 `str_interpolation_expr` 为 `StrInterp`。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `StrInterp` 内部指针与切片由 `self.arena` 分配。
    fn lowerStrInterpPayload(
        self: *Lowerer,
        id: HirId,
        green: *const GreenNode,
        start_offset: u32,
    ) std.mem.Allocator.Error!common.StrInterp {
        var parts: std.ArrayListUnmanaged(StrPart) = .empty;
        defer parts.deinit(self.gpa);
        var kind: StrKind = .single;
        var checked_first = false;

        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (child.kind == .string_content) {
                const txt = child.tokenText() orelse "";
                if (!checked_first) {
                    checked_first = true;
                    if (std.mem.startsWith(u8, txt, "\"\"\"") or std.mem.startsWith(u8, txt, "'''")) {
                        kind = .multiline;
                    }
                }
                try parts.append(self.gpa, .{ .text = .{
                    .text = txt,
                    .range = .{ .start = c_start, .end = c_start + child.text_len },
                } });
            } else if (child.kind == .interpolation_expr) {
                var body_block: ?*const BlockExpr = null;
                var i_off = c_start;
                for (child.children()) |i_child| {
                    const i_start = i_off;
                    i_off +|= i_child.text_len;
                    if (i_child.kind == .block) {
                        const b_ptr = try self.lowerBlockNode(i_child, i_start);
                        try self.mapGreen(child, b_ptr.id);
                        body_block = b_ptr;
                        break;
                    }
                }
                const i_range = trimmedRange(child, c_start);
                const b_ptr = body_block orelse try self.allocPlaceholderBlock(i_range);
                try parts.append(self.gpa, .{ .interpolation = .{
                    .body = b_ptr,
                    .range = i_range,
                } });
            }
        }

        return .{
            .id = id,
            .parts = try self.arena.dupe(StrPart, parts.items),
            .kind = kind,
            .range = trimmedRange(green, start_offset),
        };
    }

    /// 降低节点中首个满足 `isExprSyntaxKind` 的子表达式；若缺失则生成位于 `fallback_range` 的占位表达式。
    ///
    /// 指针内存约定：`green` 仅作只读借用；返回的 `*const HirExpr` 由 `self.arena` 分配。
    fn lowerFirstChildExpr(
        self: *Lowerer,
        green: *const GreenNode,
        start_offset: u32,
        fallback_range: TextRange,
    ) std.mem.Allocator.Error!*const HirExpr {
        var offset = start_offset;
        for (green.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            if (isExprSyntaxKind(child.kind)) {
                return self.lowerExprNode(child, c_start);
            }
        }
        const placeholder = try self.allocPlaceholderExpr(fallback_range);
        for (green.children()) |child| {
            if (child.kind == .error_node) {
                try self.mapGreen(child, placeholder.id());
            }
        }
        return placeholder;
    }

    // =========================================================================
    // 字面量解析与诊断
    // =========================================================================

    /// 降低整数字面量文本，识别显式类型后缀并对残缺进制字面量（如 `0x`、`0b`、`0o`）记录诊断。
    ///
    /// 指针内存约定：`text` 借用自绿树 `arena`，返回的 `IntLit.text` 直接复用该切片。
    fn lowerIntLit(
        self: *Lowerer,
        id: HirId,
        text: []const u8,
        range: TextRange,
    ) std.mem.Allocator.Error!HirExpr {
        const suffix = parseIntSuffix(text);
        const body = if (suffix) |s| text[0 .. text.len - intSuffixLen(s)] else text;
        if (!isValidIntBody(body)) {
            const msg = try std.fmt.allocPrint(self.arena, "invalid integer literal `{s}`", .{text});
            try self.emitDiagnostic(range, msg);
        }
        return .{ .int_lit = .{
            .id = id,
            .text = text,
            .suffix = suffix,
            .range = range,
        } };
    }

    /// 降低浮点数字面量文本，识别显式类型后缀（`f16`/`f32`/`f64`）并对残缺指数等非法浮点文本记录诊断。
    ///
    /// 指针内存约定：`text` 借用自绿树 `arena`，返回的 `FloatLit.text` 直接复用该切片。
    fn lowerFloatLit(
        self: *Lowerer,
        id: HirId,
        text: []const u8,
        range: TextRange,
    ) std.mem.Allocator.Error!HirExpr {
        const suffix = parseFloatSuffix(text);
        const body = if (suffix != null) text[0 .. text.len - 3] else text;
        if (!isValidFloatBody(body)) {
            const msg = try std.fmt.allocPrint(self.arena, "invalid float literal `{s}`", .{text});
            try self.emitDiagnostic(range, msg);
        }
        return .{ .float_lit = .{
            .id = id,
            .text = text,
            .suffix = suffix,
            .range = range,
        } };
    }

    /// 降低字符字面量（`r'x'`、`r"x"`）或字节字符字面量（`b'x'`），解码转义序列或 UTF-8 码点。
    ///
    /// 指针内存约定：`text` 仅作只读借用；诊断消息字符串由 `self.arena` 分配。
    fn lowerRuneLit(
        self: *Lowerer,
        id: HirId,
        text: []const u8,
        is_byte: bool,
        range: TextRange,
    ) std.mem.Allocator.Error!HirExpr {
        const decoded = decodeRuneLiteralText(text, is_byte) orelse blk: {
            const msg = try std.fmt.allocPrint(self.arena, "invalid rune literal `{s}`", .{text});
            try self.emitDiagnostic(range, msg);
            break :blk @as(u21, 0);
        };
        return .{ .rune_lit = .{
            .id = id,
            .value = decoded,
            .is_byte = is_byte,
            .range = range,
        } };
    }

    // =========================================================================
    // 占位 HIR 节点构造（用于缺损语法树容错恢复）
    // =========================================================================

    /// 分配一个占位的 `HirExpr.unit_lit` 节点，记入 `nodes_buf`。
    ///
    /// 指针内存约定：返回的 `*const HirExpr` 由 `self.arena` 分配，随 `arena` 释放。
    fn allocPlaceholderExpr(
        self: *Lowerer,
        range: TextRange,
    ) std.mem.Allocator.Error!*const HirExpr {
        const id = try self.reserveHirId();
        const ptr = try self.arena.create(HirExpr);
        ptr.* = .{ .unit_lit = .{ .id = id, .range = range } };
        try self.commitNode(id, .{ .expr = ptr }, null);
        return ptr;
    }

    /// 分配一个占位的空 `BlockExpr` 节点，记入 `nodes_buf`。
    ///
    /// 指针内存约定：返回的 `*const BlockExpr` 由 `self.arena` 分配，随 `arena` 释放。
    fn allocPlaceholderBlock(
        self: *Lowerer,
        range: TextRange,
    ) std.mem.Allocator.Error!*const BlockExpr {
        const id = try self.reserveHirId();
        const ptr = try self.arena.create(BlockExpr);
        ptr.* = .{ .id = id, .stmts = &.{}, .tail = null, .range = range };
        try self.commitNode(id, .{ .block = ptr }, null);
        return ptr;
    }

    /// 分配一个占位的 `HirType.path` 节点，记入 `nodes_buf`。
    ///
    /// 指针内存约定：返回的 `*const HirType` 由 `self.arena` 分配，随 `arena` 释放。
    fn allocPlaceholderType(
        self: *Lowerer,
        range: TextRange,
    ) std.mem.Allocator.Error!*const HirType {
        const id = try self.reserveHirId();
        const ptr = try self.arena.create(HirType);
        ptr.* = .{ .path = .{
            .id = id,
            .segments = try self.arena.dupe(TypePathSegment, &.{.{ .name = emptyNameAt(range.start) }}),
            .range = range,
        } };
        try self.commitNode(id, .{ .ty = ptr }, null);
        return ptr;
    }

    /// 分配一个占位的 `HirPattern.wildcard` 节点，记入 `nodes_buf`。
    ///
    /// 指针内存约定：返回的 `*const HirPattern` 由 `self.arena` 分配，随 `arena` 释放。
    fn allocPlaceholderPattern(
        self: *Lowerer,
        range: TextRange,
    ) std.mem.Allocator.Error!*const HirPattern {
        const id = try self.reserveHirId();
        const ptr = try self.arena.create(HirPattern);
        ptr.* = .{ .wildcard = .{ .id = id, .range = range } };
        try self.commitNode(id, .{ .pattern = ptr }, null);
        return ptr;
    }
};

/// 便捷函数：一次性将单个声明项 `GreenNode` 降低为 `LoweredItem`。
///
/// 指针内存约定：`item_green` 仅作只读借用；`green_to_hir` 非空时使用 `arena` 分配桶内存；
/// 返回的 `LoweredItem` 内部指针与切片均由 `arena` 分配，随 `arena` 统一释放，调用者不得单独释放。
pub fn lowerItem(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    file: FileId,
    item_id: ItemId,
    item_green: *const GreenNode,
    item_start_offset: u32,
    green_to_hir: ?*GreenToHirMap,
) std.mem.Allocator.Error!LoweredItem {
    var lowerer = Lowerer.init(gpa, arena, file, 0, green_to_hir);
    defer lowerer.deinit();
    return lowerer.lowerItem(item_id, item_green, item_start_offset);
}

/// 便捷函数：一次性将 `SyntaxTree` 降低为 `LoweredFile`。
///
/// 指针内存约定：`syntax_tree.tree.root` 仅作只读借用；`green_to_hir` 非空时使用 `arena` 分配桶内存；
/// 返回的 `LoweredFile` 内部指针与切片均由 `arena` 分配，随 `arena` 统一释放，调用者不得单独释放。
pub fn lowerFile(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    syntax_tree: SyntaxTree,
    green_to_hir: ?*GreenToHirMap,
) std.mem.Allocator.Error!LoweredFile {
    var lowerer = Lowerer.init(gpa, arena, syntax_tree.file, syntax_tree.version, green_to_hir);
    defer lowerer.deinit();
    return lowerer.lowerFile(syntax_tree.tree.root);
}

// =============================================================================
// 静态分类与区间/字面量辅助函数
// =============================================================================

/// 判定给定 `SyntaxKind` 是否为空白、换行、注释或 EOF。
inline fn isTriviaKind(kind: SyntaxKind) bool {
    return switch (kind) {
        .whitespace, .newline, .line_comment, .block_comment, .doc_comment, .eof => true,
        else => false,
    };
}

/// 判定给定 `SyntaxKind` 是否为 Trivia 或分号标点。
inline fn isTriviaOrPunct(kind: SyntaxKind) bool {
    return isTriviaKind(kind) or kind == .semi;
}

/// 计算 `node` 剥离内部前导与尾随 Trivia 后的精确源码字节区间。
///
/// 指针内存约定：`node` 仅作只读借用，不转移所有权。
fn trimmedRange(node: *const GreenNode, start_offset: u32) TextRange {
    const first_non_trivia = findFirstNonTriviaOffset(node, start_offset);
    const last_non_trivia_end = findLastNonTriviaEnd(node, start_offset);
    if (first_non_trivia) |s| {
        const e = last_non_trivia_end orelse (start_offset +| node.text_len);
        return .{ .start = s, .end = @max(s, e) };
    }
    return .{ .start = start_offset, .end = start_offset +| node.text_len };
}

/// 递归查找子树中首个非 Trivia 叶子节点的绝对起始位置。
///
/// 指针内存约定：`node` 仅作只读借用。
fn findFirstNonTriviaOffset(node: *const GreenNode, start_offset: u32) ?u32 {
    if (node.isLeaf()) {
        return if (!isTriviaKind(node.kind)) start_offset else null;
    }
    var offset = start_offset;
    for (node.children()) |child| {
        const c_start = offset;
        offset +|= child.text_len;
        if (findFirstNonTriviaOffset(child, c_start)) |hit| return hit;
    }
    return null;
}

/// 递归查找子树中最后一个非 Trivia 叶子节点的绝对结束位置。
///
/// 指针内存约定：`node` 仅作只读借用。
fn findLastNonTriviaEnd(node: *const GreenNode, start_offset: u32) ?u32 {
    if (node.isLeaf()) {
        return if (!isTriviaKind(node.kind)) (start_offset +| node.text_len) else null;
    }
    const kids = node.children();
    var end_offset = start_offset +| node.text_len;
    var i = kids.len;
    while (i > 0) {
        i -= 1;
        const child = kids[i];
        const c_start = end_offset -| child.text_len;
        end_offset = c_start;
        if (findLastNonTriviaEnd(child, c_start)) |hit| return hit;
    }
    return null;
}

/// 判定叶子标签是否可作为常规名字或包名段提取。
inline fn isNameTokenKind(kind: SyntaxKind) bool {
    return kind == .identifier or kind == .package_identifier;
}

/// 判定叶子标签是否可作为表达式路径段名称（含 `this`、`super`、`This` 与基础类型名）。
inline fn isExprSegmentNameKind(kind: SyntaxKind) bool {
    if (isNameTokenKind(kind)) return true;
    return switch (kind) {
        .kw_this,
        .kw_super,
        .kw_this_type,
        .kw_int8,
        .kw_int16,
        .kw_int32,
        .kw_int64,
        .kw_int_native,
        .kw_uint8,
        .kw_uint16,
        .kw_uint32,
        .kw_uint64,
        .kw_uint_native,
        .kw_float16,
        .kw_float32,
        .kw_float64,
        .kw_rune,
        .kw_bool,
        .kw_nothing,
        .kw_unit,
        => true,
        else => false,
    };
}

/// 从叶子 `GreenNode` 提取 `Name`（自动剥离原始标识符首尾的反引号并设置 `is_raw`）。
///
/// 指针内存约定：`leaf` 仅作只读借用；返回的 `Name.text` 借用自 `leaf` 所在的绿树 `arena`。
fn extractNameFromLeaf(leaf: *const GreenNode, start_offset: u32) Name {
    const raw = leaf.tokenText() orelse "";
    const is_raw = raw.len >= 2 and raw[0] == '`' and raw[raw.len - 1] == '`';
    const text = if (is_raw) raw[1 .. raw.len - 1] else raw;
    return .{
        .text = text,
        .is_raw = is_raw,
        .range = .{ .start = start_offset, .end = start_offset +| leaf.text_len },
    };
}

/// 构造位于指定字节位置处的空占位 `Name`。
inline fn emptyNameAt(offset: u32) Name {
    return .{
        .text = "",
        .is_raw = false,
        .range = .{ .start = offset, .end = offset },
    };
}

/// 将 CST 修饰符关键字标签映射为 `Modifier`。
inline fn modifierFromSyntaxKind(kind: SyntaxKind) ?Modifier {
    return switch (kind) {
        .kw_public => .public,
        .kw_private => .private,
        .kw_protected => .protected,
        .kw_internal => .internal,
        .kw_static => .static,
        .kw_open => .open,
        .kw_sealed => .sealed,
        .kw_abstract => .abstract,
        .kw_override => .override,
        .kw_redef => .redef,
        .kw_unsafe => .unsafe,
        .kw_mut => .mut,
        .kw_operator => .operator,
        .kw_const => .const_,
        .kw_common => .common,
        .kw_specific => .specific,
        .identifier => null,
        else => null,
    };
}

/// 从修饰符叶子节点提取 `Modifier`（支持以 `.identifier` 形式发射的上下文关键字 `late`）。
///
/// 指针内存约定：`child` 仅作只读借用。
inline fn modifierFromNode(child: *const GreenNode) ?Modifier {
    if (modifierFromSyntaxKind(child.kind)) |m| return m;
    if (child.kind == .identifier) {
        if (std.mem.eql(u8, child.tokenText() orelse "", "late")) return .late;
    }
    return null;
}

/// 判定标签是否为可重载的单词法单元运算符。
inline fn isOverloadableOpKind(kind: SyntaxKind) bool {
    return switch (kind) {
        .not,
        .add,
        .sub,
        .exp,
        .mul,
        .div,
        .mod,
        .lshift,
        .rshift,
        .less,
        .greater,
        .less_equal,
        .greater_equal,
        .equal,
        .not_equal,
        .bit_and,
        .bit_xor,
        .bit_or,
        => true,
        else => false,
    };
}

/// 判定给定 `SyntaxKind` 是否为声明项节点。
inline fn isDeclSyntaxKind(kind: SyntaxKind) bool {
    return switch (kind) {
        .class_decl,
        .interface_decl,
        .struct_decl,
        .enum_decl,
        .func_decl,
        .main_decl,
        .macro_decl,
        .var_decl,
        .prop_decl,
        .type_alias_decl,
        .extend_decl,
        .primary_ctor_decl,
        .init_decl,
        .finalizer_decl,
        .foreign_decl,
        .macro_expand_decl,
        => true,
        else => false,
    };
}

/// 判定节点本身是否为声明项，或为包裹了声明项的 `error_node`。
///
/// 指针内存约定：`node` 仅作只读借用。
fn isDeclOrWrappedDecl(node: *const GreenNode) bool {
    if (isDeclSyntaxKind(node.kind)) return true;
    if (node.kind == .error_node) {
        return findWrappedDeclChild(node, 0) != null;
    }
    return false;
}

/// 在 `error_node` 中查找被包裹的内层声明项节点及其起始位置。
///
/// 指针内存约定：`error_green` 仅作只读借用。
fn findWrappedDeclChild(error_green: *const GreenNode, start_offset: u32) ?LocatedGreen {
    var offset = start_offset;
    for (error_green.children()) |child| {
        const c_start = offset;
        offset +|= child.text_len;
        if (isDeclSyntaxKind(child.kind)) {
            return .{ .green = child, .start = c_start };
        }
    }
    return null;
}

/// 若 `node` 是包裹了 `features_directive`、`package_header` 或 `import_spec` 的 `error_node`，
/// 解包返回内层节点与起始位置；否则原样返回。
///
/// 指针内存约定：`node` 仅作只读借用。
fn unwrapHeaderDirective(node: *const GreenNode, start_offset: u32) LocatedGreen {
    if (node.kind == .error_node) {
        var offset = start_offset;
        for (node.children()) |child| {
            const c_start = offset;
            offset +|= child.text_len;
            switch (child.kind) {
                .features_directive, .package_header, .import_spec => {
                    return .{ .green = child, .start = c_start };
                },
                else => {},
            }
        }
    }
    return .{ .green = node, .start = start_offset };
}

/// 在 `enum_body` 下的 `error_node` 中查找错位但完整的枚举构造器子节点。
///
/// 指针内存约定：`error_green` 仅作只读借用。
fn findWrappedEnumConstructor(error_green: *const GreenNode, start_offset: u32) ?LocatedGreen {
    var offset = start_offset;
    for (error_green.children()) |child| {
        const c_start = offset;
        offset +|= child.text_len;
        if (child.kind == .enum_constructor or
            (child.kind == .macro_expand_decl and isVariantMacroNode(child)))
        {
            return .{ .green = child, .start = c_start };
        }
    }
    return null;
}

/// 判定 `enum_body` 中的 `macro_expand_decl` 是否修饰的是枚举构造器（而非成员函数或属性）。
///
/// 指针内存约定：`node` 仅作只读借用。
fn isVariantMacroNode(node: *const GreenNode) bool {
    for (node.children()) |child| {
        if (child.kind == .enum_constructor) return true;
        if (child.kind == .macro_expand_decl) return isVariantMacroNode(child);
        if (isDeclSyntaxKind(child.kind)) return false;
    }
    return false;
}

/// 判定给定 `SyntaxKind` 是否为类型节点。
inline fn isTypeSyntaxKind(kind: SyntaxKind) bool {
    return switch (kind) {
        .primitive_type,
        .path_type,
        .paren_type,
        .tuple_type,
        .func_type,
        .option_type,
        .varray_type,
        .this_type,
        => true,
        else => false,
    };
}

/// 判定给定 `SyntaxKind` 是否为模式节点。
inline fn isPatternSyntaxKind(kind: SyntaxKind) bool {
    return switch (kind) {
        .wildcard_pattern,
        .var_pattern,
        .const_pattern,
        .tuple_pattern,
        .enum_pattern,
        .type_pattern,
        .except_type_pattern,
        .command_type_pattern,
        => true,
        else => false,
    };
}

/// 判定给定 `SyntaxKind` 是否为表达式节点或表达式位置的字面量叶子。
inline fn isExprSyntaxKind(kind: SyntaxKind) bool {
    return switch (kind) {
        .integer_literal,
        .float_literal,
        .rune_literal,
        .rune_byte_literal,
        .string_literal,
        .multiline_string,
        .multiline_raw_string,
        .bool_literal,
        .wildcard_expr,
        .path_expr,
        .call_expr,
        .subscript_expr,
        .optional_expr,
        .paren_expr,
        .tuple_lit,
        .array_lit,
        .varray_expr,
        .unit_literal,
        .binary_expr,
        .unary_expr,
        .inc_or_dec_expr,
        .assign_expr,
        .range_expr,
        .is_expr,
        .as_expr,
        .type_conv_expr,
        .if_expr,
        .match_expr,
        .while_expr,
        .do_while_expr,
        .for_in_expr,
        .try_expr,
        .throw_expr,
        .return_expr,
        .jump_expr,
        .lambda_expr,
        .trailing_closure_expr,
        .spawn_expr,
        .synchronized_expr,
        .unsafe_expr,
        .quote_expr,
        .str_interpolation_expr,
        .if_available_expr,
        .macro_expand_expr,
        .perform_expr,
        .resume_expr,
        .block,
        .let_pattern_destructor,
        => true,
        else => false,
    };
}

/// 判定 `expression_statement` 节点末尾是否包含显式分号 `;`。
///
/// 指针内存约定：`expr_stmt` 仅作只读借用。
inline fn exprStmtHasSemi(expr_stmt: *const GreenNode) bool {
    return expr_stmt.childOfKind(.semi) != null;
}

/// 判定 `path_segment` 内部是否包裹了非标识符的子表达式（如 `g().b` 中的 `call_expr`）。
///
/// 指针内存约定：`seg` 仅作只读借用。
fn pathSegmentContainsExpr(seg: *const GreenNode) bool {
    for (seg.children()) |child| {
        if (isExprSyntaxKind(child.kind)) return true;
    }
    return false;
}

/// 查找 `path_segment` 内部包裹的子表达式节点及其起始位置。
///
/// 指针内存约定：`seg` 仅作只读借用。
fn findExprInPathSegment(seg: *const GreenNode, start_offset: u32) ?LocatedGreen {
    var offset = start_offset;
    for (seg.children()) |child| {
        const c_start = offset;
        offset +|= child.text_len;
        if (isExprSyntaxKind(child.kind)) {
            return .{ .green = child, .start = c_start };
        }
    }
    return null;
}

/// 从整数字面量文本末尾解析可选的 `IntSuffix`。
fn parseIntSuffix(text: []const u8) ?IntSuffix {
    const table = [_]struct { s: []const u8, val: IntSuffix }{
        .{ .s = "i16", .val = .i16 },
        .{ .s = "i32", .val = .i32 },
        .{ .s = "i64", .val = .i64 },
        .{ .s = "u16", .val = .u16 },
        .{ .s = "u32", .val = .u32 },
        .{ .s = "u64", .val = .u64 },
        .{ .s = "i8", .val = .i8 },
        .{ .s = "u8", .val = .u8 },
    };
    for (table) |entry| {
        if (std.mem.endsWith(u8, text, entry.s)) return entry.val;
    }
    return null;
}

/// 返回 `IntSuffix` 对应的字节长度。
inline fn intSuffixLen(s: IntSuffix) usize {
    return switch (s) {
        .i8, .u8 => 2,
        else => 3,
    };
}

/// 校验剥离后缀后的整数字面量主体是否包含至少一位合法数字（拦截 `0x`、`0b`、`0o` 等残缺字面量）。
fn isValidIntBody(body: []const u8) bool {
    if (body.len == 0) return false;
    if (body.len >= 2 and body[0] == '0') {
        const p = body[1];
        if (p == 'x' or p == 'X') {
            var has_hex = false;
            for (body[2..]) |c| {
                if (std.ascii.isHex(c)) {
                    has_hex = true;
                } else if (c != '_') {
                    return false;
                }
            }
            return has_hex;
        }
        if (p == 'b' or p == 'B') {
            var has_bin = false;
            for (body[2..]) |c| {
                if (c == '0' or c == '1') {
                    has_bin = true;
                } else if (c != '_') {
                    return false;
                }
            }
            return has_bin;
        }
        if (p == 'o' or p == 'O') {
            var has_oct = false;
            for (body[2..]) |c| {
                if (c >= '0' and c <= '7') {
                    has_oct = true;
                } else if (c != '_') {
                    return false;
                }
            }
            return has_oct;
        }
    }
    var has_dec = false;
    for (body) |c| {
        if (std.ascii.isDigit(c)) {
            has_dec = true;
        } else if (c != '_') {
            return false;
        }
    }
    return has_dec;
}

/// 从浮点数字面量文本末尾解析可选的 `FloatSuffix`（按仓颉规范十六进制浮点不接受类型后缀）。
fn parseFloatSuffix(text: []const u8) ?FloatSuffix {
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
        return null;
    }
    if (std.mem.endsWith(u8, text, "f16")) return .f16;
    if (std.mem.endsWith(u8, text, "f32")) return .f32;
    if (std.mem.endsWith(u8, text, "f64")) return .f64;
    return null;
}

/// 校验数字片段是否以满足 `isDigit` 的字符开头，且后续仅包含数字或 `'_'`。
fn isValidDigitRun(segment: []const u8, comptime isDigit: fn (u8) bool) bool {
    if (segment.len == 0 or !isDigit(segment[0])) return false;
    for (segment[1..]) |c| {
        if (!isDigit(c) and c != '_') return false;
    }
    return true;
}

/// 校验剥离后缀后的浮点数字面量主体是否满足仓颉十进制或十六进制浮点字面量规范。
fn isValidFloatBody(body: []const u8) bool {
    if (body.len == 0) return false;
    if (body.len >= 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X')) {
        const rest = body[2..];
        const p_pos = std.mem.indexOfAny(u8, rest, "pP") orelse return false;
        const mantissa = rest[0..p_pos];
        var exp = rest[p_pos + 1 ..];
        if (exp.len > 0 and exp[0] == '-') exp = exp[1..];
        if (!isValidDigitRun(exp, std.ascii.isDigit)) return false;

        if (std.mem.indexOfScalar(u8, mantissa, '.')) |dot_pos| {
            const int_part = mantissa[0..dot_pos];
            const frac_part = mantissa[dot_pos + 1 ..];
            if (!isValidDigitRun(frac_part, std.ascii.isHex)) return false;
            if (int_part.len > 0 and !isValidDigitRun(int_part, std.ascii.isHex)) return false;
            return true;
        }
        return isValidDigitRun(mantissa, std.ascii.isHex);
    }

    var mantissa = body;
    var has_exp = false;
    if (std.mem.indexOfAny(u8, body, "eE")) |e_pos| {
        has_exp = true;
        mantissa = body[0..e_pos];
        var exp = body[e_pos + 1 ..];
        if (exp.len > 0 and exp[0] == '-') exp = exp[1..];
        if (!isValidDigitRun(exp, std.ascii.isDigit)) return false;
    }

    if (std.mem.indexOfScalar(u8, mantissa, '.')) |dot_pos| {
        const int_part = mantissa[0..dot_pos];
        const frac_part = mantissa[dot_pos + 1 ..];
        if (!isValidDigitRun(frac_part, std.ascii.isDigit)) return false;
        if (int_part.len == 0) return true;
        if (int_part[0] == '0' and int_part.len > 1) return false;
        return isValidDigitRun(int_part, std.ascii.isDigit);
    }

    if (!has_exp) return false;
    if (mantissa.len == 0) return false;
    if (mantissa[0] == '0' and mantissa.len > 1) return false;
    return isValidDigitRun(mantissa, std.ascii.isDigit);
}

/// 解码 `r'...'`、`r"..."` 或 `b'...'` 字符字面量源码文本中的 Unicode 码点值；格式非法时返回 `null`。
fn decodeRuneLiteralText(text: []const u8, is_byte: bool) ?u21 {
    if (text.len < 3) return null;
    const prefix = text[0];
    if (is_byte and prefix != 'b') return null;
    if (!is_byte and prefix != 'r') return null;
    const quote = text[1];
    if ((quote != '\'' and quote != '"') or text[text.len - 1] != quote) return null;

    const inner = text[2 .. text.len - 1];
    if (inner.len == 0) return null;

    if (inner[0] != '\\') {
        const cp = common.utf8.decode(inner) orelse return null;
        if (cp.len != inner.len) return null;
        if (is_byte and cp.value > 0x7f) return null;
        return cp.value;
    }

    if (inner.len < 2) return null;
    return switch (inner[1]) {
        't' => if (inner.len == 2) '\t' else null,
        'b' => if (inner.len == 2) 0x08 else null,
        'r' => if (inner.len == 2) '\r' else null,
        'n' => if (inner.len == 2) '\n' else null,
        '\'' => if (inner.len == 2) '\'' else null,
        '"' => if (inner.len == 2) '"' else null,
        '\\' => if (inner.len == 2) '\\' else null,
        'f' => if (inner.len == 2) 0x0c else null,
        'v' => if (inner.len == 2) 0x0b else null,
        '0' => if (inner.len == 2) 0 else null,
        '$' => if (!is_byte and inner.len == 2) '$' else null,
        'u' => blk: {
            if (inner.len < 5 or inner[2] != '{' or inner[inner.len - 1] != '}') break :blk null;
            const hex_digits = inner[3 .. inner.len - 1];
            const max_len: usize = if (is_byte) 2 else 8;
            if (hex_digits.len == 0 or hex_digits.len > max_len) break :blk null;
            const val = std.fmt.parseInt(u32, hex_digits, 16) catch break :blk null;
            if (is_byte) {
                if (val > 0xff) break :blk null;
                break :blk @intCast(val);
            }
            if (val > 0x10ffff or common.utf8.isSurrogate(@intCast(val))) break :blk null;
            break :blk @intCast(val);
        },
        else => null,
    };
}

// =============================================================================
// 单元测试
// =============================================================================

const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const tree_mod = @import("tree.zig");

/// 测试辅助：执行词法扫描、语法解析与绿树构建，返回 `SyntaxTree`。
///
/// 指针内存约定：生成的绿树节点分配在 `arena` 中，随 `arena` 释放。
fn parseTestTree(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
) !SyntaxTree {
    var tokens: std.ArrayList(common.Token) = .empty;
    defer tokens.deinit(gpa);
    var lex = try lexer_mod.Lexer.new(source);
    while (true) {
        const tok = try lex.gen();
        try tokens.append(gpa, tok);
        if (tok.tag == .end) break;
    }

    var p = parser_mod.Parser.new(gpa, source, tokens.items);
    defer p.deinit();
    try p.parse();

    const gtree = try tree_mod.treeBuild(gpa, arena, source, p.events.items);
    return .{
        .file = .{ .index = 1, .generation = 0 },
        .version = 1,
        .tree = gtree,
    };
}

/// 测试辅助：断言 `LoweredItem` 满足 `nodes[i].id().index() == i` 与 `hir_id_start` / `hir_id_end` 不变式。
fn assertLoweredItemInvariants(item: LoweredItem) !void {
    try std.testing.expectEqual(HirId.fromIndex(0), item.hir_id_start);
    try std.testing.expectEqual(HirId.fromIndex(@intCast(item.nodes.len)), item.hir_id_end);
    for (item.nodes, 0..) |node, i| {
        try std.testing.expectEqual(HirId.fromIndex(@intCast(i)), node.id());
        try std.testing.expect(node.range().start <= node.range().end);
    }
    for (item.exprs) |e| {
        const mapped = item.expr(e.id()).?;
        try std.testing.expectEqual(e, mapped);
    }
}

test "lowerFile 文件头部（features、package、imports）与跨项 HirKey 隔离" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\features { os.linux, arch.x64 }
        \\public macro package myorg::a.`b-c`
        \\@When[os == "linux"]
        \\public import std.io.{Reader, Writer as W, net.*}
        \\import org2::pkg.Single
        \\
        \\public func fnA(x: Int64): Int64 {
        \\    let y: Int64 = x + 1;
        \\    y * 2
        \\}
        \\
        \\func fnB(): Bool {
        \\    true
        \\}
    ;

    const stree = try parseTestTree(gpa, alloc, source);
    var map: GreenToHirMap = .empty;
    const lowered = try lowerFile(gpa, alloc, stree, &map);

    // 1. 校验 features
    const feats = lowered.hir_file.features.?;
    try std.testing.expectEqual(@as(usize, 2), feats.features.len);
    try std.testing.expectEqualStrings("os", feats.features[0].segments[0].text);
    try std.testing.expectEqualStrings("linux", feats.features[0].segments[1].text);
    try std.testing.expectEqualStrings("x64", feats.features[1].segments[1].text);

    // 2. 校验 package
    const pkg = lowered.hir_file.package.?;
    try std.testing.expectEqual(Modifier.public, pkg.modifier.?);
    try std.testing.expect(pkg.is_macro);
    try std.testing.expectEqualStrings("myorg", pkg.org.?.text);
    try std.testing.expectEqual(@as(usize, 2), pkg.name.len);
    try std.testing.expectEqualStrings("a", pkg.name[0].text);
    try std.testing.expectEqualStrings("b-c", pkg.name[1].text);
    try std.testing.expect(pkg.name[1].is_raw);

    // 3. 校验 imports
    try std.testing.expectEqual(@as(usize, 2), lowered.hir_file.imports.len);
    const imp0 = lowered.hir_file.imports[0];
    try std.testing.expectEqual(Modifier.public, imp0.modifier.?);
    try std.testing.expectEqual(@as(usize, 1), imp0.annotations.len);
    try std.testing.expectEqualStrings("When", imp0.annotations[0].path[0].text);
    try std.testing.expectEqual(@as(usize, 2), imp0.prefix.len);
    try std.testing.expectEqualStrings("std", imp0.prefix[0].text);
    try std.testing.expectEqualStrings("io", imp0.prefix[1].text);
    try std.testing.expectEqual(@as(usize, 3), imp0.kind.group.len);
    try std.testing.expectEqualStrings("Reader", imp0.kind.group[0].kind.single.text);
    try std.testing.expectEqualStrings("Writer", imp0.kind.group[1].kind.alias.name.text);
    try std.testing.expectEqualStrings("W", imp0.kind.group[1].kind.alias.alias.text);
    try std.testing.expectEqualStrings("net", imp0.kind.group[2].prefix[0].text);
    try std.testing.expectEqual(.glob, std.meta.activeTag(imp0.kind.group[2].kind));

    const imp1 = lowered.hir_file.imports[1];
    try std.testing.expectEqualStrings("org2", imp1.org.?.text);
    try std.testing.expectEqualStrings("pkg", imp1.prefix[0].text);
    try std.testing.expectEqualStrings("Single", imp1.kind.single.text);

    // 4. 校验跨项 HirKey 隔离：fnA 与 fnB 各自的根 HirId 均为 0，通过 ItemId 区分
    try std.testing.expectEqual(@as(usize, 2), lowered.lowered_items.len);
    const item_a = lowered.lowered_items[0];
    const item_b = lowered.lowered_items[1];
    try assertLoweredItemInvariants(item_a);
    try assertLoweredItemInvariants(item_b);

    try std.testing.expectEqual(ItemId.fromIndex(0), item_a.id);
    try std.testing.expectEqual(ItemId.fromIndex(1), item_b.id);
    try std.testing.expectEqual(HirId.fromIndex(0), item_a.item.id());
    try std.testing.expectEqual(HirId.fromIndex(0), item_b.item.id());

    const key_a: HirKey = .{ .item = item_a.id, .hir = .fromIndex(0) };
    const key_b: HirKey = .{ .item = item_b.id, .hir = .fromIndex(0) };
    try std.testing.expect(!HirKey.eql(key_a, key_b));
    try std.testing.expectEqualStrings("fnA", lowered.node(key_a).?.item.func.name.ident.text);
    try std.testing.expectEqualStrings("fnB", lowered.node(key_b).?.item.func.name.ident.text);

    // 5. 校验块内语句与尾表达式（y * 2 无分号，作为 tail，且外层 expression_statement 映射到 tail）
    const body_a = item_a.item.func.body.?;
    try std.testing.expectEqual(@as(usize, 1), body_a.stmts.len);
    try std.testing.expect(body_a.tail != null);
    try std.testing.expectEqual(BinaryOp.mul, body_a.tail.?.binary.op);

    // 6. 校验 GreenToHirMap 上溯：光标在 `func` 关键字、`{`、形参 `x`、尾表达式 `2` 上
    const fn_a_pos: u32 = @intCast(std.mem.indexOf(u8, source, "func fnA").?);
    const key_at_func_kw = map.resolveNearestAtOffset(stree.tree.root, 0, fn_a_pos + 1).?;
    try std.testing.expect(HirKey.eql(key_a, key_at_func_kw));

    const lcurl_pos: u32 = @intCast(std.mem.indexOf(u8, source, "{\n    let y").?);
    const key_at_lcurl = map.resolveNearestAtOffset(stree.tree.root, 0, lcurl_pos).?;
    try std.testing.expectEqual(item_a.id, key_at_lcurl.item);
    try std.testing.expectEqual(body_a.id, key_at_lcurl.hir);

    const param_x_pos: u32 = @intCast(std.mem.indexOf(u8, source, "x: Int64").?);
    const key_at_param = map.resolveNearestAtOffset(stree.tree.root, 0, param_x_pos).?;
    try std.testing.expectEqual(item_a.id, key_at_param.item);
    try std.testing.expectEqual(item_a.item.func.params[0].id(), key_at_param.hir);

    const tail_2_pos: u32 = @intCast(std.mem.indexOf(u8, source, "2\n}").?);
    const key_at_tail_lit = map.resolveNearestAtOffset(stree.tree.root, 0, tail_2_pos).?;
    try std.testing.expectEqual(body_a.tail.?.binary.rhs.id(), key_at_tail_lit.hir);
}

test "点分路径、链式调用与可选链（g().b.c 与 a?.b.c）展开及精确段级映射" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\func testPaths() {
        \\    let p1 = a.b.c;
        \\    let p2 = g().b.c;
        \\    let p3 = a?.b.c;
        \\    let p4 = (1 + 2) * 3;
        \\    f { x => x + 1 }
        \\}
    ;

    const stree = try parseTestTree(gpa, alloc, source);
    var map: GreenToHirMap = .empty;
    const lowered = try lowerFile(gpa, alloc, stree, &map);
    const item = lowered.lowered_items[0];
    try assertLoweredItemInvariants(item);

    const body = item.item.func.body.?;
    try std.testing.expectEqual(@as(usize, 4), body.stmts.len);
    try std.testing.expect(body.tail != null);

    // p1 = a.b.c -> 保持为单个 3 段 HirExpr.path
    const e1 = body.stmts[0].binding.init.?;
    try std.testing.expectEqual(@as(usize, 3), e1.path.segments.len);
    try std.testing.expectEqualStrings("a", e1.path.segments[0].name.text);
    try std.testing.expectEqualStrings("b", e1.path.segments[1].name.text);
    try std.testing.expectEqualStrings("c", e1.path.segments[2].name.text);

    // p2 = g().b.c -> FieldExpr(base: FieldExpr(base: CallExpr(g()), name: b), name: c)
    const e2 = body.stmts[1].binding.init.?;
    try std.testing.expectEqualStrings("c", e2.field.name.text);
    const e2_inner_b = e2.field.base;
    try std.testing.expectEqualStrings("b", e2_inner_b.field.name.text);
    const e2_call_g = e2_inner_b.field.base;
    try std.testing.expectEqual(.call, std.meta.activeTag(e2_call_g.*));

    // 光标在 `g().b.c` 的 `b` 上 -> 精确命中内层 `.b` 的 FieldExpr（P0-4）
    const g_b_pos: u32 = @intCast(std.mem.indexOf(u8, source, "g().b.c").? + 4);
    const key_at_b = map.resolveNearestAtOffset(stree.tree.root, 0, g_b_pos).?;
    try std.testing.expectEqual(e2_inner_b.id(), key_at_b.hir);

    // 光标在 `g().b.c` 的 `c` 上 -> 命中外层 `.c` 的 FieldExpr
    const key_at_c = map.resolveNearestAtOffset(stree.tree.root, 0, g_b_pos + 2).?;
    try std.testing.expectEqual(e2.id(), key_at_c.hir);

    // p3 = a?.b.c -> FieldExpr(base: FieldExpr(base: OptionalExpr(PathExpr(a)), name: b), name: c)
    const e3 = body.stmts[2].binding.init.?;
    try std.testing.expectEqualStrings("c", e3.field.name.text);
    const e3_b = e3.field.base;
    try std.testing.expectEqualStrings("b", e3_b.field.name.text);
    try std.testing.expectEqual(.optional, std.meta.activeTag(e3_b.field.base.*));
    try std.testing.expectEqualStrings("a", e3_b.field.base.optional.operand.path.segments[0].name.text);

    // p4 = (1 + 2) * 3 -> 括号折叠，光标在 `(` 上命中 `1 + 2` 的 binary_expr（P1-3）
    const e4 = body.stmts[3].binding.init.?;
    try std.testing.expectEqual(BinaryOp.mul, e4.binary.op);
    try std.testing.expectEqual(BinaryOp.add, e4.binary.lhs.binary.op);
    const lparen_pos: u32 = @intCast(std.mem.indexOf(u8, source, "(1 + 2)").?);
    const key_at_lparen = map.resolveNearestAtOffset(stree.tree.root, 0, lparen_pos).?;
    try std.testing.expectEqual(e4.binary.lhs.id(), key_at_lparen.hir);

    // tail: f { x => x + 1 } -> 合并了 trailing_lambda 的 CallExpr
    const tail_call = body.tail.?;
    try std.testing.expectEqual(.call, std.meta.activeTag(tail_call.*));
    try std.testing.expectEqual(@as(usize, 0), tail_call.call.args.len);
    try std.testing.expect(tail_call.call.trailing_lambda != null);
    try std.testing.expectEqual(@as(usize, 1), tail_call.call.trailing_lambda.?.lambda.params.len);
}

test "声明项、类型、模式与控制流表达式全量覆盖" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\public open class Base<T> <: I1 & I2 where T <: Object {
        \\    public var count: Int64 = 0
        \\    public Base(public let id: Int64, @M a!: ?(Int64, Bool) = None) {
        \\        this.count = id
        \\    }
        \\    public init() {
        \\        this.count = 1
        \\    }
        \\    ~init() {}
        \\    public mut prop value: Int64 {
        \\        get() { count }
        \\        set(v) { count = v }
        \\    }
        \\    public operator func +(rhs: This): (x: Int64, y: VArray<Int64, $4>) -> Unit {
        \\        { a: Int64, b: VArray<Int64, $4> => () }
        \\    }
        \\}
        \\
        \\struct Point {
        \\    let x: Float64 = 1.5f64
        \\}
        \\
        \\enum Opt<T> {
        \\    | Some(T)
        \\    | @VM None
        \\    | ...
        \\    func isSome(): Bool { true }
        \\}
        \\
        \\interface I1 {}
        \\extend Int64 <: I1 {}
        \\type Callback = (Int64) -> Bool
        \\foreign {
        \\    func c_puts(s: CString): Int32
        \\}
        \\public late macro MyMacro(input: Tokens): Tokens = quote($(input) + $x)
        \\@MyMacro[attr]
        \\func decorated() {}
        \\
        \\main() {
        \\    let (a, _): (Int64, Int64) = (10i64, 20)
        \\    let arr = [1, *xs, 3]
        \\    let sub = arr[0..=2:1]
        \\    let conv = Int64(r'\n') + Int64(b'\u{41}') + Int64(r"\u{4e2d}")
        \\    let s = "hello ${a + 1} world"
        \\    if (let Some(v) <- opt) {
        \\        while (v > 0) {
        \\            break
        \\        }
        \\    } else {
        \\        do {
        \\            continue
        \\        } while (false)
        \\    }
        \\    for (item in arr where item > 0) {
        \\        match (item) {
        \\            case 1 | -2 where a > 0 => ()
        \\            case n: Int64 => ()
        \\            case _ => ()
        \\        }
        \\        match {
        \\            case a == 1 => ()
        \\            case _ => ()
        \\        }
        \\    }
        \\    try (res: File = open()) {
        \\        perform Cmd()
        \\    } catch (e: IOException | NetException) {
        \\        throw e
        \\    } handle (cmd: EffectCmd) {
        \\        resume 1 with 2
        \\    } finally {
        \\        unsafe { synchronized (mtx) { spawn { => () } } }
        \\    }
        \\    return
        \\}
    ;

    const stree = try parseTestTree(gpa, alloc, source);
    var map: GreenToHirMap = .empty;
    const lowered = try lowerFile(gpa, alloc, stree, &map);

    try std.testing.expectEqual(@as(usize, 0), lowered.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 10), lowered.lowered_items.len);
    for (lowered.lowered_items) |li| {
        try assertLoweredItemInvariants(li);
    }

    // 校验 ClassItem 及其内部成员
    const cls = lowered.hir_file.items[0].class;
    try std.testing.expectEqualStrings("Base", cls.name.text);
    try std.testing.expectEqual(@as(usize, 1), cls.type_params.len);
    try std.testing.expectEqual(@as(usize, 2), cls.supertypes.len);
    try std.testing.expect(cls.where_clause != null);
    try std.testing.expectEqual(@as(usize, 6), cls.members.len);
    try std.testing.expectEqual(.binding, std.meta.activeTag(cls.members[0]));
    try std.testing.expectEqual(.primary_ctor, std.meta.activeTag(cls.members[1]));
    try std.testing.expectEqual(.init, std.meta.activeTag(cls.members[2]));
    try std.testing.expectEqual(.finalizer, std.meta.activeTag(cls.members[3]));
    try std.testing.expectEqual(.prop, std.meta.activeTag(cls.members[4]));
    try std.testing.expectEqual(.func, std.meta.activeTag(cls.members[5]));
    try std.testing.expectEqualStrings("+", cls.members[5].func.name.operator.text);

    // 校验 EnumItem 构造器、构造器宏、非详尽标记与成员函数
    const enm = lowered.hir_file.items[2].enum_;
    try std.testing.expect(enm.is_non_exhaustive);
    try std.testing.expectEqual(@as(usize, 2), enm.variants.len);
    try std.testing.expectEqualStrings("Some", enm.variants[0].constructor.name.text);
    try std.testing.expectEqual(.macro_call, std.meta.activeTag(enm.variants[1]));
    try std.testing.expectEqual(@as(usize, 1), enm.members.len);

    // 光标在枚举构造器 `Some` 上 -> 命中该 EnumVariant 的 HirId（P1-4）
    const some_pos: u32 = @intCast(std.mem.indexOf(u8, source, "Some(T)").?);
    const key_at_some = map.resolveNearestAtOffset(stree.tree.root, 0, some_pos).?;
    try std.testing.expectEqual(ItemId.fromIndex(2), key_at_some.item);
    try std.testing.expectEqual(enm.variants[0].id(), key_at_some.hir);

    // 校验 MacroItem 上的 `late` 修饰符与 quote 插值
    const mac = lowered.hir_file.items[7].macro_;
    try std.testing.expectEqual(@as(usize, 2), mac.modifiers.len);
    try std.testing.expectEqual(Modifier.late, mac.modifiers[1]);
    try std.testing.expectEqual(.quote, std.meta.activeTag(mac.body.*));
}

test "P0-7 容错纪律：非法字面量与 error_node 包裹的错位声明产生诊断或占位节点并继续降低" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 1. 通过 Parser 解析带非法位置声明与残缺表达式的源码
    const source =
        \\private main() {
        \\    public let x: Int64 = 1 +
        \\}
    ;
    const stree = try parseTestTree(gpa, alloc, source);
    var map: GreenToHirMap = .empty;
    const lowered = try lowerFile(gpa, alloc, stree, &map);

    // `private main` 被 parser 包在 error_node 中，lower 剥开 error_node 保留完整 MainItem
    try std.testing.expectEqual(@as(usize, 1), lowered.lowered_items.len);
    try assertLoweredItemInvariants(lowered.lowered_items[0]);
    try std.testing.expectEqual(.main, std.meta.activeTag(lowered.hir_file.items[0]));
    const main_body = lowered.hir_file.items[0].main.body;
    try std.testing.expectEqual(@as(usize, 1), main_body.stmts.len);
    // `1 +` 右操作数缺失，自动补齐占位 unit_lit，不会崩溃
    const bin_init = main_body.stmts[0].binding.init.?;
    try std.testing.expectEqual(BinaryOp.add, bin_init.binary.op);
    try std.testing.expectEqual(.unit_lit, std.meta.activeTag(bin_init.binary.rhs.*));

    // 2. 构造带非法字面量叶子（如 `0x` 与非法 rune `r''`）的绿树，验证 lowerItem 产生诊断并继续
    const bad_hex = try alloc.create(GreenNode);
    bad_hex.* = .{ .kind = .integer_literal, .text_len = 2, .payload = .{ .leaf = "0x" } };
    const bad_rune = try alloc.create(GreenNode);
    bad_rune.* = .{ .kind = .rune_literal, .text_len = 3, .payload = .{ .leaf = "r''" } };
    const plus = try alloc.create(GreenNode);
    plus.* = .{ .kind = .add, .text_len = 1, .payload = .{ .leaf = "+" } };
    const bin = try alloc.create(GreenNode);
    bin.* = .{
        .kind = .binary_expr,
        .text_len = 6,
        .payload = .{ .tree = try alloc.dupe(*const GreenNode, &.{ bad_hex, plus, bad_rune }) },
    };
    const expr_stmt = try alloc.create(GreenNode);
    expr_stmt.* = .{
        .kind = .expression_statement,
        .text_len = 6,
        .payload = .{ .tree = try alloc.dupe(*const GreenNode, &.{bin}) },
    };
    const stmt_list = try alloc.create(GreenNode);
    stmt_list.* = .{
        .kind = .stmt_list,
        .text_len = 6,
        .payload = .{ .tree = try alloc.dupe(*const GreenNode, &.{expr_stmt}) },
    };
    const block = try alloc.create(GreenNode);
    block.* = .{
        .kind = .block,
        .text_len = 6,
        .payload = .{ .tree = try alloc.dupe(*const GreenNode, &.{stmt_list}) },
    };
    const func_node = try alloc.create(GreenNode);
    func_node.* = .{
        .kind = .func_decl,
        .text_len = 6,
        .payload = .{ .tree = try alloc.dupe(*const GreenNode, &.{block}) },
    };

    const bad_item = try lowerItem(gpa, alloc, .{ .index = 0, .generation = 0 }, .fromIndex(0), func_node, 0, &map);
    try assertLoweredItemInvariants(bad_item);
    try std.testing.expectEqual(@as(usize, 2), bad_item.diagnostics.len);
    try std.testing.expectEqual(@as(u21, 0), bad_item.item.func.body.?.tail.?.binary.rhs.rune_lit.value);
}

test "包装节点映射穿透（paren_type、match 分支体、quote_interpolation、trailing_closure 包裹 call_expr/varray_expr）与 OOM 安全" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\func testMappings(p: (Int64)): Unit {
        \\    let q = quote(1 + $(p + 2) + $p)
        \\    let m = match (p) {
        \\        case 1 =>
        \\            let a = 10;
        \\            a + 1
        \\        case _ => 0
        \\    }
        \\    VArray<Int64, $3> { i => i }
        \\}
    ;

    const stree = try parseTestTree(gpa, alloc, source);
    var map: GreenToHirMap = .empty;
    const lowered = try lowerFile(gpa, alloc, stree, &map);
    const item = lowered.lowered_items[0];
    try assertLoweredItemInvariants(item);

    // 1. paren_type `(Int64)` 折叠后，光标在 `(Int64)` 的 `(` 上穿透命中内层 `Int64` 的 HirType
    const paren_ty_pos: u32 = @intCast(std.mem.indexOf(u8, source, "(Int64)").?);
    const key_at_paren_ty = map.resolveNearestAtOffset(stree.tree.root, 0, paren_ty_pos).?;
    const param_ty = item.item.func.params[0].param.ty.?;
    try std.testing.expectEqual(param_ty.id(), key_at_paren_ty.hir);

    // 2. quote_interpolation `$(p + 2)` 光标在 `$` 上穿透命中内层 `p + 2` 表达式
    const interp_pos: u32 = @intCast(std.mem.indexOf(u8, source, "$(p + 2)").?);
    const key_at_interp = map.resolveNearestAtOffset(stree.tree.root, 0, interp_pos).?;
    const quote_expr = item.item.func.body.?.stmts[0].binding.init.?.quote;
    try std.testing.expectEqual(quote_expr.parts[1].interpolation.id(), key_at_interp.hir);

    // 3. match 分支体 `stmt_list` 登记为独立 BlockExpr 并写入 GreenToHirMap
    const match_expr = item.item.func.body.?.stmts[1].binding.init.?.match_expr;
    const case0_body = match_expr.cases[0].pattern.body;
    try std.testing.expectEqual(case0_body, item.node(case0_body.id).?.block);

    // 4. VArray<Int64, $3>({ i => i })：首字符 `V` 属于内层 varray_type，`(` 属于外层 varray_expr
    const tail_va = item.item.func.body.?.tail.?;
    try std.testing.expectEqual(.varray, std.meta.activeTag(tail_va.*));
    const va_pos: u32 = @intCast(std.mem.indexOf(u8, source, "VArray<Int64, $3>").?);
    const key_at_va_ty = map.resolveNearestAtOffset(stree.tree.root, 0, va_pos).?;
    try std.testing.expectEqual(tail_va.varray.ty.id(), key_at_va_ty.hir);

    // 5. OOM 全路径分配失败检查：lowerFile 在任意分配点失败均无内存泄漏
    try std.testing.checkAllAllocationFailures(gpa, struct {
        fn run(test_gpa: std.mem.Allocator, tree: SyntaxTree) !void {
            var test_arena = std.heap.ArenaAllocator.init(test_gpa);
            defer test_arena.deinit();
            var test_map: GreenToHirMap = .empty;
            _ = try lowerFile(test_gpa, test_arena.allocator(), tree, &test_map);
        }
    }.run, .{stree});
}

test "切片元素与 nodes 池指针同一性、复合 let 条件、运算符重载与错误恢复边界验证" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\class Box {
        \\    public operator func ()(idx: Int64): Int64 { idx }
        \\    public operator func [](idx: Int64): Int64 { idx }
        \\}
        \\enum Wrap {
        \\    | Val(@Deprecated["old"] Int64, @Deprecated["m"] @PM(Bool))
        \\}
        \\func checkReviewCases(opt: Wrap, arr: Array<Int64>): Int64 {
        \\    let tup = (1, 2)
        \\    let elem = arr[0]
        \\    if (let Val(n, flag) <- opt && n > 0) {
        \\        return n
        \\    }
        \\    match (opt) {
        \\        case Val(v, _) => v
        \\    }
        \\}
    ;

    const stree = try parseTestTree(gpa, alloc, source);
    var map: GreenToHirMap = .empty;
    const lowered = try lowerFile(gpa, alloc, stree, &map);
    try std.testing.expectEqual(@as(usize, 0), lowered.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 3), lowered.lowered_items.len);

    // 1. 校验顶层与嵌套切片元素地址和 LoweredItem.nodes 池中记录的节点指针完全同一
    for (lowered.lowered_items, 0..) |li, i| {
        try assertLoweredItemInvariants(li);
        try std.testing.expectEqual(&lowered.hir_file.items[i], li.item);
        try std.testing.expectEqual(&lowered.hir_file.items[i], li.nodes[0].item);
    }

    const cls_li = lowered.lowered_items[0];
    const cls = lowered.hir_file.items[0].class;
    try std.testing.expectEqual(@as(usize, 2), cls.members.len);
    try std.testing.expectEqualStrings("()", cls.members[0].func.name.operator.text);
    try std.testing.expectEqualStrings("[]", cls.members[1].func.name.operator.text);
    for (cls.members) |*m| {
        try std.testing.expectEqual(m, cls_li.node(m.id()).?.item);
    }

    // 2. 校验枚举构造器参数的注解与宏参数节点注册及指针同一
    const enm_li = lowered.lowered_items[1];
    const enm = lowered.hir_file.items[1].enum_;
    try std.testing.expectEqual(&enm.variants[0], enm_li.node(enm.variants[0].id()).?.variant);
    const ctor_payload = enm.variants[0].constructor.payload;
    try std.testing.expectEqual(@as(usize, 2), ctor_payload.len);
    try std.testing.expectEqual(@as(usize, 1), ctor_payload[0].ty.annotations.len);
    try std.testing.expectEqualStrings("Deprecated", ctor_payload[0].ty.annotations[0].path[0].text);
    try std.testing.expectEqual(.macro_call, std.meta.activeTag(ctor_payload[1]));
    try std.testing.expectEqual(@as(usize, 1), ctor_payload[1].macro_call.annotations.len);
    try std.testing.expectEqual(.param, std.meta.activeTag(enm_li.node(ctor_payload[1].macro_call.id).?));

    // 3. 校验函数体 stmts、params、tuple_lit.elements、index.indices 的指针同一性
    const fn_li = lowered.lowered_items[2];
    const fn_item = lowered.hir_file.items[2].func;
    for (fn_item.params) |*p| {
        try std.testing.expectEqual(p, fn_li.node(p.id()).?.param);
    }
    const body = fn_item.body.?;
    for (body.stmts) |*st| {
        try std.testing.expectEqual(st, fn_li.node(st.id()).?.stmt);
    }
    const tup_elems = body.stmts[0].binding.init.?.tuple_lit.elements;
    for (tup_elems) |*te| {
        try std.testing.expectEqual(te, fn_li.expr(te.id()).?);
    }
    const idx_elems = body.stmts[1].binding.init.?.index.indices;
    for (idx_elems) |*ie| {
        try std.testing.expectEqual(ie, fn_li.expr(ie.id()).?);
    }

    // 4. 校验复合条件 `if (let Val(n, flag) <- opt && n > 0)` 中模式与表达式均注册且可命中
    const cond_val_pos: u32 = @intCast(std.mem.indexOf(u8, source, "Val(n, flag)").?);
    const key_at_cond_pat = map.resolveNearestAtOffset(stree.tree.root, 0, cond_val_pos).?;
    try std.testing.expectEqual(.pattern, std.meta.activeTag(fn_li.node(key_at_cond_pat.hir).?));
    try std.testing.expectEqual(.enum_, std.meta.activeTag(fn_li.node(key_at_cond_pat.hir).?.pattern.*));

    // 5. 校验 match 分支中 `enum_pattern` `Val(v, _)` 命中 `HirNode.pattern`（非 `HirNode.ty`）
    const match_val_pos: u32 = @intCast(std.mem.indexOf(u8, source, "Val(v, _)").?);
    const key_at_match_pat = map.resolveNearestAtOffset(stree.tree.root, 0, match_val_pos).?;
    const matched_node = fn_li.node(key_at_match_pat.hir).?;
    try std.testing.expectEqual(.pattern, std.meta.activeTag(matched_node));
    try std.testing.expectEqual(.enum_, std.meta.activeTag(matched_node.pattern.*));

    // 6. 校验二元表达式夹杂 error_node 时右操作数不被挤占，且残缺浮点字面量产生诊断
    const lhs_int = try alloc.create(GreenNode);
    lhs_int.* = .{ .kind = .integer_literal, .text_len = 1, .payload = .{ .leaf = "1" } };
    const plus_tok = try alloc.create(GreenNode);
    plus_tok.* = .{ .kind = .add, .text_len = 1, .payload = .{ .leaf = "+" } };
    const stray_tok = try alloc.create(GreenNode);
    stray_tok.* = .{ .kind = .at, .text_len = 1, .payload = .{ .leaf = "@" } };
    const err_child = try alloc.create(GreenNode);
    err_child.* = .{
        .kind = .error_node,
        .text_len = 1,
        .payload = .{ .tree = try alloc.dupe(*const GreenNode, &.{stray_tok}) },
    };
    const bad_float = try alloc.create(GreenNode);
    bad_float.* = .{ .kind = .float_literal, .text_len = 4, .payload = .{ .leaf = "1.0e" } };
    const bin_with_err = try alloc.create(GreenNode);
    bin_with_err.* = .{
        .kind = .binary_expr,
        .text_len = 7,
        .payload = .{ .tree = try alloc.dupe(*const GreenNode, &.{ lhs_int, plus_tok, err_child, bad_float }) },
    };
    const expr_stmt = try alloc.create(GreenNode);
    expr_stmt.* = .{
        .kind = .expression_statement,
        .text_len = 7,
        .payload = .{ .tree = try alloc.dupe(*const GreenNode, &.{bin_with_err}) },
    };
    const stmt_list = try alloc.create(GreenNode);
    stmt_list.* = .{
        .kind = .stmt_list,
        .text_len = 7,
        .payload = .{ .tree = try alloc.dupe(*const GreenNode, &.{expr_stmt}) },
    };
    const blk_node = try alloc.create(GreenNode);
    blk_node.* = .{
        .kind = .block,
        .text_len = 7,
        .payload = .{ .tree = try alloc.dupe(*const GreenNode, &.{stmt_list}) },
    };
    const fn_green = try alloc.create(GreenNode);
    fn_green.* = .{
        .kind = .func_decl,
        .text_len = 7,
        .payload = .{ .tree = try alloc.dupe(*const GreenNode, &.{blk_node}) },
    };

    const recovered_li = try lowerItem(gpa, alloc, .{ .index = 0, .generation = 0 }, .fromIndex(0), fn_green, 0, &map);
    try assertLoweredItemInvariants(recovered_li);
    const tail_bin = recovered_li.item.func.body.?.tail.?.binary;
    try std.testing.expectEqual(.int_lit, std.meta.activeTag(tail_bin.lhs.*));
    try std.testing.expectEqual(.float_lit, std.meta.activeTag(tail_bin.rhs.*));
    try std.testing.expectEqual(@as(usize, 1), recovered_li.diagnostics.len);
}
