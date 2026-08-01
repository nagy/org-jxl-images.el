;;; org-jxl-images-tests.el --- Tests for org-jxl-images -*- lexical-binding: t -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with this file.  If not, see
;; <https://www.gnu.org/licenses/>.

;; To run these tests:
;;
;;   (require 'org-jxl-images)
;;   (require 'ert)
;;
;; Then: M-x ert RET t

(require 'org-jxl-images)
(require 'ert)

;;; Helpers

(defun org-jxl-test--with-org-buffer (content)
  "Create a temporary `org-mode' buffer with CONTENT and return it."
  (let ((buf (generate-new-buffer " *org-jxl-test*")))
    (with-current-buffer buf
      (org-mode)
      (insert content)
      (goto-char (point-min)))
    buf))

;; A valid 1x1 white JPEG XL image, base64-encoded (57 bytes raw).
(defconst org-jxl-test--valid-jxl-b64
  "/woAkAEAE4gCALQAtZ8gAAAVKqOMG7yc6/nyQ4fFtI3rDG21bWEJY7O9MEhIOGyY4s3xwRATlSQA"
  "Base64-encoded 1x1 white JPEG XL image for tests.")


;;; Block detection

(ert-deftest org-jxl-detect-single-block ()
  "A single JXL block is detected and an overlay is created."
  (skip-unless (executable-find org-jxl-djxl-program))
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (org-jxl-inline-mode 1)
      (should org-jxl--overlays)
      (should (= 1 (length org-jxl--overlays))))
    (kill-buffer buf)))

(ert-deftest org-jxl-detect-multiple-blocks ()
  "Multiple JXL blocks should each get an overlay."
  (skip-unless (executable-find org-jxl-djxl-program))
  (let ((block (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                       org-jxl-test--valid-jxl-b64)))
    (let ((buf (org-jxl-test--with-org-buffer
                (concat block "Some text in between.\n" block))))
      (with-current-buffer buf
        (org-jxl-inline-mode 1)
        (should (= 2 (length org-jxl--overlays))))
      (kill-buffer buf))))

(ert-deftest org-jxl-block-with-leading-whitespace ()
  "Blocks with leading whitespace before the #+BEGIN_JXL marker are detected."
  (skip-unless (executable-find org-jxl-djxl-program))
  (let ((buf (org-jxl-test--with-org-buffer
              (format "  #+BEGIN_JXL\n%s\n  #+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (org-jxl-inline-mode 1)
      (should org-jxl--overlays)
      (should (= 1 (length org-jxl--overlays))))
    (kill-buffer buf)))


;;; Mode toggling

(ert-deftest org-jxl-mode-enable-disable ()
  "Enabling and disabling the mode should add/remove overlays."
  (skip-unless (executable-find org-jxl-djxl-program))
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      ;; Enable
      (org-jxl-inline-mode 1)
      (should org-jxl-inline-mode)
      (should org-jxl--overlays)
      ;; Disable
      (org-jxl-inline-mode -1)
      (should-not org-jxl-inline-mode)
      (should-not org-jxl--overlays))
    (kill-buffer buf)))

(ert-deftest org-jxl-mode-off-by-default ()
  "The minor mode should be off when entering org-mode."
  (let ((buf (org-jxl-test--with-org-buffer "* Test\n")))
    (with-current-buffer buf
      (should-not org-jxl-inline-mode)
      (should-not org-jxl--overlays))
    (kill-buffer buf)))


;;; Output validity

(ert-deftest org-jxl-output-is-valid-png ()
  "The decoded image data should be valid PNG (starts with \\x89PNG)."
  (skip-unless (executable-find org-jxl-djxl-program))
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (org-jxl-inline-mode 1)
      (should org-jxl--overlays)
      (let* ((ov (car org-jxl--overlays))
             (disp (overlay-get ov 'display))
             (data (plist-get (cdr disp) :data)))
        (should data)
        (should (>= (length data) 4))
        (should (equal (substring data 0 4)
                       (unibyte-string ?\x89 ?P ?N ?G)))))
    (kill-buffer buf)))


;;; Refresh

(ert-deftest org-jxl-refresh-removes-old-overlays ()
  "Calling refresh twice should not leak overlays."
  (skip-unless (executable-find org-jxl-djxl-program))
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (org-jxl-refresh-images)
      (should (= 1 (length org-jxl--overlays)))
      (org-jxl-refresh-images)
      (should (= 1 (length org-jxl--overlays))))
    (kill-buffer buf)))

(ert-deftest org-jxl-decode-cache-reuses-png ()
  "Refreshing unchanged blocks should not grow the decode cache."
  (skip-unless (executable-find org-jxl-djxl-program))
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (org-jxl-refresh-images)
      (should (= 1 (length org-jxl--decode-cache)))
      (org-jxl-refresh-images)
      (should (= 1 (length org-jxl--decode-cache))))
    (kill-buffer buf)))

(ert-deftest org-jxl-mode-disable-clears-cache ()
  "Disabling the mode should drop the decode cache."
  (skip-unless (executable-find org-jxl-djxl-program))
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (org-jxl-inline-mode 1)
      (should org-jxl--decode-cache)
      (org-jxl-inline-mode -1)
      (should-not org-jxl--decode-cache))
    (kill-buffer buf)))


;;; Insertion helpers

(ert-deftest org-jxl-insert-base64-produces-block ()
  "`org-jxl-insert-base64' should insert a properly wrapped block."
  (let ((buf (org-jxl-test--with-org-buffer "")))
    (with-current-buffer buf
      (kill-new "dGVzdC1kYXRh")
      (org-jxl-insert-base64)
      (goto-char (point-min))
      (should (search-forward "#+BEGIN_JXL" nil t))
      (should (search-forward "dGVzdC1kYXRh" nil t))
      (should (search-forward "#+END_JXL" nil t)))
    (kill-buffer buf)))

(ert-deftest org-jxl-insert-base64-empty-kill-ring ()
  "`org-jxl-insert-base64' signals an error when the kill ring is too short."
  (let ((buf (org-jxl-test--with-org-buffer "")))
    (with-current-buffer buf
      (kill-new "short")
      (should-error (org-jxl-insert-base64)))
    (kill-buffer buf)))


;;; Mode only active in org-mode

(ert-deftest org-jxl-refresh-only-in-org-mode ()
  "`org-jxl-refresh-images' should do nothing outside org-mode."
  (let ((buf (generate-new-buffer " *org-jxl-test*")))
    (with-current-buffer buf
      (fundamental-mode)
      (insert (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))
      (org-jxl-inline-mode 1)
      (should-not org-jxl--overlays))
    (kill-buffer buf)))

(provide 'org-jxl-images-tests)
;;; org-jxl-images-tests.el ends here
