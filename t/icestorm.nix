# icestorm.nix -- a simple declarative example that builds the Project Icestorm
# tools into an installable package, using the version of nixpkgs in your
# channel

with import <nixpkgs> {};

{
  ## specify the copy of nixpkgs to use for building the bind mount tool
  #nixpkgs = import <nixpkgs> {}; # TODO FIXME

  ## specify the package information
  project-icestorm = {
    label = "Project Icestorm";
    pkgs = with pkgs;
      [ symbiyosys yosys verilog
        arachne-pnr icestorm
        yices z3
      ];
  };
}
