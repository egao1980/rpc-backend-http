(in-package #:rpc-backend-http/tests)

(defun %echo (method params)
  (cond
    ((equal method "echo") params)
    ((equal method "sum") (+ (elt params 0) (elt params 1)))
    (t (error 'rpc-protocol:rpc-method-not-found))))

(defun %free-port ()
  (let* ((sock (usocket:socket-listen "127.0.0.1" 0 :reuseaddress t))
         (port (usocket:get-local-port sock)))
    (usocket:socket-close sock)
    port))

(defun %bind ()
  (http-server-backend-hunchentoot:use-hunchentoot-backend)
  (setf http-protocol:*http-backend*
        (http-backend-dexador:make-dexador-backend)))

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
  (%bind)
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
        (ok (rpc-protocol:rpc-notify "echo" "n" :transport tx))))))
