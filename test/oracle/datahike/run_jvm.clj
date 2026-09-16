;; The JVM oracle for the datahike↔datom differential.
;;
;; Reads corpus.edn, runs every scenario (ready AND pending) against published
;; datahike, and writes expected.edn — engine-neutral encoded answers that the
;; beam-lisp side compares against. Run:
;;
;;   clojure -Sdeps '{:deps {org.replikativ/datahike {:mvn/version "0.8.1861"}}}' \
;;           -M test/oracle/datahike/run_jvm.clj
;;
;; The captured answers are COMMITTED, so the beam-lisp gate needs no JVM. Only
;; re-run this when the corpus gains a scenario or a read.

(ns run-jvm
  (:require [datahike.api :as d]
            [clojure.edn :as edn]
            [clojure.pprint :as pp])
  (:import [java.math BigDecimal]))

(def here "test/oracle/datahike")

;; ── engine-neutral encoding ──────────────────────────────────────────────
;; A datom/decimal or a datahike bigdec both encode to a tagged string so the
;; two engines' native decimal reprs never need to match structurally — only
;; their meaning does. Refs to {:db/id N} are already maps; ids are compared
;; only via unique attrs, never positionally, so entity drops :db/id.

(defn enc [v]
  (cond
    (instance? BigDecimal v) {:dec (.toPlainString v)}
    (map? v)                 (into (sorted-map) (map (fn [[k x]] [k (enc x)])) v)
    (set? v)                 (vec (sort-by pr-str (map enc v)))
    (sequential? v)          (mapv enc v)
    :else                    v))

(defn sorted-tuples [result]
  (vec (sort-by pr-str (map (fn [t] (mapv enc t)) result))))

(defn fresh-conn [schema]
  (let [cfg {:store {:backend :memory :id (random-uuid)}
             :keep-history? true
             :schema-flexibility :write}]
    (d/create-database cfg)
    (let [conn (d/connect cfg)]
      (when (seq schema) (d/transact conn (vec schema)))
      conn)))

(defn run-read [conn {:keys [kind query pattern eid] :as _read}]
  (let [db (d/db conn)]
    (case kind
      :q      (let [r (d/q query db)]
                (cond
                  (set? r)        (sorted-tuples r)
                  (sequential? r) (vec (sort-by pr-str (map enc r)))  ; collection find
                  :else           (enc r)))                          ; scalar find
      :pull   (enc (d/pull db pattern eid))
      :entity (let [e (d/entity db eid)]
                (enc (into (sorted-map) (dissoc (into {} e) :db/id))))
      :datoms (sorted-tuples (map (fn [dt] [(:e dt) (:a dt) (:v dt)]) (d/datoms db :eavt))))))

(defn run-scenario [{:keys [name schema txes reads] :as _sc}]
  (try
    (let [conn (fresh-conn schema)]
      (doseq [tx txes] (d/transact conn tx))
      [name (into (sorted-map)
                  (map (fn [{:keys [id] :as rd}]
                         [id (try (run-read conn rd)
                                  (catch Throwable e {:error true :msg (.getMessage e)}))]))
                  reads)])
    (catch Throwable e
      [name {:error true :msg (.getMessage e)}])))

(defn -main [& _]
  (let [corpus (edn/read-string {:readers {}} (slurp (str here "/corpus.edn")))
        answers (into (sorted-map)
                      (map run-scenario)
                      (:scenarios corpus))
        out {:version (:version corpus)
             :datahike "0.8.1861"
             :answers answers}]
    (spit (str here "/expected.edn")
          (with-out-str (pp/pprint out)))
    (println "wrote" (str here "/expected.edn") "—" (count answers) "scenarios")))

(-main)
