(ns sample.core
  (:require [clojure.string :as str]))

(def label-prefix "item")

(defn find-user [users user-id]
  (first (filter #(= (:id %) user-id) users)))

(defn divide [left right]
  (quot left right))

(defn label [name]
  (str label-prefix ":" name))

(defn normalize-name [name]
  (->> (str/split (str/lower-case (str/trim name)) #"\s+")
       (str/join " ")))

(defn active? [status]
  (= status "active"))

(defn admin? [role]
  (str/starts-with? role "admin"))
