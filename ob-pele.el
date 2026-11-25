;;; ob-pele.el --- Org Babel SVG output with Pele -*- lexical-binding: t; -*-

;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/LuciusChen/pele.el
;; Keywords: outlines, tools
;; SPDX-License-Identifier: MIT

;;; Commentary:
;; Evaluate #+begin_src pele blocks with :file diagram.svg.
;; Call `pele-babel-enable-mermaid' explicitly to use the same renderer for
;; #+begin_src mermaid, replacing any previously configured Mermaid backend.

;;; Code:

(require 'ob)
(require 'pele)

(defvar org-babel-default-header-args:pele
  '((:results . "file graphics") (:exports . "results"))
  "Default header arguments for Pele source blocks.")

;;;###autoload
(defun org-babel-execute:pele (body params)
  "Render Mermaid BODY using Babel PARAMS and return the SVG file name."
  (let* ((file (cdr (assq :file params)))
         (width (cdr (assq :width params)))
         (size (cdr (assq :font-size params)))
         (options (append (and width (list :max-width (if (numberp width) width (string-to-number width))))
                          (and size (list :font-size (if (numberp size) size (string-to-number size)))))))
    (unless (and (stringp file) (not (string-empty-p file)))
      (user-error "Pele Babel blocks require :file diagram.svg"))
    (unless (equal (downcase (or (file-name-extension file) "")) "svg")
      (user-error "Pele Babel output must use an .svg file"))
    (let ((result (pele-render body options)) (coding-system-for-write 'utf-8-unix))
      (with-temp-file (org-babel-process-file-name file)
        (insert (plist-get result :svg))))
    file))

(defvar pele-babel--previous nil)
(defvar pele-babel--previous-headers nil)
(defvar pele-babel--headers-bound nil)
(defvar pele-babel--enabled nil)
(defvar org-babel-default-header-args:mermaid)

;;;###autoload
(defun pele-babel-enable-mermaid ()
  "Use Pele for Mermaid Babel blocks, saving the previous backend."
  (interactive)
  (unless pele-babel--enabled
    (setq pele-babel--previous (and (fboundp 'org-babel-execute:mermaid)
                                   (symbol-function 'org-babel-execute:mermaid))
          pele-babel--headers-bound (boundp 'org-babel-default-header-args:mermaid)
          pele-babel--previous-headers (and pele-babel--headers-bound
                                            org-babel-default-header-args:mermaid)
          pele-babel--enabled t)
    (setq org-babel-default-header-args:mermaid
          (cons '(:results . "file graphics")
                (assq-delete-all :results (copy-tree pele-babel--previous-headers))))
    (defalias 'org-babel-execute:mermaid #'org-babel-execute:pele)))

(defun pele-babel-disable-mermaid ()
  "Restore the Mermaid Babel backend replaced by Pele."
  (interactive)
  (when pele-babel--enabled
    (if pele-babel--previous (fset 'org-babel-execute:mermaid pele-babel--previous)
      (fmakunbound 'org-babel-execute:mermaid))
    (if pele-babel--headers-bound
        (setq org-babel-default-header-args:mermaid pele-babel--previous-headers)
      (makunbound 'org-babel-default-header-args:mermaid))
    (setq pele-babel--enabled nil pele-babel--previous nil
          pele-babel--previous-headers nil pele-babel--headers-bound nil)))

(provide 'ob-pele)
;;; ob-pele.el ends here
