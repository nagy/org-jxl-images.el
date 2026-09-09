# AGENTS.md

## Project

Emacs package `org-jxl-images`: minor mode rendering base64-encoded JPEG XL
images in `#+BEGIN_JXL ... #+END_JXL` Org blocks. Shells out to `djxl`/`cjxl`
from libjxl.

## Build

Nix flake (flake-parts + melpaBuild), no default.nix:

- `nix build` — build the package
- `nix flake check` — byte-compile with warnings-as-errors + run ERT tests
- `nix fmt` — format flake via treefmt (nixfmt)

## Conventions

- New `*.el` files must be `git add`ed before `nix build` sees them.
- Version format: `<version>-unstable-<YYYY-MM-DD of last commit>` until tagged.
- Keep flake.nix comments explaining non-obvious Nix lines.
