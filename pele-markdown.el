;;; pele-markdown.el --- Live Mermaid previews in Markdown -*- lexical-binding: t; -*-

;; Copyright (C) 2026 pele.el contributors
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1") (pele "0.0.1"))
;; URL: https://github.com/LuciusChen/pele.el
;; Keywords: multimedia, text
;; SPDX-License-Identifier: MIT

;;; Commentary:
;; `pele-markdown-mode' adds live previews below Mermaid fenced code blocks.
;; Fences use markdown-mode's syntax context, or the existing Markdown tree
;; in markdown-ts-mode. Older markdown-mode versions need no parser patches.
;; Rendering, caching and preview lifecycle are shared with `pele-org-mode'.

;;; Code:

(require 'pele)

(declare-function treesit-buffer-root-node "treesit" (&optional language))
(declare-function treesit-query-capture "treesit" (node query &optional beg end node-only))
(declare-function treesit-node-child-count "treesit" (node &optional named))
(declare-function treesit-node-child "treesit" (node n &optional named))
(declare-function treesit-node-type "treesit" (node))
(declare-function treesit-node-start "treesit" (node))
(declare-function treesit-node-end "treesit" (node))
(declare-function treesit-node-text "treesit" (node &optional no-property))

(defun pele-markdown--language-p (info)
  "Return non-nil when code fence INFO identifies Mermaid or Pele."
  (and info
       (save-match-data
         (and (string-match "\\`[ \t]*{?\\.?\\([^ \t}\n]+\\)" info)
              (pele--language-p (match-string 1 info))))))

(defun pele-markdown--unindent (source indentation)
  "Remove up to INDENTATION Markdown spaces from each SOURCE line."
  (if (> indentation 0)
      (replace-regexp-in-string (format "^ \\{0,%d\\}" indentation) "" source)
    source))

(defun pele-markdown--legacy-blocks ()
  "Collect fences while respecting markdown-mode's syntax context."
  (syntax-propertize (point-max))
  (save-excursion
    (save-match-data
      (goto-char (point-min))
      (let (blocks)
        ;; Scan every language so fences shown inside another code block stay
        ;; literal, including long backtick fences unsupported by older hosts.
        (while (re-search-forward "^[ \t]*\\(`\\{3,\\}\\|~\\{3,\\}\\)\\(.*\\)$" nil t)
          (let ((begin (match-beginning 0))
                (fence (match-string-no-properties 1))
                (info (match-string-no-properties 2))
                (indent (current-indentation)))
            (unless (or (get-text-property begin 'markdown-pre)
                        (save-excursion (nth 4 (syntax-ppss begin)))
                        (and (eq (aref fence 0) ?`) (string-search "`" info)))
              (forward-line 1)
              (let* ((body (point))
                     (closed (re-search-forward
                              (format "^[ \t]*%c\\{%d,\\}[ \t]*$"
                                      (aref fence 0) (length fence))
                              nil t))
                     (body-end (if closed (match-beginning 0) (point-max)))
                     (end (if closed (progn (forward-line 1) (point)) (point-max))))
                (when (pele-markdown--language-p info)
                  (push (list :begin begin :end end
                              :source (pele-markdown--unindent
                                       (buffer-substring-no-properties body body-end) indent))
                        blocks))
                (goto-char end)))))
        (nreverse blocks)))))

(defun pele-markdown--treesit-content (node)
  "Read code content NODE without Markdown container prefixes."
  (when node
    (let ((position (treesit-node-start node)) parts)
      (dolist (entry (treesit-query-capture node '((block_continuation) @prefix)))
        (let ((prefix (cdr entry)))
          (push (buffer-substring-no-properties position (treesit-node-start prefix)) parts)
          (setq position (treesit-node-end prefix))))
      (push (buffer-substring-no-properties position (treesit-node-end node)) parts)
      (apply #'concat (nreverse parts)))))

(defun pele-markdown--treesit-blocks ()
  "Collect fenced blocks from markdown-ts-mode's existing parser."
  (let (blocks)
    (dolist (entry (treesit-query-capture (treesit-buffer-root-node 'markdown)
                                        '((fenced_code_block) @block)))
      (let ((node (cdr entry)) info content fence fence-start (fences 0) (container-indent 0))
        (dotimes (index (treesit-node-child-count node t))
          (let ((child (treesit-node-child node index t)))
            (pcase (treesit-node-type child)
              ("info_string" (setq info (treesit-node-text child t)))
              ("code_fence_content" (setq content child))
              ("fenced_code_block_delimiter"
               (unless fence
                 (setq fence-start (save-excursion
                                     (goto-char (treesit-node-start child))
                                     (skip-chars-forward " \t" (treesit-node-end child))
                                     (point))
                       fence (buffer-substring-no-properties fence-start (treesit-node-end child))))
               (cl-incf fences)))))
        (when (pele-markdown--language-p info)
          ;; The content reader removes container prefixes. Only additional
          ;; opening fence indentation remains to be removed from the source.
          (dolist (prefix (treesit-query-capture node '((block_continuation) @prefix)))
            (setq container-indent
                  (max container-indent
                       (save-excursion (goto-char (treesit-node-end (cdr prefix)))
                                       (current-column)))))
          (let* ((indent (max 0 (- (save-excursion
                                    (goto-char fence-start) (current-column))
                                  container-indent)))
                 (source (pele-markdown--unindent
                          (or (pele-markdown--treesit-content content) "") indent)))
            ;; Some Markdown grammar versions include a closing EOF fence in
            ;; code_fence_content when no final newline follows it.
            (when (and (= fences 1) fence (= (treesit-node-end node) (point-max))
                       (string-match
                        (format "\\(?:\\`\\|\n\\)\\( \\{0,3\\}%c\\{%d,\\}[ \t]*\\)\\'"
                                (aref fence 0) (length fence))
                        source))
              (setq source (substring source 0 (match-beginning 1))))
            (push (list :begin (save-excursion
                                 (goto-char (treesit-node-start node)) (line-beginning-position))
                        :end (treesit-node-end node) :source source)
                  blocks)))))
    (nreverse blocks)))

(defun pele-markdown--blocks ()
  "Collect Mermaid blocks using the active Markdown major mode."
  (if (derived-mode-p 'markdown-ts-mode)
      (pele-markdown--treesit-blocks)
    (pele-markdown--legacy-blocks)))

(defun pele-markdown--source-at-point ()
  "Return the Mermaid fenced block's source at point, or nil."
  (save-excursion
    (save-restriction
      (widen)
      (let ((position (point)))
        (when-let* ((block (seq-find (lambda (block)
                                      (and (<= (plist-get block :begin) position)
                                           (< position (plist-get block :end))))
                                    (pele-markdown--blocks))))
          (plist-get block :source))))))

;;;###autoload
(define-minor-mode pele-markdown-mode
  "Show live SVG previews below Mermaid fenced code blocks.
Works with markdown-mode (including gfm-mode) and markdown-ts-mode.
Editing retains the last successful diagram until a new one is ready.
Previews are overlays and do not modify the Markdown file."
  :lighter " Pele"
  (if pele-markdown-mode
      (progn
        (unless (derived-mode-p 'markdown-mode 'markdown-ts-mode)
          (setq pele-markdown-mode nil)
          (user-error "Pele Markdown mode requires a Markdown buffer"))
        (condition-case err
            (progn
              (when (called-interactively-p 'interactive) (pele--ensure-module t))
              (pele--inline-enable #'pele-markdown--blocks))
          (error (setq pele-markdown-mode nil) (signal (car err) (cdr err)))))
    (when (eq pele--inline-blocks-function #'pele-markdown--blocks)
      (pele--inline-disable))))

(provide 'pele-markdown)
;;; pele-markdown.el ends here
