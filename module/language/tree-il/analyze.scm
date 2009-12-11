;;; TREE-IL -> GLIL compiler

;; Copyright (C) 2001,2008,2009 Free Software Foundation, Inc.

;;;; This library is free software; you can redistribute it and/or
;;;; modify it under the terms of the GNU Lesser General Public
;;;; License as published by the Free Software Foundation; either
;;;; version 3 of the License, or (at your option) any later version.
;;;; 
;;;; This library is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;;; Lesser General Public License for more details.
;;;; 
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this library; if not, write to the Free Software
;;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

;;; Code:

(define-module (language tree-il analyze)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (system base syntax)
  #:use-module (system base message)
  #:use-module (system vm program)
  #:use-module (language tree-il)
  #:use-module (system base pmatch)
  #:export (analyze-lexicals
            analyze-tree
            unused-variable-analysis
            unbound-variable-analysis
            arity-analysis))

;; Allocation is the process of assigning storage locations for lexical
;; variables. A lexical variable has a distinct "address", or storage
;; location, for each procedure in which it is referenced.
;;
;; A variable is "local", i.e., allocated on the stack, if it is
;; referenced from within the procedure that defined it. Otherwise it is
;; a "closure" variable. For example:
;;
;;    (lambda (a) a) ; a will be local
;; `a' is local to the procedure.
;;
;;    (lambda (a) (lambda () a))
;; `a' is local to the outer procedure, but a closure variable with
;; respect to the inner procedure.
;;
;; If a variable is ever assigned, it needs to be heap-allocated
;; ("boxed"). This is so that closures and continuations capture the
;; variable's identity, not just one of the values it may have over the
;; course of program execution. If the variable is never assigned, there
;; is no distinction between value and identity, so closing over its
;; identity (whether through closures or continuations) can make a copy
;; of its value instead.
;;
;; Local variables are stored on the stack within a procedure's call
;; frame. Their index into the stack is determined from their linear
;; postion within a procedure's binding path:
;; (let (0 1)
;;   (let (2 3) ...)
;;   (let (2) ...))
;;   (let (2 3 4) ...))
;; etc.
;;
;; This algorithm has the problem that variables are only allocated
;; indices at the end of the binding path. If variables bound early in
;; the path are not used in later portions of the path, their indices
;; will not be recycled. This problem is particularly egregious in the
;; expansion of `or':
;;
;;  (or x y z)
;;    -> (let ((a x)) (if a a (let ((b y)) (if b b z))))
;;
;; As you can see, the `a' binding is only used in the ephemeral `then'
;; clause of the first `if', but its index would be reserved for the
;; whole of the `or' expansion. So we have a hack for this specific
;; case. A proper solution would be some sort of liveness analysis, and
;; not our linear allocation algorithm.
;;
;; Closure variables are captured when a closure is created, and stored
;; in a vector. Each closure variable has a unique index into that
;; vector.
;;
;; There is one more complication. Procedures bound by <fix> may, in
;; some cases, be rendered inline to their parent procedure. That is to
;; say,
;;
;;  (letrec ((lp (lambda () (lp)))) (lp))
;;    => (fix ((lp (lambda () (lp)))) (lp))
;;      => goto FIX-BODY; LP: goto LP; FIX-BODY: goto LP;
;;         ^ jump over the loop  ^ the fixpoint lp ^ starting off the loop
;;
;; The upshot is that we don't have to allocate any space for the `lp'
;; closure at all, as it can be rendered inline as a loop. So there is
;; another kind of allocation, "label allocation", in which the
;; procedure is simply a label, placed at the start of the lambda body.
;; The label is the gensym under which the lambda expression is bound.
;;
;; The analyzer checks to see that the label is called with the correct
;; number of arguments. Calls to labels compile to rename + goto.
;; Lambda, the ultimate goto!
;;
;;
;; The return value of `analyze-lexicals' is a hash table, the
;; "allocation".
;;
;; The allocation maps gensyms -- recall that each lexically bound
;; variable has a unique gensym -- to storage locations ("addresses").
;; Since one gensym may have many storage locations, if it is referenced
;; in many procedures, it is a two-level map.
;;
;; The allocation also stored information on how many local variables
;; need to be allocated for each procedure, lexicals that have been
;; translated into labels, and information on what free variables to
;; capture from its lexical parent procedure.
;;
;; In addition, we have a conflation: while we're traversing the code,
;; recording information to pass to the compiler, we take the
;; opportunity to generate labels for each lambda-case clause, so that
;; generated code can skip argument checks at runtime if they match at
;; compile-time.
;;
;; That is:
;;
;;  sym -> {lambda -> address}
;;  lambda -> (labels . free-locs)
;;  lambda-case -> (gensym . nlocs)
;;
;; address ::= (local? boxed? . index)
;; labels ::= ((sym . lambda) ...)
;; free-locs ::= ((sym0 . address0) (sym1 . address1) ...)
;; free variable addresses are relative to parent proc.

(define (make-hashq k v)
  (let ((res (make-hash-table)))
    (hashq-set! res k v)
    res))

(define (analyze-lexicals x)
  ;; bound-vars: lambda -> (sym ...)
  ;;  all identifiers bound within a lambda
  (define bound-vars (make-hash-table))
  ;; free-vars: lambda -> (sym ...)
  ;;  all identifiers referenced in a lambda, but not bound
  ;;  NB, this includes identifiers referenced by contained lambdas
  (define free-vars (make-hash-table))
  ;; assigned: sym -> #t
  ;;  variables that are assigned
  (define assigned (make-hash-table))
  ;; refcounts: sym -> count
  ;;  allows us to detect the or-expansion in O(1) time
  (define refcounts (make-hash-table))
  ;; labels: sym -> lambda
  ;;  for determining if fixed-point procedures can be rendered as
  ;;  labels.
  (define labels (make-hash-table))

  ;; returns variables referenced in expr
  (define (analyze! x proc labels-in-proc tail? tail-call-args)
    (define (step y) (analyze! y proc labels-in-proc #f #f))
    (define (step-tail y) (analyze! y proc labels-in-proc tail? #f))
    (define (step-tail-call y args) (analyze! y proc labels-in-proc #f
                                              (and tail? args)))
    (define (recur/labels x new-proc labels)
      (analyze! x new-proc (append labels labels-in-proc) #t #f))
    (define (recur x new-proc) (analyze! x new-proc '() tail? #f))
    (record-case x
      ((<application> proc args)
       (apply lset-union eq? (step-tail-call proc args)
              (map step args)))

      ((<conditional> test then else)
       (lset-union eq? (step test) (step-tail then) (step-tail else)))

      ((<lexical-ref> gensym)
       (hashq-set! refcounts gensym (1+ (hashq-ref refcounts gensym 0)))
       (if (not (and tail-call-args
                     (memq gensym labels-in-proc)
                     (let ((p (hashq-ref labels gensym)))
                       (and p
                            (let lp ((c (lambda-body p)))
                              (and c (lambda-case? c)
                                   (or 
                                    ;; for now prohibit optional &
                                    ;; keyword arguments; can relax this
                                    ;; restriction later
                                    (and (= (length (lambda-case-req c))
                                            (length tail-call-args))
                                         (not (lambda-case-opt c))
                                         (not (lambda-case-kw c))
                                         (not (lambda-case-rest c)))
                                    (lp (lambda-case-else c)))))))))
           (hashq-set! labels gensym #f))
       (list gensym))
      
      ((<lexical-set> gensym exp)
       (hashq-set! assigned gensym #t)
       (hashq-set! labels gensym #f)
       (lset-adjoin eq? (step exp) gensym))
      
      ((<module-set> exp)
       (step exp))
      
      ((<toplevel-set> exp)
       (step exp))
      
      ((<toplevel-define> exp)
       (step exp))
      
      ((<sequence> exps)
       (let lp ((exps exps) (ret '()))
         (cond ((null? exps) '())
               ((null? (cdr exps))
                (lset-union eq? ret (step-tail (car exps))))
               (else
                (lp (cdr exps) (lset-union eq? ret (step (car exps))))))))
      
      ((<lambda> body)
       ;; order is important here
       (hashq-set! bound-vars x '())
       (let ((free (recur body x)))
         (hashq-set! bound-vars x (reverse! (hashq-ref bound-vars x)))
         (hashq-set! free-vars x free)
         free))
      
      ((<lambda-case> opt kw inits vars body else)
       (hashq-set! bound-vars proc
                   (append (reverse vars) (hashq-ref bound-vars proc)))
       (lset-union
        eq?
        (lset-difference eq?
                         (lset-union eq?
                                     (apply lset-union eq? (map step inits))
                                     (step-tail body))
                         vars)
        (if else (step-tail else) '())))
      
      ((<let> vars vals body)
       (hashq-set! bound-vars proc
                   (append (reverse vars) (hashq-ref bound-vars proc)))
       (lset-difference eq?
                        (apply lset-union eq? (step-tail body) (map step vals))
                        vars))
      
      ((<letrec> vars vals body)
       (hashq-set! bound-vars proc
                   (append (reverse vars) (hashq-ref bound-vars proc)))
       (for-each (lambda (sym) (hashq-set! assigned sym #t)) vars)
       (lset-difference eq?
                        (apply lset-union eq? (step-tail body) (map step vals))
                        vars))
      
      ((<fix> vars vals body)
       ;; Try to allocate these procedures as labels.
       (for-each (lambda (sym val) (hashq-set! labels sym val))
                 vars vals)
       (hashq-set! bound-vars proc
                   (append (reverse vars) (hashq-ref bound-vars proc)))
       ;; Step into subexpressions.
       (let* ((var-refs
               (map
                ;; Since we're trying to label-allocate the lambda,
                ;; pretend it's not a closure, and just recurse into its
                ;; body directly. (Otherwise, recursing on a closure
                ;; that references one of the fix's bound vars would
                ;; prevent label allocation.)
                (lambda (x)
                  (record-case x
                    ((<lambda> body)
                     ;; just like the closure case, except here we use
                     ;; recur/labels instead of recur
                     (hashq-set! bound-vars x '())
                     (let ((free (recur/labels body x vars)))
                       (hashq-set! bound-vars x (reverse! (hashq-ref bound-vars x)))
                       (hashq-set! free-vars x free)
                       free))))
                vals))
              (vars-with-refs (map cons vars var-refs))
              (body-refs (recur/labels body proc vars)))
         (define (delabel-dependents! sym)
           (let ((refs (assq-ref vars-with-refs sym)))
             (if refs
                 (for-each (lambda (sym)
                             (if (hashq-ref labels sym)
                                 (begin
                                   (hashq-set! labels sym #f)
                                   (delabel-dependents! sym))))
                           refs))))
         ;; Stepping into the lambdas and the body might have made some
         ;; procedures not label-allocatable -- which might have
         ;; knock-on effects. For example:
         ;;   (fix ((a (lambda () (b)))
         ;;         (b (lambda () a)))
         ;;     (a))
         ;; As far as `a' is concerned, both `a' and `b' are
         ;; label-allocatable. But `b' references `a' not in a proc-tail
         ;; position, which makes `a' not label-allocatable. The
         ;; knock-on effect is that, when back-propagating this
         ;; information to `a', `b' will also become not
         ;; label-allocatable, as it is referenced within `a', which is
         ;; allocated as a closure. This is a transitive relationship.
         (for-each (lambda (sym)
                     (if (not (hashq-ref labels sym))
                         (delabel-dependents! sym)))
                   vars)
         ;; Now lift bound variables with label-allocated lambdas to the
         ;; parent procedure.
         (for-each
          (lambda (sym val)
            (if (hashq-ref labels sym)
                ;; Remove traces of the label-bound lambda. The free
                ;; vars will propagate up via the return val.
                (begin
                  (hashq-set! bound-vars proc
                              (append (hashq-ref bound-vars val)
                                      (hashq-ref bound-vars proc)))
                  (hashq-remove! bound-vars val)
                  (hashq-remove! free-vars val))))
          vars vals)
         (lset-difference eq?
                          (apply lset-union eq? body-refs var-refs)
                          vars)))
      
      ((<let-values> exp body)
       (lset-union eq? (step exp) (step body)))
      
      (else '())))
  
  ;; allocation: sym -> {lambda -> address}
  ;;             lambda -> (nlocs labels . free-locs)
  (define allocation (make-hash-table))
  
  (define (allocate! x proc n)
    (define (recur y) (allocate! y proc n))
    (record-case x
      ((<application> proc args)
       (apply max (recur proc) (map recur args)))

      ((<conditional> test then else)
       (max (recur test) (recur then) (recur else)))

      ((<lexical-set> exp)
       (recur exp))
      
      ((<module-set> exp)
       (recur exp))
      
      ((<toplevel-set> exp)
       (recur exp))
      
      ((<toplevel-define> exp)
       (recur exp))
      
      ((<sequence> exps)
       (apply max (map recur exps)))
      
      ((<lambda> body)
       ;; allocate closure vars in order
       (let lp ((c (hashq-ref free-vars x)) (n 0))
         (if (pair? c)
             (begin
               (hashq-set! (hashq-ref allocation (car c))
                           x
                           `(#f ,(hashq-ref assigned (car c)) . ,n))
               (lp (cdr c) (1+ n)))))
      
       (let ((nlocs (allocate! body x 0))
             (free-addresses
              (map (lambda (v)
                     (hashq-ref (hashq-ref allocation v) proc))
                   (hashq-ref free-vars x)))
             (labels (filter cdr
                             (map (lambda (sym)
                                    (cons sym (hashq-ref labels sym)))
                                  (hashq-ref bound-vars x)))))
         ;; set procedure allocations
         (hashq-set! allocation x (cons labels free-addresses)))
       n)

      ((<lambda-case> opt kw inits vars body else)
       (max
        (let lp ((vars vars) (n n))
          (if (null? vars)
              (let ((nlocs (apply
                            max
                            (allocate! body proc n)
                            ;; inits not logically at the end, but they
                            ;; are the list...
                            (map (lambda (x) (allocate! x body n)) inits))))
                ;; label and nlocs for the case
                (hashq-set! allocation x (cons (gensym ":LCASE") nlocs))
                nlocs)
              (begin
                (hashq-set! allocation (car vars)
                            (make-hashq
                             proc `(#t ,(hashq-ref assigned (car vars)) . ,n)))
                (lp (cdr vars) (1+ n)))))
        (if else (allocate! else proc n) n)))
      
      ((<let> vars vals body)
       (let ((nmax (apply max (map recur vals))))
         (cond
          ;; the `or' hack
          ((and (conditional? body)
                (= (length vars) 1)
                (let ((v (car vars)))
                  (and (not (hashq-ref assigned v))
                       (= (hashq-ref refcounts v 0) 2)
                       (lexical-ref? (conditional-test body))
                       (eq? (lexical-ref-gensym (conditional-test body)) v)
                       (lexical-ref? (conditional-then body))
                       (eq? (lexical-ref-gensym (conditional-then body)) v))))
           (hashq-set! allocation (car vars)
                       (make-hashq proc `(#t #f . ,n)))
           ;; the 1+ for this var
           (max nmax (1+ n) (allocate! (conditional-else body) proc n)))
          (else
           (let lp ((vars vars) (n n))
             (if (null? vars)
                 (max nmax (allocate! body proc n))
                 (let ((v (car vars)))
                   (hashq-set!
                    allocation v
                    (make-hashq proc
                                `(#t ,(hashq-ref assigned v) . ,n)))
                   (lp (cdr vars) (1+ n)))))))))
      
      ((<letrec> vars vals body)
       (let lp ((vars vars) (n n))
         (if (null? vars)
             (let ((nmax (apply max
                                (map (lambda (x)
                                       (allocate! x proc n))
                                     vals))))
               (max nmax (allocate! body proc n)))
             (let ((v (car vars)))
               (hashq-set!
                allocation v
                (make-hashq proc
                            `(#t ,(hashq-ref assigned v) . ,n)))
               (lp (cdr vars) (1+ n))))))

      ((<fix> vars vals body)
       (let lp ((in vars) (n n))
         (if (null? in)
             (let lp ((vars vars) (vals vals) (nmax n))
               (cond
                ((null? vars)
                 (max nmax (allocate! body proc n)))
                ((hashq-ref labels (car vars))                 
                 ;; allocate lambda body inline to proc
                 (lp (cdr vars)
                     (cdr vals)
                     (record-case (car vals)
                       ((<lambda> body)
                        (max nmax (allocate! body proc n))))))
                (else
                 ;; allocate closure
                 (lp (cdr vars)
                     (cdr vals)
                     (max nmax (allocate! (car vals) proc n))))))
             
             (let ((v (car in)))
               (cond
                ((hashq-ref assigned v)
                 (error "fixpoint procedures may not be assigned" x))
                ((hashq-ref labels v)
                 ;; no binding, it's a label
                 (lp (cdr in) n))
                (else
                 ;; allocate closure binding
                 (hashq-set! allocation v (make-hashq proc `(#t #f . ,n)))
                 (lp (cdr in) (1+ n))))))))

      ((<let-values> exp body)
       (max (recur exp) (recur body)))
      
      (else n)))

  (analyze! x #f '() #t #f)
  (allocate! x #f 0)

  allocation)


;;;
;;; Tree analyses for warnings.
;;;

(define-record-type <tree-analysis>
  (make-tree-analysis leaf down up post init)
  tree-analysis?
  (leaf tree-analysis-leaf)  ;; (lambda (x result env) ...)
  (down tree-analysis-down)  ;; (lambda (x result env) ...)
  (up   tree-analysis-up)    ;; (lambda (x result env) ...)
  (post tree-analysis-post)  ;; (lambda (result env) ...)
  (init tree-analysis-init)) ;; arbitrary value

(define (analyze-tree analyses tree env)
  "Run all tree analyses listed in ANALYSES on TREE for ENV, using
`tree-il-fold'.  Return TREE."
  (define (traverse proc)
    (lambda (x results)
      (map (lambda (analysis result)
             ((proc analysis) x result env))
           analyses
           results)))

  (let ((results
         (tree-il-fold (traverse tree-analysis-leaf)
                       (traverse tree-analysis-down)
                       (traverse tree-analysis-up)
                       (map tree-analysis-init analyses)
                       tree)))

    (for-each (lambda (analysis result)
                ((tree-analysis-post analysis) result env))
              analyses
              results))

  tree)


;;;
;;; Unused variable analysis.
;;;

;; <binding-info> records are used during tree traversals in
;; `report-unused-variables'.  They contain a list of the local vars
;; currently in scope, a list of locals vars that have been referenced, and a
;; "location stack" (the stack of `tree-il-src' values for each parent tree).
(define-record-type <binding-info>
  (make-binding-info vars refs locs)
  binding-info?
  (vars binding-info-vars)  ;; ((GENSYM NAME LOCATION) ...)
  (refs binding-info-refs)  ;; (GENSYM ...)
  (locs binding-info-locs)) ;; (LOCATION ...)

(define unused-variable-analysis
  ;; Report unused variables in the given tree.
  (make-tree-analysis
   (lambda (x info env)
     ;; X is a leaf: extend INFO's refs accordingly.
     (let ((refs (binding-info-refs info))
           (vars (binding-info-vars info))
           (locs (binding-info-locs info)))
       (record-case x
         ((<lexical-ref> gensym)
          (make-binding-info vars (cons gensym refs) locs))
         (else info))))

   (lambda (x info env)
     ;; Going down into X: extend INFO's variable list
     ;; accordingly.
     (let ((refs (binding-info-refs info))
           (vars (binding-info-vars info))
           (locs (binding-info-locs info))
           (src  (tree-il-src x)))
       (define (extend inner-vars inner-names)
         (append (map (lambda (var name)
                        (list var name src))
                      inner-vars
                      inner-names)
                 vars))
       (record-case x
         ((<lexical-set> gensym)
          (make-binding-info vars (cons gensym refs)
                             (cons src locs)))
         ((<lambda-case> req opt inits rest kw vars)
          (let ((names `(,@req
                         ,@(or opt '())
                         ,@(if rest (list rest) '())
                         ,@(if kw (map cadr (cdr kw)) '()))))
            (make-binding-info (extend vars names) refs
                               (cons src locs))))
         ((<let> vars names)
          (make-binding-info (extend vars names) refs
                             (cons src locs)))
         ((<letrec> vars names)
          (make-binding-info (extend vars names) refs
                             (cons src locs)))
         ((<fix> vars names)
          (make-binding-info (extend vars names) refs
                             (cons src locs)))
         (else info))))

   (lambda (x info env)
     ;; Leaving X's scope: shrink INFO's variable list
     ;; accordingly and reported unused nested variables.
     (let ((refs (binding-info-refs info))
           (vars (binding-info-vars info))
           (locs (binding-info-locs info)))
       (define (shrink inner-vars refs)
         (for-each (lambda (var)
                     (let ((gensym (car var)))
                       ;; Don't report lambda parameters as
                       ;; unused.
                       (if (and (not (memq gensym refs))
                                (not (and (lambda-case? x)
                                          (memq gensym
                                                inner-vars))))
                           (let ((name (cadr var))
                                 ;; We can get approximate
                                 ;; source location by going up
                                 ;; the LOCS location stack.
                                 (loc  (or (caddr var)
                                           (find pair? locs))))
                             (warning 'unused-variable loc name)))))
                   (filter (lambda (var)
                             (memq (car var) inner-vars))
                           vars))
         (fold alist-delete vars inner-vars))

       ;; For simplicity, we leave REFS untouched, i.e., with
       ;; names of variables that are now going out of scope.
       ;; It doesn't hurt as these are unique names, it just
       ;; makes REFS unnecessarily fat.
       (record-case x
         ((<lambda-case> vars)
          (make-binding-info (shrink vars refs) refs
                             (cdr locs)))
         ((<let> vars)
          (make-binding-info (shrink vars refs) refs
                             (cdr locs)))
         ((<letrec> vars)
          (make-binding-info (shrink vars refs) refs
                             (cdr locs)))
         ((<fix> vars)
          (make-binding-info (shrink vars refs) refs
                             (cdr locs)))
         (else info))))

   (lambda (result env) #t)
   (make-binding-info '() '() '())))


;;;
;;; Unbound variable analysis.
;;;

;; <toplevel-info> records are used during tree traversal in search of
;; possibly unbound variable.  They contain a list of references to
;; potentially unbound top-level variables, a list of the top-level defines
;; that have been encountered, and a "location stack" (see above).
(define-record-type <toplevel-info>
  (make-toplevel-info refs defs locs)
  toplevel-info?
  (refs  toplevel-info-refs)  ;; ((VARIABLE-NAME . LOCATION) ...)
  (defs  toplevel-info-defs)  ;; (VARIABLE-NAME ...)
  (locs  toplevel-info-locs)) ;; (LOCATION ...)

(define (goops-toplevel-definition proc args env)
  ;; If application of PROC to ARGS is a GOOPS top-level definition, return
  ;; the name of the variable being defined; otherwise return #f.  This
  ;; assumes knowledge of the current implementation of `define-class' et al.
  (define (toplevel-define-arg args)
    (and (pair? args) (pair? (cdr args)) (null? (cddr args))
         (record-case (car args)
           ((<const> exp)
            (and (symbol? exp) exp))
           (else #f))))

  (record-case proc
    ((<module-ref> mod public? name)
     (and (equal? mod '(oop goops))
          (not public?)
          (eq? name 'toplevel-define!)
          (toplevel-define-arg args)))
    ((<toplevel-ref> name)
     ;; This may be the result of expanding one of the GOOPS macros within
     ;; `oop/goops.scm'.
     (and (eq? name 'toplevel-define!)
          (eq? env (resolve-module '(oop goops)))
          (toplevel-define-arg args)))
    (else #f)))

(define unbound-variable-analysis
  ;; Report possibly unbound variables in the given tree.
  (make-tree-analysis
   (lambda (x info env)
     ;; X is a leaf: extend INFO's refs accordingly.
     (let ((refs (toplevel-info-refs info))
           (defs (toplevel-info-defs info))
           (locs (toplevel-info-locs info)))
       (define (bound? name)
         (or (and (module? env)
                  (module-variable env name))
             (memq name defs)))

       (record-case x
         ((<toplevel-ref> name src)
          (if (bound? name)
              info
              (let ((src (or src (find pair? locs))))
                (make-toplevel-info (alist-cons name src refs)
                                    defs
                                    locs))))
         (else info))))

   (lambda (x info env)
     ;; Going down into X.
     (let* ((refs (toplevel-info-refs info))
            (defs (toplevel-info-defs info))
            (src  (tree-il-src x))
            (locs (cons src (toplevel-info-locs info))))
       (define (bound? name)
         (or (and (module? env)
                  (module-variable env name))
             (memq name defs)))

       (record-case x
         ((<toplevel-set> name src)
          (if (bound? name)
              (make-toplevel-info refs defs locs)
              (let ((src (find pair? locs)))
                (make-toplevel-info (alist-cons name src refs)
                                    defs
                                    locs))))
         ((<toplevel-define> name)
          (make-toplevel-info (alist-delete name refs eq?)
                              (cons name defs)
                              locs))

         ((<application> proc args)
          ;; Check for a dynamic top-level definition, as is
          ;; done by code expanded from GOOPS macros.
          (let ((name (goops-toplevel-definition proc args
                                                 env)))
            (if (symbol? name)
                (make-toplevel-info (alist-delete name refs
                                                  eq?)
                                    (cons name defs)
                                    locs)
                (make-toplevel-info refs defs locs))))
         (else
          (make-toplevel-info refs defs locs)))))

   (lambda (x info env)
     ;; Leaving X's scope.
     (let ((refs (toplevel-info-refs info))
           (defs (toplevel-info-defs info))
           (locs (toplevel-info-locs info)))
       (make-toplevel-info refs defs (cdr locs))))

   (lambda (toplevel env)
     ;; Post-process the result.
     (for-each (lambda (name+loc)
                 (let ((name (car name+loc))
                       (loc  (cdr name+loc)))
                   (warning 'unbound-variable loc name)))
               (reverse (toplevel-info-refs toplevel))))

   (make-toplevel-info '() '() '())))


;;;
;;; Arity analysis.
;;;

;; <arity-info> records contain information about lexical definitions of
;; procedures currently in scope, top-level procedure definitions that have
;; been encountered, and calls to top-level procedures that have been
;; encountered.
(define-record-type <arity-info>
  (make-arity-info toplevel-calls lexical-lambdas toplevel-lambdas)
  arity-info?
  (toplevel-calls   toplevel-procedure-calls) ;; ((NAME . APPLICATION) ...)
  (lexical-lambdas  lexical-lambdas)          ;; ((GENSYM . DEFINITION) ...)
  (toplevel-lambdas toplevel-lambdas))        ;; ((NAME . DEFINITION) ...)

(define (validate-arity proc application lexical?)
  ;; Validate the argument count of APPLICATION, a tree-il application of
  ;; PROC, emitting a warning in case of argument count mismatch.

  (define (filter-keyword-args keywords allow-other-keys? args)
    ;; Filter keyword arguments from ARGS and return the resulting list.
    ;; KEYWORDS is the list of allowed keywords, and ALLOW-OTHER-KEYS?
    ;; specified whethere keywords not listed in KEYWORDS are allowed.
    (let loop ((args   args)
               (result '()))
      (if (null? args)
          (reverse result)
          (let ((arg (car args)))
            (if (and (const? arg)
                     (or (memq (const-exp arg) keywords)
                         (and allow-other-keys?
                              (keyword? (const-exp arg)))))
                (loop (if (pair? (cdr args))
                          (cddr args)
                          '())
                      result)
                (loop (cdr args)
                      (cons arg result)))))))

  (define (arities proc)
    ;; Return the arities of PROC, which can be either a tree-il or a
    ;; procedure.
    (define (len x)
      (or (and (or (null? x) (pair? x))
               (length x))
          0))
    (cond ((program? proc)
           (values (program-name proc)
                   (map (lambda (a)
                          (list (arity:nreq a) (arity:nopt a) (arity:rest? a)
                                (map car (arity:kw a))
                                (arity:allow-other-keys? a)))
                        (program-arities proc))))
          ((procedure? proc)
           (let ((arity (procedure-property proc 'arity)))
             (values (procedure-name proc)
                     (list (list (car arity) (cadr arity) (caddr arity)
                                 #f #f)))))
          (else
           (let loop ((name    #f)
                      (proc    proc)
                      (arities '()))
             (if (not proc)
                 (values name (reverse arities))
                 (record-case proc
                   ((<lambda-case> req opt rest kw else)
                    (loop name else
                          (cons (list (len req) (len opt) rest
                                      (and (pair? kw) (map car (cdr kw)))
                                      (and (pair? kw) (car kw)))
                                arities)))
                   ((<lambda> meta body)
                    (loop (assoc-ref meta 'name) body arities))
                   (else
                    (values #f #f))))))))

  (let ((args (application-args application))
        (src  (tree-il-src application)))
    (call-with-values (lambda () (arities proc))
      (lambda (name arities)
        (define matches?
          (find (lambda (arity)
                  (pmatch arity
                    ((,req ,opt ,rest? ,kw ,aok?)
                     (let ((args (if (pair? kw)
                                     (filter-keyword-args kw aok? args)
                                     args)))
                       (if (and req opt)
                           (let ((count (length args)))
                             (and (>= count req)
                                  (or rest?
                                      (<= count (+ req opt)))))
                           #t)))
                    (else #t)))
                arities))

        (if (not matches?)
            (warning 'arity-mismatch src
                     (or name (with-output-to-string (lambda () (write proc))))
                     lexical?)))))
  #t)

(define arity-analysis
  ;; Report arity mismatches in the given tree.
  (make-tree-analysis
   (lambda (x info env)
     ;; X is a leaf.
     info)
   (lambda (x info env)
     ;; Down into X.
     (define (extend lexical-name val info)
       ;; If VAL is a lambda, add NAME to the lexical-lambdas of INFO.
       (let ((toplevel-calls   (toplevel-procedure-calls info))
             (lexical-lambdas  (lexical-lambdas info))
             (toplevel-lambdas (toplevel-lambdas info)))
         (record-case val
           ((<lambda> body)
            (make-arity-info toplevel-calls
                             (alist-cons lexical-name val
                                         lexical-lambdas)
                             toplevel-lambdas))
           ((<lexical-ref> gensym)
            ;; lexical alias
            (let ((val* (assq gensym lexical-lambdas)))
              (if (pair? val*)
                  (extend lexical-name (cdr val*) info)
                  info)))
           ((<toplevel-ref> name)
            ;; top-level alias
            (make-arity-info toplevel-calls
                             (alist-cons lexical-name val
                                         lexical-lambdas)
                             toplevel-lambdas))
           (else info))))

     (let ((toplevel-calls   (toplevel-procedure-calls info))
           (lexical-lambdas  (lexical-lambdas info))
           (toplevel-lambdas (toplevel-lambdas info)))

       (record-case x
         ((<toplevel-define> name exp)
          (record-case exp
            ((<lambda> body)
             (make-arity-info toplevel-calls
                              lexical-lambdas
                              (alist-cons name exp toplevel-lambdas)))
            ((<toplevel-ref> name)
             ;; alias for another toplevel
             (let ((proc (assq name toplevel-lambdas)))
               (make-arity-info toplevel-calls
                                lexical-lambdas
                                (alist-cons (toplevel-define-name x)
                                            (if (pair? proc)
                                                (cdr proc)
                                                exp)
                                            toplevel-lambdas))))
            (else info)))
         ((<let> vars vals)
          (fold extend info vars vals))
         ((<letrec> vars vals)
          (fold extend info vars vals))
         ((<fix> vars vals)
          (fold extend info vars vals))

         ((<application> proc args src)
          (record-case proc
            ((<lambda> body)
             (validate-arity proc x #t)
             info)
            ((<toplevel-ref> name)
             (make-arity-info (alist-cons name x toplevel-calls)
                              lexical-lambdas
                              toplevel-lambdas))
            ((<lexical-ref> gensym)
             (let ((proc (assq gensym lexical-lambdas)))
               (if (pair? proc)
                   (record-case (cdr proc)
                     ((<toplevel-ref> name)
                      ;; alias to toplevel
                      (make-arity-info (alist-cons name x toplevel-calls)
                                       lexical-lambdas
                                       toplevel-lambdas))
                     (else
                      (validate-arity (cdr proc) x #t)
                      info))

                   ;; If GENSYM wasn't found, it may be because it's an
                   ;; argument of the procedure being compiled.
                   info)))
            (else info)))
         (else info))))

   (lambda (x info env)
     ;; Up from X.
     (define (shrink name val info)
       ;; Remove NAME from the lexical-lambdas of INFO.
       (let ((toplevel-calls   (toplevel-procedure-calls info))
             (lexical-lambdas  (lexical-lambdas info))
             (toplevel-lambdas (toplevel-lambdas info)))
         (make-arity-info toplevel-calls
                          (alist-delete name lexical-lambdas eq?)
                          toplevel-lambdas)))

     (let ((toplevel-calls   (toplevel-procedure-calls info))
           (lexical-lambdas  (lexical-lambdas info))
           (toplevel-lambdas (toplevel-lambdas info)))
       (record-case x
         ((<let> vars vals)
          (fold shrink info vars vals))
         ((<letrec> vars vals)
          (fold shrink info vars vals))
         ((<fix> vars vals)
          (fold shrink info vars vals))

         (else info))))

   (lambda (result env)
     ;; Post-processing: check all top-level procedure calls that have been
     ;; encountered.
     (let ((toplevel-calls   (toplevel-procedure-calls result))
           (toplevel-lambdas (toplevel-lambdas result)))
       (for-each (lambda (name+application)
                   (let* ((name        (car name+application))
                          (application (cdr name+application))
                          (proc
                           (or (assoc-ref toplevel-lambdas name)
                               (and (module? env)
                                    (false-if-exception
                                     (module-ref env name)))))
                          (proc*
                           ;; handle toplevel aliases
                           (if (toplevel-ref? proc)
                               (let ((name (toplevel-ref-name proc)))
                                 (and (module? env)
                                      (false-if-exception
                                       (module-ref env name))))
                               proc)))
                     ;; (format #t "toplevel-call to ~A (~A) from ~A~%"
                     ;;         name proc* application)
                     (if (or (lambda? proc*) (procedure? proc*))
                         (validate-arity proc* application (lambda? proc*)))))
                 toplevel-calls)))

   (make-arity-info '() '() '())))