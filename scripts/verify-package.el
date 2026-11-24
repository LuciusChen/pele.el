;;; verify-package.el --- Validate an extracted native bundle -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: MIT

(require 'pele)
(let ((directory (or (getenv "PELE_PACKAGE_DIR")
                     (error "Set PELE_PACKAGE_DIR to an extracted bundle"))))
  (pele--module-check-host)
  (pele--module-validate directory)
  (load (expand-file-name (concat "pele-native" module-file-suffix) directory) nil t t))

;; Refuse to pass by silently using the estimated-width fallback.
(unless (equal "native" (plist-get (pele-render "flowchart LR\nA[Hello 世界]") :textMeasurement))
  (error "The bundle has no native font measurements"))

(dolist (directory (file-expand-wildcards "/usr/share/emacs/site-lisp/elpa/markdown-mode-*"))
  (add-to-list 'load-path directory))
(require 'pele-tests)
(require 'pele-markdown-tests)
(require 'pele-corpus-tests)
(ert-run-tests-batch-and-exit)
