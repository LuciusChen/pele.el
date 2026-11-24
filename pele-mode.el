;;; pele-mode.el --- Edit Mermaid sources without external tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 pele.el contributors
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/LuciusChen/pele.el
;; Keywords: languages, tools
;; SPDX-License-Identifier: MIT

;;; Commentary:
;; Pure Elisp font locking, comments and basic indentation for Mermaid / Pele.
;; Editing does not load the renderer or start a process.  Preview and export
;; commands load `pele' only when invoked.  Org uses this mode for `mermaid'
;; and `pele' blocks unless another source mode was explicitly configured.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pele-font-lock)

(defgroup pele-editing nil "Edit Mermaid sources for Pele."
  :group 'languages :group 'pele)

(defcustom pele-indent-offset 2
  "Number of spaces per explicit Mermaid nesting level."
  :type 'natnum :group 'pele-editing)

;; Header spellings accepted by the pinned engine's src/detect.ts.  These are
;; editing hints, not a second Mermaid parser; Pele still validates the source.
(defconst pele-mode--headers
  '("graph" "flowchart" "flowchart-elk" "sequenceDiagram" "classDiagram"
    "stateDiagram" "stateDiagram-v2" "erDiagram" "pie" "gantt" "gitGraph"
    "mindmap" "timeline" "journey" "xychart" "xychart-beta" "quadrantChart"
    "requirement" "requirementDiagram" "C4Context" "C4Container" "C4Component"
    "C4Dynamic" "C4Deployment" "sankey" "sankey-beta" "block" "block-beta"
    "packet" "packet-beta" "kanban" "architecture" "architecture-beta"
    "radar-beta" "treemap" "treemap-beta" "info" "agentflow-beta"
    "usecase-beta" "railroad-beta" "railroad-ebnf-beta" "railroad-abnf-beta"
    "railroad-peg-beta" "treeView-beta" "venn-beta" "cynefin-beta"
    "wardley-beta" "swimlane-beta" "ishikawa" "ishikawa-beta" "eventmodeling"))

(defvar pele-mode-syntax-table
  (let ((table (make-syntax-table)))
    ;; Two percent signs start a line comment; a single percent does not.
    (modify-syntax-entry ?% ". 12" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?- "_" table)
    (modify-syntax-entry ?_ "_" table)
    (modify-syntax-entry ?' "." table)
    table)
  "Syntax table for `pele-mode'.")

(defconst pele-mode--openers
  '("subgraph" "loop" "alt" "opt" "par" "critical" "break" "rect" "box" "block"))
(defconst pele-mode--branches '("else" "and" "option"))
(defconst pele-mode--trees '("mindmap" "treemap" "treemap-beta" "kanban" "treeview-beta"))
(defconst pele-mode--sections '("gantt" "journey" "timeline"))

(defun pele-mode--line ()
  "Return (TOKEN BRACE CLOSING) for the line at point, ignoring comments."
  (save-excursion
    (back-to-indentation)
    (unless (or (eolp) (looking-at "%%") (nth 3 (syntax-ppss)))
      (let* ((start (point))
             (token (and (looking-at "[[:alpha:]_][[:alnum:]_-]*")
                         (match-string-no-properties 0)))
             (end (line-end-position))
             (closing (eq (char-after) ?})))
        (catch 'comment
          (while (search-forward "%%" end t)
            (let ((at (match-beginning 0)))
              (unless (save-excursion (nth 3 (syntax-ppss at)))
                (setq end at)
                (throw 'comment t)))))
        (goto-char end)
        (skip-chars-backward " \t" start)
        (list token (and (eq (char-before) ?{)
                         (not (nth 3 (syntax-ppss (1- (point))))))
              closing)))))

(defun pele-mode--frontmatter-p ()
  "Return non-nil when point is in leading YAML frontmatter."
  (let ((target (line-beginning-position)))
    (save-excursion
      (goto-char (point-min))
      (when (looking-at-p "---[ \t]*$")
        (forward-line 1)
        (or (not (re-search-forward "^---[ \t]*$" nil t))
            (<= target (line-beginning-position)))))))

(defun pele-mode--tree-indent (header)
  "Preserve meaningful tree indentation after HEADER."
  (if (save-excursion (back-to-indentation) (not (eolp)))
      (max pele-indent-offset (current-indentation))
    (save-excursion
      (forward-line -1)
      (while (and (> (point) header) (looking-at-p "^[ \t]*$")) (forward-line -1))
      (max pele-indent-offset (current-indentation)))))

(defun pele-mode--indentation ()
  "Calculate basic indentation using explicit Mermaid blocks.
Indentation-based diagrams preserve the author's existing hierarchy."
  (let ((target (line-beginning-position)) (base 0) (level 0) stack diagram header)
    (save-excursion
      (goto-char (point-min))
      (while (< (point) target)
        (let* ((line (pele-mode--line)) (token (car line)))
          (cond
           ((and token (member-ignore-case token pele-mode--headers))
            (setq diagram (downcase token) header (point)
                  base pele-indent-offset level base stack nil))
           ((or (equal token "end") (nth 2 line))
            (when stack (setq level (cdar stack) stack (cdr stack))))
           ((and (member diagram pele-mode--sections) (equal token "section"))
            (setq stack (list (cons 'section base)) level (+ base pele-indent-offset)))
           ((or (member token pele-mode--openers) (nth 1 line))
            (push (cons 'block level) stack)
            (cl-incf level pele-indent-offset))))
        (forward-line 1)))
    (let* ((line (pele-mode--line)) (token (car line)))
      (cond
       ((or (pele-mode--frontmatter-p) (nth 3 (syntax-ppss))) (current-indentation))
       ((and token (member-ignore-case token pele-mode--headers)) 0)
       ((and header (member diagram pele-mode--trees)) (pele-mode--tree-indent header))
       ((or (equal token "end") (nth 2 line) (member token pele-mode--branches))
        (if stack (cdar stack) base))
       ((and (member diagram pele-mode--sections) (equal token "section")) base)
       (t level)))))

(defun pele-indent-line ()
  "Indent the current Mermaid line without changing tree hierarchy."
  (interactive)
  (let ((offset (- (point) (line-beginning-position)))
        (column (current-indentation))
        (indent (pele-mode--indentation)))
    (indent-line-to indent)
    (when (> offset column) (move-to-column (+ indent (- offset column))))))

(autoload 'pele-preview "pele" nil t)
(autoload 'pele-export "pele" nil t)

(defvar pele-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-p") #'pele-preview)
    (define-key map (kbd "C-c C-e") #'pele-export)
    map)
  "Keymap for `pele-mode'.")

;;;###autoload
(define-derived-mode pele-mode prog-mode "Pele"
  "Edit Mermaid sources with pure Elisp highlighting and basic indentation.
No CLI, renderer, or native module is needed for editing.
Use \\[pele-preview] to preview, and \\[pele-export] to export SVG."
  :syntax-table pele-mode-syntax-table
  (pele-font-lock-setup)
  (setq-local indent-line-function #'pele-indent-line)
  (setq-local indent-tabs-mode nil)
  (setq-local comment-start "%% ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "%%+[ \t]*"))

(defvar org-src-lang-modes)

(defun pele-mode--register-org ()
  "Register source highlighting without replacing explicit Org mode choices."
  (dolist (language '("mermaid" "pele"))
    (unless (assoc language org-src-lang-modes)
      (push (cons language 'pele) org-src-lang-modes))))

(with-eval-after-load 'org-src (pele-mode--register-org))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.\\(?:mmd\\|mermaid\\)\\'" . pele-mode))

(provide 'pele-mode)
;;; pele-mode.el ends here
