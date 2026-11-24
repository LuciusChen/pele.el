;;; pele-gui-test.el --- Manual GUI verification entry point -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: MIT
;; Launch a separate Emacs -Q with -L . -l test/pele-gui-test.el.
(require 'pele)
(require 'org)
(let* ((root (file-name-directory (directory-file-name
                                  (file-name-directory (or load-file-name buffer-file-name)))))
       (output (expand-file-name "test/output" root)))
  (setq default-directory root)
  (make-directory output t)
  (set-frame-name "Pele SVG verification")
  (set-frame-size (selected-frame) 120 52)
  (find-file (expand-file-name "examples/gallery.org" root))
  (pele-org-mode 1)
  (run-at-time
   1 nil
   (lambda ()
     (let (images errors)
       (dolist (overlay pele--inline-overlays)
         (let ((result (overlay-get overlay 'pele-result)))
           (if result
               (condition-case error
                   (let ((size (image-size (pele--image result 900) t)))
                     (push (list :type (plist-get result :type) :width (car size) :height (cdr size)) images))
                 (error (push (error-message-string error) errors)))
             (push (or (overlay-get overlay 'help-echo) "Missing result") errors))))
       (with-temp-file (expand-file-name "gui-results.json" output)
         (insert (json-serialize (list :images (vconcat (nreverse images)) :errors (vconcat errors)))))
     (goto-char (point-min))
     (redisplay t)))))
