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
  };

  # https://devenv.sh/languages/
  # languages.zig.enable = true;

  # `gate` runs the shared zig-gate (src/ correctness) THEN verifies the
  # *translation output*: `zig build test-crates` regenerates every r2z
  # package and ast-checks + builds + tests it. Without this, "gate passes"
  # would only prove the translator's source is valid, never that its emitted
  # Zig is (the actual product).
  scripts.gate.exec = ''
    zig-gate
    echo
    echo "== translation output check (zig build test-crates) =="
    zig build test-crates
  '';
}
