# picorv32.nix -- a more advanced declarative example that builds the Project
# Icestorm tools as well as a custom set of RISC-V 32-bit toolchains into an
# installable package, a copy of the picorv32 source code, and uses a custom
# version of Nixpkgs for reproducible tools.

let
  # optional nixpkgs configuration
  # allowUnfree is needed for boolector, but it will allegedly go open
  # source in a future version
  config = { allowUnfree = true; };

  # upstream nixpkgs build; requires nix 2.0 for fetchTarball
  nixrev  = "fa8f4b187f703950a9e3119549d264ff7e233123";
  nixpkgs =
    let
      rev    = nixrev;
      sha256 = "0imqa7ykxy04yg26z5klabzn6m2kdr6fvd7hh3aqxqx9vagw2d67";
      src    = builtins.fetchTarball {
        name = "nixpkgs-${builtins.substring 0 7 rev}";
        url  = "https://github.com/nixos/nixpkgs/archive/${rev}.tar.gz";
        inherit sha256;
      };
    in import src { inherit config; };
in

# now bring everything into scope, as if this was
#   'with import <nixpkgs> {};'
with nixpkgs;

let
  # picorv32 can be configured in multiple ways, so add all
  # toolchains
  architectures = [ "rv32i" "rv32ic" "rv32im" "rv32imc" ];

  # picorv32 source will be included in the installation for Maximum Utility
  picorv32-src = pkgs.fetchFromGitHub {
    owner  = "cliffordwolf";
    repo   = "picorv32";
    rev    = "a9e0ea54cffa162cfe901ff8d30d8877a18c6d8e";
    sha256 = "0mwh1n0w8psdif51l2y6zw06a58x87fl6wi1szvxq2ml2k9j2nb2";
  };

  # sync'd with picorv32
  riscv-src = pkgs.fetchFromGitHub {
    owner  = "riscv";
    repo   = "riscv-gnu-toolchain";
    rev    = "bf5697a1a6509705b50dcc1f67b8c620a7b21ec4";
    sha256 = "117p2hkb5khfp7zyqymzhxxmk4ns3k79yzvl734b5mnwhpp2var8";
    fetchSubmodules = true;
  };

  # create a risc-v gcc toolchain for a given architecture
  # major version is GCC version, suffixed by revision
  riscv-toolchain-ver = "7.2.0";
  make-riscv-toolchain = arch:
    stdenv.mkDerivation rec {
      name    = "riscv-${arch}-toolchain-${version}";
      version = "${riscv-toolchain-ver}-${builtins.substring 0 7 src.rev}";
      src     = riscv-src;

      configureFlags   = [ "--with-arch=${arch}" ];
      installPhase     = ":"; # 'make' installs on its own
      hardeningDisable = [ "format" ]; # -Werror=format-security

      nativeBuildInputs = with pkgs;
        [ curl gawk texinfo bison flex gperf ];
      buildInputs = with pkgs;
        [ libmpc mpfr gmp ];
    };

  # Full version number for the package
  version = lib.concatStringsSep "-"
    [ riscv-toolchain-ver
      ("p" + builtins.substring 0 7 picorv32-src.rev)
      ("n" + builtins.substring 0 7 nixrev)
    ];

  # an attrset of all the necessary PicoRV32 toolchains
  riscv-toolchains = lib.genAttrs architectures make-riscv-toolchain;

  # TODO FIXME: remove this in favor of riscv-toolchains
  riscv-tools = map make-riscv-toolchain [ "rv32imc" ];

  # startup package that will display some helpful information
  # about the packaged tools
  startpkg = stdenv.mkDerivation {
    name = "picorv32-tools-startup";

    # important: don't patch the script shebang to
    # point to nix's bash, use /usr/bin/env bash exactly
    dontFixup = true;

    unpackPhase = ":";
    buildPhase = ":";
    installPhase = ''
      touch $out && chmod +x $out

      cat > $out <<EOF
      #!/usr/bin/env bash

      echo
      echo "PicoRV32 Toolchain build, version ${version}"
      echo "Included tools:"
      echo -n "  " && (./bin/riscv32-unknown-elf-gcc --version | head -1)
      echo -n "  " && ./bin/yosys -V
      echo -n "  " && ./bin/arachne-pnr --version
      echo -n "  " && ./bin/z3 --version
      echo -n "  " && (./bin/yices --version | head -1)
      echo -n "  " && (./bin/iverilog -V | head -1) 2>/dev/null
      EOF
    '';
  };

in
{
  picorv32-tools = {
    label  = "PicoRV32 Toolchain";
    subdir = "picorv32-tools-${version}";

    # Install the PicoRV32 source code, as well as copies of
    # all of the associated toolchains
    extraDirs = {
      picorv32   = picorv32-src;
      toolchains = riscv-toolchains;
    };

    # Cleverly add "." to the front of the string to turn "/" into "./"
    # TODO FIXME: HACK
    startup = "." + startpkg;

    pkgs = with pkgs;
      [ symbiyosys yosys verilog
        arachne-pnr icestorm
        yices z3 boolector
        startpkg
      ] ++ riscv-tools;
  };
}
