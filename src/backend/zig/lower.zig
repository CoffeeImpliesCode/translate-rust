//! translate_rust.backend.zig.lower — Lowering engine from RustIR to ZigAST.
//!
//! Transforms target-agnostic semantic IR (RustIR) into a structured Zig package AST
//! (ast.Package). Handles module-to-file mapping, item translation, method hoisting
//! (injecting inherent and trait impl methods into struct/enum bodies), type mapping
//! via pluggable LoweringStrategy, and full expression/statement/pattern lowering.

const std = @import("std");
const ir = @import("translate_rust.ir");
const ast = @import("ast.zig");
const strategy = @import("../strategy.zig");
const default_strat = @import("strategies/default.zig");

/// Lower a complete Rust semantic model (RustIR) into a target-language Zig package.
pub fn lowerRustIR(
    allocator: std.mem.Allocator,
    rust_ir: *const ir.RustIR,
    custom_strat: ?*const strategy.LoweringStrategy,
) !ast.Package {
    var lowerer = Lowerer.init(allocator, rust_ir, custom_strat);
    return try lowerer.lowerPackage();
}

const Lowerer = struct {
    alloc: std.mem.Allocator,
    ir: *const ir.RustIR,
    strat: strategy.LoweringStrategy,
    def_strat_inst: default_strat.DefaultStrategy = .{},

    /// Map from target struct/enum EntityId to hoisted method declarations
    hoisted_by_id: std.AutoHashMapUnmanaged(ir.spine.EntityId, std.ArrayListUnmanaged(ast.Decl)) = .empty,

    fn init(
        allocator: std.mem.Allocator,
        rust_ir: *const ir.RustIR,
        custom_strat: ?*const strategy.LoweringStrategy,
    ) Lowerer {
        var lowerer = Lowerer{
            .alloc = allocator,
            .ir = rust_ir,
            .strat = undefined,
        };

        if (custom_strat) |cs| {
            lowerer.strat = cs.*;
        } else {
            lowerer.strat = .{
                .ptr = &lowerer.def_strat_inst,
                .vtable = &.{
                    .lowerType = default_strat.DefaultStrategy.lowerType,
                    .lowerStdGeneric = default_strat.DefaultStrategy.lowerStdGeneric,
                },
            };
        }

        return lowerer;
    }

    fn allocType(self: *Lowerer, t: ast.Type) !*const ast.Type {
        const ptr = try self.alloc.create(ast.Type);
        ptr.* = t;
        return ptr;
    }

    fn allocExpr(self: *Lowerer, e: ast.Expr) !*const ast.Expr {
        const ptr = try self.alloc.create(ast.Expr);
        ptr.* = e;
        return ptr;
    }

    fn allocBlock(self: *Lowerer, b: ast.Block) !*const ast.Block {
        const ptr = try self.alloc.create(ast.Block);
        ptr.* = b;
        return ptr;
    }

    pub fn lowerPackage(self: *Lowerer) !ast.Package {
        try self.collectHoistedMethods();

        var files_list: std.ArrayListUnmanaged(ast.File) = .empty;

        if (self.ir.graph.modules.items.len == 0) {
            // No explicit module graph: synthesize a root file from all entities
            const root_file = try self.lowerRootFileFromSymbolTable();
            try files_list.append(self.alloc, root_file);
        } else {
            // Lower each module into a corresponding file
            for (self.ir.graph.modules.items) |mod| {
                const file = try self.lowerModule(mod);
                try files_list.append(self.alloc, file);
            }
        }

        const pkg_name = try self.alloc.dupe(u8, self.ir.crate_name);

        return ast.Package{
            .name = pkg_name,
            .version = "0.0.0",
            .fingerprint = null,
            .files = try files_list.toOwnedSlice(self.alloc),
            .zon_deps = &.{},
        };
    }

    fn collectHoistedMethods(self: *Lowerer) !void {
        const count = self.ir.graph.symbol_table.count();
        for (0..count) |idx| {
            const entity_id: ir.spine.EntityId = @intCast(idx);
            const ent = self.ir.graph.symbol_table.get(entity_id) orelse continue;

            if (ent.kind == .fn_ and ent.parent != null) {
                const parent_id = ent.parent.?;
                const parent_ent = self.ir.graph.symbol_table.get(parent_id);

                const target_id: ?ir.spine.EntityId = blk: {
                    if (parent_ent) |pe| {
                        if (pe.kind == .struct_ or pe.kind == .enum_ or pe.kind == .union_) {
                            break :blk parent_id;
                        } else if (pe.kind == .impl_) {
                            if (pe.parent) |impl_parent| {
                                break :blk impl_parent;
                            }
                        }
                    }
                    break :blk null;
                };

                if (target_id) |tid| {
                    const fn_decl = try self.lowerFnEntity(entity_id, ent);
                    const decl = ast.Decl{ .fn_decl = fn_decl };
                    var list = self.hoisted_by_id.get(tid) orelse std.ArrayListUnmanaged(ast.Decl).empty;
                    try list.append(self.alloc, decl);
                    try self.hoisted_by_id.put(self.alloc, tid, list);
                }
            }
        }
    }

    fn lowerModule(self: *Lowerer, mod: ir.graph.Module) !ast.File {
        const file_path = if (mod.source_path) |sp|
            try self.alloc.dupe(u8, sp)
        else if (mod.kind == .root or mod.is_crate)
            try self.alloc.dupe(u8, "src/root.zig")
        else if (mod.name.len > 0)
            try std.fmt.allocPrint(self.alloc, "src/{s}.zig", .{mod.name})
        else
            try self.alloc.dupe(u8, "src/root.zig");

        var imports_list: std.ArrayListUnmanaged(ast.Import) = .empty;
        try imports_list.append(self.alloc, .{
            .local_name = "std",
            .module_or_path = "std",
            .is_pub = false,
        });

        var decls_list: std.ArrayListUnmanaged(ast.Decl) = .empty;
        var tests_list: std.ArrayListUnmanaged(ast.TestDecl) = .empty;

        for (mod.items) |item_id| {
            const ent = self.ir.graph.symbol_table.get(item_id) orelse continue;

            if (ent.kind == .fn_ and (std.mem.startsWith(u8, ent.name, "test_") or std.mem.eql(u8, ent.name, "test"))) {
                if (try self.lowerTestEntity(item_id, ent)) |td| {
                    try tests_list.append(self.alloc, td);
                    continue;
                }
            }

            if (try self.lowerEntityDecl(item_id, ent)) |decl| {
                try decls_list.append(self.alloc, decl);
            }
        }

        return ast.File{
            .path = file_path,
            .imports = try imports_list.toOwnedSlice(self.alloc),
            .decls = try decls_list.toOwnedSlice(self.alloc),
            .tests = try tests_list.toOwnedSlice(self.alloc),
        };
    }

    fn lowerRootFileFromSymbolTable(self: *Lowerer) !ast.File {
        var imports_list: std.ArrayListUnmanaged(ast.Import) = .empty;
        try imports_list.append(self.alloc, .{
            .local_name = "std",
            .module_or_path = "std",
            .is_pub = false,
        });

        var decls_list: std.ArrayListUnmanaged(ast.Decl) = .empty;
        var tests_list: std.ArrayListUnmanaged(ast.TestDecl) = .empty;

        const count = self.ir.graph.symbol_table.count();
        for (0..count) |idx| {
            const entity_id: ir.spine.EntityId = @intCast(idx);
            const ent = self.ir.graph.symbol_table.get(entity_id) orelse continue;

            // Skip nested methods (they are hoisted into structs)
            if (ent.parent != null and ent.kind == .fn_) continue;

            if (ent.kind == .fn_ and (std.mem.startsWith(u8, ent.name, "test_") or std.mem.eql(u8, ent.name, "test"))) {
                if (try self.lowerTestEntity(entity_id, ent)) |td| {
                    try tests_list.append(self.alloc, td);
                    continue;
                }
            }

            if (try self.lowerEntityDecl(entity_id, ent)) |decl| {
                try decls_list.append(self.alloc, decl);
            }
        }

        return ast.File{
            .path = "src/root.zig",
            .imports = try imports_list.toOwnedSlice(self.alloc),
            .decls = try decls_list.toOwnedSlice(self.alloc),
            .tests = try tests_list.toOwnedSlice(self.alloc),
        };
    }

    fn lowerEntityDecl(self: *Lowerer, entity_id: ir.spine.EntityId, ent: ir.spine.Entity) !?ast.Decl {
        const is_pub = switch (ent.visibility) {
            .public => true,
            else => false,
        };

        const body_kind = if (entity_id < self.ir.bodies.bodies.len)
            self.ir.bodies.bodies[entity_id]
        else
            ir.bodies.BodyKind{ .none = {} };

        switch (ent.kind) {
            .struct_ => {
                var fields_list: std.ArrayListUnmanaged(ast.StructField) = .empty;
                var inner_decls: std.ArrayListUnmanaged(ast.Decl) = .empty;

                switch (body_kind) {
                    .struct_ => |sb| {
                        for (sb.fields) |f| {
                            const f_ty = try self.lowerType(f.ty);
                            try fields_list.append(self.alloc, .{
                                .name = try self.alloc.dupe(u8, f.name),
                                .ty = f_ty,
                                .is_pub = switch (f.visibility) {
                                    .public => true,
                                    else => false,
                                },
                            });
                        }

                        // Inherent methods from StructBody
                        for (sb.methods) |m| {
                            const m_decl = try self.lowerStructMethod(m, ent.name);
                            try inner_decls.append(self.alloc, ast.Decl{ .fn_decl = m_decl });
                        }
                    },
                    else => {},
                }

                // Append any hoisted methods from impl blocks
                if (self.hoisted_by_id.get(entity_id)) |hoisted| {
                    for (hoisted.items) |d| {
                        try inner_decls.append(self.alloc, d);
                    }
                }

                return ast.Decl{
                    .struct_decl = .{
                        .name = try self.alloc.dupe(u8, ent.name),
                        .is_pub = is_pub,
                        .fields = try fields_list.toOwnedSlice(self.alloc),
                        .decls = try inner_decls.toOwnedSlice(self.alloc),
                    },
                };
            },
            .enum_ => {
                var variants_list: std.ArrayListUnmanaged(ast.EnumVariant) = .empty;
                var inner_decls: std.ArrayListUnmanaged(ast.Decl) = .empty;

                switch (body_kind) {
                    .enum_ => |eb| {
                        for (eb.variants) |v| {
                            try variants_list.append(self.alloc, .{
                                .name = try self.alloc.dupe(u8, v.name),
                                .value = null,
                            });
                        }
                    },
                    else => {},
                }

                if (self.hoisted_by_id.get(entity_id)) |hoisted| {
                    for (hoisted.items) |d| {
                        try inner_decls.append(self.alloc, d);
                    }
                }

                return ast.Decl{
                    .enum_decl = .{
                        .name = try self.alloc.dupe(u8, ent.name),
                        .is_pub = is_pub,
                        .variants = try variants_list.toOwnedSlice(self.alloc),
                        .decls = try inner_decls.toOwnedSlice(self.alloc),
                    },
                };
            },
            .fn_ => {
                const fn_d = try self.lowerFnEntity(entity_id, ent);
                return ast.Decl{ .fn_decl = fn_d };
            },
            .const_ => {
                var ty: ?ast.Type = null;
                var init_expr: ast.Expr = ast.Expr{ .lit = .undefined_lit };

                switch (body_kind) {
                    .const_ => |cb| {
                        ty = try self.lowerType(cb.ty);
                        init_expr = try self.lowerExpr(cb.init);
                    },
                    else => {},
                }

                return ast.Decl{
                    .const_decl = .{
                        .name = try self.alloc.dupe(u8, ent.name),
                        .is_pub = is_pub,
                        .ty = ty,
                        .init = init_expr,
                    },
                };
            },
            .static_ => {
                var ty: ?ast.Type = null;
                var init_expr: ast.Expr = ast.Expr{ .lit = .undefined_lit };

                switch (body_kind) {
                    .const_ => |cb| {
                        ty = try self.lowerType(cb.ty);
                        init_expr = try self.lowerExpr(cb.init);
                    },
                    else => {},
                }

                return ast.Decl{
                    .var_decl = .{
                        .name = try self.alloc.dupe(u8, ent.name),
                        .is_pub = is_pub,
                        .is_mut = true,
                        .ty = ty,
                        .init = init_expr,
                    },
                };
            },
            .type_alias => {
                var target_ty: ast.Type = ast.Type{ .void_type = {} };
                switch (body_kind) {
                    .type_alias => |tab| {
                        target_ty = try self.lowerType(tab.target);
                    },
                    else => {},
                }

                const target_name = switch (target_ty) {
                    .named => |n| n,
                    .prim => |p| @tagName(p),
                    else => "type",
                };

                return ast.Decl{
                    .const_decl = .{
                        .name = try self.alloc.dupe(u8, ent.name),
                        .is_pub = is_pub,
                        .ty = null,
                        .init = ast.Expr{ .ident = try self.alloc.dupe(u8, target_name) },
                    },
                };
            },
            .use_ => {
                if (self.ir.graph.useById(entity_id)) |u| {
                    if (u.is_pub_export) {
                        const target_name = if (self.ir.graph.symbol_table.get(u.target)) |te|
                            te.name
                        else
                            "";
                        return ast.Decl{
                            .const_decl = .{
                                .name = try self.alloc.dupe(u8, u.local_name),
                                .is_pub = true,
                                .ty = null,
                                .init = ast.Expr{ .ident = try self.alloc.dupe(u8, target_name) },
                            },
                        };
                    }
                }
                return null;
            },
            .impl_ => {
                // Impl items are hoisted into their target structs/enums; skip at module root
                return null;
            },
            else => return null,
        }
    }

    fn lowerFnEntity(self: *Lowerer, entity_id: ir.spine.EntityId, ent: ir.spine.Entity) !ast.FnDecl {
        const is_pub = switch (ent.visibility) {
            .public => true,
            else => false,
        };

        const body_kind = if (entity_id < self.ir.bodies.bodies.len)
            self.ir.bodies.bodies[entity_id]
        else
            ir.bodies.BodyKind{ .none = {} };

        var params_list: std.ArrayListUnmanaged(ast.FnParam) = .empty;
        var ret_type: ast.Type = ast.Type{ .void_type = {} };
        var fn_block: ?ast.Block = null;

        switch (body_kind) {
            .fn_ => |fb| {
                if (fb.is_allocating) {
                    try params_list.append(self.alloc, .{
                        .name = "allocator",
                        .ty = ast.Type{ .named = "std.mem.Allocator" },
                    });
                }

                for (fb.params) |p| {
                    const p_ty = try self.lowerType(p.ty);
                    try params_list.append(self.alloc, .{
                        .name = try self.alloc.dupe(u8, p.name),
                        .ty = p_ty,
                    });
                }

                ret_type = try self.lowerType(fb.ret);

                if (fb.body < self.ir.bodies.exprs.len) {
                    const expr_node = self.ir.bodies.exprs[fb.body];
                    switch (expr_node.kind) {
                        .block => |be| {
                            fn_block = try self.lowerBlock(be);
                        },
                        else => {
                            const lowered_e = try self.lowerExpr(fb.body);
                            fn_block = ast.Block{
                                .stmts = &.{},
                                .expr = try self.allocExpr(lowered_e),
                            };
                        },
                    }
                }
            },
            else => {},
        }

        return ast.FnDecl{
            .name = try self.alloc.dupe(u8, ent.name),
            .is_pub = is_pub,
            .params = try params_list.toOwnedSlice(self.alloc),
            .ret_type = ret_type,
            .body = fn_block,
        };
    }

    fn lowerStructMethod(self: *Lowerer, m: ir.bodies.StructMethod, struct_name: []const u8) !ast.FnDecl {
        var params_list: std.ArrayListUnmanaged(ast.FnParam) = .empty;

        if (m.receiver) |rec| {
            const self_type = ast.Type{ .named = try self.alloc.dupe(u8, struct_name) };
            const self_type_ptr = try self.allocType(self_type);

            const rec_ty: ast.Type = switch (rec) {
                .ref_ => ast.Type{
                    .ptr = .{
                        .elem = self_type_ptr,
                        .is_const = true,
                        .size = .one,
                    },
                },
                .mut_ref => ast.Type{
                    .ptr = .{
                        .elem = self_type_ptr,
                        .is_const = false,
                        .size = .one,
                    },
                },
                .owned => self_type,
            };

            try params_list.append(self.alloc, .{
                .name = "self",
                .ty = rec_ty,
            });
        }

        if (m.is_allocating) {
            try params_list.append(self.alloc, .{
                .name = "allocator",
                .ty = ast.Type{ .named = "std.mem.Allocator" },
            });
        }

        for (m.params) |p| {
            const p_ty = try self.lowerType(p.ty);
            try params_list.append(self.alloc, .{
                .name = try self.alloc.dupe(u8, p.name),
                .ty = p_ty,
            });
        }

        const ret_type = try self.lowerType(m.ret);

        var fn_block: ?ast.Block = null;
        if (m.body < self.ir.bodies.exprs.len) {
            const expr_node = self.ir.bodies.exprs[m.body];
            switch (expr_node.kind) {
                .block => |be| {
                    fn_block = try self.lowerBlock(be);
                },
                else => {
                    const lowered_e = try self.lowerExpr(m.body);
                    fn_block = ast.Block{
                        .stmts = &.{},
                        .expr = try self.allocExpr(lowered_e),
                    };
                },
            }
        }

        return ast.FnDecl{
            .name = try self.alloc.dupe(u8, m.name),
            .is_pub = switch (m.visibility) {
                .public => true,
                else => false,
            },
            .params = try params_list.toOwnedSlice(self.alloc),
            .ret_type = ret_type,
            .body = fn_block,
        };
    }

    fn lowerTestEntity(self: *Lowerer, entity_id: ir.spine.EntityId, ent: ir.spine.Entity) !?ast.TestDecl {
        const body_kind = if (entity_id < self.ir.bodies.bodies.len)
            self.ir.bodies.bodies[entity_id]
        else
            ir.bodies.BodyKind{ .none = {} };

        var test_block: ast.Block = .{ .stmts = &.{}, .expr = null };

        switch (body_kind) {
            .fn_ => |fb| {
                if (fb.body < self.ir.bodies.exprs.len) {
                    const expr_node = self.ir.bodies.exprs[fb.body];
                    switch (expr_node.kind) {
                        .block => |be| {
                            test_block = try self.lowerBlock(be);
                        },
                        else => {
                            const lowered_e = try self.lowerExpr(fb.body);
                            test_block = ast.Block{
                                .stmts = &.{},
                                .expr = try self.allocExpr(lowered_e),
                            };
                        },
                    }
                }
            },
            else => return null,
        }

        return ast.TestDecl{
            .name = try self.alloc.dupe(u8, ent.name),
            .body = test_block,
        };
    }

    // -------------------------------------------------------------------------
    // Type Lowering
    // -------------------------------------------------------------------------

    pub fn lowerType(self: *Lowerer, ir_ty: ir.types.Type) anyerror!ast.Type {
        // Structural lowering is arena-backed and always safe to retain. The
        // pluggable strategy is consulted only for standard generic name
        // mapping (returns `.named` values — never transient pointers).
        return switch (ir_ty) {
            .prim => |p| ast.Type{ .prim = lowerPrim(p) },
            .slice => |s| ast.Type{
                .slice = .{
                    .elem = try self.allocType(try self.lowerType(s.elem)),
                    .is_const = s.const_,
                },
            },
            .reference => |r| ast.Type{
                .ptr = .{
                    .elem = try self.allocType(try self.lowerType(r.pointee)),
                    .is_const = !r.mut,
                    .size = .one,
                },
            },
            .raw_ptr => |r| ast.Type{
                .ptr = .{
                    .elem = try self.allocType(try self.lowerType(r.pointee)),
                    .is_const = !r.mut,
                    .size = .many,
                },
            },
            .array => |a| ast.Type{
                .array = .{
                    .elem = try self.allocType(try self.lowerType(a.elem)),
                    .len = switch (a.len) {
                        .literal => |n| n,
                        .generic => 0,
                    },
                },
            },
            .option => |opt| ast.Type{
                .opt = try self.allocType(try self.lowerType(opt.*)),
            },
            .result => |r| blk: {
                if (r.is_error_unionable) {
                    const payload_ty = try self.allocType(try self.lowerType(r.ok));
                    break :blk ast.Type{
                        .err_union = .{
                            .err_set = null,
                            .payload = payload_ty,
                        },
                    };
                } else {
                    break :blk ast.Type{ .named = "anyerror" };
                }
            },
            .tuple => |elems| blk: {
                var arr = try self.alloc.alloc(ast.Type, elems.len);
                for (elems, 0..) |e, i| {
                    arr[i] = try self.lowerType(e);
                }
                break :blk ast.Type{ .tuple = arr };
            },
            .path => |p| blk: {
                if (p.segments.len > 0) {
                    const last_seg = p.segments[p.segments.len - 1].name;
                    if (try self.strat.lowerStdGeneric(last_seg, &.{})) |std_ty| {
                        break :blk std_ty;
                    }
                    break :blk ast.Type{ .named = try self.alloc.dupe(u8, last_seg) };
                }
                break :blk ast.Type{ .named = "unknown" };
            },
            .generic_inst => |gi| blk: {
                const decl_name = if (self.ir.graph.symbol_table.get(gi.decl)) |e| e.name else "";
                if (decl_name.len > 0) {
                    if (try self.strat.lowerStdGeneric(decl_name, gi.args.params)) |std_ty| {
                        break :blk std_ty;
                    }
                }
                var params = try self.alloc.alloc(ast.Type, gi.args.params.len);
                for (gi.args.params, 0..) |p, i| {
                    params[i] = try self.lowerType(p);
                }
                break :blk ast.Type{
                    .generic = .{
                        .name = try self.alloc.dupe(u8, decl_name),
                        .params = params,
                    },
                };
            },
            .boxed => |b| try self.lowerType(b.*),
            .fn_ptr => ast.Type{ .named = "fn_ptr" },
            .unsupported => |u| ast.Type{ .named = try self.alloc.dupe(u8, u.message) },
        };
    }

    fn lowerPrim(p: ir.types.Prim) ast.Prim {
        return switch (p) {
            .i8 => .i8,
            .i16 => .i16,
            .i32 => .i32,
            .i64 => .i64,
            .i128 => .i128,
            .u8 => .u8,
            .u16 => .u16,
            .u32 => .u32,
            .u64 => .u64,
            .u128 => .u128,
            .isize => .isize,
            .usize => .usize,
            .f32 => .f32,
            .f64 => .f64,
            .bool => .bool,
            .char => .u32,
            .unit => .void_type,
            .never => .noreturn_type,
        };
    }

    // -------------------------------------------------------------------------
    // Expression Lowering
    // -------------------------------------------------------------------------

    pub fn lowerExpr(self: *Lowerer, expr_id: ir.exprs.NodeId) anyerror!ast.Expr {
        if (expr_id >= self.ir.bodies.exprs.len) {
            return ast.Expr{ .ident = "undefined" };
        }

        const ir_expr = self.ir.bodies.exprs[expr_id];

        return switch (ir_expr.kind) {
            .literal => |lit| switch (lit) {
                .int => |il| ast.Expr{ .lit = .{ .int = il.value } },
                .float => |fl| ast.Expr{ .lit = .{ .float = fl.value } },
                .character => |cl| ast.Expr{ .lit = .{ .char_lit = @intCast(cl.value) } },
                .string => |sl| ast.Expr{ .lit = .{ .str = try self.alloc.dupe(u8, sl.bytes) } },
                .byte_array => |ba| ast.Expr{ .lit = .{ .str = try self.alloc.dupe(u8, ba.items) } },
                .boolean => |b| ast.Expr{ .lit = .{ .bool_lit = b } },
            },
            .path => |pe| blk: {
                if (self.ir.graph.symbol_table.get(pe.def)) |ent| {
                    const name = ent.renamed_to orelse ent.name;
                    break :blk ast.Expr{ .ident = try self.alloc.dupe(u8, name) };
                }
                break :blk ast.Expr{ .ident = "unknown" };
            },
            .block => |be| ast.Expr{ .block = try self.lowerBlock(be) },
            .unit => ast.Expr{ .struct_init = .{ .type_name = null, .fields = &.{} } },
            .if_else => |ie| blk: {
                const cond = try self.allocExpr(try self.lowerExpr(ie.cond));
                const then_expr = try self.allocExpr(ast.Expr{ .block = try self.lowerBlock(ie.then_) });
                const else_expr: ?*const ast.Expr = switch (ie.@"else") {
                    .none => null,
                    .block => |eb| try self.allocExpr(ast.Expr{ .block = try self.lowerBlock(eb) }),
                    .chain => |chain_id| try self.allocExpr(try self.lowerExpr(chain_id)),
                };
                break :blk ast.Expr{
                    .if_expr = .{
                        .cond = cond,
                        .then_body = then_expr,
                        .else_body = else_expr,
                    },
                };
            },
            .if_let => |il| blk: {
                const cond = try self.allocExpr(try self.lowerExpr(il.scrutinee));
                const then_expr = try self.allocExpr(ast.Expr{ .block = try self.lowerBlock(il.then_) });
                const else_expr: ?*const ast.Expr = switch (il.@"else") {
                    .none => null,
                    .block => |eb| try self.allocExpr(ast.Expr{ .block = try self.lowerBlock(eb) }),
                    .chain => |chain_id| try self.allocExpr(try self.lowerExpr(chain_id)),
                };
                break :blk ast.Expr{
                    .if_expr = .{
                        .cond = cond,
                        .then_body = then_expr,
                        .else_body = else_expr,
                    },
                };
            },
            .match => |me| blk: {
                const target = try self.allocExpr(try self.lowerExpr(me.scrutinee));
                var arms = try self.alloc.alloc(ast.MatchArm, me.arms.len);
                for (me.arms, 0..) |arm, i| {
                    var pats = try self.alloc.alloc(ast.Pattern, arm.patterns.len);
                    for (arm.patterns, 0..) |p_id, j| {
                        pats[j] = try self.lowerPattern(p_id);
                    }
                    const body_expr = try self.lowerExpr(arm.body);
                    arms[i] = .{
                        .patterns = pats,
                        .body = body_expr,
                    };
                }
                break :blk ast.Expr{
                    .match_expr = .{
                        .target = target,
                        .arms = arms,
                    },
                };
            },
            .loop_ => |le| blk: {
                const cond = try self.allocExpr(ast.Expr{ .lit = .{ .bool_lit = true } });
                break :blk ast.Expr{
                    .while_expr = .{
                        .cond = cond,
                        .body = try self.lowerBlock(le.body),
                    },
                };
            },
            .while_ => |we| blk: {
                const cond = try self.allocExpr(try self.lowerExpr(we.cond));
                break :blk ast.Expr{
                    .while_expr = .{
                        .cond = cond,
                        .body = try self.lowerBlock(we.body),
                    },
                };
            },
            .for_ => |fe| blk: {
                const input = try self.lowerExpr(fe.iterable);
                var inputs = try self.alloc.alloc(ast.Expr, 1);
                inputs[0] = input;

                var captures_list: std.ArrayListUnmanaged([]const u8) = .empty;
                if (fe.pattern < self.ir.bodies.pats.len) {
                    const pat = self.ir.bodies.pats[fe.pattern];
                    switch (pat.kind) {
                        .binding => |b| try captures_list.append(self.alloc, try self.alloc.dupe(u8, b.name)),
                        else => {},
                    }
                }

                break :blk ast.Expr{
                    .for_expr = .{
                        .inputs = inputs,
                        .captures = try captures_list.toOwnedSlice(self.alloc),
                        .body = try self.lowerBlock(fe.body),
                    },
                };
            },
            .break_ => |be| blk: {
                const val = if (be.value) |v| try self.allocExpr(try self.lowerExpr(v)) else null;
                break :blk ast.Expr{ .break_expr = val };
            },
            .continue_ => ast.Expr{ .continue_expr = {} },
            .call => |c| blk: {
                const callee_name: []const u8 = switch (c.call_kind) {
                    .free => |def_id| if (self.ir.graph.symbol_table.get(def_id)) |e|
                        e.renamed_to orelse e.name
                    else
                        "unknown_fn",
                    .associated => |def_id| if (self.ir.graph.symbol_table.get(def_id)) |e|
                        e.renamed_to orelse e.name
                    else
                        "unknown_assoc",
                    .constructor => |def_id| if (self.ir.graph.symbol_table.get(def_id)) |e|
                        e.renamed_to orelse e.name
                    else
                        "unknown_ctor",
                };

                const callee_expr = ast.Expr{ .ident = try self.alloc.dupe(u8, callee_name) };
                var args = try self.alloc.alloc(ast.Expr, c.args.len);
                for (c.args, 0..) |arg_id, i| {
                    args[i] = try self.lowerExpr(arg_id);
                }

                break :blk ast.Expr{
                    .call = .{
                        .callee = try self.allocExpr(callee_expr),
                        .args = args,
                    },
                };
            },
            .method_call => |mc| blk: {
                const receiver = try self.allocExpr(try self.lowerExpr(mc.receiver));
                const method_name = if (self.ir.graph.symbol_table.get(mc.method)) |e|
                    e.renamed_to orelse e.name
                else
                    "method";

                const field_access = try self.allocExpr(ast.Expr{
                    .field_access = .{
                        .target = receiver,
                        .field_name = try self.alloc.dupe(u8, method_name),
                    },
                });

                var args = try self.alloc.alloc(ast.Expr, mc.args.len);
                for (mc.args, 0..) |arg_id, i| {
                    args[i] = try self.lowerExpr(arg_id);
                }

                break :blk ast.Expr{
                    .call = .{
                        .callee = field_access,
                        .args = args,
                    },
                };
            },
            .struct_lit => |sl| blk: {
                var fields = try self.alloc.alloc(ast.StructInitField, sl.fields.len);
                for (sl.fields, 0..) |fi, i| {
                    fields[i] = .{
                        .name = try self.alloc.dupe(u8, fi.field),
                        .expr = try self.lowerExpr(fi.value),
                    };
                }

                const type_name: ?ast.Type = if (self.ir.graph.symbol_table.get(sl.def)) |e|
                    ast.Type{ .named = try self.alloc.dupe(u8, e.name) }
                else
                    null;

                break :blk ast.Expr{
                    .struct_init = .{
                        .type_name = type_name,
                        .fields = fields,
                    },
                };
            },
            .enum_variant => |ev| blk: {
                const variant_name = try self.alloc.dupe(u8, ev.variant);
                if (ev.tuple_fields.len > 0) {
                    var fields = try self.alloc.alloc(ast.StructInitField, ev.tuple_fields.len);
                    for (ev.tuple_fields, 0..) |tf, i| {
                        fields[i] = .{
                            .name = try std.fmt.allocPrint(self.alloc, "{d}", .{i}),
                            .expr = try self.lowerExpr(tf),
                        };
                    }
                    break :blk ast.Expr{
                        .struct_init = .{
                            .type_name = ast.Type{ .named = variant_name },
                            .fields = fields,
                        },
                    };
                } else {
                    break :blk ast.Expr{ .ident = variant_name };
                }
            },
            .field => |fe| blk: {
                const base = try self.allocExpr(try self.lowerExpr(fe.base));
                break :blk ast.Expr{
                    .field_access = .{
                        .target = base,
                        .field_name = try self.alloc.dupe(u8, fe.field),
                    },
                };
            },
            .index => |ie| blk: {
                const base = try self.allocExpr(try self.lowerExpr(ie.base));
                const idx = try self.allocExpr(try self.lowerExpr(ie.index));
                var args = try self.alloc.alloc(ast.Expr, 2);
                args[0] = base.*;
                args[1] = idx.*;
                break :blk ast.Expr{
                    .builtin = .{
                        .name = "index",
                        .args = args,
                    },
                };
            },
            .binary => |be| blk: {
                const lhs = try self.allocExpr(try self.lowerExpr(be.lhs));
                const rhs = try self.allocExpr(try self.lowerExpr(be.rhs));
                const op_kind: ast.BinOpKind = switch (be.op) {
                    .add => switch (be.overflow) {
                        .checked => .add,
                        .wrapping => .add_wrap,
                        .saturating => .add_sat,
                    },
                    .sub => switch (be.overflow) {
                        .checked => .sub,
                        .wrapping => .sub_wrap,
                        .saturating => .sub_sat,
                    },
                    .mul => switch (be.overflow) {
                        .checked => .mul,
                        .wrapping => .mul_wrap,
                        .saturating => .add,
                    },
                    .div => .div,
                    .rem => .mod,
                    .bit_and => .bit_and,
                    .bit_or => .bit_or,
                    .bit_xor => .bit_xor,
                    .shl => .shl,
                    .shr => .shr,
                    .eq => .equal,
                    .ne => .not_equal,
                    .lt => .less_than,
                    .le => .less_than_equal,
                    .gt => .greater_than,
                    .ge => .greater_than_equal,
                    .boolean_and => .bool_and,
                    .boolean_or => .bool_or,
                };
                break :blk ast.Expr{
                    .bin_op = .{
                        .op = op_kind,
                        .lhs = lhs,
                        .rhs = rhs,
                    },
                };
            },
            .unary => |ue| blk: {
                const operand = try self.allocExpr(try self.lowerExpr(ue.operand));
                const op_kind: ast.UnaryOpKind = switch (ue.op) {
                    .negate => .negate,
                    .logical_not => .bool_not,
                    .bit_not => .bit_not,
                    .deref => .deref,
                    .ref => .addr_of,
                };
                break :blk ast.Expr{
                    .unary_op = .{
                        .op = op_kind,
                        .operand = operand,
                    },
                };
            },
            .assign => ast.Expr{ .unsupported = "assign_expr" },
            .try_ => |te| blk: {
                const operand = try self.allocExpr(try self.lowerExpr(te.inner));
                break :blk ast.Expr{
                    .unary_op = .{
                        .op = .try_op,
                        .operand = operand,
                    },
                };
            },
            .return_ => |re| blk: {
                const val = if (re.value) |v| try self.allocExpr(try self.lowerExpr(v)) else null;
                break :blk ast.Expr{ .return_expr = val };
            },
            .closure, .iterator_chain => ast.Expr{ .unsupported = "deferred" },
            .unsupported => |u| ast.Expr{ .unsupported = try self.alloc.dupe(u8, u.reason) },
        };
    }

    // -------------------------------------------------------------------------
    // Statement Lowering
    // -------------------------------------------------------------------------

    pub fn lowerStmt(self: *Lowerer, stmt_id: ir.exprs.NodeId) anyerror!ast.Stmt {
        if (stmt_id >= self.ir.bodies.stmts.len) {
            const null_expr = try self.allocExpr(ast.Expr{ .lit = .undefined_lit });
            return ast.Stmt{ .expr_stmt = null_expr };
        }

        const ir_stmt = self.ir.bodies.stmts[stmt_id];

        return switch (ir_stmt.kind) {
            .let => |ls| blk: {
                var name: []const u8 = "_";
                var is_mut = false;
                if (ls.pattern < self.ir.bodies.pats.len) {
                    const pat = self.ir.bodies.pats[ls.pattern];
                    switch (pat.kind) {
                        .binding => |b| {
                            name = b.name;
                            is_mut = b.mutable;
                        },
                        else => {},
                    }
                }

                const init_expr: ast.Expr = if (ls.init) |i_id|
                    try self.lowerExpr(i_id)
                else
                    ast.Expr{ .lit = .undefined_lit };

                const ty: ?ast.Type = if (ls.ty) |t_id|
                    if (t_id < self.ir.types.len) try self.lowerType(self.ir.types[t_id]) else null
                else
                    null;

                break :blk ast.Stmt{
                    .let_stmt = .{
                        .name = try self.alloc.dupe(u8, name),
                        .ty = ty,
                        .init = init_expr,
                        .is_mut = is_mut,
                    },
                };
            },
            .let_else => |le| blk: {
                var name: []const u8 = "_";
                if (le.pattern < self.ir.bodies.pats.len) {
                    const pat = self.ir.bodies.pats[le.pattern];
                    switch (pat.kind) {
                        .binding => |b| {
                            name = b.name;
                        },
                        else => {},
                    }
                }
                const init_expr = try self.lowerExpr(le.init);
                break :blk ast.Stmt{
                    .let_stmt = .{
                        .name = try self.alloc.dupe(u8, name),
                        .init = init_expr,
                        .is_mut = false,
                    },
                };
            },
            .expr => |e_id| blk: {
                const expr_ptr = try self.allocExpr(try self.lowerExpr(e_id));
                break :blk ast.Stmt{ .expr_stmt = expr_ptr };
            },
            .item => blk: {
                const expr_ptr = try self.allocExpr(ast.Expr{ .unsupported = "nested_item" });
                break :blk ast.Stmt{ .expr_stmt = expr_ptr };
            },
        };
    }

    // -------------------------------------------------------------------------
    // Pattern Lowering
    // -------------------------------------------------------------------------

    pub fn lowerPattern(self: *Lowerer, pat_id: ir.exprs.NodeId) anyerror!ast.Pattern {
        if (pat_id >= self.ir.bodies.pats.len) {
            return ast.Pattern.wildcard;
        }

        const ir_pat = self.ir.bodies.pats[pat_id];

        return switch (ir_pat.kind) {
            .wildcard => ast.Pattern.wildcard,
            .binding => |b| ast.Pattern{ .binding = try self.alloc.dupe(u8, b.name) },
            .literal => |l| switch (l) {
                .int => |il| ast.Pattern{ .lit = .{ .int = il.value } },
                .float => |fl| ast.Pattern{ .lit = .{ .float = fl.value } },
                .character => |cl| ast.Pattern{ .lit = .{ .char_lit = @intCast(cl.value) } },
                .string => |sl| ast.Pattern{ .lit = .{ .str = try self.alloc.dupe(u8, sl.bytes) } },
                .byte_array => |ba| ast.Pattern{ .lit = .{ .str = try self.alloc.dupe(u8, ba.items) } },
                .boolean => |b| ast.Pattern{ .lit = .{ .bool_lit = b } },
            },
            .path => |pp| blk: {
                if (pp.variant) |v| {
                    break :blk ast.Pattern{ .enum_literal = try self.alloc.dupe(u8, v) };
                }
                if (self.ir.graph.symbol_table.get(pp.def)) |ent| {
                    break :blk ast.Pattern{ .enum_literal = try self.alloc.dupe(u8, ent.name) };
                }
                break :blk ast.Pattern.wildcard;
            },
            .tuple => |tp| blk: {
                var pats = try self.alloc.alloc(ast.Pattern, tp.elements.len);
                for (tp.elements, 0..) |elem_id, i| {
                    pats[i] = try self.lowerPattern(elem_id);
                }
                break :blk ast.Pattern{ .tuple = pats };
            },
            .struct_pat => |sp| blk: {
                const struct_name = if (self.ir.graph.symbol_table.get(sp.def)) |ent|
                    try self.alloc.dupe(u8, ent.name)
                else
                    null;
                var fields = try self.alloc.alloc(ast.StructPatternField, sp.fields.len);
                for (sp.fields, 0..) |f, i| {
                    const f_pat = if (f.pat) |p_id|
                        try self.lowerPattern(p_id)
                    else
                        ast.Pattern{ .binding = try self.alloc.dupe(u8, f.field) };
                    fields[i] = .{
                        .name = try self.alloc.dupe(u8, f.field),
                        .pat = f_pat,
                    };
                }
                break :blk ast.Pattern{
                    .struct_pat = .{
                        .name = struct_name,
                        .fields = fields,
                    },
                };
            },
            .@"or" => |op| blk: {
                if (op.alternatives.len > 0) {
                    break :blk try self.lowerPattern(op.alternatives[0]);
                }
                break :blk ast.Pattern.wildcard;
            },
            else => ast.Pattern.wildcard,
        };
    }

    // -------------------------------------------------------------------------
    // Block Lowering
    // -------------------------------------------------------------------------

    pub fn lowerBlock(self: *Lowerer, be: ir.exprs.BlockExpr) anyerror!ast.Block {
        var stmts = try self.alloc.alloc(ast.Stmt, be.statements.len);
        for (be.statements, 0..) |stmt_id, i| {
            stmts[i] = try self.lowerStmt(stmt_id);
        }

        const tail_expr = if (be.tail) |t_id|
            try self.allocExpr(try self.lowerExpr(t_id))
        else
            null;

        const label = if (be.labelled) |l| try self.alloc.dupe(u8, l) else null;

        return ast.Block{
            .label = label,
            .stmts = stmts,
            .expr = tail_expr,
        };
    }
};
