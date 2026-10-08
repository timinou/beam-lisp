;; decimal_oracle_gen.clj — regenerate/verify the JVM oracle corpus behind
;; `test/bl/decimal_oracle_port_test.bl`.
;;
;; That suite pins 1051 answers captured from `java.math.BigDecimal` (the
;; reference `BeamLisp.Decimal` models). This script is the fixture generator
;; the corpus would otherwise lose: it reads every row's FIRST column (the JVM
;; expression), evaluates it here on a real JVM, and fails if the printed result
;; differs from the third column (the pinned answer).
;;
;;     clojure -M scripts/decimal_oracle_gen.clj
;;
;; Exit 0 means every pinned answer is exactly the JVM's — the oracle is
;; reproducible from its own source of truth, not merely recorded.
;;
;; The single deliberate divergence (a negative-scale BigDecimal literal `1e3M`,
;; which beam-lisp reads as scale 0) is excluded from the corpus upstream; no
;; row here exercises it.

(ns decimal-oracle-gen
  (:require [clojure.edn :as edn]
            [clojure.string :as str])
  (:import [java.math BigDecimal RoundingMode]))

(def suite "test/bl/decimal_oracle_port_test.bl")

(defn- vector-at
  "The `[ … ]` literal beginning at or after `from`, bracket-matched with string
   literals respected. nil when no `[` is found."
  [text from]
  (when-let [start (str/index-of text "[" from)]
    (loop [i start depth 0 in-str? false esc? false]
      (when (< i (count text))
        (let [c (.charAt text i)]
          (cond
            in-str?
            (cond esc? (recur (inc i) depth true false)
                  (= c \\) (recur (inc i) depth true true)
                  (= c \") (recur (inc i) depth false false)
                  :else (recur (inc i) depth true false))

            (= c \") (recur (inc i) depth true false)
            (= c \[) (recur (inc i) (inc depth) false false)
            (= c \]) (if (= depth 1)
                       (subs text start (inc i))
                       (recur (inc i) (dec depth) false false))
            :else (recur (inc i) depth false false)))))))

(defn- chunk-vectors
  "Every `(def ^:private rows-<N> [ … ])` vector, ordered by N. The suite chunks
   the corpus because one 1051-element literal overran the BEAM validator."
  [text]
  (->> (re-seq #"\(def \^:private rows-(\d+)" text)
       (map (fn [[m n]]
              [(Integer/parseInt n) (vector-at text (+ (str/index-of text m) (count m)))]))
       (sort-by first)
       (map second)
       (remove nil?)))

(defn- rows
  [text]
  (->> (chunk-vectors text) (mapcat edn/read-string) vec))

(defn- jvm-answer
  "The oracle's answer for one JVM expression, as text — `str` of the evaluated
   value, exactly as the capture recorded it."
  [expr]
  (try
    (str (eval (read-string expr)))
    (catch ArithmeticException _ "ERR")))

(defn -main [& _]
  (let [rows (rows (slurp suite))
        bad  (for [[jvm _ expected] rows
                   :let [got (jvm-answer jvm)]
                   :when (not= got expected)]
               [jvm expected got])]
    (println (format "decimal oracle: %d rows checked against the JVM." (count rows)))
    (if (empty? bad)
      (println "OK — every pinned answer is the JVM's.")
      (do
        (println (format "FAIL — %d row(s) diverge:" (count bad)))
        (doseq [[jvm expected got] bad]
          (println (format "  %s\n    pinned: %s\n    jvm:    %s" jvm expected got)))
        (System/exit 1)))))

(-main)
