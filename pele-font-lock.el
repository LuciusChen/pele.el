;;; pele-font-lock.el --- Pele website highlighting in pure Elisp -*- lexical-binding: t; -*-

;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/LuciusChen/pele.el
;; SPDX-License-Identifier: MIT
;; Adapted from kepano / Obsidian's MIT-licensed website highlighter.
;; See vendor/pele-website/ for the pinned original and its license.

;;; Commentary:
;; A direct port of the Mermaid rules in website/src/lib/highlight.ts at
;; 3a2f075ee0c3d914f0fad3545fc0f193693975ac.  Token order, cross-line state,
;; ASCII word boundaries and the 2,000 UTF-16-unit line limit follow upstream.
;; This is a highlighter, not a second Mermaid validator.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)

(defgroup pele-highlighting nil "Pele website source highlighting."
  :group 'faces :group 'pele)

;; Dark colors are the website's --syntax-* values.  Light colors use their
;; Flexoki counterparts for readable text on light editor backgrounds.
(defface pele-punctuation-face
  '((((class color) (background dark)) :foreground "#9f9d96")
    (((class color) (background light)) :foreground "#878580")
    (t :inherit font-lock-delimiter-face))
  "Punctuation in Mermaid source." :group 'pele-highlighting)
(defface pele-language-face
  '((((class color) (background dark)) :foreground "#e47da8")
    (((class color) (background light)) :foreground "#a02f6f")
    (t :inherit font-lock-preprocessor-face))
  "Directives and class names in Mermaid source." :group 'pele-highlighting)
(defface pele-keyword-face
  '((((class color) (background dark)) :foreground "#a0af54")
    (((class color) (background light)) :foreground "#66800b")
    (t :inherit font-lock-keyword-face))
  "Mermaid keywords recognized by the website." :group 'pele-highlighting)
(defface pele-constant-face
  '((((class color) (background dark)) :foreground "#dfb431")
    (((class color) (background light)) :foreground "#ad8301")
    (t :inherit font-lock-constant-face))
  "Directions, booleans and color constants." :group 'pele-highlighting)
(defface pele-variable-face
  '((((class color) (background dark)) :foreground "#66a0c8")
    (((class color) (background light)) :foreground "#205ea6")
    (t :inherit font-lock-variable-name-face))
  "Identifiers and style properties." :group 'pele-highlighting)
(defface pele-function-face
  '((((class color) (background dark)) :foreground "#ec8b49")
    (((class color) (background light)) :foreground "#bc5215")
    (t :inherit font-lock-function-name-face))
  "Callback and style function names." :group 'pele-highlighting)
(defface pele-string-face
  '((((class color) (background dark)) :foreground "#5abdac")
    (((class color) (background light)) :foreground "#24837b")
    (t :inherit font-lock-string-face))
  "Labels and string values." :group 'pele-highlighting)
(defface pele-number-face
  '((((class color) (background dark)) :foreground "#a699d0")
    (((class color) (background light)) :foreground "#5e409d")
    (t :inherit font-lock-number-face))
  "Numbers in Mermaid source." :group 'pele-highlighting)
(defface pele-yaml-key-face
  '((t :inherit pele-variable-face))
  "Keys in leading YAML frontmatter." :group 'pele-highlighting)
(defface pele-comment-face
  '((((class color)) :foreground "#6f6e69") (t :inherit font-lock-comment-face))
  "Mermaid comments." :group 'pele-highlighting)

(defconst pele-font-lock--faces
  [nil pele-punctuation-face pele-language-face pele-keyword-face
       pele-constant-face pele-variable-face pele-function-face
       pele-string-face pele-number-face pele-yaml-key-face pele-comment-face])
(defconst pele-font-lock--classes
  [nil "syn-punctuation" "syn-language" "syn-keyword" "syn-constant"
       "syn-variable" "syn-function" "syn-string" "syn-number" "syn-yaml-key" "syn-comment"])
(defconst pele-font-lock--space
  "[ \t\n\r\f\013\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]")
(defconst pele-font-lock--dot "[^\n\r\u2028\u2029]")
(defconst pele-font-lock--boundary "\\(?:\\'\\|[^A-Za-z0-9_]\\)")
(defconst pele-font-lock--declarations
  (append '("xychart" "xychart-beta" "gitGraph" "pie" "mindmap" "sequenceDiagram"
            "classDiagram" "stateDiagram" "stateDiagram-v2" "erDiagram" "gantt"
            "journey" "timeline" "quadrantChart" "requirement" "requirementDiagram"
            "C4Context" "C4Container" "C4Component" "C4Dynamic" "C4Deployment"
            "railroad-beta" "railroad-ebnf-beta" "railroad-abnf-beta" "railroad-peg-beta")
          (cl-loop for name in '("architecture" "sankey" "block" "packet" "kanban"
                                 "radar" "treemap" "info" "agentflow" "usecase" "treeView"
                                 "venn" "cynefin" "wardley" "swimlane" "ishikawa" "eventmodeling")
                   append (list name (concat name "-beta")))))
(defconst pele-font-lock--keywords
  '("flowchart-elk" "flowchart" "graph" "subgraph" "end" "direction" "click"
    "style" "classDef" "class" "linkStyle" "interpolate" "call" "href" "callback"))
(defconst pele-font-lock--shapes
  '(("(((" ")))") ("([" "])") ("[(" ")]") ("[[" "]]") ("((" "))")
    ("{{" "}}") ("[/" "/]" "\\]") ("[\\" "\\]" "/]")
    ("[" "]") ("(" ")") ("{" "}")))

;; Build the website's fixed expressions once.  In particular, regexp-opt
;; allocates a trie; rebuilding it for each identifier dominated fontification.
(defconst pele-font-lock--declaration-word-re
  (concat "\\(" (regexp-opt pele-font-lock--declarations) "\\)" pele-font-lock--boundary))
(defconst pele-font-lock--keyword-word-re
  (concat "\\(" (regexp-opt pele-font-lock--keywords) "\\)" pele-font-lock--boundary))
(defconst pele-font-lock--direction-word-re
  (concat "\\(" (regexp-opt '("TB" "TD" "BT" "RL" "LR")) "\\)" pele-font-lock--boundary))
(defconst pele-font-lock--whitespace-re (concat pele-font-lock--space "+"))
(defconst pele-font-lock--blank-re (concat "\\`" pele-font-lock--space "*\\'"))
(defconst pele-font-lock--frontmatter-re
  (concat "\\`" pele-font-lock--space "*---" pele-font-lock--space "*\\'"))
(defconst pele-font-lock--yaml-entry-re
  (concat "\\`\\(" pele-font-lock--space "*\\(?:-" pele-font-lock--space
          "+\\)?\\)\\([A-Za-z0-9_-]+\\)\\(:\\)\\(" pele-font-lock--space
          "*\\)\\(" pele-font-lock--dot "*\\)\\'"))
(defconst pele-font-lock--yaml-quoted-re
  (concat "\\`\\([\"']\\)" pele-font-lock--dot "*\\1\\'"))
(defconst pele-font-lock--directive-re
  (concat "%%{" pele-font-lock--dot "*?\\(?:}%%\\|\\'\\)"))
(defconst pele-font-lock--metadata-key-re
  (concat "\\([A-Za-z0-9_-]+\\)\\(" pele-font-lock--space "*:\\)"))
(defconst pele-font-lock--metadata-value-re
  (concat "[^" (substring pele-font-lock--space 1 -1) ",}\"]+"))
(defconst pele-font-lock--style-start-re
  (concat "[A-Za-z0-9_-]+" pele-font-lock--space "*:"))
(defconst pele-font-lock--number-re
  (concat "\\([0-9]+\\(?:\\.[0-9]+\\)?\\)" pele-font-lock--boundary))
(defconst pele-font-lock--callback-re
  (concat "\\(?:\\`\\|[^A-Za-z0-9_]\\)call" pele-font-lock--space "+\\'"))
(defconst pele-font-lock--style-color-re
  (concat "\\(#[0-9a-fA-F]\\{3,8\\}\\)" pele-font-lock--boundary))
(defconst pele-font-lock--style-text-re
  (concat "[^" (substring pele-font-lock--space 1 -1) "(),\"'#]+"))
(defconst pele-font-lock--style-declaration-re
  (concat "\\`\\(" pele-font-lock--space "*\\)\\([A-Za-z0-9_-]+\\)\\("
          pele-font-lock--space "*:" pele-font-lock--space "*\\)\\("
          pele-font-lock--dot "*\\)\\'"))

(defun pele-font-lock--match (regexp value position)
  "Match REGEXP at POSITION in VALUE, leaving match data on success."
  (and (string-match regexp value position) (= (match-beginning 0) position)))

(defun pele-font-lock--word (regexp value position)
  "Match word REGEXP in VALUE at POSITION, returning the first group's end."
  (when (pele-font-lock--match regexp value position)
    (match-end 1)))

(defun pele-font-lock--letter-p (character)
  (or (<= ?a character ?z) (<= ?A character ?Z)
      (memq (get-char-code-property character 'general-category) '(Lu Ll Lt Lm Lo))))

(defun pele-font-lock--identifier-character-p (character)
  (or (= character ?_) (pele-font-lock--letter-p character)
      (memq (get-char-code-property character 'general-category) '(Nd Nl No))))

(defun pele-font-lock--identifier-end (value position)
  "Find the end of the website's Unicode identifier at POSITION in VALUE."
  (let ((end position) (length (length value)))
    (when (and (< end length)
               (or (= (aref value end) ?_) (pele-font-lock--letter-p (aref value end))))
      (cl-incf end)
      (while (and (< end length)
                  (or (pele-font-lock--identifier-character-p (aref value end))
                      (and (memq (aref value end) '(?- ?.)) (< (1+ end) length)
                           (pele-font-lock--identifier-character-p (aref value (1+ end))))))
        (cl-incf end))
      end)))

(defun pele-font-lock--arrow (value position &optional ending)
  "Return arrow bounds in VALUE after POSITION.
ENDING searches for a closing arrow; otherwise match an arrow at POSITION."
  (let ((start position) end)
    (unless ending
      (when (and (< start (length value)) (memq (aref value start) '(?x ?o ?<))
                 (pele-font-lock--match "--\\|==\\|-\\." value (1+ start)))
        (cl-incf start)))
    (when (if ending
              (string-match "--+\\|==+\\|\\.+-+" value start)
            (pele-font-lock--match "--+\\|==+\\|-\\.+-?\\|~~~+" value start))
      (setq start (if ending (match-beginning 0) position) end (match-end 0))
      (when (< end (length value))
        (when (or (= (aref value end) ?>)
                  (and (memq (aref value end) '(?x ?o))
                       (or (= (1+ end) (length value))
                           (not (string-match-p "[A-Za-z0-9_]" (substring value (1+ end) (+ end 2)))))))
          (cl-incf end)))
      (cons start end))))

(defun pele-font-lock--quoted (value from to emit)
  "Emit website-style quote spans for VALUE from FROM to TO using EMIT."
  (when (< from to)
    (funcall emit 1 from (1+ from))
    (if (and (> (- to from) 1) (= (aref value (1- to)) (aref value from)))
        (progn (funcall emit 7 (1+ from) (1- to)) (funcall emit 1 (1- to) to))
      (funcall emit 7 (1+ from) to))))

(defun pele-font-lock--style-value (value base emit)
  "Highlight a style VALUE at BASE through the EMIT callback."
  (let ((index 0) (case-fold-search nil) end)
    (while (< index (length value))
      (let ((class 0))
        (cond
         ((pele-font-lock--match pele-font-lock--style-color-re value index)
          (setq end (match-end 1) class 4))
         ((pele-font-lock--match "-?[0-9]*\\.?[0-9]+[a-z%]*" value index)
          (setq end (match-end 0) class 8))
         ((pele-font-lock--match "\"[^\"]*\"\\|'[^']*'" value index) (setq end (match-end 0)))
         ((pele-font-lock--match "--[A-Za-z0-9_-]+" value index) (setq end (match-end 0) class 5))
         ((memq (aref value index) '(?\( ?\) ?,)) (setq end (1+ index) class 1))
         ((pele-font-lock--match pele-font-lock--whitespace-re value index) (setq end (match-end 0)))
         ((pele-font-lock--match pele-font-lock--style-text-re value index)
          (setq end (match-end 0)))
         (t (setq end (1+ index))))
        (cond
         ((memq (aref value index) '(?\" ?'))
          (pele-font-lock--quoted value index end
                                  (lambda (kind from to) (funcall emit kind (+ base from) (+ base to)))))
         (t
          (when (and (= class 0) (< end (length value)) (= (aref value end) ?\()) (setq class 6))
          (funcall emit class (+ base index) (+ base end))))
        (setq index end)))))

(defun pele-font-lock--declarations-value (value base emit)
  "Highlight style declarations in VALUE at BASE with EMIT."
  (let ((index 0) (length (length value)) (case-fold-search nil))
    (while (< index length)
      (let* ((end (or (string-match "[,;]" value index) length))
             (part (substring value index end)))
        (if (string-match pele-font-lock--style-declaration-re part)
            (let ((key-start (match-beginning 2)) (key-end (match-end 2))
                  (value-start (match-beginning 4)))
              (funcall emit 0 (+ base index) (+ base index key-start))
              (funcall emit 5 (+ base index key-start) (+ base index key-end))
              (funcall emit 1 (+ base index key-end) (+ base index value-start))
              (pele-font-lock--style-value (substring part value-start) (+ base index value-start) emit))
          (funcall emit 0 (+ base index) (+ base end)))
        (when (< end length) (funcall emit 1 (+ base end) (+ base end 1)))
        (setq index (1+ end))))))

(defun pele-font-lock--scan-line (line state)
  "Return (STATE . SPANS) after highlighting LINE from input STATE.
STATE bits are started=1, frontmatter=2, quote=4, metadata=8.
SPANS contain zero-based (FROM TO CLASS) codepoint offsets.
Plain text is included with CLASS zero."
  (let ((index 0) (length (length line)) spans (case-fold-search nil)
        after-node expects-direction (style-target 0) end)
    (cl-labels
        ((emit (class from to)
           ;; An unfinished quoted pipe label can make the website emit a
           ;; synthetic closing bar.  There is no source character to color.
           (setq from (min from length) to (min to length))
           (when (< from to)
             (if (and spans (= (nth 1 (car spans)) from) (= (nth 2 (car spans)) class))
                 (setf (nth 1 (car spans)) to)
               (push (list from to class) spans))))
         (consume (class to) (emit class index to) (setq index to))
         (text (&optional closers)
           (let (close)
             (if (and (< index length) (= (aref line index) ?\"))
                 (progn
                   (setq close (string-search "\"" line (1+ index)))
                   (unless close (setq state (logior state 4)))
                   (pele-font-lock--quoted line index (if close (1+ close) length) #'emit)
                   (setq index (if close (1+ close) length)))
               (dolist (closer closers)
                 (let ((found (string-search closer line index)))
                   (when (and found (or (not close) (< found close))) (setq close found))))
               (consume 7 (or close length))))))
      (catch 'done
        (when (or (> length 2000)
                  (> (cl-loop for character across line sum (if (> character #xffff) 2 1)) 2000))
          (consume 0 length) (throw 'done nil))
        (when (and (= (logand state 1) 0)
                   (not (string-match-p pele-font-lock--blank-re line)))
          (setq state (logior state 1))
          (when (string-match-p pele-font-lock--frontmatter-re line)
            (setq state (logior state 2)) (consume 1 length) (throw 'done nil)))
        (when (/= (logand state 2) 0)
          (cond
           ((string-match-p pele-font-lock--frontmatter-re line)
            (setq state (logand state (lognot 2))) (consume 1 length))
           ((string-match pele-font-lock--yaml-entry-re line)
            (let* ((key-start (match-beginning 2)) (key-end (match-end 2))
                   (colon-end (match-end 3)) (start (match-beginning 5))
                   (value (substring line start)))
              (emit 0 0 key-start) (emit 9 key-start key-end) (emit 1 key-end colon-end)
              (emit 0 colon-end start)
              (cond
               ((string-match-p pele-font-lock--yaml-quoted-re value)
                (pele-font-lock--quoted line start length #'emit))
               ((member value '("true" "false" "null" "~")) (emit 4 start length))
               ((string-match-p "\\`[+-]?\\(?:[0-9]+\\(?:\\.[0-9]+\\)?\\|\\.[0-9]+\\)\\'" value)
                (emit 8 start length))
               (t (emit 7 start length)))))
           (t (consume 7 length)))
          (throw 'done nil))
        (when (/= (logand state 4) 0)
          (let ((close (string-search "\"" line)))
            (unless close (consume 7 length) (throw 'done nil))
            (setq state (logand state (lognot 4)))
            (consume 7 close) (consume 1 (1+ close))))
        (while (< index length)
          (let ((was-after-node after-node))
            (setq after-node nil)
            (cond
             ((/= (logand state 8) 0)
              (cond
               ((pele-font-lock--match pele-font-lock--whitespace-re line index) (consume 0 (match-end 0)))
               ((= (aref line index) ?,) (consume 1 (1+ index)))
               ((= (aref line index) ?}) (setq state (logand state (lognot 8))) (consume 1 (1+ index)))
               ((= (aref line index) ?\") (text))
               ((pele-font-lock--match pele-font-lock--metadata-key-re line index)
                (let ((key-end (match-end 1)) (to (match-end 0))) (consume 5 key-end) (consume 1 to)))
               ((pele-font-lock--match pele-font-lock--metadata-value-re line index)
                (let ((value (match-string 0 line)) (to (match-end 0)))
                  (consume (cond ((member value '("true" "false")) 4)
                                 ((string-match-p "\\`-?[0-9]" value) 8) (t 7)) to)))))
             ((pele-font-lock--match pele-font-lock--whitespace-re line index) (consume 0 (match-end 0)))
             ((pele-font-lock--match pele-font-lock--directive-re line index)
              (consume 2 (match-end 0)))
             ((pele-font-lock--match "%%" line index) (consume 10 length))
             ((= (aref line index) ?\") (text))
             ((pele-font-lock--match "@{" line index) (setq state (logior state 8)) (consume 1 (+ index 2)))
             ((pele-font-lock--match "\\(:::\\)\\([A-Za-z0-9_-]*\\)" line index)
              (let ((to (match-end 0))) (consume 1 (+ index 3)) (consume 2 to)))
             ((= (aref line index) ?|)
              (let ((close (string-search "|" line (1+ index))))
                (consume 1 (1+ index))
                (when close (text '("|")) (consume 1 (1+ index)))))
             ((setq end (pele-font-lock--arrow line index))
              (let* ((arrow-end (cdr end)) (arrow (substring line index arrow-end))
                     (label (and (member arrow '("--" "==" "-."))
                                 (pele-font-lock--arrow line arrow-end t))))
                (if (and label (> (car label) arrow-end)
                         (let ((value (substring line arrow-end (car label))))
                           (and (not (string-match-p pele-font-lock--blank-re value))
                                (not (string-match-p "[][(){}|]" value)))))
                    (progn (consume 1 arrow-end) (consume 7 (car label)) (consume 1 (cdr label)))
                  (consume 1 arrow-end))))
             ((and (> style-target 1)
                   (pele-font-lock--match pele-font-lock--style-start-re line index))
              (pele-font-lock--declarations-value (substring line index) index #'emit) (setq index length))
             ((and (string-match-p pele-font-lock--blank-re (substring line 0 index))
                   (setq end (pele-font-lock--word pele-font-lock--declaration-word-re line index)))
              (consume 3 end))
             ((setq end (pele-font-lock--word pele-font-lock--keyword-word-re line index))
              (let ((keyword (substring line index end)))
                (setq expects-direction (string-match-p "\\`\\(?:flowchart\\|graph\\|direction\\)" keyword))
                (when (member keyword '("style" "classDef" "linkStyle")) (setq style-target 1))
                (consume 3 end)))
             ((and expects-direction (setq end (pele-font-lock--word pele-font-lock--direction-word-re line index)))
              (consume 4 end))
             ((pele-font-lock--match pele-font-lock--number-re line index)
              (consume 8 (match-end 1)) (when (> style-target 0) (setq style-target 2)))
             ((setq end (pele-font-lock--identifier-end line index))
              (let ((call (and (< end length) (= (aref line end) ?\()
                               (string-match-p pele-font-lock--callback-re
                                               (substring line 0 index)))))
                (consume (if call 6 5) end) (setq after-node (not call))
                (when (> style-target 0) (setq style-target 2))))
             ((and was-after-node (= (aref line index) ?>)) (consume 1 (1+ index)) (text '("]")))
             (t
              (let ((shape (seq-find (lambda (item) (string-prefix-p (car item) (substring line index))) pele-font-lock--shapes)))
                (if shape
                    (progn
                      (consume 1 (+ index (length (car shape))))
                      (text (cdr shape))
                      (let ((closer (seq-find (lambda (value) (string-prefix-p value (substring line index))) (cdr shape))))
                        (when closer (consume 1 (+ index (length closer))))))
                  (consume (if (memq (aref line index) '(?\] ?\) ?} ?& ?\; ?, ?: ?~ ?/ ?\\ ?< ?> ?= ?. ?-)) 1 0)
                           (1+ index)))))))))
      (cons state (nreverse spans)))))

(defvar-local pele-font-lock--cache nil)
(defvar-local pele-font-lock--matched-face nil)
(defvar-local pele-font-lock--next-position nil)
(defvar-local pele-font-lock--next-state 0)

(defun pele-font-lock--entry (begin)
  "Return the cached line entry for BEGIN, computing preceding state if needed.
An entry is [OUTPUT-STATE SPANS NEXT-LINE-POSITION]."
  (or (gethash begin pele-font-lock--cache)
      (save-excursion
        (let ((start (point-min)) (state 0) entry)
          (if (eql begin pele-font-lock--next-position)
              (setq start begin state pele-font-lock--next-state)
            (maphash (lambda (position value)
                       (when (and (< position begin) (<= (aref value 2) begin) (>= (aref value 2) start))
                         (setq start (aref value 2) state (aref value 0)))) pele-font-lock--cache))
          (goto-char start)
          (while (not (gethash begin pele-font-lock--cache))
            (let* ((from (point)) (end (line-end-position))
                   (result (pele-font-lock--scan-line (buffer-substring-no-properties from end) state))
                   (next (min (point-max) (1+ end))))
              (setq state (car result) entry (vector state (cdr result) next))
              (puthash from entry pele-font-lock--cache)
              (setq pele-font-lock--next-position next pele-font-lock--next-state state)
              (unless (= from begin) (goto-char next))))
          entry))))

(defun pele-font-lock--matcher (limit)
  "Find the next website-classified span before LIMIT."
  (catch 'found
    (while (< (point) limit)
      (let* ((position (point)) (begin (line-beginning-position))
             (entry (pele-font-lock--entry begin)))
        (dolist (span (aref entry 1))
          (let ((from (max position (+ begin (nth 0 span))))
                (to (min limit (+ begin (nth 1 span)))) (class (nth 2 span)))
            (when (and (> class 0) (< from to))
              (setq pele-font-lock--matched-face (aref pele-font-lock--faces class))
              (set-match-data (list from to)) (goto-char to) (throw 'found t))))
        (goto-char (min limit (aref entry 2)))))
    nil))

(defun pele-font-lock--after-change (begin _end _old-length)
  "Invalidate cached state from the edited line at BEGIN."
  (when pele-font-lock--cache
    (let ((from (save-excursion (goto-char begin) (line-beginning-position))) keys)
      (maphash (lambda (position _value) (when (>= position from) (push position keys))) pele-font-lock--cache)
      (dolist (position keys) (remhash position pele-font-lock--cache))
      (when (and pele-font-lock--next-position (> pele-font-lock--next-position from))
        (setq pele-font-lock--next-position nil pele-font-lock--next-state 0))
      (when font-lock-mode (font-lock-flush from (point-max))))))

(defun pele-font-lock-setup ()
  "Install the pure Elisp website highlighter in the current buffer."
  (setq-local pele-font-lock--cache (make-hash-table :test #'eql))
  (setq-local pele-font-lock--next-position nil)
  (setq-local pele-font-lock--next-state 0)
  (setq-local font-lock-defaults
              '(((pele-font-lock--matcher (0 pele-font-lock--matched-face t))) t))
  (add-hook 'after-change-functions #'pele-font-lock--after-change nil t))

(provide 'pele-font-lock)
;;; pele-font-lock.el ends here
