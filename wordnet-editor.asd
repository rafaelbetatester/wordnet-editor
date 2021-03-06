;; (C) 2013 IBM Corporation
;;
;;  Author: Alexandre Rademaker
;;
;; For info why the dependencies file is necessary, read
;; http://weitz.de/packages.html

(asdf:defsystem #:wordnet-editor
  :serial t
  :depends-on (:agclient :cl-ppcre :fare-csv :solr :alexandria :chillax :yason :split-sequence)
  :components ((:file "packages")
	       (:file "ag-init"       :depends-on ("packages"))
	       (:file "utils"         :depends-on ("packages"))
	       (:file "omw"           :depends-on ("utils"))
	       (:file "backend"       :depends-on ("utils"))
	       (:file "solr"          :depends-on ("utils"))
	       (:file "export"        :depends-on ("utils"))
	       (:file "couchdb"       :depends-on ("solr"))
	       (:file "deduplication" :depends-on ("utils"))
	       (:file "suggestions"   :depends-on ("backend"))
	       (:file "wordsenses"    :depends-on ("backend"))
	       (:file "words"         :depends-on ("backend"))
	       (:file "nomlex-rdf"    :depends-on ("backend"))
	       (:file "solr-to-ag"    :depends-on ("backend"))
	       (:file "cstnews"       :depends-on ("backend"))))
