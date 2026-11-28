# `analysis` 公共 API 说明

`analysis` 是面向仓颉语言的按需语义分析与增量查询数据库子包，纯内存无宿主磁盘 I/O 依赖，支持本地执行与 `wasm32-freestanding` 目标。

## 目录结构

- `analysis/build.zig` 与 `analysis/build.zig.zon`：子包构建脚本与依赖声明
- `analysis/src/root.zig`：模块入口与核心类型重导出
- `analysis/src/ids.zig`：全局驻留句柄、包/定义/作用域/类型句柄、可见性与访问域
- `analysis/src/interner/`
  - `StringInterner.zig`：字符串驻留池与包/模块树驻留池
  - `TypeInterner.zig`：全局去重类型池（含基础类型、`VArray`、`CPointer` 文档注释槽位）
- `analysis/src/db/`
  - `FileState.zig`：`PlatformError`、`FileDeclFingerprint`、文档注释提取与 `FileQueryState` 三级内存池
  - `PackageState.zig`：`PackageState`、`DefOrigin`、`DefEntry`、`NominalHeader`、`TypeAliasHeader`、`CallableHeaderSig`
  - `PreloadIndex.zig`：`PackageIndexProvider` 预编译索引接入协议与内置 `std.core` 引导
  - `Database.zig`：`Database` 增量编排、两级失效、三色推导缓存与聚合查询入口
- `analysis/src/resolve/`
  - `access.zig`：包/成员/扩展访问权限检查与公开签名低可见性暴露检查
  - `scope.zig`：九级词法作用域树、`VisibleExtendIndex` 与 `FileResolveData`
  - `package.zig`：`buildPackageState`（包级声明汇聚、重导出、循环拦截与声明头构建）
  - `file.zig`：`resolveFile`（作用域树、显式类型消解与有序早绑定段级定位表）
- `analysis/src/typeck/`
  - `literal.zig`：数值字面量范围校验与具体类型优先级比较
  - `subtype.zig`：`isSubtype`、`isTypeEqual`、`Option` 自动装箱、`promote` 与 `downgrade`
  - `join_meet.zig`：`computeJoin`（LUB）与 `computeMeet`（GLB）
  - `solver.zig`：支持嵌套类型变量 `SolverTyId` 的局部约束求解器 `LocalSolver`
  - `lambda.zig`：Lambda 双向推导与 `unsolvedAsQuest`
  - `builtin_expr.zig`：数组字面量、`??`、`Range`、`for-in`、字符串插值、`try`、`spawn`、`synchronized`
  - `overload.zig`：分级重载决议与无限定枚举构造器过滤
  - `checker.zig`：`ItemChecker` 与 `typeCheckItem` 项级双向检查与晚绑定
- `analysis/src/view/`
  - `SyntaxNode.zig`：只读语法树节点视图
  - `SymbolView.zig`：`SymbolView`、`TypeView`（含文档注释）、`ParamView`、`FnSigView`
  - `ScopeView.zig`：只读作用域视图与可见符号枚举
  - `Queries.zig`：`symbolAt`、`references`、`completionsAt`、`allDiagnostics`

## 内存所有权约定

1. 全局驻留池（`StringInterner`、`PackageInterner`、`TypeInterner`）中的字符串与类型数据仅在 `Database.deinit()` 或 `Database.gcTypes()` 时回收，外部只读切片在数据库有效期内稳定。
2. `PackageState` 内部所有声明头、导出表与文档注释句柄分配于 `PackageState.arena`，包结构发生变更或调用 `gcTypes()` 时整包销毁并递增 `DefId.pkg_gen`。
3. `FileQueryState` 持有三个独立单文件内存池：`ast_hir_arena`、`sema_arena`、`view_arena`。`Database.updateFile` 在源码实际变更时重置单文件内存池，消费端不得跨 `updateFile` 持有借用视图。
4. 显式传入 `alloc` 的聚合查询（`references`、`completionsAt`、`allDiagnostics`、`ScopeView.collectVisibleSymbols`）返回的外层切片由调用者使用传入的 `alloc` 释放，元素内部文本与诊断消息借用自对应阶段内存池。
