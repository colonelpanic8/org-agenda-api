;;; container-bootstrap.el --- Bootstrap straight.el and load config for container builds -*- lexical-binding: t; -*-

;; This file is used during the Nix build phase to:
;; 1. Bootstrap straight.el with HTTPS (no SSH in build sandbox)
;; 2. Force all use-package declarations to load immediately
;; 3. Trigger package downloads by loading the config
;;
;; The resulting straight/ directory is then included in the container.

;; Force HTTPS for straight.el (no SSH in build sandbox)
(setq straight-vc-git-default-protocol 'https)

;; Force all packages to load immediately (no deferring)
(setq use-package-always-demand t)

;; Disable native compilation during bootstrap
(setq straight-disable-native-compile t)
(setq native-comp-deferred-compilation-deny-list '(".*"))
(setq no-native-compile t)

;; Suppress warnings during batch build
(setq warning-minimum-level :emergency)

;; Point to the elisp directory (set by Nix via environment variable)
;; Ensure trailing slash - Emacs requires this for user-emacs-directory
(setq user-emacs-directory
      (file-name-as-directory
       (or (getenv "EMACS_CONFIG_DIR")
           (file-name-directory load-file-name)
           user-emacs-directory)))

(message "Bootstrapping with user-emacs-directory: %s" user-emacs-directory)

;; Set user-init-file (nil in batch mode, but some configs reference it)
(setq user-init-file (concat user-emacs-directory "init.el"))

;; Variables normally defined in init.el before loading README.el
(defvar imalison:do-benchmark nil)
(defvar imalison:kat-mode nil)

;; Bootstrap straight.el
(let ((bootstrap-file (concat user-emacs-directory "straight/repos/straight.el/bootstrap.el"))
      (install-url "https://raw.githubusercontent.com/raxod502/straight.el/develop/install.el"))
  (unless (file-exists-p bootstrap-file)
    (message "Downloading straight.el bootstrap...")
    (with-current-buffer
        (url-retrieve-synchronously install-url 'silent 'inhibit-cookies)
      (goto-char (point-max))
      (eval-print-last-sexp)))
  (load bootstrap-file nil 'nomessage))

;; Workaround for emacs28+ symlink issue
(defun my-patch-package-find-file-visit-truename (oldfun &rest r)
  (let ((find-file-visit-truename nil))
    (apply oldfun r)))
(advice-add #'straight--build-autoloads :around
            #'my-patch-package-find-file-visit-truename)

;; Setup use-package with straight.el
(setq package-enable-at-startup nil)
(setq straight-use-package-by-default t)
(straight-use-package 'use-package)
(require 'use-package)
(setq use-package-ensure-function 'straight-use-package-ensure-function)

;; CRITICAL: Load custom org from straight BEFORE anything else loads built-in org
;; This matches the declaration from init.el
(straight-use-package
 '(org :type git :host github :repo "colonelpanic8/org-mode" :local-repo "org"
       :branch "my-main-2025"
       :depth full :pre-build (straight-recipes-org-elpa--build) :build
       (:not autoloads) :files
       (:defaults "lisp/*.el" ("etc/styles/" "etc/styles/*"))))

;; Also load dash early as many packages depend on it
(straight-use-package 'dash)
(require 'dash)

;; Load the minimal bootstrap utilities (imalison:join-paths, etc.)
;; This is tangled from README.org with :tangle org-config-bootstrap.el
(let ((bootstrap-el (concat user-emacs-directory "org-config-bootstrap.el")))
  (when (file-exists-p bootstrap-el)
    (message "Loading org-config-bootstrap.el...")
    (load bootstrap-el)))

;; Load org config (this loads org-config-preface.el, org-config-config.el, etc.)
(let ((org-config-el (concat user-emacs-directory "org-config.el")))
  (when (file-exists-p org-config-el)
    (message "Loading org-config.el...")
    (load org-config-el)))

(message "Bootstrap complete. Packages should be downloaded to straight/")
