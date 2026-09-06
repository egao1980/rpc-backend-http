# rpc-backend-http

HTTP POST JSON-RPC transport for rpc-protocol.

Part of [cl-stack](https://github.com/egao1980/cl-stack) agent-wire ([brief](https://github.com/egao1980/cl-stack/blob/main/docs/capabilities/agent-wire.md)).

```lisp
(asdf:load-system "rpc-backend-http")

(http-server-protocol:with-server
    (s (rpc-backend-http:make-rpc-app
        (lambda (method params) (declare (ignore method)) params)
        :path "/rpc")
       :port 8080)
  (rpc-protocol:rpc-call "echo" "hi"
    :transport (rpc-backend-http:make-http-rpc-transport
                :url "http://127.0.0.1:8080/rpc")))

;; :call-stream — POST Accept: text/event-stream, :want-stream t
(let ((s (rpc-protocol:rpc-call-stream "tick" nil
           :transport (rpc-backend-http:make-http-rpc-transport
                       :url "http://127.0.0.1:8080/rpc"))))
  (loop for ev = (rpc-protocol:rpc-recv s)
        until (eq ev :eof)
        collect ev))
```

`sbcl --load scripts/live-http.lisp`

CI: canned [`cl-repository`](https://github.com/egao1980/cl-repository) (`test-system.yml` / `setup-client` + `ci`). Deps from `ghcr.io/egao1980/cl-systems`.

## License

MIT
