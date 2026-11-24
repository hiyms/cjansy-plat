# `frontend` 外部 API

入口模块为 `frontend`（对应 `frontend/src/root.zig`），对外导出词法分析器模块 `frontend.lexer` 与语法解析器模块 `frontend.parser`。

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

基于事件流产出 Lossless CST 构建指令（供下游 `GreenBuilder` 构建只读绿树），对任意输入切片保证不崩溃、节点开闭严格平衡且叶子区间单调无损覆盖源码。

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
| `errors: std.ArrayList(ParseError)` | 存放解析过程中产出的全部 `ParseError`（已完成回溯清理并合并字符串插值子解析错误），首次调用 `gen` 完成解析后可读取 `parser.errors.items`；内存由 `deinit` 统一释放。 |
| `pub fn new(allocator: std.mem.Allocator, source: []const u8, tokens: []const common.Token) Parser` | 创建语法解析器。`source` 与 `tokens` 借用自调用方，使用期间须保持有效且不由此结构体释放；结束使用后须调用 `deinit` 释放内部事件与错误缓冲区。 |
| `pub fn deinit(self: *Parser) void` | 释放解析器内部事件缓冲区与 `errors` 列表内存，不释放借用的 `source` 与 `tokens`。 |
| `pub fn gen(self: *Parser) std.mem.Allocator.Error!?Event` | 产出下一个 `Event`，全部事件消费完毕返回 `null`。首次调用时执行整份输入解析并缓存事件流与 `errors`；若期间发生内存不足，会自动清空半成品数据并复位状态。 |

### `parseErrorToDiagnostic` 的内存约定

`common.parse_error.parseErrorToDiagnostic` 遵循诊断消息混合所有权约定：

- 编译期可完全确定的错误码（`recursive_depth_limit`、`non_associative_comparison`、`non_associative_assignment`、`non_associative_operator`、`invalid_assignment_target`、`unclosed_delimiter`、`invalid_interpolation`、`dangling_doc_comment`）以及 `err.range` 无有效可展示源码片段时，`Diagnostic.message` 直接返回编译期静态字符串切片，不调用 `allocator`，调用方不可对其单独调用 `free`。
- 其余需要拼入源码片段的错误码在 `err.range` 有效且非空时，按合法 UTF-8 码点边界安全截断片段并通过 `allocator` 格式化分配 `Diagnostic.message`。
- `source` 仅作只读借用；推荐使用 `std.heap.ArenaAllocator` 统一托管整批诊断消息的生命周期。

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

// 2. 语法解析并消费事件流
var parser = frontend.parser.Parser.new(gpa, source_text, tokens.items);
defer parser.deinit();
while (try parser.gen()) |ev| {
    // 交由 GreenBuilder 处理 ev
    _ = ev;
}

// 3. 将 ParseError 批量转换为 common.Diagnostic（使用 Arena 统一管理消息生命周期）
var diag_arena = std.heap.ArenaAllocator.init(gpa);
defer diag_arena.deinit();
const diag_alloc = diag_arena.allocator();

var diagnostics: std.ArrayList(common.Diagnostic) = .empty;
defer diagnostics.deinit(gpa);
for (parser.errors.items) |err_item| {
    try diagnostics.append(gpa, try err_item.toDiagnostic(diag_alloc, file_id, source_text));
}
```
