(in-package #:rpc-backend-http/tests)

(deftest transport-class
  (ok (typep (rpc-backend-http:make-http-rpc-transport) 'rpc-backend-http:http-rpc-transport)))
