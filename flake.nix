{
  description = "Inline JPEG XL images in Org mode (Emacs package)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      # One nixpkgs closure: the formatter shares our package set.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      nixpkgs,
      treefmt-nix,
      ...
    }:
    # Date of the last commit as YYYY-MM-DD, folded into the version
    # string below.  Flake source info gives it as e.g. "20260921T231157Z".
    let
      sourceInfo = inputs.self.sourceInfo or { };
      lastModifiedDate = sourceInfo.lastModifiedDate or "19700101000000";
      commitDate = "${builtins.substring 0 4 lastModifiedDate}-${
        builtins.substring 4 2 lastModifiedDate
      }-${builtins.substring 6 2 lastModifiedDate}";
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Emacs packages are pure Elisp: no ELF binaries, so evaluate on
      # every Linux arch (and darwin if the deps exist there).
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          system,
          pkgs,
          lib,
          config,
          ...
        }:
        let
          version = "0.1.0-unstable-${commitDate}";

          treefmt = treefmt-nix.lib.evalModule pkgs {
            # nixfmt for the flake itself; nothing else to format in a
            # pure-Elisp repo (no rustfmt/taplo needed).
            programs.nixfmt.enable = true;
          };
        in
        {
          # Overridable, so a consumer can swap the Emacs or the package set:
          #   inputs.org-jxl-images.packages.${system}.org-jxl-images.override
          #   { emacs = pkgs.emacs-nox; }
          packages.org-jxl-images = lib.makeOverridable (
            {
              # `melpaBuild' closes over the Emacs of its package set, so an
              # `emacs' argument on the build does nothing. Build the set
              # against the chosen Emacs instead.
              emacs ? pkgs.emacs,
              emacsPackages ? emacs.pkgs,
              melpaBuild ? emacsPackages.melpaBuild,
              # The flake passes this, so a plain import stays explicit.
              version,
            }:
            melpaBuild {
              pname = "org-jxl-images";
              preferLocalBuild = true;
              inherit version;

              src = lib.cleanSource ./.;

              # The package shells out to djxl/cjxl from libjxl, so rewrite
              # the default executable paths to the Nix store path so the
              # installed package works without anything on $PATH.
              # `lib.getExe'` validates that the binary exists in the package.
              postPatch = ''
                substituteInPlace org-jxl-images.el \
                  --replace-fail 'org-jxl-djxl-program "djxl"' \
                                   'org-jxl-djxl-program "${lib.getExe' pkgs.libjxl "djxl"}"' \
                  --replace-fail 'org-jxl-cjxl-program "cjxl"' \
                                   'org-jxl-cjxl-program "${lib.getExe' pkgs.libjxl "cjxl"}"'
              '';

              # Byte-compilation warnings fail the build. Keep it: it is
              # the cheapest lint the package will ever get.
              turnCompilationWarningToError = true;

              doCheck = true;

              checkPhase = ''
                runHook preCheck

                # melpaBuild stages only the files its `files' spec matches
                # (root *.el), so the test tree has to come back before the
                # glob loader can see it.
                cp -r ${./test} ./test

                # The tests decode real JXL data, so djxl must be reachable
                # via PATH (the package's defcustom points at the absolute
                # libjxl path after postPatch, but the tests use
                # `executable-find`).
                export PATH=${lib.getBin pkgs.libjxl}/bin:$PATH

                # printf repeats "-l %s" once per match, so a new test file
                # needs no flake edit.  failglob makes an empty glob a shell
                # error; the || guard is what fails the build, because
                # without `set -e' the substitution alone would not abort the
                # phase and the run would pass with zero tests.
                shopt -s failglob
                test_args=$(printf -- "-l %s " test/*-test.el) || {
                  echo 'no tests matched test/*-test.el' >&2
                  exit 1
                }
                shopt -u failglob

                # Unquoted $test_args is intentional: the words must split
                # into -l <file> pairs, which is safe because test file names
                # never contain spaces.
                emacs --batch -L . $test_args -f ert-run-tests-batch-and-exit

                runHook postCheck
              '';

              meta = {
                description = "Inline JPEG XL images in Org mode";
                longDescription = ''
                  A minor mode that renders base64-encoded JPEG XL (JXL)
                  images stored in #+BEGIN_JXL ... #+END_JXL blocks as
                  inline images in Org buffers.  Requires djxl and cjxl
                  from libjxl at runtime.
                '';
                # Read from the `;;; org-jxl-images.el ---` file header.
                license = lib.licenses.agpl3Plus;
                homepage = "https://github.com/nagy/org-jxl-images.el";
                maintainers = with lib.maintainers; [ nagy ];
                platforms = lib.platforms.unix;
              };
            }
          ) { inherit version; };

          packages.default = config.packages.org-jxl-images;

          checks.default = config.packages.org-jxl-images;

          # Lint gate on top of the compiler warnings: package-lint for
          # package/MELPA conventions, checkdoc for docstring style.
          checks.lint =
            pkgs.runCommandLocal "org-jxl-images-lint"
              {
                nativeBuildInputs = [
                  (pkgs.emacsPackages.emacsWithPackages (p: [ p.package-lint ]))
                ];
                src = config.packages.org-jxl-images.src;
              }
              ''
                export HOME="$TMPDIR"
                # The test tree is part of the lint surface, so copy every
                # tracked source, not just the package file.
                cp -r "$src"/. .
                # package-lint assumes online ELPA, so this offline build
                # stubs two things: the package's real symbol prefix (file
                # names can be longer than the symbol namespace), and a
                # dependency that normally resolves from an ELPA archive.
                # The stub rides package-initialize, which rebuilds its
                # package state on every call.
                # `package-lint-main-file' is what lets test files join the
                # glob: without it each test file is treated as a package of
                # its own and flagged for a missing Package-Requires header.
                emacs --batch -l package-lint \
                  --eval '(progn
                  (setq package-lint-main-file "org-jxl-images.el")
                  (setq package-lint--sane-prefixes (concat package-lint--sane-prefixes "\\|org-jxl"))
                  (advice-add (quote package-initialize) :after
                    (lambda (&rest _)
                      (push (cons (quote org) (list (package-desc-create :name (quote org) :version (quote (9 8 7)) :reqs nil :kind (quote single) :archive "stub" :summary "stub"))) package-alist))))' \
                  -f package-lint-batch-and-exit \
                  *.el test/*.el
                # checkdoc exits 0 even on findings, so gate on its output.
                # command-line-args-left still holds the file list here:
                # --eval runs before the trailing arguments are visited.
                lint_log=$(emacs --batch -l checkdoc \
                  --eval '(mapc (lambda (f) (checkdoc-file f)) command-line-args-left)' \
                  *.el test/*.el 2>&1)
                if [ -n "$lint_log" ]; then
                  printf '%s\n' "$lint_log"
                  echo "checkdoc reported problems" >&2
                  exit 1
                fi
                touch "$out"
              '';

          formatter = treefmt.config.build.wrapper;
          # Without this the formatter exists but nothing fails on an
          # unformatted file.
          checks.formatting = treefmt.config.build.check inputs.self;

          devShells.default = pkgs.mkShell {
            # Mirror what the package needs at runtime when hacking on
            # it: libjxl tools for decoding, a real Emacs for
            # interactive testing.
            packages = [
              pkgs.emacs
              pkgs.libjxl
            ];
          };
        };
    };
}
