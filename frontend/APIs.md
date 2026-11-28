# `frontend` 外部 API

入口模块为 `frontend`（对应 `frontend/src/root.zig`），对外导出词法分析器模块 `frontend.lexer`、语法解析器模块 `frontend.parser`、绿树构建模块 `frontend.tree` 与 CST→HIR 降低器模块 `frontend.lower`。顶层同时导出 `frontend.GreenBuilder`、`frontend.treeBuild`、`frontend.Lowerer`、`frontend.LoweredItem`、`frontend.LoweredFile`、`frontend.lowerItem` 与 `frontend.lowerFile`。

---

## 词法分析器（`frontend.lexer`）

### `Lexer`（别名 `frontend.lexer.t`）

流式仓颉词法分析器，不分配堆内存；借用外部 UTF-8 源码切片 `raw`，调用方须保证在使用期间源码切片持续有效。水平空白（空格、`\t`、`\x0c`）自动跳过，换行产出 `common.TokenTag.nl`，注释产出 `common.TokenTag.comment`，词法非法片段产出 `common.TokenTag.illegal` 并继续推进游标，到达输入结尾产出 `common.TokenTag.end`。

#### 错误集合

```zig
pub const Error = error{
    /// 输入源码长度超过 `std.math.maxInt(u32)`。
    SourceTooLarge,
    /// 当前游标越过源码末尾。
    InvalidCursor,
    /// 字符串插值嵌套层级超过上限（128）。
    InterpolationDepthExceeded,
};
```

#### 字段与方法

| 成员 / 签名 | 说明 |
| :--- | :--- |
| `raw: []const u8` | 借用的待扫描 UTF-8 源码切片。 |
| `index: u32` | 当前扫描游标字节下标（范围 `0..=raw.len`）。 |
| `pub inline fn new(source: []const u8) Error!Lexer` | 创建词法分析器，借用 `source` 切片；超长时返回 `error.SourceTooLarge`。 |
| `pub fn gen(self: *Lexer) Error!common.Token` | 扫描并返回下一个词法单元，到达末尾返回 `.tag == .end`。 |

---

## 语法解析器（`frontend.parser`）

基于事件流产出 Lossless CST 构建指令（供 `frontend.tree` 中的 `GreenBuilder` 构建只读绿树），对任意输入切片保证不崩溃、节点开闭严格平衡且叶子区间单调无损覆盖源码。

### 常量

- `pub const max_recursion_depth: u32 = 256`：最大递归嵌套深度上限，超限时记录 `ParseErrorCode.recursive_depth_limit` 并安全中止深层展开。

### `ParseErrorCode`、`ParseError` 与 `parseErrorToDiagnostic`

这三个接口定义于 `common.parse_error`，在 `frontend.parser` 中作为同类型别名与函数别名重新导出，用法与 `common` 模块一致：

- `pub const ParseErrorCode = common.ParseErrorCode`
- `pub const ParseError = common.ParseError`
- `pub const parseErrorToDiagnostic = common.parse_error.parseErrorToDiagnostic`

### `TokenEvent` 与 `Event`

事件流协议定义于 `common.event`，在 `frontend.parser` 中以 `pub const TokenEvent = common.TokenEvent` 与 `pub const Event = common.Event` 重新导出。`start_node` 与 `wrap_node` 的总发射次数与 `finish_node` 严格相等，叶子位置信息仅由 `token` 与 `parse_error` 携带。

### `Parser`（别名 `frontend.parser.t`）

| 成员 / 签名 | 说明 |
| :--- | :--- |
| `events: std.ArrayList(Event)` | 解析后的事件流。`parse` 成功后 `parser.events.items` 为整份输入的完整事件流，可直接交给 `frontend.treeBuild` 或逐个写出；内存由 `deinit` 统一释放。 |
| `errors: std.ArrayList(ParseError)` | 存放解析产出的全部 `ParseError`（已完成回溯清理并合并字符串插值子解析错误），`parse` 完成后可读取 `parser.errors.items`；内存由 `deinit` 统一释放。 |
| `pub fn new(allocator: std.mem.Allocator, source: []const u8, tokens: []const common.Token) Parser` | 创建语法解析器，此时尚未解析。`source` 与 `tokens` 借用自调用方，使用期间须保持有效且不由此结构体释放；结束使用后须调用 `deinit` 释放内部事件与错误缓冲区。 |
| `pub fn deinit(self: *Parser) void` | 释放解析器内部事件缓冲区与 `errors` 列表内存，不释放借用的 `source` 与 `tokens`。 |
| `pub fn parse(self: *Parser) std.mem.Allocator.Error!void` | 一次性解析整份输入，把完整事件流写入 `events`、语法诊断写入 `errors`。按词法单元数量预先分配事件缓冲；若期间发生内存不足，自动清空半成品数据并复位解析状态，使同一个解析器可以重新调用 `parse`。 |

### 声明位置与 `error_node`

声明类别是否允许出现在当前位置，依据 `cangjie_spec` 中各声明体的成员列表判定，覆盖顶层、`class`/`struct`/`interface`/`enum`/`extend` 体、`foreign` 块、语句块与文件头部。文件头部顺序为 `features`、`package`、`import`；三者出现在其它位置时同样属于非法位置。

非法位置会记录 `ParseErrorCode.invalid_declaration_position`，并把正常解析得到的声明节点包在 `error_node` 内。内层节点与在合法位置解析得到的结构一致，例如语句块中的 `import` 产生 `error_node { import_spec }`，`class` 体内嵌套的 `struct` 产生 `error_node { struct_decl }`。修饰符与声明类别不相容时同样按非法位置处理，例如顶层 `static let`、带访问修饰符的局部变量与 `public foreign func`。

局部函数与局部 `const` 变量符合语言规范，不会产生 `error_node`。

### 语法约束

- 文件头部的 `features` 指令可带内置注解（如 `@NonProduct`）。
- 尾随闭包只允许挂在函数名或变量名调用之后；条件、迭代源与模式守卫中的尾随闭包与普通表达式一样允许。
- 赋值左值限定为标识符、字段访问、下标访问、可选链左值与元组左值；`=` 左侧允许 `_`，复合赋值不允许。
- 同一行内的表达式与声明之间必须有 `;` 或换行分隔。
- 类型实参不允许尾随逗号，类型实参只能附在路径末段；元组与函数类型的标签必须全有或全无，命名元组至少两个元素。
- `extend` 的被扩展类型只能是点分标识符或基础类型；lambda 形参只能写名称或 `_` 加可选类型。
- `foreign` 只接受函数声明，块内不得出现变量、类型、属性或构造函数；函数本身不能附加其它修饰符。
- 元组模式至少两个元素，枚举构造器模式参数至少一个；`let`、`var`、`const` 与 `for-in` 只接受 irrefutable 模式。
- 枚举至少一个构造器；导入分组不得为空且不得嵌套；`match` 至少一个分支，`try` 必须有 catch、handle 或 finally，下标、元组与插值不得为空，闭区间不可省略右端点。
- 换行按 `Chapter_01_Lexical_Structure.md` 的最长匹配规则处理：`return` 后换行可接表达式，行首一元 `-` 在可延长上一行表达式时作为二元减法。

### `parseErrorToDiagnostic` 的内存约定

`common.parse_error.parseErrorToDiagnostic` 遵循诊断消息混合所有权约定：

- 编译期可完全确定的错误码（`recursive_depth_limit`、`non_associative_comparison`、`non_associative_assignment`、`non_associative_operator`、`invalid_assignment_target`、`unclosed_delimiter`、`invalid_interpolation`、`dangling_doc_comment`）以及 `err.range` 无有效可展示源码片段时，`Diagnostic.message` 直接返回编译期静态字符串切片，不调用 `allocator`，调用方不可对其单独调用 `free`。
- 其余需要拼入源码片段的错误码在 `err.range` 有效且非空时，按合法 UTF-8 码点边界安全截断片段并通过 `allocator` 格式化分配 `Diagnostic.message`。
- `source` 仅作只读借用；推荐使用 `std.heap.ArenaAllocator` 统一托管整批诊断消息的生命周期。

---

## 绿树构建（`frontend.tree`）

把 `common.Event` 事件流转换为 `common.GreenTree`。构建期间的临时节点列表与子节点列表使用 `gpa`，最终节点、子节点指针数组与叶子文本复制进 `arena`；`arena` 必须比返回的绿树活得久，通常传入 `File.allocator()`。叶子文本在构建时从源码复制，返回的绿树不引用源码切片。`parse_error` 事件不进入绿树。

### `GreenBuilder`

基于后进先出节点列表的状态机，只接收节点开闭与叶子指令。

```zig
pub const GreenBuilder = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
    frames: std.ArrayListUnmanaged(Frame),
    root: ?*const GreenNode,

    pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator, source: []const u8) GreenBuilder
    pub fn deinit(self: *GreenBuilder) void
    pub fn startNode(self: *GreenBuilder, kind: SyntaxKind) std.mem.Allocator.Error!void
    pub fn wrapNode(self: *GreenBuilder, kind: SyntaxKind) std.mem.Allocator.Error!void
    pub fn token(self: *GreenBuilder, kind: SyntaxKind, range: TextRange) std.mem.Allocator.Error!void
    pub fn finishNode(self: *GreenBuilder) std.mem.Allocator.Error!void
    pub fn finish(self: *GreenBuilder) *const GreenNode
};
```

| 方法 | 说明 |
| :--- | :--- |
| `startNode(kind)` | 开始一个新节点，新节点成为当前节点。 |
| `wrapNode(kind)` | 把当前节点的最后一个已完成子节点包裹进新节点，新节点成为当前节点，被包裹的节点成为其首个子节点。 |
| `token(kind, range)` | 追加叶子节点，文本从 `source[range]` 复制进 `arena`。 |
| `finishNode()` | 结束当前节点并交还给父节点；结束根节点时记录到 `root`。 |
| `finish()` | 返回已完成的根节点。调用前须确保未结束节点列表为空且存在已完成的根节点。 |

`finish()` 返回的指针借用自 `arena`，调用者不得单独释放。根节点类型由事件流决定，不要求是 `source_file`。

### `treeBuild`

```zig
pub fn treeBuild(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
    events: []const common.Event,
) std.mem.Allocator.Error!common.GreenTree
```

一次性消费全部事件并返回绿树。`source` 是事件区间对应的完整源码，只在构建期间借用；`gpa` 只用于临时内存；`arena` 持有最终节点与叶子文本，必须比返回的绿树活得久，通常传入 `File.allocator()`。`parse_error` 事件会被忽略，诊断由调用方从解析器读取。构建期间发生内存分配错误时返回 `std.mem.Allocator.Error`。

---

## CST→HIR 降低器（`frontend.lower`）

将 Lossless Green CST 转换为高层中间表示（`common.hir`），在项内从 `0` 顺序分配 `HirId` 并可选填充 `common.GreenToHirMap`。

- 内部不依赖 `RedNode` 或 `QueryContext`，通过 `GreenNode` 树的 `text_len` 现场累加计算每个节点的源码字节区间（自动剥离节点内部前导与尾随 Trivia）。
- 遵循容错纪律：遇到缺损语法树、`error_node` 或非法字面量（如残缺进制字面量 `0x`、非法字符字面量）时，记录 `source = .parser` 的 `Diagnostic` 并生成占位 HIR 节点继续降低，仅在内存不足时返回 `std.mem.Allocator.Error`。
- 平铺的 `path_expr` 在首段为普通名称且全链不含 `?.` 时保留为单个 `HirExpr.path`；若首段包裹了非名称表达式（如 `g().b.c`）或链中含 `?.`（如 `a?.b.c`），自动按左结合转换为接收者表达式、`HirExpr.optional` 与链式 `HirExpr.field`，并将每个 `path_segment` 映射到对应层级的 `HirId`。
- 折叠或合并的包装节点（`paren_expr`、`paren_type`、`trailing_closure_expr`、`quote_interpolation`、`ret_type`、`pattern_guard`、`finally_clause`、被提取为块尾表达式的末尾无分号 `expression_statement`、包裹了声明的 `error_node`）均穿透映射到内层目标节点的 `HirId`。

### `LoweredItem`

```zig
pub const LoweredItem = struct {
    id: common.ItemId,
    item: *const common.HirItem,
    hir_id_start: common.HirId,
    hir_id_end: common.HirId,
    nodes: []const common.HirNode,
    exprs: []const *const common.HirExpr,
    diagnostics: []const common.Diagnostic,

    pub inline fn node(self: LoweredItem, id: common.HirId) ?common.HirNode
    pub inline fn expr(self: LoweredItem, id: common.HirId) ?*const common.HirExpr
};
```

单个顶层或独立声明项的 lowering 产物。恒满足 `hir_id_start == .fromIndex(0)`、`hir_id_end == .fromIndex(@intCast(nodes.len))` 且对任意 `0 <= i < nodes.len` 有 `nodes[i].id().index() == i`。`item`、`nodes`、`exprs`、`diagnostics` 及其内部所有指针均由 `arena` 分配，随 `arena` 统一释放，调用者不得单独释放。

### `LoweredFile`

```zig
pub const LoweredFile = struct {
    hir_file: common.HirFile,
    lowered_items: []const LoweredItem,
    diagnostics: []const common.Diagnostic,

    pub inline fn node(self: LoweredFile, key: common.HirKey) ?common.HirNode
    pub inline fn hirRange(self: LoweredFile, key: common.HirKey) ?common.TextRange
};
```

整份 `source_file` 的 lowering 产物。`lowered_items` 与 `hir_file.items` 一一对应，下标即为 `ItemId.index()`。所有指针与切片均由 `arena` 分配，随 `arena` 统一释放，调用者不得单独释放。

### `Lowerer`、`lowerItem` 与 `lowerFile`

```zig
pub const Lowerer = struct {
    pub fn init(
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        file: common.FileId,
        version: u32,
        green_to_hir: ?*common.GreenToHirMap,
    ) Lowerer
    pub fn deinit(self: *Lowerer) void
    pub fn lowerItem(
        self: *Lowerer,
        item_id: common.ItemId,
        item_green: *const common.GreenNode,
        item_start_offset: u32,
    ) std.mem.Allocator.Error!LoweredItem
    pub fn lowerFile(
        self: *Lowerer,
        root: *const common.GreenNode,
    ) std.mem.Allocator.Error!LoweredFile
};

pub fn lowerItem(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    file: common.FileId,
    item_id: common.ItemId,
    item_green: *const common.GreenNode,
    item_start_offset: u32,
    green_to_hir: ?*common.GreenToHirMap,
) std.mem.Allocator.Error!LoweredItem

pub fn lowerFile(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    syntax_tree: common.SyntaxTree,
    green_to_hir: ?*common.GreenToHirMap,
) std.mem.Allocator.Error!LoweredFile
```

- `gpa` 仅用于 lowering 期间的临时可变工作缓冲（由 `Lowerer.deinit` 释放）。
- `arena` 用于分配所有产出的 HIR 节点指针、切片、诊断消息以及 `green_to_hir` 的哈希桶内存（通常传入 `File.allocator()`），随 `arena` 统一释放。

---

## 典型调用流程

```zig
const std = @import("std");
const common = @import("common");
const frontend = @import("frontend");

// 1. 词法扫描
var tokens: std.ArrayList(common.Token) = .empty;
defer tokens.deinit(gpa);
var lex = try frontend.lexer.Lexer.new(source_text);
while (true) {
    const tok = try lex.gen();
    try tokens.append(gpa, tok);
    if (tok.tag == .end) break;
}

// 2. 语法解析，事件流通过 `events` 成员读取
var parser = frontend.parser.Parser.new(gpa, source_text, tokens.items);
defer parser.deinit();
try parser.parse();

// 3. 构建绿树。arena 通常使用 File.allocator()，须比绿树活得久
var tree_arena = std.heap.ArenaAllocator.init(gpa);
defer tree_arena.deinit();
const tree = try frontend.treeBuild(gpa, tree_arena.allocator(), source_text, parser.events.items);

// 4. 将 ParseError 批量转换为 common.Diagnostic（使用 Arena 统一管理消息生命周期）
var diag_arena = std.heap.ArenaAllocator.init(gpa);
defer diag_arena.deinit();
const diag_alloc = diag_arena.allocator();

var diagnostics: std.ArrayList(common.Diagnostic) = .empty;
defer diagnostics.deinit(gpa);
for (parser.errors.items) |err_item| {
    try diagnostics.append(gpa, try err_item.toDiagnostic(diag_alloc, file_id, source_text));
}
```
