(defsystem "rpc-backend-http"
  :version "0.1.2"
  :description "HTTP POST JSON-RPC transport for rpc-protocol"
  :author "egao1980"
  :license "MIT"
  :depends-on ("rpc-protocol" "rpc-protocol-json" "http-protocol" "http-server-protocol"
               "sse-protocol" "babel")
  :properties (:cl-repo (:ci (:with ("dissect"))))
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "backend"))
  :in-order-to ((test-op (test-op "rpc-backend-http/tests"))))

(defsystem "rpc-backend-http/tests"
  :depends-on ("rpc-backend-http"
               "http-server-backend-hunchentoot"
               "http-backend-async"
               "event-backend-libuv"
               "event-protocol"
               "rove"
               "usocket")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "backend-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
