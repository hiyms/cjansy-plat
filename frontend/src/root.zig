//! 解析器前端的库入口，供 `cjfrontend` 以及其它项目依赖。

pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");

test {
    _ = @import("./lexer.zig");
    _ = @import("./parser.zig");
}
