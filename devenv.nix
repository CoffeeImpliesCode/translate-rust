{ pkgs, ... }:

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
    # Zig flocks every global-cache manifest. A build that dies holding one
    # of its manifest locks wedges every later build that wants the same
    # global cache. A project-local global cache keeps `zig build`
    # independent of that; the cost is one extra compiler_rt build.
    ZIG_GLOBAL_CACHE_DIR = ".zig-global-cache";
  };

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
