;;; benchmark.el --- Measure Pele API and highlighting latency -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: MIT
;; Run: emacs -Q --batch -L . -l scripts/benchmark.el
;; Results are written to test/output/performance.json.  No GUI drawing is timed.

(require 'cl-lib)
(require 'json)
(require 'pele)

(defconst pele-bench--root
  (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name)))))
(defconst pele-bench--small
  "flowchart LR\nA[开始] --> B{校验通过?}\nB -->|是| C[保存]\nB -->|否| D[修正]\nD --> B\n")
(defvar pele-bench--rows nil)

(defun pele-bench--stats (name samples &rest metadata)
  (let* ((values (sort (copy-sequence samples) #'<)) (n (length values))
         (median (if (= (% n 2) 0)
                     (/ (+ (nth (1- (/ n 2)) values) (nth (/ n 2) values)) 2.0)
                   (nth (/ n 2) values))))
    (let ((row (append (list :name name :samples n :medianMs median
                             :p95Ms (nth (1- (ceiling (* n 0.95))) values)
                             :minMs (car values) :maxMs (car (last values))) metadata)))
      (push row pele-bench--rows)
      (princ (format "%s: median %.3f ms, p95 %.3f ms (%d samples)\n"
                     name median (plist-get row :p95Ms) n))
      row)))

(defun pele-bench--measure (function count)
  (let (samples)
    (dotimes (_ count)
      (let ((start (float-time)))
        (funcall function)
        (push (* 1000.0 (- (float-time) start)) samples)))
    (nreverse samples)))

(defun pele-bench--chain (nodes)
  (concat "flowchart TD\n"
          (mapconcat (lambda (i) (format "n%d --> n%d" i (1+ i)))
                     (number-sequence 0 (- nodes 2)) "\n") "\n"))

(defun pele-bench--highlight (source count label)
  (let (samples)
    (dotimes (_ count)
      (with-temp-buffer
        (insert source) (pele-mode)
        (let ((start (float-time)))
          (font-lock-ensure)
          (push (* 1000.0 (- (float-time) start)) samples))))
    (pele-bench--stats label (nreverse samples) :characters (length source))))

(defun pele-bench--edit (source near-top count)
  (with-temp-buffer
    (insert source) (pele-mode) (font-lock-mode 1) (font-lock-ensure)
    (let ((position (save-excursion
                      (goto-char (if near-top (point-min) (point-max)))
                      (if near-top (forward-line 2) (forward-line -1))
                      (line-end-position)))
          samples)
      (dotimes (_ count)
        (goto-char position)
        (let ((start (float-time)))
          (insert "x")
          ;; A viewport of up to 40 lines; the rest is refontified on demand.
          (font-lock-ensure (line-beginning-position)
                            (save-excursion (forward-line 40) (point)))
          (push (* 1000.0 (- (float-time) start)) samples))
        (goto-char position) (delete-char 1)
        (font-lock-ensure))
      (pele-bench--stats (if near-top "edit-top-viewport-1000-lines" "edit-bottom-1000-lines")
                         (nreverse samples) :characters (length source)
                         :fontLockMode (if font-lock-mode t :false)))))

(let ((coding-system-for-write 'utf-8-unix)
      (options '(:timeout 5000 :now 1767225600000))
      (pele-cache-size 0)
      (started (float-time)))
  (pele-clear-cache)
  (garbage-collect)
  (let* ((start (float-time)) (result (pele-render pele-bench--small options)))
    (pele-bench--stats "first-render-in-process" (list (* 1000.0 (- (float-time) start)))
                       :textMeasurement (plist-get result :textMeasurement)))
  (pele-bench--stats "small-render-no-svg-cache"
                     (pele-bench--measure (lambda () (pele-render pele-bench--small options)) 100))
  (dolist (nodes '(100 300 1000))
    (let* ((source (pele-bench--chain nodes))
           (result (pele-render source options)))
      (pele-bench--stats (format "chain-%d-nodes-no-svg-cache" nodes)
                         (pele-bench--measure (lambda () (pele-render source options)) 10)
                         :characters (length source) :svgBytes (string-bytes (plist-get result :svg)))))
  (let ((pele-cache-size 32))
    (pele-clear-cache)
    (pele-render pele-bench--small options)
    (pele-bench--stats "small-svg-cache-hit-sync"
                       (pele-bench--measure (lambda () (pele-render pele-bench--small options)) 200))
    (let (samples)
      (dotimes (_ 15)
        (let ((start (float-time)) done)
          (pele-render-async pele-bench--small (lambda (_) (setq done t)) options)
          (while (not done) (accept-process-output pele--channel 0.002))
          (push (* 1000.0 (- (float-time) start)) samples)))
      (pele-bench--stats "small-svg-cache-hit-async-delivery" (nreverse samples))))
  (pele-clear-cache)
  (let ((files (directory-files (expand-file-name "test/corpus" pele-bench--root) t "-docs\\.json\\'"))
        samples (count 0))
    (dolist (file files)
      (let ((sources (with-temp-buffer (insert-file-contents file) (json-parse-buffer :array-type 'list))))
        (dolist (source sources)
          (let ((start (float-time)))
            (pele-render source options)
            (push (* 1000.0 (- (float-time) start)) samples)
            (cl-incf count)))))
    (pele-bench--stats "522-examples-no-svg-cache" (nreverse samples) :diagramTypes (length files) :cases count))
  (pele-bench--highlight pele-bench--small 100 "small-initial-highlighting")
  (pele-bench--highlight (pele-bench--chain 100) 30 "100-lines-initial-highlighting")
  (pele-bench--highlight (pele-bench--chain 1000) 10 "1000-lines-initial-highlighting")
  (pele-bench--edit (pele-bench--chain 1000) nil 30)
  (pele-bench--edit (pele-bench--chain 1000) t 30)
  (let* ((source (pele-bench--chain 1000)) (last (float-time)) gaps done outcome
         (timer (run-at-time 0.005 0.005
                             (lambda ()
                               (let ((now (float-time)))
                                 (push (* 1000.0 (- now last)) gaps)
                                 (setq last now)))))
         (start (float-time))
         (request (pele-render-async source (lambda (result) (setq outcome result done t)) options))
         (submit (* 1000.0 (- (float-time) start))))
    (unwind-protect
        (progn
          (while (not done) (accept-process-output pele--channel 0.002))
          (unless (plist-get outcome :ok) (error "Heartbeat rendering failed: %S" outcome))
          (when gaps (pele-bench--stats "main-thread-timer-gaps-during-1000-node-render" (nreverse gaps)
                                        :requestedIntervalMs 5 :submitMs submit
                                        :renderMs (* 1000.0 (- (float-time) start)))))
      (cancel-timer timer)
      (unless done (pele-cancel request))))
  (make-directory (expand-file-name "test/output" pele-bench--root) t)
  (with-temp-file (expand-file-name "test/output/performance.json" pele-bench--root)
    (insert (json-serialize
             (list :packageVersion pele-version :engineVersion pele-engine-version
                   :emacsVersion emacs-version :system system-configuration
                   :gcConsThreshold gc-cons-threshold :gcConsPercentage gc-cons-percentage
                   :previewDebounceMs (* 1000 pele-preview-delay)
                   :scope "Batch Emacs; elapsed API/highlighting time including normal GC, excluding GUI SVG rasterization/display and Emacs startup. Cold render includes module and engine initialization."
                   :elapsedSeconds (- (float-time) started)
                   :results (vconcat (nreverse pele-bench--rows))))))
  (pele-shutdown))
