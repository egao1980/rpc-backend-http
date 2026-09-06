(in-package #:rpc-backend-http)

(defclass http-rpc-transport (rpc-protocol:rpc-transport)
  ((url :initarg :url :initform nil :accessor transport-url)
   (next-id :initform 0 :accessor transport-next-id)
   (headers :initarg :headers :initform nil :accessor transport-headers
            :documentation "Extra request headers (alist). Precedence over defaults.")))

(defun make-http-rpc-transport (&key url headers)
  (make-instance 'http-rpc-transport :url url :headers headers))

(defun use-http-rpc-transport (&key url headers)
  (setf rpc-protocol:*rpc-transport*
        (make-http-rpc-transport :url url :headers headers)))

(defun %request-headers (transport &key (accept "application/json"))
  "Defaults after extras. :ACCEPT wins over a transport-headers Accept."
  (let ((extras (remove "accept" (transport-headers transport)
                        :key #'car :test #'string-equal)))
    (append extras
            `(("content-type" . "application/json")
              ("accept" . ,accept)))))

(defun %ensure-http-backend ()
  (unless http-protocol:*http-backend*
    (error 'rpc-protocol:rpc-error
           :message "*http-backend* is nil — bind an http-protocol backend"
           :code rpc-protocol:+internal-error+)))

(defgeneric http-rpc-request-url (transport method)
  (:documentation "URL for METHOD on TRANSPORT. Default is TRANSPORT-URL.")
  (:method ((transport http-rpc-transport) method)
    (declare (ignore method))
    (or (transport-url transport)
        (error 'rpc-protocol:rpc-error
               :message "http RPC transport has no :url"
               :code rpc-protocol:+internal-error+))))

(defgeneric http-rpc-encode-body (transport method params &key id notify)
  (:documentation "Serialize the POST body. Default is JSON-RPC 2.0.")
  (:method ((transport http-rpc-transport) method params &key id notify)
    (if notify
        (rpc-protocol:encode-notification method params)
        (rpc-protocol:encode-request method params :id (or id 1)))))

(defgeneric http-rpc-decode-event (transport event)
  (:documentation "Decode one SSE event's data. Default is a JSON-RPC result.")
  (:method ((transport http-rpc-transport) event)
    (%raise-rpc (rpc-protocol:decode-message
                 (or (sse-protocol:sse-event-data event) "")))))

(defun %octets-to-string (octets)
  (babel:octets-to-string octets :encoding :utf-8))

(defun %slurp-stream (stream)
  (if (and (open-stream-p stream)
           (ignore-errors
             (let ((et (stream-element-type stream)))
               (and et (subtypep et 'character)))))
      (with-output-to-string (out)
        (loop for c = (read-char stream nil :eof)
              until (eq c :eof)
              do (write-char c out)))
      (let ((bytes (make-array 0 :element-type '(unsigned-byte 8)
                                  :adjustable t :fill-pointer 0)))
        (loop for b = (read-byte stream nil :eof)
              until (eq b :eof)
              do (vector-push-extend b bytes))
        (%octets-to-string bytes))))

(defun slurp-env-body (env)
  (let ((raw (getf env :raw-body)))
    (cond
      ((null raw) "")
      ((stringp raw) raw)
      ((and (vectorp raw) (not (stringp raw)))
       (%octets-to-string raw))
      ((streamp raw) (%slurp-stream raw))
      (t (princ-to-string raw)))))

(defun %body-string (response)
  (let ((b (http-protocol:response-body response)))
    (cond
      ((stringp b) b)
      ((and (vectorp b) (not (stringp b)))
       (%octets-to-string b))
      ((streamp b) (%slurp-stream b))
      (t ""))))

(defun %raise-rpc (msg)
  (let ((err (gethash "error" msg)))
    (if err
        (error 'rpc-protocol:rpc-error
               :code (or (gethash "code" err) rpc-protocol:+internal-error+)
               :message (gethash "message" err)
               :data (gethash "data" err))
        (gethash "result" msg))))

(defun %dispatch (handler body)
  (let ((msg (rpc-protocol:decode-message body)))
    (let ((method (gethash "method" msg))
          (params (gethash "params" msg))
          (id (gethash "id" msg)))
      (unless method
        (return-from %dispatch
          (rpc-protocol:encode-error-response
           rpc-protocol:+invalid-request+ "missing method" :id id)))
      (handler-case
          (let ((result (funcall handler method params)))
            (if id
                (rpc-protocol:encode-response result :id id)
                ""))
        (rpc-protocol:rpc-error (c)
          (rpc-protocol:encode-error-response
           (rpc-protocol:rpc-error-code c)
           (or (rpc-protocol:rpc-error-message c) "rpc error")
           :id id :data (rpc-protocol:rpc-error-data c)))
        (error (c)
          (rpc-protocol:encode-error-response
           rpc-protocol:+internal-error+ (format nil "~a" c) :id id))))))

(defun make-rpc-app (handler &key (path nil))
  "Clack app: POST application/json JSON-RPC → JSON response."
  (lambda (env)
    (block app
      (when (and path (not (string= (or (getf env :path-info) "/") path)))
        (return-from app
          '(404 (:content-type "text/plain") ("not found"))))
      (unless (eq (getf env :request-method) :post)
        (return-from app
          '(405 (:content-type "text/plain" :allow "POST") ("POST only"))))
      (list 200
            '(:content-type "application/json; charset=utf-8")
            (list (%dispatch handler (slurp-env-body env)))))))

(defun make-rpc-stream-app (handler &key (path nil))
  "Clack app: POST JSON-RPC → text/event-stream of JSON-RPC results.
   HANDLER may return a list of results (one SSE event each)."
  (lambda (env)
    (block app
      (when (and path (not (string= (or (getf env :path-info) "/") path)))
        (return-from app
          '(404 (:content-type "text/plain") ("not found"))))
      (unless (eq (getf env :request-method) :post)
        (return-from app
          '(405 (:content-type "text/plain" :allow "POST") ("POST only"))))
      (let* ((body (slurp-env-body env))
             (msg (rpc-protocol:decode-message body))
             (method (gethash "method" msg))
             (params (gethash "params" msg))
             (id (gethash "id" msg)))
        (unless method
          (return-from app
            (list 200 '(:content-type "application/json; charset=utf-8")
                  (list (rpc-protocol:encode-error-response
                         rpc-protocol:+invalid-request+ "missing method"
                         :id id)))))
        (handler-case
            (let* ((result (funcall handler method params))
                   (events (if (and result (listp result))
                               result
                               (list result))))
              (list 200
                    '(:content-type "text/event-stream; charset=utf-8"
                      :cache-control "no-cache")
                    (list (apply #'concatenate 'string
                                 (mapcar (lambda (ev)
                                           (sse-protocol:encode-sse-event
                                            (sse-protocol:make-sse-event
                                             :data (rpc-protocol:encode-response
                                                    ev :id (or id 1)))))
                                         events)))))
          (rpc-protocol:rpc-error (c)
            (list 200
                  '(:content-type "application/json; charset=utf-8")
                  (list (rpc-protocol:encode-error-response
                         (rpc-protocol:rpc-error-code c)
                         (or (rpc-protocol:rpc-error-message c) "rpc error")
                         :id id :data (rpc-protocol:rpc-error-data c))))))))))

(defun %ensure-http-server ()
  (or http-server-protocol:*http-server-backend*
      (progn
        (asdf:load-system "http-server-backend-hunchentoot")
        (funcall (find-symbol "USE-HUNCHENTOOT-BACKEND"
                              :http-server-backend-hunchentoot)))))

(defmethod rpc-protocol:backend-rpc-call
    ((transport http-rpc-transport) method params &key timeout id)
  (%ensure-http-backend)
  (let* ((id (or id (incf (transport-next-id transport))))
         (res (apply #'http:post (http-rpc-request-url transport method)
                     :content (http-rpc-encode-body transport method params :id id)
                     :headers (%request-headers transport)
                     (when timeout (list :timeout timeout)))))
    (unless (<= 200 (http-protocol:response-status res) 299)
      (error 'rpc-protocol:rpc-error
             :message (format nil "HTTP ~a" (http-protocol:response-status res))
             :code rpc-protocol:+internal-error+))
    (%raise-rpc (rpc-protocol:decode-message (%body-string res)))))

(defmethod rpc-protocol:backend-rpc-notify
    ((transport http-rpc-transport) method params)
  (%ensure-http-backend)
  (http:post (http-rpc-request-url transport method)
             :content (http-rpc-encode-body transport method params :notify t)
             :headers (%request-headers transport))
  t)

(defclass http-rpc-stream (rpc-protocol:rpc-stream)
  ((queue :initarg :queue :initform nil :accessor http-rpc-stream-queue)
   (close-fn :initarg :close-fn :initform nil :accessor http-rpc-stream-close-fn)))

(defun %close-http-response (response)
  (ignore-errors
    (http-protocol:release-response-connection response :abort t)))

(defun %event-stream-p (response)
  (let ((ctype (http-protocol:response-header response "content-type")))
    (and (stringp ctype)
         (search "text/event-stream" ctype :test #'char-equal))))

(defun %collect-sse-results (transport response)
  (let ((out '()))
    (sse-protocol:map-sse-events
     (lambda (ev)
       (push (http-rpc-decode-event transport ev) out))
     (http-protocol:body-stream response))
    (nreverse out)))

(defmethod rpc-protocol:backend-rpc-call-stream
    ((transport http-rpc-transport) method params &key timeout id metadata)
  (declare (ignore metadata))
  (%ensure-http-backend)
  (let* ((id (or id (incf (transport-next-id transport))))
         (res (apply #'http:post (http-rpc-request-url transport method)
                     :content (http-rpc-encode-body transport method params :id id)
                     :headers (%request-headers transport
                                                :accept "text/event-stream")
                     :want-stream t
                     :accept-encoding nil
                     :decompress nil
                     (when timeout (list :timeout timeout))))
         (status (http-protocol:response-status res)))
    (unless (<= 200 status 299)
      (%close-http-response res)
      (error 'rpc-protocol:rpc-error
             :message (format nil "HTTP ~a" status)
             :code rpc-protocol:+internal-error+))
    (if (%event-stream-p res)
        (let ((queue (unwind-protect
                          (%collect-sse-results transport res)
                       (%close-http-response res))))
          (make-instance 'http-rpc-stream
                         :transport transport
                         :method method
                         :mode :call-stream
                         :queue queue))
        (let ((result (%raise-rpc (rpc-protocol:decode-message (%body-string res)))))
          (%close-http-response res)
          (make-instance 'http-rpc-stream
                         :transport transport
                         :method method
                         :mode :call-stream
                         :queue (list result))))))

(defmethod rpc-protocol:backend-rpc-recv ((stream http-rpc-stream) &key timeout)
  (declare (ignore timeout))
  (let ((q (http-rpc-stream-queue stream)))
    (cond
      (q
       (setf (http-rpc-stream-queue stream) (rest q))
       (first q))
      (t :eof))))

(defmethod rpc-protocol:backend-rpc-close ((stream http-rpc-stream) &key)
  (let ((fn (http-rpc-stream-close-fn stream)))
    (when fn
      (ignore-errors (funcall fn))
      (setf (http-rpc-stream-close-fn stream) nil)))
  (call-next-method))

(defmethod rpc-protocol:backend-rpc-serve
    ((transport http-rpc-transport) handler &key (host "127.0.0.1") (port 8080)
                                              (path "/"))
  (%ensure-http-server)
  (http-server-protocol:serve (make-rpc-app handler :path path)
                              :host host :port port))

(use-http-rpc-transport)
