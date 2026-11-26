# `common` 外部 API

入口模块为 `common`（对应 `common/src/root.zig`），对外导出通用基础类型、词法与 CST 标签、语法错误与解析事件、内置注解名称、源文件管理、诊断结构、UTF-8 解码能力及语法树结构。

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

携带绝对起始字节偏移的绿树节点定位结果。顶层可通过 `common.LocatedGreen` 访问。

### `GreenTree`

```zig
pub const GreenTree = struct {
    root: *const GreenNode,
};
```

对根 `GreenNode` 节点的封装。顶层可通过 `common.GreenTree` 访问。

- `pub inline fn textLen(self: GreenTree) u32`：返回整棵树覆盖的文本长度。
- `pub fn nodeAt(self: GreenTree, offset: u32) ?LocatedGreen`：定位包含给定字节位置的叶子节点及其绝对起始偏移，返回结果中的 `green` 指针借用自所属 `arena`。
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

绑定了父节点指针与绝对文件偏移的语法树视图节点，由 `QueryContext` 托管生命周期（预期短于底层 `GreenNode`）。顶层可通过 `common.RedNode` 访问。

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
- `pub fn initFromNode(gpa: std.mem.Allocator, node: *const GreenNode, start_offset: u32) GreenTraversal`：从指定节点与起始偏移初始化遍历器。
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
| `pub inline fn isContextKeyword(self: TokenTag) bool` | 是否为上下文关键字（`public`、`open` 等可在标识符位置复用的软关键字）。 |
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
- 源文件、特性、包、导入、注解、声明、声明体、语句块、泛型、参数、路径、类型、模式、表达式、语句、宏/quote 原始片段与 `error_node`。

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
};
```

语法分析阶段可遇到的错误码。顶层可通过 `common.ParseErrorCode` 访问。

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

### `CompactEvent`

```zig
pub const CompactEvent = struct {
    pub const Tag = enum(u8) { start_node, wrap_node, token, finish_node, parse_error };
    range: TextRange,
    payload: u16,
    tag: Tag,

    pub inline fn startNode(kind: SyntaxKind) CompactEvent
    pub inline fn wrapNode(kind: SyntaxKind) CompactEvent
    pub inline fn token(kind: SyntaxKind, range: TextRange) CompactEvent
    pub inline fn finishNode() CompactEvent
    pub inline fn parseError(err: ParseError) CompactEvent
    pub inline fn toEvent(self: CompactEvent) Event
};
```

12 字节的紧凑事件存储，避免对外 `Event` 联合体的尾部填充开销。顶层可通过 `common.CompactEvent` 访问。

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
};
```

带代次校验的 8 字节文件句柄。文件删除并复用槽位后旧句柄自动失效。顶层可通过 `common.FileId` 访问。

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
