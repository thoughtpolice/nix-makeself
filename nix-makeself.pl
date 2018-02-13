#! /usr/bin/env nix-shell
#! nix-shell -i perl -p ncurses nixUnstable perl man less makeself perlPackages.JSON
#! nix-shell -I nixpkgs=https://github.com/NixOS/nixpkgs-channels/archive/nixos-unstable.tar.gz

## nix-makeself -- package Nix closures as stand-alone installable packages
## Copyright (c) 2018 Austin Seipp.
##
## This program is free software; you can redistribute it and/or modify it under
## the terms of the GNU General Public License as published by the Free Software
## Foundation; either version 2 of the License, or (at your option) any later
## version.
##
## This program is distributed in the hope that it will be useful, but WITHOUT
## ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
## FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
## details.
##
## You should have received a copy of the GNU General Public License along with
## this program; if not, write to the Free Software Foundation, Inc., 51
## Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.

## -----------------------------------------------------------------------------
## -- Imports, setup

use JSON::PP qw( decode_json );
use strict;
use warnings "all";
use 5.12.0;

use Getopt::Long;
use Pod::Usage;
use File::Temp qw/ tempfile tempdir unlink0 /;

## -----------------------------------------------------------------------------

use constant VERSION => "0.0";
use constant COPYRIGHT => "Copyright (c) 2018 Austin Seipp";

## -----------------------------------------------------------------------------
## -- Option parsing

my $help = 0;
my $version = 0;
my $debug = 0;
my $nixpkgs = "import <nixpkgs> {}";

my $license;
my $output;
my $label;
my $subdir;
my $input;
my $startup;

my $decl_mode = 0;

$ENV{'PAGER'} = "less"; # ensure '--help' works adequately
GetOptions(
    'help|?'     => \$help,
    "version|v"  => \$version,
    "debug"      => \$debug,
    "nixpkgs=s"  => \$nixpkgs,
    "license=s"  => \$license,
    "label=s"    => \$label,
    "subdir=s"   => \$subdir,
    "output|o=s" => \$output,
    "file|f=s"   => \$input,
) or pod2usage(2);

## -- Basic cases

if ($version) {
    print STDERR <<EOF
nix-makeself version @{[ VERSION ]}
@{[ COPYRIGHT ]}
License GPLv2+: GNU GPL version 2 or later <https://gnu.org/licenses/gpl-2.0.html>.
This is free software: you are free to change and redistribute it.
There is NO WARRANY, to the extent permitted by law.
EOF
        ;

    exit 0;
}

pod2usage(-exitval => 0, -verbose => 2) if $help;

$decl_mode = 1 if $input;

## -- Sanity cases

if ($decl_mode and @ARGV) {
    pod2usage(
        -exitval => -1,
        -verbose => 0,
        -message => "ERROR: -f and a list of store paths are exclusive; try --help for more information"
    );
} elsif ($decl_mode) {

    die "Declarative input file '$input' does not exist"
        unless (-e $input);

} elsif (@ARGV) {

    pod2usage(
        -exitval => -1,
        -verbose => 0,
        -message => "ERROR: must provide an install label; try --help for more information"
    ) unless ($label);

    pod2usage(
        -exitval => -1,
        -verbose => 0,
        -message => "ERROR: must provide an output file to create; try --help for more information"
    ) unless ($output);

    pod2usage(
        -exitval => -1,
        -verbose => 0,
        -message => "ERROR: must provide subdirectory for the installer to create; try --help for more information"
    ) unless ($subdir);

} else {
    pod2usage(
        -exitval => -1,
        -verbose => 0,
        -message => "ERROR: Must provide a list of store paths or a declarative input; try --help for more information"
    );
}

## -----------------------------------------------------------------------------
## -- Prepare `nix-makeself-run`

my $nix_makeself_run_cc = <<'EOF'
    #define _GNU_SOURCE

    #include <assert.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <stdbool.h>
    #include <string.h>
    #include <err.h>

    #include <dirent.h>
    #include <limits.h>
    #include <unistd.h>
    #include <sched.h>
    #include <sys/mount.h>
    #include <sys/types.h>
    #include <sys/stat.h>
    #include <sys/wait.h>
    #include <fcntl.h>

    #ifdef DEBUG
    #define dwarnx(...) warnx(__VA_ARGS__)
    #else
    #define dwarnx(...)
    #endif

    #define STR_EQ(x, y, n) (0 == strncmp(x, y, n))

    void
    usage(char* p, int ret)
    {
        fprintf(stderr, "usage: %s <nix store> -- <program> args...\n", p);
        exit(ret);
    }

    void
    write_file(const char* file, char* data, size_t len)
    {
        int fd = open(file, O_WRONLY);
        if (fd < 0) err(EXIT_FAILURE, "could not open '%s'", file);

        if (write(fd, data, len) != len)
            err(EXIT_FAILURE, "writing to '%s'", file);

        close(fd);
    }

    int
    is_directory(const char* path)
    {
        struct stat buf;
        if (0 != stat(path, &buf)) err(EXIT_FAILURE, "stat of '%s'", path);

        return S_ISDIR(buf.st_mode);
    }

    void
    rebind_root(char* rootdir)
    {
        char origpath[PATH_MAX];
        char newpath[PATH_MAX];
        struct stat statbuf;

        DIR* d = opendir("/");
        if (!d) err(EXIT_FAILURE, "opendir(\"/\")");

        dwarnx("rebinding root directories into '%s'...", rootdir);

        struct dirent* e;
        while((e = readdir(d))) {
            // skip link dirs
            if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) {
                dwarnx("note -- skipping directory '/%s'", e->d_name);
                continue;
            }

            // skip existing nix dirs
            if (STR_EQ(e->d_name, "nix", 3)) {
                dwarnx("note -- skipping existing '/nix'");
                continue;
            }

            snprintf(origpath, PATH_MAX, "/%s", e->d_name);
            if (0 != stat(origpath, &statbuf)) {
                dwarnx("could not stat '%s'", origpath);
                continue;
            }

            if(!S_ISDIR(statbuf.st_mode)) {
                dwarnx("note -- skipping non-directory '%s'", origpath);
                continue;
            }

            size_t cnt = snprintf(newpath, PATH_MAX, "%s%s", rootdir, origpath);
            assert(cnt < sizeof(newpath) && "nix mount buffer write too large");
            dwarnx("rebinding '%s' to '%s'", origpath, newpath);

            // TODO FIXME
            mkdir(newpath, statbuf.st_mode & ~S_IFMT);
            if (0 != mount(origpath, newpath, "none", MS_BIND | MS_REC, NULL))
                err(EXIT_FAILURE, "mount('%s', '%s')", origpath, newpath);
        }
    }

    void
    mount_store(char* rootdir, char* store)
    {
        struct stat statbuf;
        if (0 != stat(store, &statbuf))
            err(EXIT_FAILURE, "stat for '%s'", store);

        char buf[PATH_MAX] = { 0, };
        size_t cnt = snprintf(buf, PATH_MAX, "%s/nix", rootdir);
        assert(cnt < sizeof(buf) && "nix mount buffer write too large");

        dwarnx("mounting nix store '%s' to %s", store, buf);
        mkdir(buf, statbuf.st_mode & ~S_IFMT);
        if (0 != mount(store, buf, "none", MS_BIND | MS_REC, NULL))
          err(EXIT_FAILURE, "mount('%s', '%s')", store, buf);
    }

    void
    update_proc(uid_t uid, gid_t gid)
    {
        size_t r = 0;
        char mapbuf[1024];

        // see user_namespaces(7) for more documentation
        int setgroups = open("/proc/self/setgroups", O_WRONLY);
        if (setgroups < 0)
            err(EXIT_FAILURE, "opening /proc/self/setgroups");

        dwarnx("updating setgroups policy to 'deny'");
        if(write(setgroups, "deny", 4) != 4)
            err(EXIT_FAILURE, "writing 'deny' policy to /proc/self/setgroups");

        // update uid mapping
        r = snprintf(mapbuf, sizeof(mapbuf), "%d %d 1", uid, uid);
        assert(r < sizeof(mapbuf) && "Map buffer write too large");

        dwarnx("writing uid map '%s' to /proc/self/uid_map", mapbuf);
        write_file("/proc/self/uid_map", mapbuf, strlen(mapbuf));

        // update gid mapping
        r = snprintf(mapbuf, sizeof(mapbuf), "%d %d 1", gid, gid);
        assert(r < sizeof(mapbuf) && "Map buffer write too large");

        dwarnx("writing gid map '%s' to /proc/self/gid_map", mapbuf);
        write_file("/proc/self/gid_map", mapbuf, strlen(mapbuf));
    }

    void
    update_chroot(const char* rootdir)
    {
        char mycwd[PATH_MAX];

        if (NULL == getcwd(mycwd, PATH_MAX)) err(EXIT_FAILURE, "getcwd");
        if (0 != chdir("/")) err(EXIT_FAILURE, "chdir(\"/\")");
        if (0 != chroot(rootdir)) err(EXIT_FAILURE, "chroot(\"%s\")", rootdir);
        if (0 != chdir(mycwd)) err(EXIT_FAILURE, "chdir(\"%s\")", mycwd);
    }

    void
    check_namespace_support(char** av)
    {
        pid_t cpid, w;
        bool ok = false;

        printf("Checking for user namespace support... ");

        cpid = fork();
        if (cpid == -1) err(EXIT_FAILURE, "fork");

        // Child
        if (cpid == 0) {
            // Simply try to set up a namespace, and exit based on that
            if (unshare(CLONE_NEWNS | CLONE_NEWUSER) < 0) {
                _exit(EXIT_FAILURE);
            } else {
                _exit(EXIT_SUCCESS);
            }
        }
        // Parent
        else {
            int wstatus;
            do {
                w = waitpid(cpid, &wstatus, 0);
                if (w == -1) err(EXIT_FAILURE, "waitpid");
            } while (!WIFEXITED(wstatus));

            ok = (WEXITSTATUS(wstatus) == EXIT_SUCCESS) ? true : false;
        }

        printf("%s\n", ok ? "OK!" : "FAILURE!");
        if (!ok) {
            fprintf(stderr, "\n");
            fprintf(stderr, "TODO FIXME: put a long message here about "
                            "missing user namespace support\n\n");
        }

        // Exit now if the user had no startup program of their own
        if (STR_EQ(av[3], "--", 2)) exit(EXIT_SUCCESS);

        // Otherwise, execute the specified program
        char*  prog = av[3];
        dwarnx("executing program '%s'", prog);
        execvp(prog, av + 3); // should not return
        err(EXIT_FAILURE, "execvp for '%s' failure", prog);
    }

    int
    main(int ac, char** av)
    {
        char rootdirbuf[PATH_MAX] = { 0, };

        if (ac < 4) usage(av[0], EXIT_FAILURE);
        if (!STR_EQ(av[2], "--", 2)) usage(av[0], EXIT_FAILURE);

        if (STR_EQ(av[1], "--check", 7)) {
            check_namespace_support(av);
        }

        char* store = av[1];
        char*  prog = av[3];

        // bail early if we're already inside a mount
        if (NULL != getenv("NIX_MAKESELF_MNT")) {
            dwarnx("not entering new namespace (as it was already inherited)");
            goto execute;
        }

        if (!is_directory(store))
            errx(EXIT_FAILURE, "store path '%s' is not a directory", store);

        char* tmpdir = getenv("XDG_RUNTIME_DIR");
        size_t cnt = snprintf(rootdirbuf, PATH_MAX, "%s/nix-XXXXXX", tmpdir);
        assert(cnt < sizeof(rootdirbuf) && "rootdir buffer write too large");

        dwarnx("using tmpdir '%s' and fuzzy temp root '%s'", tmpdir, rootdirbuf);

        char* rootdir = mkdtemp(rootdirbuf);
        if (!rootdir) err(EXIT_FAILURE, "mkdtemp failure");

        dwarnx("using store path '%s'", store);
        dwarnx("using temporary root path '%s'", rootdir);

        uid_t uid = getuid();
        gid_t gid = getgid();

        if (unshare(CLONE_NEWNS | CLONE_NEWUSER) < 0)
            err(EXIT_FAILURE, "unshare(NEWNS|NEWUSER)");

        dwarnx("entered new mount/user namespace");

        rebind_root(rootdir);
        mount_store(rootdir, store);
        update_proc(uid, gid);
        update_chroot(rootdir);

        // Execute
     execute:
        dwarnx("executing program '%s'", prog);
        setenv("NIX_CONF_DIR", "/nix/etc/nix", 1);
        setenv("NIX_MAKESELF_MNT", "1", 1);
        execvp(prog, av + 3); // should not return

        err(EXIT_FAILURE, "execvp for '%s' failure", prog);
        return EXIT_FAILURE;
    }
EOF
;

my $ccdebug = $debug ? "-DDEBUG" : "";
my $nix0 = <<EOF
let
  nixpkgs = ($nixpkgs);

  version = "@{[ VERSION ]}";
  src = nixpkgs.runCommand "nix-makeself-run.c" {} ''
    cat > \$out <<CCODE
$nix_makeself_run_cc
    CCODE
  '';
in

nixpkgs.stdenv.mkDerivation rec {
  name = "nix-makeself-run-\${version}";
  inherit version src;

  buildInputs = [ ];
  nativeBuildInputs = [ nixpkgs.glibc.static ];

  unpackPhase = ":";
  installPhase = ''
    mkdir -p \$out/bin
    echo compiling \$src
    cc -O2 $ccdebug -Wall -std=gnu99 -static \\
      -o \$out/bin/nix-makeself-run \$src
  '';
}
EOF
;

say "compiling \`nix-makeself-run\` helper program (with nixpkgs = '$nixpkgs')...";

my ($nbh, $nbtempfile) = tempfile();
print $nbh $nix0;

chomp(my $nix_makeself_run= qx/nix-build --no-out-link $nbtempfile/);
chomp (my @makeself_reqs = qx/nix path-info -r $nix_makeself_run/);

say "ok, nix-makeself-run built: $nix_makeself_run, ",
    scalar @makeself_reqs, " dependent paths";

unlink0($nbh, $nbtempfile);

## -----------------------------------------------------------------------------
## -- Figure out how we're executing

if ($decl_mode) {
    my $objs = decode_json(qx/nix eval --json -f "$input" ''/);

    foreach my $project (keys %$objs) {
        my $pref  = $objs->{"$project"}->{"pkgs"};
        my $paths = join(' ', @$pref);
        my $lbl   = $objs->{"$project"}->{"label"};

        say "building deps for '", $project, "', '", $lbl ,"'...";
        qx/nix build --no-link -f "$input" "$project.pkgs"/;

        push @ARGV, @$pref;

        # TODO FIXME: hack
        $output = "$project.sh";
        $label  = $lbl;
        $subdir = $objs->{$project}->{"subdir"} || $project;
        $startup = $objs->{$project}->{"startup"} || "--";
        $license = $objs->{$project}->{"license"};
    }
}

## -----------------------------------------------------------------------------
## -- Prepare the Nix closure

my $numpaths = scalar @ARGV;
say "packaging up ", $numpaths, " paths and their closures...";

my $totalpaths = scalar @makeself_reqs;
my @bindirs = ();

foreach (@ARGV) {
    chomp(my @requisites = qx/nix path-info -r $_/)
        or die "could not run 'nix path-info'";

    print "path $_ has ", scalar @requisites, " dependent paths, ";

    my $bindir = "$_/bin";
    if (-e $bindir) {
        say "with bindir";
        push @bindirs, $bindir;
    } else {
        say "with no bindir"
    }

    $totalpaths += scalar @requisites;
}

say "";
say "got $totalpaths paths in resulting closure, with ",
    scalar @bindirs, " /bin dirs";

my $tempstore = tempdir( CLEANUP => 1 ) . "/$subdir";
mkdir $tempstore or die "could not create temporary dir $tempstore!";
say "copying paths to temporary store $tempstore";

push @ARGV, $nix_makeself_run; # hack(?)
my $allpaths = join(' ', @ARGV);

# TODO FIXME: '... or die' fails here? nix copy returns bad result?
qx/nix copy --no-check-sigs --to $tempstore $allpaths/;

## ----------------------------------------------------------------------------- #
## -- Create /bin wrappers

say "creating /bin dir wrappers";

my $tempbin = "$tempstore/bin";
mkdir $tempbin or die "could not create temporary $tempbin!";

my $relpath = substr $nix_makeself_run, 1;

my @allbins = ();
foreach (@bindirs) {
    my $dir = $_;
    say "linking binaries in $_...";

    opendir (my $dh, $_) or die "could not open $_!";
    while (readdir $dh) {
        if ($_ eq ".." || $_ eq ".") { next };

        push @allbins, $_;

        my $script = <<EOF
#!/usr/bin/env bash
BASEDIR="\$( cd \"\$( dirname \"\${BASH_SOURCE[0]}\" )\" && pwd )/.."
exec \$BASEDIR/$relpath/bin/nix-makeself-run "\$BASEDIR/nix" -- "$dir/$_" "\$@"
EOF
              ;

        open(FH, '>', "$tempbin/$_") or die $!;
        print FH $script;
        close FH;
        chmod 0755, "$tempbin/$_" or die "could not set +x bit on $_!";
    }
}

## ----------------------------------------------------------------------------- #
## -- Create makeself package

my $check = "./$relpath/bin/nix-makeself-run --check";
my $makeself_args;
$makeself_args .= " --license $license" if $license;
$makeself_args .= " \"$tempstore\"";
$makeself_args .= " \"$output\"";
$makeself_args .= " \"$label\"";
$makeself_args .= " $check -- $startup";

# NOTE: when 'nix copy' exports the store closure, it marks the files as u+r only
# fix that here when creating the tar file by adding +w bits back to the files.
#
# if this isn't done, 'rm -rf foo/' can result in errors since the +w bit is not
# set
#
# this probably is an issue running nix tools inside this mount as they'll find
# a writeable store location suspicious
qx/makeself --tar-quietly --tar-extra "--mode=ug+w" --xz --notemp $makeself_args/
    or die "Could not execute 'makeself'!";

## ----------------------------------------------------------------------------- #
## -- El fin

say "";
say "Finished.";
exit(0);

## Local Variables:
## fill-column: 80
## indent-tabs-mode: nil
## buffer-file-coding-system: utf-8-unix
## End:

__END__

=encoding utf8

=head1 NAME

nix-makeself -- Package a Nix closure as a self-contained Unix installer

=head1 SYNOPSIS

B<nix-makeself> [I<options>] [STORE PATHS...]

OR

B<nix-makeself> [I<options>] <-f|--file> I<pkg.nix>

=head1 DESCRIPTION

B<nix-makeself> packages a set of closures from your Nix store into an installer
for users that doesn't require them to have Nix at runtime. This package is
created using B<makeself>. When a program is executed, a wrapper program creates
a user namespace and the "indirect" Nix store that is packaged inside the
installer is mounted into B</nix/store> instead. This allows painless
redistribution of Nix packages (even highly custom ones).

If B<[STORE PATHS...]> are provided, then B<nix-makeself> will create a package
(with metadata specified by I<options>) with the specified paths and their
entire closure included.

If B<--file> is provided with a file I<pkg.nix> containing a Nix expression,
then B<nix-makeself> will create a package based on the declarative
specification contained in I<pkg.nix> (see B<EXAMPLES> below.)

=head1 OPTIONS

=over

=item B<--help>, B<-h>

Display nix-makeself's man page -- the one you're reading now -- and exit.

=item B<--version>, B<-v>

Display nix-makeself's version number and exit.

=item B<--debug>

Display extra debugging information on B<stderr> during operation. This
primarily is a debugging-only tool. Packages created with this flag will have
their binary "wrapper" programs compiled in debug mode, which will dump various
information about the bind mounts it performs as well as other auxiliary
information.

=item B<--nixpkgs>

Specify an expression that, when evaluated, will result in a copy of Nixpkgs
which will be used to bootstrap and compile the B<nix-makeself-run> tool. By
default, 'import <nixpkgs> { }' is used in order to bootstrap the tool using the
existing copy of nixpkgs from B<nixos-unstable>, the same one used to bootstrap
B<nix-makeself>.

See B<INTERNALS> below.

=item B<--label LABEL>

An arbitrary string of text describing the package; it's displayed while
extracting the files.

=item B<--license FILE>

Attach the given license file (located in B<FILE>) to the installer, requiring
the user to accept the license before installation can proceed any further.

=item B<--output FILE>, B<-o FILE>

Specify the location to put the resulting installer when finished. This option
is mandatory and must be provided.

=item B<--subdir NAME>

Subdirectory to package the closure paths into. For example, if you pass an
argument of '--subdir hello', then when the installer is run, the package will
be extracted to the './hello/' directory in the $CWD of the installer.

=item B<--file FILE>, B<-f FILE>

Specify a declarative Nix input file that will be evaluated in order to create
an installer from a set of Nix expressions.

Providing a declarative installer specification with B<--file> is mutually
exclusive with providing a set of direct B<[STORE PATHS...]>.

=item B<[STORE PATHS...]>

Root paths into the current Nix store that will be packaged into the installer.
The closure of these paths (and only those paths) will be recursively copied
into a temporary store location and packaged from there for installation.

Providing direct store paths is mutually exclusive with the B<--file> option.

=back

=head1 EXAMPLES

B<nix-makeself> has two operating modes, "imperative" and "declarative." In the
imperative mode, you specify a set of Nix store paths which must exist, and an
installer is created. In declarative mode, you evaluate a file containing a Nix
expression describing the installer, and it's created for you automatically.

In the imperative case, you can package B<chez-scheme> from your nixpkgs
channel quite easily:

    $ ./nix-makeself.pl -o chez.sh --label "Chez Scheme" --subdir=chez \
        $(nix-build '<nixpkgs>' -A chez)

The resulting file B<chez.sh> is a fully packaged installer ready to be
installed by a user, using whatever copy of B<chez> was currently available in
the nixpkgs package set.

The declarative case is often more robust. Instead, write a file which will
evaluate to an attrset containing a single attribute. The attribute name will be
the name of the installer to create, with the value being another attrset
describing the installer and packages inside. For example, in the file
I<icestorm.nix> you may have:

    with import <nixpkgs> {};

    {
      project-icestorm = {
        label = "Project Icestorm";
        pkgs = with pkgs;
          [ symbiyosys yosys
            arachne-pnr icestorm
            yices z3
          ];
      };
    }

Now, you may build the I<project-icestorm.sh> installer like so:

    $ ./nix-makeself.pl -f icestorm.nix

The created './project-icestorm.sh' installer will package all the given
packages into the installer for you, automatically. This case is more robust
because it allows much more flexibility in specifying the package set; for
example, you could 'import' a custom version of nixpkgs and your own package
sets.

=head1 DECLARATIVE FILE SPECIFICATIONS

Lorem ipsum...

=head1 INCLUDING EXTRA DATA FILES

Lorem ipsum...

=head1 STARTUP SCRIPT

A single "startup script" may be specified that will be run upon extraction of
the installer program. This program is run from I<within> the unpacked directory
created by the installer, after extraction. The program may be global (such as
L<echo(1)>), but may also be a program inside the tarball itself. It can even be
a Nix program, provided B<nix-makeself> has wrapped the program with the bind
mount program appropriately.

If the program is inside the installer directory (e.g. you are executing a Nix
program), you MUST prefix the program path with B<./> to indicate the relative
path to the executable, inside the directory.

For example, assuming we package "GNU Hello", we can have it print its version
information immediately when the installer executes and extracts the Nix
closure:

    hello = {
      label = "GNU Hello";
      startup = "./bin/hello --version";
      pkgs = [ pkgs.hello ];
    };

In either case, whether a startup script is specified or not, B<nix-makeself>
first checks for user namespace support and, if it is not available, throws up a
helpful warning before continuing to execute the specified startup script.

Note that like L<makeself(1)>, the startup script I<can> provide arguments to
the program it executes, but for more complex scripts you are encouraged to
include a more complex startup script as a separate program. This is luckily
quite easy to achieve with Nix by simply creating a new derivation with your
tool inside of it, and including it inside your installer. You may then just
point the B<startup> attribute to point to this program.

=head1 REQUIREMENTS

Packages created with B<nix-makeself> have two main requirements that must be
satisfied by Linux systems on which the binaries will run:

=over

=item B<Bash must be available>

Bash is required for the wrapper scripts that execute programs under the
mystical nix bind mount. (This is not a design choice, simply a technical
limitation.)

=item B<User namespaces must be available>

User namespace support (kernel option B<CONFIG_USERNS> and B<CLONE_NEWUSER> flag
to L<unshare(2)>) is required in order to execute programs packaged by
B<nix-makeself>. This is a hard limitation/design choice that cannot be lifted
easily.

B<CONFIG_USERNS> and B<CONFIG_NEWUSER> are available in Linux 3.8 and later,
though in practice it may be disabled/botched on your kernel. See B<BUGS> below.

=back

=head1 HOW BINARIES ARE SELECTED

Currently, B<nix-makeself> looks at each of the store paths you provide to it
and examines them for B</bin> subdirectories. If these directories exist, all of
the files in the bin directory are wrapped with a shell script that executes the
program under B<nix-makeself-run> (see B<INTERNALS> below.) These wrapper
programs are then installed in the B</bin> subdirectory of the package created
by B<makeself>. The wrappers are intended to be executed by users.

Note that I<dependencies> of the paths you provide will not have their B</bin>
subdirectories examined; this is only for top-level packages you provide. It is
assumed the tool will be able to load/find paths in the store that it needs
otherwise (e.g. by having the path embedded at build time.)

=head1 INTERNALS

As a whole, B<nix-makeself> is split into two components: creating the installer
using B<nix-makeself> the script, and running programs in the store using a
packaged tool called B<nix-makeself-run>.

Internally, B<nix-makeself> is a monstrosity that is written in 3 programming
languages at once to retain its simple, single-file nature. It is intended to be
I<simple for users>, that does not mean it's actually simple.

=head2 nix-makeself

Lorem ipsum...

=head2 nix-makeself-run

The bind-mount execution tool, B<nix-makeself-run>, is a statically linked
binary that is prepared by B<nix-makeself> upon execution, and always included
in the closure of the Nix store that is packaged. It wraps the execution of
every binary that the user sees, and mounts B</nix> before executing the
underlying program.

=head3 Static linking

This tool is created internally by B<nix-makeself> using L<nix-build(1)>, and is
statically linked against glibc in order to make sure that it can execute on any
Linux system. Static linking is also a necessary requirement, besides making a
"portable" binary: because B<nix-makeself-run> is compiled with Nix, it too,
would need the B</nix> store mounted before execution if it was not statically
linked -- it would be linked against B</nix/store/...-glibc/lib/libc.so.6>
dynamically, requiring the mount to already exist before its execution, creating
a difficult bootstrapping problem.

=head3 Compiling nix-makeself-run

The B<nix-makeself-run> tool is compiled with a specific version of Nixpkgs, and
is intended to have a minimal closure. You can control the version of Nixpkgs
that is used to fetch the compiler used to compile the C source code using the
B<--nixpkgs> argument. If you fixed a copy of Nixpkgs (e.g. using
B<builtins.fetchTarball>) and could retrieve it by importing the file
B<./nixpkgs.nix> in your project, you can build B<nix-makeself-run> using this
version:

    $ ./nix-makeself.pl --nixpkgs '(import ./nixpkgs.nix)' ...

This flag is mostly an optimization: while B<nix-makeself-run> is always
statically linked, it depends at minimum on the B<stdenv> derivation. Thus, by
specifying this flag, you can ensure the resulting binary shares a copy of
B<stdenv> (and other basic dependencies) with the existing copies in the binary
installer that will be created, by making sure they use the same base version of
nixpkgs.

=head3 How it runs

The B<nix-makeself-run> tool performs a few simple steps in order to set up the
Nix store appropriately before calling L<execvp(2)>:

=over

=item B<Step 1: Create new user/mount namespace>

As a first step, we begin by creating a new set of mount/user namespaces, so
that we can create new private mount points, and also create mounts that would
otherwise be restricted (like rebinding / dirs).

If this does not work (because your kernel forbids it, or is too old), then
B<nix-makeself-run> will immediately fail. Unfortunately it does not make a cool
explosion sound if this happens, but in a future version it might.

=item B<Step 2: Create temporary / dir, and bind mount / entries>

Next, we create a temporary directory under B<$XDG_RUNTIME_DIR> and use this as
the temporary root directory for the process that will execute.

After this directory is created, we recursively bind mount (with B<mount(...,
MS_BIND | MS_REC))>) the directory entries under / on the host system to entries
in the temporary directory. We skip non-directories, and special-case skip
pre-existing B</nix> directories as well.

=item B<Step 3: Bind the store into /nix>

With the existing mounts already created, we finally bind mount B</nix> inside
the temporary directory to the store location that was unpacked by the
installer. This step completes the filesystem rebinding process, and the
temporary directory now reflects a process-private recursive bind of /,
augmented with a customized B</nix>.

=item B<Step 4: Update user namespace UID/GID mappings>

Next, after the bind mounts are created inside the namespace, we proceed by
mapping UIDs/GIDs inside the namespace to ones outside of it. Normally, once the
namespace is created, L<getuid(2)> and L<getgid(2)> calls would return unmapped
UIDs/GIDs. Mapping the UIDs of the parent namespace to the created namespace
fixes this.

This is done by writing to two files, B</proc/self/uid_map> and
B</proc/self/gid_map>. These define ranges of UIDs/GIDs that map from the
(currently) executing process to the process that created it, i.e. it is a
mapping from parent IDs to current (unmapped) IDs in the created namespace.

See L<user_namespaces(7)>, section "User and group ID mappings: uid_map and
gid_map", for ore information.

=item B<Step 5: Update process chroot>

Lorem ipsum...

=item B<Step 6: Execute program>

Before executing the program, we make sure to export the B<NIX_CONF_DIR>
environment variable to the subprocess that will be created. This allows B<nix>
based tools to find their configuration files, and it allows installers to ship
e.g. L<nix.conf(5)> for those tools. B<NIX_CONF_DIR> is exported to
B</nix/etc/nix>, e.g. it is located inside the Nix store of the binary package.

Finally, we can simply call L<execvp(2)> on the specified program, with the
specified arguments, to execute it.

=back

=head1 BUGS

Yes. Current known bugs that you might run into include:

=over

=item B<Horrid internals>

Attempting to debug this program may hurt you because the source code is awful.
Do not taunt Happy Fun Ball.

=item B<Requires user namespaces>

B<nix-makeself> uses two major features of the Linux namespace subsystem: mount,
and user namespaces. While mount namespaces aren't normally a problem, user
namespaces are somewhat tricky in modern distributions: security and instability
issues have often caused them to be disabled in kernel builds. Make sure
B<CONFIG_USERNS> is enabled in your kernel configuration.

=item B<Does not support upgrades>

There's currently no support for incrementally upgrading, rolling back or
garbage collecting the indirect store created by B<nix-makeself>. As a result
your users will simply need to install new versions next to the old one.

=item B<Does not support Nix signatures>

The exported indirect store is exported without signatures and used the same
way. This is not fundamental but simply a technical limitation.

This is a pre-requisite to supporting secure upgrades and rollbacks.

=item B<Declarative specifications can only declare one package>

Only a single package is supported in a declarative specification file for
creating installers. Nothing fundamentally presents multiple installers
in a single file declarative file; this is simply a technical limitation.

As a workaround, you can share code using ordinary Nix B<import> semantics and
have a declarative file, per-installer, that simply reuses the code. The
following example assumes a common I<common.nix> file with a 'my-installer'
attribute exists:

    {
      my-installer = (import ./common.nix).my-installer;
    }

=item B<No support for declarative file arguments>

The usual arguments B<--arg> and B<--argstr> available to most Nix-based
evaluation tools are not available when evaluating a declarative specification.
Declarative files are currently expected to evaluate directly to an attrset with
no arguments.

This is simply a technical limitation and may be lifted in the future.

=item B<Only supports Nix 2.0 for package creation>

Nix 1.11 is not supported when creating packages, although this is not a
fundamental design decision and could be lifted in the future.

Nix 2.0 (or any Nix installation at all) is I<not> required to use packages
created with B<nix-makeself>.

=item B<Assumes the store location is I</nix/store>>

The user namespace remount of the indirect store created by B<nix-makeself>
assumes the original store path was B</nix/store> -- that is, the indirect store
is mounted into B</nix/store> upon execution. As a result, B<nix-makeself>
currently does not work with binary caches with different store directories.

=item B<Leaves around temporary directories>

When you run an executable packaged with B<nix-makeself>, it creates a directory
with bind mounts into / for local execution. This directory is created under
B<$XDG_RUNTIME_DIR>, but is not removed after it's used. This results in the
creation of many 'nix-XXXXXX' directories under B<$XDG_RUNTIME_DIR>.

=back

nix-makeself is developed here, where you may report many bugs, and where some
might be fixed: L<https://github.com/thoughtpolice/nix-makeself>

=head1 SEE ALSO

L<nix(1)>, L<makeself(1)>, L<unshare(2)>, L<user_namespaces(7)>

=head1 AUTHORS

nix-makeself was written by, and is currently maintained by, L<Austin
Seipp|https://inner-haven.net>.

=head1 COPYRIGHT

Copyright (C) 2018 Austin Seipp. License:
L<MIT|https://opensource.org/licenses/MIT> -- this is open source software: you
are free to change and redistribute it. There is NO WARRANTY, to the extent
permitted by law.

=head1 COLOPHON

This page is part of release 0.0 of the nix-makeself project.
