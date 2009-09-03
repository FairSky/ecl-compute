;;; -*- mode:lisp; indent-tabs-mode: nil; -*-

(in-package fast-compute)

(defparameter *upper-type-cache* nil)
(defparameter *bottom-type-cache* nil)

(defun propagate-upper-type (expr type)
  (let ((cur-type (gethash expr *upper-type-cache*)))
    (when (and (eql cur-type 'float) (eql type 'integer))
      (setf cur-type nil))
    (when (and cur-type type (not (eql cur-type type))
               (not (and (eql type 'float) (eql cur-type 'integer))))
      (error "Conflicting type requirement: ~A must be both ~A and ~A"
             expr type cur-type))
    (unless (or cur-type (numberp expr))
      (when type
        (setf (gethash expr *upper-type-cache*) type))

      (labels ((mark-list (subexprs subtype)
                 (dolist (e subexprs)
                   (recurse-factored #'propagate-upper-type e subtype))))
        (match expr
          ((type atom _) nil)
          (`(multivalue-data ,@_) nil)
          ((ranging-spec idx minv maxv _)
            (mark-list (list idx minv maxv) 'integer))
          (`(tmp-ref ,name)
            (mark-list (list name) 'float))
          (`(tmp-ref ,name ,@indices)
            (mark-list (list name) 'array)
            (mark-list indices 'integer))
          (`(texture-ref-int ,_ ,idx)
            (mark-list (list idx) 'integer))
          (`(texture-ref ,_ ,@indices)
            (mark-list indices 'float))
          (`(temporary ,_ ,dims ,@_)
            (mark-list dims 'integer))
          (`(,(or 'aref 'iref) ,arr ,@indices)
            (mark-list (list arr) 'array)
            (mark-list indices 'integer))
          (`(,(or '+ '- '* '/ 'mod 'rem 'min 'max
                  'floor 'ceiling 'truncate 'setf '_grp) ,@rest)
            (mark-list rest type))
          (`(,(or 'and 'or) ,@rest)
            (mark-list rest 'boolean))
          (`(ptr-deref ,ptr)
            (mark-list (list ptr) 'float-ptr))
          (`(ptr+ ,ptr ,idx)
            (mark-list (list ptr) 'float-ptr)
            (mark-list (list idx) 'integer))
          (`(,(or 'arr-dim 'arr-ptr) ,arr ,@_)
            (mark-list (list arr) 'array))
          (`(if ,cond ,@rest)
            (mark-list (list cond) 'boolean)
            (mark-list rest type))
          (`(,(or 'let 'let* 'symbol-macrolet) ,_ ,@rest)
            (mark-list (butlast rest) nil)
            (mark-list (last rest) type))
          (`(progn ,@rest)
            (mark-list (butlast rest) nil)
            (mark-list (last rest) type))
          (`(,(or '> '< '>= '<= '/= '= 'loop-range) ,@rest)
            (mark-list rest nil))
          (`(safety-check ,checks ,@rest)
            (mark-list (mapcar #'first checks) 'boolean)
            (mark-list rest nil))
          (`(,(or 'sin 'cos 'exp 'expt 'float-sign) ,@rest)
            (mark-list rest 'float))
          (`(_ ,@rest)
            (mark-list rest nil)))))))

(defun get-bottom-type-1 (expr)
  (use-cache (expr *bottom-type-cache*)
    (let ((upper-type (gethash expr *upper-type-cache*)))
      (labels ((merge-types (rest)
                 (let ((types (mapcar #'get-bottom-type rest)))
                   (when (find 'boolean types)
                     (error "Cannot do arithmetics with booleans: ~A" expr))
                   (when (find 'float-ptr types)
                     (error "Cannot do arithmetics with pointers: ~A" expr))
                   (cond
                     ((find 'float types) 'float)
                     ((every #'(lambda (tp) (eql tp 'integer)) types)
                      'integer)
                     (t nil)))))
        (match expr
          ((type float _) 'float)
          ((type integer _) 'integer)
          ((type symbol s) upper-type)
          (`(multivalue-data ,@_) 'array)
          ((ranging-spec ix minv maxv _)
            (get-bottom-type ix)
            (get-bottom-type minv)
            (get-bottom-type maxv)
            'integer)
          (`(,(or 'aref 'iref 'tmp-ref
                  'texture-ref 'texture-ref-int)
              ,arr ,@idxlst)
            (get-bottom-type arr)
            (dolist (idx idxlst) (get-bottom-type idx))
            'float)
          (`(ptr-deref ,ptr)
            (get-bottom-type ptr)
            'float)
          (`(ptr+ ,ptr ,idx)
            (get-bottom-type ptr)
            (get-bottom-type idx)
            'float-ptr)
          (`(arr-ptr ,arr)
            (get-bottom-type arr)
            'float-ptr)
          (`(arr-dim ,arr ,_ ,_)
            (get-bottom-type arr)
            'integer)
          (`(temporary ,_ nil ,@_)
            'float)
          (`(temporary ,@_)
            (if (eql upper-type 'float-ptr)
                'float-ptr
                'array))
          (`(setf ,target ,src)
            (merge-types (list target src)))
          (`(,(or '+ '- '* '/ 'min 'max 'floor 'ceiling '_grp) ,@rest)
            (merge-types rest))
          (`(,(or 'mod 'rem 'truncate) ,@rest)
            (dolist (arg rest) (get-bottom-type arg))
            'integer)
          (`(,(or 'sin 'cos 'exp 'expt 'float-sign) ,@rest)
            (dolist (arg rest) (get-bottom-type arg))
            'float)
          (`(if ,cond ,tb ,eb)
            (get-bottom-type cond)
            (merge-types (list tb eb)))
          (`(,(or '> '< '>= '<= '/= '= 'and 'or) ,@rest)
            (dolist (arg rest) (get-bottom-type arg))
            'boolean)
          (`(,(or 'let 'let* 'symbol-macrolet) ,_ ,@rest)
            (dolist (arg rest) (get-bottom-type arg))
            (merge-types (last rest)))
          (`(progn ,@rest)
            (dolist (arg rest) (get-bottom-type arg))
            (merge-types (last rest)))
          (`(,_ ,@rest)
            (dolist (arg rest) (get-bottom-type arg))
            nil)
          (_ nil))))))

(defun get-bottom-type (expr)
  (recurse-factored #'get-bottom-type-1 expr))

(defun derive-types (expr)
  (let ((*bottom-type-cache* (make-hash-table))
        (*upper-type-cache* (make-hash-table)))
    (propagate-upper-type expr nil)
    (apply-skipping-structure #'get-bottom-type expr nil)
    (maphash #'(lambda (sub type)
                 (let ((upper (gethash sub *upper-type-cache*)))
                   (when (and upper type (not (eql upper type))
                              (not (and (eql upper 'float)
                                        (eql type 'integer))))
                     (error "Type conflict: ~A is ~A, required ~A~%~A"
                            sub type upper expr))
                   ;; Help resolve comparison types
                   (when (and (consp sub)
                              (find (car sub) '(> < >= <= /= =)))
                     (let* ((subtypes (mapcar #'get-bottom-type (cdr sub)))
                            (rtype (if (find 'float subtypes) 'float 'integer)))
                       (dolist (arg (cdr sub))
                         (recurse-factored #'propagate-upper-type arg rtype))))
                   ;; Mark float divisions
                   (when (and (consp sub)
                              (eql (first sub) '/)
                              (symbolp (third sub))
                              (get (third sub) 'let-clause))
                     (incf-nil (get (third sub) 'fdiv-users)))
                   ;; Help resolve general arithmetics
                   (when (and type (not upper))
                     (propagate-upper-type sub type))))
             *bottom-type-cache*)
    (clrhash *bottom-type-cache*)
    (apply-skipping-structure #'get-bottom-type expr nil)
    *bottom-type-cache*))
