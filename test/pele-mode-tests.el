;;; pele-mode-tests.el --- Verify the standalone editor -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: MIT
(require 'ert)
(require 'cl-lib)
(require 'pele-mode)

(defun pele-mode-test--face (text)
  (goto-char (point-min))
  (search-forward text)
  (get-text-property (- (point) (length text)) 'face))

(defun pele-mode-test--indent (source)
  (with-temp-buffer
    (insert source)
    (pele-mode)
    (indent-region (point-min) (point-max))
    (buffer-string)))

(ert-deftest pele-mode-editing-needs-no-renderer-or-process ()
  (let ((loaded (featurep 'pele-native)) (treesit (featurep 'treesit)))
    (cl-letf (((symbol-function 'call-process) (lambda (&rest _) (ert-fail "Started a process")))
              ((symbol-function 'process-file) (lambda (&rest _) (ert-fail "Started a process")))
              ((symbol-function 'make-process) (lambda (&rest _) (ert-fail "Started a process")))
              ((symbol-function 'module-load) (lambda (&rest _) (ert-fail "Loaded a native module")))
              ((symbol-function 'treesit-parser-create) (lambda (&rest _) (ert-fail "Created a Tree-sitter parser"))))
      (with-temp-buffer
        (insert "flowchart LR\nA[Start] --> B[End]\n%% comment\n")
        (pele-mode)
        (font-lock-ensure)
        (indent-region (point-min) (point-max))
        (should (eq (pele-mode-test--face "flowchart") 'pele-keyword-face))))
    (should (eq loaded (featurep 'pele-native)))
    (should (eq treesit (featurep 'treesit)))))

(ert-deftest pele-mode-comments-strings-and-single-percent ()
  (with-temp-buffer
    (insert "flowchart LR\n%% title is a comment\nA[\"100% and %% are text\"] --> B[Done]\n")
    (pele-mode)
    (font-lock-ensure)
    (should (eq (pele-mode-test--face "title") 'pele-comment-face))
    (should (eq (pele-mode-test--face "100%") 'pele-string-face))
    (should (eq (pele-mode-test--face "%% are") 'pele-string-face))
    (should (eq (pele-mode-test--face "-->") 'pele-punctuation-face))
    (should (eq (pele-mode-test--face "A[") 'pele-variable-face))))

(ert-deftest pele-mode-directives-and-new-diagram-headers ()
  (with-temp-buffer
    (insert "%%{init: {\"theme\": \"dark\"}}%%\nrailroad-ebnf-beta\n")
    (pele-mode)
    (font-lock-ensure)
    (should (eq (pele-mode-test--face "%%{init") 'pele-language-face))
    (should (eq (pele-mode-test--face "railroad-ebnf-beta") 'pele-keyword-face))))

(ert-deftest pele-mode-indents-nested-flowchart-blocks ()
  (should
   (equal (pele-mode-test--indent
           "flowchart TD\nsubgraph Outer\nA --> B\nsubgraph Inner\nB --> C\nend\nend\nD --> E\n")
          "flowchart TD\n  subgraph Outer\n    A --> B\n    subgraph Inner\n      B --> C\n    end\n  end\n  D --> E\n")))

(ert-deftest pele-mode-indents-sequence-branches ()
  (should
   (equal (pele-mode-test--indent
           "sequenceDiagram\nalt Success\nA->>B: yes\nelse Retry\nloop Attempts\nB-->>A: retry\nend\nend\n")
          "sequenceDiagram\n  alt Success\n    A->>B: yes\n  else Retry\n    loop Attempts\n      B-->>A: retry\n    end\n  end\n")))

(ert-deftest pele-mode-indents-braces-and-gantt-sections ()
  (should (equal (pele-mode-test--indent "classDiagram\nclass Vehicle {\n+String name\n}\nVehicle --> Other\n")
                 "classDiagram\n  class Vehicle {\n    +String name\n  }\n  Vehicle --> Other\n"))
  (should (equal (pele-mode-test--indent "gantt\nsection Engine\nBuild :2026-11-24, 1d\nsection Editor\nTest :2026-11-25, 1d\n")
                 "gantt\n  section Engine\n    Build :2026-11-24, 1d\n  section Editor\n    Test :2026-11-25, 1d\n")))

(ert-deftest pele-mode-preserves-tree-and-frontmatter-indentation ()
  (let ((source "---\nconfig:\n  theme: dark\n---\nmindmap\n  root((Pele))\n    Editor\n      Highlight\n    Renderer\n"))
    (should (equal source (pele-mode-test--indent source))))
  (with-temp-buffer
    (insert "mindmap\n  root\n    Child\n")
    (pele-mode)
    (goto-char (point-max))
    (pele-indent-line)
    (should (= 4 (current-indentation)))))

(ert-deftest pele-mode-indentation-ignores-comment-markers-in-strings ()
  (should (equal (pele-mode-test--indent "flowchart TD\nsubgraph Outer %% comment\nA[\"%% text\"] --> B\nend\n")
                 "flowchart TD\n  subgraph Outer %% comment\n    A[\"%% text\"] --> B\n  end\n")))

(ert-deftest pele-mode-org-fontification-and-edit-buffer ()
  (require 'org)
  (require 'org-src)
  (let ((before (and (fboundp 'org-babel-execute:mermaid)
                      (symbol-function 'org-babel-execute:mermaid)))
        (org-src-fontify-natively t))
    (dolist (language '("mermaid" "pele"))
      (save-window-excursion
        (with-temp-buffer
          (org-mode)
          (insert (format "#+begin_src %s\nflowchart LR\nA --> B\n#+end_src\n" language))
          (font-lock-ensure)
          (should (memq 'pele-keyword-face
                        (ensure-list (pele-mode-test--face "flowchart"))))
          (goto-char (point-min))
          (org-edit-special)
          (unwind-protect
              (should (derived-mode-p 'pele-mode))
            (org-edit-src-abort)))))
    (should (eq before (and (fboundp 'org-babel-execute:mermaid)
                             (symbol-function 'org-babel-execute:mermaid))))))

(ert-deftest pele-mode-respects-existing-org-mode-choices ()
  (require 'org-src)
  (let ((org-src-lang-modes '(("mermaid" . user-mode))))
    (pele-mode--register-org)
    (should (eq 'user-mode (cdr (assoc "mermaid" org-src-lang-modes))))
    (should (eq 'pele (cdr (assoc "pele" org-src-lang-modes))))))

(provide 'pele-mode-tests)
;;; pele-mode-tests.el ends here
