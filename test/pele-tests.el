;;; pele-tests.el --- Integration tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: MIT
(require 'ert)
(require 'pele)
(require 'ob-pele)
(require 'org)
(require 'xml)
(require 'dom)

(defconst pele-test--flow "flowchart LR\nA[开始] --> B{Valid?}\nB -->|yes| C[完成]\nB -->|no| A")

(defun pele-test--wait ()
  (let ((deadline (+ (float-time) 10)))
    (while (and (> (hash-table-count pele--pending) 0) (< (float-time) deadline))
      (sleep-for 0.01)
      (pele--drain))
    (should (= 0 (hash-table-count pele--pending)))))

(defun pele-test--chain (count)
  (string-join (cons "flowchart TD"
                     (cl-loop for i from 1 below count
                              collect (format "n%d --> n%d" i (1+ i)))) "\n"))

(defun pele-test--xml (svg)
  (with-temp-buffer
    (insert svg)
    (if (fboundp 'libxml-parse-xml-region)
        (libxml-parse-xml-region (point-min) (point-max))
      (car (xml-parse-region (point-min) (point-max))))))

(ert-deftest pele-render-original-engine ()
  (let* ((result (pele-render pele-test--flow)) (svg (plist-get result :svg)))
    (should (plist-get result :ok))
    (should (equal "flowchart" (plist-get result :type)))
    (should (> (plist-get result :width) 0))
    (should (equal 'svg (car (pele-test--xml svg))))
    (dolist (label '("开始" "完成" "yes" "no")) (should (string-search label svg)))
    (should-not (string-search "var(" svg))))

(ert-deftest pele-retains-all-edge-labels ()
  (let ((svg (plist-get
              (pele-render "flowchart TD\nn0 -->|edge00| n4\nn1 -->|edge01| n4\nn2 -->|edge02| n6\nn4 -->|edge03| n6") :svg)))
    (dotimes (i 4) (should (string-search (format "edge%02d" i) svg)))))

(ert-deftest pele-unicode-labels-stay-text ()
  (let ((svg (plist-get (pele-render "flowchart LR\nA[\"é 👩‍💻 中文\"] --> B") :svg)))
    (should (string-search "é 👩‍💻 中文" svg))
    (should (pele-test--xml svg))))

(ert-deftest pele-supports-self-loops-nested-groups-and-semicolons ()
  (should (plist-get (pele-render "flowchart LR; subgraph Outer; subgraph Inner; A-->A; end; end;") :ok)))

(ert-deftest pele-pie-is-a-pie ()
  (let ((result (pele-render "pie title Animals\n\"Dogs\" : 3\n\"Cats\" : 2")))
    (should (equal "pie" (plist-get result :type)))
    (should (string-search "pele-slice" (plist-get result :svg)))))

(ert-deftest pele-syntax-errors-have-location ()
  (let* ((error (should-error (pele-render "flowchart TD\nA[Unfinished") :type 'pele-error))
         (details (nth 2 error)))
    (should (equal "syntax" (plist-get details :code)))
    (should (> (plist-get details :line) 0)))
  (should (plist-get (pele-render "flowchart LR\nA --> B") :ok)))

(ert-deftest pele-unsupported-type-is-reported ()
  (let ((error (should-error (pele-render "not-a-diagram") :type 'pele-error)))
    (should (equal "unsupported-diagram" (plist-get (nth 2 error) :code)))))

(ert-deftest pele-timeout-and-recovery ()
  (let* ((error (should-error (pele-render (pele-test--chain 1500) '(:timeout 1)) :type 'pele-error))
         (details (nth 2 error)))
    (should (equal "timeout" (plist-get details :code))))
  (should (plist-get (pele-render "flowchart LR\nRecovery --> OK" '(:timeout 1000)) :ok)))

(ert-deftest pele-source-limit-is-enforced ()
  (let ((error (should-error (pele-render (concat "flowchart LR\nA[" (make-string 60000 ?x) "]")) :type 'pele-error)))
    (should (equal "limit" (plist-get (nth 2 error) :code)))))

(ert-deftest pele-cancel-suppresses-callback-and-recovers ()
  (let ((called nil)
        (pele-cache-size 0))
    (pele-cancel (pele-render-async (pele-test--chain 300)
                                   (lambda (_) (setq called t))))
    (pele-test--wait)
    (should-not called)
    (should (plist-get (pele-render "flowchart LR\nAfterCancel --> OK") :ok))))

(ert-deftest pele-background-render-leaves-timers-responsive ()
  (let (ticked finished)
    (run-at-time 0.001 nil (lambda () (setq ticked t)))
    (pele-render-async (pele-test--chain 200)
                        (lambda (_) (setq finished t)) '(:timeout 2000))
    (pele-test--wait)
    (should ticked)
    (should finished)))

(ert-deftest pele-completion-channel-works-without-polling ()
  (let (done (deadline (+ (float-time) 5)))
    (pele-render-async "flowchart LR\nNativeNotification --> Emacs"
                        (lambda (result) (setq done (plist-get result :ok))))
    (when pele--poll-timer (cancel-timer pele--poll-timer) (setq pele--poll-timer nil))
    (while (and (not done) (< (float-time) deadline))
      (accept-process-output pele--channel 0.02))
    (should done)))

(ert-deftest pele-cache-hit-is-asynchronous-and-bounded ()
  (let ((pele--cache (make-hash-table :test #'equal))
        (pele--cache-order nil) (pele--cache-bytes 0)
        (pele-cache-size 2) called)
    (pele-render "flowchart LR\nA --> B")
    (pele-render-async "flowchart LR\nA --> B" (lambda (_) (setq called t)))
    (should-not called)
    (pele-test--wait)
    (should called)
    (pele-render "flowchart LR\nC --> D")
    (pele-render "flowchart LR\nE --> F")
    (should (= 2 (hash-table-count pele--cache)))
    (should (= 2 (length pele--cache-order)))))

(ert-deftest pele-cache-respects-byte-limit ()
  (let ((pele--cache (make-hash-table :test #'equal))
        (pele--cache-order nil) (pele--cache-bytes 0)
        (pele-cache-byte-limit 10))
    (pele-render "flowchart LR\nA --> B")
    (should (= 0 (hash-table-count pele--cache)))))

(ert-deftest pele-cached-results-arrive-asynchronously-without-periodic-polling ()
  (pele-test--wait)
  (pele-render "flowchart LR\nCached --> Ready")
  (should-not pele--poll-timer)
  (let (received cancelled)
    (dotimes (index 10)
      (pele-render-async "flowchart LR\nCached --> Ready"
                         (lambda (result)
                           (should (plist-get result :ok))
                           (push index received))))
    (setq cancelled (pele-render-async "flowchart LR\nCached --> Ready"
                                       (lambda (_) (ert-fail "Delivered a cancelled cached request"))))
    (pele-cancel cancelled)
    (should-not received)
    (should pele--delivery-timer)
    (should-not pele--poll-timer)
    (let ((deadline (+ (float-time) 2)))
      (while (and (< (length received) 10) (< (float-time) deadline))
        (accept-process-output pele--channel 0.01)))
    (should (= 10 (length received)))
    (should-not pele--delivery-timer)
    (should-not pele--poll-timer)))

(ert-deftest pele-shutdown-cancels-cached-delivery ()
  (pele-render "flowchart LR\nShutdownCache --> Ready")
  (let (called)
    (pele-render-async "flowchart LR\nShutdownCache --> Ready" (lambda (_) (setq called t)))
    (pele-shutdown)
    (accept-process-output nil 0.01)
    (should-not called)
    (should-not pele--delivery-timer)
    (should (= 0 (hash-table-count pele--pending)))))

(ert-deftest pele-gantt-cache-requires-explicit-time ()
  (let ((pele--cache (make-hash-table :test #'equal))
        (pele--cache-order nil) (pele--cache-bytes 0)
        (source "gantt\ndateFormat YYYY-MM-DD\nTask :2026-01-01, 1d"))
    (pele-render source)
    (should (= 0 (hash-table-count pele--cache)))
    (pele-render source '(:now 1767225600000))
    (should (= 1 (hash-table-count pele--cache)))))

(ert-deftest pele-gantt-crlf-does-not-cache-the-current-date ()
  (let ((pele--cache (make-hash-table :test #'equal))
        (pele--cache-order nil) (pele--cache-bytes 0))
    (pele-render "gantt\r\ndateFormat YYYY-MM-DD\r\nTask :2026-01-01, 1d\r\n")
    (pele-render "gantt\ndateFormat YYYY-MM-DD\nTask :2026-01-01, 1d\n" '(:now nil))
    (should (= 0 (hash-table-count pele--cache)))))

(ert-deftest pele-sync-cache-hit-leaves-no-completion-timers ()
  (pele-render "flowchart LR\nIdle --> Cache")
  (pele-render "flowchart LR\nIdle --> Cache")
  (should (= 0 (hash-table-count pele--pending)))
  (should-not pele--poll-timer)
  (should-not pele--delivery-timer))

(ert-deftest pele-themes-produce-concrete-different-colors ()
  (let ((light (plist-get (pele-render pele-test--flow '(:theme light)) :svg))
        (dark (plist-get (pele-render pele-test--flow '(:theme dark)) :svg))
        (custom (plist-get (pele-render pele-test--flow '(:theme (("--pele-fg" . "#123456")))) :svg)))
    (should-not (equal light dark))
    (should (string-search "#123456" custom))
    (dolist (svg (list light dark custom)) (should-not (string-search "var(" svg)))))

(ert-deftest pele-official-theme-includes-palette-and-corner-radius ()
  (let ((flow (plist-get (pele-render "flowchart LR\nA[First] --> B[Second]" '(:theme light :background theme)) :svg))
        (pie (plist-get (pele-render "pie\n\"One\": 3\n\"Two\": 2" '(:theme dark)) :svg)))
    (should (string-search "#fffcf0" flow))
    (should (string-search "#f2f0e5" flow))
    (should (string-search "rx=\"6px\"" flow))
    (should (string-search "#d14d41" pie))
    (should (string-search "#da702c" pie))))

(ert-deftest pele-transparent-canvas-keeps-node-fills ()
  (let* ((source "flowchart LR\nA[Rectangle] --> B((Circle))")
         (svg (plist-get (pele-render source '(:theme light :background transparent)) :svg))
         (tree (pele-test--xml svg)))
    (should-not (dom-by-class tree "pele-background"))
    (should (= 2 (length (dom-by-class tree "\\bpele-node\\b"))))
    (dolist (node (dom-by-class tree "\\bpele-node\\b"))
      (let* ((shape (or (car (dom-by-tag node 'rect)) (car (dom-by-tag node 'circle))))
             (fill (dom-attr shape 'fill)))
        (should shape)
        (should (equal fill "#f2f0e5"))))
    (let* ((solid (pele-test--xml
                   (plist-get (pele-render source '(:theme light :background theme)) :svg)))
           (background (car (dom-by-class solid "pele-background"))))
      (should (equal "#fffcf0" (dom-attr background 'fill)))
      (should (equal "100%" (dom-attr background 'width))))))

(ert-deftest pele-native-measurement-respects-actual-font ()
  (let* ((wide "flowchart LR\nA[MMMMMMMMMMMM]")
         (narrow "flowchart LR\nA[iiiiiiiiiiii]")
         (options '(:font-family "monospace" :measure-text native))
         (result (pele-render wide options)))
    (skip-unless (equal "native" (plist-get result :textMeasurement)))
    ;; The old Arial estimates incorrectly gave different widths to these
    ;; two labels even when the SVG used a monospace font.
    (should (= (plist-get result :width)
               (plist-get (pele-render narrow options) :width)))
    (should-not (= (plist-get result :width)
                   (plist-get (pele-render wide '(:font-family "sans-serif" :measure-text native)) :width)))))

(ert-deftest pele-estimated-measurement-remains-available ()
  (let ((result (pele-render pele-test--flow '(:measure-text estimate))))
    (should (equal "estimate" (plist-get result :textMeasurement)))))

(defun pele-test--font-family (generic)
  "Resolve GENERIC to an installed family for font-order assertions."
  (if (eq system-type 'darwin)
      (if (equal generic "monospace") "Menlo" "Helvetica")
    (when (executable-find "fc-match")
      (with-temp-buffer
        (when (eq 0 (process-file "fc-match" nil t nil "-f" "%{family[0]}" generic))
          (let ((family (string-trim (buffer-string))))
            (unless (string-empty-p family) family)))))))

(ert-deftest pele-native-font-family-fallback-uses-available-fonts ()
  (let* ((source "flowchart LR\nA[MMMMMMMMMMMM]")
         (mono (pele-render source '(:font-family "monospace")))
         (fallback (pele-render source '(:font-family "\"Pele Missing Font 07CF\", monospace, sans-serif"))))
    (skip-unless (equal "native" (plist-get mono :textMeasurement)))
    (should (= (plist-get mono :width) (plist-get fallback :width)))
    ;; Pango and Core Text may resolve mixed generic aliases differently.
    ;; Verify family order with actual installed names instead of aliases.
    (let ((sans-family (pele-test--font-family "sans-serif"))
          (mono-family (pele-test--font-family "monospace")))
      (when (and sans-family mono-family)
        (dolist (families (list (list sans-family mono-family) (list mono-family sans-family)))
          (should (= (plist-get (pele-render source (list :font-family (car families))) :width)
                     (plist-get (pele-render source (list :font-family (string-join families ", "))) :width))))))))

(ert-deftest pele-native-font-measurement-follows-size-and-bold ()
  (let* ((source "flowchart LR\nA[iiiiiiiiiiii]")
         (plain (pele-render source '(:font-family "sans-serif" :font-size 16)))
         (bold (pele-render "flowchart LR\nA[\"<b>iiiiiiiiiiii</b>\"]" '(:font-family "sans-serif" :font-size 16))))
    (skip-unless (equal "native" (plist-get plain :textMeasurement)))
    (should (> (plist-get bold :width) (plist-get plain :width)))
    (should (> (plist-get (pele-render source '(:font-family "sans-serif" :font-size 32)) :width)
               (plist-get plain :width)))))

(ert-deftest pele-css-looking-label-is-not-rewritten ()
  (should (string-search "var(--example)"
                         (plist-get (pele-render "flowchart LR\nA[\"var(--example)\"]") :svg))))

(ert-deftest pele-native-input-validation-keeps-emacs-alive ()
  (pele--ensure-module)
  (should-error (pele--native-submit 1 nil "{}" 1000))
  (should-error (pele--native-submit 1 "info" "{}" 0))
  (should-error (pele--native-submit 1 (make-string 1048577 ?x) "{}" 1000))
  (should-error (pele-render "info" '(:font-size 500)))
  (should-error (pele-render "info" '(:background white)))
  (should-error (pele-render "info" '(:now "today")))
  (should-error (pele-render "info" '(:theme (("--bad" . "red")))))
  (should (plist-get (pele-render "info") :ok)))

(ert-deftest pele-shutdown-allows-restart ()
  (pele-render "flowchart LR\nBefore --> Shutdown")
  (pele-shutdown)
  (should (plist-get (pele-render "flowchart LR\nAfter --> Restart") :ok)))

(ert-deftest pele-native-queue-is-bounded ()
  (pele-test--wait)
  (pele-shutdown)
  (dotimes (i 32) (pele--native-submit (+ 100000 i) "info" "{}" 1000))
  (should-error (pele--native-submit 200000 "info" "{}" 1000))
  (let ((deadline (+ (float-time) 10)) (count 0))
    (while (and (< count 32) (< (float-time) deadline))
      (if (pele--native-poll) (cl-incf count) (sleep-for 0.01)))
    (should (= count 32)))
  (pele-shutdown))

(ert-deftest pele-org-extracts-only-current-source-block ()
  (with-temp-buffer
    (org-mode)
    (insert "* Notes\n#+begin_src mermaid\nflowchart LR\nA --> B\n#+end_src\n")
    (goto-char (point-min)) (search-forward "A -->")
    (should (equal "flowchart LR\nA --> B\n" (pele--source-at-point)))))

(ert-deftest pele-org-supports-pele-source-blocks ()
  (skip-unless (image-type-available-p 'svg))
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src pele\nflowchart LR\nA --> B\n#+end_src\n")
    (goto-char (point-min)) (search-forward "A -->")
    (should (equal "flowchart LR\nA --> B\n" (pele--source-at-point)))
    (unwind-protect
        (progn
          (pele-org-mode 1) (pele-test--wait)
          (should (= 1 (length pele--inline-overlays)))
          (should (overlay-get (car pele--inline-overlays) 'pele-result)))
      (pele-org-mode -1))))

(ert-deftest pele-preview-cancels-on-mode-change-and-keeps-new-content ()
  (let (callback cancelled)
    (cl-letf (((symbol-function 'pele-render-async)
               (lambda (_source function &optional _options) (setq callback function) 73))
              ((symbol-function 'pele-cancel) (lambda (id) (push id cancelled)))
              ((symbol-function 'pele--image) (lambda (&rest _) nil))
              ((symbol-function 'insert-image) (lambda (&rest _) (insert "late image"))))
      (with-temp-buffer
        (pele-preview-mode)
        (setq pele--preview-source "flowchart LR\nA --> B")
        (pele-preview-refresh)
        (fundamental-mode)
        (setq buffer-read-only nil)
        (insert "User content")
        (funcall callback '(:ok t :svg "unused"))
        (should (equal "User content" (buffer-string)))
        (should (equal '(73) cancelled))))))

(ert-deftest pele-preview-cancels-when-buffer-is-killed ()
  (let ((buffer (generate-new-buffer " *pele-preview-test*")) cancelled)
    (cl-letf (((symbol-function 'pele-render-async) (lambda (&rest _) 74))
              ((symbol-function 'pele-cancel) (lambda (id) (push id cancelled))))
      (unwind-protect
          (with-current-buffer buffer
            (pele-preview-mode)
            (setq pele--preview-source "flowchart LR\nA --> B")
            (pele-preview-refresh))
        (kill-buffer buffer))
      (should (equal '(74) cancelled)))))

(ert-deftest pele-org-preview-keeps-buffer-unmodified ()
  (skip-unless (image-type-available-p 'svg))
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src mermaid\nflowchart LR\nA --> B\n#+end_src\n")
    (set-buffer-modified-p nil)
    (unwind-protect
        (progn
          (pele-org-mode 1)
          (pele-test--wait)
          (should (= 1 (length pele--inline-overlays)))
          (should (overlay-get (car pele--inline-overlays) 'pele-result))
          (should-not (buffer-modified-p)))
      (pele-org-mode -1))))

(ert-deftest pele-org-input-after-preview-stays-below-image ()
  (skip-unless (image-type-available-p 'svg))
  (dolist (tail '("" "\n\n" " \t" "\n \t\nNext paragraph\n"))
    (with-temp-buffer
      (org-mode)
      (insert "#+begin_src mermaid\ninfo\n#+end_src\n")
      (let ((end (point)))
        (insert tail)
        (unwind-protect
            (progn
              (pele-org-mode 1) (pele-test--wait)
              (let* ((overlay (car pele--inline-overlays))
                     (image (overlay-get overlay 'after-string)))
                (should (= end (overlay-start overlay)))
                (goto-char end) (newline 2)
                (should (= end (overlay-start overlay)))
                (pele--inline-refresh) (pele-test--wait)
                (should (eq overlay (car pele--inline-overlays)))
                (should (= end (overlay-start overlay)))
                (should (equal image (overlay-get overlay 'after-string)))
                (insert "Text below the diagram")
                (pele--inline-refresh) (pele-test--wait)
                (should (= end (overlay-start overlay)))))
          (pele-org-mode -1))))))

(ert-deftest pele-org-retains-last-image-on-incomplete-input ()
  (skip-unless (image-type-available-p 'svg))
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src mermaid\nflowchart LR\nA --> B\n#+end_src\n")
    (unwind-protect
        (progn
          (pele-org-mode 1) (pele-test--wait)
          (let* ((overlay (car pele--inline-overlays)) (image (overlay-get overlay 'after-string)))
            (goto-char (point-min)) (search-forward "A --> B") (replace-match "A[")
            (pele--inline-refresh) (pele-test--wait)
            (should (equal image (overlay-get overlay 'after-string)))
            (should (stringp (overlay-get overlay 'help-echo)))))
      (pele-org-mode -1))))

(ert-deftest pele-org-cleans-up-removed-blocks ()
  (skip-unless (image-type-available-p 'svg))
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src mermaid\ninfo\n#+end_src\n")
    (unwind-protect
        (progn
          (pele-org-mode 1) (pele-test--wait)
          (erase-buffer) (pele--inline-refresh)
          (should-not pele--inline-overlays))
      (pele-org-mode -1))))

(ert-deftest pele-org-cleans-up-on-major-mode-change ()
  (skip-unless (image-type-available-p 'svg))
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src mermaid\ninfo\n#+end_src\n")
    (pele-org-mode 1) (pele-test--wait)
    (let ((overlay (car pele--inline-overlays)))
      (fundamental-mode)
      (should-not (overlay-buffer overlay)))))

(ert-deftest pele-org-initial-render-error-restores-editor-state ()
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src mermaid\ninfo\n#+end_src\n")
    (cl-letf (((symbol-function 'pele-render-async) (lambda (&rest _) (error "Unavailable renderer"))))
      (should-error (pele-org-mode 1)))
    (should-not pele-org-mode)
    (should-not pele--inline-overlays)
    (should-not (local-variable-p 'mwheel-scroll-up-function))
    (should-not (memq #'pele--inline-after-command post-command-hook))))

(ert-deftest pele-many-previews-respect-native-queue-bound ()
  (skip-unless (image-type-available-p 'svg))
  (with-temp-buffer
    (org-mode)
    (dotimes (i 45)
      (insert (format "#+begin_src mermaid\nflowchart LR\nn%d --> done%d\n#+end_src\n\n" i i)))
    (unwind-protect
        (progn
          (pele-org-mode 1) (pele-test--wait)
          (should (= 45 (length pele--inline-overlays)))
          (dolist (overlay pele--inline-overlays)
            (should (overlay-get overlay 'pele-result))))
      (pele-org-mode -1))))

(ert-deftest pele-babel-writes-actual-svg ()
  (let ((file (make-temp-file "pele-test-" nil ".svg")))
    (unwind-protect
        (progn
          (should (equal file (org-babel-execute:pele "sequenceDiagram\nA->>B: hello" `((:file . ,file)))))
          (with-temp-buffer
            (insert-file-contents file)
            (should (string-search "pele-sequence" (buffer-string)))))
      (delete-file file))))

(ert-deftest pele-babel-validates-file-before-render ()
  (should-error (org-babel-execute:pele "info" nil) :type 'user-error)
  (should-error (org-babel-execute:pele "info" '((:file . "wrong.png"))) :type 'user-error))

(ert-deftest pele-babel-executes-complete-org-block ()
  (let ((file (make-temp-file "pele-babel-" nil ".svg"))
        (org-confirm-babel-evaluate nil))
    (unwind-protect
        (progn
          (pele-babel-enable-mermaid)
          (dolist (language '(pele mermaid))
            (with-temp-buffer
              (org-mode)
              (insert (format "#+begin_src %s :file %s\nflowchart LR\nA --> B\n#+end_src\n" language file))
              (goto-char (point-min))
              (org-babel-execute-src-block)
              (should (string-search (concat "[[file:" file "]]") (buffer-string)))
              (should (> (file-attribute-size (file-attributes file)) 100)))))
      (pele-babel-disable-mermaid)
      (delete-file file))))

(ert-deftest pele-babel-backend-is-opt-in-and-restorable ()
  (let ((before (and (fboundp 'org-babel-execute:mermaid) (symbol-function 'org-babel-execute:mermaid)))
        (headers-bound (boundp 'org-babel-default-header-args:mermaid))
        (headers (and (boundp 'org-babel-default-header-args:mermaid)
                      org-babel-default-header-args:mermaid)))
    (unwind-protect
        (progn
          (pele-babel-enable-mermaid)
          (should (eq (symbol-function 'org-babel-execute:mermaid) 'org-babel-execute:pele)))
      (pele-babel-disable-mermaid))
    (should (equal before (and (fboundp 'org-babel-execute:mermaid)
                              (symbol-function 'org-babel-execute:mermaid))))
    (should (eq headers-bound (boundp 'org-babel-default-header-args:mermaid)))
    (when headers-bound (should (equal headers org-babel-default-header-args:mermaid)))))

(provide 'pele-tests)
