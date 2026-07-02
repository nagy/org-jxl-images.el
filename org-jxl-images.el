;;; org-jxl-images.el --- Inline JPEG XL images in Org mode -*- lexical-binding: t -*-

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

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Keywords: multimedia, org
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/nagy/org-jxl-images

;;; Commentary:

;; This package provides `org-jxl-inline-mode', a minor mode that
;; renders base64-encoded JPEG XL (JXL) images stored inside
;; #+BEGIN_JXL ... #+END_JXL blocks as inline images in Org buffers.
;;
;; JPEG XL compresses screenshots efficiently, and storing the data
;; inside the Org file keeps everything self-contained — no loose
;; image files, clean Git history, portable notes.
;;
;; Usage:
;;     ;; Activate manually per buffer:
;;     M-x org-jxl-inline-mode RET
;;
;;     ;; Or auto-enable for all Org files:
;;     (add-hook 'org-mode-hook #'org-jxl-inline-mode)
;;
;; Paste base64-encoded JXL data from the kill ring:
;;     M-x org-jxl-insert-base64 RET
;;
;; Requirements:
;;     - djxl (JPEG XL decoder, part of libjxl)

;;; Code:

(require 'org)
(require 'org-element)

(defgroup org-jxl nil
  "Inline JPEG XL images in Org mode."
  :group 'org
  :prefix "org-jxl-")

(defcustom org-jxl-djxl-program "djxl"
  "Path to the djxl executable for decoding JPEG XL to PNG."
  :type 'string
  :group 'org-jxl)

(defcustom org-jxl-cjxl-program "cjxl"
  "Path to the cjxl executable for encoding images to JPEG XL."
  :type 'string
  :group 'org-jxl)

(defun org-jxl--create-image (png-data)
  "Create an image from PNG-DATA, respecting Org's width settings."
  (let ((img (create-image png-data 'png t :ascent 'center))
        (width nil))
    (when (and (boundp 'org-image-actual-width)
               org-image-actual-width
               (not (eq org-image-actual-width t)))
      (setq width (if (functionp org-image-actual-width)
                      (funcall org-image-actual-width
                               (car (image-size img t)))
                    org-image-actual-width))
      (when (floatp width)
        (setq width (* width (car (image-size img t)))))
      (when (and width (> width 0))
        (setq img (append img (list :width (truncate width))))))
    img))

(defvar-local org-jxl--overlays nil
  "List of image overlays created by `org-jxl-inline-mode'.")

(defun org-jxl--change-major-mode ()
  "Disable JXL inline mode when leaving the current major mode."
  (org-jxl-inline-mode -1))


;;; Overlay management

(defun org-jxl--delete-overlays ()
  "Remove all JXL image overlays in the current buffer."
  (setq org-jxl--overlays
        (cl-remove-if-not #'overlay-buffer org-jxl--overlays))
  (mapc #'delete-overlay org-jxl--overlays)
  (setq org-jxl--overlays nil))

(defun org-jxl--decode-and-render (start end base64-str)
  "Decode BASE64-STR with djxl and place an image overlay from START to END."
  (let ((source-buffer (current-buffer))
        (jxl-file (make-temp-file "org-jxl-" nil ".jxl")))
    ;; Decode base64, write binary JXL to temp file
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (let ((coding-system-for-write 'binary)
            (coding-system-for-read 'binary))
        (insert base64-str)
        (goto-char (point-min))
        (while (re-search-forward "[ \t\n\r]+" nil t)
          (replace-match ""))
        (base64-decode-region (point-min) (point-max))
        (write-region (point-min) (point-max) jxl-file nil 'silent)))
    ;; Feed to djxl, capture PNG on stdout
    (unwind-protect
        (condition-case err
            (let* ((png-data
                    (with-temp-buffer
                      (set-buffer-multibyte nil)
                      (let ((coding-system-for-write 'binary)
                            (coding-system-for-read 'binary))
                        (call-process org-jxl-djxl-program nil
                                     (list (current-buffer) nil) nil
                                     jxl-file "-" "--output_format" "png")
                        (buffer-string))))
                   (img (org-jxl--create-image png-data)))
              (with-current-buffer source-buffer
                (let ((ov (make-overlay start end)))
                  (overlay-put ov 'display img)
                  (overlay-put ov 'evaporate t)
                  (push ov org-jxl--overlays))))
          (error (message "Failed to render JXL block image: %s"
                         (error-message-string err))
                 nil))
      (ignore-errors (delete-file jxl-file)))))


;;; Block scanning

(defun org-jxl-refresh-images ()
  "Scan the buffer for #+BEGIN_JXL blocks and render them as inline images."
  (interactive)
  (when (derived-mode-p 'org-mode)
    (org-jxl--delete-overlays)
    (org-element-map (org-element-parse-buffer) 'special-block
      (lambda (block)
        (when (string-equal (org-element-property :type block) "JXL")
          (org-jxl--decode-and-render
           (org-element-property :begin block)
           (org-element-property :end block)
           (buffer-substring-no-properties
            (org-element-property :contents-begin block)
            (org-element-property :contents-end block))))))))


;;; Insertion commands

(defun org-jxl--wrap-base64 (b64-string)
  "Wrap B64-STRING in #+BEGIN_JXL / #+END_JXL and insert at point."
  (insert "#+BEGIN_JXL\n")
  (let ((start (point)))
    (insert b64-string)
    (fill-region start (point)))
  (insert "\n#+END_JXL\n"))

;;;###autoload
(defun org-jxl-insert-base64 ()
  "Insert base64-encoded JXL data from the kill ring as a JXL block.
The current top entry of the kill ring is wrapped in
#+BEGIN_JXL ... #+END_JXL."
  (interactive)
  (let ((b64 (car kill-ring)))
    (if (and b64 (> (length b64) 10))
        (progn
          (org-jxl--wrap-base64 b64)
          (when (and (boundp 'org-jxl-inline-mode) org-jxl-inline-mode)
            (org-jxl-refresh-images)))
      (user-error "Kill ring does not contain valid base64 data"))))


;;; Minor mode

;;;###autoload
(define-minor-mode org-jxl-inline-mode
  "Minor mode to render base64-encoded JXL data blocks as inline images.

When enabled, scans the Org buffer for blocks of the form:

    #+BEGIN_JXL
    ... base64 data ...
    #+END_JXL

and replaces each block with the rendered JPEG XL image using an
overlay.  Toggling inline images with \\[org-toggle-inline-images]
will also hide/show JXL blocks.

To insert a JXL block, encode your image to base64 externally
(e.g. `cjxl image.png - | base64 -w0 | wl-copy') and run
`org-jxl-insert-base64' or paste it manually."
  :lighter " JXL"
  :keymap nil
  (if org-jxl-inline-mode
      (progn
        (org-jxl-refresh-images)
        (add-hook 'change-major-mode-hook #'org-jxl--change-major-mode nil t)
        (advice-add 'org-toggle-inline-images :after #'org-jxl-refresh-images))
    (org-jxl--delete-overlays)
    (advice-remove 'org-toggle-inline-images #'org-jxl-refresh-images)
    (remove-hook 'change-major-mode-hook #'org-jxl--change-major-mode t)))

(provide 'org-jxl-images)
;;; org-jxl-images.el ends here
