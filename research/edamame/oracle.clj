;; oracle.clj — edamame as an external oracle for beam-lisp's reader.
;;
;; edamame (borkdude) is the Clojure world's configurable EDN/Clojure reader:
;; one options map, positions on the values, errors as data, forms one at a
;; time. It is NOT a dependency here (it needs a JVM, and a second reader would
;; be a second truth), but it is a useful third party to measure against — and
;; babashka ships it built in, so the oracle costs no setup.
;;
;;   bb research/edamame/oracle.clj rows        # the case corpus, as EDN
;;   bb research/edamame/oracle.clj scan DIR…   # every .bl under DIR, positioned
;;
;; rows emits, per case, a form a beam-lisp test can assert against:
;;   {:id … :ok true  :forms "…"}
;;   {:id … :ok false :error {:row … :col … :expected … :opened … :opened-loc …}}
;; Cases labelled :dialect are ones a Clojure reader and beam-lisp's MUST
;; disagree on, so a conformance run skips them deliberately.
;;
;; scan reads every .bl file once. Each refusal gets the reader's own error
;; data AND an independent balance verdict (nesting depth, strings / semicolon
;; comments / character literals respected) — the two answer different
;; questions, and only an imbalance is a defect in the tree. This is the check
;; that found priv/lib/web.bl:479 on 2026-09-20.
;;
;; The code spells characters by code point (BACKSLASH 92, QUOTE 34, NEWLINE
;; 10) on purpose: a file ABOUT a reader, written in a reader's escape syntax,
;; is a good way to write a file the reader cannot read.

(require '[edamame.core :as e]
         '[clojure.java.io :as io]
         '[clojure.string :as str])

(def BACKSLASH 92)
(def QUOTE 34)
(def NEWLINE 10)
(def SEMI 59)
(def OPEN {123 125, 91 93, 40 41})
(def CLOSE {125 123, 93 91, 41 40})

(def opts
  {:all true
   :read-cond :allow
   :features #{:clj}
   :readers {'d (fn [x] x), 'time (fn [x] x), 'inst (fn [x] x), 'uuid (fn [x] x)}})

(def cases
  [{:id :location-seq-only :group :location :src "[1 {:a 2}]"}
   {:id :location-every-node :group :location :src "[1 {:a 2}]" :locations true
       :opts {:location? (constantly true) :end-location true}}
   {:id :error-expected-delimiter :group :error :src "{:a (let [x 5"}
   {:id :error-mismatched-closer :group :error :src "[1 2)"}
   {:id :stream-two-forms :group :stream :stream "(a b) :after"}
   {:id :stream-form-and-source :group :stream
    :stream (str "(defn f [x]" (char NEWLINE) "  ;; c" (char NEWLINE) "  (inc x)) 42")}
   {:id :read-cond-preserve :group :options :src "[1 #?(:cljs :x :clj :y)]"
    :opts {:read-cond :preserve}}
   {:id :read-cond-select-cljs :group :options :src "[1 #?(:cljs :x :clj :y)]"
    :opts {:features #{:cljs}}}
   {:id :read-eval-refused :group :options :src "#=(+ 1 2)"
    :opts {:read-eval false}}
   {:id :read-eval-opt-in :group :options :src "#=(+ 1 2)" :opts {:read-eval true}}
   {:id :auto-resolve-ns :group :options
    :src-all "(ns foo (:require [clojure.set :as set])) ::set/foo"
    :opts {:auto-resolve-ns true}}
   {:id :fn-literal-deterministic :group :options :src "#(* % %1 %2)" :opts {:fn true}}
   {:id :dialect-slash-eq :group :dialect :src "erlang/=/="}
   {:id :dialect-plus-arrow :group :dialect :src "+1→inc"}
   ;; a STRING escape that Clojure's edn reader refuses and ours accepts
   {:id :dialect-string-escape :group :dialect
    :src (str (char QUOTE) (char BACKSLASH) "(" (char QUOTE))}
   ;; a bare `::` — refused unless :auto-resolve is supplied (see :auto-resolve-ns)
   {:id :dialect-unresolvable-kw :group :dialect :src "::"}])

(defn- failed [id group ex]
  (let [d (ex-data ex)]
    {:id id :group group :ok false
     :error (cond-> {:message (ex-message ex)}
              (:row d) (assoc :row (:row d) :col (:col d))
              (:edamame/expected-delimiter d)
              (assoc :expected (:edamame/expected-delimiter d)
                     :opened (:edamame/opened-delimiter d)
                     :opened-loc (:edamame/opened-delimiter-loc d)))}))

(defn- row
  [{id :id group :group src :src src-all :src-all stream :stream locations :locations o :opts}]
  (let [o (merge opts o)]
    (try
      (cond stream
            {:id id :group group :ok true
             :stream (vec (let [r (e/source-reader stream)]
                            (loop [acc []]
                              (let [v (e/parse-next+string r o)]
                                ;; the EOF answer is the VECTOR [:edamame.core/eof ""]
                                (if (= :edamame.core/eof (first v)) acc (recur (conj acc v)))))))}
            src-all {:id id :group group :ok true
                     :forms (pr-str (e/parse-string-all src-all o))}
            locations {:id id :group group :ok true
                       :locations (pr-str (map meta (tree-seq coll? seq (e/parse-string src o))))}
            :else {:id id :group group :ok true
                   :forms (pr-str (e/parse-string-all src o))})
      (catch Exception ex (failed id group ex)))))

(defn rows [& _] (doseq [r (map row cases)] (prn r)))

(defn balanced?
  "The first place `s` stops balancing, or nil. Strings, semicolon comments and
   character literals are honoured, so this answers for the SOURCE, not for any
   particular reader's tokenizer."
  [s]
  (loop [cs (seq s), line 1, col 0, stack []]
    (if (nil? cs)
      (when (seq stack)
        (let [[c l k] (peek stack)] {:kind :unclosed :line l :col k :char (str (char c))}))
      (let [c (int (first cs))]
        (cond
          (= c NEWLINE) (recur (next cs) (inc line) 0 stack)
          (= c SEMI) (recur (drop-while #(not= (int %) NEWLINE) cs) line col stack)
          (and (= c BACKSLASH) (next cs)) (recur (nnext cs) line (+ col 2) stack)
          (= c QUOTE) (recur (loop [r (next cs)]
                               (cond (nil? r) nil
                                     (= (int (first r)) BACKSLASH) (recur (nnext r))
                                     (= (int (first r)) QUOTE) (next r)
                                     :else (recur (next r))))
                             line col stack)
          (contains? OPEN c) (recur (next cs) line (inc col) (conj stack [c line (inc col)]))
          (contains? CLOSE c)
          (if (empty? stack)
            {:kind :unmatched-close :line line :col (inc col) :char (str (char c))}
            (let [[o ol oc] (peek stack)]
              (if (= o (CLOSE c))
                (recur (next cs) line (inc col) (pop stack))
                {:kind :mismatch :line line :col (inc col) :char (str (char c))
                 :opened-line ol :opened-col oc :opened (str (char o))})))
          :else (recur (next cs) line (inc col) stack))))))

(defn- bl-files [roots]
  (->> roots
       (map io/file)
       (filter #(.exists ^java.io.File %))
       (mapcat file-seq)
       (filter #(.isFile ^java.io.File %))
       (remove #(re-find #"/_build/|/\.git/|/\.bl/" (str %)))
       (filter #(str/ends-with? (str %) ".bl"))
       sort))

(defn scan [& roots]
  (let [fs (bl-files (if (seq roots) roots ["."]))
        bad (reduce (fn [acc f]
                      (let [s (slurp f)]
                        (try (doall (e/parse-string-all s opts)) acc
                             (catch Exception ex
                               (let [bal (balanced? s)]
                                 (conj acc (cond-> (assoc (failed (str f) :file ex)
                                                          :balanced (nil? bal))
                                             bal (assoc :imbalance bal))))))))
                    [] fs)]
    (println (format "scan: %d files read, %d refused" (count fs) (count bad)))
    (doseq [f bad] (prn f))
    (let [real (filter :imbalance bad)]
      (println (format "unbalanced (a defect in the source): %d" (count real)))
      (doseq [f real] (println "  " (:id f) (pr-str (:imbalance f))))
      (System/exit (if (seq real) 1 0)))))

(let [[mode & args] *command-line-args*]
  (case mode
    "rows" (apply rows args)
    "scan" (apply scan args)
    (do (println "usage: bb research/edamame/oracle.clj rows | scan DIR…")
        (System/exit 2))))
