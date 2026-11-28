// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 平台错误集合、单文件版本化查询内存池（`FileQueryState`）与声明头摘要指纹（`FileDeclFingerprint`）。

const std = @import("std");
const common = @import("common");
const frontend = @import("frontend");
const ids = @import("../ids.zig");
const scope_mod = @import("../resolve/scope.zig");
const checker_mod = @import("../typeck/checker.zig");

const PackageId = ids.PackageId;
const FileResolveData = scope_mod.FileResolveData;
const ItemTypeckData = checker_mod.ItemTypeckData;

/// 平台级错误：仅用于句柄无效、参数范围非法或内存耗尽。
/// 仓颉源码语法与语义缺陷一律产出 `common.Diagnostic` 与 `TypeInterner.err_ty`。
pub const PlatformError =
    common.source.Error ||
    frontend.lexer.Lexer.Error ||
    error{
        InvalidPackageId,
        InvalidDefId,
        InvalidScopeId,
        InvalidItemId,
    };

/// 128 位声明头摘要指纹。
///
/// 覆盖 `PackageHeader`、`FeaturesDirective`、`ImportItem` 列表，以及本文件全部非局部声明的
/// 名称、修饰符、泛型形参列表、父类型列表、`where` 约束、显式类型标注结构、成员排列顺序与
/// 前导文档注释 `doc_comment`（不含函数体内部语句、源码字节区间与普通注释）。
pub const FileDeclFingerprint = u128;

const DualHasher = struct {
    h0: std.hash.Wyhash,
    h1: std.hash.Wyhash,

    /// 初始化双路 64 位哈希器以产生 128 位指纹。
    inline fn init() DualHasher {
        return .{
            .h0 = std.hash.Wyhash.init(0x9e3779b97f4a7c15),
            .h1 = std.hash.Wyhash.init(0xbf58476d1ce4e5b9),
        };
    }

    /// 混入字节切片。
    inline fn update(self: *DualHasher, bytes: []const u8) void {
        self.h0.update(bytes);
        self.h1.update(bytes);
    }

    /// 混入单个字节标记。
    inline fn tag(self: *DualHasher, byte: u8) void {
        self.update(&.{byte});
    }

    /// 混入定宽整数。
    inline fn int(self: *DualHasher, v: u64) void {
        self.update(std.mem.asBytes(&v));
    }

    /// 混入带长度前缀的字符串切片，避免边界拼接碰撞。
    inline fn str(self: *DualHasher, text: []const u8) void {
        self.int(@intCast(text.len));
        self.update(text);
    }

    /// 混入 HIR 名称（包含 `is_raw` 标记，不含字节区间）。
    inline fn name(self: *DualHasher, n: common.Name) void {
        self.tag(@intFromBool(n.is_raw));
        self.str(n.text);
    }

    /// 输出最终 128 位摘要指纹。
    inline fn final(self: *DualHasher) FileDeclFingerprint {
        const lo: u128 = self.h0.final();
        const hi: u128 = self.h1.final();
        return (hi << 64) | lo;
    }
};

/// 结合无损语法树与 `LoweredFile` 计算单文件声明头摘要指纹（含各声明前导文档注释）。
pub fn computeDeclFingerprint(
    syntax_tree: common.SyntaxTree,
    lowered: *const frontend.LoweredFile,
) FileDeclFingerprint {
    var h = DualHasher.init();
    const hf = lowered.hir_file;

    // 1. 包声明头
    if (hf.package) |pkg| {
        h.tag(1);
        h.tag(if (pkg.modifier) |m| @backingInt(m) else 0xFF);
        h.tag(@intFromBool(pkg.is_macro));
        if (pkg.org) |org| {
            h.tag(1);
            h.name(org);
        } else {
            h.tag(0);
        }
        h.int(@intCast(pkg.name.len));
        for (pkg.name) |seg| h.name(seg);
    } else {
        h.tag(0);
    }

    // 2. 特性指令
    if (hf.features) |feats| {
        h.tag(1);
        h.int(@intCast(feats.features.len));
        for (feats.features) |fid| {
            h.int(@intCast(fid.segments.len));
            for (fid.segments) |seg| h.name(seg);
        }
    } else {
        h.tag(0);
    }

    // 3. 导入列表
    h.int(@intCast(hf.imports.len));
    for (hf.imports) |imp| hashImport(&h, imp);

    // 4. 顶层非局部声明头
    h.int(@intCast(hf.items.len));
    for (hf.items) |*item| hashItemHeader(&h, item);

    // 5. 声明级前导文档注释（仅扫描顶层与成员声明体，不深入函数体或语句块）
    hashDeclDocComments(&h, syntax_tree.tree.root);

    return h.final();
}

/// 递归哈希单条 `ImportItem` 结构。
fn hashImport(h: *DualHasher, imp: common.ImportItem) void {
    h.tag(if (imp.modifier) |m| @backingInt(m) else 0xFF);
    if (imp.org) |org| {
        h.tag(1);
        h.name(org);
    } else {
        h.tag(0);
    }
    h.int(@intCast(imp.prefix.len));
    for (imp.prefix) |seg| h.name(seg);
    h.tag(@backingInt(std.meta.activeTag(imp.kind)));
    switch (imp.kind) {
        .single => |n| h.name(n),
        .alias => |a| {
            h.name(a.name);
            h.name(a.alias);
        },
        .glob => {},
        .group => |items| {
            h.int(@intCast(items.len));
            for (items) |sub| hashImport(h, sub);
        },
    }
}

/// 哈希修饰符切片。
fn hashModifiers(h: *DualHasher, mods: []const common.Modifier) void {
    h.int(@intCast(mods.len));
    for (mods) |m| h.tag(@backingInt(m));
}

/// 哈希泛型形参名称列表。
fn hashTypeParams(h: *DualHasher, tps: []const common.Name) void {
    h.int(@intCast(tps.len));
    for (tps) |tp| h.name(tp);
}

/// 哈希可选 `WhereClause`。
fn hashWhereClause(h: *DualHasher, wc: ?*const common.WhereClause) void {
    if (wc) |w| {
        h.tag(1);
        h.int(@intCast(w.constraints.len));
        for (w.constraints) |c| {
            hashHirType(h, c.subject);
            h.int(@intCast(c.bounds.len));
            for (c.bounds) |*b| hashHirType(h, b);
        }
    } else {
        h.tag(0);
    }
}

/// 递归哈希显式 `HirType` 结构（不含源码字节区间）。
fn hashHirType(h: *DualHasher, ty: *const common.HirType) void {
    h.tag(@backingInt(std.meta.activeTag(ty.*)));
    switch (ty.*) {
        .path => |p| {
            h.int(@intCast(p.segments.len));
            for (p.segments) |seg| {
                h.name(seg.name);
                h.int(@intCast(seg.type_args.len));
                for (seg.type_args) |*ta| hashHirType(h, ta);
            }
        },
        .option => |o| hashHirType(h, o.inner),
        .tuple => |t| {
            h.int(@intCast(t.elements.len));
            for (t.elements) |el| hashHirType(h, el.ty);
        },
        .func => |f| {
            h.int(@intCast(f.params.len));
            for (f.params) |p| hashHirType(h, p.ty);
            hashHirType(h, f.ret);
        },
        .varray => |v| {
            hashHirType(h, v.elem);
            h.str(v.size);
        },
        .this => {},
    }
}

/// 哈希形参列表结构（包含命名标记、默认值存在标记、主构造器字段绑定与显式类型）。
fn hashParams(h: *DualHasher, params: []const common.Param) void {
    h.int(@intCast(params.len));
    for (params) |param| {
        h.tag(@backingInt(std.meta.activeTag(param)));
        switch (param) {
            .param => |hp| {
                hashModifiers(h, hp.modifiers);
                h.tag(if (hp.binding) |b| @backingInt(b) else 0xFF);
                if (hp.name) |n| {
                    h.tag(1);
                    h.name(n);
                } else {
                    h.tag(0);
                }
                h.tag(@intFromBool(hp.is_named));
                h.tag(@intFromBool(hp.default_value != null));
                if (hp.ty) |t| {
                    h.tag(1);
                    hashHirType(h, t);
                } else {
                    h.tag(0);
                }
            },
            .macro_call => |pm| {
                h.int(@intCast(pm.call.path.len));
                for (pm.call.path) |seg| h.name(seg);
                if (pm.param) |inner| hashParams(h, inner[0..1]);
            },
        }
    }
}

/// 哈希模式绑定名称结构（用于顶层或成员解构绑定 `let (a, b) = ...`）。
fn hashPatternHead(h: *DualHasher, pat: *const common.HirPattern) void {
    h.tag(@backingInt(std.meta.activeTag(pat.*)));
    switch (pat.*) {
        .binding => |b| h.name(b.name),
        .tuple => |t| {
            h.int(@intCast(t.elements.len));
            for (t.elements) |*el| hashPatternHead(h, el);
        },
        .typed => |tp| {
            if (tp.name) |n| {
                h.tag(1);
                h.name(n);
            } else {
                h.tag(0);
            }
            hashHirType(h, tp.ty);
        },
        else => {},
    }
}

/// 哈希单个非局部 `HirItem` 的声明头结构（忽略全部函数体与变量初始化表达式内部）。
fn hashItemHeader(h: *DualHasher, item: *const common.HirItem) void {
    h.tag(@backingInt(std.meta.activeTag(item.*)));
    switch (item.*) {
        .func => |f| {
            hashModifiers(h, f.modifiers);
            h.tag(@backingInt(std.meta.activeTag(f.name)));
            switch (f.name) {
                .ident, .operator => |n| h.name(n),
            }
            hashTypeParams(h, f.type_params);
            hashParams(h, f.params);
            h.tag(@intFromBool(f.is_variadic));
            h.tag(@intFromBool(f.body != null));
            if (f.ret_type) |rt| {
                h.tag(1);
                hashHirType(h, rt);
            } else {
                h.tag(0);
            }
            hashWhereClause(h, f.where_clause);
        },
        .main => |m| {
            hashModifiers(h, m.modifiers);
            hashParams(h, m.params);
            h.tag(@intFromBool(m.is_variadic));
            if (m.ret_type) |rt| {
                h.tag(1);
                hashHirType(h, rt);
            } else {
                h.tag(0);
            }
        },
        .class => |c| {
            hashModifiers(h, c.modifiers);
            h.name(c.name);
            hashTypeParams(h, c.type_params);
            h.int(@intCast(c.supertypes.len));
            for (c.supertypes) |*st| hashHirType(h, st);
            hashWhereClause(h, c.where_clause);
            h.int(@intCast(c.members.len));
            for (c.members) |*mem| hashItemHeader(h, mem);
        },
        .struct_ => |s| {
            hashModifiers(h, s.modifiers);
            h.name(s.name);
            hashTypeParams(h, s.type_params);
            h.int(@intCast(s.interfaces.len));
            for (s.interfaces) |*iface| hashHirType(h, iface);
            hashWhereClause(h, s.where_clause);
            h.int(@intCast(s.members.len));
            for (s.members) |*mem| hashItemHeader(h, mem);
        },
        .enum_ => |e| {
            hashModifiers(h, e.modifiers);
            h.name(e.name);
            hashTypeParams(h, e.type_params);
            h.int(@intCast(e.interfaces.len));
            for (e.interfaces) |*iface| hashHirType(h, iface);
            hashWhereClause(h, e.where_clause);
            h.tag(@intFromBool(e.is_non_exhaustive));
            h.int(@intCast(e.variants.len));
            for (e.variants) |*v| hashEnumVariantHeader(h, v);
            h.int(@intCast(e.members.len));
            for (e.members) |*mem| hashItemHeader(h, mem);
        },
        .interface => |i| {
            hashModifiers(h, i.modifiers);
            h.name(i.name);
            hashTypeParams(h, i.type_params);
            h.int(@intCast(i.interfaces.len));
            for (i.interfaces) |*iface| hashHirType(h, iface);
            hashWhereClause(h, i.where_clause);
            h.int(@intCast(i.members.len));
            for (i.members) |*mem| hashItemHeader(h, mem);
        },
        .extend_ => |ex| {
            hashModifiers(h, ex.modifiers);
            hashTypeParams(h, ex.type_params);
            hashHirType(h, ex.target);
            h.int(@intCast(ex.interfaces.len));
            for (ex.interfaces) |*iface| hashHirType(h, iface);
            hashWhereClause(h, ex.where_clause);
            h.int(@intCast(ex.members.len));
            for (ex.members) |*mem| hashItemHeader(h, mem);
        },
        .prop => |p| {
            hashModifiers(h, p.modifiers);
            h.name(p.name);
            hashHirType(h, p.ty);
            h.int(@intCast(p.accessors.len));
            for (p.accessors) |acc| h.name(acc.name);
        },
        .type_alias => |ta| {
            hashModifiers(h, ta.modifiers);
            h.name(ta.name);
            hashTypeParams(h, ta.type_params);
            hashHirType(h, ta.target);
        },
        .init => |in| {
            hashModifiers(h, in.modifiers);
            hashParams(h, in.params);
            h.tag(@intFromBool(in.is_variadic));
        },
        .finalizer => |fin| {
            hashModifiers(h, fin.modifiers);
            hashParams(h, fin.params);
        },
        .primary_ctor => |pc| {
            hashModifiers(h, pc.modifiers);
            h.name(pc.name);
            hashParams(h, pc.params);
            h.tag(@intFromBool(pc.is_variadic));
        },
        .binding => |b| {
            hashModifiers(h, b.modifiers);
            h.tag(@backingInt(b.kind));
            hashPatternHead(h, b.pattern);
            if (b.ty) |t| {
                h.tag(1);
                hashHirType(h, t);
            } else {
                h.tag(0);
            }
            h.tag(@intFromBool(b.init != null));
        },
        .foreign => |fg| {
            hashModifiers(h, fg.modifiers);
            h.int(@intCast(fg.members.len));
            for (fg.members) |*mem| hashItemHeader(h, mem);
        },
        .macro_ => |mc| {
            hashModifiers(h, mc.modifiers);
            h.name(mc.name);
            hashParams(h, mc.params);
            if (mc.ret_type) |rt| {
                h.tag(1);
                hashHirType(h, rt);
            } else {
                h.tag(0);
            }
        },
        .macro_expand => |me| {
            h.int(@intCast(me.call.path.len));
            for (me.call.path) |seg| h.name(seg);
            if (me.wrapped) |w| {
                h.tag(1);
                hashItemHeader(h, w);
            } else {
                h.tag(0);
            }
        },
    }
}

/// 哈希单个枚举构造器头结构。
fn hashEnumVariantHeader(h: *DualHasher, variant: *const common.EnumVariant) void {
    h.tag(@backingInt(std.meta.activeTag(variant.*)));
    switch (variant.*) {
        .constructor => |c| {
            h.name(c.name);
            h.int(@intCast(c.payload.len));
            for (c.payload) |el| {
                switch (el) {
                    .ty => |pt| hashHirType(h, pt.ty),
                    .macro_call => |pm| {
                        h.int(@intCast(pm.call.path.len));
                        for (pm.call.path) |seg| h.name(seg);
                    },
                }
            }
        },
        .macro_call => |vm| {
            h.int(@intCast(vm.call.path.len));
            for (vm.call.path) |seg| h.name(seg);
            if (vm.constructor) |inner| hashEnumVariantHeader(h, inner);
        },
    }
}

/// 递归哈希顶层与容器体成员节点上的前导文档注释 `doc_comment`（跳过函数体与表达式语句块，避免函数体内部编辑导致指纹抖动）。
fn hashDeclDocComments(h: *DualHasher, node: *const common.GreenNode) void {
    switch (node.kind) {
        .block, .stmt_list => return,
        .doc_comment => {
            h.tag(0xDC);
            if (node.tokenText()) |txt| h.str(txt);
            return;
        },
        else => {},
    }
    for (node.children()) |child| {
        hashDeclDocComments(h, child);
    }
}

/// 从声明 `GreenNode` 的前导子节点提取并规范化文档注释正文（去除 `///`、`/**`、`*/` 与每行前导 `*`）。
/// 返回切片由调用者传入的 `alloc` 分配，结束后须由调用者通过 `alloc.free` 释放；无文档注释返回 `null`。
pub fn extractLeadingDocComment(
    alloc: std.mem.Allocator,
    decl_node: *const common.GreenNode,
) std.mem.Allocator.Error!?[]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    var found = false;
    for (decl_node.children()) |child| {
        switch (child.kind) {
            .doc_comment => {
                const raw = child.tokenText() orelse continue;
                if (found) try buf.append(alloc, '\n');
                try appendCleanedDocComment(alloc, &buf, raw);
                found = true;
            },
            .whitespace, .newline, .line_comment, .block_comment, .annotation => {},
            else => break,
        }
    }
    if (!found) return null;
    return try buf.toOwnedSlice(alloc);
}

/// 清理单段仓颉文档注释文本定界符并追加至 `out`。
fn appendCleanedDocComment(
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    raw: []const u8,
) std.mem.Allocator.Error!void {
    if (std.mem.startsWith(u8, raw, "///")) {
        var content = raw[3..];
        if (content.len > 0 and content[0] == ' ') content = content[1..];
        content = std.mem.trimEnd(u8, content, "\r");
        try out.appendSlice(alloc, content);
        return;
    }
    if (std.mem.startsWith(u8, raw, "/**") and std.mem.endsWith(u8, raw, "*/") and raw.len >= 5) {
        const inner = raw[3 .. raw.len - 2];
        var lines = std.mem.splitScalar(u8, inner, '\n');
        var emitted_any = false;
        while (lines.next()) |line_raw| {
            var line = std.mem.trim(u8, line_raw, " \t\r");
            if (std.mem.startsWith(u8, line, "*")) {
                line = line[1..];
                if (line.len > 0 and line[0] == ' ') line = line[1..];
            }
            if (!emitted_any and line.len == 0) {
                continue;
            }
            if (emitted_any) try out.append(alloc, '\n');
            emitted_any = true;
            try out.appendSlice(alloc, line);
        }
        while (out.items.len > 0 and (out.items[out.items.len - 1] == '\n' or out.items[out.items.len - 1] == ' ')) {
            _ = out.pop();
        }
        return;
    }
    try out.appendSlice(alloc, raw);
}

/// 单文件版本化查询缓存与三级隔离单文件内存池。
///
/// 文件内容发生实际变更时，先清理关联推导缓存条目，再对三个内存池执行 `reset(.retain_capacity)`。
pub const FileQueryState = struct {
    file: common.FileId,
    /// 当前缓存对应的 `common.File.version`。
    cached_version: ?u32 = null,
    /// 上一次稳定解析出的包标识与声明头指纹，用于两级增量失效判定。
    last_pkg: ?PackageId = null,
    last_decl_fp: ?FileDeclFingerprint = null,

    /// 承载 `SyntaxTree`、`LoweredFile`、`GreenToHirMap` 与词法/语法/`lower` 阶段诊断。
    ast_hir_arena: std.heap.ArenaAllocator,
    /// 承载 `FileResolveData` 与本文件各顶层声明项的 `ItemTypeckData`。
    sema_arena: std.heap.ArenaAllocator,
    /// 承载对外只读视图层生成的格式化签名与展示切片。
    view_arena: std.heap.ArenaAllocator,

    syntax_tree: ?common.SyntaxTree = null,
    parse_diagnostics: []const common.Diagnostic = &.{},
    lowered: ?frontend.LoweredFile = null,
    green_to_hir: common.GreenToHirMap = .empty,

    resolve_data: ?*const FileResolveData = null,
    /// 长度等于 `lowered.lowered_items.len`，按 `ItemId.index()` 懒加载填充。
    item_typeck: []?*const ItemTypeckData = &.{},
    /// 跨文件 `inferred_deps` 导致局部声明项失效重算的累计次数；超过阈值时触发整文件 `sema_arena` 重置以控制内存水位。
    sema_recheck_count: u32 = 0,

    /// 初始化单文件状态；底层分配器统一传入 `Database.gpa`。
    pub fn init(gpa: std.mem.Allocator, file: common.FileId) FileQueryState {
        return .{
            .file = file,
            .ast_hir_arena = .init(gpa),
            .sema_arena = .init(gpa),
            .view_arena = .init(gpa),
        };
    }

    /// 释放三个内存池。
    pub fn deinit(self: *FileQueryState) void {
        self.view_arena.deinit();
        self.sema_arena.deinit();
        self.ast_hir_arena.deinit();
        self.* = undefined;
    }

    /// 清空当前文件全部阶段产物并保留底层容量。
    pub fn invalidateAll(self: *FileQueryState) void {
        self.cached_version = null;
        self.syntax_tree = null;
        self.parse_diagnostics = &.{};
        self.lowered = null;
        self.green_to_hir = .empty;
        self.resolve_data = null;
        self.item_typeck = &.{};
        self.sema_recheck_count = 0;
        _ = self.view_arena.reset(.retain_capacity);
        _ = self.sema_arena.reset(.retain_capacity);
        _ = self.ast_hir_arena.reset(.retain_capacity);
    }

    /// 仅失效语义分析与视图产物（用于上游包结构变更但本文件源码未变更的场景）。
    pub fn invalidateSemaAndView(self: *FileQueryState) void {
        self.resolve_data = null;
        self.item_typeck = &.{};
        self.sema_recheck_count = 0;
        _ = self.view_arena.reset(.retain_capacity);
        _ = self.sema_arena.reset(.retain_capacity);
    }
};

test "computeDeclFingerprint 忽略函数体内部修改但感知文档注释与声明头变更" {
    const gpa = std.testing.allocator;
    const src1 = "/// 类型文档\npublic class Foo {\n    public func bar(): Int64 { 1 }\n}\n";
    const src2 = "/// 类型文档\npublic class Foo {\n    public func bar(): Int64 { let x = 2; x + 3 }\n}\n";
    const src3 = "/// 修改后的文档\npublic class Foo {\n    public func bar(): Int64 { 1 }\n}\n";

    const fp1 = try computeTestFp(gpa, src1);
    const fp2 = try computeTestFp(gpa, src2);
    const fp3 = try computeTestFp(gpa, src3);

    try std.testing.expectEqual(fp1, fp2);
    try std.testing.expect(fp1 != fp3);
}

/// 解析并计算单段源码声明头指纹的测试辅助函数。
fn computeTestFp(gpa: std.mem.Allocator, text: []const u8) !FileDeclFingerprint {
    var tokens: std.ArrayListUnmanaged(common.Token) = .empty;
    defer tokens.deinit(gpa);
    var lex = try frontend.lexer.Lexer.new(text);
    while (true) {
        const tok = try lex.gen();
        try tokens.append(gpa, tok);
        if (tok.tag == .end) break;
    }
    var parser = frontend.parser.Parser.new(gpa, text, tokens.items);
    defer parser.deinit();
    try parser.parse();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const green = try frontend.treeBuild(gpa, arena.allocator(), text, parser.events.items);
    const st: common.SyntaxTree = .{ .file = .{ .index = 0, .generation = 0 }, .version = 0, .tree = green };
    const lowered = try frontend.lowerFile(gpa, arena.allocator(), st, null);
    return computeDeclFingerprint(st, &lowered);
}
