;;; pele-corpus-tests.el --- Compare all diagram kinds to upstream -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: MIT
(require 'ert)
(require 'pele)
(require 'xml)

(defconst pele-corpus--directory
  (expand-file-name "corpus" (file-name-directory (or load-file-name buffer-file-name))))

(defun pele-corpus--read (file)
  (with-temp-buffer
    (insert-file-contents (expand-file-name file pele-corpus--directory))
    (json-parse-buffer :object-type 'hash-table :array-type 'list :false-object nil)))

(defun pele-corpus--digest (svg regexp)
  (let ((position 0) parts)
    (while (string-match regexp svg position)
      (when (> (length (match-string 1 svg)) 0) (push (match-string 1 svg) parts))
      (setq position (match-end 0)))
    (secure-hash 'sha256 (encode-coding-string (mapconcat #'identity (nreverse parts) "\0") 'utf-8))))

(let* ((manifest (pele-corpus--read "manifest.json"))
       (now (gethash "now" manifest)))
  ;; Match the original engine's reference timezone, including local-calendar
  ;; Gantt operations. This affects only the isolated corpus-test process.
  (set-time-zone-rule (gethash "timezone" manifest))
  (maphash
   (lambda (file expected)
     (ert-set-test
      (intern (concat "pele-corpus-" (string-remove-suffix "-docs.json" file)))
      (make-ert-test
       :name (intern (concat "pele-corpus-" (string-remove-suffix "-docs.json" file)))
       :body
       (lambda ()
         (let ((sources (pele-corpus--read file)) (index 0) (pele-cache-size 0))
           (cl-mapc
            (lambda (source reference)
              (ert-info ((format "%s case %d: %.100s" file index source))
                (if (gethash "ok" reference)
                    (let* ((result (pele-render source (list :now now :theme 'light :timeout 5000
                                                            :font-family "sans-serif" :font-family-mono "monospace"
                                                            :measure-text 'estimate)))
                           (svg (plist-get result :svg)))
                      (should (equal (gethash "type" reference) (plist-get result :type)))
                      (should (= (gethash "width" reference) (plist-get result :width)))
                      (should (= (gethash "height" reference) (plist-get result :height)))
                      (should (equal (gethash "paths" reference)
                                     (pele-corpus--digest svg "<path\\b[^>]*\\bd=\"\\([^\"]*\\)\"")))
                      (should (equal (gethash "text" reference)
                                     (pele-corpus--digest svg ">\\([^<]*\\)<")))
                      (should-not (string-match-p "[=\"]var(" svg))
                      (with-temp-buffer
                        (insert svg)
                        (should (if (fboundp 'libxml-parse-xml-region)
                                    (libxml-parse-xml-region (point-min) (point-max))
                                  (xml-parse-region (point-min) (point-max)))))
                      (let* ((native (pele-render source (list :now now :theme 'light :timeout 5000)))
                             (native-svg (plist-get native :svg)))
                        (should (plist-get native :ok))
                        (should (> (plist-get native :width) 0))
                        (should (> (plist-get native :height) 0))
                        (with-temp-buffer
                          (insert native-svg)
                          (should (if (fboundp 'libxml-parse-xml-region)
                                      (libxml-parse-xml-region (point-min) (point-max))
                                    (xml-parse-region (point-min) (point-max)))))))
                  (let ((error (should-error (pele-render source (list :now now :timeout 5000)) :type 'pele-error)))
                    (should (equal (gethash "code" reference) (plist-get (nth 2 error) :code))))))
              (cl-incf index))
            sources expected))))))
   (gethash "files" manifest)))

(provide 'pele-corpus-tests)
