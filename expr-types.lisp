;;;; kate: indent-width 4; replace-tabs yes; space-indent on;

(in-package fast-compute)

(defparameter *upper-type-cache* nil)

(defun propagate-upper-type (expr type)
    (let ((cur-type (gethash expr *upper-type-cache*)))
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
                    (`(ranging ,idx ,minv ,maxv ,@_)
                        (mark-list (list idx minv maxv) 'integer))
                    (`(,(or 'aref 'iref) ,arr ,@indices)
                        (mark-list (list arr) 'array)
                        (mark-list indices 'integer))
                    (`(,(or '+ '- '* '/ 'mod 'rem 'floor 'ceiling 'truncate 'setf '_grp) ,@rest)
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
                    (`(,(or 'let 'let*) ,_ ,@rest)
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
                    (`(,(or 'sin 'cos 'exp 'expt) ,@rest)
                        (mark-list rest 'float))
                    (`(_ ,@rest)
                        (mark-list rest nil)))))))

(defparameter *bottom-type-cache* nil)

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
                    (`(ranging ,ix ,minv ,maxv ,@_)
                        (get-bottom-type ix)
                        (get-bottom-type minv)
                        (get-bottom-type maxv)
                        'integer)
                    (`(,(or 'aref 'iref) ,arr ,@idxlst)
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
                    (`(arr-dim ,arr ,_)
                        (get-bottom-type arr)
                        'integer)
                    (`(setf ,target ,src)
                        (merge-types (list target src)))
                    (`(,(or '+ '- '* '/ 'floor 'ceiling '_grp) ,@rest)
                        (merge-types rest))
                    (`(,(or 'mod 'rem 'truncate) ,@rest)
                        (dolist (arg rest) (get-bottom-type arg))
                        'integer)
                    (`(,(or 'sin 'cos 'exp 'expt) ,@rest)
                        (dolist (arg rest) (get-bottom-type arg))
                        'float)
                    (`(if ,cond ,tb ,eb)
                        (get-bottom-type cond)
                        (merge-types (list tb eb)))
                    (`(,(or '> '< '>= '<= '/= '= 'and 'or) ,@rest)
                        (dolist (arg rest) (get-bottom-type arg))
                        'boolean)
                    (`(,(or 'let 'let*) ,_ ,@rest)
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
        (maphash
            #'(lambda (sub type)
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

(defun annotate-types (expr)
    (let ((types (derive-types expr)))
        (simplify-rec-once
            #'(lambda (expr old-expr)
                (match expr
                    (`(,(or 'let 'let*) ,@_)
                        nil)
                    (`(ranging ,@_)
                        old-expr)
                    (`(setf (the ,_ ,arg) ,tgt)
                        `(setf ,arg ,tgt))
                    (`(safety-check ,checks1 ,@body)
                        `(safety-check
                             ,(mapcar #'(lambda (new old)
                                            (cons (car new) (cdr old)))
                                  checks1 (second old-expr))
                             ,@body))
                    (_
                        (multiple-value-bind (type found) (gethash old-expr types)
                            (if found
                                (let ((tspec (match type
                                                ('float 'single-float)
                                                ('integer 'fixnum)
                                                ('boolean 'boolean)
                                                ('array 'array)
                                                ('nil 'single-float)
                                                (_ (error "Bad type ~A" type)))))
                                    `(the ,tspec ,expr))
                                expr)))))
            expr)))
