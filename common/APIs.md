# `common` 外部 API

入口模块为 `common`（对应 `common/src/root.zig`），对外导出通用基础类型、词法与 CST 标签、语法错误与解析事件、内置注解名称、源文件管理、诊断结构、UTF-8 解码能力、语法树结构及高层中间表示。

## 模块导出

- `common.common`：通用字节区间。
- `common.token`：词法单元、词法标签与标签分类。
- `common.syntax`：Lossless CST 节点标签与转换函数。
- `common.parse_error`：语法错误码、语法错误及其到诊断的转换。
- `common.event`：语法解析事件流协议。
- `common.annotation`：仓颉内置注解名称表。
- `common.source`：源文件管理、编辑与行列索引。
- `common.diagnostic`：统一诊断数据结构。
- `common.utf8`：UTF-8 解码与 Unicode 码点判定。
- `common.tree`：不可变语法树结构。
- `common.hir`：高层中间表示（HIR）数据结构与运算符映射。

---

## 语法树（`common.tree`）

### `GreenNode`

```zig
pub const GreenNode = struct {
    kind: SyntaxKind,
    text_len: u32,
    payload: Payload,

    pub const Payload = union(enum) {
        leaf: []const u8,
        tree: []const *const GreenNode,
    };
};
```

表示单个不可变语法节点，构造完成后只读。构造时由传入的 `arena` 分配叶子文本副本与子节点指针数组，调用方通过释放 `arena` 统一回收。顶层可通过 `common.GreenNode` 访问。

提供以下 `inline` 方法（返回的指针与切片均借用自所属 `arena`，调用者不得单独释放）：
- `isLeaf(self: *const GreenNode) bool`
- `childCount(self: *const GreenNode) usize`（叶子返回 `0`）
- `childAt(self: *const GreenNode, index: usize) ?*const GreenNode`
- `children(self: *const GreenNode) []const *const GreenNode`（叶子返回 `&.{}`）
- `tokenText(self: *const GreenNode) ?[]const u8`
- `childOfKind(self: *const GreenNode, kind: SyntaxKind) ?*const GreenNode`

### `LocatedGreen`

```zig
pub const LocatedGreen = struct {
    green: *const GreenNode,
    start: u32,
};
```

携带绝对起始字节位置的绿树节点定位结果。顶层可通过 `common.LocatedGreen` 访问。

### `GreenTree`

```zig
pub const GreenTree = struct {
    root: *const GreenNode,
};
```

对根 `GreenNode` 节点的封装。顶层可通过 `common.GreenTree` 访问。

- `pub inline fn textLen(self: GreenTree) u32`：返回整棵树覆盖的文本长度。
- `pub fn nodeAt(self: GreenTree, offset: u32) ?LocatedGreen`：定位包含给定字节位置的叶子节点及其绝对起始位置，返回结果中的 `green` 指针借用自所属 `arena`。
- `pub inline fn traversal(self: GreenTree, gpa: std.mem.Allocator) GreenTraversal`：创建前向遍历当前绿树的迭代器，结束后须调用 `GreenTraversal.deinit` 释放。

### `SyntaxTree`

```zig
pub const SyntaxTree = struct {
    file: FileId,
    version: u32,
    tree: GreenTree,
};
```

语法树的进一步包装，持有 `FileId` 和文件版本号以判定是否过期。顶层可通过 `common.SyntaxTree` 访问。

- `pub inline fn isOutdated(self: SyntaxTree, file: FileId, current_version: u32) bool`：文件标识或版本号任一不匹配即判定树已过期。
- `pub inline fn textLen(self: SyntaxTree) u32`：转发 `GreenTree.textLen`。
- `pub inline fn nodeAt(self: SyntaxTree, offset: u32) ?LocatedGreen`：转发 `GreenTree.nodeAt`。

### `QueryContext`

单次语法树查询会话的红节点分配与去重上下文，基于外部传入的 `gpa` 自持有 `arena` 与 `(green, offset)` 去重缓存。顶层可通过 `common.QueryContext` 访问。

- `pub fn init(gpa: std.mem.Allocator) QueryContext`：初始化查询上下文。
- `pub fn deinit(self: *QueryContext) void`：释放去重缓存与内部 `arena` 中的全部红节点数据。
- `pub inline fn allocator(self: *QueryContext) std.mem.Allocator`：获取内部 `arena` 分配器。
- `pub fn allocRed(self: *QueryContext, green: *const GreenNode, parent: ?*const RedNode, offset: u32) std.mem.Allocator.Error!*const RedNode`：在内部 `arena` 中按 `(green, offset)` 分配或复用 `RedNode`；同一 `QueryContext` 内相同的 `(green, offset)` 必然返回同一指针。返回的指针随 `deinit` 统一回收，调用者不得单独释放。

### `RedNode`

```zig
pub const RedNode = struct {
    green: *const GreenNode,
    parent_node: ?*const RedNode,
    text_offset: u32,
};
```

绑定了父节点指针与绝对文件字节位置的语法树视图节点，由 `QueryContext` 托管生命周期（预期短于底层 `GreenNode`）。顶层可通过 `common.RedNode` 访问。

提供以下方法（返回的节点指针与切片均借用自对应的 `QueryContext` 或绿树 `arena`，调用者不得单独释放）：
- `pub inline fn kind(self: *const RedNode) SyntaxKind`
- `pub inline fn textLen(self: *const RedNode) u32`
- `pub inline fn offset(self: *const RedNode) u32`
- `pub inline fn range(self: *const RedNode) TextRange`
- `pub inline fn parent(self: *const RedNode) ?*const RedNode`
- `pub inline fn isLeaf(self: *const RedNode) bool`
- `pub inline fn tokenText(self: *const RedNode) ?[]const u8`
- `pub inline fn childCount(self: *const RedNode) usize`
- `pub fn childAt(self: *const RedNode, ctx: *QueryContext, index: usize) std.mem.Allocator.Error!?*const RedNode`
- `pub fn children(self: *const RedNode, ctx: *QueryContext) std.mem.Allocator.Error![]const *const RedNode`
- `pub fn findTokenAt(self: *const RedNode, ctx: *QueryContext, target_offset: u32) std.mem.Allocator.Error!?*const RedNode`
- `pub inline fn ancestors(self: *const RedNode) AncestorIter`

### `AncestorIter`

沿父节点链向上遍历 `RedNode` 的迭代器，从起始节点自身开始直至根节点。顶层可通过 `common.AncestorIter` 访问。

- `pub inline fn next(self: *AncestorIter) ?*const RedNode`：返回当前红节点并推进至父节点；越过根节点后返回 `null`。

### `GreenTraversal`

对 `GreenTree` 执行非递归深度优先前向遍历的迭代器，无需分配 `RedNode`，事件类型为 `GreenTraversal.Event = union(enum) { enter: LocatedGreen, leave: LocatedGreen }`。顶层可通过 `common.GreenTraversal` 访问。

- `pub inline fn init(gpa: std.mem.Allocator, tree: GreenTree) GreenTraversal`：从绿树根节点初始化遍历器。
- `pub fn initFromNode(gpa: std.mem.Allocator, node: *const GreenNode, start_offset: u32) GreenTraversal`：从指定节点与起始字节位置初始化遍历器。
- `pub fn deinit(self: *GreenTraversal) void`：释放遍历器内部的临时缓冲。
- `pub fn next(self: *GreenTraversal) std.mem.Allocator.Error!?Event`：产出下一个 `.enter` 或 `.leave` 事件，结束时返回 `null`。
- `pub fn skipChildren(self: *GreenTraversal) void`：跳过当前活动帧的剩余子节点（`.enter` 后调用跳过当前节点的子节点，`.leave` 后调用跳过其父节点的剩余子节点，未进入或结束后调用无效果）。

---

## 通用定义（`common.common`）

### `Span`

```zig
pub const Span = struct {
    start: u32,
    end: u32,
};
```

源文件中的左闭右开字节区间，起止值相对于所属文件开头。顶层可通过 `common.Span` 访问。

---

## 词法单元（`common.token`）

### `TokenTag`

```zig
pub const TokenTag = enum { ... };
```

词法分析阶段产出的词法单元标签枚举（涵盖运算符、分隔符、关键字、标识符、字面量、`comment`、`nl`、`end`、`sentinel`、`illegal`）。顶层可通过 `common.TokenTag` 访问。

标签上提供以下只读判定方法：

| 方法 | 说明 |
| :--- | :--- |
| `pub inline fn isContextKeyword(self: TokenTag) bool` | 是否为上下文关键字（`public`、`open` 等可在标识符位置复用的关键字）。 |
| `pub inline fn isIdentLike(self: TokenTag) bool` | 是否可作为标识符使用（普通标识符与上下文关键字）。 |
| `pub inline fn isPackageIdentLike(self: TokenTag) bool` | 是否可作为包名段使用（标识符、上下文关键字与反引号包名）。 |
| `pub inline fn isPrimitiveType(self: TokenTag) bool` | 是否为内建基础类型关键字（不含 `This` 与 `VArray`）。 |
| `pub inline fn isNumericOrRuneType(self: TokenTag) bool` | 是否为数值或字符类型转换关键字（`Int8`..`Float64` 及 `Rune`）。 |

### `Token`

```zig
pub const Token = struct {
    tag: TokenTag,
    span: Span,
};
```

单个词法单元，只承载标签与在源码中的字节区间，不持有堆内存。顶层可通过 `common.Token` 访问。

---

## CST 标签（`common.syntax`）

### `SyntaxKind`

```zig
pub const SyntaxKind = enum { ... };
```

Lossless CST 全部叶子与内部节点标签，包含：

- 空白、换行与三类注释：`whitespace`、`newline`、`line_comment`、`block_comment`、`doc_comment`、`eof`、`illegal`。
- 标识符、字面量、运算符、分隔符与关键字（含语法期组合标签 `coalescing`、`rshift`、`rshift_assign`、`greater_equal` 与插值文本片段 `string_content`）。
- 源文件、特性、包、导入、注解、声明、声明体、语句块、泛型、参数、路径、类型、模式、表达式、语句、宏/quote 原始片段与 `error_node`。`error_node` 覆盖无法按语法解析的词法单元，以及出现在非法位置的声明；后者的内部节点是正常解析得到的声明节点。

顶层可通过 `common.SyntaxKind` 访问。

### `toSyntaxKind`

```zig
pub fn toSyntaxKind(token_tag: TokenTag) ?SyntaxKind
```

将 `TokenTag` 转换为对应的 `SyntaxKind`：`.nl` 转为 `.newline`，`.end` 转为 `.eof`，`.comment` 与 `.sentinel` 返回 `null`，其余标签按同名成员转换。顶层可通过 `common.toSyntaxKind` 访问。

### `classifyComment`

```zig
pub fn classifyComment(text: []const u8) SyntaxKind
```

按注释源码文本区分 `.line_comment`、`.block_comment` 与 `.doc_comment`：`///...`（不含 `////...`）与 `/**...*/`（不含 `/**/` 与 `/***...`）为文档注释。顶层可通过 `common.classifyComment` 访问。

### `tokenToSyntaxKind`

```zig
pub fn tokenToSyntaxKind(tag: TokenTag, text: []const u8) SyntaxKind
```

把词法单元标签与其源码文本转换为 CST 叶子标签；注释按文本细分，`sentinel` 映射为 `.illegal`。顶层可通过 `common.tokenToSyntaxKind` 访问。

---

## 语法错误（`common.parse_error`）

### `ParseErrorCode`

```zig
pub const ParseErrorCode = enum(u8) {
    expected_expression,
    expected_token,
    expected_item,
    non_associative_comparison,
    recursive_depth_limit,
    invalid_literal,
    expected_type,
    expected_pattern,
    expected_identifier,
    expected_block,
    non_associative_assignment,
    non_associative_operator,
    invalid_assignment_target,
    unclosed_delimiter,
    illegal_token,
    unexpected_token,
    invalid_interpolation,
    dangling_doc_comment,
    invalid_declaration_position,
};
```

语法分析阶段可遇到的错误码。`invalid_declaration_position` 表示声明类别或修饰符与所在作用域不相容：parser 记录该错误码，并把正常解析得到的声明节点包在 `error_node` 内。顶层可通过 `common.ParseErrorCode` 访问。

### `ParseError`

```zig
pub const ParseError = struct {
    code: ParseErrorCode,
    range: TextRange,

    pub inline fn toDiagnostic(
        self: ParseError,
        allocator: std.mem.Allocator,
        file: FileId,
        source: []const u8,
    ) std.mem.Allocator.Error!Diagnostic
};
```

语法分析错误，携带错误码与源码字节区间；`toDiagnostic` 为 `parseErrorToDiagnostic` 的便捷转发方法。顶层可通过 `common.ParseError` 访问。

### `parseErrorToDiagnostic`

```zig
pub fn parseErrorToDiagnostic(
    allocator: std.mem.Allocator,
    file: FileId,
    source: []const u8,
    err: ParseError,
) std.mem.Allocator.Error!Diagnostic
```

将单个 `ParseError` 转换为平台统一的 `Diagnostic`（`severity = .err`、`source = .parser`、`related = &.{}`）。

内存所有权与零分配约定：

- 编译期可完全确定的错误码（`recursive_depth_limit`、`non_associative_comparison`、`non_associative_assignment`、`non_associative_operator`、`invalid_assignment_target`、`unclosed_delimiter`、`invalid_interpolation`、`dangling_doc_comment`）以及 `err.range` 无有效可展示源码片段时，`Diagnostic.message` 直接返回编译期静态字符串切片，不调用 `allocator`，调用方不可对其单独调用 `free`。
- 其余需要拼入源码片段的错误码在 `err.range` 有效且非空时，按合法 UTF-8 码点边界安全截断片段（最多 32 字节）并通过 `allocator` 格式化分配 `Diagnostic.message`。
- `source` 仅作只读借用；推荐使用 `std.heap.ArenaAllocator` 统一托管整批诊断消息的生命周期。

---

## 解析事件（`common.event`）

### `TokenEvent` 与 `Event`

```zig
pub const TokenEvent = struct {
    kind: SyntaxKind,
    range: TextRange,
};

pub const Event = union(enum) {
    /// 标识语法节点开始。
    start_node: SyntaxKind,
    /// 将当前父节点已完成子节点列表的最后一项包裹进新节点，成为其首个子节点。
    wrap_node: SyntaxKind,
    /// 发射叶子词法单元（含合成的 `whitespace`、细分的注释、`newline`、组合运算符与插值片段）。
    token: TokenEvent,
    /// 标识当前语法节点结束。
    finish_node: void,
    /// 记录语法诊断，不破坏节点开闭平衡。
    parse_error: ParseError,
};
```

`start_node` 与 `wrap_node` 的总发射次数与 `finish_node` 严格相等；位置信息仅由 `token` 与 `parse_error` 携带。顶层可通过 `common.Event`、`common.TokenEvent` 访问。

---

## 内置注解（`common.annotation`）

### `isBuiltinAnnotationName`

```zig
pub inline fn isBuiltinAnnotationName(name: []const u8) bool
```

判定给定标识符文本是否为仓颉内置注解名称（`When`、`Deprecated`、`C` 等，与参考编译器及 `cangjie_spec` 一致）。顶层可通过 `common.isBuiltinAnnotationName` 访问。

---

## 源文件管理（`common.source`）

### 常量与错误集合

- `common.source.max_file_bytes: usize = 64 * 1024 * 1024`：从磁盘读取单文件的字节上限。
- `common.source.Error`：

```zig
pub const Error = std.mem.Allocator.Error || error{
    InvalidFileId,
    ReadOnlyFile,
    InvalidRange,
    OverlappingEdits,
    InvalidPosition,
    InvalidLine,
    PathAlreadyRegistered,
    InvalidPath,
    TooLarge,
};
```

### `FileId`

```zig
pub const FileId = struct {
    index: u32,
    generation: u32,

    pub const invalid: FileId = .{ .index = std.math.maxInt(u32), .generation = 0 };

    pub inline fn eql(a: FileId, b: FileId) bool
};

pub inline fn isOutdated(target: FileId, version: u32, current: FileId, current_version: u32) bool;
```

带代次校验的 8 字节文件句柄。文件删除并复用槽位后旧句柄自动失效。`FileId.eql` 判定两个句柄是否指向同一槽位且代次相同；模块级 `isOutdated` 判定给定文件与版本号相对于当前文件与版本号是否过期，供 `common.SyntaxTree` 与 `common.HirFile` 复用。顶层可通过 `common.FileId` 访问。

### `TextRange` 与 `Edit`

```zig
pub const TextRange = struct {
    start: u32,
    end: u32,

    pub const zero: TextRange = .{ .start = 0, .end = 0 };

    pub fn len(self: TextRange) u32
    pub fn isEmpty(self: TextRange) bool
    pub fn contains(self: TextRange, offset: u32) bool
};

pub const Edit = struct {
    range: TextRange,
    new_text: []const u8,
};
```

- `TextRange` 为左闭右开字节区间，`start == end` 表示空插入位置。
- `Edit` 描述以应用编辑前文本为基准的单次替换，`new_text` 不得指向被编辑文件的内容缓冲。
- 顶层可通过 `common.TextRange`、`common.Edit` 访问。

### `Position` 与 `LineIndex`

```zig
pub const Position = struct {
    line: u32,
    column: u32,
};
```

行号从 `0` 开始，列号以字节计。顶层可通过 `common.Position`、`common.LineIndex` 访问。

`LineIndex` 公开方法：

| 签名 | 说明 |
| :--- | :--- |
| `pub fn deinit(self: *LineIndex, gpa: std.mem.Allocator) void` | 释放行首缓存内存。 |
| `pub fn invalidate(self: *LineIndex, from: u32) void` | 丢弃 `from` 位置及之后的行首缓存。 |
| `pub fn lineCount(self: *LineIndex, gpa: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!u32` | 返回总行数（空文本为 1）。 |
| `pub fn lineOf(self: *LineIndex, gpa: std.mem.Allocator, text: []const u8, offset: u32) !u32` | 查询字节位置所在行号，越界返回 `error.InvalidPosition`。 |
| `pub fn lineRange(self: *LineIndex, gpa: std.mem.Allocator, text: []const u8, line: u32) !TextRange` | 返回含末尾换行符的半开行区间，越界返回 `error.InvalidLine`。 |
| `pub fn positionOf(self: *LineIndex, gpa: std.mem.Allocator, text: []const u8, offset: u32) !Position` | 字节位置转行列。 |
| `pub fn offsetOf(self: *LineIndex, gpa: std.mem.Allocator, text: []const u8, pos: Position) !u32` | 行列转字节位置。 |

### 文件元信息与 `File`

- `FileKind = enum { workspace, external }`：标识文件是否可编辑。
- `FileType = enum { Source, Header }`：标识源码文件或索引文件。
- `PackageNameConstraint`：`{ org: ?[]const u8 = null, root_package: []const u8, sub_package: ?[][]const u8 = null }`，提供 `clone(gpa)` 与 `deinit(gpa)`。
- `FileExtraInfo`：`{ requirePackageName: ?PackageNameConstraint = null, features: std.StringHashMapUnmanaged(bool) = .empty, typ: FileType = .Source }`，提供 `clone(gpa)` 与 `deinit(gpa)`。
- `File`：由 `Source` 独占持有，公开字段含 `kind`、`path`、`extra`、`version`、`line_index`、`arena` 与 `contract_arena`。两个内存池都是 `std.heap.ArenaAllocator`，创建文件时建立，随文件的删除或 `Source.deinit` 整体释放，编辑不会清空。

| 签名 | 说明 |
| :--- | :--- |
| `pub fn content(self: *const File) []const u8` | 当前文本切片，在下次编辑前有效。 |
| `pub fn allocator(self: *File) std.mem.Allocator` | 从 `arena` 分配，供文件内部使用；分配的内容随文件释放。返回的分配器句柄持有指向当前 `File` 的指针，`Source` 新建文件导致槽位数组重新分配后失效，继续分配须重新从 `Source.get` 获取。 |
| `pub fn contractAlloc(self: *File, comptime T: type, n: usize) std.mem.Allocator.Error![]T` | 从 `contract_arena` 申请一次填充的空间，填充完成后只作为只读数据使用。 |
| `pub fn contractDupe(self: *File, comptime T: type, values: []const T) std.mem.Allocator.Error![]const T` | 把已有数据复制进 `contract_arena` 并返回只读切片。 |

顶层可通过 `common.File`、`common.FileKind`、`common.FileType`、`common.FileExtraInfo`、`common.PackageNameConstraint` 访问。

### `Source`

全局源文件管理器（顶层可通过 `common.Source` 访问，`common.source.t` 为其别名）。创建文件时深拷贝文本与 `FileExtraInfo`，调用方传入的数据在调用返回后可立即释放；通过 `get` 与 `content` 取得的指针或切片均借用自 `Source`，不可由调用方释放。

| 签名 | 说明 |
| :--- | :--- |
| `pub fn init(gpa: std.mem.Allocator) Source` | 初始化空源文件管理器。 |
| `pub fn deinit(self: *Source) void` | 释放所有文件与内部容器内存。 |
| `pub fn get(self: *Source, id: FileId) ?*File` | 按句柄查文件指针；下标越界、代次不符或已删除时返回 `null`。 |
| `pub fn find(self: *const Source, path: []const u8) ?FileId` | 按规范化绝对路径查文件句柄。 |
| `pub fn count(self: *const Source) usize` | 返回当前存活文件数。 |
| `pub fn iterator(self: *Source) Iterator` | 返回跳过空槽位的存活文件迭代器（`Iterator.next()` 返回 `?Item{ .id, .file }`）；迭代期间不得增删文件。 |
| `pub fn addWorkspace(self: *Source, path: ?[]const u8, text: []const u8, extra: FileExtraInfo) Error!FileId` | 创建可编辑工作区文件；`path` 非空时须为未登记的绝对路径。 |
| `pub fn addExternal(self: *Source, path: []const u8, text: []const u8, extra: FileExtraInfo) Error!FileId` | 创建只读外部文件。 |
| `pub fn loadExternal(self: *Source, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, extra: FileExtraInfo) !FileId` | 规范化路径并从磁盘载入外部文件；同一路径已登记时幂等返回既有 `FileId`。 |
| `pub fn remove(self: *Source, id: FileId) Error!void` | 删除文件并递增槽位代次，不触碰磁盘。 |
| `pub fn content(self: *Source, id: FileId) Error![]const u8` | 获取文件当前文本切片（下次 `applyEdits` 前有效）。 |
| `pub fn openForEdit(self: *Source, id: FileId) Error!void` | 将外部文件切换为可编辑工作区文件。 |
| `pub fn freeze(self: *Source, id: FileId) Error!void` | 将工作区文件冻结为只读外部文件。 |
| `pub fn applyEdit(self: *Source, id: FileId, edit: Edit) Error!void` | 应用单条内存编辑。 |
| `pub fn applyEdits(self: *Source, id: FileId, edits: []const Edit) Error!void` | 批量应用按 `start` 升序且不重叠的编辑（失败时原子回滚），成功后递增 `version` 并使受影响行索引失效。 |
| `pub fn lineCount(self: *Source, id: FileId) Error!u32` | 查询文件总行数。 |
| `pub fn lineOf(self: *Source, id: FileId, offset: u32) Error!u32` | 查询字节位置所在行号。 |
| `pub fn positionOf(self: *Source, id: FileId, offset: u32) Error!Position` | 查询字节位置对应的行列。 |
| `pub fn offsetOf(self: *Source, id: FileId, pos: Position) Error!u32` | 查询行列对应的字节位置。 |
| `pub fn lineRange(self: *Source, id: FileId, line: u32) Error!TextRange` | 查询指定行的半开字节区间。 |

---

## 诊断数据结构（`common.diagnostic`）

### `Severity`

```zig
pub const Severity = enum(u8) {
    err = 0,
    warning = 1,
    info = 2,
    hint = 3,
};
```

诊断严重级别，按数值升序排列（`err` 最先）。顶层可通过 `common.Severity` 访问。

### `Source`（顶层别名 `common.DiagnosticSource`）

```zig
pub const Source = union(enum) {
    lexer,
    parser,
    name_res,
    typeck,
    linter: []const u8, // 静态规则名切片，生命周期同程序

    pub inline fn eql(a: Source, b: Source) bool
};
```

诊断来源阶段或 Linter 规则名。模块内通过 `common.diagnostic.Source` 访问，顶层通过 `common.DiagnosticSource` 访问。

### `RelatedInfo`

```zig
pub const RelatedInfo = struct {
    range: TextRange,
    message: []const u8,
};
```

诊断附带的关联区间与说明。顶层可通过 `common.RelatedInfo` 访问。

### `Diagnostic`

```zig
pub const Diagnostic = struct {
    file: FileId,
    range: TextRange,
    severity: Severity,
    source: Source,
    message: []const u8,
    related: []const RelatedInfo = &.{},

    pub fn order(a: Diagnostic, b: Diagnostic) std.math.Order
    pub fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool
};
```

平台统一诊断结构。`Diagnostic` 本身不绑定单一内存来源，`message` 与 `related` 可来自编译期静态字符串、Arena 托管或外部借用，具体释放约定由各构造方文档说明。顶层可通过 `common.Diagnostic` 访问。

---

## UTF-8 工具（`common.utf8`）

### `Codepoint`

```zig
pub const Codepoint = struct {
    value: u21,
    len: u3,
};
```

解码得到的单个 Unicode 码点与其 UTF-8 字节长度。顶层可通过 `common.Codepoint` 访问。

### 函数

| 签名 | 说明 |
| :--- | :--- |
| `pub fn isSurrogate(cp: u21) bool` | 判断码点是否位于 UTF-16 代理项区间（`U+D800..=U+DFFF`）。 |
| `pub fn decode(bytes: []const u8) ?Codepoint` | 从切片开头解码单个合法 UTF-8 码点，空切片、非法字节或截断序列返回 `null`。 |
| `pub fn decodeAt(bytes: []const u8, index: usize) ?Codepoint` | 从切片 `index` 处解码单个合法 UTF-8 码点，越界或非法返回 `null`。 |

---

## 高层中间表示（`common.hir`）

由 `GreenTree` 经由 lower 阶段生成，去除源码中的空白、注释与纯语法标点，保留语义分析、名称解析、类型检查与静态检查所需的抽象语法结构。顶层可通过 `common.hir` 访问模块，各节点类型同时以 `common.` 前缀直接导出。

### 约定

- 命名约定：`Hir` 前缀用于跨声明项共用的节点类型（`HirType`、`HirExpr`、`HirStmt`、`HirPattern`、`HirItem`、`HirCondition`、`HirParam`、`HirCallArg`、`HirTypeElement`、`HirFile`），其余载荷结构体、字面量与运算符枚举按语言术语命名。
- 每个节点都带 `range: TextRange`（左闭右开字节区间）。名字位置另带 `Name` 中的独立区间，便于把诊断定位到具体标识符。
- 每个 parser 产生的 CST 标签都在测试 `每个 CST 标签都有 HIR 对应或明确的折叠规则` 中登记为 trivia、lexeme、value、wrapper、node 或 error_node；`SyntaxKind` 新增标签会让该测试编译失败，迫使补齐对应关系。
- 括号表达式与括号类型在 HIR 中折叠，`range` 取内层表达式或内层类型的区间。
- 所有节点、切片与子指针由所属 `arena` 分配（如 `File.allocator()`），随 `arena` 统一释放，调用者不得单独释放其中任何指针或切片。
- 列表字段与可选字段按声明是否带默认值区分：带默认值的列表为 `&.{}`，可选字段为 `null`；没有默认值的字段构造时必须显式给出。绑定类别、运算符、目标类型、字符串书写形式、字节字面量标记与名字的原始形式标记没有默认值，漏填会在编译期报错。
- `HirExpr`、`HirType`、`HirPattern`、`HirItem`、`HirStmt`、`Param`、`EnumVariant`、`BlockExpr`、`PropAccessor`、`Resource` 的全部载荷结构体均携带 `id: HirId = .fromIndex(0)` 字段，并提供 `id(self: *const T) HirId` 与 `range(self: *const T) TextRange` 方法，统一取得项内 `HirId` 与节点覆盖区间，指针仅作只读借用。

### 句柄、节点视图与 CST→HIR 映射（`ItemId`、`HirId`、`HirKey`、`HirNode`、`GreenToHirMap`）

```zig
pub const ItemId = enum(u32) {
    _,
    pub inline fn fromIndex(idx: u32) ItemId
    pub inline fn index(self: ItemId) u32
};

pub const HirId = enum(u32) {
    _,
    pub inline fn fromIndex(idx: u32) HirId
    pub inline fn index(self: HirId) u32
};

pub const HirKey = struct {
    item: ItemId,
    hir: HirId,
    pub inline fn eql(a: HirKey, b: HirKey) bool
};

pub const HirNode = union(enum) {
    item: *const HirItem,
    stmt: *const HirStmt,
    expr: *const HirExpr,
    block: *const BlockExpr,
    pattern: *const HirPattern,
    ty: *const HirType,
    param: *const Param,
    variant: *const EnumVariant,
    prop_accessor: *const PropAccessor,
    resource: *const Resource,

    pub inline fn range(self: HirNode) TextRange
    pub inline fn id(self: HirNode) HirId
};

pub const GreenToHirMap = struct {
    by_green: std.AutoHashMapUnmanaged(usize, HirKey) = .empty,
    pub const empty: GreenToHirMap = .{};

    pub fn deinit(self: *GreenToHirMap, allocator: std.mem.Allocator) void
    pub inline fn clearRetainingCapacity(self: *GreenToHirMap) void
    pub inline fn count(self: *const GreenToHirMap) usize
    pub fn put(
        self: *GreenToHirMap,
        allocator: std.mem.Allocator,
        green: *const GreenNode,
        item: ItemId,
        hir: HirId,
    ) std.mem.Allocator.Error!void
    pub inline fn get(self: *const GreenToHirMap, green: *const GreenNode) ?HirKey
    pub fn resolveNearest(self: *const GreenToHirMap, red: *const RedNode) ?HirKey
    pub fn resolveNearestGreen(
        self: *const GreenToHirMap,
        root: *const GreenNode,
        target: *const GreenNode,
    ) ?HirKey
    pub fn resolveNearestAtOffset(
        self: *const GreenToHirMap,
        root: *const GreenNode,
        root_offset: u32,
        offset: u32,
    ) ?HirKey
};
```

- `ItemId` 与 `HirId` 采用 4 字节强类型枚举句柄。每个顶层声明项内部的 `HirId` 从 `0` 独立顺序分配，使某项内部的修改不会导致同文件其他顶层项的 `HirId` 漂移。
- `HirKey` 为 `(ItemId, HirId)` 复合定位键，可在文件范围内无歧义定位任意 HIR 节点。
- `HirNode` 统一包装所有可由 `GreenToHirMap` 寻址的 HIR 节点类别（含独立语句块 `BlockExpr`、形参 `Param`、枚举构造器 `EnumVariant`、属性访问器 `PropAccessor` 与 `try` 资源声明 `Resource`），其内部指针均借用自所属 `arena`。
- `GreenToHirMap` 以 `@intFromPtr(green)` 为键保存 `*const GreenNode -> HirKey` 映射：
  - `put` 在 `allocator`（通常为文件级 `arena`）中分配哈希桶，若 `allocator` 为 `ArenaAllocator` 则无需单独调用 `deinit`。
  - `resolveNearest` 从给定 `RedNode` 沿父链上溯查找最近具有 HIR 映射的节点；`resolveNearestGreen` 与 `resolveNearestAtOffset` 无需构造 `RedNode`，直接基于 `GreenNode` 子树或目标字节位置完成零分配上溯查询（当光标位于关键字、标点或空白/注释 Trivia 上时自动回退到最近的语义父节点）。
- 顶层可通过 `common.ItemId`、`common.HirId`、`common.HirKey`、`common.HirNode`、`common.GreenToHirMap` 访问。

### 名字、修饰符与注解

```zig
pub const Name = struct {
    text: []const u8,                   // 已去掉包围原始标识符与包名的反引号
    is_raw: bool,                       // 是否由反引号包围
    range: TextRange,
};

pub const Modifier = enum(u8) {
    public, private, protected, internal,
    static, open, sealed, abstract, override, redef,
    unsafe, mut, operator, const_, common, specific, late,
};

pub const Annotation = struct {
    path: []const Name,
    args: []const HirCallArg = &.{},
    range: TextRange,
};
```

`Modifier.const_` 表示 `const func` 与 `const init` 上的上下文关键字；绑定类别使用 `BindingKind`（`let_`、`var_`、`const_`）。`Name.text` 保留去掉反引号的文本，`Name.is_raw` 记录反引号包围的原始形式，因此关键字与同名原始标识符可以区分。

### 运算符

- `BinaryOp`：`add`、`sub`、`mul`、`div`、`mod`、`exp`、`eq`、`ne`、`lt`、`le`、`gt`、`ge`、`logical_and`、`logical_or`、`bit_and`、`bit_or`、`bit_xor`、`lshift`、`rshift`、`coalescing`、`pipeline`、`composition`。
- `AssignOp`：`assign` 与全部复合赋值运算符。
- `UnaryOp`：`neg`（`-`）与 `not`（`!`，逻辑取反与按位取反共用）。
- `IncDecOp`：`incr`、`decr`。
- `JumpOp`：`break_`、`continue_`。
- `IntSuffix`：`i8` 至 `i64`、`u8` 至 `u64`；`FloatSuffix`：`f16`、`f32`、`f64`。

`BinaryOp` 与 `AssignOp` 使用编译期查找表，`UnaryOp`、`IncDecOp`、`JumpOp` 使用 `switch`，均提供 `fromSyntaxKind(kind: SyntaxKind) ?T`，把 CST 运算符或关键字标签转换为 HIR 标签，非对应标签返回 `null`。区间表达式、`is`、`as` 使用独立的表达式变体，不出现在这些映射表中。

### 类型

```zig
pub const HirType = union(enum) {
    path: PathType,
    option: OptionalType,
    tuple: TupleType,
    func: FuncType,
    varray: VArrayType,
    this: ThisType,
};

pub const PathType = struct {
    segments: []const TypePathSegment,   // 每段带 name 与可选 type_args
    range: TextRange,
};

pub const HirTypeElement = struct {
    label: ?Name = null,                 // (x: Int64, y: Int64) 中的 x
    ty: *const HirType,
    range: TextRange,
};

pub const OptionalType = struct { inner: *const HirType, range: TextRange };
pub const TupleType = struct { elements: []const HirTypeElement, range: TextRange };
pub const FuncType = struct {
    params: []const HirTypeElement = &.{},
    ret: *const HirType,
    range: TextRange,
};
pub const VArrayType = struct {
    elem: *const HirType,
    size: []const u8,                   // VArray<T, $4> 中 $4 的文本 4
    range: TextRange,
};
pub const ThisType = struct { range: TextRange };
```

类型实参挂在路径的各个段上，`a<T>.b` 与 `a.b<T>` 均可表达。元组类型与函数类型的元素可带可读性标签，`label` 为 `null` 表示无标签。`path` 同时承载内置类型名（`Int64`、`Bool`、`Unit` 等）。`VArrayType.size` 保存长度字面量的源码文本，不对长度预设数值范围。

### 字面量

```zig
pub const IntLit = struct { text: []const u8, suffix: ?IntSuffix = null, range: TextRange };
pub const FloatLit = struct { text: []const u8, suffix: ?FloatSuffix = null, range: TextRange };
pub const RuneLit = struct { value: u21, is_byte: bool, range: TextRange };
pub const StringLit = struct { text: []const u8, kind: StrKind, range: TextRange };
pub const BoolLit = struct { value: bool, range: TextRange };
pub const Bare = struct { range: TextRange };    // ()、_ 等无载荷节点
```

`StrKind` 区分 `single`、`multiline` 与 `raw_multiline`。负数字面量由外层 `HirExpr.unary` 表达。

整数字面量与浮点数字面量只保存完整源码文本与显式后缀，不保存解析后的数值。字面量在宏实参等非表达式位置可以超出所有数值类型的范围，需要数值的阶段按文本解析并做类型范围检查。

带插值的字符串使用 `StrInterp`：

```zig
pub const StrKind = enum(u8) { single, multiline, raw_multiline };
pub const StrText = struct { text: []const u8, range: TextRange };
pub const StrInterpolation = struct { body: *const BlockExpr, range: TextRange };
pub const StrPart = union(enum) { text: StrText, interpolation: StrInterpolation };
pub const StrInterp = struct {
    parts: []const StrPart,
    kind: StrKind,
    range: TextRange,
};
```

`parts` 按源码顺序交替保存纯文本与插值片段，插值内容是 `.block` 表达式。

### 表达式

```zig
pub const HirExpr = union(enum) {
    int_lit: IntLit,
    float_lit: FloatLit,
    rune_lit: RuneLit,
    string_lit: StringLit,
    str_interp: StrInterp,
    bool_lit: BoolLit,
    unit_lit: Bare,
    wildcard: Bare,
    path: PathExpr,
    field: FieldExpr,
    optional: OptionalExpr,
    call: CallExpr,
    index: IndexExpr,
    inc_dec: IncDecExpr,
    unary: UnaryExpr,
    binary: BinaryExpr,
    assign: AssignExpr,
    range_expr: RangeExpr,
    is_expr: IsExpr,
    as_expr: AsExpr,
    type_conv: TypeConvExpr,
    varray: VArrayExpr,
    tuple_lit: TupleLit,
    array_lit: ArrayLit,
    block: BlockExpr,
    if_expr: IfExpr,
    match_expr: MatchExpr,
    while_expr: WhileExpr,
    do_while_expr: DoWhileExpr,
    for_in_expr: ForInExpr,
    try_expr: TryExpr,
    throw_expr: ThrowExpr,
    return_expr: ReturnExpr,
    jump: JumpExpr,
    lambda: LambdaExpr,
    spawn: SpawnExpr,
    synchronized: SynchronizedExpr,
    unsafe: UnsafeExpr,
    quote: QuoteExpr,
    macro_call: MacroCallExpr,
    if_available: IfAvailableExpr,
    perform: PerformExpr,
    resume_expr: ResumeExpr,
};
```

后缀链与访问：

```zig
pub const ExprPathSegment = struct {
    name: Name,                          // this、super、This 与内置类型名同样作为段名
    type_args: []const HirType = &.{},
};
pub const PathExpr = struct { segments: []const ExprPathSegment, range: TextRange };
pub const FieldExpr = struct {
    base: *const HirExpr,
    name: Name,
    type_args: []const HirType = &.{},
    range: TextRange,
};
pub const OptionalExpr = struct { operand: *const HirExpr, range: TextRange };
pub const HirCallArg = struct {
    name: ?Name = null,                  // 命名实参 name: expr
    is_inout: bool = false,              // C 互操作中的 inout 引用传值
    value: *const HirExpr,
    range: TextRange,
};
pub const CallExpr = struct {
    callee: *const HirExpr,
    args: []const HirCallArg = &.{},
    trailing_lambda: ?*const HirExpr = null,
    range: TextRange,
};
pub const IndexExpr = struct { base: *const HirExpr, indices: []const HirExpr, range: TextRange };
```

`a?.b`、`c?(d)`、`e?[f]` 中的 `?` 统一表示为 `OptionalExpr`，字段访问、调用与下标以它作为接收者，因此可选链的类型信息不会丢失。`arr[1..5]`、`arr[..5]`、`arr[0..]` 使用 `range_expr` 变体作为下标表达式。尾随闭包 `f { ... }` 表示为带 `trailing_lambda` 的调用。

运算与转换：

```zig
pub const IncDecExpr = struct { op: IncDecOp, operand: *const HirExpr, range: TextRange };
pub const UnaryExpr = struct { op: UnaryOp, operand: *const HirExpr, range: TextRange };
pub const BinaryExpr = struct { op: BinaryOp, lhs: *const HirExpr, rhs: *const HirExpr, range: TextRange };
pub const AssignExpr = struct { op: AssignOp, lhs: *const HirExpr, rhs: *const HirExpr, range: TextRange };
pub const RangeExpr = struct {
    start: ?*const HirExpr = null,       // 下标位置的 ..b 为 null
    end: ?*const HirExpr = null,         // 下标位置的 a.. 为 null
    inclusive: bool,                     // ..= 为 true
    step: ?*const HirExpr = null,        // a..=b:step
    range: TextRange,
};
pub const IsExpr = struct { operand: *const HirExpr, ty: *const HirType, range: TextRange };
pub const AsExpr = struct { operand: *const HirExpr, ty: *const HirType, range: TextRange };
pub const TypeConvExpr = struct { ty: *const HirType, value: *const HirExpr, range: TextRange };
pub const VArrayExpr = struct {
    ty: *const HirType,
    args: []const HirCallArg = &.{},
    trailing_lambda: ?*const HirExpr = null,
    range: TextRange,
};
pub const TupleLit = struct { elements: []const HirExpr, range: TextRange };
pub const ArrayElement = struct { spread: bool = false, value: *const HirExpr, range: TextRange };
pub const ArrayLit = struct { elements: []const ArrayElement, range: TextRange };
```

语句块与条件：

```zig
pub const BlockExpr = struct {
    stmts: []const HirStmt = &.{},
    tail: ?*const HirExpr = null,        // 作为块值的尾表达式
    range: TextRange,                    // match 分支体对应不带花括号的 stmt_list
};
pub const LetDestructor = struct {
    patterns: []const HirPattern,        // let p1 | p2 <- expr
    value: *const HirExpr,
    range: TextRange,
};
pub const HirCondition = union(enum) {
    expr: *const HirExpr,
    let_destructor: LetDestructor,
};
pub const IfExpr = struct {
    condition: HirCondition,
    then_branch: *const BlockExpr,
    else_branch: ?*const HirExpr = null,
    range: TextRange,
};
```

`if` 与 `while` 的条件使用 `HirCondition`，因此 `if (let Some(x) <- value)` 与普通条件表达式都能表达。

分支与循环：

```zig
pub const PatternCase = struct {
    patterns: []const HirPattern,        // case p1 | p2
    guard: ?*const HirExpr = null,       // where cond
    body: *const BlockExpr,
    range: TextRange,
};
pub const ExprCase = struct {
    value: *const HirExpr,               // 无选择器 match 的分支表达式，case _ 为 .wildcard
    body: *const BlockExpr,
    range: TextRange,
};
pub const MatchCase = union(enum) { pattern: PatternCase, expr: ExprCase };
pub const MatchExpr = struct {
    selector: ?*const HirExpr = null,
    cases: []const MatchCase = &.{},
    range: TextRange,
};

pub const WhileExpr = struct { condition: HirCondition, body: *const BlockExpr, range: TextRange };
pub const DoWhileExpr = struct { body: *const BlockExpr, condition: *const HirExpr, range: TextRange };
pub const ForInExpr = struct {
    pattern: *const HirPattern,
    iterable: *const HirExpr,
    guard: ?*const HirExpr = null,
    body: *const BlockExpr,
    range: TextRange,
};
```

异常与跳转：

```zig
pub const Resource = struct { name: Name, ty: ?*const HirType = null, init: ?*const HirExpr = null, range: TextRange };
pub const CatchClause = struct { pattern: *const HirPattern, body: *const BlockExpr, range: TextRange };
pub const HandleClause = struct { pattern: *const HirPattern, body: *const BlockExpr, range: TextRange };
pub const TryClause = union(enum) { catch_: CatchClause, handle: HandleClause };
pub const TryExpr = struct {
    resources: []const Resource = &.{},
    body: *const BlockExpr,
    clauses: []const TryClause = &.{},
    finally: ?*const BlockExpr = null,
    range: TextRange,
};
pub const ThrowExpr = struct { value: *const HirExpr, range: TextRange };
pub const ReturnExpr = struct { value: ?*const HirExpr = null, range: TextRange };
pub const JumpExpr = struct { op: JumpOp, range: TextRange };
```

`catch` 与 `handle` 子句保持在同一个 `clauses` 列表中，源码顺序不会丢失。

并发、效应与宏：

```zig
pub const LambdaExpr = struct {
    annotations: []const Annotation = &.{},
    params: []const Param = &.{},
    is_variadic: bool = false,
    body: *const BlockExpr,
    range: TextRange,
};
pub const SpawnExpr = struct { context: ?*const HirExpr = null, task: *const HirExpr, range: TextRange };
pub const SynchronizedExpr = struct { mutex: *const HirExpr, body: *const BlockExpr, range: TextRange };
pub const UnsafeExpr = struct { body: *const BlockExpr, range: TextRange };
pub const QuotePart = union(enum) {
    token: TextRange,                   // 未插值的词法单元，按区间取源文本
    interpolation: *const HirExpr,      // $(expr)；$name 表示为单段路径
};
pub const QuoteExpr = struct { parts: []const QuotePart = &.{}, range: TextRange };

pub const MacroCall = struct {
    path: []const Name,
    has_bang: bool = false,
    attributes: ?TextRange = null,      // [..] 宏属性区间
    input: ?TextRange = null,           // 括号输入区间
};
pub const MacroCallExpr = struct { call: MacroCall, inner: ?*const HirExpr = null, range: TextRange };
pub const IfAvailableExpr = struct { args: []const HirCallArg, range: TextRange };
pub const PerformExpr = struct { value: *const HirExpr, range: TextRange };
pub const ResumeModifier = enum(u8) { with, throwing };
pub const ResumeExpr = struct {
    value: ?*const HirExpr = null,
    modifier: ?ResumeModifier = null,
    modifier_value: ?*const HirExpr = null,
    range: TextRange,
};
```

宏属性与括号输入以 `MacroCall.attributes`、`MacroCall.input` 区间保存，`quote` 的未插值词法单元以 `QuotePart.token` 区间保存；文本通过源文件与区间取得，HIR 不保存原始词法单元序列。

### 模式

```zig
pub const HirPattern = union(enum) {
    wildcard: WildcardPattern,           // _
    binding: BindingPattern,             // x
    const_: ConstPattern,                // -1、() 等字面量
    tuple: TuplePattern,                 // (a, b)
    enum_: EnumPattern,                  // Some(x)、Color.Red
    typed: TypePattern,                  // x: Int64、_: Int64
    except_type: ClausePattern,          // catch 中的 e: A | B
    command_type: ClausePattern,         // handle 中的 e: A | B
};

pub const BindingPattern = struct { name: Name, range: TextRange };
pub const ConstPattern = struct { value: *const HirExpr, range: TextRange };
pub const TuplePattern = struct { elements: []const HirPattern, range: TextRange };
pub const EnumPattern = struct {
    path: PathType,
    args: []const HirPattern = &.{},
    range: TextRange,
};
pub const TypePattern = struct { name: ?Name = null, ty: *const HirType, range: TextRange };
pub const ClausePattern = struct { name: ?Name = null, types: []const HirType, range: TextRange };
```

上述模式用于 `let` 绑定、`for (x in xs)` 与 `case` 分支：`let (a, b) = ...` 使用 `.tuple`，`let _ = ...` 使用 `.wildcard`，普通变量绑定使用 `.binding`。

### 语句与绑定

```zig
pub const Binding = struct {
    modifiers: []const Modifier = &.{},
    annotations: []const Annotation = &.{},
    kind: BindingKind,
    pattern: *const HirPattern,
    ty: ?*const HirType = null,
    init: ?*const HirExpr = null,
    range: TextRange,
};
pub const ExprStmt = struct { value: *const HirExpr, has_semi: bool = false, range: TextRange };
pub const HirStmt = union(enum) {
    binding: Binding,
    expr: ExprStmt,
    item: HirItem,                       // 块内允许出现的局部声明
};
```

`Binding` 同时用于语句、顶层常量与结构体字段，`kind` 没有默认值。

### 参数、泛型约束与函数名

```zig
pub const HirParam = struct {
    modifiers: []const Modifier = &.{},
    annotations: []const Annotation = &.{},
    binding: ?BindingKind = null,        // 主构造器成员参数的 let / var
    name: ?Name = null,                  // _ 参数为 null
    is_named: bool = false,              // a!: T
    ty: ?*const HirType = null,
    default_value: ?*const HirExpr = null,
    range: TextRange,
};
pub const ParamMacro = struct {
    annotations: []const Annotation = &.{},
    call: MacroCall,
    param: ?*const Param = null,         // 被宏修饰的参数；链式参数宏在此嵌套
    range: TextRange,
};
pub const Param = union(enum) { param: HirParam, macro_call: ParamMacro };

pub const FuncName = union(enum) {
    ident: Name,
    operator: Name,                      // text 为运算符源码文本，如 +、()、[]
};
pub const GenericConstraint = struct {
    subject: *const HirType,
    bounds: []const HirType,
    range: TextRange,
};
pub const WhereClause = struct { constraints: []const GenericConstraint, range: TextRange };
```

参数位置的宏调用（`func f(@M x: Int64)`）使用 `Param.macro_call`，`param` 字段指向被修饰的 `Param`，因此链式参数宏 `@M @N x: Int64` 可以嵌套表达。

### 声明项

```zig
pub const HirItem = union(enum) {
    func: FuncItem,
    main: MainItem,
    class: ClassItem,
    struct_: StructItem,
    enum_: EnumItem,
    interface: InterfaceItem,
    extend_: ExtendItem,
    prop: PropItem,
    type_alias: TypeAliasItem,
    init: InitItem,
    finalizer: FinalizerItem,
    primary_ctor: PrimaryCtorItem,
    binding: Binding,
    foreign: ForeignItem,
    macro_: MacroItem,
    macro_expand: MacroExpandItem,
};
```

函数、入口与宏：

```zig
pub const FuncItem = struct {
    modifiers: []const Modifier = &.{},
    annotations: []const Annotation = &.{},
    name: FuncName,
    type_params: []const Name = &.{},
    params: []const Param = &.{},
    is_variadic: bool = false,
    ret_type: ?*const HirType = null,
    where_clause: ?*const WhereClause = null,
    body: ?*const BlockExpr = null,      // 无函数体的声明为 null
    range: TextRange,
};
pub const MainItem = struct {
    modifiers: []const Modifier = &.{},
    annotations: []const Annotation = &.{},
    params: []const Param = &.{},
    is_variadic: bool = false,
    ret_type: ?*const HirType = null,
    body: *const BlockExpr,
    range: TextRange,
};
pub const MacroItem = struct {
    modifiers: []const Modifier = &.{},
    annotations: []const Annotation = &.{},
    name: Name,
    params: []const Param = &.{},
    is_variadic: bool = false,
    ret_type: ?*const HirType = null,
    body: *const HirExpr,                // = expr 或 .block
    range: TextRange,
};
pub const MacroExpandItem = struct {
    annotations: []const Annotation = &.{},
    call: MacroCall,
    wrapped: ?*const HirItem = null,     // 宏自行生成声明时为 null
    range: TextRange,
};
```

类型声明：

```zig
pub const ClassItem = struct {
    modifiers: []const Modifier = &.{},
    annotations: []const Annotation = &.{},
    name: Name,
    type_params: []const Name = &.{},
    supertypes: []const HirType = &.{},  // 第一个为父类，其余为接口
    where_clause: ?*const WhereClause = null,
    members: []const HirItem = &.{},
    range: TextRange,
};
pub const StructItem = struct {
    modifiers: []const Modifier = &.{},
    annotations: []const Annotation = &.{},
    name: Name,
    type_params: []const Name = &.{},
    interfaces: []const HirType = &.{},
    where_clause: ?*const WhereClause = null,
    members: []const HirItem = &.{},     // 字段以 .binding 出现
    range: TextRange,
};
pub const EnumPayloadType = struct {
    annotations: []const Annotation = &.{},
    ty: *const HirType,
    range: TextRange,
};
pub const EnumPayloadElement = union(enum) { ty: EnumPayloadType, macro_call: ParamMacro };

pub const EnumConstructor = struct {
    annotations: []const Annotation = &.{},
    name: Name,
    payload: []const EnumPayloadElement = &.{},
    range: TextRange,
};
pub const VariantMacro = struct {
    annotations: []const Annotation = &.{},
    call: MacroCall,
    constructor: ?*const EnumVariant = null,  // 被宏修饰的构造器；链式构造器宏在此嵌套
    range: TextRange,
};
pub const EnumVariant = union(enum) { constructor: EnumConstructor, macro_call: VariantMacro };
pub const EnumItem = struct {
    modifiers: []const Modifier = &.{},
    annotations: []const Annotation = &.{},
    name: Name,
    type_params: []const Name = &.{},
    interfaces: []const HirType = &.{},
    where_clause: ?*const WhereClause = null,
    variants: []const EnumVariant = &.{},
    is_non_exhaustive: bool = false,     // 带 ... 标记
    members: []const HirItem = &.{},
    range: TextRange,
};
pub const InterfaceItem = struct {
    modifiers: []const Modifier = &.{},
    annotations: []const Annotation = &.{},
    name: Name,
    type_params: []const Name = &.{},
    interfaces: []const HirType = &.{},  // 父接口
    where_clause: ?*const WhereClause = null,
    members: []const HirItem = &.{},
    range: TextRange,
};
pub const ExtendItem = struct {
    modifiers: []const Modifier = &.{},
    annotations: []const Annotation = &.{},
    type_params: []const Name = &.{},
    target: *const HirType,
    interfaces: []const HirType = &.{},
    where_clause: ?*const WhereClause = null,
    members: []const HirItem = &.{},
    range: TextRange,
};
```

`InterfaceItem` 的字段为 `modifiers`、`annotations`、`name`、`type_params`、`interfaces`、`where_clause`、`members` 与 `range`。

成员与其他声明：

```zig
pub const Binding = struct {
    modifiers: []const Modifier = &.{},
    annotations: []const Annotation = &.{},
    kind: BindingKind,
    pattern: *const HirPattern,
    ty: ?*const HirType = null,
    init: ?*const HirExpr = null,
    range: TextRange,
};
pub const PropAccessor = struct {
    name: Name,                          // get 或 set
    params: []const Param = &.{},
    body: *const BlockExpr,
    range: TextRange,
};
pub const PropItem = struct {
    modifiers: []const Modifier = &.{},
    annotations: []const Annotation = &.{},
    name: Name,
    ty: *const HirType,
    accessors: []const PropAccessor = &.{},
    range: TextRange,
};
pub const TypeAliasItem = struct {
    modifiers: []const Modifier = &.{},
    annotations: []const Annotation = &.{},
    name: Name,
    type_params: []const Name = &.{},
    target: *const HirType,
    range: TextRange,
};
pub const InitItem = struct {
    modifiers: []const Modifier = &.{},
    annotations: []const Annotation = &.{},
    params: []const Param = &.{},
    is_variadic: bool = false,
    body: *const BlockExpr,
    range: TextRange,
};
pub const FinalizerItem = struct {
    modifiers: []const Modifier = &.{},
    annotations: []const Annotation = &.{},
    params: []const Param = &.{},
    is_variadic: bool = false,
    body: *const BlockExpr,
    range: TextRange,
};
pub const PrimaryCtorItem = struct {
    modifiers: []const Modifier = &.{},
    annotations: []const Annotation = &.{},
    name: Name,                         // 与所属类型同名
    params: []const Param = &.{},
    is_variadic: bool = false,
    body: *const BlockExpr,
    range: TextRange,
};
pub const ForeignItem = struct {
    modifiers: []const Modifier = &.{},
    annotations: []const Annotation = &.{},
    members: []const HirItem = &.{},
    range: TextRange,
};
```

`FinalizerItem` 与 `PrimaryCtorItem` 的字段分别对应类终结器 `~init() { ... }` 与主构造器 `Point(let x: Int64) { ... }`。

### 包、特性、导入与文件根节点

```zig
pub const PackageHeader = struct {
    modifier: ?Modifier = null,
    is_macro: bool = false,
    org: ?Name = null,                   // org::a.b 中的 org
    name: []const Name,
    range: TextRange,
};
pub const FeatureId = struct { segments: []const Name, range: TextRange };
pub const FeaturesDirective = struct { features: []const FeatureId, range: TextRange };

pub const ImportAlias = struct { name: Name, alias: Name };
pub const ImportKind = union(enum) {
    single: Name,
    alias: ImportAlias,
    glob: void,                          // *
    group: []const ImportItem,           // { b, c as d, e.* }
};
pub const ImportItem = struct {
    modifier: ?Modifier = null,
    annotations: []const Annotation = &.{},
    org: ?Name = null,
    prefix: []const Name = &.{},
    kind: ImportKind,
    range: TextRange,
};

pub const HirFile = struct {
    file: FileId,
    version: u32,
    package: ?PackageHeader = null,
    features: ?FeaturesDirective = null,
    imports: []const ImportItem = &.{},
    items: []const HirItem = &.{},

    pub inline fn isOutdated(self: HirFile, file: FileId, current_version: u32) bool
};
```

`ImportItem` 覆盖 `importSingle`、`importAlias`、`importAll` 与 `importMulti` 四种形态。分组导入的每个元素同样是 `ImportItem`，其 `prefix` 为元素自身的点分路径（可为空切片），完整包路径由外层 `prefix` 与元素 `prefix` 拼接；例如 `e.*` 元素为 `prefix = [e]`、`kind = .glob`。`HirFile.imports` 收集文件中的全部导入声明；parser 在声明项之后接受的导入同样收入此列表，与声明项的相对位置不保留。`HirFile.isOutdated` 与 `common.SyntaxTree.isOutdated` 使用同一判定，复用 `common.source.isOutdated`。
