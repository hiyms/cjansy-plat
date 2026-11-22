// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! 供其它项目依赖的公共库。

pub const common = @import("common.zig");
pub const token = @import("token.zig");
pub const syntax = @import("syntax.zig");
pub const source = @import("source.zig");
pub const diagnostic = @import("diagnostic.zig");
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

pub const Severity = diagnostic.Severity;
pub const DiagnosticSource = diagnostic.Source;
pub const RelatedInfo = diagnostic.RelatedInfo;
pub const Diagnostic = diagnostic.Diagnostic;

pub const Codepoint = utf8.Codepoint;

test {
    _ = common;
    _ = token;
    _ = syntax;
    _ = source;
    _ = diagnostic;
    _ = utf8;
}
