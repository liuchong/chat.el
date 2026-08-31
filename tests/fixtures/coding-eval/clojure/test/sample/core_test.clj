(ns sample.core-test
  (:require [clojure.test :refer :all]
            [sample.core :as sample]))

(deftest divide-test
  (is (= 5/2 (sample/divide 5 2)))
  (is (thrown? IllegalArgumentException (sample/divide 1 0))))

(deftest label-test
  (is (= "entry:alpha" (sample/label "alpha"))))

(deftest normalize-test
  (is (= "alpha beta" (sample/normalize-name "  Alpha   BETA "))))

(deftest active-test
  (is (sample/active? {:state "active"}))
  (is (not (sample/active? {:state "paused"}))))
