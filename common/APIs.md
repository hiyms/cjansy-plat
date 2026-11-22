# `common` 外部 API

入口模块为 `common`（对应 `common/src/root.zig`），对外导出通用基础类型、词法与 CST 标签、源文件管理、诊断结构及 UTF-8 解码能力。

## 模块导出

- `common.common`：通用字节区间与错误集合。
- `common.token`：词法单元与词法标签。
- `common.syntax`：Lossless CST 节点标签与转换函数。
- `common.source`：源文件管理、编辑与行列索引。
- `common.diagnostic`：统一诊断数据结构。
- `common.utf8`：UTF-8 解码与 Unicode 码点判定。

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

### `ParseError`

```zig
pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEndOfInput,
    InvalidCharacter,
    UnsupportFeature,
};
```

公共库通用错误集合。顶层可通过 `common.ParseError` 访问。

---

## 词法单元（`common.token`）

### `TokenTag`

```zig
pub const TokenTag = enum { ... };
```

词法分析阶段产出的词法单元标签枚举（涵盖运算符、分隔符、关键字、标识符、字面量、`comment`、`nl`、`end`、`sentinel`、`illegal`）。顶层可通过 `common.TokenTag` 访问。

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
- `File`：由 `Source` 独占持有，公开字段含 `kind`、`path`、`extra`、`version`、`line_index`，通过 `pub fn content(self: *const File) []const u8` 获取当前只读文本切片（在下次编辑前有效）。

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
