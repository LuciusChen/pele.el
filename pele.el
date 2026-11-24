;;; pele.el --- Mermaid SVG previews using upstream Pele -*- lexical-binding: t; -*-

;; Copyright (C) 2026 pele.el contributors
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/LuciusChen/pele.el
;; Keywords: multimedia, tools, outlines
;; SPDX-License-Identifier: MIT

;;; Commentary:
;; Render Mermaid with the unmodified Pele engine, embedded in a native module.
;; A persistent worker owns the JavaScript runtime; it never calls Emacs APIs.
;; `pele-preview' previews a region, a Mermaid code block, or the whole buffer.
;; `pele-org-mode' adds live previews below Mermaid source blocks.
;; Download the module with `pele-download-module', or build it with `make'.
;; Rendering needs no Node.js, browser, network connection or external process.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'pele-mode)

(declare-function pele--native-submit "pele-native" (id source options timeout))
(declare-function pele--native-poll "pele-native" ())
(declare-function pele--native-cancel "pele-native" (id))
(declare-function pele--native-shutdown "pele-native" ())
(declare-function pele--native-channel "pele-native" (process))
(declare-function org-element-context "org-element" (&optional element))
(declare-function org-element-lineage "org-element" (datum types &optional with-self))
(declare-function org-element-property "org-element" (property element))
(declare-function org-element-parse-buffer "org-element" (&optional granularity visible-only))
(declare-function org-element-map "org-element" (data types fun &optional info first-match no-recursion with-affiliated))
(declare-function org-babel-where-is-src-block-result "ob-core" (&optional insert info hash))
(declare-function org-babel-result-end "ob-core" ())
(declare-function image-mode "image-mode" ())
(declare-function evil-emacs-state "evil-states" (&optional arg))
(defvar image-auto-resize)
(defvar mwheel-scroll-up-function)

(defgroup pele nil "Mermaid SVG previews with Pele." :group 'multimedia)

(require 'pele-module)

(defcustom pele-font-family
  (if (eq system-type 'darwin) "Helvetica Neue, Arial, sans-serif"
    "Inter, Noto Sans, DejaVu Sans, sans-serif")
  "Font family used to measure and draw SVG labels."
  :type 'string)

(defcustom pele-font-family-mono
  (if (eq system-type 'darwin) "Menlo, monospace" "DejaVu Sans Mono, monospace")
  "Font family used for monospace labels."
  :type 'string)

(defcustom pele-text-measurement 'native
  "Measure label widths with the SVG font backend when available.
`native' uses Core Text on macOS or Pango when built in on Linux,
falling back to Pele's estimates when no font backend is available.
`estimate' uses the upstream built-in width table for reproducibility."
  :type '(choice (const native) (const estimate)))

(defcustom pele-font-size 16
  "Base SVG label size in pixels."
  :type 'integer)

(defcustom pele-render-timeout 1000
  "Maximum time in milliseconds for one rendering, excluding engine startup."
  :type 'integer)

(defcustom pele-preview-delay 0.2
  "Idle seconds before refreshing Mermaid previews after an edit."
  :type 'number)

(defcustom pele-cache-size 32
  "Maximum number of successful renderings to cache."
  :type 'integer)

(defcustom pele-cache-byte-limit (* 16 1024 1024)
  "Maximum total SVG bytes retained in the rendering cache."
  :type 'integer)

(defcustom pele-theme 'auto
  "SVG theme: `pele', `auto', `light', `dark', or CSS variables.
`pele' follows the editor's light/dark appearance with Pele's official
Flexoki colors.  `auto' uses the editor's actual background and foreground.
An alist uses string keys such as \"--pele-bg\" and CSS color values."
  :type '(choice (const pele) (const auto) (const light) (const dark)
                 (alist :key-type string :value-type string)))

(defcustom pele-background 'transparent
  "Canvas background for diagrams.
`transparent' lets the Emacs buffer show through.  Node fills remain intact.
`theme' fills the canvas with the selected theme's background color."
  :type '(choice (const transparent) (const theme)))

(defconst pele-version "0.0.1")
(defconst pele-engine-version "1.13.0")
(defconst pele--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory)))

(define-error 'pele-error "Pele could not render the diagram")
(cl-defstruct (pele--request (:constructor pele--make-request))
  callback cache-key state fixed-time)
(defvar pele--next-id 0)
(defvar pele--pending (make-hash-table :test #'eql))
(defvar pele--ready nil)
(defvar pele--waiting nil)
(defvar pele--in-flight 0)
(defvar pele--channel nil)
(defvar pele--poll-timer nil)
(defvar pele--delivery-timer nil)
(defvar pele--cache (make-hash-table :test #'equal))
(defvar pele--cache-order nil)
(defvar pele--cache-bytes 0)

(defun pele--ensure-module (&optional prompt)
  "Load the native renderer; allow a download PROMPT at interactive use."
  (unless (featurep 'pele-native)
    (unless module-file-suffix
      (user-error "This Emacs was built without dynamic module support"))
    (let ((file (pele--module-file prompt)))
      (load file nil t t)
      (setq pele--loaded-module-file file)))
  (unless (process-live-p pele--channel)
    (setq pele--channel
          (make-pipe-process :name "pele-completions" :noquery t :coding 'no-conversion
                             :filter (lambda (_process _text) (pele--drain))))
    (pele--native-channel pele--channel)))

(defun pele--color (name fallback)
  "Resolve color NAME to hexadecimal, or return FALLBACK."
  (let ((rgb (and (stringp name) (ignore-errors (color-name-to-rgb name)))))
    (if rgb (apply #'color-rgb-to-hex (append rgb '(2))) fallback)))

;; Upstream website/src/styles/pele-theme.scss, MIT, kepano / Obsidian.
(defconst pele--light-colors
  '(("--pele-bg" . "#fffcf0") ("--pele-fg" . "#100f0f")
    ("--pele-muted" . "#6f6e69") ("--pele-line" . "#100f0f")
    ("--pele-surface" . "#f2f0e5") ("--pele-surface-alt" . "#e6e4d9")
    ("--pele-border" . "#cecdc3") ("--pele-accent" . "#205ea6")
    ("--pele-critical" . "#af3029") ("--pele-radius" . "6px")
    ("--pele-series-1" . "#af3029") ("--pele-series-2" . "#bc5215")
    ("--pele-series-3" . "#ad8301") ("--pele-series-4" . "#66800b")
    ("--pele-series-5" . "#24837b") ("--pele-series-6" . "#205ea6")
    ("--pele-series-7" . "#5e409d") ("--pele-series-8" . "#a02f6f")))

(defconst pele--dark-colors
  '(("--pele-bg" . "#100f0f") ("--pele-fg" . "#cecdc3")
    ("--pele-muted" . "#878580") ("--pele-line" . "#cecdc3")
    ("--pele-surface" . "#1c1b1a") ("--pele-surface-alt" . "#282726")
    ("--pele-border" . "#403e3c") ("--pele-accent" . "#4385be")
    ("--pele-critical" . "#d14d41") ("--pele-radius" . "6px")
    ("--pele-series-1" . "#d14d41") ("--pele-series-2" . "#da702c")
    ("--pele-series-3" . "#d0a215") ("--pele-series-4" . "#879a39")
    ("--pele-series-5" . "#3aa99f") ("--pele-series-6" . "#4385be")
    ("--pele-series-7" . "#8b7ec8") ("--pele-series-8" . "#ce5d97")))

(defun pele--theme (theme)
  "Return the concrete color variables for THEME."
  (if (listp theme)
      (progn
        (dolist (entry theme)
          (unless (and (stringp (car entry))
                       (string-match-p "\\`--pele-[[:alnum:]-]+\\'" (car entry))
                       (stringp (cdr entry))
                       (not (string-match-p "[;{}<>]" (cdr entry))))
            (error "Invalid Pele theme entry: %S" entry)))
        theme)
    (let* ((background (pele--color (face-background 'default nil t) "#ffffff"))
           (foreground (pele--color (face-foreground 'default nil t) "#100f0f"))
           (dark (if (memq theme '(light dark)) (eq theme 'dark)
                   (< (apply #'+ (color-name-to-rgb background)) 1.5)))
           (colors (copy-tree (if dark pele--dark-colors pele--light-colors))))
      (when (eq theme 'auto)
        (setcdr (assoc "--pele-bg" colors) background)
        (setcdr (assoc "--pele-fg" colors) foreground)
        (setcdr (assoc "--pele-line" colors) foreground))
      colors)))

(defun pele--options-json (options)
  "Validate OPTIONS and encode the supported render settings."
  (let ((size (or (plist-get options :font-size) pele-font-size))
        (family (or (plist-get options :font-family) pele-font-family))
        (mono (or (plist-get options :font-family-mono) pele-font-family-mono))
        (measurement (or (plist-get options :measure-text) pele-text-measurement))
        (background (or (plist-get options :background) pele-background))
        (now (plist-get options :now))
        (width (plist-get options :max-width))
        (theme (if (plist-member options :theme) (plist-get options :theme) pele-theme)))
    (unless (and (numberp size) (> size 0) (<= size 200))
      (error "Pele font size must be between 0 and 200"))
    (unless (stringp family) (error "Pele font family must be a string"))
    (unless (stringp mono) (error "Pele monospace font family must be a string"))
    (unless (memq measurement '(native estimate))
      (error "Unknown Pele text measurement: %S" measurement))
    (unless (memq background '(transparent theme))
      (error "Unknown Pele canvas background: %S" background))
    (unless (or (null now) (numberp now))
      (error "Pele reference time must be epoch milliseconds"))
    (unless (or (null width) (and (numberp width) (> width 0)))
      (error "Pele width must be a positive number"))
    (unless (or (memq theme '(pele auto light dark)) (listp theme))
      (error "Unknown Pele theme: %S" theme))
    (json-serialize
     (append `((fontSize . ,size) (fontFamily . ,family)
               (fontFamilyMono . ,mono)
               (measureText . ,(if (eq measurement 'native) t :false))
               (transparentBackground . ,(if (eq background 'transparent) t :false))
               (autoDirection . ,(if (plist-get options :auto-direction) t :false))
               (theme . ,(let ((table (make-hash-table :test #'equal)))
                           (dolist (entry (pele--theme theme))
                             (puthash (car entry) (cdr entry) table))
                           table)))
             (and width `((maxWidth . ,width)))
             (and now `((now . ,now)))
             (and (plist-get options :config) `((config . ,(plist-get options :config)))))
     :false-object :false)))

;;;###autoload
(defun pele-clear-cache ()
  "Discard cached diagrams."
  (interactive)
  (clrhash pele--cache)
  (setq pele--cache-order nil pele--cache-bytes 0))

(defun pele--cache-get (key)
  "Return the cached result for KEY and mark it as recently used."
  (when-let* ((result (gethash key pele--cache)))
    (setq pele--cache-order (cons key (delete key pele--cache-order)))
    result))

(defun pele--cache-put (key result)
  "Cache successful RESULT under KEY within the configured bounds."
  (let ((size (string-bytes (plist-get result :svg))))
    (when (and (> pele-cache-size 0) (<= size pele-cache-byte-limit))
      (when-let* ((old (gethash key pele--cache)))
        (cl-decf pele--cache-bytes (string-bytes (plist-get old :svg))))
      (puthash key result pele--cache)
      (cl-incf pele--cache-bytes size)
      (setq pele--cache-order (cons key (delete key pele--cache-order)))
      (while (or (> (hash-table-count pele--cache) pele-cache-size)
                 (> pele--cache-bytes pele-cache-byte-limit))
        (let* ((last (car (last pele--cache-order))) (old (gethash last pele--cache)))
          (cl-decf pele--cache-bytes (string-bytes (plist-get old :svg)))
          (remhash last pele--cache)
          (setq pele--cache-order (butlast pele--cache-order)))))))

(defun pele--deliver (id result)
  "Deliver RESULT to pending request ID exactly once."
  (when-let* ((request (gethash id pele--pending)))
    (remhash id pele--pending)
    (when (pele--request-callback request)
      ;; Use the engine's detected type, including frontmatter and CRLF input.
      ;; Gantt's implicit current time must never become a stale cached image.
      (when (and (pele--request-cache-key request) (plist-get result :ok)
                 (or (pele--request-fixed-time request)
                     (not (equal (plist-get result :type) "gantt"))))
        (pele--cache-put (pele--request-cache-key request) result))
      (condition-case error
          (funcall (pele--request-callback request) result)
        (error (message "Pele callback: %s" (error-message-string error)))))))

(defun pele--dispatch ()
  "Feed a bounded number of requests to the worker."
  (while (and pele--waiting (< pele--in-flight 8))
    (let* ((job (pop pele--waiting))
           (id (car job))
           (request (gethash id pele--pending)))
      (when request
        (if (null (pele--request-callback request)) (remhash id pele--pending)
          (condition-case error
              (progn
                (apply #'pele--native-submit job)
                (setf (pele--request-state request) 'native)
                (cl-incf pele--in-flight))
            (error
             (push (cons id (list :ok nil :error
                                 (list :code "engine" :message (error-message-string error))))
                   pele--ready))))))))

(defun pele--stop-timers ()
  "Cancel the request polling and ready-result delivery timers."
  (when pele--poll-timer (cancel-timer pele--poll-timer))
  (when pele--delivery-timer (cancel-timer pele--delivery-timer))
  (setq pele--poll-timer nil pele--delivery-timer nil))

(defun pele--drain ()
  "Collect completed renderings without waiting for the worker."
  (pele--dispatch)
  (let ((ready (prog1 (nreverse pele--ready) (setq pele--ready nil)))
        (remaining 32))
    (dolist (entry ready) (pele--deliver (car entry) (cdr entry)))
    (when (featurep 'pele-native)
      (let (entry)
        (while (and (> remaining 0) (setq entry (pele--native-poll)))
          (cl-decf remaining)
          (when-let* ((request (gethash (car entry) pele--pending)))
            (when (eq (pele--request-state request) 'native) (cl-decf pele--in-flight)))
          (pele--deliver (car entry)
                         (json-parse-string (cadr entry) :object-type 'plist
                                            :array-type 'list :false-object nil :null-object nil))))))
  (pele--dispatch)
  (when (= 0 (hash-table-count pele--pending)) (pele--stop-timers)))

;;;###autoload
(defun pele-render-async (source callback &optional options)
  "Render Mermaid SOURCE, then call CALLBACK with a result plist.
Return a request id accepted by `pele-cancel'.  CALLBACK runs in Emacs,
never the worker thread.  Success has :ok t, :svg, :width, :height and :type.
Failure has :ok nil and :error with :code, :message and source positions.
OPTIONS is a plist accepting :font-size, :font-family, :font-family-mono,
:measure-text (`native' or `estimate'), :background (`transparent' or
`theme'), :max-width, :theme,
:auto-direction, :timeout, :now (epoch milliseconds), and :config (a JSON
object represented as an alist or hash table).  The renderer is offline."
  (unless (stringp source) (signal 'wrong-type-argument (list 'stringp source)))
  (unless (functionp callback) (signal 'wrong-type-argument (list 'functionp callback)))
  (let* ((json (pele--options-json options))
         (timeout (or (plist-get options :timeout) pele-render-timeout))
         (key (secure-hash 'sha256 (concat pele-engine-version "\0" json "\0" source)))
         (cached (pele--cache-get key))
         (id (cl-incf pele--next-id)))
    (unless (and (integerp timeout) (<= 1 timeout 60000))
      (error "Pele timeout must be an integer from 1 to 60000 milliseconds"))
    (puthash id (pele--make-request :callback callback :cache-key key
                                   :state (if cached 'cache 'waiting)
                                   :fixed-time (and (plist-get options :now) t))
             pele--pending)
    (condition-case error
        (if cached (push (cons id cached) pele--ready)
          (pele--ensure-module)
          (setq pele--waiting (nconc pele--waiting (list (list id source json timeout))))
          (pele--dispatch))
      (error (remhash id pele--pending) (signal (car error) (cdr error))))
    ;; Cached results are already ready.  Deliver on the next event-loop turn
    ;; instead of waiting for a native-worker polling interval.
    (when (and pele--ready (not pele--delivery-timer))
      (setq pele--delivery-timer
            (run-at-time 0 nil (lambda ()
                                (setq pele--delivery-timer nil)
                                (pele--drain)))))
    (unless (or cached pele--poll-timer)
      (setq pele--poll-timer (run-at-time 0.01 0.02 #'pele--drain)))
    id))

;;;###autoload
(defun pele-cancel (id)
  "Cancel request ID.  Its callback will not be called."
  (when-let* ((request (gethash id pele--pending)))
    (setf (pele--request-callback request) nil)
    (when (and (eq (pele--request-state request) 'native) (featurep 'pele-native))
      (pele--native-cancel id))))

;;;###autoload
(defun pele-render (source &optional options)
  "Render Mermaid SOURCE synchronously and return its result plist.
OPTIONS are as for `pele-render-async'.  Signal `pele-error' on failure.
Interactive previews use the asynchronous API instead."
  (let (result done id)
    (unwind-protect
        (progn
          (setq id (pele-render-async source (lambda (value) (setq result value done t)) options))
          (while (not done)
            (pele--drain)
            (unless done
              (unless (gethash id pele--pending)
                (signal 'pele-error '("Rendering was cancelled" (:code "cancelled"))))
              (accept-process-output pele--channel 0.01)))
          (unless (plist-get result :ok)
            (signal 'pele-error (list (plist-get (plist-get result :error) :message)
                                      (plist-get result :error))))
          result)
      (unless done (when id (pele-cancel id))))))

;;;###autoload
(defun pele-shutdown ()
  "Cancel pending requests and release the native JavaScript runtime."
  (interactive)
  (pele--stop-timers)
  (setq pele--ready nil pele--waiting nil pele--in-flight 0)
  (clrhash pele--pending)
  (when (featurep 'pele-native) (pele--native-shutdown))
  (when (process-live-p pele--channel) (delete-process pele--channel))
  (setq pele--channel nil))

(add-hook 'kill-emacs-hook #'pele-shutdown)

(defun pele--language-p (language)
  "Return non-nil when source LANGUAGE is handled by Pele."
  (member (downcase (or language "")) '("mermaid" "pele")))

(defun pele--source-at-point ()
  "Return the active region, current Mermaid code block, or buffer contents."
  (cond ((use-region-p) (buffer-substring-no-properties (region-beginning) (region-end)))
        ((derived-mode-p 'org-mode)
         (require 'org-element)
         (let ((block (org-element-lineage (org-element-context) '(src-block) t)))
           (unless (and block (pele--language-p (org-element-property :language block)))
             (user-error "Point is not in a Mermaid source block"))
           (org-element-property :value block)))
        ((derived-mode-p 'markdown-mode 'markdown-ts-mode)
         (or (pele-markdown--source-at-point)
             (user-error "Point is not in a Mermaid code block")))
        (t (buffer-substring-no-properties (point-min) (point-max)))))

(defun pele--window-width ()
  "Return the pixel width available for a diagram."
  (max 1 (- (apply #'min (mapcar (lambda (window) (window-body-width window t))
                                (or (get-buffer-window-list nil nil t)
                                    (list (selected-window))))) 16)))

(defun pele--window-height ()
  "Return the pixel height available for an inline diagram.
Leave room for its surrounding newlines and the cursor below it."
  (max 1 (- (apply #'min (mapcar (lambda (window) (window-body-height window t))
                                (or (get-buffer-window-list nil nil t)
                                    (list (selected-window)))))
            (* 3 (default-line-height)))))

(defun pele--image (result &optional width height)
  "Create an image for RESULT that fits WIDTH and HEIGHT, in pixels.
Default to the available window size.  Preserve aspect ratio; never enlarge."
  (unless (image-type-available-p 'svg) (user-error "This Emacs has no SVG image support"))
  (let* ((natural-width (plist-get result :width))
         (scale (min 1.0 (/ (float (or width (pele--window-width))) natural-width)
                     (/ (float (or height (pele--window-height)))
                        (plist-get result :height)))))
    (create-image (plist-get result :svg) 'svg t
                  :width (max 1 (floor (* natural-width scale))) :scale 1.0)))

(defun pele--view-image (result)
  "Open RESULT at its original size using Emacs's image viewer."
  (require 'image-mode)
  (let ((buffer (get-buffer-create "*Pele Image*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (fundamental-mode)
        (buffer-disable-undo)
        (erase-buffer)
        (insert (plist-get result :svg))
        (let ((image-auto-resize nil)) (image-mode))
        (when (bound-and-true-p evil-local-mode) (evil-emacs-state))
        (setq buffer-read-only t)
        (set-buffer-modified-p nil)))
    (pop-to-buffer buffer '((display-buffer-same-window)))))

(defvar pele-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'pele-preview-refresh)
    (define-key map (kbd "s") #'pele-preview-save)
    (define-key map (kbd "RET") #'pele-preview-open)
    map))

(defvar-local pele--preview-source nil)
(defvar-local pele--preview-result nil)
(defvar-local pele--preview-request nil)

(defun pele--preview-cleanup ()
  "Cancel the rendering owned by the current preview buffer."
  (when pele--preview-request (pele-cancel pele--preview-request))
  (setq pele--preview-request nil))

(define-derived-mode pele-preview-mode special-mode "Pele"
  "View a Mermaid diagram.  Use g to refresh, s to save SVG, q to quit."
  (add-hook 'kill-buffer-hook #'pele--preview-cleanup nil t)
  (add-hook 'change-major-mode-hook #'pele--preview-cleanup nil t))

(defun pele-preview-refresh ()
  "Render the source associated with the current preview buffer again."
  (interactive)
  (unless pele--preview-source (user-error "This buffer has no diagram source"))
  (when (called-interactively-p 'interactive) (pele--ensure-module t))
  (pele--preview-cleanup)
  (let ((buffer (current-buffer)) (width (pele--window-width)))
    (setq pele--preview-request
          (pele-render-async
           pele--preview-source
           (lambda (result)
             (when (and (buffer-live-p buffer)
                        (with-current-buffer buffer (derived-mode-p 'pele-preview-mode)))
               (with-current-buffer buffer
                 (setq pele--preview-request nil)
                 (if (plist-get result :ok)
                     (progn
                       (setq pele--preview-result result header-line-format nil)
                       (pele--preview-display))
                   (setq header-line-format
                         (concat " " (plist-get (plist-get result :error) :message)))))))
           (list :max-width width)))))

(defun pele--preview-display ()
  "Fit the standalone preview's cached image to its window."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert-image (pele--image pele--preview-result))
    (goto-char (point-min))))

(defun pele-preview-save (file)
  "Save the displayed SVG to FILE."
  (interactive (list (read-file-name "Save SVG: " nil nil nil "diagram.svg")))
  (unless pele--preview-result (user-error "No successful rendering to save"))
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file file (insert (plist-get pele--preview-result :svg))))
  (message "Saved %s" file))

(defun pele-preview-open ()
  "Open the displayed diagram at its original size."
  (interactive)
  (unless pele--preview-result (user-error "No successful rendering to open"))
  (pele--view-image pele--preview-result))

;;;###autoload
(defun pele-preview ()
  "Preview the region, current Mermaid code block, or Mermaid buffer."
  (interactive)
  (let ((source (pele--source-at-point)))
    (when (called-interactively-p 'interactive) (pele--ensure-module t))
    (pop-to-buffer (get-buffer-create "*Pele Preview*"))
    (unless (derived-mode-p 'pele-preview-mode) (pele-preview-mode))
    (setq pele--preview-source source header-line-format " Rendering diagram…")
    (pele-preview-refresh)))

;;;###autoload
(defun pele-export (file)
  "Render the current diagram and write SVG to FILE."
  (interactive (list (read-file-name "Export SVG: " nil nil nil "diagram.svg")))
  (when (called-interactively-p 'interactive) (pele--ensure-module t))
  (let ((result (pele-render (pele--source-at-point)))
        (coding-system-for-write 'utf-8-unix))
    (with-temp-file file (insert (plist-get result :svg))))
  (message "Saved %s" file))

(defvar-local pele--inline-overlays nil)
(defvar-local pele--inline-timer nil)
(defvar-local pele--inline-blocks-function nil)
(defvar-local pele--inline-focus nil)
(defvar-local pele--inline-below nil)
(defvar-local pele--inline-focus-exit nil)
(defvar-local pele--inline-wheel nil)
(defvar pele--inline-moving nil)

(defconst pele--inline-motions
  '((next-line 1) (previous-line -1)
    (meow-next 1 meow) (meow-prev -1 meow)
    (evil-next-line 1 evil) (evil-previous-line -1 evil)
    (evil-next-visual-line 1 evil) (evil-previous-visual-line -1 evil))
  "Motion commands with their direction and optional providing feature.")

(defvar pele--inline-focus-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'pele-inline-open)
    map))

(defvar pele--inline-image-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'pele-inline-open)
    map))

(defun pele--inline-display (overlay)
  "Display OVERLAY's cached result at the current window size."
  (when-let* ((result (overlay-get overlay 'pele-result)))
    (let ((size (cons (pele--window-width) (pele--window-height))))
      (unless (equal size (overlay-get overlay 'pele-size))
        (overlay-put overlay 'pele-image (pele--image result (car size) (cdr size)))
        (overlay-put overlay 'pele-size size)))
    (let* ((focused (eq overlay pele--inline-focus))
           (image (overlay-get overlay 'pele-image))
           (text (concat "\n" (propertize " " 'display image 'cursor focused
                                        'keymap pele--inline-image-map 'pele-overlay overlay)
                         "\n"
                         (propertize " " 'display '(space :width 0) 'cursor
                                     (and (not focused)
                                          (or (eq overlay pele--inline-below)
                                              (eq (char-before (overlay-start overlay)) ?\n)))))))
      ;; A virtual cursor below the image keeps normal insertion below it.
      ;; Focus moves it onto the image without adding any buffer characters.
      (overlay-put overlay 'after-string
                   (propertize text 'line-prefix "" 'wrap-prefix "")))))

(defun pele--inline-unfocus ()
  "Leave the focused preview and remove its temporary keymap."
  (when pele--inline-focus-exit
    (let ((exit pele--inline-focus-exit))
      (setq pele--inline-focus-exit nil)
      (funcall exit))))

(defun pele--inline-focus (overlay)
  "Put the keyboard cursor on OVERLAY's image."
  (pele--inline-unfocus)
  (setq pele--inline-focus overlay pele--inline-below nil)
  (goto-char (overlay-start overlay))
  (pele--inline-display overlay)
  (set-window-vscroll nil 0 t)
  (set-window-start nil (save-excursion
                         (if (bolp) (forward-line -1) (beginning-of-line))
                         (point)))
  (let ((buffer (current-buffer)) (window (selected-window)))
    (setq pele--inline-focus-exit
          (set-transient-map
           pele--inline-focus-map
           (lambda ()
             (and (eq buffer (current-buffer)) (eq window (selected-window))
                  (eq overlay pele--inline-focus)
                  (or (assq this-command pele--inline-motions)
                      (eq this-command 'pele-inline-open))))
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq pele--inline-focus nil pele--inline-focus-exit nil
                       pele--inline-below overlay)
                 (when (overlay-buffer overlay) (pele--inline-display overlay)))))))))

(defun pele--inline-leave (direction)
  "Leave the focused preview in DIRECTION."
  (let ((overlay pele--inline-focus))
    (goto-char (overlay-start overlay))
    (pele--inline-unfocus)
    (when (< direction 0)
      (setq pele--inline-below nil)
      (pele--inline-display overlay)
      (when (bolp) (forward-line -1))
      (end-of-line))))

(defun pele-inline-open (&optional event)
  "Open the focused or clicked preview at its original size."
  (interactive (list (when (mouse-event-p last-input-event) last-input-event)))
  (let* ((position (and event (event-start event)))
         (string (and position (posn-string position)))
         (overlay (if string (get-text-property (cdr string) 'pele-overlay (car string))
                    pele--inline-focus))
         (result (and overlay (overlay-get overlay 'pele-result))))
    (unless result (user-error "No preview selected"))
    (when position (select-window (posn-window position)))
    (pele--inline-unfocus)
    (pele--view-image result)))

(defun pele--inline-eof-preview ()
  "Return a preview with an image at the accessible end of the buffer."
  (seq-find (lambda (overlay)
              (and (= (overlay-start overlay) (point-max))
                   (overlay-get overlay 'pele-result)))
            pele--inline-overlays))

(defun pele--inline-move (direction original &rest args)
  "Call ORIGINAL with ARGS, handling single-step preview motion in DIRECTION.
Modal commands may call native motions themselves.  Handle only the outer
motion, and leave counts, selections, operators and programmatic calls alone."
  (if (or (not pele--inline-blocks-function) pele--inline-moving
          ;; Modal commands can rewrite `this-command' during their motion.
          (not (assq real-this-command pele--inline-motions))
          (not (memq (car args) '(nil 1))) (region-active-p)
          (memq (bound-and-true-p evil-state) '(visual operator)))
      (apply original args)
    (let* ((pele--inline-moving t)
           (before (point)) (below pele--inline-below)
           (eof (and (> direction 0) (= (line-end-position) (point-max))
                     (not (eq (char-before (point-max)) ?\n))
                     (pele--inline-eof-preview))))
      (cond
       (pele--inline-focus (pele--inline-leave direction))
       ((and eof (not (eq eof below))) (pele--inline-focus eof))
       (t
        (prog1 (apply original args)
          (when-let* ((overlay
                       (seq-find
                        (lambda (overlay)
                          (let ((end (overlay-start overlay)))
                            (and (overlay-get overlay 'pele-result)
                                 (if (> direction 0)
                                     (and (< before end) (>= (point) end))
                                   (or (and (> before end) (< (point) end))
                                       (and (= before end) (<= (point) end)
                                            (or (eq below overlay)
                                                (eq (char-before end) ?\n))))))))
                        pele--inline-overlays)))
            (pele--inline-focus overlay))))))))

(defun pele--inline-advise-motions (&optional feature)
  "Route FEATURE's commands through the shared preview motion handler."
  (dolist (motion pele--inline-motions)
    (when (eq (nth 2 motion) feature)
      (advice-add (car motion) :around
                  (apply-partially #'pele--inline-move (cadr motion))
                  '((name . pele-inline-motion))))))

(defun pele--inline-evil-cursor (original &rest args)
  "Keep Evil's cursor adjustment from leaving a virtual preview position."
  (unless (and (memq (bound-and-true-p evil-state) '(normal motion))
               (let ((overlay (or pele--inline-focus pele--inline-below)))
                 (and overlay (= (point) (overlay-start overlay)))))
    (apply original args)))

(pele--inline-advise-motions)
(with-eval-after-load 'meow
  (when (fboundp 'pele--inline-advise-motions)
    (pele--inline-advise-motions 'meow)))
(with-eval-after-load 'evil
  (when (fboundp 'pele--inline-advise-motions)
    (pele--inline-advise-motions 'evil)
    (advice-add 'evil-adjust-cursor :around #'pele--inline-evil-cursor
                '((name . pele-inline-cursor)))))

(defun pele--inline-scroll-up (&rest args)
  "Scroll normally, ending mwheel's retry loop when the window cannot advance."
  (condition-case nil
      (let ((start (window-start)) (vscroll (window-vscroll nil t)))
        (prog1 (apply (cdr pele--inline-wheel) args)
          ;; Emacs can return successfully without moving at an EOF after-string.
          ;; mwheel otherwise retries that same state indefinitely.
          (when (and (= start (window-start)) (= vscroll (window-vscroll nil t)))
            (signal 'end-of-buffer nil))))
    (end-of-buffer
     (when-let* ((overlay (pele--inline-eof-preview)))
       (setq pele--inline-below overlay)
       (goto-char (overlay-start overlay))
       (pele--inline-display overlay)
       (set-window-vscroll nil 0 t)
       (set-window-start nil (point)))
     (signal 'end-of-buffer nil))))

(defun pele--inline-after-command ()
  "Discard a virtual below-image cursor after point leaves its anchor."
  (when (and pele--inline-below (/= (point) (overlay-start pele--inline-below)))
    (let ((overlay pele--inline-below))
      (setq pele--inline-below nil)
      (pele--inline-display overlay))))

(defun pele--inline-delete (overlay)
  "Remove OVERLAY and cancel its pending rendering."
  (when (eq overlay pele--inline-focus) (pele--inline-unfocus))
  (when (eq overlay pele--inline-below) (setq pele--inline-below nil))
  (when-let* ((id (overlay-get overlay 'pele-request))) (pele-cancel id))
  (when-let* ((marker (overlay-get overlay 'pele-begin))) (set-marker marker nil))
  (delete-overlay overlay))

(defun pele--inline-update (overlay source options)
  "Update OVERLAY for SOURCE and render OPTIONS."
  (let ((key (concat source "\0" (pele--options-json options)))
        (buffer (current-buffer)))
    (unless (equal key (overlay-get overlay 'pele-key))
      (when-let* ((id (overlay-get overlay 'pele-request))) (pele-cancel id))
      (overlay-put overlay 'pele-key key)
      (overlay-put
       overlay 'pele-request
       (pele-render-async
        source
        (lambda (result)
          (when (and (buffer-live-p buffer) (overlay-buffer overlay)
                     (equal key (overlay-get overlay 'pele-key)))
            (with-current-buffer buffer
              (overlay-put overlay 'pele-request nil)
              (if (plist-get result :ok)
                  (progn
                    (overlay-put overlay 'pele-result result)
                    (overlay-put overlay 'pele-size nil)
                    (overlay-put overlay 'help-echo "Mermaid preview")
                    (pele--inline-display overlay))
                (let ((message (plist-get (plist-get result :error) :message)))
                  (overlay-put overlay 'help-echo message)
                  (unless (overlay-get overlay 'pele-result)
                    (overlay-put overlay 'after-string
                                 (propertize (concat "\n" message "\n") 'face 'error))))))))
        options)))))

(defun pele--inline-refresh ()
  "Refresh previews using the current buffer's block collector."
  (when pele--inline-timer (cancel-timer pele--inline-timer))
  (setq pele--inline-timer nil)
  (when pele--inline-blocks-function
    (save-excursion
      (save-restriction
        (widen)
        (let ((blocks (funcall pele--inline-blocks-function))
              (old pele--inline-overlays)
              (width (pele--window-width)))
          (setq pele--inline-overlays nil)
          (unwind-protect
              (dolist (block blocks)
                (let* ((begin (plist-get block :begin))
                       (end (plist-get block :end))
                       (overlay (or (seq-find
                                     (lambda (candidate)
                                       (equal begin (marker-position
                                                     (overlay-get candidate 'pele-begin))))
                                     old)
                                    (make-overlay end end))))
                  (setq old (delq overlay old))
                  ;; Track ownership before starting work, including error paths.
                  (push overlay pele--inline-overlays)
                  (unless (overlay-get overlay 'pele-begin)
                    (overlay-put overlay 'pele-begin (copy-marker begin)))
                  (move-overlay overlay end end)
                  (pele--inline-update overlay (plist-get block :source)
                                       (list :max-width width))
                  (pele--inline-display overlay)))
            (mapc #'pele--inline-delete old)
            (setq pele--inline-overlays (nreverse pele--inline-overlays))))))))

(defun pele--inline-schedule (&rest change)
  "Schedule a refresh of the current buffer's previews."
  ;; Layout notifications from modal mode lines must not dismiss image focus.
  (when change (pele--inline-unfocus))
  (when pele--inline-timer (cancel-timer pele--inline-timer))
  (let ((buffer (current-buffer)))
    (setq pele--inline-timer
          (run-with-idle-timer pele-preview-delay nil
                               (lambda ()
                                 (when (buffer-live-p buffer)
                                   (with-current-buffer buffer (pele--inline-refresh))))))))

(defun pele--inline-disable ()
  "Remove the current buffer's previews, hooks and pending work."
  (pele--inline-unfocus)
  (when (eq pele--inline-blocks-function #'pele--org-blocks)
    (pele--org-display-results nil))
  (remove-hook 'post-command-hook #'pele--inline-after-command t)
  (when pele--inline-wheel
    (when (eq mwheel-scroll-up-function #'pele--inline-scroll-up)
      (if (car pele--inline-wheel)
          (setq mwheel-scroll-up-function (cdr pele--inline-wheel))
        (kill-local-variable 'mwheel-scroll-up-function)))
    (setq pele--inline-wheel nil))
  (remove-hook 'after-change-functions #'pele--inline-schedule t)
  (remove-hook 'kill-buffer-hook #'pele--inline-disable t)
  (remove-hook 'change-major-mode-hook #'pele--inline-disable t)
  (when pele--inline-timer (cancel-timer pele--inline-timer))
  (setq pele--inline-timer nil pele--inline-blocks-function nil)
  (mapc #'pele--inline-delete pele--inline-overlays)
  (setq pele--inline-overlays nil))

(defun pele--inline-enable (collector)
  "Enable previews for blocks returned by COLLECTOR.
Each block is a plist with :begin, :end and :source."
  (pele--inline-disable)
  (require 'mwheel)
  (setq pele--inline-wheel (cons (local-variable-p 'mwheel-scroll-up-function)
                                 mwheel-scroll-up-function))
  (setq-local mwheel-scroll-up-function #'pele--inline-scroll-up)
  (setq pele--inline-blocks-function collector)
  (add-hook 'post-command-hook #'pele--inline-after-command nil t)
  (add-hook 'after-change-functions #'pele--inline-schedule nil t)
  (add-hook 'kill-buffer-hook #'pele--inline-disable nil t)
  (add-hook 'change-major-mode-hook #'pele--inline-disable nil t)
  (pele--inline-refresh))

(defun pele--org-display-results (regions)
  "Suppress Org result images in REGIONS, restoring any outside them.
Keep Org's overlays so its image toggles and refreshes retain ownership.
Only their display properties change; links, files and undo stay intact."
  (dolist (overlay (let ((lists (overlay-lists))) (append (car lists) (cdr lists))))
    (let ((saved (overlay-get overlay 'pele-org-image)))
      (if (and (overlay-get overlay 'org-image-overlay)
               (seq-some (lambda (region)
                           (and (<= (car region) (overlay-start overlay))
                                (<= (overlay-end overlay) (cdr region))))
                         regions))
          (when (eq (car-safe (overlay-get overlay 'display)) 'image)
            ;; Org may have replaced the image since the last refresh.
            (overlay-put overlay 'pele-org-image
                         (mapcar (lambda (property)
                                   (cons property (overlay-get overlay property)))
                                 '(display before-string face keymap)))
            (dolist (property '(display before-string face keymap))
              (overlay-put overlay property nil)))
        (when saved
          (dolist (entry saved) (overlay-put overlay (car entry) (cdr entry)))
          (overlay-put overlay 'pele-org-image nil))))))

(defun pele--org-blocks ()
  "Collect Mermaid Org blocks and suppress their duplicate result images."
  (require 'org-element)
  (require 'ob-core)
  (let (regions)
    (prog1
        (org-element-map (org-element-parse-buffer) 'src-block
          (lambda (element)
            (when (pele--language-p (org-element-property :language element))
              (save-excursion
                (goto-char (org-element-property :begin element))
                (when-let* ((result (org-babel-where-is-src-block-result)))
                  (goto-char result)
                  (forward-line 1)
                  (push (cons (point) (org-babel-result-end)) regions)))
              (list :begin (org-element-property :begin element)
                    :end (save-excursion
                           ;; Org's :end includes following blank lines. Keep the
                           ;; preview at the closing line so input stays below it.
                           (goto-char (org-element-property :end element))
                           (skip-chars-backward " \t\r\n")
                           (forward-line 1)
                           (point))
                    :source (org-element-property :value element)))))
      (pele--org-display-results regions))))

(defun pele--org-after-images (&optional buffer &rest _)
  "Deduplicate Org images after an image refresh, possibly in BUFFER."
  (let ((buffer (if (bufferp buffer) buffer (current-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (eq pele--inline-blocks-function #'pele--org-blocks)
          (save-excursion
            (save-restriction
              (widen)
              (pele--org-blocks))))))))

(with-eval-after-load 'org
  (when (fboundp 'pele--org-after-images)
    ;; Org 9.8 also creates previews in asynchronous batches.
    (dolist (function '(org-display-inline-images org-link-preview--process-queue))
      (when (fboundp function)
        (advice-add function :after #'pele--org-after-images
                    '((name . pele-org-results)))))))

;;;###autoload
(define-minor-mode pele-org-mode
  "Show live SVG previews beneath Mermaid source blocks.
Editing leaves the last successful image visible until a new one is ready.
Hide duplicate Babel result images while enabled, retaining their links
and files.  Previews are overlays and do not modify the Org file."
  :lighter " Pele"
  (if pele-org-mode
      (progn
        (unless (derived-mode-p 'org-mode)
          (setq pele-org-mode nil)
          (user-error "Pele Org mode requires an Org buffer"))
        (condition-case err
            (progn
              (when (called-interactively-p 'interactive) (pele--ensure-module t))
              (pele--inline-enable #'pele--org-blocks))
          (error
           (pele--inline-disable)
           (setq pele-org-mode nil)
           (signal (car err) (cdr err)))))
    (when (eq pele--inline-blocks-function #'pele--org-blocks)
      (pele--inline-disable))))

(defun pele--refresh-inline-buffers (&rest _)
  "Refresh enabled previews after a theme or window size change."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when pele--inline-blocks-function (pele--inline-schedule))
      (when (and (derived-mode-p 'pele-preview-mode) pele--preview-result
                 (get-buffer-window buffer t))
        (pele--preview-display)))))

(add-hook 'enable-theme-functions #'pele--refresh-inline-buffers)
(add-hook 'disable-theme-functions #'pele--refresh-inline-buffers)
(add-hook 'window-size-change-functions #'pele--refresh-inline-buffers)

(defun pele-unload-function ()
  "Remove preview state and motion advice before unloading Pele."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when pele--inline-blocks-function
        (pele--inline-disable)
        (setq pele-org-mode nil)
        (when (boundp 'pele-markdown-mode) (setq pele-markdown-mode nil)))))
  (dolist (entry pele--inline-motions)
    (advice-remove (car entry) 'pele-inline-motion))
  (advice-remove 'evil-adjust-cursor 'pele-inline-cursor)
  (dolist (function '(org-display-inline-images org-link-preview--process-queue))
    (advice-remove function 'pele-org-results))
  (dolist (hook '(enable-theme-functions disable-theme-functions window-size-change-functions))
    (remove-hook hook #'pele--refresh-inline-buffers))
  (remove-hook 'kill-emacs-hook #'pele-shutdown)
  (pele-shutdown)
  nil)

(autoload 'pele-markdown-mode "pele-markdown" nil t)
(autoload 'pele-markdown--source-at-point "pele-markdown")

(provide 'pele)
;;; pele.el ends here
