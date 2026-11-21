# Zig 编码要求
- 当函数传入传出指针时，一般情况默认为调用者申请传参指针空间，结束后调用者需使用传入的 alloc 释放返回值指针。不符合上面描述的指针规则**必须**在函数文档注释中说明。

# Git 使用要求
- commit message 使用 Conventional Commits 规范。
