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
          inherit (pkgs.emacsPackages) melpaBuild;
          treefmt = treefmt-nix.lib.evalModule pkgs {
            # nixfmt for the flake itself; nothing else to format in a
            # pure-Elisp repo (no rustfmt/taplo needed).
            programs.nixfmt.enable = true;
          };
        in
        {
          packages.org-jxl-images = melpaBuild {
            pname = "org-jxl-images";
            # Nix rejects versions Nixpkgs cannot parse. Convention for
            # unreleased packages: <upstream-version>-unstable-<YYYY-MM-DD>,
            # where the date is the last commit touching the source.
            version = "0.1.0-unstable-2026-08-02";

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

              # The tests decode real JXL data, so djxl must be reachable
              # via PATH (the package's defcustom points at the absolute
              # libjxl path after postPatch, but the tests use
              # `executable-find`).
              export PATH=${lib.getBin pkgs.libjxl}/bin:$PATH

              emacs --batch -L . \
                -l org-jxl-images-tests.el \
                -f ert-run-tests-batch-and-exit

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
          };

          packages.default = config.packages.org-jxl-images;

          checks.default = config.packages.org-jxl-images;

          formatter = treefmt.config.build.wrapper;

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
