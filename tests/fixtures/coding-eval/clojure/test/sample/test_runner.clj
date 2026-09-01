(ns sample.test-runner
  (:require [clojure.test :as test]
            [sample.core-test]))

(defn- resolve-test [name]
  (or (ns-resolve 'sample.core-test (symbol name))
      (throw (ex-info "Unknown test" {:name name}))))

(defn -main [& [name]]
  (try
    (let [counters (ref test/*initial-report-counters*)]
      (binding [test/*report-counters* counters]
        (test/test-vars [(resolve-test name)]))
      (let [{:keys [fail error]} @counters]
        (shutdown-agents)
        (System/exit (if (zero? (+ fail error)) 0 1))))
    (catch Exception exception
      (binding [*out* *err*]
        (println (.getMessage exception)))
      (shutdown-agents)
      (System/exit 2))))
