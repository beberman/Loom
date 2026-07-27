;; .emacs.d/init.el

;; ===================================
;; MELPA Package Support
;; ===================================
;; Enables basic packaging support
(require 'package)

;; Adds the Melpa archive to the list of available repositories
(add-to-list 'package-archives
             '("melpa" . "http://melpa.org/packages/") t)

;; Initializes the package infrastructure
(package-initialize)

;; If there are no archived package contents, refresh them
(when (not package-archive-contents)
  (package-refresh-contents))


;; Installs packages
;;
;; myPackages contains a list of package names

(defvar myPackages
  '(better-defaults                 ;; Set up some better Emacs defaults
    material-theme                  ;; Theme
    elpy ;; Emacs lisp python enviroment
    copilot
    slime
    magit
    )
  )

;; Scans the list in myPackages
;; If the package listed is not already installed, install it
(mapc #'(lambda (package)
          (unless (package-installed-p package)
            (package-install package)))
      myPackages)

(setq inhibit-startup-message-t t)
(load-theme 'material t)
(global-linum-mode t)


;; ====================================
;; Development Setup
;; ====================================
;; copilot
(unless (package-installed-p 'copilot)
  (package-refresh-contents)
  (package-install 'copilot))

(require 'copilot)
;(add-hook 'prog-mode-hook 'copilot-mode)

(with-eval-after-load 'copilot
  (define-key copilot-completion-map (kbd "TAB") #'copilot-accept-completion)
  (define-key copilot-completion-map (kbd "<tab>") #'copilot-accept-completion))

;; slime setup
(unless (package-installed-p 'slime)
  (package-refresh-contents)
  (package-install 'slime))

(setq inferior-lisp-program "sbcl")
(setq slime-contribs '(slime-fancy slime-quicklisp slime-asdf))

(load (expand-file-name "c:/Users/bsebe/quicklisp/slime-helper.el"))

(setq inferior-lisp-program "sbcl")

;; magit setup
(unless (package-installed-p 'magit)
  (package-refresh-contents)
  (package-install 'magit))

(global-set-key (kbd "C-x g") #'magit-status)
