;;; pele-highlighting-tests.el --- Compare to the website -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: MIT
(require 'ert)
(require 'cl-lib)
(require 'pele-mode)

(defconst pele-highlighting-test--directory
  (expand-file-name "corpus" (file-name-directory (or load-file-name buffer-file-name))))
(defconst pele-highlighting-test--reference
  (with-temp-buffer
    (insert-file-contents (expand-file-name "highlighting.json" pele-highlighting-test--directory))
    (json-parse-buffer :array-type 'list :null-object nil)))

(defun pele-highlighting-test--runs ()
  "Return canonical (END CLASS) runs for the current buffer's actual faces."
  (let ((position (point-min)) runs)
    (while (< position (point-max))
      (let* ((face (get-text-property position 'face))
             (class (cl-position face pele-font-lock--faces))
             (end (next-single-property-change position 'face nil (point-max))))
        (unless class (ert-fail (list :unexpected-face face :at position)))
        (if (and runs (= class (cadar runs)))
            (setcar (car runs) (1- end))
          (push (list (1- end) class) runs))
        (setq position end)))
    (nreverse runs)))

(defun pele-highlighting-test--assert-runs (expected)
  "Compare EXPECTED to actual faces without printing an entire large corpus case."
  (let ((actual (pele-highlighting-test--runs)) (index 0))
    (while (and actual expected (equal (car actual) (car expected)))
      (setq actual (cdr actual) expected (cdr expected)) (cl-incf index))
    (when (or actual expected)
      (ert-fail (list :run index :actual (cl-subseq actual 0 (min 5 (length actual)))
                      :expected (cl-subseq expected 0 (min 5 (length expected))))))))

(defun pele-highlighting-test--assert-states (source expected)
  (let ((state 0) states)
    (dolist (line (split-string source "\n" nil))
      (setq state (car (pele-font-lock--scan-line line state)))
      (push state states))
    (should (equal (nreverse states) expected))))

(defun pele-highlighting-test--replace (source)
  "Change only the differing region of the current buffer to SOURCE."
  (let* ((old (buffer-substring-no-properties (point-min) (point-max)))
         (prefix 0) (old-end (length old)) (new-end (length source)))
    (while (and (< prefix old-end) (< prefix new-end) (= (aref old prefix) (aref source prefix)))
      (cl-incf prefix))
    (while (and (> old-end prefix) (> new-end prefix)
                (= (aref old (1- old-end)) (aref source (1- new-end))))
      (cl-decf old-end) (cl-decf new-end))
    (goto-char (1+ prefix))
    (delete-region (point) (1+ old-end))
    (insert (substring source prefix new-end))))

(ert-deftest pele-highlighting-reference-matches-vendored-source ()
  (maphash
   (lambda (name expected)
     (with-temp-buffer
       (set-buffer-multibyte nil)
       (insert-file-contents-literally
        (expand-file-name (concat "../../vendor/pele-website/" name)
                          pele-highlighting-test--directory))
       (should (equal expected (secure-hash 'sha256 (current-buffer))))))
   (gethash "sha256" pele-highlighting-test--reference)))

(ert-deftest pele-highlighting-matches-website-all-522-examples ()
  (should (equal (append pele-font-lock--classes nil)
                 (gethash "classes" pele-highlighting-test--reference)))
  (let ((count 0))
    (maphash
     (lambda (file references)
       (let ((sources (with-temp-buffer
                        (insert-file-contents (expand-file-name file pele-highlighting-test--directory))
                        (json-parse-buffer :array-type 'list)))
             (index 0))
         (cl-mapc
          (lambda (source reference)
            (ert-info ((format "%s case %d" file index))
              (with-temp-buffer
                (insert source) (pele-mode) (font-lock-ensure)
                (pele-highlighting-test--assert-runs (gethash "runs" reference))))
            (cl-incf count) (cl-incf index)) sources references)))
     (gethash "corpus" pele-highlighting-test--reference))
    (should (= 522 count))))

(ert-deftest pele-highlighting-matches-website-focused-cases-and-states ()
  (dolist (reference (gethash "fixtures" pele-highlighting-test--reference))
    (ert-info ((gethash "name" reference))
      (let ((source (gethash "source" reference)))
        (with-temp-buffer
          (insert source) (pele-mode) (font-lock-ensure)
          (pele-highlighting-test--assert-runs (gethash "runs" reference)))
        (pele-highlighting-test--assert-states source (gethash "states" reference))))))

(ert-deftest pele-highlighting-updates-cross-line-state-after-small-edits ()
  (dolist (sequence (gethash "edits" pele-highlighting-test--reference))
    (ert-info ((gethash "name" sequence))
      (with-temp-buffer
        (pele-mode)
        (dolist (step (gethash "steps" sequence))
          (pele-highlighting-test--replace (gethash "source" step))
          (font-lock-ensure)
          (pele-highlighting-test--assert-runs (gethash "runs" step)))))))

(ert-deftest pele-highlighting-fontifies-from-inside-a-multiline-label ()
  (with-temp-buffer
    (insert "flowchart LR\nA[\"first\nsecond\nthird\"] --> B\n")
    (pele-mode)
    (goto-char (point-min)) (search-forward "second")
    (let ((begin (- (point) 6)))
      (font-lock-ensure begin (point))
      (should (eq (get-text-property begin 'face) 'pele-string-face)))))

(ert-deftest pele-highlighting-preserves-state-with-out-of-order-regions ()
  ;; JIT fontification can jump to a distant viewport, then back to cached
  ;; earlier lines.  The sequential cache shortcut must not use the wrong state.
  (dolist (name '("frontmatter" "metadata" "nodes-and-labels"))
    (let ((reference (seq-find (lambda (value) (equal (gethash "name" value) name))
                               (gethash "fixtures" pele-highlighting-test--reference))))
      (ert-info (name)
        (with-temp-buffer
          (insert (gethash "source" reference)) (pele-mode)
          (let (regions)
            (goto-char (point-min))
            (while (< (point) (point-max))
              (let ((begin (point)))
                (forward-line 1)
                (push (cons begin (point)) regions)))
            (dolist (region regions) (font-lock-ensure (car region) (cdr region)))
            (dolist (region (reverse regions)) (font-lock-ensure (car region) (cdr region)))
            (font-lock-ensure)
            (pele-highlighting-test--assert-runs (gethash "runs" reference))))))))

(provide 'pele-highlighting-tests)
;;; pele-highlighting-tests.el ends here
