;;; This file is part of Rules, an extensible pattern matching,
;;; pattern dispatch, and term rewriting system for MIT Scheme.
;;; Copyright 2010-2013 Alexey Radul, Massachusetts Institute of
;;; Technology
;;;
;;; Rules is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU Affero General Public License as
;;; published by the Free Software Foundation; either version 3 of the
;;; License, or (at your option) any later version.
;;;
;;; This code is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU Affero General Public
;;; License along with Rules; if not, see
;;; <http://www.gnu.org/licenses/>.

(declare (usual-integrations))

;;;; Functions for generating common rule types

;;; Note the use of unquote in the matcher expressions.

(define (nullary-replacement operator value)
  (rule `(,operator)
        (succeed value)))

(define (unary-elimination operator)
  (rule `(,operator (? a))
        (succeed a)))

(define (constant-elimination operator constant)
  (rule `(,operator ,constant (?? x))
        `(,operator ,@x)))

(define (constant-promotion operator constant)
  (rule `(,operator ,constant (?? x))
        (succeed constant)))

(define (associativity operator)
  (rule `(,operator (?? a) (,operator (?? b)) (?? c))
        #; `(,operator ,@a ,@b ,@c) ; Too slow to do them one at a time
        (append-map (lambda (item)
                      (if (and (pair? item)
                               (eq? operator (car item)))
                          (cdr item)
                          (list item)))
                    `(,operator ,@a ,@b ,@c))))

(define (commutativity operator)
  ;; Flipping one at a time is bubble sort
  ;; (rule `(,operator (?? a) (? y) (? x) (?? b))
  ;;       (and (expr<? x y)
  ;;            `(,operator ,@a ,x ,y ,@b)))
  ;; Finding a pair out of order and sorting is still quadratic,
  ;; because the matcher matches N times, and each requires
  ;; constructing the segments so they can be handed to the handler
  ;; (laziness would help).
  ;; (rule `(,operator (?? a) (? y) (? x) (?? b))
  ;;       (and (expr<? x y)
  ;;            `(,operator ,@(sort `(,@a ,x ,y ,@b) expr<?))))
  (rule `(,operator (?? terms))
        (and (not (sorted? terms expr<?))
             `(,operator ,@(sort terms expr<?)))))

(define (idempotence operator)
  (define (remove-consecutive-duplicates lst)
    (cond ((null? lst)        '())
          ((null? (cdr lst))  lst)
          ((equal? (car lst) (cadr lst))
           (remove-consecutive-duplicates (cdr lst)))
          (else
           (cons (car lst) (remove-consecutive-duplicates (cdr lst))))))
  (rule `(,operator (?? a) (? x) (? x) (?? b))
        #; `(,operator ,@a ,x ,@b) ; One at a time is too slow
        `(,operator ,@(remove-consecutive-duplicates `(,@a ,x ,@b)))))

;;;; Some algebraic simplification rulesets

(define simplify-sums
  (term-rewriting
   (nullary-replacement '+ 0)
   (unary-elimination '+)
   (constant-elimination '+ 0)
   (rule `(+ (? x ,number?) (? y ,number?) (?? z))
         `(+ ,(+ x y) ,@z))
   (associativity '+)
   (commutativity '+)))

(define simplify-products
  (term-rewriting
   (nullary-replacement '* 1)
   (unary-elimination '*)
   (constant-elimination '* 1)
   (constant-promotion '* 0)
   (rule `(* (? x ,number?) (? y ,number?) (?? z))
         `(* ,(* x y) ,@z))
   (associativity '*)
   ;; TODO be able to turn commutativity off nicely?
   (commutativity '*)))

(define remove-minus
  (term-rewriting
   (rule `(- (? x) (? y) (?? z))
         `(+ ,x (* -1 (+ ,y ,@z))))
   (rule `(- (? x)) `(* -1 ,x))))

(define distributive-law
  (rule `(* (?? a) (+ (?? b)) (?? c))
        `(+ ,@(map (lambda (x)
                     (simplify-products
                      `(* ,@a ,x ,@c)))
                   b))))

(define simplify-quotient
  (term-rewriting
   (rule `(/ (? n) 1) n)
   (rule `(/ 0 (? d)) 0)
   (rule `(/ 1 (/ (? n) (? d)))
         `(/ ,d ,n))
   ;; Note how the applicability test (gcd != 1) and the computation
   ;; share a subexpression.  This is why handlers need to be able to
   ;; reject, instead of having separate applicability tests.
   (rule `(/ (? n) (? d))
         (let ((g (g:gcd n d)))
           (and (not (= g 1))
                (let ((nn (g:divide n g))
                      (dd (g:divide d g)))
                  (simplify-quotient
                   `(/ ,nn ,dd))))))))

;;; TODO Implement multivariate polynomial gcd
(define (g:gcd x y) 1)
(define (g:divide x y)
  (error "Unimplemented divide" x y))

(define simplify-algebra
  (in-order
   remove-minus
   (iterated
    (in-order
     simplify-products
     simplify-sums
     (term-rewriting distributive-law)
     simplify-quotient))))

;;; Approaches toward two different normal forms for quotients

(define ->quotient-of-sums
  (term-rewriting
   ;; Same denominator
   (rule `(+ (?? a1) (/ (? n1) (? d)) (?? a2) (/ (? n2) (? d)) (?? a3))
         (simplify-sums
          `(+ ,(simplify-quotient
                `(/ ,(simplify-sums `(+ ,n1 ,n2)) ,d))
              ,@a1 ,@a2 ,@a3)))

   ;; General Case
   (rule `(+ (?? a1) (/ (? n1) (? d1)) (?? a2) (/ (? n2) (? d2)) (?? a3))
         (simplify-sums
          `(+ ,(simplify-quotient
                `(/ ,(simplify-sums
                      `(+ ,(simplify-products `(* ,n1 ,d2))
                          ,(simplify-products `(* ,n2 ,d1))))
                    ,(simplify-products `(* ,d1 ,d2))))
              ,@a1 ,@a2 ,@a3)))

   ;; Other terms
   (rule `(+ (?? a1) (/ (? n) (? d)) (?? a2))
         (simplify-quotient
          `(/ ,(simplify-sums
                `(+ ,n
                    ,(simplify-products
                      (* ,d ,(simplify-sums `(+ ,@a1 ,@a2))))))
              ,d)))))

(define quotient-of-sums->sum-of-quotients
  (term-rewriting
   (rule `(/ (+ (?? as)) (? d))
         `(+ ,@(map (lambda (n)
                      (simplify-quotient
                       `(/ ,n ,d)))
                    as)))))

;;; Some rules for exponentiation (toward different normal forms)

(define simplify-expt
  (term-rewriting
   (rule `(expt (? a ,number?) (? b ,number?))
         (expt a b))

   (rule `(expt (? b) 1) b)
   (rule `(expt (? b) -1) `(/ 1 b))     ; Do we want this?
   (rule `(expt 0 (? e)) 0)             ; Needs to be positive
   (rule `(expt 1 (? e)) 1)))

(define expand-expt
  (term-rewriting
   (rule `(expt (? x) (? n ,exact-integer? ,positive?))
         `(* ,@(make-list n x)))
   (rule `(expt (? x) (? n ,exact-integer? ,negative?))
         `(/ 1 (* ,@(make-list n x))))))

(define contract-expt
  (term-rewriting
   (rule `(* (?? f1) (? x) (? x) (?? f2))
         `(* ,@f1 (expt x 2) ,@f2))
   (rule `(expt (expt (? x) (? n)) (? m))
         `(expt x (* ,n ,m)))
   (rule `(* (?? f1) (? x) (expt (? x) (? n)) (?? f2))
         `(* ,@f1 (expt x (+ ,n 1)) ,@f2))
   (rule `(* (?? f1) (expt (? x) (? n)) (? x) (?? f2))
         `(* ,@f1 (expt x (+ ,n 1)) ,@f2))
   (rule `(* (?? f1) (expt (? x) (? n)) (expt (? x) (? m)) (?? f2))
         `(* ,@f1 (expt x (+ ,n ,m)) ,@f2))))

;;;; Logical simplification

(define simplify-negations
  (term-rewriting
   (rule `(not (not (? x))) (succeed x))
   (rule `(not #t) (succeed #f))
   (rule `(not #f) (succeed #t))
   (rule `(not (or (?? terms)))
         `(and ,@(map (lambda (term) `(not ,term))
                      terms)))
   (rule `(not (and (?? terms)))
         `(or ,@(map (lambda (term) `(not ,term))
                     terms)))))

(define simplify-ors
  (term-rewriting
   (nullary-replacement 'or #f)
   (unary-elimination 'or)
   (constant-elimination 'or #f)
   (constant-promotion 'or #t)
   (associativity 'or)
   (commutativity 'or)
   (idempotence 'or)
   (rule `(or (?? ts1) (? a) (?? ts2) (not (? a)) (?? ts3))
         (succeed #t))
   (rule `(or (?? ts1) (not (? a)) (?? ts2) (? a) (?? ts3))
         (succeed #t))))

(define simplify-ands
  (term-rewriting
   (nullary-replacement 'and #t)
   (unary-elimination 'and)
   (constant-elimination 'and #t)
   (constant-promotion 'and #f)
   (associativity 'and)
   (commutativity 'and)
   (idempotence 'and)
   (rule `(and (?? ts1) (? a) (?? ts2) (not (? a)) (?? ts3))
         (succeed #f))
   (rule `(and (?? ts1) (not (? a)) (?? ts2) (? a) (?? ts3))
         (succeed #f))))

(define push-or-through-and
  (rule `(or (?? or-terms-1) (and (?? and-terms)) (?? or-terms-2))
        `(and ,@(map (lambda (and-term)
                       `(or ,@or-terms-1 ,and-term ,@or-terms-2))
                     and-terms))))

(define ->conjunctive-normal-form
  (in-order
   simplify-negations
   (iterated
    (in-order
     simplify-ors
     simplify-ands
     (term-rewriting push-or-through-and)))))

(define simplify-logic ->conjunctive-normal-form)

;;; TODO Implement subsumption, and then implement resolution properly.

;;; These resolution rules are wrong, because they do not deduce all
;;; consequences, and they remove the resolvees prematurely.
;; (define resolution-1
;;   (rule `(and (?? and-ts-1) (or (?? or-1-ts-1) (? a) (?? or-1-ts-2))
;;           (?? and-ts-2) (or (?? or-2-ts-1) (not (? a)) (?? or-2-ts-2))
;;           (?? and-ts-3))
;;      `(and ,@and-ts-1 (or ,@or-1-ts-1 ,@or-1-ts-2 ,@or-2-ts-1 ,@or-2-ts-2)
;;            ,@and-ts-2 ,@and-ts-3)))

;; (define resolution-2
;;   (rule `(and (?? and-ts-1) (or (?? or-1-ts-1) (not (? a)) (?? or-1-ts-2))
;;           (?? and-ts-2) (or (?? or-2-ts-1) (? a) (?? or-2-ts-2))
;;           (?? and-ts-3))
;;      `(and ,@and-ts-1 (or ,@or-1-ts-1 ,@or-1-ts-2 ,@or-2-ts-1 ,@or-2-ts-2)
;;            ,@and-ts-2 ,@and-ts-3)))

;; (define do-resolution
;;   (iterated
;;    (in-order
;;     ->conjunctive-normal-form
;;     (term-rewriting resolution-1 resolution-2))))

;;; Sort order for expressions (useful for canonical forms of
;;; commutative operations)

(define (list<? x y)
  (let ((nx (length x)) (ny (length y)))
    (cond ((< nx ny) #t)
	  ((> nx ny) #f)
	  (else
	   (let lp ((x x) (y y))
	     (cond ((null? x) #f)	; same
		   ((expr<? (car x) (car y)) #t)
		   ((expr<? (car y) (car x)) #f)
		   (else (lp (cdr x) (cdr y)))))))))

(define expr<?
  (make-entity
   (lambda (self x y)
     (let per-type ((types (entity-extra self)))
       (if (null? types)
	   (error "Unknown expression type -- expr<?" x y)
	   (let ((predicate? (caar types))
		 (comparator (cdar types)))
	     (cond ((predicate? x)
		    (if (predicate? y)
			(comparator x y)
			#t))
		   ((predicate? y) #f)
		   (else (per-type (cdr types))))))))
   `((,null?    . ,(lambda (x y) #f))
     (,boolean? . ,(lambda (x y) (and (eq? x #t) (eq? y #f))))
     (,number?  . ,<)
     (,symbol?  . ,symbol<?)
     (,list?    . ,list<?))))

(define (sorted? lst <?)
  ;; Specifically, I am testing that a stable sort of lst by <? will
  ;; not change anything, that is, that there are no reversals where a
  ;; later item is <? an earlier one.
  (cond ((not (pair? lst)) #t)
        ((not (pair? (cdr lst))) #t)
        ((<? (cadr lst) (car lst)) #f)
        (else (sorted? (cdr lst) <?))))
