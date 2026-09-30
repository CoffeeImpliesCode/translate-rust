const r2z = @import("r2z");

pub const FnvHasher = struct {
    const Self = @This();

    @"0": u64,

    pub fn default() root.FnvHasher {
        return root.FnvHasher{ .@"0" = 14695981039346656037 };
    }

    pub fn with_key(key: u64) root.FnvHasher {
        return root.FnvHasher{ .@"0" = key };
    }

    pub fn finish(self: *const FnvHasher) u64 {
        return self.@"0";
    }

    pub fn write(self: *FnvHasher, bytes: []const u8) void {
        var hash: u64 = self.@"0";
        for (bytes[0..]) |*byte| {
            hash = hash ^ @as(u64, byte.*);
            hash = hash *% 1099511628211;
        }
        self.* = root.FnvHasher{ .@"0" = hash };
    }
};

pub const FnvBuildHasher = r2z.BuildHasherDefault(FnvHasher);

pub fn FnvHashMap(comptime K: type, comptime V: type) type {
    return r2z.collections.HashMap(K, V, FnvBuildHasher);
}

pub fn FnvHashSet(comptime T: type) type {
    return r2z.collections.HashSet(T, FnvBuildHasher);
}

pub const root = @import("./root.zig");
