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

(require 'cl-lib)
(require 'org)
(require 'org-element)
;; Org's link preview machinery (Org 9.8+): JXL overlays register with
;; `org-link-preview-overlays' so Org's show/hide covers them too.
(require 'ol)
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

(defcustom org-jxl-external-cleanup-delay 5
  "Seconds before the temporary PNG of `org-jxl-open-external' is deleted.
The delay must outlive the hand-off to the external opener: a busy
`xdg-open' or a first-launch viewer can still be reading the file.
Longer delays favour slow openers; shorter delays litter the temp
directory for less time."
  :type 'number
  :group 'org-jxl)

(defvar-local org-jxl--overlays nil
  "List of image overlays created by `org-jxl-inline-mode'.")

(defvar-local org-jxl--decode-cache nil
  "Alist mapping JXL block base64 contents to decoded PNG data.
Reused across refreshes so unchanged blocks are not decoded again with
`org-jxl-djxl-program'.  Capped at `org-jxl--decode-cache-max' entries,
oldest evicted first.")

(defcustom org-jxl--decode-cache-max 64
  "Maximum number of entries kept in `org-jxl--decode-cache'."
  :type 'integer
  :group 'org-jxl)

(defun org-jxl--change-major-mode ()
  "Disable JXL inline mode when leaving the current major mode."
  (org-jxl-inline-mode -1))


;;; Overlay management

(defun org-jxl--delete-overlays ()
  "Remove all JXL image overlays in the current buffer.
Also unregisters them from `org-link-preview-overlays', keeping
Org's preview bookkeeping free of dead overlays."
  (setq org-jxl--overlays
        (cl-remove-if-not #'overlay-buffer org-jxl--overlays))
  (dolist (ov org-jxl--overlays)
    (setq org-link-preview-overlays (delq ov org-link-preview-overlays))
    (delete-overlay ov))
  (setq org-jxl--overlays nil))

(defun org-jxl--run-djxl (base64-str)
  "Decode BASE64-STR with djxl and return PNG data, or nil on error.
Feeds the decoded JXL stream to djxl on stdin and captures its PNG
stdout, so no temporary files touch disk."
  (condition-case err
      (let ((png-buffer (generate-new-buffer " *org-jxl-png*")))
        (unwind-protect
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (with-current-buffer png-buffer
                (set-buffer-multibyte nil))
              (let ((coding-system-for-read 'binary)
                    (coding-system-for-write 'binary))
                ;; Decode base64 in place; the buffer now holds raw JXL.
                (insert base64-str)
                (goto-char (point-min))
                (while (re-search-forward "[ \t\n\r]+" nil t)
                  (replace-match ""))
                (base64-decode-region (point-min) (point-max))
                ;; "-" on stdin, "-" on stdout; the PNG lands in
                ;; png-buffer instead of the source buffer.
                (let* ((exit-code
                        (call-process-region (point-min) (point-max)
                                             org-jxl-djxl-program
                                             nil (list png-buffer nil) nil
                                             "-" "-" "--output_format" "png"))
                       (png-data (with-current-buffer png-buffer
                                   (buffer-string))))
                  ;; A failed run yields empty output; an empty string is
                  ;; truthy and would blank the block behind an empty image.
                  (when (and (eq exit-code 0) (> (length png-data) 0))
                    png-data))))
          (kill-buffer png-buffer)))
    (error (message "Failed to render JXL block image: %s"
                    (error-message-string err))
           nil)))



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
  "Decode BASE64-STR with djxl and place an image overlay from START to END.
The overlay joins `org-link-preview-overlays' and carries the
`org-image-overlay' property, so Org's own preview machinery
(`org-link-preview-clear', `org-toggle-inline-images') hides and
shows JXL blocks together with ordinary inline images."
  (let ((png-data (org-jxl--decode-to-png base64-str)))
    (when png-data
      (let ((ov (make-overlay start end)))
        (overlay-put ov 'display (create-image png-data 'png t :ascent 'center))
        (overlay-put ov 'evaporate t)
        ;; Register with Org's link preview machinery, as
        ;; `org-link-preview-region' does for its own overlays.
        (overlay-put ov 'org-image-overlay t)
        (overlay-put ov 'modification-hooks
                     (list 'org-link-preview--remove-overlay))
        (push ov org-link-preview-overlays)
        (push ov org-jxl--overlays)))))


(defun org-jxl--temp-file-cleanup (tmp)
  "Delete TMP once it has been handed to the system opener.
Give the opener `org-jxl-external-cleanup-delay' seconds to grab
the file, then remove it.  The timer is one-shot and fires
regardless of open success; raise the delay if a slow opener
still races the deletion."
  (run-with-timer org-jxl-external-cleanup-delay nil
                  (lambda (file) (ignore-errors (delete-file file)))
                  tmp))

;;; Block scanning

(defun org-jxl--find-image-pos (&optional pos)
  "Return the start of the JXL block containing POS, or nil.
POS defaults to point and may sit anywhere inside the block,
including on the base64 contents, which org-element parses as an
inner paragraph; the containing special block is walked up to via
`org-element-lineage'.  The returned position is the start of the
block's #+BEGIN_JXL marker line: the image overlay covers only the
contents between the markers.  Returns nil outside `org-mode',
outside any special block, and for special blocks of other types,
so commands using this can be called safely from any buffer."
  (when (derived-mode-p 'org-mode)
    (let ((block (org-element-lineage (org-element-at-point pos)
                                      '(special-block) t)))
      (when (and block
                 (string-equal (downcase (org-element-property :type block))
                               "jxl"))
        (org-element-property :begin block)))))

(defun org-jxl--block-marker-present-p ()
  "Return non-nil if the buffer may contain a JXL block.
Cheap regexp pre-scan so `org-jxl-refresh-images' can skip the
expensive `org-element-parse-buffer' on buffers without JXL
blocks — the refresh advice runs on every link preview pass."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search t))
      (re-search-forward "^[ \t]*#\\+begin_jxl\\b" nil t))))

(defun org-jxl-refresh-images ()
  "Scan the buffer for #+BEGIN_JXL blocks and render them as inline images."
  (interactive)
  (when (derived-mode-p 'org-mode)
    (org-jxl--delete-overlays)
    (when (org-jxl--block-marker-present-p)
      (org-element-map (org-element-parse-buffer) 'special-block
                       (lambda (block)
                         (when (string-equal (downcase (org-element-property :type block)) "jxl")
                           (let ((contents-begin (org-element-property :contents-begin block))
                                 (contents-end (org-element-property :contents-end block)))
                             ;; Overlay only the contents: the #+BEGIN_JXL/#+END_JXL
                             ;; markers stay visible and editable around the image.
                             (when contents-begin
                               (org-jxl--decode-and-render
                                contents-begin contents-end
                                (buffer-substring-no-properties
                                 contents-begin contents-end))))))))))

(defvar org-jxl-inline-mode)

(defun org-jxl--after-change (beg end _len)
  "Re-render JXL overlays when the text around BEG..END changed.
Refreshes when the change sits inside a JXL block, or when it
overlaps a live overlay — the latter catches marker deletions,
which leave an overlay behind but no block to re-detect."
  (when (and org-jxl-inline-mode
             (or (org-jxl--find-image-pos beg)
                 (org-jxl--find-image-pos end)
                 (cl-some (lambda (ov)
                            (and (overlay-buffer ov)
                                 (<= (overlay-start ov) end)
                                 (>= (overlay-end ov) beg)))
                          org-jxl--overlays)))
    (org-jxl-refresh-images)))


;;; Org link preview integration

(defun org-jxl--after-link-preview (&rest _)
  "Render JXL blocks after `org-link-preview-region' has run.
This is the show path for both `org-link-preview' and the compat
`org-toggle-inline-images', which delegates to it.  Guarded on the
buffer-local mode, so buffers without `org-jxl-inline-mode' are
left untouched.  The hide path needs no advice: JXL overlays are
registered in `org-link-preview-overlays', so
`org-link-preview-clear' deletes them like ordinary previews
without re-decoding."
  (when org-jxl-inline-mode
    (org-jxl-refresh-images)))

;; Installed once at load time, not per mode toggle: per-mode
;; installation meant any buffer disabling the mode removed the advice
;; for every other buffer, and left toggling broken with the mode off.
(advice-add 'org-link-preview-region :after #'org-jxl--after-link-preview)


;;; Minor mode

;;;###autoload
(define-minor-mode org-jxl-inline-mode
  "Minor mode to render base64-encoded JXL data blocks as inline images.

When enabled, scans the Org buffer for blocks of the form:

    #+BEGIN_JXL
    ... base64 data ...
    #+END_JXL

and overlays each block's contents with the rendered JPEG XL
image, keeping the #+BEGIN_JXL/#+END_JXL markers visible and
editable.  JXL blocks take part in Org's link preview machinery:
\\[org-link-preview] and the compat \\[org-toggle-inline-images]
hide and show them together with ordinary inline images.

To insert a JXL block, encode your image to base64 externally
(e.g. `cjxl image.png - | base64 -w0 | wl-copy') and run
`org-jxl-insert-base64' or paste it manually."
  :lighter " JXL"
  :keymap nil
  (if org-jxl-inline-mode
      (progn
        (org-jxl-refresh-images)
        (add-hook 'change-major-mode-hook #'org-jxl--change-major-mode nil t)
        (add-hook 'after-change-functions #'org-jxl--after-change nil t))
    (org-jxl--delete-overlays)
    (setq org-jxl--decode-cache nil)
    (remove-hook 'after-change-functions #'org-jxl--after-change t)
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
  (let ((start (org-jxl--find-image-pos (point))))
    (unless start
      (user-error "No JXL image at point"))
    (let* ((block (org-element-at-point start))
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
