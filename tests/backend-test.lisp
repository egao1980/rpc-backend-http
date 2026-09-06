(in-package #:rpc-backend-http/tests)

(defun %echo (method params)
  (cond
    ((equal method "echo") params)
    ((equal method "sum") (+ (elt params 0) (elt params 1)))
    ((equal method "tick") (list "a" "b" "c"))
    ((equal method "boom")
     (error 'rpc-protocol:rpc-error
            :code rpc-protocol:+internal-error+
            :message "nope"))
    (t (error 'rpc-protocol:rpc-method-not-found))))

(defun %free-port ()
  (let* ((sock (usocket:socket-listen "127.0.0.1" 0 :reuseaddress t))
         (port (usocket:get-local-port sock)))
    (usocket:socket-close sock)
    port))

(defmacro with-live-http (&body body)
  "Hunchentoot server + http-backend-async × event-backend-libuv client."
  `(progn
     (http-server-backend-hunchentoot:use-hunchentoot-backend)
     (let* ((eb (event-backend-libuv:make-libuv-backend))
            (el (event-protocol:make-event-loop eb))
            (http-backend-async:*event-backend-maker* (lambda () eb)))
       (event-protocol:with-event-backend (eb)
         (event-protocol:with-event-loop-var (el)
           (let ((http-protocol:*http-backend*
                   (http-backend-async:make-async-backend)))
             ,@body))))))

(defun %recv-all (stream)
  (unwind-protect
       (loop for ev = (rpc-protocol:rpc-recv stream)
             until (eq ev :eof)
             collect ev)
    (rpc-protocol:rpc-close stream)))

(deftest transport-class
  (ok (typep (rpc-backend-http:make-http-rpc-transport)
             'rpc-backend-http:http-rpc-transport)))

(deftest extra-headers
  (let ((tx (rpc-backend-http:make-http-rpc-transport
             :url "http://127.0.0.1/rpc"
             :headers '(("A2A-Version" . "1.0")
                        ("accept" . "application/json, text/event-stream")))))
    (ok (equal "1.0" (cdr (assoc "A2A-Version"
                                 (rpc-backend-http:transport-headers tx)
                                 :test #'string=))))))

(deftest make-rpc-app-in-process
  (let* ((app (rpc-backend-http:make-rpc-app #'%echo :path "/rpc"))
         (body (rpc-protocol:encode-request "echo" "hi" :id 1))
         (env (list :request-method :post
                    :path-info "/rpc"
                    :raw-body body
                    :headers (make-hash-table :test 'equal)))
         (res (funcall app env))
         (msg (rpc-protocol:decode-message (first (third res)))))
    (ok (= 200 (first res)))
    (ok (equal "hi" (gethash "result" msg)))))

(deftest live-http-rpc
  (with-live-http
    (let ((port (%free-port)))
      (http-server-protocol:with-server
          (s (rpc-backend-http:make-rpc-app #'%echo :path "/rpc")
             :host "127.0.0.1" :port port)
        (sleep 0.2)
        (let ((tx (rpc-backend-http:make-http-rpc-transport
                   :url (format nil "http://127.0.0.1:~a/rpc" port))))
          (ok (equal "hi" (rpc-protocol:rpc-call "echo" "hi" :transport tx :id 1)))
          (ok (= 3 (rpc-protocol:rpc-call "sum" #(1 2) :transport tx :id 2)))
          (ok (signals (rpc-protocol:rpc-call "nope" nil :transport tx :id 3)
                       'rpc-protocol:rpc-error))
          (ok (rpc-protocol:rpc-notify "echo" "n" :transport tx)))))))

(deftest make-rpc-stream-app-in-process
  (let* ((app (rpc-backend-http:make-rpc-stream-app #'%echo :path "/rpc"))
         (body (rpc-protocol:encode-request "tick" nil :id 1))
         (env (list :request-method :post
                    :path-info "/rpc"
                    :raw-body body
                    :headers (make-hash-table :test 'equal)))
         (res (funcall app env)))
    (ok (= 200 (first res)))
    (ok (search "text/event-stream" (getf (second res) :content-type)))
    (let ((events (with-input-from-string (s (first (third res)))
                    (sse-protocol:collect-sse-events s))))
      (ok (= 3 (length events)))
      (ok (equal "a" (gethash "result"
                              (rpc-protocol:decode-message
                               (sse-protocol:sse-event-data (first events)))))))))

(deftest live-http-rpc-stream
  (with-live-http
    (let ((port (%free-port)))
      (http-server-protocol:with-server
          (s (rpc-backend-http:make-rpc-stream-app #'%echo :path "/rpc")
             :host "127.0.0.1" :port port)
        (sleep 0.2)
        (let* ((tx (rpc-backend-http:make-http-rpc-transport
                    :url (format nil "http://127.0.0.1:~a/rpc" port)))
               (stream (rpc-protocol:rpc-call-stream "tick" nil :transport tx :id 1)))
          (ok (typep stream 'rpc-backend-http:http-rpc-stream))
          (ok (equal '("a" "b" "c") (%recv-all stream)))
          (ok (equal "hi" (first (%recv-all
                                  (rpc-protocol:rpc-call-stream
                                   "echo" "hi" :transport tx :id 2)))))
          (ok (signals (rpc-protocol:rpc-call-stream "boom" nil :transport tx :id 3)
                       'rpc-protocol:rpc-error)))))))

(deftest rpc-call-stream-needs-http-backend
  (let ((http-protocol:*http-backend* nil)
        (tx (rpc-backend-http:make-http-rpc-transport
             :url "http://127.0.0.1/rpc")))
    (ok (signals (rpc-protocol:rpc-call-stream "echo" "hi" :transport tx)
                 'rpc-protocol:rpc-error))))
