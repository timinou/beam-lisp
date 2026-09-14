(ns acme.money
  "A cross-platform money type, written for the JVM and ClojureScript.
   This file is UNMODIFIED Clojure: `:import`, `#?(:clj …)`, `.method`
   interop, `M` literals, `^BigDecimal` hints and `defonce` all appear."
  (:refer-clojure :exclude [zero?])
  (:require [clojure.string :as str])
  #?(:clj (:import [java.math BigDecimal RoundingMode])))

(defrecord Money [amount currency])

(defonce ^:private default-scale 2)

(defn- coerce [x]
  #?(:clj  (cond (instance? BigDecimal x) x
                 (integer? x) (BigDecimal/valueOf (long x))
                 (string? x) (BigDecimal. ^String x)
                 :else (throw (ex-info "not exact" {:value x})))
     :cljs (js/Number x)))

(defn money [amount currency] (->Money (coerce amount) currency))

(defn add [^Money a ^Money b]
  (when-not (= (:currency a) (:currency b))
    (throw (ex-info "currency mismatch" {:a a :b b})))
  (->Money #?(:clj (.add ^BigDecimal (:amount a) ^BigDecimal (:amount b))
              :cljs (+ (:amount a) (:amount b)))
           (:currency a)))

(defn round
  ([m] (round m default-scale))
  ([m scale]
   (->Money #?(:clj (.setScale ^BigDecimal (:amount m) (int scale) RoundingMode/HALF_EVEN)
               :cljs (:amount m))
            (:currency m))))

(defn allocate
  "Split `m` into parts by `ratios`, largest-remainder, sum exact."
  [m ratios]
  (let [total (reduce + 0 ratios)
        amt ^BigDecimal (:amount m)
        shares (mapv (fn [r] (.divide (.multiply amt (BigDecimal/valueOf (long r)))
                                       (BigDecimal/valueOf (long total)) 2 RoundingMode/DOWN))
                     ratios)
        rem (.subtract amt (reduce (fn [^BigDecimal a ^BigDecimal b] (.add a b)) 0M shares))
        cents (.longValue (.movePointRight rem 2))]
    (mapv (fn [i s] (->Money (if (< i cents) (.add s 0.01M) s) (:currency m)))
          (range) shares)))

(defn zero? [m] (= 0 (.signum ^BigDecimal (:amount m))))

(defn ->str [m] (str (.toPlainString ^BigDecimal (:amount m)) " " (str/upper-case (name (:currency m)))))
