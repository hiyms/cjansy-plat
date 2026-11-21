//! 供其它项目依赖的公共库。

pub const common = @import("common.zig");
pub const token = @import("token.zig");
pub const syntax = @import("syntax.zig");
pub const source = @import("source.zig");
pub const utf8 = @import("utf8.zig");

pub const Span = common.Span;
pub const ParseError = common.ParseError;

pub const TokenTag = token.TokenTag;
pub const Token = token.Token;

pub const SyntaxKind = syntax.SyntaxKind;
pub const toSyntaxKind = syntax.toSyntaxKind;

pub const Source = source.Source;
pub const FileId = source.FileId;
pub const File = source.File;
pub const FileKind = source.FileKind;
pub const FileExtraInfo = source.FileExtraInfo;
pub const PackageNameConstraint = source.PackageNameConstraint;
pub const FileType = source.FileType;
pub const Edit = source.Edit;
pub const TextRange = source.TextRange;
pub const Position = source.Position;
pub const LineIndex = source.LineIndex;

pub const Codepoint = utf8.Codepoint;

test {
    _ = common;
    _ = token;
    _ = syntax;
    _ = source;
    _ = utf8;
}
