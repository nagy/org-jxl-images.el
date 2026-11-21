# AGENTS.md — org-jxl-images.el

## Purpose

`org-jxl-images.el`: Emacs Lisp package, a minor mode that renders base64-encoded
JPEG XL images in `#+BEGIN_JXL ... #+END_JXL` Org blocks. Shells out to `djxl` and
`cjxl` from libjxl.

## Build and test

- `nix build` — build the package.
- `nix flake check` — the gate.
- `nix fmt` — format the flake through treefmt (nixfmt).

The flake uses flake-parts plus `melpaBuild`. No `default.nix`.

## Rules

- Do not hand-bump the version. The format stays
  `<version>-unstable-<YYYY-MM-DD of last commit>` until a tag lands. The date
  derives from `self.sourceInfo.lastModifiedDate`.
- Keep the `flake.nix` comments that explain a non-obvious Nix line.
