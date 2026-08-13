# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

## Overview

`axiom-logtail` ships [logtail](https://github.com/logtail/logtail-ruby) events to [Axiom](https://axiom.co), and adds two pieces of hardening logtail does not provide: recursive credential/PII redaction that reaches inside serialised-JSON values, and a size bound on the params carried by `controller_called` events.

Extracted from three Rails applications. **It is intended to be open sourced.** See "Publishing constraint" below — it changes what may go in a comment.

Supports Ruby 2.7 through 3.4. Both are tested; 2.7 is not optional, one consumer is still on it.

## Development Commands

```bash
bundle install
bundle exec rspec                      # full suite
bundle exec rspec spec/path_spec.rb:42 # one example
```

Verify against **both** Rubies before pushing — a change that only works on 3.x will break the oldest consumer at boot:

```bash
rvm use 3.4.9 && bundle install --quiet && bundle exec rspec
rvm use 2.7.8 && bundle install --quiet && bundle exec rspec
```

## Architecture

| File | Responsibility |
|---|---|
| `log_device.rb` | The Axiom sink. Subclasses `Logtail::LogDevices::HTTP`, overriding **only** the wire format. Also owns redaction. |
| `bounded_params.rb` | Caps params on `controller_called` events. Prepends to the event class. |
| `header_filters.rb` | Configures `logtail-rack`'s `http_header_filters`. Optional — degrades if `logtail-rack` is absent. |
| `configuration.rb` | Key lists and buffer bounds. |

`LogDevice` inherits batching, the flush thread, the request outlet, retry/backoff and UTF-8 coercion **unchanged**. Do not reimplement any of it — Axiom's own Rails guide has you hand-roll this with Faraday, which puts a synchronous HTTP client in the logging path.

## Three traps that fail silently

Everything here returns a plausible success while doing the wrong thing. That is why the specs assert runtime *effect* rather than configuration.

**1. The Axiom ingest contract.** All three of these were established by testing against live Axiom, not from its documentation:
- Path is `/v1/ingest/<dataset>`. The documented-looking `/v1/datasets/<dataset>/ingest` returns 404.
- Ingest must go to the dataset's **regional edge host**. `api.axiom.co` rejects it with 400, and the wrong region silently defeats data residency.
- `?timestamp-field=dt` is **required**. Without it Axiom stamps every event at ingest time — while returning `200 {"ingested":1}`.

The parent gem ignores non-2xx responses entirely, so any of these discards every batch while the app looks healthy. That is what `LogDevice#verify!` exists for.

**2. Header-name normalisation.** `logtail-rack` does **not** pass rack env keys to its filter. `HTTPEvents#call` wraps the env in `Logtail::Util::Request`, whose `#headers` strips the `HTTP_` prefix, splits on `_` and capitalises each part — so the filter sees `X_Csrf_Token`, never `HTTP_X_CSRF_TOKEN`. Response headers arrive unprefixed (`Set-Cookie`). `normalize_header_name` then downcases and maps `-` to `_` on both sides.

Consequence: the canonical hyphenated spelling matches both forms. `HTTP_`-prefixed entries match **nothing** — they exist only as insurance against a future change in `Util::Request#headers`. An earlier version of this code had that exactly backwards, and its specs were green because they fed fixtures a shape production never produces.

**Any spec touching request headers must build fixtures from `Logtail::Util::Request`**, not `ActionDispatch::Request#headers.to_h`.

**3. Redaction must reach inside strings.** Apps do not emit nested hashes for `headers_json` / `params_json` — they emit a JSON *document serialised into a string*. An earlier version walked only `Hash` and `Array`, every unit spec built fixtures as nested hashes, every example passed, and live Basic-auth credentials shipped to a third party. **Keep spec fixtures string-shaped.**

The embedded-JSON check is deliberately not limited to keys whose names suggest JSON — that assumption is what caused the leak.

## Do not change without understanding why

- **`request_queue` drops, it does not block.** `#write` runs on the request path; a blocking `SizedQueue` would turn a slow sink into an application outage. Dropping is correct — which is exactly why `request_queue_size` must stay generous. It records nothing when it drops, so under-sizing loses log lines invisibly.
- **`build_http` restores TLS peer verification.** The parent disables it for a historical Windows issue. Inheriting that sends log contents and a long-lived ingest token over unverified TLS.
- **`write` deliberately does not call `super`.** The parent short-circuits on a global vendor-specific filter; inheriting it lets a filter configured for another sink silently suppress this one.
- **`safe_bound` never raises.** A bug in bounding must not cost a log line or surface as a request error.
- **`http_header_filters=` cannot be reset to `nil`** — it maps over its argument. It can only be replaced.

## Testing

- Assert the **runtime effect**, never the contents of a configured list. A filter that looks configured and redacts nothing is the failure mode this library exists to prevent.
- Pair any size assertion that could pass against unpatched code with a content assertion that cannot.
- Coupling to the parent gem's private methods (`build_request`, `filter_http_headers`) is intentional: an upgrade that changes them should fail in CI rather than silently break delivery.
- Configuration is global state. `spec_helper` resets it after every example.

## Code Style

- Double quotes; single quotes inside interpolations.
- Frozen string literal comment on every file.
- No Rails/ActiveSupport dependency — `BoundedParams` uses a plain empty check rather than `blank?` for this reason. Keep it that way.

## Publishing constraint

This repo is private now and intended to go public. Nothing in `lib/`, `spec/` or `README.md` may contain:

- internal ticket references, incident detail, or measured production figures
- vendor relationships or which provider is being migrated from
- internal service, host or header names — use neutral examples (`X-Acme-Key`)
- references to internal documents

Technical reasoning **should** stay in full; it is the valuable part. The rule is about internal detail, not about depth. An audit before publishing:

```bash
rg -i "internal-ticket-prefix|company-name|vendor-name|internal-host" lib/ spec/ README.md
```

## Important Files

- `lib/axiom_logtail/log_device.rb` — the sink and redaction; highest-risk file
- `spec/axiom_logtail/log_device_spec.rb` — the wire contract; each assertion maps to a real observed failure
- `README.md` — user-facing; also states what the library deliberately does not cover
