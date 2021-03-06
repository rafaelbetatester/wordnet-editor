
(in-package :wordnet)

(defparameter *solr* (make-instance 'solr:solr :uri "http://localhost:8983/solr/wn"))
(defparameter *solr-pointers* (make-instance 'solr:solr :uri "http://localhost:8983/solr/pointers"))

(defparameter *debug-load-pointers* nil)

(defun synset-to-alist (addr &key (suffix "en") (data nil) (plan nil))
  (labels ((tostr (apart regex replacement)
	     (multiple-value-bind (val type extra)
		 (upi->value apart)
	       (declare (ignore val extra))
	       (if (equal 0 type)
		   (cl-ppcre:regex-replace regex (part->string apart :format :concise) replacement)
		   (cl-ppcre:regex-replace regex (part->value apart) replacement))))
	   (adj-name (name)
	     (cond 
	       ((cl-ppcre:scan "^word" name) 
		(intern (format nil "~a_~a" name suffix) :keyword))
	       ((cl-ppcre:scan "example" name)
		(intern (format nil "example_~a" suffix) :keyword))
	       ((cl-ppcre:scan "gloss" name)
		(intern (format nil "gloss_~a" suffix) :keyword))
	       (t (intern name :keyword)))))
    (let* ((synset (resource (concatenate 'string "synset-" addr) 
			     (concatenate 'string "wn30" suffix)))
	   (words (mapcar (lambda (w) (part->value (car w))) 
			  (sparql:run-sparql plan 
					     :with-variables `((?synset . ,synset))
					     :engine :sparql-1.1 :results-format :lists)))
	   (query (get-triples :s synset)))
      (do ((res (or data (list (cons :id addr))))
	   (a-triple (cursor-next-row query)
		     (cursor-next-row query)))
	  ((null a-triple)
	   (if words (push (cons (adj-name "word") words) res))
	   (push (cons (adj-name "word_count") (length words)) res)
	   res)
	(cond
	  ((part= (predicate a-triple) !owl:sameAs)
	   (setf res (synset-to-alist addr :suffix "pt" :data res :plan plan)))
	  ((not (member (predicate a-triple) (list !skos:inScheme !wn30:containsWordSense) :test #'part=)) 
	   (let ((key (adj-name (tostr (predicate a-triple) ":" "_")))
		 (val (tostr (object a-triple) "^wn30(en|br)?:(synset-)?" "")))
	     (push (cons key val) res))))))))


(defun nomlex-to-alist (addr)
  (labels ((tostr (apart regex replacement)
	     (multiple-value-bind (val type extra)
		 (upi->value apart)
	       (declare (ignore val extra))
	       (if (equal 0 type)
		   (cl-ppcre:regex-replace regex (part->string apart :format :concise) replacement)
		   (cl-ppcre:regex-replace regex (part->value apart) replacement)))))
    (let ((query (get-triples :s addr)))
      (do ((res (list (cons :id (part->string addr :format :concise))))
	   (a-triple (cursor-next-row query)
		     (cursor-next-row query)))
	  ((null a-triple)
	   res)
	(let ((key (intern (tostr (predicate a-triple) ":" "_") :keyword)))
	  (if (member (predicate a-triple) '(!nomlex:noun !nomlex:verb) :test #'part=)
	      (let ((val (object (get-triple :s (object a-triple) :p !wn30:lexicalForm))))
		(push (cons key (part->value val)) res))
	      (push (cons key (tostr (object a-triple) "^nomlex:" "")) res)))))))


(defun load-nomlex-solr (blocksize)
  (let* ((current 0) 
	 (total 0)
	 (block-tmp nil)
	 (query (get-triples :p !rdf:type :o !nomlex:Nominalization))) 
    (do* ((a-triple (cursor-next-row query)
		    (cursor-next-row query)))
	 ((null a-triple)
	  (solr:solr-add* *solr* block-tmp :commit t))
      (format *debug-io* "Processing ~a [~a/~a ~a]~%"
	      (part->string (subject a-triple)) current blocksize total)
      (push (remove-duplicates (nomlex-to-alist (subject a-triple)) :test #'equal)
	    block-tmp)
      (setf current (1+ current))
      (if (> current blocksize)
	  (progn
	    (solr:solr-add* *solr* block-tmp :commit t)
	    (setf total (+ total current)
		  current 0
		  block-tmp nil))))))

(defun load-synsets-solr (blocksize)
  (let* ((current 0) 
	 (total 0)
	 (block-tmp nil)
	 (plan-words (sparql:parse-sparql (query-string "synset-words.sparql")))
	 (synsets (sparql:run-sparql (sparql:parse-sparql (query-string "all-synsets.sparql")) 
				     :results-format :lists))) 
    (dolist (p synsets)
      (let ((id (cl-ppcre:regex-replace "^wn30en:synset-"
					(part->string (car p) :format :concise) "")))
	(format *debug-io* "Processing ~a [~a/~a ~a]~%"
		id current blocksize total)
	(push (remove-duplicates (synset-to-alist id :plan plan-words) :test #'equal) block-tmp)
	(setf current (1+ current))
	(if (> current blocksize)
	    (progn
	      (solr:solr-add* *solr* block-tmp :commit t)
	      (setf total (+ total current)
		    current 0
		    block-tmp nil)))))
    (solr:solr-add* *solr* block-tmp :commit t)))

(defun link-to-alist (params &key type)
  (case type 
    (:synset
       (pairlis '(:source_synset :pointer :target_synset)
                (mapcar #'part->value params)))
    (:wordsense
       (pairlis '(:source_synset :source_word :pointer :target_synset :target_word)
                (mapcar #'part->value params)))
    (:nomlex
        (pairlis '(:source_word :pointer :target_word)
                 (mapcar #'part->value params)))))

(defun load-pointers (blocksize)
  (let* ((current 0) 
	 (total 0)
	 (block-tmp nil)
         (queries (pairlis '(:synset :wordsense :nomlex) 
                           '("all-synset-links.sparql" "all-wordsense-links.sparql" "all-nomlex-links.sparql"))))
    (dolist (q queries)
      (let ((result (sparql:run-sparql 
                     (sparql:parse-sparql (query-string (cdr q))
                                          (alexandria:alist-hash-table (collect-namespaces)))
                     :results-format :lists)))
        (dolist (l result)
          (when *debug-load-pointers* (format *debug-io* "Processing (~{~a~^,~}) [~a/~a ~a]~%"  l current blocksize total))
          (push (link-to-alist l :type (car q)) block-tmp)
          (setf current (1+ current))
          (if (> current blocksize)
              (progn
                (solr:solr-add* *solr-pointers* block-tmp :commit t)
                (setf total (+ total current)
                      current 0
                      block-tmp nil))))
        (solr:solr-add* *solr-pointers* block-tmp :commit t)))))

