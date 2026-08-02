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
(require 'browse-url)

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

(defvar-local org-jxl--overlays nil
  "List of image overlays created by `org-jxl-inline-mode'.")

(defvar-local org-jxl--decode-cache nil
  "Alist mapping JXL block base64 contents to decoded PNG data.
Reused across refreshes so unchanged blocks are not decoded again with
`org-jxl-djxl-program'.  Capped at `org-jxl--decode-cache-max' entries,
oldest evicted first.")

(defvar org-jxl--decode-cache-max 64
  "Maximum number of entries kept in `org-jxl--decode-cache'.")

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

(defun org-jxl--run-djxl (base64-str)
  "Decode BASE64-STR with djxl and return PNG data, or nil on error."
  (let ((jxl-file (make-temp-file "org-jxl-" nil ".jxl")))
    (unwind-protect
        (condition-case err
            ;; Decode base64 and write binary JXL to a temp file.
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (let ((coding-system-for-write 'binary)
                    (coding-system-for-read 'binary))
                (insert base64-str)
                (goto-char (point-min))
                (while (re-search-forward "[ \t\n\r]+" nil t)
                  (replace-match ""))
                (base64-decode-region (point-min) (point-max))
                (write-region (point-min) (point-max) jxl-file nil 'silent))
              ;; Feed to djxl, capture PNG on stdout in a fresh buffer so
              ;; `call-process' appends to empty contents.
              (let ((png-data
                     (with-temp-buffer
                       (set-buffer-multibyte nil)
                       (let ((coding-system-for-write 'binary)
                             (coding-system-for-read 'binary))
                         (call-process org-jxl-djxl-program nil
                                       (list (current-buffer) nil) nil
                                       jxl-file "-" "--output_format" "png")
                         (buffer-string)))))
                png-data))
          (error (message "Failed to render JXL block image: %s"
                          (error-message-string err))
                 nil))
      (ignore-errors (delete-file jxl-file)))))



(defun org-jxl--decode-to-png (base64-str)
  "Return PNG data for BASE64-STR, decoding with djxl when not cached.
Entries are cached in `org-jxl--decode-cache' keyed by BASE64-STR;
oldest entries are evicted past `org-jxl--decode-cache-max'."
  (or (cdr (assoc base64-str org-jxl--decode-cache))
      (let ((png-data (org-jxl--run-djxl base64-str)))
        (when png-data
          (setq org-jxl--decode-cache
                (cons (cons base64-str png-data) org-jxl--decode-cache))
          (when (> (length org-jxl--decode-cache) org-jxl--decode-cache-max)
            (setq org-jxl--decode-cache
                  (butlast org-jxl--decode-cache
                           (- (length org-jxl--decode-cache)
                              org-jxl--decode-cache-max)))))
        png-data)))

(defun org-jxl--decode-and-render (start end base64-str)
  "Decode BASE64-STR with djxl and place an image overlay from START to END."
  (let ((png-data (org-jxl--decode-to-png base64-str)))
    (when png-data
      (let ((ov (make-overlay start end)))
        (overlay-put ov 'display (create-image png-data 'png t :ascent 'center))
        (overlay-put ov 'evaporate t)
        (push ov org-jxl--overlays)))))


(defun org-jxl--temp-file-cleanup (tmp)
  "Delete TMP once it has been handed to the system opener.
Give the opener a second to grab the file, then remove it.
The timer is one-shot and fires regardless of open success."
  (run-with-timer 1 nil
                  (lambda (file) (ignore-errors (delete-file file)))
                  tmp))

;;; Block scanning

(defun org-jxl--find-image-pos (&optional pos)
  "Return the start of the JXL block containing POS, or nil.
Returns nil outside `org-mode', so commands using this can be
called safely from any buffer."
  (when (and (derived-mode-p 'org-mode)
             (eq (org-element-type (org-element-at-point pos)) 'special-block))
    pos))

(defun org-jxl-refresh-images ()
  "Scan the buffer for #+BEGIN_JXL blocks and render them as inline images."
  (interactive)
  (when (derived-mode-p 'org-mode)
    (org-jxl--delete-overlays)
    (org-element-map (org-element-parse-buffer) 'special-block
      (lambda (block)
        (when (string-equal (downcase (org-element-property :type block)) "jxl")
          (org-jxl--decode-and-render
           (org-element-property :begin block)
           (org-element-property :end block)
           (buffer-substring-no-properties
            (org-element-property :contents-begin block)
            (org-element-property :contents-end block))))))))


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
    (setq org-jxl--decode-cache nil)
    (advice-remove 'org-toggle-inline-images #'org-jxl-refresh-images)
    (remove-hook 'change-major-mode-hook #'org-jxl--change-major-mode t)))


;;; Insertion commands

;;;###autoload
(defun org-jxl-insert-base64 ()
  "Insert base64-encoded JXL data from the kill ring as a JXL block.
The current top entry of the kill ring is wrapped in
#+BEGIN_JXL ... #+END_JXL."
  (interactive)
  (let ((b64 (current-kill 0)))
    (if (and (stringp b64)
             (> (length b64) 10)
             (not (string-match-p "[^A-Za-z0-9+/=]" b64)))
        (progn
          (insert "#+BEGIN_JXL\n")
          (insert b64)
          (insert "\n#+END_JXL\n")
          (when org-jxl-inline-mode
            (org-jxl-refresh-images)))
      (user-error "Kill ring does not contain valid base64 data"))))

;;;###autoload
(defun org-jxl-open-external ()
  "Open the JXL image at point in an external viewer.
Decodes the block's stored base64 contents on demand, writes the
resulting PNG to a temporary file, and passes it to the user's
configured `browse-url-browser-function' (which picks a suitable
opener per platform, e.g. `xdg-open', `open', or `start').  The
temporary file is deleted shortly after."
  (interactive)
  (let ((pos (point)))
    (unless (org-jxl--find-image-pos pos)
      (user-error "No JXL image at point"))
    (let* ((block (org-element-at-point pos))
           (base64-str (buffer-substring-no-properties
                        (org-element-property :contents-begin block)
                        (org-element-property :contents-end block)))
           (png-data (org-jxl--decode-to-png base64-str)))
      (unless png-data
        (user-error "Failed to decode JXL image at point"))
      (let ((tmp (make-temp-file "org-jxl-view-" nil ".png")))
        (unwind-protect
            (progn
              (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert png-data)
                (write-region (point-min) (point-max) tmp nil 'silent))
              (browse-url-of-file tmp))
          (org-jxl--temp-file-cleanup tmp))))))

(provide 'org-jxl-images)
;;; org-jxl-images.el ends here
