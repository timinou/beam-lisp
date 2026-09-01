# Payroll fixture

A document that IS a namespace.

```beam-lisp
(ns docx.payroll)

(defn gross [rate hours]
  (* rate hours))

(defn net [rate hours]
  (* 0.8 (gross rate hours)))
```

Frozen history:

```beam-lisp id=record frozen
:payroll-v1
```

```bl-result record
:payroll-v1
```
