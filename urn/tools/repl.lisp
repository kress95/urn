(import io/argparse arg)
(import io/term (coloured))
(import lua/basic (load))
(import lua/coroutine co)
(import lua/debug debug)
(import lua/io io)
(import lua/os os)

(import urn/backend/lua lua)
(import urn/backend/writer writer)
(import urn/documentation docs)
(import urn/loader loader)
(import urn/logger logger)
(import urn/logger)
(import urn/logger/void void)
(import urn/parser parser)
(import urn/range range)
(import urn/resolve/error (resolver-error?))
(import urn/resolve/loop (compile))
(import urn/resolve/scope scope)
(import urn/resolve/state state)

(import lua/basic (require))

(define history-path
  "The path for the history file."
  :hidden
  (with (home (and os/getenv
                (or
                  ;; Unix
                  (os/getenv "HOME")
                  ;; Windows
                  (os/getenv "USERPROFILE") (os/getenv "HOMEDRIVE") (os/getenv "HOMEPATH"))))
    (if home (.. home "/.urn_history") ".urn_history")))

(define read-line!
  "Read a line with the given PROMPT. Provides an INITIAL string and a
   function to COMPLETE partial strings if supported."
  :hidden
  (let [(read nil)
        (providers
          (list
            ;; Provider using LuaJIT's FFI and readline library
            (lambda ()
              (with ((ffi-ok ffi) (pcall require "ffi"))
                (if ffi-ok
                  (when-with ((ok readline) (pcall (.> ffi :load) "readline"))
                    ((.> ffi :cdef) "void* malloc(size_t bytes); // Required to allocate strings for completions
                                     void free(void *); // Required to free strings returned by readline
                                     char *readline (const char *prompt); // Read a line with the given prompt
                                     const char * rl_readline_name; // Set the program name

                                     // History manipulation
                                     void using_history();
                                     void add_history(const char *line);
                                     void read_history(const char *filename);

                                     // Hooks
                                     typedef int rl_hook_func_t (void);
                                     rl_hook_func_t *rl_startup_hook;

                                     // Completion
                                     typedef char *rl_compentry_func_t (const char *, int);
                                     typedef char **rl_completion_func_t (const char *, int, int);
                                     char **rl_completion_matches (const char *text, rl_compentry_func_t *entry_func);
                                     int rl_attempted_completion_over;
                                     char * rl_line_buffer;
                                     const char* rl_basic_word_break_characters;
                                     rl_completion_func_t * rl_attempted_completion_function;

                                     int rl_insert_text (const char *text);")
                    (let* [(current-initial "")
                           (previous "")
                           (current-completer nil)]
                      ;; Set the program name
                      (.<! readline :rl_readline_name "urn")

                      ;; Add a hook to insert the default text
                      (.<! readline :rl_startup_hook
                        (lambda ()
                          (when (> (n current-initial) 0) ((.> readline :rl_insert_text) current-initial))
                          0))

                      ;; Read the existing history
                      ((.> readline :using_history))
                      ((.> readline :read_history) history-path)

                      ;; Setup completion
                      (.<! readline :rl_basic_word_break_characters "\n \t;()[]{},@`'")
                      (.<! readline :rl_attempted_completion_function
                        (lambda (str start finish)
                          (.<! readline :rl_attempted_completion_over 1)
                          (let [(results nil)
                                (results-idx 0)]
                          ((.> readline :rl_completion_matches) str
                            (lambda (str idx)
                              (when (= idx 0)
                                (set! results
                                  (if current-completer
                                    (current-completer ((.> ffi :string) (.> readline :rl_line_buffer) finish))
                                    '())))
                              (inc! results-idx)
                              (with (res-partial (nth results results-idx))
                                (if res-partial
                                  (let* [(res-str (.. ((.> ffi :string) str) res-partial))
                                         (res-buf ((.> ffi :C :malloc) (succ (n res-str))))]
                                    ((.> ffi :copy) res-buf res-str (succ (n res-str)))
                                    res-buf)
                                  nil)))))))

                      (lambda (prompt initial complete)
                        (set! current-initial (or initial ""))
                        (set! current-completer complete)
                        ;; Wrap escape sequences in RL_PROMPT_(START|END)_IGNORE
                        (set! prompt (string/gsub prompt "(\27%[%A*%a)", "\1%1\2"))
                        (with (res ((.> readline :readline) prompt))
                          (if (= res nil)
                            nil
                            (with (str ((.> ffi :string) res))
                              (when (and (string/find str "%S") (/= previous str))
                                (set! previous str)
                                ((.> readline :add_history) res)
                                ;; We don't know when we'll exit to append "live". We do this
                                ;; rather than saving to avoid doubling the history file each save.
                                (when-with (out (io/open history-path "a"))
                                  (self out :write str "\n")
                                  (self out :close)))
                              ((.> ffi :C :free) res)
                              str))))))
                  nil)))

            ;; Provider using Lua readline library (http://www.pjb.com.au/comp/lua/readline.html)
            (lambda ()
              (with ((readline-ok readline) (pcall require "readline"))
                (if readline-ok
                  (with (previous nil)
                    ((.> readline :set_options) { :histfile history-path :completion false })
                    (lambda (prompt initial complete)
                      ;; Wrap escape sequences in RL_PROMPT_(START|END)_IGNORE
                      (set! prompt (string/gsub prompt "(\27%[%A*%a)", "\1%1\2"))
                      (with (res ((.> readline :readline) prompt))
                        (when (and res (string/find res "%S") (/= previous res))
                          (set! previous res)
                          ;; We don't know when we'll exit to append "live". We do this
                          ;; rather than saving to avoid doubling the history file each save.
                          (when-with (out (io/open history-path "a"))
                            (self out :write res "\n")
                            (self out :close)))
                        res)))
                  nil)))

            ;; Provider using Lua linenoise library (https://github.com/hoelzro/lua-linenoise)
            (lambda ()
              (with ((linenoise-ok linenoise) (pcall require "linenoise"))
                (if linenoise-ok
                  (with (previous nil)
                    ((.> linenoise :historysetmaxlen) 1000)
                    ((.> linenoise :historyload) history-path)
                    (lambda (prompt initial complete)
                      ;; Strip escape sequences as linenoise doesn't handle them
                      (set! prompt (string/gsub prompt "(\27%[%A*%a)", ""))

                      ;; Setup the completion function
                      (if complete
                        ((.> linenoise :setcompletion)
                          (lambda (obj line)
                            (for-each completion (complete line)
                              ((.> linenoise :addcompletion) obj (.. line completion " ")))))
                        ((.> linenoise :setcompletion) nil))

                      ;; Read all lines
                      (with (res ((.> linenoise :linenoise) prompt))
                        (when (and res (string/find res "%S") (/= previous res))
                          (set! previous res)
                          ((.> linenoise :historyadd) res)
                          ;; We don't know when we'll exit to append "live". We do this
                          ;; rather than saving to avoid doubling the history file each save.
                          (when-with (out (io/open history-path "a"))
                            (self out :write res "\n")
                            (self out :close)))
                        res)))
                  nil)))

            (lambda ()
              (lambda (prompt initial complete)
                (io/write prompt)
                (io/flush)
                (io/read "*l")))))]

    (lambda (prompt initial complete)
      (unless read
        (loop
          [(i 1)]
          []
          (with (provider ((nth providers i)))
            (if provider
              (set! read provider)
              (recur (succ i))))))
      (read prompt initial complete))))

(defun requires-input (str)
  "Determine whether STR requires additional input (such as quotes or parens).
   The returns false if no input is required, and nil if a syntax error occured."
  :hidden
  (case (list (pcall (lambda()
                       (parser/parse
                         void/void
                         (parser/lex void/void str "<stdin>" true)
                         true))))
    [(true _) false]
    [(false (table? @ ?x)) (if (.> x :context) true false)]
    [(false ?x) nil]))

(defun get-indent (str)
  "Determines the indent required for STR.

   This simply lexes the string and counts the opening and closing parens."
  :hidden
  (let [(toks (case (list (pcall parser/lex void/void str "<stdin>" true))
                [(true ?x) x]
                [(false (table? @ ?x)) (or (.> x :tokens) '())]))
        (stack '(1))]
    (for-each tok toks
      (case (type tok)
        ["open" (push-cdr! stack (+ (.> tok :range :start :column) 2))]
        ["close" (pop-last! stack)]
        [_]))
    (string/rep " " (pred (last stack)))))

(defun get-complete (str scope)
  "Gets the possible completions for PREVIOUS + STR in the given scope..

   This determines whether we're in a symbol context and, if so, the
   possible variables in scope."
  :hidden
  ;; TODO: If the string is one line and starts with ':', can we complete commands?
  (case (list (pcall parser/lex void/void str "<stdin>" true))
    [(true ?toks)
     ;; Get the penultimate token (the last one will be an eof).
     (let* [(last (nth toks (pred (n toks))))
            (contents
              (cond
                ;; If there was no previous token, then start anew.
                [(= last nil) ""]
                ;; If the previous token finished before the cursor, then start anew.
                [(< (.> last :range :finish :offset) (n str)) ""]
                ;; If the previous token was a symbo, then finish completing it.
                [(symbol? last) (symbol->string last)]
                ;; Otherwise don't complete it.
                [true nil]))]

       (if contents
         (let [(visited {})
               (vars '())]
           ;; Scan the scope for variables starting with the prefix.
           (loop
             [(scope scope)]
             [(= scope nil)]
             (for-pairs (name _) (.> scope :variables)
               (when (and (string/starts-with? name contents) (not (.> visited name)))
                 (.<! visited name true)
                 (push-cdr! vars (string/sub name (succ (n contents))))))
             (recur (.> scope :parent)))
           (sort! vars)
           vars)
         '()))]
    ;; EOF errors within the lexer only occur in strings, thus we do not need to complete them.
    [_ '()]))

(define repl-colour-scheme
  :hidden
  (when-let* [(ge os/getenv) ; actually check that os/getenv exists
              (clrs (ge "URN_COLOURS"))
              (scheme-alist (parser/read clrs))]
    scheme-alist))

(defun colour-for (elem) :hidden
  (if (assoc? repl-colour-scheme (string->symbol elem))
    (const-val (assoc repl-colour-scheme (string->symbol elem)))
    (case elem
      ["text" 0]
      ["arg" 36]
      ["mono" 97]
      ["bold" 1]
      ["italic" 3]
      ["link" 94]

      ["comment"  90]
      ["string"   32]
      ["number"   0]
      ["key"      36]
      ["symbol"   0]
      ["keyword"  35]
      ["operator" 0])))

(define token-mapping :hidden
  "Mapping of token names to their corresponding definition in [[colour-for]]"
  { :string      :string
    :interpolate :string
    :number      :number
    :key         :key
    :symbol      :symbol

    :open           :operator
    :close          :operator
    :open-struct    :operator
    :close-struct   :operator
    :quote          :operator
    :quasi-quote    :operator
    :syntax-quote   :operator
    :unquote        :operator
    :unquote-splice :operator })

(define keywords :hidden
  "Set of keywords which will be highlighted differently."
  (create-lookup '("define" "define-macro" "define-native"
                   "lambda" "set!" "cond" "import" "struct-literal"
                   "quote" "syntax-quote" "unquote" "unquote-splice"

                   "defun" "defmacro" "car" "cdr" "list" "cons" "progn"
                   "if" "when" "unless" "let" "let*" "with" "not" "gensym"
                   "for" "while" "and" "or" "loop" "case")))

(defun print-docs! (str)
  :hidden
  (with (docs (docs/parse-docstring str))
    (for-each tok docs
      (with (tag (.> tok :kind))
        (cond
          [(= tag "bolic")
           (io/write (coloured (colour-for :bold) (coloured (colour-for :italic) (.> tok :contents))))]
          [true
           (io/write (coloured (colour-for tag) (.> tok :contents)))])))
    (print!)))

(defun exec-command (compiler scope args)
  "Execute command given by ARGS using the given compiler state (COMPILER) and SCOPE"
  :hidden
  (let* [(logger (.> compiler :log))
         (command (car args))]
    (cond
      [nil
       (logger/put-error! logger "Expected command after ':'")]

      [(or (= command "help") (= command "h"))
       (print! "REPL commands:
                [:d]oc NAME        Get documentation about a symbol
                :module NAME       Display a loaded module's docs and definitions.
                :scope             Print out all variables in the scope
                [:s]earch QUERY    Search the current scope for symbols and documentation containing a string.
                [:v]iew NAME       Display the definition of a symbol.
                [:q]uit            Exit the REPL cleanly.")]

      [(or (= command "doc") (= command "d"))
       (with (name (nth args 2))
         (if name
           (with (var (scope/get scope name))
             (if (= var nil)
               (logger/put-error! logger (.. "Cannot find '" name "'"))
               (let* [(sig (docs/extract-signature var))
                      (name (.> var :full-name))]
                 (when sig
                   (with (buffer (list name))
                     (for-each arg sig (push-cdr! buffer (.> arg :contents)))
                     (set! name (.. "(" (concat buffer " ") ")"))))
                 (print! (coloured 96 name))

                 (if (.> var :doc)
                   (print-docs! (.> var :doc))
                   (logger/put-error! logger (.. "No documentation for '" name "'"))))))
           (logger/put-error! logger ":doc <variable>")))]

      [(= command "module")
       (with (name (nth args 2))
         (if name
           (with (mod (.> compiler :lib-names name))
             (cond
               [(= mod nil)
                (logger/put-error! logger (.. "Cannot find '" name "'"))]
               [true
                (print! (coloured 96 (.> mod :name)))
                (print! (.. "Located at " (.> mod :path)))

                (when (.> mod :docs)
                  (print-docs! (.> mod :docs))
                  (print!))

                (print! (coloured 92 "Exported symbols"))
                (with (vars '())
                  (for-pairs (name) (.> mod :scope :exported) (push-cdr! vars name))
                  (sort! vars)
                  (print! (concat vars "  ")))]))
           (logger/put-error! logger ":module <variable>")))]

      [(or (= command "search") (= command "s"))
       (if (> (n args) 1)
         (let* [(keywords (map string/lower (cdr args)))
                (name-results '())
                (docs-results '())
                (vars '())
                (vars-set {})
                (current scope)]
           (while current
             (for-pairs (name var) (.> current :variables)
               (unless (.> vars-set name)
                 (push-cdr! vars name)
                 (.<! vars-set name true)))
             (set! current (.> current :parent)))

           (for-each var vars
             ;; search by function name
             (for-each keyword keywords
               (when (string/find var keyword)
                 (push-cdr! name-results var)))
             ;; search by function docs
             (when-let* [(doc-var (scope/get scope var))
                         (temp-docs (.> doc-var :doc))
                         (docs (string/lower temp-docs))
                         (keywords-found 0)]
               (for-each keyword keywords
                 (when (string/find docs keyword)
                   (inc! keywords-found)))
               (when (eq? keywords-found (n keywords))
                 (push-cdr! docs-results var))))
           (if (and (empty? name-results) (empty? docs-results))
             (logger/put-error! logger "No results")
             (progn
               (when (not (empty? name-results))
                 (print! (coloured 92 "Search by function name:"))
                 (if (> (n name-results) 20)
                   (print! (.. (concat (take name-results 20) "  ") "  ..."))
                   (print! (concat name-results "  "))))
               (when (not (empty? docs-results))
                 (print! (coloured 92 "Search by function docs:"))
                 (if (> (n docs-results) 20)
                   (print! (.. (concat (take docs-results 20) "  ") "  ..."))
                   (print! (concat docs-results "  ")))))))
         (logger/put-error! logger ":search <keywords>"))]

      [(= command "scope")
       (let* [(vars '())
              (vars-set {})
              (current scope)]
         (while current
           (for-pairs (name var) (.> current :variables)
             (unless (.> vars-set name)
               (push-cdr! vars name)
               (.<! vars-set name true)))
           (set! current (.> current :parent)))

         (sort! vars)

         (print! (concat vars "  ")))]

      [(or (= command "view") (= command "v"))
       (with (name (nth args 2))
         (if name
           (with (var (scope/get scope name))
             (if (/= var nil)
               (let* [(node (.> var :node))
                      (range (and node (range/get-source node)))]
                 (if (/= range nil)
                   (let* [(lines (.> range :lines))
                          (start (.> range :start))
                          (finish (.> range :finish))
                          (buffer '())]

                     (for i (.> start :line) (.> finish :line) 1
                       (push-cdr! buffer (string/sub (.> lines i)
                                                     (if (= i (.> start  :line)) (.> start  :column) 1)
                                                     (if (= i (.> finish :line)) (.> finish :column) -1))))

                     (let* [(contents (concat buffer "\n"))
                            (previous 0)]
                       (for-each tok (parser/lex void/void contents "stdin")
                         (with (start (.> tok :range :start  :offset))
                           (when (/= start previous)
                             (io/write (coloured (colour-for "comment") (string/sub contents previous (pred start))))))

                         (with (tag (type tok))
                           (unless (= tag "eof")
                             (if (and (= tag "symbol") (.> keywords (.> tok :contents)))
                               (io/write (coloured (colour-for "keyword") (.> tok :contents)))
                               (io/write (coloured (colour-for (.> token-mapping (type tok))) (.> tok :contents))))))

                         (set! previous (succ (.> tok :range :finish :offset)))))
                     (io/write "\n"))

                   (logger/put-error! logger (.. "Cannot extract source code for " (string/quoted name)))))
               (logger/put-error! logger (.. "Cannot find " (string/quoted name)))))
           (logger/put-error! logger ":view <variable>")))]

      [(or (= command "quit") (= command "q"))
       (print! "Goodbye.")
       (os/exit 0)]

      [else
       (logger/put-error! logger (.. "Unknown command '" command "'"))])))

(defun exec-string (compiler scope string)
  :hidden
  (let* [(logger (.> compiler :log))
         (lexed (parser/lex logger string "<stdin>"))
         (parsed (parser/parse logger lexed))
         (state (cadr (list (compile compiler parsed scope))))]
    (when (> (n state) 0)
      (let* [(current 0)
             (exec (co/create (lambda ()
                                (for-each elem state
                                  (set! current elem)
                                  (state/get! current)))))
             (compile-state (.> compiler :compile-state))
             (global (.> compiler :global))
             (logger (.> compiler :log))
             (run true)]
        (while run
          (with (res (list (co/resume exec)))
            (cond
              [(not (car res))
               (logger/put-error! logger (cadr res))
               (set! run false)]
              [(= (co/status exec) "dead")
               (let* [(lvl (state/get! (last state)))]
                 (with (pretty-fun pretty)
                   (when-with (pretty-var (scope/get scope "pretty"))
                     (with (pretty-val (state/get! (.> compiler :states pretty-var)))
                       (set! pretty-fun pretty-val)))

                   (print! (.. "out = " (coloured 96 (pretty-fun lvl)))))

                 (.<! global (lua/push-escape-var! (scope/add! scope "out" "defined" lvl)
                                                   compile-state) lvl))
               (set! run false)]
              [true
                (let* [(states (.> (cadr res) :states))
                       (latest (car states))
                       (co (co/create lua/execute-states))
                       (task nil)]

                  (while (and run (/= (co/status co) "dead"))
                    (.<! compiler :active-node (.> latest :node))
                    (.<! compiler :active-scope (.> latest :scope))

                    (with (res (if task
                                 (list (co/resume co))
                                 (list (co/resume co compile-state states global))))

                      (.<! compiler :active-node nil)
                      (.<! compiler :active-scope nil)

                      (case res
                        [(false ?msg) (fail! msg)]
                        [(true)]
                        [(true ?arg)
                         (when (/= (co/status co) "dead")
                           (set! task arg)
                           (case (type task)
                             ["execute" (lua/execute-states compile-state (.> task :states) global)]
                             [?task fail! (.. "Cannot handle " task)]))]))))])))))))

(defun repl (compiler args)
  (let* [(scope (.> compiler :root-scope))
         (logger (.> compiler :log))
         (buffer "")
         (running true)]

    ;; Import all specified modules if possible
    (for-each input (.> args :input)
      (with (library (car (loader/loader compiler input false)))
        (for-pairs (name var) (.> library :scope :exported)
          (if (.> scope :variables name)
            (scope/import! scope (.. (.> library :name) "/" name) var)
            (scope/import! scope name var)))))

    (while running
      (with (line (read-line!
                    (coloured 92 (if (empty? buffer) "> " ". "))
                    (get-indent buffer)
                    (lambda (x) (get-complete (.. buffer x) scope))))
        (cond
          ;; If we got no input, then exit the REPL
          [(and (not line) (empty? buffer)) (set! running false)]

          [true
            (with (data (if line (.. buffer line "\n") buffer))
              (cond
                [(= (string/char-at data 1) ":")
                 (set! buffer "")
                 (exec-command compiler scope (map string/trim (string/split (string/sub data 2) " ")))]
                [(and line (> (n line) 0) (requires-input data))
                 (set! buffer data)]
                [true
                 (set! buffer "")
                 (set! scope (scope/child scope))
                 (.<! scope :is-root true)

                 (with (res (list (pcall exec-string compiler scope data)))
                   ;; Clear active node/scope
                   (.<! compiler :active-node nil)
                   (.<! compiler :active-scope nil)
                   (unless (or (car res) (resolver-error? (cadr res)))
                     (logger/put-error! logger (cadr res))))]))])))))

(defun exec (compiler)
  (let* [(data (io/read "*a"))
         (scope (.> compiler :root-scope))
         (logger (.> compiler :log))
         (res (list (pcall exec-string compiler scope data)))]
    (unless (or (car res) (resolver-error? (cadr res)))
      (logger/put-error! logger (cadr res)))
    (os/exit 0)))

(define repl-task
  { :name  "repl"
    :setup (lambda (spec)
             (arg/add-argument! spec '("--repl")
               :help "Start an interactive session."))
    :pred  (lambda (args) (.> args :repl))
    :run  repl })

(define exec-task
  { :name  "exec"
    :setup (lambda (spec)
             (arg/add-argument! spec '("--exec")
               :help "Execute a program from stdin without compiling it. This acts as if it were input in one go via the REPL."))
    :pred  (lambda (args) (.> args :exec))
    :run   exec })
