;;; matlab-shell-gud.el --- GUD support in matlab-shell.
;;
;; Copyright (C) 2019 Eric Ludlam
;;
;; Author: Eric Ludlam <eludlam@emacsvm>
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see https://www.gnu.org/licenses/.

;;; Commentary:
;;
;; GUD (grand unified debugger) support for MATLAB shell.
;;
;; Includes setting up gud mode in the shell, and all filters, etc specific
;; to supporting gud.

(require 'matlab-shell)

(eval-and-compile
  (require 'gud)
  )

;;; Code:

;;;###autoload
(defun matlab-shell-mode-gud-enable-bindings ()
  "Enable GUD features for `matlab-shell' in the current buffer."

  ;; Make sure this is safe to use gud to debug MATLAB
  (when (not (fboundp 'gud-def))
    (error "Your emacs is missing `gud-def' which means matlab-shell won't work correctly.  Stopping"))

  (gud-def gud-break  "dbstop in %d/%f at %l"  "\C-b" "Set breakpoint at current line.")
  (gud-def gud-remove "dbclear in %d/%f at %l" "\C-d" "Remove breakpoint at current line.")
  (gud-def gud-step   "dbstep in"           "\C-s" "Step one source line, possibly into a function.")
  (gud-def gud-next   "dbstep %p"           "\C-n" "Step over one source line.")
  (gud-def gud-cont   "dbcont"              "\C-r" "Continue with display.")
  (gud-def gud-stop-subjob "dbquit"         nil    "Quit debugging.") ;; gud toolbar stop
  (gud-def gud-finish "dbquit"              "\C-f" "Finish executing current function.")
  (gud-def gud-up     "dbup"                "<"    "Up N stack frames (numeric arg).")
  (gud-def gud-down   "dbdown"              ">"    "Down N stack frames (numeric arg).")
  ;; using (gud-def gud-print  "%e" "\C-p" "Eval expression at point") fails
  (gud-def gud-print  "% gud-print not available" "\C-p" "gud-print not available.")

  (if (fboundp 'gud-make-debug-menu)
      (gud-make-debug-menu))
  )

;;;###autoload
(defun matlab-shell-gud-startup ()
  "Configure GUD when a new `matlab-shell' is initialized."
  (gud-mode)

  ;; This starts us supporting gud tooltips.
  (add-to-list 'gud-tooltip-modes 'matlab-mode)
  
  (make-local-variable 'gud-marker-filter)
  (setq gud-marker-filter 'gud-matlab-marker-filter)
  (make-local-variable 'gud-find-file)
  (setq gud-find-file 'gud-matlab-find-file)

  ;; XEmacs doesn't seem to have this concept already.  Oh well.
  (make-local-variable 'gud-marker-acc)
  (setq gud-marker-acc nil)

  ;; Setup our debug tracker.
  (add-hook 'matlab-shell-prompt-appears-hook #'gud-matlab-debug-tracker)
  
  (gud-set-buffer))

;;; GUD Functions
(defun gud-matlab-massage-args (file args)
  "Argument message for starting matlab file.
I don't think I have to do anything, but I'm not sure.
FILE is ignored, and ARGS is returned."
  args)

(defun gud-matlab-find-file (f)
  "Find file F when debugging frames in MATLAB."
  (save-excursion
    (let* ((realfname (if (string-match "\\.\\(p\\)$" f)
			  (progn
			    (aset f (match-beginning 1) ?m)
			    f)
			f))
	   (buf (find-file-noselect realfname)))
      (set-buffer buf)
      (if (fboundp 'gud-make-debug-menu)
	  (gud-make-debug-menu))
      buf)))


;;; GUD Filter Function
;;
;; MATLAB's process filter handles output from the MATLAB process and
;; interprets it for formatting text, and for running the debugger.

(defvar gud-matlab-marker-regexp-plain-prompt "^K?>>"
  "Regular expression for finding a prompt.")

(defvar gud-matlab-marker-regexp-K>> "^K>>"
  "Regular expression for finding a file line-number.")
(defvar gud-matlab-marker-regexp->> "^>>"
  "Regular expression for finding a file line-number.")

(defvar gud-matlab-dbhotlink nil
  "Track if we've sent a dbhotlink request.")
(make-variable-buffer-local 'gud-matlab-dbhotlink)

(defun gud-matlab-marker-filter (string)
  "Filters STRING for the Unified Debugger based on MATLAB output."

  (setq gud-marker-acc (concat gud-marker-acc string))
  (let ((output "") (frame nil))

    ;; ERROR DELIMITERS
    ;; Newer MATLAB's wrap error text in {^H  }^H characters.
    ;; Convert into something COMINT won't delete so we can scan them.
    (while (string-match "{" gud-marker-acc)
      (setq gud-marker-acc (replace-match matlab-shell-errortext-start-text t t gud-marker-acc 0)))

    (while (string-match "}" gud-marker-acc)
      (setq gud-marker-acc (replace-match matlab-shell-errortext-end-text t t gud-marker-acc 0)))
    
    ;; DEBUG PROMPTS
    (when (string-match gud-matlab-marker-regexp-K>> gud-marker-acc)

      ;; Look for any frames for case of a debug prompt.
      (let ((url gud-marker-acc)
	    ef el)

	;; We use dbhotlinks to create the below syntax.  If we see it we have a frame,
	;; and should tell gud to go there.
	
	(when (string-match "opentoline('\\([^']+\\)',\\([0-9]+\\),\\([0-9]+\\))" url)
	  (setq ef (substring url (match-beginning 1) (match-end 1))
		el (substring url (match-beginning 2) (match-end 2)))

	  (setq frame (cons ef (string-to-number el)))))

      ;; Newer MATLAB's don't print useful info.  We'll have to
      ;; search backward for the previous line to see if a frame was
      ;; displayed.
      (when (and (not frame) (not gud-matlab-dbhotlink))
	(let ((dbhlcmd (if matlab-shell-echoes
			   "dbhotlink()%%%\n"
			 ;; If no echo, force an echo
			 "disp(['dbhotlink()%%%' newline]);dbhotlink();\n")))
	  ;;(when matlab-shell-io-testing (message "!!> [%s]" dbhlcmd))
	  (process-send-string (get-buffer-process gud-comint-buffer) dbhlcmd)
	  )
	(setq gud-matlab-dbhotlink t)
	)
      )

    ;; If we're forced to ask for a stack hotlink, we will see it come in via the
    ;; process output.  Don't output anything until a K prompt is seen after the display
    ;; of the dbhotlink command.
    (when gud-matlab-dbhotlink
      (let ((start (string-match "dbhotlink()%%%" gud-marker-acc))
	    (endprompt nil))
	(if start
	    (progn
	      (setq output (substring gud-marker-acc 0 start)
		    gud-marker-acc (substring gud-marker-acc start))

	      ;; The hotlink text will persist until we see the K prompt.
	      (when (string-match gud-matlab-marker-regexp-plain-prompt gud-marker-acc)
		(setq endprompt (match-end 0))

		;; (when matlab-shell-io-testing (message "!!xx [%s]" (substring gud-marker-acc 0 endprompt)))

		;; We're done with the text!  Remove it from the accumulator.
		(setq gud-marker-acc (substring gud-marker-acc endprompt))
		;; If we got all this at the same time, push output back onto the accumulator for
		;; the next code bit to push it out.
		(setq gud-marker-acc (concat output gud-marker-acc)
		      output ""
		      gud-matlab-dbhotlink nil)
		))
	  ;; Else, waiting for a link, but hasn't shown up yet.
	  ;; TODO - what can I do here to fix var setting if it gets
	  ;; locked?
	  (when (string-match gud-matlab-marker-regexp->> gud-marker-acc)
	    ;; A non-k prompt showed up.  We're not going to get out request.
	    (setq gud-matlab-dbhotlink nil))
	  )))
    
    ;; This if makes sure that the entirety of an error output is brought in
    ;; so that matlab-shell-mode doesn't try to display a file that only partially
    ;; exists in the buffer.  Thus, if MATLAB output:
    ;;  error: /home/me/my/mo/mello.m,10,12
    ;; All of that is in the buffer, and it goes to mello.m, not just
    ;; the first half of that file name.
    ;; The below used to match against the prompt, not \n, but then text that
    ;; had error: in it for some other reason wouldn't display at all.
    (if (and matlab-prompt-seen ;; don't pause output if prompt not seen
	     gud-matlab-dbhotlink ;; pause output if waiting on debugger
	     )
	;; We could be collecting debug info.  Wait before output.
	nil
      ;; Finish off this part of the output.  None of our special stuff
      ;; ends with a \n, so display those as they show up...
      (while (string-match "^[^\n]*\n" gud-marker-acc)
	(setq output (concat output (substring gud-marker-acc 0 (match-end 0)))
	      gud-marker-acc (substring gud-marker-acc (match-end 0))))

      (if (string-match (concat gud-matlab-marker-regexp-plain-prompt "\\s-*$") gud-marker-acc)
	  (setq output (concat output gud-marker-acc)
		gud-marker-acc ""))
      
      ;; Check our output for a prompt, and existence of a frame.
      ;; If this is true, throw out the debug arrow stuff.
      (if (and (string-match (concat gud-matlab-marker-regexp->> "\\s-*$") output)
	       gud-last-last-frame)
	  (progn
	    (setq overlay-arrow-position nil
		  gud-last-last-frame nil
		  gud-overlay-arrow-position nil)
	    (sit-for 0)
	    )))

    (if frame (setq gud-last-frame frame))

    (when matlab-shell-io-testing
      (message "-->[%s] [%s]" output gud-marker-acc))

    ;;(message "Looking for prompt in %S" output)
    (when (and (not matlab-shell-suppress-prompt-hooks)
	       (string-match gud-matlab-marker-regexp-plain-prompt output))
      ;; Now that we are about to dump this, run our prompt hook.
      ;;(message "PROMPT!")
      (setq matlab-shell-prompt-hook-cookie t))
    
    output))


;;; K prompt state and hooks.

(defvar gud-matlab-debug-active nil
  "Non-nil if MATLAB has a K>> prompt up.")
(defvar gud-matlab-debug-activate-hook nil
  "Hooks run when MATLAB detects a K>> prompt after a >> prompt")
(defvar gud-matlab-debug-deactivate-hook nil
  "Hooks run when MATLAB detects a >> prompt after a K>> prompt")

(defun gud-matlab-debug-tracker ()
  "Function called when new prompts appear.
Call debug activate/deactivate features."
  (save-excursion
    (let ((inhibit-field-text-motion t))
      (beginning-of-line)
      (cond
       ((and gud-matlab-debug-active (looking-at gud-matlab-marker-regexp->>))
	(setq gud-matlab-debug-active nil)
	(global-matlab-shell-gud-minor-mode -1)
	(run-hooks 'gud-matlab-debug-deactivate-hook))
       ((and (not gud-matlab-debug-active) (looking-at gud-matlab-marker-regexp-K>>))
	(setq gud-matlab-debug-active t)
	(global-matlab-shell-gud-minor-mode 1)
	(run-hooks 'gud-matlab-debug-activate-hook))
       (t
	;; All clear
	))))
  )

;;; MATLAB SHELL GUD Minor Mode
;;
;; When K prompt is active, this minor mode is applied to frame buffers so
;; that GUD commands are easy to get to.

(defvar matlab-shell-gud-minor-mode-map 
  (let ((km (make-sparse-keymap))
	(key ?\ ))
    (while (<= key ?~)
      (define-key km (string key) 'matlab-shell-gud-mode-help-notice)
      (setq key (1+ key)))
    (define-key km "h" 'matlab-shell-gud-mode-help)

    ;; gud bindings.
    (define-key km "b" 'gud-break)
    (define-key km "r" 'gud-remove)
    (define-key km "c" 'gud-cont)
    (define-key km "s" 'gud-step)
    (define-key km "n" 'gud-next)
    (define-key km "f" 'gud-finish)
    (define-key km "q" 'gud-finish)
    (define-key km "u" 'gud-up)
    (define-key km "d" 'gud-down)
    (define-key km "<" 'gud-up)
    (define-key km ">" 'gud-down)
    (define-key km "p" 'matlab-shell-gud-show-symbol-value)
    ;; (define-key km "p" gud-print)

    (define-key km "e" 'matlab-shell-gud-mode-edit)
    
    km)
  "Keymap used by matlab mode maintainers.")

(easy-menu-define
  matlab-shell-gud-menu matlab-shell-gud-minor-mode-map "MATLAB Maintainer's Minor Mode"
  '("MATLAB-DEBUG"
      ["Exit MATLAB Debug mode" matlab-shell-gud-mode-edit
       :help "Exit the MATLAB debug minor mode to edit without exiting MATLAB's K>> prompt."]
      ["dbstop in FILE at point" gud-break
       :active (matlab-shell-active-p)
       :help "When MATLAB debugger is active, set break point at current M-file point"]
      ["dbclear in FILE at point" gud-remove
       :active (matlab-shell-active-p)
       :help "When MATLAB debugger is active, clear break point at current M-file point"]
      ["dbstep in" gud-step
       :active (matlab-shell-active-p)
       :help "When MATLAB debugger is active, step into line"]
      ["dbstep" gud-next
       :active (matlab-shell-active-p)
       :help "When MATLAB debugger is active, step one line"]
      ["dbup" gud-up
       :active (matlab-shell-active-p)
       :help "When MATLAB debugger is active and at break point, go up a frame"]
      ["dbdown" gud-down
       :active (matlab-shell-active-p)
       :help "When MATLAB debugger is active and at break point, go down a frame"]
      ["dbcont" gud-cont
       :active (matlab-shell-active-p)
       :help "When MATLAB debugger is active, run to next break point or finish"]
      ["dbquit" gud-finish
       :active (matlab-shell-active-p)
       :help "When MATLAB debugger is active, stop debugging"]
      ))

;;;###autoload
(define-minor-mode matlab-shell-gud-minor-mode
  "Minor mode activated when `matlab-shell' K>> prompt is active.
This minor mode makes MATLAB buffers read only so simple keystrokes
activate debug commands.  It also enables tooltips to appear when the
mouse hovers over a symbol when debugging.
\\<matlab-shell-gud-minor-mode-map>
Debug commands are:
 \\[gud-break]   - Set a breakpoint on the current line
 \\[gud-remove]   - Clear breakpoint on line
 \\[gud-cont]   - Continue till next breakpoint
 \\[gud-step]   - Step into next functions
 \\[gud-next]   - Next line in current function
 \\[gud-finish]   - Exit debug mode
 \\[gud-up]   - Navigate up the call stack
 \\[gud-down]   - Navigate down the call stack
 \\[matlab-shell-gud-mode-edit]   - Exit gud minor mode so you can edit
       you file without causing MATLAB to exit debug mode."
  nil " MGUD" matlab-shell-gud-minor-mode-map
  
  ;; Make the buffer read only
  (if matlab-shell-gud-minor-mode
      ;; Enable
      (progn
	(gud-tooltip-mode 1)
	(add-hook 'tooltip-functions 'gud-matlab-tooltip-tips)
	)
    ;; Disable
    (gud-tooltip-mode -1)
    (remove-hook 'tooltip-functions 'gud-matlab-tooltip-tips)
    )
  )

;;;###autoload
(define-global-minor-mode global-matlab-shell-gud-minor-mode
  matlab-shell-gud-minor-mode
  (lambda ()
    "Should we turn on in this buffer? Only if in a MATLAB mode."
    (when (eq major-mode 'matlab-mode)
      (matlab-shell-gud-minor-mode 1)))
  )

(defun matlab-shell-gud-show-symbol-value (sym)
  "Show the value of the symbol under point from MATLAB shell."
  (interactive
   (list
    (if (use-region-p)
	;; Don't ask user anything, just take it.
	(buffer-substring-no-properties (region-beginning) (region-end))
      (let ((word (matlab-read-word-at-point)))
	(read-from-minibuffer "MATLAB variable: " (cons word 0))))))
  (let ((txt (matlab-shell-collect-command-output
	      (concat "disp(" sym ")"))))
    (if (not (string-match "ERRORTXT" txt))
	(matlab-output-to-temp-buffer "*MATLAB Help*" txt)
      (message "Error evaluationg MATLAB expression"))))


(defun matlab-shell-gud-mode-edit ()
  "Turn off `matlab-shell-gud-minor-mode' so you can edit again."
  (interactive)
  (global-matlab-shell-gud-minor-mode -1))

(defun matlab-shell-gud-mode-help-notice ()
  "Default binding for most keys in `matlab-shell-gud-minor-mode'.
Shows a help message in the mini buffer."
  (interactive)
  (error "MATLAB shell GUD minor-mode: Press 'h' for help, 'e' to go back to editing."))

(defun matlab-shell-gud-mode-help ()
  "Show the default binding for most keys in `matlab-shell-gud-minor-mode'."
  (interactive)
  (describe-minor-mode 'matlab-shell-gud-minor-mode)
  )

;;; Tooltips
;;
;; Using the gud tooltip feature for a bunch of setup, but then
;; just override the tooltip fcn (see the mode) with this function
;; as an additional piece.
(defun gud-matlab-tooltip-tips (event)
  "Implementation of the tooltip feture for MATLAB.
Much of this was copied from `gud-tooltip-tips'.

This function must return nil if it doesn't handle EVENT."
  (when (eventp event)
    (with-current-buffer (tooltip-event-buffer event)
      (when (and gud-tooltip-mode
		 matlab-shell-gud-minor-mode
		 (buffer-name gud-comint-buffer) ; might be killed
		 )
	(let ((expr (matlab-shell-gud-find-tooltip-expression event))
	      (txt nil))
	  (when expr
	    (setq txt (matlab-shell-collect-command-output
		       (concat "emacstipstring(" expr ")")))

	    (when (not (string-match "ERRORTXT" txt))

	      (tooltip-show (concat expr "=\n" txt)
			    (or gud-tooltip-echo-area
				tooltip-use-echo-area
				(not tooltip-mode)))
	      t)))))))  

(defun matlab-shell-gud-find-tooltip-expression (event)
  "Identify an expression to output in a tooltip at EVENT.
Unlike `tooltip-expr-to-print', this looks at the symbol, and
if it looks like a function call, it will return nil."
  (interactive)

  (with-current-buffer (tooltip-event-buffer event)
    ;; Only do this for MATLAB stuff.
    (when matlab-shell-gud-minor-mode
      
      (let ((point (posn-point (event-end event))))
	(if (use-region-p)
	    (when (and (<= (region-beginning) point) (<= point (region-end)))
	      (buffer-substring (region-beginning) (region-end)))

	  ;; This snippent copied from tooltip.el, then modified to
	  ;; detect matlab functions
	  (save-excursion
	    (goto-char point)
	    (let* ((origin (point))
		   (start (progn
			    (skip-syntax-backward "w_")
			    ;; find full . expression
			    (while (= (preceding-char) ?.)
			      (forward-char -1)
			      (skip-syntax-backward "w_"))
			    (point)))
		   (pstate (syntax-ppss)))
	      (unless (or (looking-at "[0-9]")
			  (nth 3 pstate)
			  (nth 4 pstate))
		(goto-char origin)
		(skip-syntax-forward "w_")
		(when (> (point) start)
		  ;; At this point, look to see we are looking at (.  If so
		  ;; we need to grab that stuff too.
		  (if (not (looking-at "\\s-*("))
		      (buffer-substring-no-properties start (point))
		    ;; Also grab the arguments
		    (matlab-forward-sexp)
		    (buffer-substring-no-properties start (point)))
		  )))))))))

(provide 'matlab-shell-gud)

;;; matlab-shell-gud.el ends here
