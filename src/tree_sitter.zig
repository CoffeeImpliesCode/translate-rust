//! Private Tree-sitter boundary. C node aggregates cross by pointer only.
//! Parsers and trees are owned; nodes borrow their tree, strings borrow the grammar.

const std = @import("std");

pub const Language = opaque {};

pub const Parser = opaque {
    /// The caller owns the parser and must call `destroy`.
    pub fn create() *Parser {
        return ts_parser_new();
    }

    pub fn destroy(self: *Parser) void {
        ts_parser_delete(self);
    }

    pub fn setLanguage(self: *Parser, language: ?*const Language) error{IncompatibleLanguage}!void {
        if (!ts_parser_set_language(self, language)) return error.IncompatibleLanguage;
    }

    /// Parse UTF-8 source. The caller owns a returned tree and must destroy it.
    pub fn parseString(self: *Parser, source: []const u8, old_tree: ?*const Tree) ?*Tree {
        return ts_parser_parse_string(self, old_tree, source.ptr, @intCast(source.len));
    }
};

pub const Tree = opaque {
    /// Release the tree. All nodes borrowed from it become invalid.
    pub fn destroy(self: *Tree) void {
        ts_tree_delete(self);
    }

    pub fn rootNode(self: *const Tree) Node {
        var root: Node = undefined;
        r2z_ts_tree_root_node(self, &root);
        return root;
    }
};

/// C's TSNode layout. Navigation converts C null-node sentinels to Zig null.
pub const Node = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const Tree,

    /// Node identity ignores traversal context, matching the C runtime.
    pub fn eql(self: *const Node, other: Node) bool {
        return self.tree == other.tree and self.id == other.id;
    }

    pub fn kind(self: *const Node) []const u8 {
        return std.mem.span(r2z_ts_node_type(self));
    }

    pub fn isNamed(self: *const Node) bool {
        return r2z_ts_node_is_named(self);
    }

    pub fn hasError(self: *const Node) bool {
        return r2z_ts_node_has_error(self);
    }

    pub fn startByte(self: *const Node) u32 {
        return r2z_ts_node_start_byte(self);
    }

    pub fn endByte(self: *const Node) u32 {
        return r2z_ts_node_end_byte(self);
    }

    pub fn namedChildCount(self: *const Node) u32 {
        return r2z_ts_node_named_child_count(self);
    }

    pub fn child(self: *const Node, child_index: u32) ?Node {
        var found: Node = undefined;
        if (!r2z_ts_node_child(self, child_index, &found)) return null;
        return found;
    }

    pub fn namedChild(self: *const Node, child_index: u32) ?Node {
        var found: Node = undefined;
        if (!r2z_ts_node_named_child(self, child_index, &found)) return null;
        return found;
    }

    pub fn childByFieldName(self: *const Node, name: []const u8) ?Node {
        var found: Node = undefined;
        if (!r2z_ts_node_child_by_field_name(self, name.ptr, @intCast(name.len), &found)) return null;
        return found;
    }

    pub fn fieldNameForNamedChild(self: *const Node, named_child_index: u32) ?[]const u8 {
        const name = r2z_ts_node_field_name_for_named_child(self, named_child_index) orelse return null;
        return std.mem.span(name);
    }

    pub fn prevNamedSibling(self: *const Node) ?Node {
        var found: Node = undefined;
        if (!r2z_ts_node_prev_named_sibling(self, &found)) return null;
        return found;
    }

    pub fn nextNamedSibling(self: *const Node) ?Node {
        var found: Node = undefined;
        if (!r2z_ts_node_next_named_sibling(self, &found)) return null;
        return found;
    }
};

extern fn ts_parser_new() callconv(.c) *Parser;
extern fn ts_parser_delete(self: *Parser) callconv(.c) void;
extern fn ts_parser_set_language(self: *Parser, language: ?*const Language) callconv(.c) bool;
extern fn ts_parser_parse_string(self: *Parser, old_tree: ?*const Tree, source: [*]const u8, length: u32) callconv(.c) ?*Tree;
extern fn ts_tree_delete(self: *Tree) callconv(.c) void;

extern fn r2z_ts_tree_root_node(self: *const Tree, out: *Node) callconv(.c) void;
extern fn r2z_ts_node_type(self: *const Node) callconv(.c) [*:0]const u8;
extern fn r2z_ts_node_start_byte(self: *const Node) callconv(.c) u32;
extern fn r2z_ts_node_end_byte(self: *const Node) callconv(.c) u32;
extern fn r2z_ts_node_named_child_count(self: *const Node) callconv(.c) u32;
extern fn r2z_ts_node_is_named(self: *const Node) callconv(.c) bool;
extern fn r2z_ts_node_has_error(self: *const Node) callconv(.c) bool;
extern fn r2z_ts_node_child(self: *const Node, child_index: u32, out: *Node) callconv(.c) bool;
extern fn r2z_ts_node_named_child(self: *const Node, child_index: u32, out: *Node) callconv(.c) bool;
extern fn r2z_ts_node_child_by_field_name(self: *const Node, name: [*]const u8, name_length: u32, out: *Node) callconv(.c) bool;
extern fn r2z_ts_node_field_name_for_named_child(self: *const Node, named_child_index: u32) callconv(.c) ?[*:0]const u8;
extern fn r2z_ts_node_prev_named_sibling(self: *const Node, out: *Node) callconv(.c) bool;
extern fn r2z_ts_node_next_named_sibling(self: *const Node, out: *Node) callconv(.c) bool;
