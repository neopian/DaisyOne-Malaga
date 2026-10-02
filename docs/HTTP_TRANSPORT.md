# Streaming JSON transport

The Node HTTP bridge negotiates streaming gzip for successful 200 JSON GET
responses from `/api/questions`, `/api/questions/:id`, `/api/guide/questions`,
and `/api/points`. Search/detail fields, ordering, authorization and response
models are unchanged. Compression runs after the application produces its
response. This reduces transferred bytes; it does not reduce database query
work or make the application's existing JSON generation itself streaming.

Authentication, profiles, exports, mutations, errors, image bytes, already
encoded responses, partial representations, and `no-transform` responses are
excluded. In particular, login/registration bearer tokens and account export
data are not added to this compression path. Selected resources contain the
same private data they already returned and retain their exact `Cache-Control`
policy; there is no new shared response cache.

Negotiation recognizes gzip, wildcard, explicit identity preferences, and
quality weights. Explicit `gzip;q=0` overrides a wildcard; absent/empty headers
select identity. Invalid quality values are treated as exclusions, and
conflicting duplicate entries use their lower weight. Eligible requests that
exclude both supported representations return 406. `Vary: Accept-Encoding`
merges with existing `Origin` or other values without duplicating tokens; `*`
is preserved. A compressed response removes the original Content-Length and
sets Content-Encoding to gzip. Uncompressed bytes/lengths remain unchanged.

The implementation uses Node's asynchronous gzip transform at level 4 and
stream pipeline for backpressure and teardown. It does not buffer another
complete compressed response. An aborted client cancels the Web response body
and destroys the transport streams. A failed stream ends the connection;
the bridge never appends an error JSON document to partial/compressed content.
The default bridge logger emits fixed error categories only, without error
objects, request URLs, signed image queries, exception messages, or headers.

## Verification and limits

`backend/test/transport.test.mjs` uses real loopback HTTP with Node's raw HTTP
client, so it measures encoded response-body bytes instead of fetch's automatic
decompression. It checks exact decompressed payload equality, every eligible
route, quality/wildcard negotiation, CORS/Vary/cache headers, statuses and
exclusions, abort cancellation, source-stream errors, and redacted logging of
malformed targets and exceptions.

The deterministic 60-question fixture contains nested answer/evidence/comment
search text: 289,071 identity bytes became 3,417 gzip bytes (1.2%) on the tested
Node 24.19.0 build, with identical decompressed bytes. This deliberately
repetitive synthetic fixture proves transport behavior, not a real-world
compression ratio, mobile latency, CPU load, or throughput guarantee. Header
and transfer-framing bytes are not included in those payload measurements.
Concurrent compression uses CPU/threadpool resources and needs deployment load
testing. No proxy setting, live service, or deployment was changed.

## References

- [Node zlib and HTTP compression](https://nodejs.org/api/zlib.html#compressing-http-requests-and-responses)
- [Node stream pipeline](https://nodejs.org/api/stream.html#streampipelinesource-transforms-destination-callback)
- [HTTP Accept-Encoding semantics, RFC 9110 §12.5.3](https://www.rfc-editor.org/rfc/rfc9110.html#section-12.5.3)
