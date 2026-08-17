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

  scripts.gate.exec = "zig-gate";
}
