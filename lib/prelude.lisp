(import base (lambda defun defmacro progn for while if quasiquote const-val and
              or xpcall pcall values-list gensym tostring tonumber
              require => <=> unpack list when unless arg apply for-pairs first
              second third fourth fifth sixth seventh ninth tenth + - * / % ^ !
              .. n else) :export)
(import base)
(import string (format concat $) :export)
(import binders () :export)
(import comparison () :export)
(import function () :export)
(import lens () :export)
(import list () :export)
(import string :export)
(import table () :export)
(import type () :export)
(import lua/os)
(import lua/io (write) :export)
(import lua/io io :export)
(import lua/math math :export)
(import lua/math maths :export)
(import match (destructuring-bind case handler-case matches? function if-match) :export)

(define *standard-output*
  "The standard output stream."
  (io/output))

(define *standard-error*
  "The standard error stream."
  (io/stderr))

(define *standard-input*
  "The standard input stream."
  (io/input))

(defun succ (x)
  "Return the successor of the number X."
  (+ x 1))

(defun pred (x)
  "Return the predecessor of the number X."
  (- x 1))

(define string->number
  "Convert the string X into a number. Returns `nil` if it could not be
   parsed.

   Optionally takes a BASE which the number is in (such as 16 for
   hexadecimal).

   ### Example:
   ```cl
   > (string->number \"23\")
   out = 23
   ```"
  tonumber)

(define number->string
  "Convert the number X into a string."
  tostring)

(define bool->string
  "Convert the boolean X into a string."
  tostring)

(defun symbol->string (x)
  "Convert the symbol X to a string."
  (if (symbol? x)
    (.> x "contents")
    nil))

(defun string->symbol (x)
  "Convert the string X to a symbol."
  { :tag "symbol" :contents x })

(defun sym.. (&xs)
  "Concatenate all the symbols in XS."
  (string->symbol (concat (map symbol->string xs))))

(define error!
  "Throw an error."
  base/error)

(define print!
  "Print to standard output."
  base/print)

(defun fail! (x)
  "Fail with the error message X, that is, exit the program immediately,
   without unwinding for an error handler."
  (error! x 0))

(defun exit! (reason code)
  "Exit the program with the exit code CODE, and optionally, print the
   error message REASON."
  (with (code (if (string? reason) code reason))
    (cond
      [lua/os/exit
       (when (string? reason) (print! reason))
       (lua/os/exit code)]
      [(string? reason) (fail! reason)]
      [else (fail!)])))

(defun id (x)
  "Return the value X unmodified."
  x)

(defun as-is (x)
  "Return the value X unchanged."
  x)

(defun const (x)
  "Return a function which always returns X. This is equivalent to the
   `K` combinator in SK combinator calculus.

   ### Example
   ```cl
   > (define x (const 1))
   > (x 2)
   out = 1
   > (x \"const\")
   out = 1
   ```"
  (lambda () x))

(defun call (x key &args)
  "Index X with KEY and invoke the resulting function with ARGS."
  ((.> x key) (unpack args 1 (n args))))

(defun self (x key &args)
  "Index X with KEY and invoke the resulting function with X and ARGS."
  ((.> x key) x (unpack args 1 (n args))))

(defun even? (x)
  "Is X an even number?"
  (= (% x 2) 0))

(defun odd? (x)
  "Is X an odd number?"
  (/= (% x 2) 0))

(defmacro inc! (x)
  "Increments the symbol X by 1.

   ### Example
   ```cl
   > (with (x 1)
   .   (inc! x)
   .   x)
   out = 2
   ```"
  `(set! ,x (succ ,x)))

(defmacro dec! (x)
  "Decrements the symbol X by 1.

   ### Example
   ```cl
   > (with (x 1)
   .   (dec! x)
   .   x)
   out = 0
   ```"
  `(set! ,x (pred ,x)))

(defun sprintf (fmt &args)
  "Format the format string FMT using ARGS.

   ### Example
   ```cl
   > (sprintf \"%.3d\" 1)
   out = \"001\"
   ```"
  (apply string/format fmt args))

(defun printf (fmt &args)
  "Print the formatted string FMT using ARGS.

   ### Example
   ```cl
   > (printf \"%.3d\" 1)
   001
   out = nil
   ```"
  (print! (apply sprintf fmt args)))
