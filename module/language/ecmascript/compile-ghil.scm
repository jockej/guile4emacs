;;; ECMAScript for Guile

;; Copyright (C) 2009 Free Software Foundation, Inc.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.
;; 
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;; 
;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Code:

(define-module (language ecmascript compile-ghil)
  #:use-module (language ghil)
  #:use-module (ice-9 receive)
  #:use-module (system base pmatch)
  #:export (compile-ghil))

(define (compile-ghil exp env opts)
  (values
  (call-with-ghil-environment (make-ghil-toplevel-env) '()
    (lambda (env vars)
      (make-ghil-lambda env #f vars #f '() (comp exp env))))
  env))

(define (location x)
  (and (pair? x)
       (let ((props (source-properties x)))
	 (and (not (null? props))
              props))))

(define-macro (@implv e l sym)
  `(make-ghil-ref ,e ,l
                  (ghil-var-at-module! ,e '(language ecmascript impl) ',sym #t)))
(define-macro (@impl e l sym args)
  `(make-ghil-call ,e ,l
                   (@implv ,e ,l ,sym)
                   ,args))

(define (comp x e)
  (let ((l (location x)))
    (pmatch x
      (null
       ;; FIXME, null doesn't have much relation to EOL...
       (make-ghil-quote e l '()))
      (true
       (make-ghil-quote e l #t))
      (false
       (make-ghil-quote e l #f))
      ((number ,num)
       (make-ghil-quote e l num))
      ((string ,str)
       (make-ghil-quote e l str))
      (this
       (@impl e l get-this '()))
      ((+ ,a ,b)
       (make-ghil-inline e l 'add (list (comp a e) (comp b e))))
      ((- ,a ,b)
       (make-ghil-inline e l 'sub (list (comp a e) (comp b e))))
      ((/ ,a ,b)
       (make-ghil-inline e l 'div (list (comp a e) (comp b e))))
      ((* ,a ,b)
       (make-ghil-inline e l 'mul (list (comp a e) (comp b e))))
      ((postinc (ref ,foo))
       (call-with-ghil-bindings e '(%tmp)
         (lambda (vars)
           (make-ghil-begin
            e l (list (make-ghil-set e l (car vars) (comp `(ref ,foo) e))
                      (make-ghil-set e l (ghil-var-for-set! e foo)
                                     (make-ghil-inline
                                      e l 'add (list (make-ghil-quote e l 1)
                                                     (make-ghil-ref e l (car vars)))))
                      (make-ghil-ref e l (car vars)))))))
      ((postinc (pref ,obj ,prop))
       (call-with-ghil-bindings e '(%tmp)
         (lambda (vars)
           (make-ghil-begin
            e l (list (make-ghil-set e l (car vars) (comp `(pref ,obj ,prop) e))
                      (@impl e l pput (list (comp obj e)
                                            (make-ghil-quote e l prop)
                                            (make-ghil-inline
                                             e l 'add (list (make-ghil-quote e l 1)
                                                            (make-ghil-ref e l (car vars))))))
                      (make-ghil-ref e l (car vars)))))))
      ((postinc (aref ,obj ,prop))
       (call-with-ghil-bindings e '(%tmp)
         (lambda (vars)
           (make-ghil-begin
            e l (list (make-ghil-set e l (car vars) (comp `(aref ,obj ,prop) e))
                      (@impl e l pput (list (comp obj e)
                                            (comp prop e)
                                            (make-ghil-inline
                                             e l 'add (list (make-ghil-quote e l 1)
                                                            (make-ghil-ref e l (car vars))))))
                      (make-ghil-ref e l (car vars)))))))
      ((postdec (ref ,foo))
       (call-with-ghil-bindings e '(%tmp)
         (lambda (vars)
           (make-ghil-begin
            e l (list (make-ghil-set e l (car vars) (comp `(ref ,foo) e))
                      (make-ghil-set e l (ghil-var-for-set! e foo)
                                     (make-ghil-inline
                                      e l 'sub (list (make-ghil-ref e l (car vars))
                                                     (make-ghil-quote e l 1))))
                      (make-ghil-ref e l (car vars)))))))
      ((postdec (pref ,obj ,prop))
       (call-with-ghil-bindings e '(%tmp)
         (lambda (vars)
           (make-ghil-begin
            e l (list (make-ghil-set e l (car vars) (comp `(pref ,obj ,prop) e))
                      (@impl e l pput (list (comp obj e)
                                            (make-ghil-quote e l prop)
                                            (make-ghil-inline
                                             e l 'sub (list (make-ghil-ref e l (car vars))
                                                            (make-ghil-quote e l 1)))))
                      (make-ghil-ref e l (car vars)))))))
      ((postdec (aref ,obj ,prop))
       (call-with-ghil-bindings e '(%tmp)
         (lambda (vars)
           (make-ghil-begin
            e l (list (make-ghil-set e l (car vars) (comp `(aref ,obj ,prop) e))
                      (@impl e l pput (list (comp obj e)
                                            (comp prop e)
                                            (make-ghil-inline
                                             e l 'sub (list (make-ghil-ref e l (car vars))
                                                            (make-ghil-quote e l 1)))))
                      (make-ghil-ref e l (car vars)))))))
      ((preinc (ref ,foo))
       (let ((v (ghil-var-for-set! e foo)))
         (make-ghil-begin
          e l (list (make-ghil-set e l v
                                   (make-ghil-inline
                                    e l 'add (list (make-ghil-quote e l 1)
                                                   (make-ghil-ref e l v))))
                    (make-ghil-ref e l v)))))
      ((preinc (pref ,obj ,prop))
       (call-with-ghil-bindings e '(%tmp)
         (lambda (vars)
           (make-ghil-begin
            e l (list (make-ghil-set e l (car vars) (comp obj e))
                      (@impl e l pput (list (make-ghil-ref e l (car vars))
                                            (make-ghil-quote e l prop)
                                            (make-ghil-inline
                                             e l 'add (list (make-ghil-quote e l 1)
                                                            (@impl e l pget (list (make-ghil-ref e l (car vars))
                                                                                  (make-ghil-quote e l prop)))))))
                      (@impl e l pget (list (make-ghil-ref e l (car vars))
                                            (make-ghil-quote e l prop))))))))
      ((preinc (aref ,obj ,prop))
       (call-with-ghil-bindings e '(%tmp)
         (lambda (vars)
           (make-ghil-begin
            e l (list (make-ghil-set e l (car vars) (comp obj e))
                      (@impl e l pput (list (make-ghil-ref e l (car vars))
                                            (comp prop e)
                                            (make-ghil-inline
                                             e l 'add (list (make-ghil-quote e l 1)
                                                            (@impl e l pget (list (make-ghil-ref e l (car vars))
                                                                                  (comp prop e)))))))
                      (@impl e l pget (list (make-ghil-ref e l (car vars))
                                            (comp prop e))))))))
      ((predec (ref ,foo))
       (let ((v (ghil-var-for-set! e foo)))
         (make-ghil-begin
          e l (list (make-ghil-set e l v
                                   (make-ghil-inline
                                    e l 'sub (list (make-ghil-ref e l v)
                                                   (make-ghil-quote e l 1))))
                    (make-ghil-ref e l v)))))
      ((predec (pref ,obj ,prop))
       (call-with-ghil-bindings e '(%tmp)
         (lambda (vars)
           (make-ghil-begin
            e l (list (make-ghil-set e l (car vars) (comp obj e))
                      (@impl e l pput (list (make-ghil-ref e l (car vars))
                                            (make-ghil-quote e l prop)
                                            (make-ghil-inline
                                             e l 'sub (list (@impl e l pget (list (make-ghil-ref e l (car vars))
                                                                                  (make-ghil-quote e l prop)))
                                                            (make-ghil-quote e l 1)))))
                      (@impl e l pget (list (make-ghil-ref e l (car vars))
                                            (make-ghil-quote e l prop))))))))
      ((predec (aref ,obj ,prop))
       (call-with-ghil-bindings e '(%tmp)
         (lambda (vars)
           (make-ghil-begin
            e l (list (make-ghil-set e l (car vars) (comp obj e))
                      (@impl e l pput (list (make-ghil-ref e l (car vars))
                                            (comp prop e)
                                            (make-ghil-inline
                                             e l 'sub (list (@impl e l pget (list (make-ghil-ref e l (car vars))
                                                                                  (comp prop e)))
                                                            (make-ghil-quote e l 1)))))
                      (@impl e l pget (list (make-ghil-ref e l (car vars))
                                            (comp prop e))))))))
      ((ref ,id)
       (make-ghil-ref e l (ghil-var-for-ref! e id)))
      ((var . ,forms)
       (make-ghil-begin e l
                        (map (lambda (form)
                               (pmatch form
                                 ((,x ,y)
                                  (make-ghil-define e l
                                                    (ghil-var-define!
                                                     (ghil-env-parent e) x)
                                                    (comp y e)))
                                 ((,x)
                                  (make-ghil-define e l
                                                    (ghil-var-define!
                                                     (ghil-env-parent e) x)
                                                    (@implv e l *undefined*)))
                                 (else (error "bad var form" form))))
                             forms)))
      ((begin . ,forms)
       (make-ghil-begin e l (map (lambda (x) (comp x e)) forms)))
      ((lambda ,formals ,body)
       (call-with-ghil-environment e '(%args)
         (lambda (env vars)
           (make-ghil-lambda env l vars #t '()
                             (comp-body env l body formals '%args)))))
      ((call/this ,obj ,prop ,args)
       ;; FIXME: only evaluate "obj" once
       (@impl e l call/this*
              (list obj (make-ghil-lambda
                         e l '() #f '()
                         (make-ghil-call e l (@impl e l pget (list obj prop))
                                         args)))))
      ((call (pref ,obj ,prop) ,args)
       (comp `(call/this ,(comp obj e) ,(make-ghil-quote e l prop)
                         ,(map (lambda (x) (comp x e)) args))
             e))
      ((call (aref ,obj ,prop) ,args)
       (comp `(call/this ,(comp obj e) ,(comp prop e)
                         ,(map (lambda (x) (comp x e)) args))
             e))
      ((call ,proc ,args)
       (make-ghil-call e l (comp proc e) (map (lambda (x) (comp x e)) args)))
      ((return ,expr)
       (make-ghil-inline e l 'return (list (comp expr e))))
      ((array . ,args)
       (@impl e l new-array (map (lambda (x) (comp x e)) args)))
      ((object . ,args)
       (@impl e l new-object
              (map (lambda (x)
                     (pmatch x
                       ((,prop ,val)
                        (make-ghil-inline e l 'cons
                                          (list (make-ghil-quote e l prop)
                                                (comp val e))))
                       (else
                        (error "bad prop-val pair" x))))
                   args)))
      ((pref ,obj ,prop)
       (@impl e l pget (list (comp obj e) (make-ghil-quote e l prop))))
      ((aref ,obj ,index)
       (@impl e l pget (list (comp obj e) (comp index e))))
      ((= (ref ,name) ,val)
       (make-ghil-set e l (ghil-var-for-set! e name) (comp val e)))
      ((= (pref ,obj ,prop) ,val)
       (@impl e l pput (list (comp obj e) (make-ghil-quote e l prop) (comp val e))))
      ((= (aref ,obj ,prop) ,val)
       (@impl e l pput (list (comp obj e) (comp prop e) (comp val e))))
      ((new ,what ,args)
       (@impl e l new (map (lambda (x) (comp x e)) (cons what args))))
      ((delete (pref ,obj ,prop))
       (@impl e l pdel (list (comp obj e) (make-ghil-quote e l prop))))
      ((delete (aref ,obj ,prop))
       (@impl e l pdel (list (comp obj e) (comp prop e))))
      ((void ,expr)
       (make-ghil-begin e l (list (comp expr e) (@implv e l *undefined*))))
      ((typeof ,expr)
       (@impl e l typeof (list (comp expr e))))
      (else
       (error "compilation not yet implemented:" x)))))

(define (comp-body env loc body formals %args)
  (define (process)
    (let lp ((in body) (out '()) (rvars (reverse formals)))
      (pmatch in
        (((var (,x) . ,morevars) . ,rest)
         (lp `((var . ,morevars) . ,rest)
             out
             (if (memq x rvars) rvars (cons x rvars))))
        (((var (,x ,y) . ,morevars) . ,rest)
         (lp `((var . ,morevars) . ,rest)
             `((= (ref ,x) ,y) . ,out)
             (if (memq x rvars) rvars (cons x rvars))))
        (((var) . ,rest)
         (lp rest out rvars))
        ((,x . ,rest) (guard (and (pair? x) (eq? (car x) 'lambda)))
         (lp rest
             (cons x out)
             rvars))
        ((,x . ,rest) (guard (pair? x))
         (receive (sub-out rvars)
             (lp x '() rvars)
           (lp rest
               (cons sub-out out)
               rvars)))
        ((,x . ,rest)
         (lp rest
             (cons x out)
             rvars))
        (()
         (values (reverse! out)
                 rvars)))))
  (receive (out rvars)
      (process)
    (call-with-ghil-bindings env (reverse rvars)
      (lambda (vars)
        (let ((%argv (assq-ref (ghil-env-table env) %args)))
          (make-ghil-begin
           env loc
           `(,@(map (lambda (f)
                      (make-ghil-if
                       env loc
                       (make-ghil-inline
                        env loc 'null?
                        (list (make-ghil-ref env loc %argv)))
                       (make-ghil-begin env loc '())
                       (make-ghil-begin
                        env loc
                        (list (make-ghil-set
                               env loc
                               (ghil-var-for-ref! env f)
                               (make-ghil-inline
                                env loc 'car
                                (list (make-ghil-ref env loc %argv))))
                              (make-ghil-set
                               env loc %argv
                               (make-ghil-inline
                                env loc 'cdr
                                (list (make-ghil-ref env loc %argv))))))))
                    formals)
             ;; fixme: here check for too many args
             ,(comp out env))))))))