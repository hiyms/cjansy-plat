// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 仓颉语义分析与按需查询数据库库入口。

const std = @import("std");
const common = @import("common");

pub const ids = @import("ids.zig");
pub const string_interner = @import("interner/StringInterner.zig");
pub const type_interner = @import("interner/TypeInterner.zig");
pub const file_state = @import("db/FileState.zig");
pub const package_state = @import("db/PackageState.zig");
pub const preload_index = @import("db/PreloadIndex.zig");
pub const database = @import("db/Database.zig");
pub const access = @import("resolve/access.zig");
pub const scope = @import("resolve/scope.zig");
pub const resolve_package = @import("resolve/package.zig");
pub const resolve_file = @import("resolve/file.zig");
pub const literal = @import("typeck/literal.zig");
pub const subtype = @import("typeck/subtype.zig");
pub const join_meet = @import("typeck/join_meet.zig");
pub const solver = @import("typeck/solver.zig");
pub const lambda = @import("typeck/lambda.zig");
pub const builtin_expr = @import("typeck/builtin_expr.zig");
pub const overload = @import("typeck/overload.zig");
pub const checker = @import("typeck/checker.zig");
pub const syntax_node = @import("view/SyntaxNode.zig");
pub const symbol_view = @import("view/SymbolView.zig");
pub const scope_view = @import("view/ScopeView.zig");
pub const queries = @import("view/Queries.zig");

// 顶层高频类型重导出
pub const InternedId = ids.InternedId;
pub const ModuleId = ids.ModuleId;
pub const PackageId = ids.PackageId;
pub const GlobalItemId = ids.GlobalItemId;
pub const GlobalHirKey = ids.GlobalHirKey;
pub const DefId = ids.DefId;
pub const LocalSymId = ids.LocalSymId;
pub const CallableRef = ids.CallableRef;
pub const ScopeId = ids.ScopeId;
pub const TypeId = ids.TypeId;
pub const TypeListId = ids.TypeListId;
pub const PrimKind = ids.PrimKind;
pub const TypeParamRef = ids.TypeParamRef;
pub const SymbolRef = ids.SymbolRef;
pub const Visibility = ids.Visibility;
pub const AccessDomain = ids.AccessDomain;
pub const AccessContext = ids.AccessContext;
pub const SymbolKind = ids.SymbolKind;
pub const ReferenceKind = ids.ReferenceKind;

pub const StringInterner = string_interner.StringInterner;
pub const PackageInterner = string_interner.PackageInterner;
pub const PackageInfo = string_interner.PackageInfo;
pub const ModuleInfo = string_interner.ModuleInfo;
pub const PackageRelation = string_interner.PackageRelation;

pub const PointerWidth = type_interner.PointerWidth;
pub const TargetConfig = type_interner.TargetConfig;
pub const TypeData = type_interner.TypeData;
pub const KnownDefs = type_interner.KnownDefs;
pub const TypeInterner = type_interner.TypeInterner;

pub const PlatformError = file_state.PlatformError;
pub const FileDeclFingerprint = file_state.FileDeclFingerprint;
pub const FileQueryState = file_state.FileQueryState;
pub const DefOrigin = package_state.DefOrigin;
pub const DefFlags = package_state.DefFlags;
pub const DefEntry = package_state.DefEntry;
pub const GenericBoundSig = package_state.GenericBoundSig;
pub const NominalHeader = package_state.NominalHeader;
pub const TypeAliasHeader = package_state.TypeAliasHeader;
pub const CallableParamSig = package_state.CallableParamSig;
pub const CallableHeaderSig = package_state.CallableHeaderSig;
pub const ExportEntry = package_state.ExportEntry;
pub const ExtendEntry = package_state.ExtendEntry;
pub const PackageState = package_state.PackageState;
pub const PreloadSymbolMatch = preload_index.PreloadSymbolMatch;
pub const PackageIndexProvider = preload_index.PackageIndexProvider;

pub const InferState = database.InferState;
pub const InferredDep = database.InferredDep;
pub const DatabaseConfig = database.DatabaseConfig;
pub const Database = database.Database;

pub const ScopeKind = scope.ScopeKind;
pub const LocalSymbol = scope.LocalSymbol;
pub const DefSourceInfo = scope.DefSourceInfo;
pub const Scope = scope.Scope;
pub const ResolvedIdentOccurrence = scope.ResolvedIdentOccurrence;
pub const VisibleExtendIndex = scope.VisibleExtendIndex;
pub const FileResolveData = scope.FileResolveData;

pub const SynPos = checker.SynPos;
pub const OutgoingSymbolRef = checker.OutgoingSymbolRef;
pub const ItemTypeckData = checker.ItemTypeckData;
pub const SubtypeOptions = subtype.SubtypeOptions;
pub const JoinMeetResult = join_meet.JoinMeetResult;
pub const LocalSolver = solver.LocalSolver;

pub const SyntaxNode = syntax_node.SyntaxNode;
pub const TypeView = symbol_view.TypeView;
pub const ParamView = symbol_view.ParamView;
pub const FnSigView = symbol_view.FnSigView;
pub const SymbolView = symbol_view.SymbolView;
pub const ScopeView = scope_view.ScopeView;
pub const Location = queries.Location;
pub const CompletionCandidate = queries.CompletionCandidate;

test {
    _ = ids;
    _ = string_interner;
    _ = type_interner;
    _ = file_state;
    _ = scope;
    _ = literal;
}

test "Database 基础查询、类型文档注释与 TypeView 展示" {
    const gpa = std.testing.allocator;
    var db = try Database.init(gpa, .{});
    defer db.deinit();

    const src =
        \\/// 演示用用户结构体文档。
        \\public struct User {
        \\    public let id: Int64
        \\    public init(id: Int64) {
        \\        this.id = id
        \\    }
        \\}
        \\
        \\/// 用户标识类型别名文档。
        \\public type UserId = Int64
        \\
        \\public func makeUser(n: UserId) {
        \\    let u = User(n)
        \\    u
        \\}
    ;
    const f = try db.addWorkspaceFile("/demo/user.cj", src, .{});

    const pkg = try db.packageOfFile(f);
    const ps = try db.packageState(pkg);
    const s_user = try db.strings.intern("User");
    const user_def = ps.lookupTop(s_user)[0].def;
    const user_nh = try db.nominalHeaderOf(user_def);
    try std.testing.expect(user_nh.doc != null);
    try std.testing.expectEqualStrings("演示用用户结构体文档。", db.strings.get(user_nh.doc.?));

    const user_ty = try db.types.intern(.{ .nominal = .{ .def = user_def, .args = .empty } });
    const user_tv = try db.typeViewOf(f, user_ty, null);
    try std.testing.expectEqualStrings("User", user_tv.display);
    try std.testing.expectEqualStrings("演示用用户结构体文档。", user_tv.doc.?);

    const s_alias = try db.strings.intern("UserId");
    const alias_def = ps.lookupTop(s_alias)[0].def;
    const alias_tv = try db.typeViewOf(f, try db.typeAliasTargetOf(alias_def), alias_def);
    try std.testing.expectEqualStrings("Int64", alias_tv.display);
    try std.testing.expectEqualStrings("用户标识类型别名文档。", alias_tv.doc.?);

    // 基础类型文档注释验证
    const i64_doc = try db.typeDocOf(TypeInterner.int64_ty);
    try std.testing.expect(i64_doc != null);

    // 省略返回类型推导验证
    const s_make = try db.strings.intern("makeUser");
    const make_def = ps.lookupTop(s_make)[0].def;
    const ret_ty = try db.returnTypeOf(make_def);
    try std.testing.expectEqual(user_ty, ret_ty);

    const diags = try db.allDiagnostics(gpa, f);
    defer gpa.free(diags);
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "Database 两级增量失效、DefId 世代校验与 gcTypes 回收" {
    const gpa = std.testing.allocator;
    var db = try Database.init(gpa, .{});
    defer db.deinit();

    const f1 = try db.addWorkspaceFile("/inc/a.cj",
        \\package demo.a
        \\public func value() {
        \\    1
        \\}
    , .{});
    const f2 = try db.addWorkspaceFile("/inc/b.cj",
        \\package demo.b
        \\import demo.a.*
        \\public func useValue() {
        \\    value()
        \\}
    , .{});

    const pkg_a = try db.packageOfFile(f1);
    const ps_a1 = try db.packageState(pkg_a);
    const gen_a1 = ps_a1.generation;
    const s_val = try db.strings.intern("value");
    const val_def_v1 = ps_a1.lookupTop(s_val)[0].def;
    try std.testing.expectEqual(TypeInterner.int64_ty, try db.returnTypeOf(val_def_v1));

    const pkg_b = try db.packageOfFile(f2);
    const ps_b1 = try db.packageState(pkg_b);
    const s_use = try db.strings.intern("useValue");
    const use_def_v1 = ps_b1.lookupTop(s_use)[0].def;
    try std.testing.expectEqual(TypeInterner.int64_ty, try db.returnTypeOf(use_def_v1));

    // 快速路径：仅修改函数体内部字面量，PackageState 世代与 DefId 保持不变
    const content1 = try db.fileContent(f1);
    const pos_one = std.mem.indexOf(u8, content1, "1").?;
    try db.updateFile(f1, &.{.{
        .range = .{ .start = @intCast(pos_one), .end = @intCast(pos_one + 1) },
        .new_text = "true",
    }});
    const ps_a2 = try db.packageState(pkg_a);
    try std.testing.expectEqual(gen_a1, ps_a2.generation);
    try std.testing.expectEqual(TypeInterner.bool_ty, try db.returnTypeOf(val_def_v1));
    // 跨文件省略返回类型函数 useValue 在快速路径下应同步推导出最新返回类型 Bool
    try std.testing.expectEqual(TypeInterner.bool_ty, try db.returnTypeOf(use_def_v1));

    // 结构变更路径：修改签名添加参数触发下游包传递失效与 DefId 世代号递增
    const content2 = try db.fileContent(f1);
    const pos_paren = std.mem.indexOf(u8, content2, "()").?;
    try db.updateFile(f1, &.{.{
        .range = .{ .start = @intCast(pos_paren), .end = @intCast(pos_paren + 2) },
        .new_text = "(x: Int64)",
    }});
    const ps_a3 = try db.packageState(pkg_a);
    const gen_a3 = ps_a3.generation;
    try std.testing.expect(gen_a3 > gen_a1);
    try std.testing.expectError(error.InvalidDefId, db.getDef(val_def_v1));

    // gcTypes 回收验证
    try db.gcTypes();
    const ps_a4 = try db.packageState(pkg_a);
    try std.testing.expect(ps_a4.generation > gen_a3);
}

test "Database 无标注递归函数三色环路截断与公开签名低可见性暴露检查" {
    const gpa = std.testing.allocator;
    var db = try Database.init(gpa, .{});
    defer db.deinit();

    const src =
        \\private class Secret {}
        \\public func leak(s: Secret): Unit {}
        \\public func rec(n: Int64) {
        \\    rec(n - 1)
        \\}
    ;
    const f = try db.addWorkspaceFile("/check/vis.cj", src, .{});
    const pkg = try db.packageOfFile(f);
    const ps = try db.packageState(pkg);

    // 无标注直接递归截断，返回 err_ty 且不发生无限递归
    const s_rec = try db.strings.intern("rec");
    const rec_def = ps.lookupTop(s_rec)[0].def;
    const rec_ret = try db.returnTypeOf(rec_def);
    try std.testing.expectEqual(TypeInterner.err_ty, rec_ret);

    // 公开函数参数暴露 private 类型触发诊断
    const diags = try db.allDiagnostics(gpa, f);
    defer gpa.free(diags);
    var found_exposure = false;
    for (diags) |d| {
        if (std.mem.indexOf(u8, d.message, "低可见性") != null) {
            found_exposure = true;
            break;
        }
    }
    try std.testing.expect(found_exposure);
}

test "多文件同包、主构造器、extend、VArray 实参与视图聚合查询" {
    const gpa = std.testing.allocator;
    var db = try Database.init(gpa, .{});
    defer db.deinit();

    const ops_src =
        \\package sample
        \\
        \\/**
        \\ * 读取固定两元素数组
        \\ */
        \\protected func readPair(data: Array<UInt8>): VArray<UInt64, $2> {
        \\    if (data.size > 0) {
        \\        [UInt64(data[0]), UInt64(data[0])]
        \\    } else {
        \\        [0, 0]
        \\    }
        \\}
        \\
        \\protected const MULTIPLIER: UInt64 = 6364136223846793005
        \\
        \\protected func mix(a: UInt64, b: UInt64): UInt64 {
        \\    (a ^ b) * MULTIPLIER
        \\}
    ;
    const state_src =
        \\package sample
        \\
        \\const ROT = 23u32
        \\
        \\public struct SeedState {
        \\    protected SeedState(protected let k0: UInt64, protected let k1: UInt64) {}
        \\}
        \\
        \\public class HasherBox {
        \\    protected HasherBox(var acc: UInt64, var keys: VArray<UInt64, $2>) {}
        \\
        \\    protected static func fromSeed(seed: SeedState) {
        \\        HasherBox(seed.k0, [seed.k0, seed.k1])
        \\    }
        \\
        \\    public func clone() {
        \\        HasherBox(this.acc, this.keys)
        \\    }
        \\}
        \\
        \\extend HasherBox {
        \\    public func write(v: UInt8) {
        \\        UInt64(v) |> this.write
        \\    }
        \\
        \\    public func write(v: UInt64) {
        \\        this.acc = mix(this.acc, v)
        \\    }
        \\
        \\    public func finish() {
        \\        let pair = readPair([1u8, 2u8])
        \\        let shift = ROT
        \\        let hi = (acc << shift) | (acc >> (64 - shift))
        \\        mix(hi, pair[0])
        \\    }
        \\}
        \\
        \\extend SeedState {
        \\    public static func makeDefault() {
        \\        let h = HasherBox.fromSeed(SeedState(1u64, 2u64))
        \\        let copy = h.clone()
        \\        copy.write(3u8)
        \\        let out = copy.finish()
        \\        SeedState(out, out)
        \\    }
        \\}
    ;

    const f_ops = try db.addWorkspaceFile("/sample/ops.cj", ops_src, .{});
    const f_state = try db.addWorkspaceFile("/sample/state.cj", state_src, .{});

    const pkg = try db.packageOfFile(f_ops);
    try std.testing.expectEqual(pkg, try db.packageOfFile(f_state));

    const ps = try db.packageState(pkg);
    const s_read_pair = try db.strings.intern("readPair");
    const rp_def = ps.lookupTop(s_read_pair)[0].def;
    const rp_entry = try db.getDef(rp_def);
    try std.testing.expectEqualStrings("读取固定两元素数组", db.strings.get(rp_entry.doc.?));

    const s_rot = try db.strings.intern("ROT");
    try std.testing.expectEqual(TypeInterner.uint32_ty, try db.varTypeOf(ps.lookupTop(s_rot)[0].def));

    const s_box = try db.strings.intern("HasherBox");
    const box_def = ps.lookupTop(s_box)[0].def;
    const box_entry = try db.getDef(box_def);
    const s_from_seed = try db.strings.intern("fromSeed");
    const s_clone = try db.strings.intern("clone");
    for (box_entry.members) |m| {
        const me = try db.getDef(m);
        if (me.name == s_from_seed or me.name == s_clone) {
            const tv = try db.typeViewOf(f_state, try db.returnTypeOf(m), null);
            try std.testing.expectEqualStrings("HasherBox", tv.display);
        }
    }

    const s_finish = try db.strings.intern("finish");
    const s_make_def = try db.strings.intern("makeDefault");
    const s_seed = try db.strings.intern("SeedState");
    const seed_def = ps.lookupTop(s_seed)[0].def;
    var checked_finish = false;
    var checked_make = false;
    for (ps.extends) |ext| {
        if (ext.target_kind != .nominal) continue;
        const ee = try db.getDef(ext.def);
        if (DefId.eql(ext.target_kind.nominal, box_def)) {
            for (ee.members) |m| {
                if ((try db.getDef(m)).name == s_finish) {
                    try std.testing.expectEqual(TypeInterner.uint64_ty, try db.returnTypeOf(m));
                    checked_finish = true;
                }
            }
        } else if (DefId.eql(ext.target_kind.nominal, seed_def)) {
            for (ee.members) |m| {
                if ((try db.getDef(m)).name == s_make_def) {
                    const tv = try db.typeViewOf(f_state, try db.returnTypeOf(m), null);
                    try std.testing.expectEqualStrings("SeedState", tv.display);
                    checked_make = true;
                }
            }
        }
    }
    try std.testing.expect(checked_finish);
    try std.testing.expect(checked_make);

    const d_ops = try db.allDiagnostics(gpa, f_ops);
    defer gpa.free(d_ops);
    try std.testing.expectEqual(@as(usize, 0), d_ops.len);

    const d_state = try db.allDiagnostics(gpa, f_state);
    defer gpa.free(d_state);
    try std.testing.expectEqual(@as(usize, 0), d_state.len);

    // 校验 symbolAt、references 与成员补全
    const rp_pos = std.mem.indexOf(u8, ops_src, "readPair").?;
    const sym_v = (try db.symbolAt(f_ops, @intCast(rp_pos + 1))).?;
    try std.testing.expectEqualStrings("readPair", sym_v.name);
    try std.testing.expectEqualStrings("读取固定两元素数组", sym_v.doc.?);

    const refs = try db.references(gpa, .{ .def = rp_def }, true);
    defer gpa.free(refs);
    try std.testing.expectEqual(@as(usize, 2), refs.len);

    const acc_pos = std.mem.indexOf(u8, state_src, "this.acc").?;
    const comps = try db.completionsAt(gpa, f_state, @intCast(acc_pos + 6));
    defer gpa.free(comps);
    try std.testing.expect(comps.len > 0);
}

test "嵌套子作用域隔离、前向类型别名、Unit 校验与负字面量边界" {
    const gpa = std.testing.allocator;
    var db = try Database.init(gpa, .{});
    defer db.deinit();

    const ok_src =
        \\public type AliasA = AliasB
        \\public type AliasB = Int64
        \\
        \\public func nestedScope(flag: Bool): AliasA {
        \\    let a = 1
        \\    if (flag) {
        \\        let b = 2
        \\        let _ = b
        \\    }
        \\    let c = a + 3
        \\    let min_i8: Int8 = -128i8
        \\    let zero_f: Float64 = 0.0e10
        \\    let _ = (min_i8, zero_f)
        \\    c
        \\}
    ;
    const f_ok = try db.addWorkspaceFile("/reg/ok.cj", ok_src, .{});
    const pkg = try db.packageOfFile(f_ok);
    const ps = try db.packageState(pkg);
    const s_alias_a = try db.strings.intern("AliasA");
    const alias_a_def = ps.lookupTop(s_alias_a)[0].def;
    try std.testing.expectEqual(TypeInterner.int64_ty, try db.typeAliasTargetOf(alias_a_def));

    const diags_ok = try db.allDiagnostics(gpa, f_ok);
    defer gpa.free(diags_ok);
    try std.testing.expectEqual(@as(usize, 0), diags_ok.len);

    // 验证 Unit 目标不再错误放行整数初始化表达式
    const bad_unit_src =
        \\public func badUnit(): Unit {
        \\    let u: Unit = 123
        \\    u
        \\}
    ;
    const f_bad = try db.addWorkspaceFile("/reg/bad_unit.cj", bad_unit_src, .{});
    const diags_bad = try db.allDiagnostics(gpa, f_bad);
    defer gpa.free(diags_bad);
    try std.testing.expect(diags_bad.len >= 1);
}
