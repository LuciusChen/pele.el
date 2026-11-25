;;; pele-package-tests.el --- Verify package-vc installation -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: MIT

(require 'ert)
(require 'cl-lib)

(defconst pele-package-test--root
  (file-name-directory
   (directory-file-name (file-name-directory (or load-file-name buffer-file-name)))))

(defun pele-package-test--emacs (script)
  "Run SCRIPT in a fresh Emacs, reporting installation errors."
  (with-temp-buffer
    (let ((status (call-process (expand-file-name invocation-name invocation-directory)
                                nil t nil "-Q" "--batch" "-l" script)))
      (unless (eq status 0)
        (ert-fail (list :exit status :output
                        (buffer-substring-no-properties
                         (point-min) (min (point-max) (+ (point-min) 2500)))))))))

(ert-deftest pele-package-vc-installs-and-activates-without-self-dependency ()
  (skip-unless (executable-find "git"))
  (let* ((root (make-temp-file "pele-package-vc-" t))
         (checkout (expand-file-name "source/" root))
         (user-dir (expand-file-name "user/" root))
         (install-script (expand-file-name "install.el" root))
         (startup-script (expand-file-name "startup.el" root))
         (settings `(setq user-emacs-directory ,user-dir
                          package-user-dir ,(expand-file-name "elpa/" user-dir)
                          package-directory-list nil package-archives nil
                          package-check-signature nil
                          package-native-compile nil package-quickstart nil
                          native-comp-jit-compilation nil max-lisp-eval-depth 800
                          custom-file ,(expand-file-name "custom.el" user-dir))))
    (unwind-protect
        (progn
          (make-directory checkout t)
          (make-directory user-dir t)
          (dolist (file (directory-files pele-package-test--root t "\\`[^.].*\\.el\\'"))
            (copy-file file (expand-file-name (file-name-nondirectory file) checkout)))
          (let ((default-directory checkout))
            (should (eq 0 (call-process "git" nil nil nil "init" "-q")))
            (should (eq 0 (call-process "git" nil nil nil "add" ".")))
            (should (eq 0 (call-process "git" nil nil nil
                                       "-c" "user.name=Pele Tests"
                                       "-c" "user.email=pele-tests@example.invalid"
                                       "-c" "commit.gpgsign=false"
                                       "-c" "core.hooksPath=/dev/null"
                                       "commit" "-qm" "Package fixture"))))
          (with-temp-file install-script
            (insert ";;; -*- lexical-binding: t; -*-\n")
            (prin1 settings (current-buffer))
            (insert "\n(require 'package-vc)\n")
            (prin1 `(package-vc-install '(pele :url ,checkout :vc-backend Git))
                   (current-buffer)))
          (with-temp-file startup-script
            (insert ";;; -*- lexical-binding: t; -*-\n")
            (prin1 settings (current-buffer))
            (insert "\n(require 'package)\n(package-initialize)\n"
                    "(let ((desc (cadr (assq 'pele package-alist))))\n"
                    "  (unless (and desc (assq 'emacs (package-desc-reqs desc))\n"
                    "               (not (assq 'pele (package-desc-reqs desc))))\n"
                    "    (error \"Invalid generated package requirements: %S\" desc)))\n"
                    "(unless (memq 'pele package-activated-list)\n"
                    "  (error \"Pele did not activate on startup\"))\n"
                    "(require 'pele)\n(require 'ob-pele)\n(require 'pele-markdown)\n"
                    "(when (featurep 'pele-native) (error \"Loaded native renderer during activation\"))\n"))
          (pele-package-test--emacs install-script)
          (pele-package-test--emacs startup-script))
      (delete-directory root t))))

(provide 'pele-package-tests)
;;; pele-package-tests.el ends here
