//! 解析器前端的库入口，供 `cjparser_test` 以及其它项目依赖。

pub const lexer = @import("lexer.zig");

test {
    _ = @import("./lexer.zig");
}
