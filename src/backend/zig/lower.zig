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

const MethodTypeContext = struct {
    struct_name: []const u8,
    generic_params: []const ast.GenericParam,
};

const Lowerer = struct {
    alloc: std.mem.Allocator,
    ir: *const ir.RustIR,
    strat: strategy.LoweringStrategy,
    def_strat_inst: default_strat.DefaultStrategy = .{},
    current_module_id: ?ir.spine.EntityId = null,
    /// The inherent struct/enum/union whose method body is being lowered.
    current_struct_id: ?ir.spine.EntityId = null,
    /// An explicit floating-point function result supplies the expected type
    /// for nested arithmetic whose operands lack inferred type metadata.
    float_context: bool = false,

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
                    // A method already registered on the target's StructBody
                    // is rendered directly from `StructBody.methods` by
                    // `lowerEntityDecl`; skip re-hoisting its `.fn_` entity to
                    // avoid a duplicate declaration in the emitted struct.
                    if (self.isStructMethodRegistered(tid, ent.name)) continue;
                    // Both inherent (`impl Target`) and trait (`impl Trait for
                    // Target`) blocks collect methods onto the target here.
                    // Guard by method name so an identical name supplied by a
                    // second impl block is not appended twice.
                    if (self.isHoistedMethodRegistered(tid, ent.name)) continue;
                    const fn_decl = try self.lowerFnEntity(entity_id, ent);
                    const decl = ast.Decl{ .fn_decl = fn_decl };
                    var list = self.hoisted_by_id.get(tid) orelse std.ArrayListUnmanaged(ast.Decl).empty;
                    try list.append(self.alloc, decl);
                    try self.hoisted_by_id.put(self.alloc, tid, list);
                }
            }
        }
    }

    /// True when the target entity carries a `.struct_` body whose
    /// `StructBody.methods` already registers a method named `name`.
    fn isStructMethodRegistered(self: *Lowerer, tid: ir.spine.EntityId, name: []const u8) bool {
        if (tid >= self.ir.bodies.bodies.len) return false;
        switch (self.ir.bodies.bodies[tid]) {
            .struct_ => |sb| {
                for (sb.methods) |m| {
                    if (std.mem.eql(u8, m.name, name)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// True when a hoisted declaration already exists for `name` on `tid`.
    fn isHoistedMethodRegistered(self: *Lowerer, tid: ir.spine.EntityId, name: []const u8) bool {
        if (self.hoisted_by_id.get(tid)) |list| {
            for (list.items) |d| {
                if (d == .fn_decl and std.mem.eql(u8, d.fn_decl.name, name)) return true;
            }
        }
        return false;
    }

    fn appendImport(
        self: *Lowerer,
        imports: *std.ArrayListUnmanaged(ast.Import),
        local_name: []const u8,
        module_or_path: []const u8,
        is_pub: bool,
    ) !void {
        for (imports.items) |existing| {
            if (std.mem.eql(u8, existing.local_name, local_name) and
                std.mem.eql(u8, existing.module_or_path, module_or_path))
            {
                return;
            }
        }
        try imports.append(self.alloc, .{
            .local_name = try self.alloc.dupe(u8, local_name),
            .module_or_path = try self.alloc.dupe(u8, module_or_path),
            .is_pub = is_pub,
        });
    }

    /// Find the module row for a module entity. Module rows are dense, while
    /// symbol entities also contain non-module items, so their ids can differ.
    fn moduleForEntity(self: *const Lowerer, entity_id: ir.spine.EntityId) ?ir.graph.Module {
        const entity = self.ir.graph.symbol_table.get(entity_id) orelse {
            return self.ir.graph.module(entity_id);
        };

        // Some hand-built IR fixtures contain module rows without matching
        // module entities. Preserve the dense row lookup for those graphs,
        // but prefer a name/parent match when the entity table is complete.
        if (self.ir.graph.module(entity_id)) |dense_module| {
            var has_matching_module_entity = false;
            for (self.ir.graph.symbol_table.entities.items) |candidate| {
                if (candidate.kind != .module) continue;
                if (candidate.parent == dense_module.parent and
                    std.mem.eql(u8, candidate.name, dense_module.name))
                {
                    has_matching_module_entity = true;
                    break;
                }
            }
            if (!has_matching_module_entity) return dense_module;
            if (dense_module.parent == entity.parent and
                std.mem.eql(u8, dense_module.name, entity.name))
            {
                return dense_module;
            }
        }

        for (self.ir.graph.modules.items) |module| {
            if (module.parent == entity.parent and std.mem.eql(u8, module.name, entity.name)) {
                return module;
            }
        }
        return null;
    }

    fn moduleEntityId(self: *const Lowerer, module: ir.graph.Module) ?ir.spine.EntityId {
        for (self.ir.graph.symbol_table.entities.items) |entity| {
            if (entity.kind != .module) continue;
            if (entity.parent == module.parent and std.mem.eql(u8, entity.name, module.name)) {
                return entity.id;
            }
        }
        return null;
    }

    /// Return the generated source path for a module. The Rust module ancestry
    /// forms the directory hierarchy so equal leaf names under different
    /// parents cannot collide.
    fn moduleFilePath(self: *Lowerer, module: ir.graph.Module) ![]const u8 {
        if (module.kind == .root or module.is_crate) {
            return self.alloc.dupe(u8, "src/root.zig");
        }

        var components: std.ArrayListUnmanaged([]const u8) = .empty;
        defer components.deinit(self.alloc);

        var current = module;
        var remaining = self.ir.graph.modules.items.len + 1;
        while (current.kind != .root and !current.is_crate) {
            if (remaining == 0) return error.ModuleHierarchyCycle;
            remaining -= 1;

            if (current.name.len > 0) {
                try components.append(self.alloc, current.name);
            }
            const parent_id = current.parent orelse break;
            current = self.moduleForEntity(parent_id) orelse {
                return error.ModuleParentMissing;
            };
        }

        if (components.items.len == 0) {
            return self.alloc.dupe(u8, "src/root.zig");
        }

        var path: std.ArrayListUnmanaged(u8) = .empty;
        errdefer path.deinit(self.alloc);
        try path.appendSlice(self.alloc, "src/");

        var index = components.items.len;
        while (index > 0) {
            index -= 1;
            try path.appendSlice(self.alloc, components.items[index]);
            if (index > 0) try path.append(self.alloc, '/');
        }
        try path.appendSlice(self.alloc, ".zig");
        return path.toOwnedSlice(self.alloc);
    }

    /// Return the target module path relative to the importing module file.
    fn moduleImportPath(
        self: *Lowerer,
        importing_module: ir.graph.Module,
        target_module: ir.graph.Module,
    ) ![]const u8 {
        const importing_path = try self.moduleFilePath(importing_module);
        defer self.alloc.free(importing_path);
        const target_path = try self.moduleFilePath(target_module);
        defer self.alloc.free(target_path);

        const importing_dir = std.fs.path.dirname(importing_path) orelse ".";
        const relative_path = try std.fs.path.relativePosix(
            self.alloc,
            ".",
            importing_dir,
            target_path,
        );
        if (relative_path.len > 0 and relative_path[0] == '.') {
            return relative_path;
        }
        defer self.alloc.free(relative_path);
        return std.fmt.allocPrint(self.alloc, "./{s}", .{relative_path});
    }

    /// Add the import required by a sibling path or call.
    fn appendUseSiblingImport(
        self: *Lowerer,
        imports: *std.ArrayListUnmanaged(ast.Import),
        current_mod_id: ir.spine.EntityId,
        use_id: ir.spine.EntityId,
    ) !void {
        const use_decl = self.ir.graph.useById(use_id) orelse return;
        if (!self.useHasLowerableTarget(use_decl)) return;
        if (use_decl.kind == .glob) return;

        const target = self.ir.graph.symbol_table.get(use_decl.target) orelse return;
        const parent_id = if (target.kind == .module)
            target.id
        else
            target.parent orelse return;
        if (parent_id == current_mod_id or parent_id == 0) return;

        const parent_module = self.moduleForEntity(parent_id) orelse return;
        if (parent_module.name.len == 0 or parent_module.is_extern) return;
        const current_module = self.moduleForEntity(current_mod_id) orelse return;
        const module_path = try self.moduleImportPath(current_module, parent_module);
        defer self.alloc.free(module_path);
        const parent_entity = self.ir.graph.symbol_table.get(parent_id) orelse return;
        try self.appendImport(
            imports,
            parent_module.name,
            module_path,
            use_decl.is_pub_export and parent_entity.visibility == .public,
        );
    }

    fn owningModuleEntity(self: *const Lowerer, entity_id: ir.spine.EntityId) ?ir.spine.EntityId {
        var current: ?ir.spine.EntityId = entity_id;
        while (current) |id| {
            const entity = self.ir.graph.symbol_table.get(id) orelse return null;
            if (entity.kind == .module) return id;
            current = entity.parent;
        }
        return null;
    }

    /// Return the nominal type that owns an inherent method entity.
    fn inherentStructForEntity(
        self: *const Lowerer,
        entity_id: ir.spine.EntityId,
    ) ?ir.spine.EntityId {
        const entity = self.ir.graph.symbol_table.get(entity_id) orelse return null;
        if (entity.kind != .fn_) return null;

        var parent_id = entity.parent;
        while (parent_id) |id| {
            const parent = self.ir.graph.symbol_table.get(id) orelse return null;
            switch (parent.kind) {
                .struct_, .enum_, .union_ => return id,
                .impl_ => {
                    // An impl whose name contains " for " is a trait impl.
                    // Trait methods are not inherent members of the target.
                    if (std.mem.indexOf(u8, parent.name, " for ") != null) return null;
                    const target_id = parent.parent orelse return null;
                    const target = self.ir.graph.symbol_table.get(target_id) orelse return null;
                    switch (target.kind) {
                        .struct_, .enum_, .union_ => return target_id,
                        else => parent_id = target.parent,
                    }
                },
                else => parent_id = parent.parent,
            }
        }
        return null;
    }

    /// Qualify an inherent method with its type namespace. Methods called from
    /// their own struct use `Self`; calls from another scope use the type name.
    fn qualifyInherentMethod(
        self: *Lowerer,
        entity_id: ir.spine.EntityId,
        resolved: ast.Expr,
    ) !ast.Expr {
        const owner_id = self.inherentStructForEntity(entity_id) orelse return resolved;
        const owner = self.ir.graph.symbol_table.get(owner_id) orelse return resolved;
        const owner_name = owner.renamed_to orelse owner.name;
        const target_name = if (self.current_struct_id) |current_id|
            if (current_id == owner_id) "Self" else owner_name
        else
            owner_name;
        const entity = self.ir.graph.symbol_table.get(entity_id) orelse return resolved;
        const name = entity.renamed_to orelse entity.name;
        const target = try self.allocExpr(.{
            .ident = try self.alloc.dupe(u8, target_name),
        });
        return ast.Expr{ .field_access = .{
            .target = target,
            .field_name = try self.alloc.dupe(u8, name),
        } };
    }

    /// Emit a resolved entity as a bare name in its module, or as
    /// `module.name` when the target belongs to another translated module.
    fn lowerResolvedEntity(self: *Lowerer, def: ir.spine.EntityId) !ast.Expr {
        const entity = self.ir.graph.symbol_table.get(def) orelse {
            return ast.Expr{ .ident = "unknown" };
        };
        const name = entity.renamed_to orelse entity.name;
        const owner = self.owningModuleEntity(def) orelse {
            return ast.Expr{ .ident = try self.alloc.dupe(u8, name) };
        };
        if (self.current_module_id == null or self.current_module_id.? == owner) {
            return ast.Expr{ .ident = try self.alloc.dupe(u8, name) };
        }
        const module = self.moduleForEntity(owner) orelse {
            return ast.Expr{ .ident = try self.alloc.dupe(u8, name) };
        };
        if (module.name.len == 0) {
            return ast.Expr{ .ident = try self.alloc.dupe(u8, name) };
        }
        const target = try self.allocExpr(.{ .ident = try self.alloc.dupe(u8, module.name) });
        return ast.Expr{ .field_access = .{
            .target = target,
            .field_name = try self.alloc.dupe(u8, name),
        } };
    }

    /// Register the module that owns a qualified public re-export.
    fn appendUseModuleImport(
        self: *Lowerer,
        imports: *std.ArrayListUnmanaged(ast.Import),
        current_mod_id: ir.spine.EntityId,
        use_id: ir.spine.EntityId,
    ) !void {
        const use_decl = self.ir.graph.useById(use_id) orelse return;
        if (!use_decl.is_pub_export) return;
        if (use_decl.local_name.len == 0 or std.mem.eql(u8, use_decl.local_name, "_")) return;
        if (use_decl.kind == .glob) return;

        const target = self.ir.graph.symbol_table.get(use_decl.target) orelse return;
        const parent_id = target.parent orelse return;
        if (parent_id == current_mod_id or parent_id == 0) return;
        const parent_module = self.moduleForEntity(parent_id) orelse return;
        if (parent_module.name.len == 0 or parent_module.is_extern) return;
        const parent_entity = self.ir.graph.symbol_table.get(parent_id) orelse return;
        const current_module = self.moduleForEntity(current_mod_id) orelse return;
        const module_path = try self.moduleImportPath(current_module, parent_module);
        defer self.alloc.free(module_path);
        try self.appendImport(
            imports,
            parent_module.name,
            module_path,
            parent_entity.visibility == .public,
        );
    }

    fn lowerModule(self: *Lowerer, mod: ir.graph.Module) !ast.File {
        const file_path = try self.moduleFilePath(mod);

        const current_mod_id = self.moduleEntityId(mod) orelse mod.id;

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

            if (ent.kind == .module) {
                const child_mod = self.moduleForEntity(item_id) orelse continue;
                const module_path = try self.moduleImportPath(mod, child_mod);
                defer self.alloc.free(module_path);
                try self.appendImport(
                    &imports_list,
                    child_mod.name,
                    module_path,
                    ent.visibility == .public,
                );
                continue;
            }

            if (ent.kind == .use_) {
                const use_decl = self.ir.graph.useById(item_id) orelse continue;
                if (!self.useHasLowerableTarget(use_decl)) continue;
                try self.appendUseModuleImport(&imports_list, current_mod_id, item_id);
                try self.appendUseSiblingImport(&imports_list, current_mod_id, item_id);
            }
            if (ent.kind == .fn_ and (std.mem.startsWith(u8, ent.name, "test_") or std.mem.eql(u8, ent.name, "test"))) {
                if (try self.lowerTestEntity(item_id, ent)) |td| {
                    try tests_list.append(self.alloc, td);
                    continue;
                }
            }

            if (try self.lowerEntityDecl(item_id, ent, current_mod_id)) |decl| {
                try decls_list.append(self.alloc, decl);
            }
        }

        const imports = try imports_list.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(imports);
        const decls = try decls_list.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(decls);
        const tests = try tests_list.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(tests);

        return ast.File{
            .path = file_path,
            .imports = imports,
            .decls = decls,
            .tests = tests,
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
            if (ent.kind == .use_) {
                const use_decl = self.ir.graph.useById(entity_id) orelse continue;
                if (!self.useHasLowerableTarget(use_decl)) continue;
                try self.appendUseModuleImport(&imports_list, 0, entity_id);
                try self.appendUseSiblingImport(&imports_list, 0, entity_id);
            }

            if (ent.kind == .fn_ and (std.mem.startsWith(u8, ent.name, "test_") or std.mem.eql(u8, ent.name, "test"))) {
                if (try self.lowerTestEntity(entity_id, ent)) |td| {
                    try tests_list.append(self.alloc, td);
                    continue;
                }
            }

            if (try self.lowerEntityDecl(entity_id, ent, 0)) |decl| {
                try decls_list.append(self.alloc, decl);
            }
        }

        const imports = try imports_list.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(imports);
        const decls = try decls_list.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(decls);
        const tests = try tests_list.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(tests);

        return ast.File{
            .path = "src/root.zig",
            .imports = imports,
            .decls = decls,
            .tests = tests,
        };
    }

    fn useHasLowerableTarget(self: *const Lowerer, use_decl: ir.graph.UseDecl) bool {
        if (use_decl.local_name.len == 0 or std.mem.eql(u8, use_decl.local_name, "_")) {
            return false;
        }

        const use_entity = self.ir.graph.symbol_table.get(use_decl.id) orelse return false;
        if (use_entity.kind != .use_ or use_entity.resolved == null) return false;

        const target = self.ir.graph.symbol_table.get(use_decl.target) orelse return false;
        if (target.name.len == 0 or std.mem.eql(u8, target.name, "_")) return false;
        if (target.kind == .extern_crate) return false;

        if (target.parent) |parent_id| {
            if (self.moduleForEntity(parent_id)) |parent_module| {
                if (parent_module.is_extern) return false;
            }
        }

        return true;
    }

    fn lowerEntityDecl(self: *Lowerer, entity_id: ir.spine.EntityId, ent: ir.spine.Entity, current_mod_id: ?ir.spine.EntityId) !?ast.Decl {
        const previous_module_id = self.current_module_id;
        self.current_module_id = current_mod_id;
        defer self.current_module_id = previous_module_id;
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
                const previous_struct_id = self.current_struct_id;
                self.current_struct_id = entity_id;
                defer self.current_struct_id = previous_struct_id;
                var fields_list: std.ArrayListUnmanaged(ast.StructField) = .empty;
                var inner_decls: std.ArrayListUnmanaged(ast.Decl) = .empty;
                var generic_params_list: std.ArrayListUnmanaged(ast.GenericParam) = .empty;

                switch (body_kind) {
                    .struct_ => |sb| {
                        if (sb.generic_params.len > 0) {
                            for (sb.generic_params) |gp| {
                                try generic_params_list.append(self.alloc, .{
                                    .name = try self.alloc.dupe(u8, gp),
                                    .is_comptime = true,
                                    .ty = null,
                                });
                            }
                        } else {
                            for (sb.fields) |f| {
                                try self.collectGenericTypeParams(f.ty, &generic_params_list);
                            }
                        }

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
                            const m_decl = try self.lowerStructMethod(
                                m,
                                ent.name,
                                generic_params_list.items,
                            );
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

                const fields = try fields_list.toOwnedSlice(self.alloc);
                errdefer self.alloc.free(fields);
                const decls = try inner_decls.toOwnedSlice(self.alloc);
                errdefer self.alloc.free(decls);
                const generic_params = try generic_params_list.toOwnedSlice(self.alloc);
                errdefer self.alloc.free(generic_params);

                return ast.Decl{
                    .struct_decl = .{
                        .name = try self.alloc.dupe(u8, ent.name),
                        .is_pub = is_pub,
                        .fields = fields,
                        .decls = decls,
                        .generic_params = generic_params,
                    },
                };
            },
            .enum_ => {
                var variants_list: std.ArrayListUnmanaged(ast.EnumVariant) = .empty;
                var union_fields: std.ArrayListUnmanaged(ast.UnionField) = .empty;
                var inner_decls: std.ArrayListUnmanaged(ast.Decl) = .empty;
                var is_data_carrying = false;

                switch (body_kind) {
                    .enum_ => |eb| {
                        if (eb.kind == .data) is_data_carrying = true;
                        for (eb.variants) |v| {
                            if (is_data_carrying) {
                                var v_ty: ast.Type = ast.Type{ .void_type = {} };
                                switch (v.fields) {
                                    .none => {
                                        v_ty = ast.Type{ .void_type = {} };
                                    },
                                    .tuple => |tup| {
                                        if (tup.len == 1) {
                                            v_ty = try self.lowerType(tup[0]);
                                        } else if (tup.len > 1) {
                                            v_ty = try self.lowerType(ir.types.Type{ .tuple = tup });
                                        }
                                    },
                                    .named => |flds| {
                                        var sf_list: std.ArrayListUnmanaged(ast.StructField) = .empty;
                                        for (flds) |f| {
                                            const f_ty = try self.lowerType(f.ty);
                                            try sf_list.append(self.alloc, .{
                                                .name = try self.alloc.dupe(u8, f.name),
                                                .ty = f_ty,
                                            });
                                        }
                                        v_ty = ast.Type{
                                            .anon_struct = .{
                                                .fields = try sf_list.toOwnedSlice(self.alloc),
                                            },
                                        };
                                    },
                                }
                                try union_fields.append(self.alloc, .{
                                    .name = try self.alloc.dupe(u8, v.name),
                                    .ty = v_ty,
                                });
                            } else {
                                try variants_list.append(self.alloc, .{
                                    .name = try self.alloc.dupe(u8, v.name),
                                    .value = null,
                                });
                            }
                        }
                    },
                    else => {},
                }

                if (self.hoisted_by_id.get(entity_id)) |hoisted| {
                    for (hoisted.items) |d| {
                        try inner_decls.append(self.alloc, d);
                    }
                }

                if (is_data_carrying) {
                    const fields = try union_fields.toOwnedSlice(self.alloc);
                    errdefer self.alloc.free(fields);
                    const decls = try inner_decls.toOwnedSlice(self.alloc);
                    errdefer self.alloc.free(decls);

                    return ast.Decl{
                        .union_decl = .{
                            .name = try self.alloc.dupe(u8, ent.name),
                            .is_pub = is_pub,
                            .tag_type = ast.Type{ .named = "enum" },
                            .fields = fields,
                            .decls = decls,
                        },
                    };
                }

                const variants = try variants_list.toOwnedSlice(self.alloc);
                errdefer self.alloc.free(variants);
                const decls = try inner_decls.toOwnedSlice(self.alloc);
                errdefer self.alloc.free(decls);

                return ast.Decl{
                    .enum_decl = .{
                        .name = try self.alloc.dupe(u8, ent.name),
                        .is_pub = is_pub,
                        .variants = variants,
                        .decls = decls,
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

                var init_expr: ast.Expr = ast.Expr{ .ident = "type" };
                switch (target_ty) {
                    .named => |n| {
                        init_expr = ast.Expr{ .ident = try self.alloc.dupe(u8, n) };
                    },
                    .generic => |g| {
                        var arg_exprs = try self.alloc.alloc(ast.Expr, g.params.len);
                        for (g.params, 0..) |p, i| {
                            arg_exprs[i] = switch (p) {
                                .named => |pn| ast.Expr{ .ident = try self.alloc.dupe(u8, pn) },
                                .prim => |pp| ast.Expr{ .ident = try self.alloc.dupe(u8, @tagName(pp)) },
                                else => ast.Expr{ .ident = "anyopaque" },
                            };
                        }
                        init_expr = ast.Expr{
                            .call = .{
                                .callee = try self.allocExpr(ast.Expr{ .ident = try self.alloc.dupe(u8, g.name) }),
                                .args = arg_exprs,
                            },
                        };
                    },
                    .prim => |p| {
                        init_expr = ast.Expr{ .ident = try self.alloc.dupe(u8, @tagName(p)) };
                    },
                    else => {},
                }

                return ast.Decl{
                    .const_decl = .{
                        .name = try self.alloc.dupe(u8, ent.name),
                        .is_pub = is_pub,
                        .ty = null,
                        .init = init_expr,
                    },
                };
            },
            .use_ => {
                const use_decl = self.ir.graph.useById(entity_id) orelse return null;
                if (!use_decl.is_pub_export) return null;
                if (!self.useHasLowerableTarget(use_decl)) return null;
                switch (use_decl.kind) {
                    .glob => return null,
                    else => {},
                }

                const target_entity = self.ir.graph.symbol_table.get(use_decl.target) orelse return null;
                var init_expr: ?ast.Expr = null;

                if (target_entity.parent) |parent_id| {
                    const cur_mod_id = current_mod_id orelse 0;
                    if (parent_id != cur_mod_id and parent_id != 0) {
                        const mod_name = if (self.moduleForEntity(parent_id)) |pm|
                            pm.name
                        else if (self.ir.graph.symbol_table.get(parent_id)) |pe|
                            pe.name
                        else
                            "";
                        if (mod_name.len > 0) {
                            const target_name = try self.alloc.dupe(u8, mod_name);
                            errdefer self.alloc.free(target_name);
                            const target = try self.allocExpr(ast.Expr{ .ident = target_name });
                            errdefer self.alloc.destroy(target);
                            const field_name = try self.alloc.dupe(u8, target_entity.name);
                            errdefer self.alloc.free(field_name);
                            init_expr = ast.Expr{
                                .field_access = .{
                                    .target = target,
                                    .field_name = field_name,
                                },
                            };
                        }
                    }
                }

                if (init_expr == null) {
                    const cur_mod_id = current_mod_id orelse 0;
                    const target_parent = target_entity.parent orelse 0;
                    if (target_parent == cur_mod_id and
                        std.mem.eql(u8, use_decl.local_name, target_entity.name))
                    {
                        return null;
                    }
                    init_expr = ast.Expr{ .ident = try self.alloc.dupe(u8, target_entity.name) };
                }

                return ast.Decl{
                    .const_decl = .{
                        .name = try self.alloc.dupe(u8, use_decl.local_name),
                        .is_pub = true,
                        .ty = null,
                        .init = init_expr.?,
                    },
                };
            },
            .impl_ => {
                // Impl items are hoisted into their target structs/enums; skip at module root
                return null;
            },
            else => return null,
        }
    }

    fn appendFunctionGenericParams(
        self: *Lowerer,
        generic_params: []const []const u8,
        params: *std.ArrayListUnmanaged(ast.FnParam),
    ) !void {
        for (generic_params) |generic_name| {
            try params.append(self.alloc, .{
                .name = try self.alloc.dupe(u8, generic_name),
                .ty = .{ .named = "type" },
                .is_comptime = true,
            });
        }
    }

    fn lowerFnEntity(self: *Lowerer, entity_id: ir.spine.EntityId, ent: ir.spine.Entity) !ast.FnDecl {
        const previous_module_id = self.current_module_id;
        self.current_module_id = self.owningModuleEntity(entity_id) orelse previous_module_id;
        defer self.current_module_id = previous_module_id;
        const previous_struct_id = self.current_struct_id;
        self.current_struct_id = self.inherentStructForEntity(entity_id) orelse previous_struct_id;
        defer self.current_struct_id = previous_struct_id;
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
                try self.appendFunctionGenericParams(fb.generic_params, &params_list);
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

                // Explicit Rust `-> T` (including `-> ()`) wins. Only when the
                // return type was left implicit (unit) do we try to infer a
                // concrete type from the tail expression so the emitted fn
                // carries a real `ret_type` (e.g. `origin() -> Point`,
                // `area(s) -> f64`).
                const effective_ret = if (fb.ret == .prim and fb.ret.prim == .unit)
                    if (self.inferTailReturnType(fb.body)) |t| t else fb.ret
                else
                    fb.ret;
                ret_type = try self.lowerType(effective_ret);
                const previous_float_context = self.float_context;
                self.float_context = isFloatType(effective_ret);
                defer self.float_context = previous_float_context;

                if (fb.body < self.ir.bodies.exprs.len) {
                    const expr_node = self.ir.bodies.exprs[fb.body];
                    switch (expr_node.kind) {
                        .block => |be| {
                            var body = try self.lowerBlock(be);
                            switch (ret_type) {
                                .void_type => {},
                                else => promoteTrailingMatch(&body),
                            }
                            fn_block = body;
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

    /// Tree-sitter represents a final Rust match as an expression statement.
    /// Restore value position when the function has a non-void return type.
    fn promoteTrailingMatch(block: *ast.Block) void {
        if (block.expr != null) return;
        if (block.stmts.len == 0) return;

        const tail = switch (block.stmts[block.stmts.len - 1]) {
            .expr_stmt => |expr| expr,
            else => return,
        };
        if (tail.* != .match_expr) return;

        block.stmts = block.stmts[0 .. block.stmts.len - 1];
        block.expr = tail;
    }

    /// Infer a concrete return type from a function body's tail expression when
    /// the return type was left implicit (Rust `-> ()` desugars to unit). Used
    /// only to surface an accurate `ret_type` on the emitted fn; never attempts
    /// full type inference. Returns `null` when the tail is unit/empty or an
    /// explicit `return ...;` statement owns the value (the statement set has
    /// no tail).
    fn inferTailReturnType(self: *Lowerer, body: ir.exprs.NodeId) ?ir.types.Type {
        if (body >= self.ir.bodies.exprs.len) return null;
        const tail = switch (self.ir.bodies.exprs[body].kind) {
            .block => |be| blk: {
                if (be.tail) |tail_id| {
                    if (tail_id >= self.ir.bodies.exprs.len) return null;
                    break :blk tail_id;
                }
                if (be.statements.len == 0) return null;

                const stmt_id = be.statements[be.statements.len - 1];
                if (stmt_id >= self.ir.bodies.stmts.len) return null;
                break :blk switch (self.ir.bodies.stmts[stmt_id].kind) {
                    .expr => |expr_id| expr_id,
                    else => return null,
                };
            },
            else => body,
        };
        if (tail >= self.ir.bodies.exprs.len) return null;

        const e = self.ir.bodies.exprs[tail];
        // A wired concerete type annotation on the tail expr is authoritative.
        if (e.ty) |ty_id| {
            if (ty_id < self.ir.types.len) {
                const ct = self.ir.types[ty_id];
                if (ct != .unsupported) return ct;
            }
        }

        return switch (e.kind) {
            .literal => |lit| switch (lit) {
                .int => |il| blk: {
                    const nm = il.ty_suffix orelse break :blk .{ .prim = .i32 };
                    const prim: ir.types.Prim = if (std.mem.eql(u8, nm, "i8"))
                        .i8
                    else if (std.mem.eql(u8, nm, "i16"))
                        .i16
                    else if (std.mem.eql(u8, nm, "i32"))
                        .i32
                    else if (std.mem.eql(u8, nm, "i64"))
                        .i64
                    else if (std.mem.eql(u8, nm, "i128"))
                        .i128
                    else if (std.mem.eql(u8, nm, "isize"))
                        .isize
                    else if (std.mem.eql(u8, nm, "u8"))
                        .u8
                    else if (std.mem.eql(u8, nm, "u16"))
                        .u16
                    else if (std.mem.eql(u8, nm, "u32"))
                        .u32
                    else if (std.mem.eql(u8, nm, "u64"))
                        .u64
                    else if (std.mem.eql(u8, nm, "u128"))
                        .u128
                    else if (std.mem.eql(u8, nm, "usize"))
                        .usize
                    else
                        .i32;
                    break :blk .{ .prim = prim };
                },
                .float => .{ .prim = .f64 },
                .boolean => .{ .prim = .bool },
                .character => .{ .prim = .u8 },
                .string => .{ .slice = (self.sliceU8Alloc() orelse return null) },
                .byte_array => .{ .slice = (self.sliceU8Alloc() orelse return null) },
            },
            .struct_lit => |sl| self.namedFromDef(sl.def),
            .enum_variant => |ev| self.namedFromDef(ev.def),
            .call => |c| switch (c.call_kind) {
                .free => |def_id| self.namedFromDef(def_id),
                .associated => |def_id| self.namedFromDef(def_id),
                .constructor => |def_id| self.namedFromDef(def_id),
            },
            .path => |pe| self.namedFromDef(pe.def),
            .binary => |b| self.binopResultType(b),
            .unary => |u| switch (u.op) {
                .negate, .deref => self.exprType(u.operand),
                else => null,
            },
            .if_else => |ie| self.exprType(ie.then_.tail orelse return null),
            .match => |match| self.matchResultType(match),
            else => null,
        };
    }

    /// Re-wrap a concrete ir type as a fresh slice-of-u8 (for string/byte-array
    /// tail literals). The returned slice is arena-backed.
    fn sliceU8Alloc(self: *Lowerer) ?*const ir.types.Slice {
        const s = self.alloc.create(ir.types.Slice) catch return null;
        s.* = .{ .const_ = true, .elem = .{ .prim = .u8 } };
        return s;
    }

    /// Resolve a def id to its emitted name as a `.named` type; null when
    /// unresolvable in the symbol table.
    fn namedFromDef(self: *Lowerer, def: ir.spine.EntityId) ?ir.types.Type {
        const ent = self.ir.graph.symbol_table.get(def) orelse return null;
        const nm = ent.renamed_to orelse ent.name;
        if (nm.len == 0) return null;
        return .{ .path = .{ .segments = &.{.{ .name = nm, .id = def }} } };
    }

    /// Best-effort concrete type of a sub-expression (used by binary/unary/if
    /// inference), recursing one level only.
    fn exprType(self: *Lowerer, id: ir.exprs.NodeId) ?ir.types.Type {
        if (id >= self.ir.bodies.exprs.len) return null;
        const e = self.ir.bodies.exprs[id];
        if (e.ty) |ty_id| {
            const ct: ?ir.types.Type = if (ty_id < self.ir.types.len)
                self.ir.types[ty_id]
            else if (ty_id < self.ir.bodies.types.len)
                self.ir.bodies.types[ty_id]
            else
                null;
            if (ct) |resolved| {
                if (resolved != .unsupported) return resolved;
            }
        }
        return switch (e.kind) {
            .literal => |lit| switch (lit) {
                .int => .{ .prim = .i32 },
                .float => .{ .prim = .f64 },
                .boolean => .{ .prim = .bool },
                else => null,
            },
            .struct_lit => |sl| self.namedFromDef(sl.def),
            .path => |pe| self.namedFromDef(pe.def),
            .binary => |binary| self.binopResultType(binary),
            .match => |match| self.matchResultType(match),
            else => null,
        };
    }

    fn matchResultType(self: *Lowerer, match: ir.exprs.MatchExpr) ?ir.types.Type {
        for (match.arms) |arm| {
            if (self.exprType(arm.body)) |result_type| return result_type;
        }
        return null;
    }

    /// Result type of a binary expression: comparisons/boolean ops are bool;
    /// otherwise prefer an operand's concrete type (float vs int), falling back
    /// to any operand concrete type.
    fn binopResultType(self: *Lowerer, b: ir.exprs.BinaryExpr) ?ir.types.Type {
        return switch (b.op) {
            .eq, .ne, .lt, .le, .gt, .ge, .boolean_and, .boolean_or => .{ .prim = .bool },
            else => blk: {
                const lt = self.exprType(b.lhs);
                if (isFloatType(lt)) break :blk lt;
                const rt = self.exprType(b.rhs);
                if (isFloatType(rt)) break :blk rt;
                break :blk if (lt) |t| t else rt;
            },
        };
    }

    /// True for a resolved f32/f64 type. Float arithmetic must never use
    /// integer wrapping operators, even when the source overflow mode is
    /// `.wrapping`.
    fn isFloatType(t: ?ir.types.Type) bool {
        return if (t) |ty| ty == .prim and (ty.prim == .f32 or ty.prim == .f64) else false;
    }

    fn lowerStructMethod(
        self: *Lowerer,
        m: ir.bodies.StructMethod,
        struct_name: []const u8,
        generic_params: []const ast.GenericParam,
    ) !ast.FnDecl {
        var params_list: std.ArrayListUnmanaged(ast.FnParam) = .empty;
        try self.appendFunctionGenericParams(m.generic_params, &params_list);
        var generic_args: []ast.Type = &.{};
        if (generic_params.len > 0) {
            generic_args = try self.alloc.alloc(ast.Type, generic_params.len);
            for (generic_params, 0..) |gp, i| {
                generic_args[i] = .{ .named = try self.alloc.dupe(u8, gp.name) };
            }
        }
        const is_generic = generic_params.len > 0;
        const self_type = if (is_generic)
            ast.Type{ .generic = .{
                .name = try self.alloc.dupe(u8, struct_name),
                .params = generic_args,
            } }
        else
            ast.Type{ .named = try self.alloc.dupe(u8, struct_name) };

        if (m.receiver) |rec| {
            // A generic struct is emitted as a comptime type function. Keep the
            // receiver tied to that type so its AST matches the method return.
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

        const ret_type = if (is_generic and isSelfPath(m.ret))
            self_type
        else
            try self.lowerType(m.ret);
        const previous_float_context = self.float_context;
        self.float_context = isFloatType(m.ret);
        defer self.float_context = previous_float_context;

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

    /// Collect generic type parameters referenced by a struct's field types so
    /// a generic struct (e.g. `Fletcher<T>` with `a: T`) is recognized even
    /// when the StructBody did not populate its own `generic_params` list.
    /// Recurses through container types; appends each new parameter once.
    fn collectGenericTypeParams(self: *Lowerer, ty: ir.types.Type, out: *std.ArrayListUnmanaged(ast.GenericParam)) !void {
        switch (ty) {
            .path => |p| {
                // A generic type parameter reference (e.g. `a: T`) lowers to a
                // single-segment path with a resolved `id` of null — the symbol
                // table has no entity for a type parameter. Resolved nominal
                // types always carry a non-null id, so null id is a safe
                // discriminator for an undeclared generic parameter.
                if (p.segments.len == 1) {
                    const seg = p.segments[0];
                    if (seg.id == null and isGenericParamName(seg.name) and
                        !hasGenericParam(seg.name, out.items))
                    {
                        try out.append(self.alloc, .{
                            .name = try self.alloc.dupe(u8, seg.name),
                            .is_comptime = true,
                            .ty = null,
                        });
                    }
                }
            },
            .reference => |r| try self.collectGenericTypeParams(r.pointee, out),
            .raw_ptr => |r| try self.collectGenericTypeParams(r.pointee, out),
            .slice => |s| try self.collectGenericTypeParams(s.elem, out),
            .array => |a| try self.collectGenericTypeParams(a.elem, out),
            .tuple => |tup| for (tup) |t| try self.collectGenericTypeParams(t, out),
            .generic_inst => |gi| for (gi.args.params) |arg| try self.collectGenericTypeParams(arg, out),
            .option => |inner| try self.collectGenericTypeParams(inner.*, out),
            .result => |r| {
                try self.collectGenericTypeParams(r.ok, out);
                try self.collectGenericTypeParams(r.err, out);
            },
            .boxed => |inner| try self.collectGenericTypeParams(inner.*, out),
            else => {},
        }
    }

    fn hasGenericParam(name: []const u8, list: []const ast.GenericParam) bool {
        for (list) |gp| {
            if (std.mem.eql(u8, gp.name, name)) return true;
        }
        return false;
    }

    /// Heuristic: a bare single segment whose name looks like a type parameter
    /// (single uppercase letter `T`/`U`/`V`, or an uppercase-leading identifier
    /// that is not a known resolved nominal type). Used only to recover generic
    /// structs when `StructBody.generic_params` is empty.
    fn isGenericParamName(name: []const u8) bool {
        if (name.len == 0) return false;
        // Single uppercase letter type params (T, U, V, ...)
        if (name.len == 1 and name[0] >= 'A' and name[0] <= 'Z') return true;
        // Already declared as a generic param somewhere? Treat any
        // non-resolved uppercase-leading identifier as a type parameter.
        if (name[0] >= 'A' and name[0] <= 'Z') return true;
        return false;
    }

    fn lowerTestEntity(self: *Lowerer, entity_id: ir.spine.EntityId, ent: ir.spine.Entity) !?ast.TestDecl {
        const previous_module_id = self.current_module_id;
        self.current_module_id = self.owningModuleEntity(entity_id) orelse previous_module_id;
        defer self.current_module_id = previous_module_id;
        const previous_struct_id = self.current_struct_id;
        self.current_struct_id = self.inherentStructForEntity(entity_id) orelse previous_struct_id;
        defer self.current_struct_id = previous_struct_id;
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

    /// A path can come from a partially recovered sidecar or from a temporary
    /// model slice. Reject null-ish/corrupt metadata before indexing it.
    fn validPathSegments(segments: []const ir.types.PathSegment) bool {
        if (segments.len == 0 or segments.len > 4096) return false;
        const address = @intFromPtr(segments.ptr);
        return address >= 4096 and address % @alignOf(ir.types.PathSegment) == 0;
    }

    /// Validate a path name before passing it to an allocator. In particular,
    /// a stale slice can carry a huge length even when its pointer is non-null.
    fn validPathName(name: []const u8) bool {
        if (name.len == 0 or name.len > 4096) return false;
        if (@intFromPtr(name.ptr) < 4096) return false;
        for (name) |c| {
            if (c == 0) return false;
        }
        return true;
    }

    fn genericPathParam(segments: []const ir.types.PathSegment) ?[]const u8 {
        if (segments.len < 2) return null;
        const first = segments[0];
        if (first.id != null or !validPathName(first.name)) return null;
        if (first.name.len != 1) return null;
        if (first.name[0] < 'A' or first.name[0] > 'Z') return null;
        return first.name;
    }
    fn isSelfPath(ty: ir.types.Type) bool {
        return switch (ty) {
            .path => |p| blk: {
                if (!validPathSegments(p.segments)) break :blk false;
                const last = p.segments[p.segments.len - 1].name;
                break :blk validPathName(last) and std.mem.eql(u8, last, "Self");
            },
            else => false,
        };
    }

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
            .array => |a| blk: {
                const elem_ty = try self.allocType(try self.lowerType(a.elem));
                const len = switch (a.len) {
                    .literal => |n| n,
                    .generic => 0,
                };
                if (len == 0) {
                    break :blk ast.Type{
                        .slice = .{
                            .elem = elem_ty,
                            .is_const = true,
                        },
                    };
                }
                break :blk ast.Type{
                    .array = .{
                        .elem = elem_ty,
                        .len = len,
                    },
                };
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
                if (!validPathSegments(p.segments)) {
                    break :blk ast.Type{ .named = "unknown" };
                }
                if (genericPathParam(p.segments)) |generic_name| {
                    break :blk ast.Type{ .named = try self.alloc.dupe(u8, generic_name) };
                }
                const last_segment = p.segments[p.segments.len - 1];
                if (!validPathName(last_segment.name)) {
                    if (last_segment.id) |id| {
                        if (self.ir.graph.symbol_table.get(id)) |ent| {
                            break :blk ast.Type{ .named = try self.alloc.dupe(u8, ent.name) };
                        }
                    }
                    break :blk ast.Type{ .named = "unknown" };
                }
                if (try self.strat.lowerStdGeneric(last_segment.name, &.{})) |std_ty| {
                    break :blk std_ty;
                }
                break :blk ast.Type{ .named = try self.alloc.dupe(u8, last_segment.name) };
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
                const name = if (decl_name.len > 0) decl_name else "generic";
                break :blk ast.Type{
                    .generic = .{
                        .name = try self.alloc.dupe(u8, name),
                        .params = params,
                    },
                };
            },
            .boxed => |b| try self.lowerType(b.*),
            .fn_ptr => ast.Type{ .named = "fn_ptr" },
            .unsupported => ast.Type.any_opaque,
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
            .char => .u21,
            .unit => .void_type,
            .never => .noreturn_type,
        };
    }

    // -------------------------------------------------------------------------
    // Expression Lowering
    // -------------------------------------------------------------------------

    /// True when the declared type of `expr_id` is (or reference-wraps) an array.
    fn receiverIsArray(self: *const Lowerer, expr_id: ir.exprs.NodeId) bool {
        if (expr_id >= self.ir.bodies.exprs.len) return false;
        const e = self.ir.bodies.exprs[expr_id];
        if (e.ty) |tid| {
            if (tid < self.ir.bodies.types.len) {
                var t = self.ir.bodies.types[tid];
                while (true) {
                    switch (t) {
                        .array => return true,
                        .reference => |r| t = r.pointee,
                        else => return false,
                    }
                }
            }
        }
        return false;
    }

    /// Grok the lowered receiver when it is a `&x` / `&mut x` unary-expression node,
    /// producing `x` for use as a by-value operand.
    fn lowerDeref(self: *Lowerer, recv_node: ir.exprs.NodeId, receiver: *const ast.Expr) anyerror!*const ast.Expr {
        if (recv_node < self.ir.bodies.exprs.len) {
            const re = self.ir.bodies.exprs[recv_node];
            if (re.kind == .unary and re.kind.unary.op == .ref) {
                return receiver;
            }
        }
        return receiver;
    }

    /// Slice-coercion helper: cite `receiver[0..]` for array receivers, else the
    /// receiver expression itself (slices/references are already slice-compatible).
    fn lowerAsRef(self: *Lowerer, receiver_node: ir.exprs.NodeId, receiver: *const ast.Expr) anyerror!*const ast.Expr {
        if (self.receiverIsArray(receiver_node)) {
            const zero = try self.allocExpr(ast.Expr{ .lit = .{ .int = 0 } });
            const open = try self.allocExpr(ast.Expr{ .range = .{ .start = zero, .end = null } });
            var args = try self.alloc.alloc(ast.Expr, 2);
            args[0] = receiver.*;
            args[1] = open.*;
            return try self.allocExpr(ast.Expr{ .builtin = .{ .name = "index", .args = args } });
        }
        return receiver;
    }

    /// Lower a prelude method call to native Zig. Returns the lowered
    /// expression when `method_name` is a recognised std prelude trait method
    /// (identity/slice coercion, clone, len, or an operator trait); returns
    /// null to fall through to the default method-call emission.
    fn lowerStdMethodCall(
        self: *Lowerer,
        method_name: []const u8,
        receiver_node: ir.exprs.NodeId,
        receiver: *const ast.Expr,
        args: []const ast.Expr,
    ) anyerror!?*const ast.Expr {
        if (std.mem.eql(u8, method_name, "as_ref") or
            std.mem.eql(u8, method_name, "as_bytes") or
            std.mem.eql(u8, method_name, "borrow") or
            std.mem.eql(u8, method_name, "as_slice"))
        {
            return try self.lowerAsRef(receiver_node, receiver);
        }
        if (std.mem.eql(u8, method_name, "clone") or
            std.mem.eql(u8, method_name, "to_vec"))
        {
            // Zig assignments (and by-value params/returns) copy already.
            return receiver;
        }
        if (std.mem.eql(u8, method_name, "len")) {
            return try self.allocExpr(ast.Expr{
                .field_access = .{
                    .target = receiver,
                    .field_name = try self.alloc.dupe(u8, "len"),
                },
            });
        }
        if (std.mem.eql(u8, method_name, "is_empty")) {
            if (args.len != 0) return null;
            const len = try self.allocExpr(ast.Expr{
                .field_access = .{
                    .target = receiver,
                    .field_name = try self.alloc.dupe(u8, "len"),
                },
            });
            const zero = try self.allocExpr(ast.Expr{ .lit = .{ .int = 0 } });
            return try self.allocExpr(ast.Expr{
                .bin_op = .{ .op = .equal, .lhs = len, .rhs = zero },
            });
        }
        const bin_kind: ?ast.BinOpKind = if (std.mem.eql(u8, method_name, "bitxor"))
            .bit_xor
        else if (std.mem.eql(u8, method_name, "bitor"))
            .bit_or
        else if (std.mem.eql(u8, method_name, "bitand"))
            .bit_and
        else if (std.mem.eql(u8, method_name, "shl"))
            .shl
        else if (std.mem.eql(u8, method_name, "shr"))
            .shr
        else if (std.mem.eql(u8, method_name, "add"))
            .add
        else if (std.mem.eql(u8, method_name, "sub"))
            .sub
        else if (std.mem.eql(u8, method_name, "mul"))
            .mul
        else if (std.mem.eql(u8, method_name, "div"))
            .div
        else if (std.mem.eql(u8, method_name, "rem"))
            .mod
        else if (std.mem.eql(u8, method_name, "wrapping_add"))
            .add_wrap
        else if (std.mem.eql(u8, method_name, "wrapping_sub"))
            .sub_wrap
        else if (std.mem.eql(u8, method_name, "wrapping_mul"))
            .mul_wrap
        else if (std.mem.eql(u8, method_name, "saturating_add"))
            .add_sat
        else if (std.mem.eql(u8, method_name, "saturating_sub"))
            .sub_sat
        else
            null;
        if (bin_kind) |bk| {
            if (args.len < 1) return null;
            const lhs = receiver;
            const rhs = try self.allocExpr(args[0]);
            return try self.allocExpr(ast.Expr{
                .bin_op = .{ .op = bk, .lhs = lhs, .rhs = rhs },
            });
        }
        if (std.mem.eql(u8, method_name, "neg")) {
            return try self.allocExpr(ast.Expr{
                .unary_op = .{ .op = .negate, .operand = receiver },
            });
        }
        if (std.mem.eql(u8, method_name, "not")) {
            return try self.allocExpr(ast.Expr{
                .unary_op = .{ .op = .bit_not, .operand = receiver },
            });
        }
        return null;
    }

    /// Lower an assertion marker emitted by the frontend macro pass. The
    /// marker stores the condition node id as `assertion:<id>` so the
    /// condition remains a normal IR expression while the assertion call is
    /// represented in the target AST.
    fn lowerAssertionMarker(self: *Lowerer, reason: []const u8) anyerror!ast.Expr {
        var condition_id: ?ir.exprs.NodeId = null;
        if (std.mem.startsWith(u8, reason, "assertion:")) {
            const suffix = reason["assertion:".len..];
            if (!std.mem.eql(u8, suffix, "none")) {
                if (std.fmt.parseInt(u32, suffix, 10)) |id| {
                    condition_id = @intCast(id);
                } else |_| {}
            }
        }

        const condition = if (condition_id) |id|
            if (id < self.ir.bodies.exprs.len)
                try self.lowerExpr(id)
            else
                ast.Expr{ .lit = .{ .bool_lit = true } }
        else
            ast.Expr{ .lit = .{ .bool_lit = true } };

        var args = try self.alloc.alloc(ast.Expr, 1);
        args[0] = condition;
        return ast.Expr{
            .call = .{
                .callee = try self.allocExpr(.{ .ident = try self.alloc.dupe(u8, "std.debug.assert") }),
                .args = args,
            },
        };
    }

    fn isAssertionReason(reason: []const u8) bool {
        if (std.mem.startsWith(u8, reason, "assertion:")) return true;
        return std.mem.eql(u8, reason, "macro debug_assert") or
            std.mem.eql(u8, reason, "macro debug_assert_eq") or
            std.mem.eql(u8, reason, "macro debug_assert_ne");
    }

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
            .array => |a| blk: {
                const elem_ast: ?ast.Type = if (ir_expr.ty) |tid|
                    if (tid < self.ir.bodies.types.len) try self.lowerType(self.ir.bodies.types[tid]) else null
                else
                    null;
                if (a.repeat) |len| {
                    const elem = try self.allocExpr(try self.lowerExpr(a.elements[0]));
                    break :blk ast.Expr{
                        .repeat = .{
                            .type_name = elem_ast,
                            .elem = elem,
                            .len = len,
                        },
                    };
                }
                var elems = try self.alloc.alloc(ast.Expr, a.elements.len);
                for (a.elements, 0..) |el, i| elems[i] = try self.lowerExpr(el);
                break :blk ast.Expr{
                    .multi_array = .{
                        .type_name = elem_ast,
                        .elements = elems,
                    },
                };
            },
            .path => |pe| blk: {
                break :blk try self.lowerResolvedEntity(pe.def);
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
                    const pattern_ids = arm.patterns;
                    const patterns_valid = pattern_ids.len > 0 and
                        pattern_ids.len <= self.ir.bodies.pats.len and
                        @intFromPtr(pattern_ids.ptr) >= 4096 and
                        @intFromPtr(pattern_ids.ptr) % @alignOf(ir.exprs.NodeId) == 0;
                    const pattern_count = if (pattern_ids.len > 0 and
                        pattern_ids.len <= self.ir.bodies.pats.len and
                        pattern_ids.len <= 4096)
                        pattern_ids.len
                    else
                        0;
                    var pats: []const ast.Pattern = &.{};
                    if (pattern_count > 0) {
                        var lowered_patterns = try self.alloc.alloc(ast.Pattern, pattern_count);
                        if (patterns_valid) {
                            for (pattern_ids, 0..) |p_id, j| {
                                lowered_patterns[j] = try self.lowerPattern(p_id);
                            }
                        } else {
                            for (lowered_patterns) |*pattern| pattern.* = .wildcard;
                        }
                        pats = lowered_patterns;
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
                const captures = if (we.capture) |cap_id|
                    try self.lowerWhileCapture(cap_id)
                else
                    null;
                break :blk ast.Expr{
                    .while_expr = .{
                        .cond = cond,
                        .captures = captures,
                        .body = try self.lowerBlock(we.body),
                    },
                };
            },
            .for_ => |fe| blk: {
                var inputs: std.ArrayListUnmanaged(ast.Expr) = .empty;
                defer inputs.deinit(self.alloc);
                var captures_list: std.ArrayListUnmanaged([]const u8) = .empty;
                defer captures_list.deinit(self.alloc);
                var destructure: std.ArrayListUnmanaged(ast.Stmt) = .empty;
                defer destructure.deinit(self.alloc);

                switch (fe.iter_kind) {
                    .slice => {
                        try inputs.append(self.alloc, try self.lowerExpr(fe.iterable));
                        try self.appendPatternCaptures(fe.pattern, &captures_list);
                    },
                    .range => {
                        // `0..end`; a Rust start that isn't 0 (or `..=` inclusive)
                        // was handled in the frontend (`..=` lowers to `end+1`).
                        const start = try self.allocExpr(ast.Expr{ .lit = .{ .int = 0 } });
                        const end = try self.allocExpr(try self.lowerExpr(fe.iterable));
                        try inputs.append(self.alloc, ast.Expr{ .range = .{ .start = start, .end = end } });
                        try self.appendPatternCaptures(fe.pattern, &captures_list);
                    },
                    .enumerate => {
                        // Rust `for (idx, elem) in xs.enumerate()` →
                        // Zig `for (xs, 0..) |elem, idx|`.
                        const slice = try self.lowerExpr(fe.iterable);
                        const zstart = try self.allocExpr(ast.Expr{ .lit = .{ .int = 0 } });
                        const open = try self.allocExpr(ast.Expr{ .range = .{ .start = zstart, .end = null } });
                        try inputs.append(self.alloc, slice);
                        try inputs.append(self.alloc, open.*);

                        var idx_name: []const u8 = "_";
                        var elem_name: []const u8 = "_";
                        if (fe.pattern < self.ir.bodies.pats.len) {
                            const pat = self.ir.bodies.pats[fe.pattern];
                            switch (pat.kind) {
                                .tuple => |tp| {
                                    if (tp.elements.len >= 1) idx_name = try self.patternName(tp.elements[0]);
                                    if (tp.elements.len >= 2) elem_name = try self.patternName(tp.elements[1]);
                                },
                                .binding => elem_name = try self.patternName(fe.pattern),
                                else => {},
                            }
                        }
                        try captures_list.append(self.alloc, elem_name);
                        try captures_list.append(self.alloc, idx_name);
                    },
                    .multi => |ids| {
                        for (ids, 0..) |mid, mi| {
                            try inputs.append(self.alloc, try self.lowerExpr(mid));
                            if (fe.pattern < self.ir.bodies.pats.len) {
                                const pat = self.ir.bodies.pats[fe.pattern];
                                if (pat.kind == .tuple) {
                                    const tp = pat.kind.tuple;
                                    if (mi < tp.elements.len) {
                                        try self.appendMultiCapture(tp.elements[mi], &captures_list, &destructure);
                                    } else {
                                        try captures_list.append(self.alloc, try self.alloc.dupe(u8, "_"));
                                    }
                                } else {
                                    try self.appendPatternCaptures(fe.pattern, &captures_list);
                                }
                            } else {
                                try captures_list.append(self.alloc, try self.alloc.dupe(u8, "_"));
                            }
                        }
                    },
                    .adapter => |ad| {
                        _ = ad;
                        return error.UnsupportedIterableAdapter;
                    },
                }

                var body = try self.lowerBlock(fe.body);
                if (destructure.items.len > 0) {
                    const merged = try self.alloc.alloc(ast.Stmt, destructure.items.len + body.stmts.len);
                    @memcpy(merged[0..destructure.items.len], destructure.items);
                    @memcpy(merged[destructure.items.len..], body.stmts);
                    body.stmts = merged;
                }

                const for_inputs = try inputs.toOwnedSlice(self.alloc);
                errdefer self.alloc.free(for_inputs);
                const captures = try captures_list.toOwnedSlice(self.alloc);
                errdefer self.alloc.free(captures);

                break :blk ast.Expr{
                    .for_expr = .{
                        .inputs = for_inputs,
                        .captures = captures,
                        .body = body,
                    },
                };
            },
            .break_ => |be| blk: {
                const val = if (be.value) |v| try self.allocExpr(try self.lowerExpr(v)) else null;
                break :blk ast.Expr{ .break_expr = val };
            },
            .continue_ => ast.Expr{ .continue_expr = {} },
            .call => |c| blk: {
                const callee_def: ir.spine.EntityId = switch (c.call_kind) {
                    .free => |def_id| def_id,
                    .associated => |def_id| def_id,
                    .constructor => |def_id| def_id,
                };
                const callee_name: []const u8 = if (self.ir.graph.symbol_table.get(callee_def)) |e|
                    e.renamed_to orelse e.name
                else
                    "unknown_fn";

                // Trait-associated calls like `Clone::clone(&x)` / `AsRef::as_ref(&x)`
                // lower to the receiver/copy/slice expression directly.
                if (c.call_kind == .associated) {
                    if (c.args.len >= 1) {
                        const recv_ast = try self.lowerExpr(c.args[0]);
                        const recv_ptr = try self.allocExpr(recv_ast);
                        if (try self.lowerStdMethodCall(callee_name, c.args[0], recv_ptr, &.{})) |lowered| {
                            break :blk lowered.*;
                        }
                    }
                }

                const resolved_callee = try self.lowerResolvedEntity(callee_def);
                const callee_expr = try self.qualifyInherentMethod(callee_def, resolved_callee);
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

                var args = try self.alloc.alloc(ast.Expr, mc.args.len);
                for (mc.args, 0..) |arg_id, i| {
                    args[i] = try self.lowerExpr(arg_id);
                }

                if (try self.lowerStdMethodCall(method_name, mc.receiver, receiver, args)) |lowered| {
                    break :blk lowered.*;
                }

                const field_access = try self.allocExpr(ast.Expr{
                    .field_access = .{
                        .target = receiver,
                        .field_name = try self.alloc.dupe(u8, method_name),
                    },
                });

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
                    const name = try self.alloc.dupe(u8, fi.field);
                    errdefer self.alloc.free(name);
                    const expr = try self.lowerExpr(fi.value);

                    fields[i] = .{
                        .name = name,
                        .expr = expr,
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
                        const name = try std.fmt.allocPrint(self.alloc, "{d}", .{i});
                        errdefer self.alloc.free(name);
                        const expr = try self.lowerExpr(tf);

                        fields[i] = .{
                            .name = name,
                            .expr = expr,
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
                const uses_float = self.float_context or isFloatType(self.binopResultType(be));
                const previous_float_context = self.float_context;
                self.float_context = uses_float;
                defer self.float_context = previous_float_context;
                const lhs = try self.allocExpr(try self.lowerExpr(be.lhs));
                const rhs = try self.allocExpr(try self.lowerExpr(be.rhs));
                const op_kind: ast.BinOpKind = switch (be.op) {
                    .add => if (uses_float) .add else switch (be.overflow) {
                        .checked => .add,
                        .wrapping => .add_wrap,
                        .saturating => .add_sat,
                    },
                    .sub => if (uses_float) .sub else switch (be.overflow) {
                        .checked => .sub,
                        .wrapping => .sub_wrap,
                        .saturating => .sub_sat,
                    },
                    .mul => if (uses_float) .mul else switch (be.overflow) {
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
            .unsupported => |u| blk: {
                if (isAssertionReason(u.reason)) {
                    break :blk try self.lowerAssertionMarker(u.reason);
                }
                break :blk ast.Expr{ .unsupported = try self.alloc.dupe(u8, u.reason) };
            },
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
                if (e_id < self.ir.bodies.exprs.len) {
                    switch (self.ir.bodies.exprs[e_id].kind) {
                        .assign => |assignment| {
                            const target = try self.lowerExpr(assignment.target);
                            const val = try self.lowerExpr(assignment.value);
                            const op: ast.AssignOp = switch (assignment.op) {
                                .plain => .assign,
                                .add => .add_assign,
                                .sub => .sub_assign,
                                .mul => .mul_assign,
                                .div => .div_assign,
                                .rem => .mod_assign,
                                .bit_and => .bit_and_assign,
                                .bit_or => .bit_or_assign,
                                .bit_xor => .bit_xor_assign,
                                .shl => .shl_assign,
                                .shr => .shr_assign,
                            };
                            break :blk ast.Stmt{ .assign = .{
                                .target = target,
                                .val = val,
                                .op = op,
                            } };
                        },
                        else => {},
                    }
                }
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
    // For-loop capture helpers
    // -------------------------------------------------------------------------

    /// Append the flat capture name(s) for a simple loop pattern (bindings,
    /// references and wildcards — not tuples).
    fn appendPatternCaptures(
        self: *Lowerer,
        pat_id: ir.exprs.NodeId,
        captures: *std.ArrayListUnmanaged([]const u8),
    ) anyerror!void {
        try captures.append(self.alloc, try self.patternName(pat_id));
    }

    /// The Zig capture identifier for a pattern: a binding's name, `_` for a
    /// wildcard, the inner pattern's name for a reference.
    fn patternName(self: *Lowerer, pat_id: ir.exprs.NodeId) anyerror![]const u8 {
        if (pat_id >= self.ir.bodies.pats.len) return self.alloc.dupe(u8, "_");
        const pat = self.ir.bodies.pats[pat_id];
        return switch (pat.kind) {
            .binding => |b| self.alloc.dupe(u8, b.name),
            .reference => |r| self.patternName(r.inner),
            .wildcard => self.alloc.dupe(u8, "_"),
            else => self.alloc.dupe(u8, "_"),
        };
    }

    /// Capture for one zip (`multi`) input. A plain binding/reference yields a
    /// single Zig capture; a tuple element yields a temporary capture plus a
    /// `const` destructure injected at the top of the loop body.
    fn appendMultiCapture(
        self: *Lowerer,
        pat_id: ir.exprs.NodeId,
        captures: *std.ArrayListUnmanaged([]const u8),
        destructure: *std.ArrayListUnmanaged(ast.Stmt),
    ) anyerror!void {
        if (pat_id >= self.ir.bodies.pats.len) {
            try captures.append(self.alloc, try self.alloc.dupe(u8, "_"));
            return;
        }
        const pat = self.ir.bodies.pats[pat_id];
        switch (pat.kind) {
            .binding => |b| try captures.append(self.alloc, try self.alloc.dupe(u8, b.name)),
            .reference => |r| try self.appendMultiCapture(r.inner, captures, destructure),
            .wildcard => try captures.append(self.alloc, try self.alloc.dupe(u8, "_")),
            .tuple => |tp| {
                const tmp = try self.alloc.dupe(u8, "_tup");
                try captures.append(self.alloc, tmp);
                const base = try self.allocExpr(ast.Expr{ .ident = tmp });
                try self.emitTupleDestructure(tp, base, destructure);
            },
            else => try captures.append(self.alloc, try self.alloc.dupe(u8, "_")),
        }
    }

    /// Emit `const a = base[i]; const b = base[j]; ...` statements for a tuple
    /// pattern, recursing into nested tuple sub-patterns.
    fn emitTupleDestructure(
        self: *Lowerer,
        tp: ir.exprs.TuplePat,
        base: *const ast.Expr,
        destructure: *std.ArrayListUnmanaged(ast.Stmt),
    ) anyerror!void {
        for (tp.elements, 0..) |el, i| {
            const el_pat = self.ir.bodies.pats[el];
            const el_access = try self.indexExpr(base, i);
            switch (el_pat.kind) {
                .binding => |b| try destructure.append(self.alloc, ast.Stmt{
                    .let_stmt = .{
                        .name = try self.alloc.dupe(u8, b.name),
                        .init = el_access.*,
                        .is_mut = b.mutable,
                    },
                }),
                .reference => |r| {
                    const rp = self.ir.bodies.pats[r.inner];
                    if (rp.kind == .binding) {
                        const rb = rp.kind.binding;
                        try destructure.append(self.alloc, ast.Stmt{
                            .let_stmt = .{
                                .name = try self.alloc.dupe(u8, rb.name),
                                .init = el_access.*,
                                .is_mut = rb.mutable,
                            },
                        });
                    }
                },
                .wildcard => {},
                .tuple => |sub| try self.emitTupleDestructure(sub, el_access, destructure),
                else => {},
            }
        }
    }

    /// Allocate `base[idx]` (the emitter renders `@index` with 2 args as `[ ]`).
    fn indexExpr(self: *Lowerer, base: *const ast.Expr, idx: usize) anyerror!*const ast.Expr {
        const idx_lit = try self.allocExpr(ast.Expr{ .lit = .{ .int = @intCast(idx) } });
        var args = try self.alloc.alloc(ast.Expr, 2);
        args[0] = base.*;
        args[1] = idx_lit.*;
        return self.allocExpr(ast.Expr{ .builtin = .{ .name = "index", .args = args } });
    }

    // -------------------------------------------------------------------------
    // Pattern Lowering
    // -------------------------------------------------------------------------

    fn enumVariantFields(
        self: *Lowerer,
        variant_id: ir.spine.EntityId,
    ) ?ir.items.VariantFields {
        const variant_entity = self.ir.graph.symbol_table.get(variant_id) orelse return null;

        if (variant_entity.kind == .variant) {
            if (variant_entity.parent) |enum_id| {
                if (enum_id < self.ir.bodies.bodies.len) {
                    switch (self.ir.bodies.bodies[enum_id]) {
                        .enum_ => |enum_body| {
                            for (enum_body.variants) |variant| {
                                if (std.mem.eql(u8, variant.name, variant_entity.name)) {
                                    return variant.fields;
                                }
                            }
                        },
                        else => {},
                    }
                }
            }
        }

        // Source extraction can resolve `Shape::Circle` to a local placeholder
        // before enum variant entities are linked. Use the unique variant name.
        for (self.ir.bodies.bodies) |body_kind| {
            const enum_body = switch (body_kind) {
                .enum_ => |body| body,
                else => continue,
            };
            for (enum_body.variants) |variant| {
                if (std.mem.eql(u8, variant.name, variant_entity.name)) return variant.fields;
            }
        }
        return null;
    }
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
                    const field_name = if (self.enumVariantFields(sp.def)) |variant_fields|
                        switch (variant_fields) {
                            .tuple => try std.fmt.allocPrint(self.alloc, "{d}", .{i}),
                            else => try self.alloc.dupe(u8, f.field),
                        }
                    else
                        try self.alloc.dupe(u8, f.field);
                    fields[i] = .{
                        .name = field_name,
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

    /// Extract the capture identifier(s) for a `while let` pattern. Handles
    /// `Some(v)` / `Ok(v)` (struct pattern → its single field's binding) and a
    /// plain `v` (direct binding). Returns null when there is no binding.
    fn lowerWhileCapture(self: *Lowerer, pat_id: ir.exprs.NodeId) anyerror!?[]const []const u8 {
        if (pat_id >= self.ir.bodies.pats.len) return null;
        const cap = (try self.whileCaptureName(pat_id)) orelse return null;
        var out = try self.alloc.alloc([]const u8, 1);
        out[0] = cap;
        return out;
    }

    fn whileCaptureName(self: *Lowerer, pat_id: ir.exprs.NodeId) anyerror!?[]const u8 {
        if (pat_id >= self.ir.bodies.pats.len) return null;
        const pat = self.ir.bodies.pats[pat_id];
        return switch (pat.kind) {
            .binding => |b| try self.alloc.dupe(u8, b.name),
            .reference => |rp| try self.whileCaptureName(rp.inner),
            .struct_pat => |sp| blk: {
                if (sp.fields.len == 0) break :blk null;
                const f = sp.fields[0];
                if (f.pat) |fpid| {
                    break :blk try self.whileCaptureName(fpid);
                }
                if (f.shorthand) {
                    break :blk try self.alloc.dupe(u8, f.field);
                }
                break :blk null;
            },
            else => null,
        };
    }

    // -------------------------------------------------------------------------
    // Block Lowering
    // -------------------------------------------------------------------------

    pub fn lowerBlock(self: *Lowerer, be: ir.exprs.BlockExpr) anyerror!ast.Block {
        // An unsupported tail expression would emit as `return @panic(...)`,
        // which Zig rejects as unreachable code (the panic never returns).
        // Keep it as a plain statement so the block still terminates in a loud
        // unsoundness marker without diverting control flow or failing to
        // compile.
        const tail_ast = if (be.tail) |t_id|
            try self.allocExpr(try self.lowerExpr(t_id))
        else
            null;

        var stmts = try self.alloc.alloc(
            ast.Stmt,
            be.statements.len + @intFromBool(tail_ast != null and tail_ast.?.* == .unsupported),
        );
        for (be.statements, 0..) |stmt_id, i| {
            stmts[i] = try self.lowerStmt(stmt_id);
        }
        var tail_expr: ?*const ast.Expr = tail_ast;
        if (tail_ast) |t| {
            if (t.* == .unsupported) {
                stmts[be.statements.len] = ast.Stmt{ .expr_stmt = t };
                tail_expr = null;
            }
        }

        const label = if (be.labelled) |l| try self.alloc.dupe(u8, l) else null;

        return ast.Block{
            .label = label,
            .stmts = stmts,
            .expr = tail_expr,
        };
    }
};
