(in-package #:rpc-backend-http)

(defclass http-rpc-transport (rpc-protocol:rpc-transport) ())

(defun make-http-rpc-transport ()
  (make-instance 'http-rpc-transport))

(defun use-http-rpc-transport ()
  (setf rpc-protocol:*rpc-transport* (make-http-rpc-transport)))

(defmethod rpc-protocol:backend-rpc-call ((transport http-rpc-transport) method params &key timeout id)
  (declare (ignore timeout id))
  (error 'rpc-protocol:rpc-error
         :message "rpc-backend-http: backend-rpc-call not implemented"
         :code rpc-protocol:+internal-error+))

(defmethod rpc-protocol:backend-rpc-notify ((transport http-rpc-transport) method params)
  (declare (ignore method params))
  (error 'rpc-protocol:rpc-error
         :message "rpc-backend-http: backend-rpc-notify not implemented"
         :code rpc-protocol:+internal-error+))

(defmethod rpc-protocol:backend-rpc-serve ((transport http-rpc-transport) handler &key)
  (declare (ignore handler))
  (error 'rpc-protocol:rpc-error
         :message "rpc-backend-http: backend-rpc-serve not implemented"
         :code rpc-protocol:+internal-error+))
