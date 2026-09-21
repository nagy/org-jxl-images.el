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

;; Org's preview hide path calls `image-flush', which signals "Window
;; system frame should be used" in batch mode.  The tests never display
;; images, so stub it out.
(advice-add 'image-flush :override #'ignore)

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
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (org-jxl-refresh-images)
      (should (= 1 (length org-jxl--decode-cache)))
      (org-jxl-refresh-images)
      (should (= 1 (length org-jxl--decode-cache))))
    (kill-buffer buf)))

(ert-deftest org-jxl-decode-cache-max-obsolete-alias ()
  "The old internal name resolves to the public cache option."
  (should (eq (indirect-variable 'org-jxl--decode-cache-max)
              (indirect-variable 'org-jxl-decode-cache-max))))

(ert-deftest org-jxl-decode-cache-max-evicts-oldest ()
  "Beyond `org-jxl-decode-cache-max' entries the oldest are evicted."
  (let ((buf (org-jxl-test--with-org-buffer ""))
        (org-jxl-decode-cache-max 2))
    (with-current-buffer buf
      (cl-letf (((symbol-function 'org-jxl--run-djxl)
                 (lambda (s) (concat "png:" s))))
        (org-jxl--decode-to-png "one")
        (org-jxl--decode-to-png "two")
        (org-jxl--decode-to-png "three"))
      (should (= 2 (length org-jxl--decode-cache)))
      (should-not (assoc "one" org-jxl--decode-cache))
      (should (assoc "three" org-jxl--decode-cache)))
    (kill-buffer buf)))

(ert-deftest org-jxl-mode-disable-clears-cache ()
  "Disabling the mode should drop the decode cache."
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

(ert-deftest org-jxl-insert-base64-rejects-invalid-chars ()
  "`org-jxl-insert-base64' rejects strings that are not base64."
  (let ((buf (org-jxl-test--with-org-buffer "")))
    (with-current-buffer buf
      (dolist (bad (list "dGVzdC1kYXRh-"          ; trailing dash
                         "not base64!!"           ; punctuation
                         "aGVsbG8 gd29ybGQ="))   ; embedded space
        (kill-new bad)
        (should-error (org-jxl-insert-base64))))
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

;;; Decode failures

(ert-deftest org-jxl-decode-failure-leaves-no-overlay ()
  "A failing decoder leaves the block text visible, with no overlay."
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (let ((org-jxl-djxl-program "false"))
        (org-jxl-inline-mode 1))
      (should-not org-jxl--overlays))
    (kill-buffer buf)))

(ert-deftest org-jxl-decode-empty-output-leaves-no-overlay ()
  "Empty decoder output counts as failure, not an empty image."
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (let ((org-jxl-djxl-program "true"))
        (org-jxl-inline-mode 1))
      (should-not org-jxl--overlays))
    (kill-buffer buf)))


;;; External viewer cleanup

(ert-deftest org-jxl-cleanup-delay-configurable ()
  "The cleanup timer uses `org-jxl-external-cleanup-delay', not a hardcode."
  (let ((org-jxl-external-cleanup-delay 5)
        (tmp (make-temp-file "org-jxl-test-view-" nil ".png"))
        scheduled)
    (should (> org-jxl-external-cleanup-delay 2))
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (secs repeat fn &rest files)
                 (ignore repeat fn)
                 (setq scheduled (cons secs files)))))
      (org-jxl--temp-file-cleanup tmp))
    (should (equal (car scheduled) org-jxl-external-cleanup-delay))
    (should (equal (cdr scheduled) (list tmp)))
    (should (file-exists-p tmp))
    (delete-file tmp)))

(ert-deftest org-jxl-cleanup-deletes-file ()
  "The scheduled cleanup eventually removes the temporary file."
  (let ((org-jxl-external-cleanup-delay 0.1)
        (tmp (make-temp-file "org-jxl-test-view-" nil ".png")))
    (org-jxl--temp-file-cleanup tmp)
    (should (file-exists-p tmp))
    (sit-for 1)
    (should-not (file-exists-p tmp))))


;;; External viewer

(ert-deftest org-jxl-find-image-pos-inside-contents ()
  "Point on the base64 resolves to the containing JXL block start."
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (search-forward org-jxl-test--valid-jxl-b64)
      (let* ((pos (match-beginning 0))
             (start (org-jxl--find-image-pos pos)))
        (should start)
        (should (< start pos))))
    (kill-buffer buf)))

(ert-deftest org-jxl-open-external-from-inside-block ()
  "`org-jxl-open-external' works with point on the base64 contents."
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (search-forward org-jxl-test--valid-jxl-b64)
      (goto-char (match-beginning 0))
      (let (opened)
        (cl-letf (((symbol-function 'browse-url-of-file)
                   (lambda (file) (setq opened file))))
          (org-jxl-open-external))
        (should opened)
        (should (file-exists-p opened))
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert-file-contents-literally opened)
          (should (equal (buffer-substring-no-properties 1 5)
                         (unibyte-string ?\x89 ?P ?N ?G))))
        (delete-file opened)))
    (kill-buffer buf)))

(ert-deftest org-jxl-open-external-rejects-non-jxl-block ()
  "Point inside a non-JXL special block still signals a user error."
  (let ((buf (org-jxl-test--with-org-buffer
              "#+BEGIN_FOO\nsome text\n#+END_FOO\n")))
    (with-current-buffer buf
      (search-forward "some text")
      (goto-char (match-beginning 0))
      (should-error (org-jxl-open-external) :type 'user-error))
    (kill-buffer buf)))


;;; Overlay scoping

(ert-deftest org-jxl-overlay-excludes-markers ()
  "The overlay covers only the contents; markers stay visible."
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (org-jxl-inline-mode 1)
      (should (= 1 (length org-jxl--overlays)))
      (let* ((ov (car org-jxl--overlays))
             (contents-begin (save-excursion
                               (goto-char (point-min))
                               (forward-line 1)
                               (line-beginning-position)))
             (contents-end (save-excursion
                             (goto-char (point-max))
                             (forward-line -1)
                             (line-beginning-position))))
        (should (= (overlay-start ov) contents-begin))
        (should (= (overlay-end ov) contents-end))))
    (kill-buffer buf)))

(ert-deftest org-jxl-edit-rescopes-overlay ()
  "An edit inside the block re-scopes the overlay to the new contents."
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (org-jxl-inline-mode 1)
      (let ((old (car org-jxl--overlays)))
        (goto-char (overlay-start old))
        (insert "\n")           ; whitespace: decode unaffected
        (let* ((ov (car org-jxl--overlays))
               (el (org-element-at-point (point-min))))
          (should (= 1 (length org-jxl--overlays)))
          (should-not (eq ov old))
          (should (= (overlay-start ov)
                     (org-element-property :contents-begin el)))
          (should (= (overlay-end ov)
                     (org-element-property :contents-end el))))))
    (kill-buffer buf)))

(ert-deftest org-jxl-marker-deletion-clears-overlay ()
  "Deleting the markers drops the orphaned overlay."
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (org-jxl-inline-mode 1)
      (should (= 1 (length org-jxl--overlays)))
      (delete-region (point-min)                    ; kill #+BEGIN_JXL line
                     (save-excursion (goto-char (point-min))
                                     (forward-line 1) (point)))
      (should-not org-jxl--overlays))
    (kill-buffer buf)))
;;; Org link preview integration

(ert-deftest org-jxl-overlay-registered-with-link-preview ()
  "JXL overlays join `org-link-preview-overlays' and mark `org-image-overlay'."
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (org-jxl-inline-mode 1)
      (let ((ov (car org-jxl--overlays)))
        (should (memq ov org-link-preview-overlays))
        (should (overlay-get ov 'org-image-overlay))))
    (kill-buffer buf)))

(ert-deftest org-jxl-toggle-hides-and-shows-in-lockstep ()
  "One toggle hides JXL blocks and link previews; the next shows both."
  (let ((png-file (make-temp-file "org-jxl-test-link-" nil ".png"))
        (buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (unwind-protect
        (progn
          ;; An ordinary image link next to the JXL block.
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert (org-jxl--decode-to-png org-jxl-test--valid-jxl-b64))
            (write-region (point-min) (point-max) png-file nil 'silent))
          (with-current-buffer buf
            (goto-char (point-max))
            (insert (format "[[file:%s]]\n" png-file))
            (org-jxl-inline-mode 1)
            (should (= 1 (length (org-link-preview--get-overlays))))
            ;; Org only previews image links on graphic displays; fake
            ;; one so its own preview runs under batch mode.
            (cl-letf (((symbol-function 'display-graphic-p)
                       (lambda (&rest _) t)))
              ;; Hide, then show: the link preview joins the JXL block.
              (org-toggle-inline-images)
              (should-not (org-link-preview--get-overlays))
              (should-not (cl-some #'overlay-buffer org-jxl--overlays))
              (org-toggle-inline-images)
              (should (= 2 (length (org-link-preview--get-overlays))))
              (should (= 1 (cl-count-if #'overlay-buffer org-jxl--overlays)))
              ;; A single toggle now hides both.
              (org-toggle-inline-images)
              (should-not (org-link-preview--get-overlays))
              (should-not (cl-some #'overlay-buffer org-jxl--overlays))
              (org-toggle-inline-images)
              (should (= 2 (length (org-link-preview--get-overlays))))
              (should (= 1 (cl-count-if #'overlay-buffer org-jxl--overlays))))))
      (delete-file png-file)
      (kill-buffer buf))))

(ert-deftest org-jxl-toggle-cycle-does-not-re-decode ()
  "Hiding and re-showing never runs the decoder again."
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (org-jxl-inline-mode 1)
      (let ((cache-size (length org-jxl--decode-cache))
            (decodes 0))
        (cl-letf (((symbol-function 'org-jxl--run-djxl)
                   (lambda (_) (cl-incf decodes) nil)))
          (org-toggle-inline-images)
          (org-toggle-inline-images))
        (should (= 0 decodes))
        (should (= cache-size (length org-jxl--decode-cache))))
      ;; Re-shown image is a live overlay again.
      (should (= 1 (cl-count-if #'overlay-buffer org-jxl--overlays))))
    (kill-buffer buf)))

(ert-deftest org-jxl-mode-off-buffer-stays-untouched ()
  "The preview advice ignores buffers without `org-jxl-inline-mode'."
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (org-link-preview-region)
      (should-not org-jxl--overlays))
    (kill-buffer buf)))

(ert-deftest org-jxl-advice-survives-mode-disable ()
  "Disabling the mode in one buffer leaves the preview advice installed."
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (org-jxl-inline-mode 1)
      (org-jxl-inline-mode -1))
    (should (advice-member-p #'org-jxl--after-link-preview
                             'org-link-preview-region))
    (kill-buffer buf)))

(ert-deftest org-jxl-hiding-unregisters-overlays ()
  "Hiding drops JXL overlays from `org-link-preview-overlays'."
  (let ((buf (org-jxl-test--with-org-buffer
              (format "#+BEGIN_JXL\n%s\n#+END_JXL\n"
                      org-jxl-test--valid-jxl-b64))))
    (with-current-buffer buf
      (org-jxl-inline-mode 1)
      (should (= 1 (length org-link-preview-overlays)))
      (org-toggle-inline-images)
      (should-not org-link-preview-overlays)
      ;; Disabling afterwards must not resurrect anything.
      (org-jxl-inline-mode -1)
      (should-not org-link-preview-overlays))
    (kill-buffer buf)))


;;; Version guard

(ert-deftest org-jxl-old-org-rejected-at-load ()
  "Loading against Org older than 9.8 signals an explicit error."
  (cl-letf (((symbol-function 'org-version) (lambda (&rest _) "9.6.1")))
    (should-error (load (locate-library "org-jxl-images") nil nil t))))

(ert-deftest org-jxl-current-org-loads-fine ()
  "Loading against the running Org version succeeds."
  (should (load (locate-library "org-jxl-images") nil nil t)))


(provide 'org-jxl-images-tests)
;;; org-jxl-images-tests.el ends here
