;;; org-zotxt.el --- Interface org-mode with Zotero via the zotxt extension
     
;; Copyright (C) 2010-2014 Erik Hetzner

;; Author: Erik Hetzner <egh@e6h.org>
;; Keywords: bib

;; This file is not part of GNU Emacs.

;; org-zotxt.el is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; org-zotxt.el is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with org-zotxt.el. If not, see
;; <http://www.gnu.org/licenses/>.

;;; Commentary:

;;; Code:

(require 'request)
(require 'org-element)
(require 'zotxt)

(defcustom org-zotxt-link-text-style
  :citation
  "Style to use for org zotxt link texts."
  :group 'org-zotxt
  :type '(choice (const :tag "easykey" :easykey)
                 (const :tag "citation" :citation)))

(defun org-zotxt-extract-link-id-at-point ()
  "Extract the Zotero key of the link at point."
  (let ((ct (org-element-context)))
    (if (eq 'link (org-element-type ct))
        (org-zotxt-extract-link-id-from-link (org-element-property :raw-link ct))
      nil)))

(defun org-zotxt-extract-link-id-from-link (path)
  "Return the zotxt ID from a link PATH."
  (if (string-match "^zotero://select/items/\\(.*\\)$" path)
      (match-string 1 path)
    nil))

(defun org-zotxt-insert-reference-link-to-item (item)
  "Insert link to Zotero ITEM in buffer."
  (insert (org-make-link-string (format "zotero://select/items/%s"
                                        (plist-get item :key))
                                (if (eq org-zotxt-link-text-style :easykey)
                                    (concat "@" (plist-get item :easykey))
                                  (plist-get item :citation)))))

(defun org-zotxt-insert-reference-links-to-items (items)
  "Insert links to Zotero ITEMS in buffer."
  (mapc (lambda (item)
          (org-zotxt-insert-reference-link-to-item item)
          (insert "\n")
          (forward-line 1))
        items))

(defun org-zotxt-update-reference-link-at-point ()
  "Update the zotero:// link at point."
  (interactive)
  (lexical-let ((mk (point-marker))
                (item-id (org-zotxt-extract-link-id-at-point)))
    (if item-id
        (deferred:$
          (deferred:next (lambda () `(:key ,item-id)))
          (deferred:nextc it
            (lambda (item)
              (org-zotxt-get-item-link-text-deferred item)))
          (deferred:nextc it
            (lambda (item)
              (save-excursion
                (with-current-buffer (marker-buffer mk)
                  (goto-char (marker-position mk))
                  (let ((ct (org-element-context)))
                    (goto-char (org-element-property :begin ct))
                    (delete-region (org-element-property :begin ct)
                                   (org-element-property :end ct))
                    (org-zotxt-insert-reference-link-to-item item))))))))))

(defun org-zotxt-update-all-reference-links ()
  "Update all zotero:// links in a document."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (let ((next-link (org-element-link-successor)))
      (while (not (null next-link))
        (goto-char (cdr next-link))
        (let* ((parse (org-element-link-parser))
               (path (org-element-property :raw-link parse))
               (end (org-element-property :end parse)))
          (if (org-zotxt-extract-link-id-from-link path)
              (org-zotxt-update-reference-link-at-point))
          (goto-char end))
        (setq next-link (org-element-link-successor))))))

(defun org-zotxt-get-item-link-text-deferred (item)
  "Get the link text for ITEM.
May be either an easy key or bibliography, depending on the value
of `org-zotxt-link-text-style'."
  (if (eq org-zotxt-link-text-style :easykey)
      (zotxt-get-item-easykey-deferred item)
    (zotxt-get-item-bibliography-deferred item)))

(defun org-zotxt-insert-reference-link (arg)
  "Insert a zotero link in the org-mode document. Prompts for
search to choose item. If prefix argument (C-u) is used, will
insert the currently selected item from Zotero."
  (interactive "P")
  (lexical-let ((mk (point-marker)))
    (deferred:$
      (if arg 
          (zotxt-get-selected-items-deferred)
        (zotxt-choose-deferred))
      (deferred:nextc it
        (lambda (items)
          (zotxt-mapcar-deferred #'org-zotxt-get-item-link-text-deferred items)))
      (deferred:nextc it
        (lambda (items)
          (with-current-buffer (marker-buffer mk)
            (goto-char (marker-position mk))
            (org-zotxt-insert-reference-links-to-items items)))))))

(org-add-link-type "zotero"
                   (lambda (rest)
                     (zotxt-select-key (substring rest 15))))

(defvar org-zotxt-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c \" i") 'org-zotxt-insert-reference-link)
    (define-key map (kbd "C-c \" u") 'org-zotxt-update-reference-link-at-point)
    map))

(defun org-zotxt-choose-path (paths)
  "Prompt user to select a path from the PATHS.
If only path is available, return it.  If no paths are available, error."
  (if (= 0 (length paths))
      (progn (message "No attachments for item!")
             (error "No attachments for item!"))
    (if (= 1 (length paths))
        (elt paths 0)
      (completing-read "File: " (append paths nil)))))

(defun org-zotxt-open-attachment (arg)
  "Open a Zotero items attachment.
Prefix ARG means open in Emacs."
  (interactive "P")
  (lexical-let ((arg arg))
    (deferred:$
      (zotxt-choose-deferred)
      (deferred:nextc it
        (lambda (items)
          (request-deferred
           zotxt-url-items
           :params `(("key" . ,(plist-get  (car items) :key)) ("format" . "recoll"))
           :parser 'json-read)))
      (deferred:nextc it
        (lambda (response)
          (let ((paths (cdr (assq 'paths (elt (request-response-data response) 0)))))
            (org-open-file (org-zotxt-choose-path paths) arg)))))))

;;;###autoload
(define-minor-mode org-zotxt-mode
  "Toggle org-zotxt-mode.
With no argument, this command toggles the mode.
Non-null prefix argument turns on the mode.
Null prefix argument turns off the mode.

This is a minor mode for managing your citations with Zotero in a
org-mode document."  
  nil
  " OrgZot"
  org-zotxt-mode-map)

(provide 'org-zotxt)
;;; org-zotxt.el ends here
