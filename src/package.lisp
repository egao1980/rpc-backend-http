(defpackage #:rpc-backend-http
  (:use #:cl)
  (:export #:http-rpc-transport
           #:http-rpc-stream
           #:transport-url
           #:transport-headers
           #:transport-next-id
           #:make-http-rpc-transport
           #:use-http-rpc-transport
           #:http-rpc-request-url
           #:http-rpc-encode-body
           #:http-rpc-decode-event
           #:make-rpc-app
           #:make-rpc-stream-app
           #:slurp-env-body))

(in-package #:rpc-backend-http)
