;;; pele-module.el --- Download native modules for Pele -*- lexical-binding: t; -*-

;; Copyright (C) 2026 pele.el contributors
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:
;; Download the release matching the installed Elisp, verify it, and keep it
;; outside the package manager's checkout.  Loading this file never downloads.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defvar pele-version)
(defvar pele--directory)
(defvar pele--loaded-module-file nil)
(defvar url-http-response-status)
(declare-function url-retrieve-synchronously "url" (url &optional silent inhibit-cookies timeout))

(defcustom pele-module-directory (locate-user-emacs-file "pele/modules/")
  "Directory for downloaded Pele modules, independent of package checkouts."
  :type 'directory :group 'pele)

(defcustom pele-module-auto-install 'ask
  "How to install a missing native module.
`ask' offers a download when preview/export commands or preview modes are
invoked interactively.  `download' downloads at the first render, including
previews enabled by hooks.  nil requires `pele-download-module' or a local
source build.  Loading or byte-compiling the package never downloads."
  :type '(choice (const :tag "Ask at interactive use" ask)
                 (const :tag "Download at first render" download)
                 (const :tag "Install manually" nil))
  :group 'pele)

(defun pele--module-platform ()
  "Return the release platform and architecture for this Emacs."
  (let ((os (pcase system-type ('darwin "macos") ('gnu/linux "linux")))
        (arch (pcase (car (split-string system-configuration "-"))
                ((or "aarch64" "arm64") "aarch64")
                ((or "x86_64" "amd64") "x86_64"))))
    (unless (and module-file-suffix os arch
                 (not (string-match-p "musl\\|android" system-configuration)))
      (user-error "No Pele prebuilt module for %s; build from source" system-configuration))
    (concat os "-" arch)))

(defun pele--module-host-version (program &rest arguments)
  "Return the version printed by PROGRAM with ARGUMENTS."
  (with-temp-buffer
    (let ((default-directory temporary-file-directory))
      (unless (and (executable-find program)
                   (eq 0 (apply #'process-file program nil t nil arguments))
                   (progn (goto-char (point-min))
                          (re-search-forward "[0-9]+\\.[0-9]+\\(?:\\.[0-9]+\\)?" nil t)))
        (user-error "Cannot determine host compatibility with %s" program)))
    (match-string 0)))

(defun pele--module-check-host ()
  "Check the supported operating system baseline before downloading."
  (let* ((mac (eq system-type 'darwin))
         (version (if mac (pele--module-host-version "sw_vers" "-productVersion")
                    (pele--module-host-version "getconf" "GNU_LIBC_VERSION")))
         (minimum (if mac "12.0" "2.35")))
    (when (version< version minimum)
      (user-error "Pele downloads require %s %s+; build from source on this system"
                  (if mac "macOS" "glibc") minimum))))

(defun pele--module-install-directory ()
  "Return the cache directory for this Elisp version and platform."
  (expand-file-name (concat pele-version "/" (pele--module-platform) "/")
                    pele-module-directory))

(defun pele--module-hash (file)
  "Return the SHA-256 of FILE without decoding binary bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun pele--module-safe-name-p (name)
  "Whether NAME is an ordinary relative archive path."
  (and (stringp name) (not (string-empty-p name))
       (not (file-name-absolute-p name))
       (not (string-match-p "[\\\\\n\r]" name))
       (not (member ".." (split-string name "/")))))

(defun pele--module-validate (directory)
  "Verify DIRECTORY's manifest and every listed file; return its module."
  (let* ((file (expand-file-name (concat "pele-native" module-file-suffix) directory))
         (manifest (with-temp-buffer
                     (insert-file-contents (expand-file-name "manifest.json" directory))
                     (json-parse-buffer :object-type 'hash-table)))
         (files (gethash "files" manifest))
         (platform (pele--module-platform)))
    (unless (and (equal pele-version (gethash "version" manifest))
                 (eql 1 (gethash "moduleABI" manifest))
                 (equal (if (eq system-type 'darwin) "darwin" "linux") (gethash "platform" manifest))
                 (equal (cadr (split-string platform "-")) (gethash "architecture" manifest))
                 (hash-table-p files) (gethash (file-name-nondirectory file) files))
      (error "Pele module does not match this package version or platform"))
    (maphash
     (lambda (name hash)
       (unless (and (pele--module-safe-name-p name)
                    (stringp hash) (string-match-p "\\`[[:xdigit:]]\\{64\\}\\'" hash)
                    (let ((path (expand-file-name name directory)))
                      (and (file-regular-p path) (not (file-symlink-p path))
                           (equal hash (pele--module-hash path)))))
         (error "Pele module file failed verification: %s" name)))
     files)
    file))

(defun pele--module-fetch (url file)
  "Download HTTPS URL into FILE, rejecting HTTP errors."
  (require 'url)
  (unless (string-prefix-p "https://" url) (error "Pele requires HTTPS downloads"))
  (let ((buffer (url-retrieve-synchronously url t t 60)))
    (unless (buffer-live-p buffer) (error "Could not download %s" url))
    (unwind-protect
        (with-current-buffer buffer
          (unless (eql url-http-response-status 200)
            (error "Pele download failed (HTTP %s): %s" url-http-response-status url))
          (when (> (buffer-size) (* 64 1024 1024)) (error "Pele download exceeds 64 MiB"))
          ;; url-http's header marker can precede the final newline.  Find
          ;; the complete separator so no HTTP bytes enter the archive.
          (goto-char (point-min))
          (unless (re-search-forward "\r?\n\r?\n" nil t)
            (error "Malformed HTTP response for the Pele module"))
          ;; The response is already compressed.  Do not let jka-compr (or
          ;; another filename handler) encode it again based on FILE's suffix.
          (let ((coding-system-for-write 'no-conversion)
                (file-name-handler-alist nil))
            (write-region (point) (point-max) file nil 'silent)))
      (kill-buffer buffer))))

(defun pele--module-unpack (archive directory)
  "Check ARCHIVE's paths and entry types, then extract it into DIRECTORY."
  (let ((default-directory temporary-file-directory))
    (unless (executable-find "tar") (user-error "Installing Pele downloads requires tar"))
    (dolist (verbose '(nil t))
      (with-temp-buffer
	(unless (eq 0 (process-file "tar" nil t nil (if verbose "-tvzf" "-tzf") archive))
          (error "Could not read the Pele module archive"))
	(let ((entries (split-string (buffer-string) "\n" t)))
          (unless (and entries (< (length entries) 2000)
                       (cl-every (if verbose (lambda (line) (memq (aref line 0) '(?- ?d)))
                                   #'pele--module-safe-name-p)
				 entries))
            (error "Unsafe path or link in Pele module archive")))))
    (unless (eq 0 (process-file "tar" nil nil nil "-xzf" archive "-C" directory))
      (error "Could not extract the Pele module archive"))))

(defun pele--module-install (staging directory)
  "Move verified STAGING into DIRECTORY, preserving the old copy on failure."
  (let ((backup (when (file-exists-p directory)
                  (make-temp-file (expand-file-name ".pele-old-" (file-name-directory (directory-file-name directory))) t))))
    (when backup
      (delete-directory backup)
      (rename-file (directory-file-name directory) backup))
    (condition-case err
        (rename-file staging (directory-file-name directory))
      (error
       (when backup (rename-file backup (directory-file-name directory)))
       (signal (car err) (cdr err))))
    (when backup (delete-directory backup t))))

;;;###autoload
(defun pele-download-module (&optional force)
  "Install the prebuilt module matching this package's exact release.
Verify the archive checksum, manifest, platform and file hashes before
installing.  With prefix FORCE, replace an existing download.  A loaded
module cannot be replaced; restart Emacs first.  Return the module path."
  (interactive "P")
  (require 'pele)
  (let* ((platform (pele--module-platform))
         (directory (pele--module-install-directory))
         (existing (and (not force) (ignore-errors (pele--module-validate directory)))))
    (pele--module-check-host)
    (if existing
        (progn (message "Pele module %s is already installed" pele-version) existing)
      (when (and (file-exists-p directory) (featurep 'pele-native)
                 (or (null pele--loaded-module-file)
                     (file-in-directory-p pele--loaded-module-file directory)))
        (user-error "Restart Emacs before replacing the loaded Pele module"))
      (let* ((parent (file-name-directory (directory-file-name directory)))
             (asset (format "pele-native-%s-%s.tar.gz" pele-version platform))
             (url (format "https://github.com/LuciusChen/pele.el/releases/download/v%s/%s" pele-version asset))
             temporary staging)
        (make-directory parent t)
        (setq temporary (make-temp-file (expand-file-name ".pele-download-" parent) t)
              staging (expand-file-name "module" temporary))
        (unwind-protect
            (let ((archive (expand-file-name asset temporary))
                  (checksum (expand-file-name "checksum" temporary)))
              (message "Downloading Pele %s for %s…" pele-version platform)
              (pele--module-fetch (concat url ".sha256") checksum)
              (pele--module-fetch url archive)
              (let ((expected (with-temp-buffer
                                (insert-file-contents checksum)
                                (car (split-string (buffer-string))))))
                (unless (and expected (string-match-p "\\`[[:xdigit:]]\\{64\\}\\'" expected)
                             (equal expected (pele--module-hash archive)))
                  (error "Pele archive checksum does not match")))
              (make-directory staging)
              (pele--module-unpack archive staging)
              (pele--module-validate staging)
              (pele--module-install staging directory)
              (message "Installed Pele %s module%s" pele-version
                       (if (featurep 'pele-native) "; restart Emacs to use it" ""))
              (expand-file-name (concat "pele-native" module-file-suffix) directory))
          (delete-directory temporary t))))))

(defun pele--module-file (&optional prompt)
  "Find a local or downloaded module; optionally PROMPT at interactive use."
  (let ((local (expand-file-name (concat "pele-native" module-file-suffix) pele--directory)))
    (or (and (file-exists-p local) local)
        (condition-case nil
            (let ((directory (pele--module-install-directory)))
              (when (file-exists-p directory)
                (pele--module-check-host)
                (pele--module-validate directory)))
          (error nil))
        (when (or (eq pele-module-auto-install 'download)
                  (and prompt (not noninteractive) (eq pele-module-auto-install 'ask)
                       (yes-or-no-p (format "Download the Pele %s native module from GitHub? " pele-version))))
          (pele-download-module))
        (user-error "Install the renderer with M-x pele-download-module, or run make in %s" pele--directory))))

(provide 'pele-module)
;;; pele-module.el ends here
