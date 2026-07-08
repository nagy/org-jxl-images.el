{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  emacs ? pkgs.emacs,
  emacsPackages ? emacs.pkgs,
  melpaBuild ? emacsPackages.melpaBuild,
  libjxl ? pkgs.libjxl,
}:

melpaBuild (finalAttrs: {
  pname = "org-jxl-images";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  postPatch = ''
    substituteInPlace org-jxl-images.el \
      --replace-fail 'org-jxl-djxl-program "djxl"' \
                       'org-jxl-djxl-program "${lib.getBin libjxl}/bin/djxl"' \
      --replace-fail 'org-jxl-cjxl-program "cjxl"' \
                       'org-jxl-cjxl-program "${lib.getBin libjxl}/bin/cjxl"'
  '';

  turnCompilationWarningToError = true;

  checkPhase = ''
    runHook preCheck

    emacs --batch -L . \
      -l org-jxl-images-tests.el \
      -f ert-run-tests-batch-and-exit

    runHook postCheck
  '';

  doCheck = true;

  meta = {
    description = "Inline JPEG XL images in Org mode";
    longDescription = ''
      A minor mode that renders base64-encoded JPEG XL (JXL)
      images stored in #+BEGIN_JXL ... #+END_JXL blocks as
      inline images in Org buffers.  Requires djxl and cjxl
      from libjxl at runtime.
    '';
    license = lib.licenses.agpl3Plus;
    homepage = "https://github.com/nagy/org-jxl-images.el";
    maintainers = with lib.maintainers; [ nagy ];
    platforms = lib.platforms.unix;
  };
})
