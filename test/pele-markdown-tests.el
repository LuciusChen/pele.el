;;; pele-markdown-tests.el --- Markdown preview integration -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: MIT
(require 'ert)
(require 'cl-lib)
(require 'pele-markdown)

(defun pele-markdown-test--available-p (mode)
  (and (require mode nil t)
       (or (not (eq mode 'markdown-ts-mode))
           (and (fboundp 'treesit-ready-p)
                (treesit-ready-p '(markdown markdown-inline) t)))))

(defmacro pele-markdown-test--deftest (name &rest body)
  "Run BODY as test NAME in each real Markdown major mode."
  (declare (indent 1))
  `(progn
     ,@(mapcar
        (lambda (mode)
          `(ert-deftest ,(intern (format "pele-markdown-%s-%s" name mode)) ()
             (skip-unless (pele-markdown-test--available-p ',mode))
             (with-temp-buffer
               (funcall #',mode)
               (unwind-protect
                   (progn ,@body)
                 (when (bound-and-true-p pele-markdown-mode) (pele-markdown-mode -1))))))
        '(markdown-mode markdown-ts-mode))))

(defun pele-markdown-test--wait ()
  (let ((deadline (+ (float-time) 5)))
    (while (and (> (hash-table-count pele--pending) 0) (< (float-time) deadline))
      (pele--drain)
      (accept-process-output pele--channel 0.01))
    (should (= 0 (hash-table-count pele--pending)))))

(pele-markdown-test--deftest collects-only-mermaid-fences
  (insert "# Examples\n\n````text\n```mermaid\ninfo\n```\n````\n\n"
          "<!--\n```mermaid\ninfo\n```\n-->\n\n"
          "    ```mermaid\n    info\n    ```\n\n"
          "```python\nprint(1)\n```\n\n~~~mermaid\ninfo\n~~~~\n\n"
          "```mermaid title=Demo\nflowchart LR\nA-->B\n```\n\n"
          "```mermaidx\ninfo\n```\n\n```pele\npie\n\"A\": 1\n```\n")
  (should (equal '("info\n" "flowchart LR\nA-->B\n" "pie\n\"A\": 1\n")
                 (mapcar (lambda (block) (plist-get block :source))
                         (pele-markdown--blocks)))))

(pele-markdown-test--deftest preserves-relative-indentation
  (insert "  ```mermaid\n  mindmap\n    root\n      Child\n  ```\n")
  (should (equal '("mindmap\n  root\n    Child\n")
                 (mapcar (lambda (block) (plist-get block :source))
                         (pele-markdown--blocks)))))

(pele-markdown-test--deftest supports-unclosed-fence-and-no-final-newline
  (dolist (source '("```mermaid\ninfo\n" "```mermaid\ninfo\n```"))
    (erase-buffer) (insert source)
    (let ((blocks (pele-markdown--blocks)))
      (should (= 1 (length blocks)))
      (should (equal "info\n" (plist-get (car blocks) :source)))
      (should (= (point-max) (plist-get (car blocks) :end))))))

(pele-markdown-test--deftest eof-fence-must-match-opening-length-and-character
  (dolist (fence '("````" "~~~~"))
    (erase-buffer)
    (insert fence "mermaid\ninfo\n```\n" fence)
    (should (equal "info\n```\n" (plist-get (car (pele-markdown--blocks)) :source)))))

(pele-markdown-test--deftest extracts-current-block-without-enabling-previews
  (insert "# Notes\n\n```mermaid\nflowchart LR\nA-->B\n```\n\nOutside\n")
  (goto-char (point-min)) (search-forward "A-->")
  (should (equal "flowchart LR\nA-->B\n" (pele--source-at-point)))
  (should-not pele-markdown-mode)
  (should-not pele--inline-overlays)
  (goto-char (point-max))
  (should-error (pele--source-at-point) :type 'user-error))

(pele-markdown-test--deftest renders-without-changing-buffer
  (skip-unless (image-type-available-p 'svg))
  (insert "# Diagram\n\n```mermaid\nflowchart LR\nA-->B\n```\n")
  (set-buffer-modified-p nil)
  (let ((source (buffer-string)) (mode major-mode))
    (pele-markdown-mode 1) (pele-markdown-test--wait)
    (should (eq mode major-mode))
    (should (equal source (buffer-string)))
    (should-not (buffer-modified-p))
    (should (= 1 (length pele--inline-overlays)))
    (let ((overlay (car pele--inline-overlays)))
      (should (overlay-get overlay 'after-string))
      (should (plist-get (overlay-get overlay 'pele-result) :ok))
      (should (= (point-max) (overlay-start overlay))))))

(pele-markdown-test--deftest empty-document-does-not-start-rendering
  (cl-letf (((symbol-function 'pele-render-async)
             (lambda (&rest _) (ert-fail "Rendered an empty Markdown document"))))
    (pele-markdown-mode 1)
    (should-not pele--inline-overlays)))

(pele-markdown-test--deftest initial-render-error-restores-editor-state
  (insert "```mermaid\ninfo\n```\n")
  (cl-letf (((symbol-function 'pele-render-async) (lambda (&rest _) (error "Unavailable renderer"))))
    (should-error (pele-markdown-mode 1)))
  (should-not pele-markdown-mode)
  (should-not pele--inline-overlays)
  (should-not (local-variable-p 'mwheel-scroll-up-function))
  (should-not (memq #'pele--inline-after-command post-command-hook)))

(pele-markdown-test--deftest input-after-preview-stays-below-image
  (skip-unless (image-type-available-p 'svg))
  (dolist (tail '("" "\n\n" " \t" "\n \t\nNext paragraph\n"))
    (erase-buffer)
    (insert "```mermaid\ninfo\n```\n")
    (let ((end (point)))
      (insert tail)
      (pele-markdown-mode 1) (pele-markdown-test--wait)
      (let* ((overlay (car pele--inline-overlays))
             (image (overlay-get overlay 'after-string)))
        (should (= end (overlay-start overlay)))
        (goto-char end) (newline 2)
        (should (= end (overlay-start overlay)))
        (pele--inline-refresh) (pele-markdown-test--wait)
        (should (eq overlay (car pele--inline-overlays)))
        (should (= end (overlay-start overlay)))
        (should (equal image (overlay-get overlay 'after-string)))
        (insert "Text below the diagram")
        (pele--inline-refresh) (pele-markdown-test--wait)
        (should (= end (overlay-start overlay)))))
    (pele-markdown-mode -1)))

(pele-markdown-test--deftest retains-last-image-and-recovers-after-edit
  (skip-unless (image-type-available-p 'svg))
  (insert "```mermaid\nflowchart LR\nA-->B\n```\n")
  (pele-markdown-mode 1) (pele-markdown-test--wait)
  (let* ((overlay (car pele--inline-overlays))
         (image (overlay-get overlay 'after-string)))
    (goto-char (point-min)) (search-forward "A-->B") (replace-match "A[")
    (should (timerp pele--inline-timer))
    (pele--inline-refresh) (pele-markdown-test--wait)
    (should (eq overlay (car pele--inline-overlays)))
    (should (equal image (overlay-get overlay 'after-string)))
    (should-not (equal "Mermaid preview" (overlay-get overlay 'help-echo)))
    (goto-char (point-min)) (search-forward "A[") (replace-match "C-->D")
    (pele--inline-refresh) (pele-markdown-test--wait)
    (should (equal "Mermaid preview" (overlay-get overlay 'help-echo)))
    (should (string-search ">C<" (plist-get (overlay-get overlay 'pele-result) :svg)))))

(pele-markdown-test--deftest unchanged-blocks-keep-their-previews
  (skip-unless (image-type-available-p 'svg))
  (insert "# Diagram\n\n```mermaid\ninfo\n```\n")
  (let ((render (symbol-function 'pele-render-async)) (calls 0))
    (cl-letf (((symbol-function 'pele-render-async)
               (lambda (&rest args) (cl-incf calls) (apply render args))))
      (pele-markdown-mode 1) (pele-markdown-test--wait)
      (let ((overlay (car pele--inline-overlays)))
        (goto-char (point-min)) (insert "Another paragraph\n\n")
        (pele--inline-refresh) (pele-markdown-test--wait)
        (should (= calls 1))
        (should (eq overlay (car pele--inline-overlays)))))))

(pele-markdown-test--deftest deleted-or-relabeled-blocks-are-cleaned-up
  (skip-unless (image-type-available-p 'svg))
  (insert "```mermaid\ninfo\n```\n\n~~~mermaid\ninfo\n~~~\n")
  (pele-markdown-mode 1) (pele-markdown-test--wait)
  (should (= 2 (length pele--inline-overlays)))
  (let ((first (car pele--inline-overlays)))
    (goto-char (point-min)) (search-forward "mermaid") (replace-match "text")
    (pele--inline-refresh) (pele-markdown-test--wait)
    (should (= 1 (length pele--inline-overlays)))
    (should-not (overlay-buffer first)))
  (erase-buffer) (pele--inline-refresh)
  (should-not pele--inline-overlays))

(pele-markdown-test--deftest narrowed-buffer-still-previews-all-blocks
  (skip-unless (image-type-available-p 'svg))
  (insert "```mermaid\ninfo\n```\n\n~~~mermaid\ninfo\n~~~\n")
  (narrow-to-region (point-min) (+ (point-min) 5))
  (pele-markdown-mode 1) (pele-markdown-test--wait)
  (should (= 2 (length pele--inline-overlays)))
  (should (buffer-narrowed-p)))

(pele-markdown-test--deftest disable-cancels-pending-work-and-ignores-late-result
  (insert "```mermaid\ninfo\n```\n")
  (let (callback cancelled overlay timer)
    (cl-letf (((symbol-function 'pele-render-async)
               (lambda (_source function &optional _options) (setq callback function) 999))
              ((symbol-function 'pele-cancel) (lambda (id) (push id cancelled)))
              ((symbol-function 'pele--image) (lambda (&rest _) (ert-fail "Displayed a stale result"))))
      (pele-markdown-mode 1)
      (setq overlay (car pele--inline-overlays))
      (goto-char (point-min)) (insert "\n")
      (setq timer pele--inline-timer)
      (should (timerp timer))
      (pele-markdown-mode -1)
      (funcall callback '(:ok t :svg "unused"))
      (should (equal '(999) cancelled))
      (should-not (overlay-buffer overlay))
      (should-not pele--inline-timer)
      (should-not (memq timer timer-idle-list))
      (should-not (memq #'pele--inline-schedule after-change-functions)))))

(pele-markdown-test--deftest major-mode-change-removes-previews
  (skip-unless (image-type-available-p 'svg))
  (insert "```mermaid\ninfo\n```\n")
  (pele-markdown-mode 1) (pele-markdown-test--wait)
  (let ((overlay (car pele--inline-overlays)))
    (goto-char (point-min)) (insert "\n")
    (fundamental-mode)
    (should-not (overlay-buffer overlay))
    (should-not pele--inline-timer)
    (should-not pele--inline-blocks-function)))

(pele-markdown-test--deftest disabling-org-mode-leaves-markdown-previews-alone
  (skip-unless (image-type-available-p 'svg))
  (insert "```mermaid\ninfo\n```\n")
  (pele-markdown-mode 1) (pele-markdown-test--wait)
  (let ((overlay (car pele--inline-overlays)))
    (pele-org-mode -1)
    (should pele-markdown-mode)
    (should (overlay-buffer overlay))
    (should (eq pele--inline-blocks-function #'pele-markdown--blocks))))

(ert-deftest pele-markdown-disabling-markdown-mode-leaves-org-previews-alone ()
  (skip-unless (image-type-available-p 'svg))
  (require 'org)
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src mermaid\ninfo\n#+end_src\n")
    (unwind-protect
        (progn
          (pele-org-mode 1) (pele-markdown-test--wait)
          (let ((overlay (car pele--inline-overlays)))
            (pele-markdown-mode -1)
            (should pele-org-mode)
            (should (overlay-buffer overlay))
            (should (eq pele--inline-blocks-function #'pele--org-blocks))))
      (pele-org-mode -1))))

(ert-deftest pele-markdown-treesit-strips-quote-and-list-prefixes ()
  (skip-unless (pele-markdown-test--available-p 'markdown-ts-mode))
  (with-temp-buffer
    (markdown-ts-mode)
    (insert "> ~~~mermaid\n> flowchart LR\n> A-->B\n> ~~~\n\n"
            "- Diagram\n\n  ```mermaid\n  mindmap\n    root\n      Child\n  ```\n")
    (should (equal '("flowchart LR\nA-->B\n" "mindmap\n  root\n    Child\n")
                   (mapcar (lambda (block) (plist-get block :source))
                           (pele-markdown--blocks))))))

(ert-deftest pele-markdown-treesit-preserves-indentation-after-blank-lines ()
  (skip-unless (pele-markdown-test--available-p 'markdown-ts-mode))
  (with-temp-buffer
    (markdown-ts-mode)
    (insert "- Diagram\n\n    ```mermaid\n\n    mindmap\n      root\n        Child\n    ```\n")
    (should (equal "\nmindmap\n  root\n    Child\n"
                   (plist-get (car (pele-markdown--blocks)) :source)))))

(ert-deftest pele-markdown-supports-gfm-mode ()
  (skip-unless (image-type-available-p 'svg))
  (skip-unless (pele-markdown-test--available-p 'markdown-mode))
  (with-temp-buffer
    (gfm-mode)
    (insert "```mermaid\ninfo\n```\n")
    (unwind-protect
        (progn (pele-markdown-mode 1) (pele-markdown-test--wait)
               (should (overlay-get (car pele--inline-overlays) 'pele-result)))
      (pele-markdown-mode -1))))

(ert-deftest pele-markdown-killing-buffer-cancels-pending-work ()
  (dolist (mode '(markdown-mode markdown-ts-mode))
    (when (pele-markdown-test--available-p mode)
      (let ((buffer (generate-new-buffer " *pele-markdown-kill-test*")) callback cancelled overlay)
        (cl-letf (((symbol-function 'pele-render-async)
                   (lambda (_source function &optional _options) (setq callback function) 998))
                  ((symbol-function 'pele-cancel) (lambda (id) (push id cancelled))))
          (unwind-protect
              (with-current-buffer buffer
                (funcall mode)
                (insert "```mermaid\ninfo\n```\n")
                (pele-markdown-mode 1)
                (setq overlay (car pele--inline-overlays)))
            (kill-buffer buffer))
          (funcall callback '(:ok t :svg "unused"))
          (should (equal '(998) cancelled))
          (should-not (overlay-buffer overlay)))))))

(ert-deftest pele-markdown-rejects-other-major-modes ()
  (with-temp-buffer
    (should-error (pele-markdown-mode 1) :type 'user-error)
    (should-not pele-markdown-mode)
    (should-not pele--inline-blocks-function)))

(provide 'pele-markdown-tests)
;;; pele-markdown-tests.el ends here
