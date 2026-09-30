{ pkgs, ... }:

let
  # Zig flocks every global-cache manifest. A build that dies holding one of
  # its manifest locks wedges every later build that wants the same cache, so
  # each project gets its own root under the node-local scratch disk.
  #
  # The anyzig shim resolves its toolchain through this same variable, at
  # `<root>/p/<hash>`. A root without `p` makes the shim re-fetch the tarball
  # from ziglang.org, fail extraction, and exit 1 in silence, so `p` is a
  # symlink to the one shared toolchain store: build caches stay per-project,
  # downloaded toolchains stay shared.
  zigCache = "/tmp/zig-caches/translate-rust";
in
rec {
  # zig 0.16 dev environment (house convention, cf. ~/projects/{notui,ztex}).
  # https://devenv.sh/basics/
  packages = with pkgs; [
    # zig
    bash
    pkg-config
    # zig-zlint
  ];

  env = {
    LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath packages}";
    INCLUDE_DIRECTORIES = "${pkgs.lib.makeIncludePath packages}";
    ZIGLINT_ARGS = "--ignore Z024 --ignore Z011";
    GATE_EXCLUDE = "test vendor r2z-core";
    ZIG_GLOBAL_CACHE_DIR = zigCache;
  };

  # Create the root if the node's scratch was wiped, then restore the `p`
  # symlink. The shim would otherwise rebuild `p` from the hashstore on the
  # next `zig version`, which costs a slow run on every shell entry.
  enterShell = ''
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    [ -e "$ZIG_GLOBAL_CACHE_DIR/p" ] || ln -s /tmp/zig-global-cache/p "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  # https://devenv.sh/languages/
  # languages.zig.enable = true;

  # Check translator correctness, then generated packages and fixture refusals.
  scripts.gate.exec = ''
    set -e
    zig-gate
    echo
    echo "== translation output check (zig build test-crates) =="
    zig build test-crates
  '';
}