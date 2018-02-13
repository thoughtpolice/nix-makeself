# hello.nix -- a simple declarative example that builds GNU Hello, and nothing
# more.

with import <nixpkgs> {};

{
  ## specify the copy of nixpkgs to use for building the bind mount tool
  #nixpkgs = import <nixpkgs> {}; # TODO FIXME

  ## specify the package information
  hello = {
    label = "GNU Hello";
    startup = "./bin/hello --version";
    pkgs = [ pkgs.hello ];
  };
}
