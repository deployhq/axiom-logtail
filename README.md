# axiom-logtail

Ships [logtail](https://github.com/logtail/logtail-ruby) events to [Axiom](https://axiom.co), with two pieces of hardening logtail does not provide: recursive credential/PII redaction that reaches inside serialised-JSON values, and a size bound on the params carried by `controller_called` events.

Supports Ruby 2.7 through 3.4.

## Why

Three things are easy to get wrong and fail silently:

1. **Axiom's ingest contract.** The documented-looking `/v1/datasets/<ds>/ingest` path 404s; `api.axiom.co` rejects ingest with 400; and without `?timestamp-field=dt` Axiom stamps every event at ingest time while returning `200 {"ingested":1}`. All three look like success.
2. **Credentials in logs.** `logtail-rack` logs every request and response header. Its `http_header_filters` defaults to `nil`, so an unconfigured app exports `Cookie` and `Authorization` verbatim — and a *mis*configured one filters nothing, with no warning.
3. **Unbounded params.** `Logtail::Events::ControllerCall` serialises request params twice per request with no size cap. One webhook endpoint receiving large payloads can dominate a log bill.

## Usage

### Shipping to Axiom

```ruby
device = AxiomLogtail::LogDevice.new(ENV["AXIOM_TOKEN"], "my-dataset", region: "eu-central-1")
logger = Logtail::Logger.new(device)
```

The `region` must match the dataset's **Edge deployment** setting — sending to the wrong region silently defeats data residency.

`LogDevice#verify!` synchronously delivers one probe event and raises unless Axiom accepts it. Call it at boot: the parent gem ignores non-2xx responses, so a revoked token or missing dataset otherwise discards every batch while the app looks healthy.

```ruby
Thread.new { device.verify! }   # off the boot path; report failures to your error tracker
```

### Redaction

Every event is walked before it leaves the process. Credential and PII keys are replaced with `[REDACTED]`, **including inside string values that are themselves JSON** — which is where header and param payloads actually live.

Defaults cover what any Rails app emits. Add your own:

```ruby
AxiomLogtail.configure do |config|
  config.additional_credential_keys = %w[X-Acme-Key Stats-Auth-Key]
end
```

Matching ignores case and separator, so one entry covers `X_Acme_Key`, `x-acme-key` and `X-ACME-KEY`.

### Header filtering

Requires `logtail-rack`.

```ruby
AxiomLogtail::HeaderFilters.apply!(extra: %w[X-Acme-Key Stripe-Signature])
```

Use the canonical hyphenated spelling. The middleware presents request headers as `X_Acme_Key` (it strips the rack `HTTP_` prefix and capitalises each part) and response headers as `Set-Cookie`; the normalisation makes one spelling match both.

### Bounded params

```ruby
AxiomLogtail::BoundedParams.install!
```

Prepends to `Logtail::Events::ControllerCall` so both the structured field and the message string shrink from one pass. Ordinary requests are untouched; oversized payloads are pruned recursively, preserving structure so the log still shows which resource was touched.

Truncated events carry `_params_truncated_bytes` (pre-truncation size) and `_params_dropped_keys`. A `_params_bounding_failed` marker means the bounding itself raised — it never propagates, since logging must not break a request.

## Configuration reference

| Option | Default | Purpose |
|---|---|---|
| `additional_credential_keys` | `[]` | App-specific credential keys |
| `additional_pii_keys` | `[]` | App-specific identifier keys |
| `credential_keys` / `pii_keys` | see `Configuration` | Replace the defaults entirely |
| `batch_size` | `1000` | Events per request |
| `request_queue_size` | `25` | Queued requests before dropping |
| `max_embedded_json_bytes` | `64_000` | Above this, embedded JSON is scrubbed textually rather than parsed |

**On `request_queue_size`:** the queue *drops* when full rather than blocking, and records nothing when it does. Under-sizing it loses log lines invisibly. Blocking instead would be worse — `#write` runs on the request path, so back pressure turns a slow sink into an application outage. Dropping is the correct failure mode, which is exactly why the bound should stay generous.

## What this does not do

- It does not scrub credentials from URL **paths** or **query strings**. `logtail-rack` records both with no filtering hook, and `config.filter_parameters` does not apply to them. If your routes carry tokens in the path, that exposure is not addressed here.
- It does not scrub free-text log messages. Redaction covers structured keys and embedded JSON; an identifier interpolated into a message string passes through. Scrub those at the source.

## Development

```bash
bundle install
bundle exec rspec
```
