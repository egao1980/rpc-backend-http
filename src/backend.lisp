(in-package #:rpc-backend-http)

(defclass http-rpc-transport (rpc-protocol:rpc-transport)
  ((url :initarg :url :initform nil :accessor transport-url)
   (next-id :initform 0 :accessor transport-next-id)))

(defun make-http-rpc-transport (&key url)
  (make-instance 'http-rpc-transport :url url))

(defun use-http-rpc-transport (&key url)
  (setf rpc-protocol:*rpc-transport* (make-http-rpc-transport :url url)))

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

(defun %ensure-http-server ()
  (or http-server-protocol:*http-server-backend*
      (progn
        (asdf:load-system "http-server-backend-hunchentoot")
        (funcall (find-symbol "USE-HUNCHENTOOT-BACKEND"
                              :http-server-backend-hunchentoot)))))

(defmethod rpc-protocol:backend-rpc-call
    ((transport http-rpc-transport) method params &key timeout id)
  (unless http-protocol:*http-backend*
    (error 'rpc-protocol:rpc-error
           :message "*http-backend* is nil — bind an http-protocol backend"
           :code rpc-protocol:+internal-error+))
  (let* ((id (or id (incf (transport-next-id transport))))
         (url (or (transport-url transport)
                  (error 'rpc-protocol:rpc-error
                         :message "http RPC transport has no :url"
                         :code rpc-protocol:+internal-error+)))
         (res (apply #'http:post url
                     :content (rpc-protocol:encode-request method params :id id)
                     :headers '(("content-type" . "application/json")
                                ("accept" . "application/json"))
                     (when timeout (list :timeout timeout)))))
    (unless (<= 200 (http-protocol:response-status res) 299)
      (error 'rpc-protocol:rpc-error
             :message (format nil "HTTP ~a" (http-protocol:response-status res))
             :code rpc-protocol:+internal-error+))
    (%raise-rpc (rpc-protocol:decode-message (%body-string res)))))

(defmethod rpc-protocol:backend-rpc-notify
    ((transport http-rpc-transport) method params)
  (unless http-protocol:*http-backend*
    (error 'rpc-protocol:rpc-error
           :message "*http-backend* is nil — bind an http-protocol backend"
           :code rpc-protocol:+internal-error+))
  (http:post (or (transport-url transport)
                 (error 'rpc-protocol:rpc-error
                        :message "http RPC transport has no :url"
                        :code rpc-protocol:+internal-error+))
             :content (rpc-protocol:encode-notification method params)
             :headers '(("content-type" . "application/json")))
  t)

(defmethod rpc-protocol:backend-rpc-serve
    ((transport http-rpc-transport) handler &key (host "127.0.0.1") (port 8080)
                                              (path "/"))
  (%ensure-http-server)
  (http-server-protocol:serve (make-rpc-app handler :path path)
                              :host host :port port))

(use-http-rpc-transport)
