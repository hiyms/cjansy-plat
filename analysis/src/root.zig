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

/// 测试辅助函数：检查单段仓颉源码至少产生 1 条包含 `expected_substr` 的错误诊断。
fn expectDiagContains(src: []const u8, expected_substr: []const u8) !void {
    const gpa = std.testing.allocator;
    var db = try Database.init(gpa, .{});
    defer db.deinit();
    const f = try db.addWorkspaceFile("/diag_case.cj", src, .{});
    const diags = try db.allDiagnostics(gpa, f);
    defer gpa.free(diags);
    for (diags) |d| {
        if (d.severity == .err and std.mem.indexOf(u8, d.message, expected_substr) != null) {
            return;
        }
    }
    std.debug.print("\n期望包含诊断: \"{s}\"\n源码:\n{s}\n实际诊断 ({d} 条):\n", .{ expected_substr, src, diags.len });
    for (diags) |d| {
        std.debug.print("  - [{d}..{d}] {s}\n", .{ d.range.start, d.range.end, d.message });
    }
    return error.TestExpectedDiagnosticNotFound;
}

test "诊断完整性：名称解析、显式类型、循环别名、继承与导入错误必产诊断" {
    try expectDiagContains(
        \\func f() { unknown_var }
    , "未定义的标识符");
    try expectDiagContains(
        \\func f() { unknown_fn(1, 2) }
    , "未定义的标识符");
    try expectDiagContains(
        \\func f() { let x: UnknownType = 1 }
    , "未找到指定的类型名称");
    try expectDiagContains(
        \\func f() { let a: Array<Int64, String> = [1] }
    , "泛型类型实参个数与声明不匹配");
    try expectDiagContains(
        \\struct Plain {}
        \\func f() { let a: Plain<String> = Plain() }
    , "非泛型类型不允许提供类型实参");
    try expectDiagContains(
        \\func f() { let x = this }
    , "this 只能在类型或 extend 声明内部使用");
    try expectDiagContains(
        \\func f() { let x = super }
    , "super 只能在存在父类的 class 声明内部使用");
    try expectDiagContains(
        \\func f(): This { 1 }
    , "This 类型只能出现在类型或 extend 声明内部");
    try expectDiagContains(
        \\type CycleA = CycleB
        \\type CycleB = CycleA
    , "循环类型别名");
    try expectDiagContains(
        \\open class Base {}
        \\struct BadS <: Base {}
    , "只能继承或实现接口");
    try expectDiagContains(
        \\open class CA <: CB {}
        \\open class CB <: CA {}
    , "循环继承");
    try expectDiagContains(
        \\import no.such.pkg.*
        \\func f() {}
    , "找不到要导入的包");
    try expectDiagContains(
        \\import no.such.pkg.MissingSym
        \\func f() {}
    , "找不到要导入的包或符号");
}

test "诊断完整性：调用重载、构造器、成员访问、可选链与约束错误必产诊断" {
    try expectDiagContains(
        \\func add(a: Int64, b: Int64): Int64 { a + b }
        \\func testCall() { add(1) }
    , "未找到匹配实参列表的函数重载");
    try expectDiagContains(
        \\func add(a: Int64, b: Int64): Int64 { a + b }
        \\func testCall() { add("a", "b") }
    , "未找到匹配实参列表的函数重载");
    try expectDiagContains(
        \\func add(a: Int64, b: Int64): Int64 { a + b }
        \\func testCall() { let s: String = add(1, 2) }
    , "函数调用返回类型与期望类型不兼容");
    try expectDiagContains(
        \\interface Tag {}
        \\func needTag<T>(x: T): T where T <: Tag { x }
        \\func testCall() { needTag<Int64>(1) }
    , "where 约束上界");
    try expectDiagContains(
        \\func testCall() { let n = 1; n(2) }
    , "目标表达式不是可调用类型");
    try expectDiagContains(
        \\func testCall(f: (Int64) -> Int64) { f(1, 2) }
    , "实参个数与形参个数不匹配");
    try expectDiagContains(
        \\func testCall(f: (Int64) -> Int64) { let s: String = f(1) }
    , "表达式类型与期望类型不兼容");
    try expectDiagContains(
        \\struct Point {
        \\    public init(x: Int64) {}
        \\}
        \\func testCtor() { let p = Point("bad") }
    , "未找到匹配实参列表的构造器");
    try expectDiagContains(
        \\struct Empty {}
        \\func testCtor() { let e = Empty(1) }
    , "默认无参构造器不接受任何实参");
    try expectDiagContains(
        \\abstract class Abs {}
        \\func testCtor() { let a = Abs() }
    , "不能直接实例化抽象类");
    try expectDiagContains(
        \\struct Box { public let v: Int64 = 1 }
        \\func testMember(b: Box) { let x = b.missing }
    , "该类型不存在指定成员");
    try expectDiagContains(
        \\struct Box { private let secret: Int64 = 1 }
        \\func testMember(b: Box) { let x = b.secret }
    , "目标成员在当前作用域不可访问");
    try expectDiagContains(
        \\func testOpt() { let n = 1; let x = n?.size }
    , "可选链运算符 ? 的操作数必须为 Option<T> 类型");
    try expectDiagContains(
        \\struct Box { public let v: Int64 = 1 }
        \\func testOpt(b: ?Box) { let x = b.v }
    , "该类型不存在指定成员");
}

test "诊断完整性：运算符、复合赋值、左值可变性、下标索引与类型转换错误必产诊断" {
    try expectDiagContains(
        \\func testOp() { let x = 1.0 & 2.0 }
    , "未找到匹配的二元运算符实现");
    try expectDiagContains(
        \\func testOp(a: Int32, b: Int64) { let c = a < b }
    , "未找到匹配的二元运算符实现");
    try expectDiagContains(
        \\func testOp() { let c = true < false }
    , "未找到匹配的二元运算符实现");
    try expectDiagContains(
        \\func testComp() { let x = 1 ~> 2 }
    , "函数组合运算符 ~> 两侧必须为函数类型");
    try expectDiagContains(
        \\func testComp(f: (Int64) -> String, g: (Int64) -> Bool) { let h = f ~> g }
    , "左侧返回类型与右侧形参类型不兼容");
    try expectDiagContains(
        \\func testAssign() { var b = true; b += false }
    , "该类型不支持对应的复合赋值运算符");
    try expectDiagContains(
        \\func testAssign() { let x = 1; x = 2 }
    , "不能对不可变局部变量或形参赋值");
    try expectDiagContains(
        \\func testAssign(a: Int64) { a = 2 }
    , "不能对不可变局部变量或形参赋值");
    try expectDiagContains(
        \\func testAssign() { let x = 1; x++ }
    , "不能对不可变局部变量或形参赋值");
    try expectDiagContains(
        \\func testIdx() { let t = (1, "a"); let x = t[2] }
    , "元组下标索引越界");
    try expectDiagContains(
        \\func testIdx(i: Int64) { let t = (1, "a"); let x = t[i] }
    , "元组下标索引必须为非负整数字面量");
    try expectDiagContains(
        \\func testIdx(arr: Array<Int64>) { let x = arr["bad"] }
    , "表达式类型与期望类型不兼容");
    try expectDiagContains(
        \\func testIdx() { let n = 42; let x = n[0] }
    , "该类型不支持下标索引运算");
    try expectDiagContains(
        \\func testConv() { let x = Int64("abc") }
    , "不支持将该类型转换为目标基础类型");
}

test "诊断完整性：Lambda、语法糖、模式匹配与互递归推导错误必产诊断" {
    try expectDiagContains(
        \\func testLam() { let x: Int64 = { a: Int64 => a } }
    , "表达式类型与期望类型不兼容");
    try expectDiagContains(
        \\func testLam() { let f: (Int64) -> Int64 = { a, b => a } }
    , "Lambda 表达式形参个数与期望函数类型不匹配");
    try expectDiagContains(
        \\func testArr() { let x: Int64 = [1, 2] }
    , "表达式类型与期望类型不兼容");
    try expectDiagContains(
        \\func testCoal(o: ?Int64) { let s: String = o ?? 0 }
    , "表达式类型与期望类型不兼容");
    try expectDiagContains(
        \\func testRange() { let x: Int64 = 0..10 }
    , "表达式类型与期望类型不兼容");
    try expectDiagContains(
        \\func testRange() { let r = 0i32.."abc" }
    , "表达式类型与期望类型不兼容");
    try expectDiagContains(
        \\func testFor() { for (x in 123) {} }
    , "for-in 迭代源类型未实现 Iterable 接口");
    try expectDiagContains(
        \\func testIf(c: Bool) { let x: Int64 = if (c) { 1 } }
    , "表达式类型与期望类型不兼容");
    try expectDiagContains(
        \\func testSpawn() { let x: Int64 = spawn { 1 } }
    , "表达式类型与期望类型不兼容");
    try expectDiagContains(
        \\func testCatch() {
        \\    try { () } catch (e: Int64) { () }
        \\}
    , "catch 子句捕获的类型必须为 Exception 或 Error 子类型");
    try expectDiagContains(
        \\func testPat() { let (a, b) = 123 }
    , "元组模式只能匹配元组类型");
    try expectDiagContains(
        \\func testPat() { let (a, b) = (1, 2, 3) }
    , "元组模式元素个数与目标元组类型不匹配");
    try expectDiagContains(
        \\func testPat(o: ?Int64) {
        \\    match (o) {
        \\        case Some(a, b) => a
        \\        case _ => 0
        \\    }
        \\}
    , "枚举模式参数个数与构造器定义不匹配");
    try expectDiagContains(
        \\func testPat(o: ?Int64) {
        \\    match (o) {
        \\        case Option.Missing => 0
        \\        case _ => 0
        \\    }
        \\}
    , "目标枚举类型中不存在该构造器");
    try expectDiagContains(
        \\func mutualA(n: Int64) { mutualB(n) }
        \\func mutualB(n: Int64) { mutualA(n) }
    , "无显式返回类型标注的递归函数无法推导返回类型");
    try expectDiagContains(
        \\let cycA = cycB
        \\let cycB = cycA
    , "循环初始化依赖");
}

test "诊断完整性：合法语法糖、可选链、元组索引、位置 Lambda 与类型转换不产生误报" {
    const gpa = std.testing.allocator;
    var db = try Database.init(gpa, .{});
    defer db.deinit();

    const ok_src =
        \\public struct Item {
        \\    public let id: Int64
        \\    public var count: Int64
        \\    public init(id: Int64, count: Int64) {
        \\        this.id = id
        \\        this.count = count
        \\    }
        \\}
        \\
        \\func apply(v: Int64, f: (Int64) -> Int64): Int64 {
        \\    f(v)
        \\}
        \\
        \\public func validFeatures(opt: ?Item, arr: Array<Int64>): Int64 {
        \\    var sum = 0
        \\    sum += 1
        \\    sum++
        \\    let tup = (10, "hi")
        \\    let first: Int64 = tup[0]
        \\    let slice = arr[0..2]
        \\    let maybe_id: ?Int64 = opt?.id
        \\    let id_val: Int64 = maybe_id ?? 0
        \\    let va = VArray<Int64, $2>(repeat: 0)
        \\    let ch: Rune = Rune(65)
        \\    let code: UInt32 = UInt32(ch)
        \\    let applied = apply(first, { x => x + 1 })
        \\    let _ = (slice, va, code)
        \\    sum + id_val + applied
        \\}
    ;
    const f = try db.addWorkspaceFile("/valid/features.cj", ok_src, .{});
    const diags = try db.allDiagnostics(gpa, f);
    defer gpa.free(diags);
    if (diags.len > 0) {
        for (diags) |d| {
            std.debug.print("意外诊断: [{d}..{d}] {s}\n", .{ d.range.start, d.range.end, d.message });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "审查回归：合法高级语义（解构顶层绑定、this/super委托、多赋值、多级可选链、求幂、泛型运算符、枚举重载与别名）无误报" {
    const gpa = std.testing.allocator;
    var db = try Database.init(gpa, .{});
    defer db.deinit();

    const ok_src =
        \\public let (TOP_NUM, TOP_STR) = (42, "ok")
        \\
        \\abstract class AbsBase {
        \\    public var v: Int64
        \\    public init(v: Int64) {
        \\        this.v = v
        \\    }
        \\    public open func compute(x: Int64): Int64 { x }
        \\}
        \\
        \\public class Derived <: AbsBase {
        \\    public init(v: Int64) {
        \\        super(v)
        \\    }
        \\    public init() {
        \\        this(0)
        \\    }
        \\    public override func compute(x: Int64): Int64 { x + 1 }
        \\}
        \\
        \\public struct Box<T> {
        \\    public var val: T
        \\    public init(val: T) {
        \\        this.val = val
        \\    }
        \\    public operator func +(rhs: Box<T>): Int64 { 1 }
        \\    public mut func setVal(v: T): Unit {
        \\        this.val = v
        \\    }
        \\}
        \\
        \\public type IntBox = Box<Int64>
        \\
        \\public enum OverEnum {
        \\    | Tag
        \\    | Tag(Int64)
        \\}
        \\
        \\public class Node {
        \\    public var next: ?Node = None
        \\    public var value: Int64 = 0
        \\}
        \\
        \\public struct CallableObj {
        \\    public operator func ()(x: Int64): String { "ok" }
        \\}
        \\
        \\func takeAny(x: Any): Unit {}
        \\
        \\public func checkAllValid(d: Derived, opt_n: ?Node, oe: OverEnum, opt_i: ?Int64): Int64 {
        \\    let n_check: Int64 = TOP_NUM
        \\    let s_check: String = TOP_STR
        \\
        \\    var a = 1
        \\    var b = 2
        \\    (a, b) = (3, 4)
        \\    (a, _) = (5, 6)
        \\
        \\    let deep_val: ?Int64 = opt_n?.next?.value
        \\    opt_n?.value = 10
        \\
        \\    var p_i64: Int64 = 2 ** 3u64
        \\    p_i64 **= 2u64
        \\    let p_f64: Float64 = 2.0 ** 3 + 2.0 ** 3.0
        \\
        \\    let sum_box: Int64 = IntBox(1) + Box<Int64>(2)
        \\    let b_conv: UInt8 = Byte(65)
        \\
        \\    let va1 = VArray<Int64, $0x4>(item: 0)
        \\    let va2 = VArray<Int64, $1_0>(repeat: 1)
        \\    let va_sz: Int64 = va1.size + va2.size
        \\
        \\    let eq_tup: Bool = (1, "a") == (1, "a")
        \\    let eq_opt: Bool = opt_i == None
        \\    let eq_rng: Bool = (0..10) == (0..10)
        \\
        \\    let fn_ref: (Int64) -> Int64 = d.compute
        \\    let callable = CallableObj()
        \\    let composed: (Int64) -> String = fn_ref ~> callable
        \\    takeAny { 1 }
        \\
        \\    let matched: Int64 = match (oe) {
        \\        case Tag => 0
        \\        case Tag(x) => x
        \\    }
        \\
        \\    let _ = (s_check, deep_val, p_f64, b_conv, eq_tup, eq_opt, eq_rng, composed)
        \\    n_check + a + b + p_i64 + sum_box + va_sz + matched
        \\}
    ;
    const f = try db.addWorkspaceFile("/valid/review_ok.cj", ok_src, .{});
    const diags = try db.allDiagnostics(gpa, f);
    defer gpa.free(diags);
    if (diags.len > 0) {
        for (diags) |d| {
            std.debug.print("审查回归意外诊断: [{d}..{d}] {s}\n", .{ d.range.start, d.range.end, d.message });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "审查回归：规范违例必产诊断且环路诊断不误伤非递归入口" {
    try expectDiagContains(
        \\func badExp(a: Int32, b: Int32) { let c = a ** b }
    , "未找到匹配的二元运算符实现");
    try expectDiagContains(
        \\func badMulti() { var a = 1; var b = 2; (a, b) = 123 }
    , "多赋值右侧表达式必须为元组类型");
    try expectDiagContains(
        \\func badMulti() { var a = 1; var b = 2; (a, b) = (1, 2, 3) }
    , "多赋值左侧与右侧元组元素个数不匹配");
    try expectDiagContains(
        \\func badMulti() { let a = 1; var b = 2; (a, b) = (3, 4) }
    , "不能对不可变局部变量或形参赋值");
    try expectDiagContains(
        \\struct ValS { public var x: Int64 = 0 }
        \\func badOptAssign(s: ?ValS) { s?.x = 1 }
    , "值类型的可选链表达式不能作为赋值左值");
    try expectDiagContains(
        \\class C {
        \\    public init() {}
        \\    public func f() { this() }
        \\}
    , "构造器委托调用只能出现在实例构造器内部");
    try expectDiagContains(
        \\struct AddRetStr {
        \\    public operator func +(rhs: Int64): String { "bad" }
        \\}
        \\func badCompAssign() { var v = AddRetStr(); v += 1 }
    , "表达式类型与期望类型不兼容");
    try expectDiagContains(
        \\interface I {}
        \\extend I { public func f(): Unit {} }
    , "该类型不支持 extend 扩展声明");
    try expectDiagContains(
        \\class FinalBase {}
        \\class Sub <: FinalBase {}
    , "不能继承未声明 open 或 abstract 的类");
    try expectDiagContains(
        \\interface I {}
        \\struct S <: I {
        \\    public func f() { let x = super }
        \\}
    , "super 只能在存在父类的 class 声明内部使用");
    try expectDiagContains(
        \\struct S {
        \\    public var x: Int64 = 0
        \\    public func badMut() { this.x = 1 }
        \\}
    , "在 struct 非 mut 方法中不能修改实例字段");
    try expectDiagContains(
        \\struct S { public var x: Int64 = 0 }
        \\func badImmutField() { let s = S(); s.x = 1 }
    , "不能修改不可变值类型的字段");
    try expectDiagContains(
        \\func badTupleSet() { var t = (1, 2); t[0] = 3 }
    , "元组元素不可通过下标修改");
    try expectDiagContains(
        \\func badStringSet() { var s = "ab"; s[0] = 65u8 }
    , "String 字符不可通过下标修改");

    // 非递归入口函数调用互递归函数时，仅环路成员报错，入口函数自身不报错
    const gpa = std.testing.allocator;
    var db = try Database.init(gpa, .{});
    defer db.deinit();
    const cyc_src =
        \\func entry() { cycA() }
        \\func cycA() { cycB() }
        \\func cycB() { cycA() }
    ;
    const f_cyc = try db.addWorkspaceFile("/cyc/entry.cj", cyc_src, .{});
    const diags = try db.allDiagnostics(gpa, f_cyc);
    defer gpa.free(diags);
    const entry_end = std.mem.indexOf(u8, cyc_src, "\nfunc cycA").?;
    var cyc_diag_count: usize = 0;
    for (diags) |d| {
        if (std.mem.indexOf(u8, d.message, "递归函数无法推导返回类型") != null) {
            try std.testing.expect(d.range.start >= entry_end);
            cyc_diag_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), cyc_diag_count);
}
