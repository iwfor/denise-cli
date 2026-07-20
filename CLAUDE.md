# DeNiSe CLI

A thrown together simple DNS manager for hobbyists, written in Ruby.

## Providers

- Cloudflare
- DreamHost
- AWS (Route 53)

## Structure

- `bin/denise` — CLI entry point; intercepts `--completions` before handing off to Thor
- `lib/denise.rb` — top-level requires
- `lib/denise/cli.rb` — Thor-based command definitions
- `lib/denise/config.rb` — reads/writes `config.toml`; source/zone/entry CRUD, alias resolution
- `lib/denise/crypto.rb` — key management + AES-256-GCM encrypt/decrypt for tokens
- `lib/denise/providers.rb` — registry of known providers, their default aliases, and `client_for` factory
- `lib/denise/providers/base.rb` — shared provider client interface
  (`create_record`/`delete_record`/`list_records`/`list_zones`)
- `lib/denise/providers/cloudflare.rb` — Cloudflare v4 API client (Bearer token, zone-id lookup/cache)
- `lib/denise/providers/dreamhost.rb` — DreamHost API client (key-based query auth, no zone/TTL params)
- `lib/denise/providers/aws.rb` — AWS Route 53 client (hand-rolled SigV4 signing, REST-XML API)
- `lib/denise/paths.rb` — config directory/file path resolution (`DENISE_CONFIG_DIR` override for tests)
- `lib/denise/completions.rb` — bash/zsh completion script generation
- `lib/denise/errors.rb` — typed error classes, each rescued in the CLI and printed as `denise: <message>`
- `lib/denise/version.rb` — version constant
- `spec/` — RSpec tests (each example runs against a fresh `Dir.mktmpdir` config dir)

## Stack

- Ruby, managed with Bundler (`Gemfile`)
- `thor` for the CLI
- `faraday` for provider HTTP APIs (Cloudflare, DreamHost, AWS)
- `tomlib` for TOML config read/write
- `rexml` for building/parsing the AWS Route 53 client's XML request/response bodies
- `rspec` for tests, `rubocop` for linting, `bundler-audit` for dependency vulnerability scanning
- `base64`, `reline`, and `rexml` are pulled in explicitly since they stopped being Ruby default gems (3.4/4.0)

## Configuration

Config lives at `~/.config/denise-cli/config.toml` (override with `DENISE_CONFIG_DIR`, used by the test suite).
A per-install encryption key is auto-created at `~/.config/denise-cli/key` with `0600` permissions on first run
(`Denise::Crypto#ensure_key!`) and used to AES-256-GCM encrypt every provider API token before it's written to
the TOML file. The key is never rotated automatically — rotating it would orphan already-encrypted tokens.

A source's token is stored as `token_encrypted`. config.toml is meant to be hand-editable, and a person editing
it by hand has no way to produce ciphertext, so `Denise::Config#encrypt_plaintext_tokens!` runs on every load:
if a source has a plaintext `token` key, it's encrypted into `token_encrypted` and the plaintext is deleted,
rewriting the file immediately — so a plaintext token is never left on disk past the next command invocation.
This also doubles as the manual-rotation path: a freshly hand-edited `token` always overwrites a stale
`token_encrypted`. `token_for` raises `MissingTokenError` if a source has neither key.

`denise config` displays the current config as TOML with every source's `token_encrypted` stripped out
(`Config#to_toml_without_secrets`) — safe to paste into an issue or share for debugging. If `config.toml`
doesn't exist yet, `Config#ensure_file!` creates a skeleton (a one-line comment plus an empty `[sources]`
table) before displaying it, so this command also doubles as "give me a config.toml to hand-edit."

### Data model

A **source** is one configured instance of a provider: a provider type (`cloudflare`, `dreamhost`, ...), an
encrypted API token, and the zones managed through it. Sources are keyed in the config by a unique **alias**
(`dh`, `cf`, ...). Duplicate provider types are allowed — e.g. two DreamHost accounts — as long as their
aliases differ.

- Each provider type has a default alias (`Denise::Providers::KNOWN`, e.g. `dreamhost` → `dh`, `aws` → `aws`).
- An explicit `--alias` must be unique or `add-provider` rejects it (`AliasConflictError`).
- An omitted `--alias` uses the provider's default alias, auto-numbered (`dh`, `dh2`, `dh3`, ...) if already taken.
- The default *source* is whichever alias was added first, unless overridden with `--default` on `add-provider`
  or later via `set-default-provider`.

Zones live under their source; entries (DNS records: name/type/value/ttl) live under their zone.

### Zone import / refresh

`add-provider` imports the source's zones from the live API right after creating it
(`CLI#sync_zones_for` → `provider_client(alias).list_zones` → `Config#sync_zones`), so a source starts
populated instead of empty. Import failure doesn't roll back the source or fail the command - it's caught and
printed as a warning pointing at `refresh-zones`, since a bad/under-scoped token shouldn't block adding the
source itself.

`refresh-zones` re-runs the same sync: `-p ALIAS` for one source, or every configured source if `-p` is
omitted. `Config#sync_zones(alias, live_zone_names)` diffs against the locally stored zone list - new zones
are added with empty entries, zones no longer present are dropped **along with their locally tracked
entries**, and zones present in both are left untouched (so their entries survive). There's no confirmation
prompt before removing a zone/its entries, unlike `remove-provider` - this command's whole point is
"make local state match the live API," so a removal here just means the CLI has already caught up to a
change made at the provider, not a new destructive action of its own.

When refreshing multiple sources, `refresh_zones` validates every alias exists in one pass *before* doing any
work (so a typoed `-p` aborts cleanly), then syncs each source in a second pass where a single source's live
API failure is caught and reported per-source rather than aborting the rest (`rubocop:disable
Style/CombinableLoops` marks this as deliberate, not an oversight).

### Provider clients

`add-entry`/`remove-entry` call the live provider (`Denise::Providers.client_for(provider_type, token:)`) and
only touch local config *after* the API call succeeds — a failed API call leaves local config untouched, so it
never drifts from what's actually live. `list-entries` is the one exception: it reads local config only (no
network call), so it shows what denise has provisioned, not necessarily everything that exists in the zone
(records created outside denise won't show up). Zones, by contrast, are actively synced from the live API by
`add-provider`/`refresh-zones` (see above) — `list-zones` still just reads local config, but that config is
kept in sync rather than being denise's own record of what it separately provisioned.

DreamHost's `#list_zones` has no dedicated API to call: DreamHost removed its account/domain-management
commands, leaving `dns-list_records` (which returns every record for every domain on the account, each
tagged with a `zone`) as the only way to discover which zones exist - so it's derived as the unique `zone`
values from that same call `#list_records` already uses. A domain with zero DNS records wouldn't show up this
way, but that's a real limitation of DreamHost's current API, not a bug in ours.

Every provider client subclasses `Denise::Providers::Base` and implements `create_record`/`delete_record`/
`list_records`, raising `Denise::ProviderError` on any API/network failure. `initialize(token:, connection:
nil)` accepts an injectable Faraday connection so specs can stub HTTP via `Faraday::Adapter::Test::Stubs`
without touching the network — see `spec/denise/providers/*_spec.rb`.

**Gotcha that already bit us once:** stubbed specs can be self-consistently wrong about the base URL if the
bug is in how the base URL and request path are joined, because the same (buggy) construction is used on both
sides. `Cloudflare::API_URL` must end in a trailing slash and request paths must NOT start with `/` — Faraday
resolves `req.url("/foo", ...)` against the connection's base URL like a browser resolves an absolute-path
link, which discards the base path (`/client/v4`) entirely. Whenever adding a new provider client, do at least
one live request against the real endpoint with a garbage token (an auth-format error, not a 404, confirms the
URL is right) in addition to the stubbed specs. (Every client, including AWS's, follows the same
trailing-slash-base / no-leading-slash-path convention now.)

**AWS is different from Cloudflare/DreamHost**: AWS auth is a signature over the whole request (SigV4:
access key ID + secret access key), not a single bearer token, so `Denise::Providers::Aws#initialize` splits
the config `token` on the first `:` into `ACCESS_KEY_ID:SECRET_ACCESS_KEY` and raises `ProviderError`
immediately if that split doesn't produce two non-empty halves — there's no schema change to the single-token
config model, just a documented convention for that one provider. Route 53's API is REST-XML, not JSON (see
`rexml` in Stack), and is a global service that AWS still signs against the fixed pseudo-region `us-east-1`.
The signer (`Aws#signed_headers`/`#signing_key`) is hand-rolled from
[AWS's documented SigV4 algorithm](https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html)
rather than pulling in `aws-sdk-route53` (a much heavier dependency than this project's other providers use).
`spec/denise/providers/aws_spec.rb` verifies it by independently re-deriving the expected `Authorization`
header from the same published algorithm (not by calling the implementation's own private helpers) and
comparing — the crypto equivalent of the live-smoke-test principle above: don't let a test validate an
implementation against itself.

### Verbose logging (`-v`/`--verbose`)

A class option on every command (`Denise.verbose`, a simple module-level flag set once in `CLI#initialize` -
not threaded through every method call, since this is a single-threaded CLI, not a server). Each provider
client's private `request` calls `Base#log` before/after the HTTP call, printing method/path/params/body and
the response status to stderr (`warn`, gated on `Denise.verbose`) - stdout stays reserved for actual command
output.

**The secret-safety rule that shapes this:** `#log` is only ever called with method/path/params/body/status -
never with headers, and never with `@token`/`@secret_access_key` directly. This matters most for DreamHost,
where the plaintext API key travels as a `key=` query param on every request: `Dreamhost#request` builds its
log line from `cmd`/`params` (the method's own arguments, which never include `key`), not from the `query`
hash actually sent over the wire (which does). Cloudflare and AWS carry their secrets in the `Authorization`
header instead, which `#log` never touches at all. `spec/denise/providers/*_spec.rb` has an explicit
"verbose logging" example per provider asserting the token/secret string is absent from captured output, not
just that logging happens - see `capture_stderr` in `spec/spec_helper.rb`.

### Provider resolution (`-p`/`--provider`)

Used by every zone/entry command via `CLI#resolve_provider_alias`, in this order:

1. `-p/--provider ALIAS` if given.
2. Inferred from `-z/--zone ZONE` if exactly one source owns a zone with that name (`AmbiguousZoneError` if
   more than one does — the caller must disambiguate with `-p`).
3. The configured default source (`NoProviderError` if none is set).

`remove-provider` is the one exception: it never falls back to the default and always requires the alias as an
explicit positional argument, plus a confirmation prompt (skippable with `-y/--yes`).

## Commands

`config`,
`add-provider` / `list-providers` / `remove-provider` / `set-default-provider`,
`add-zone` / `list-zones` / `remove-zone` / `refresh-zones`,
`add-entry` / `list-entries` / `remove-entry`,
`version`, and `--completions [bash|zsh]` (defaults to `$SHELL`; handled in `bin/denise`, not a Thor command,
so it works without a subcommand).

Thor command methods use underscores (`add_provider`); Thor normalizes hyphenated CLI input to underscores for
dispatch, so `denise add-provider` and the `desc` help text both show the hyphenated form.

`CLI#help` overrides Thor's built-in `help` command (matching its `(command = nil, subcommand = false)`
signature exactly, since Thor calls it positionally via both `super` and its own internal dispatch — see the
`rubocop:disable Style/OptionalBooleanParameter` comment). With no command given it prints a one-line tool
description and, after `super`, a "Global flags" section documenting `--completions` — which otherwise
wouldn't appear anywhere in the help output, since it's intercepted in `bin/denise` before Thor ever sees it.
`denise help COMMAND` (a specific command) skips both additions.

## Conventions

- **Test everything.** Every new module, command, or behavior change needs RSpec coverage in `spec/` before
  it's considered done — not just the happy path, but conflict/error cases (see the alias-conflict,
  ambiguous-zone, and unknown-* examples in the existing specs as the bar to match).
- **Keep `--help` and `--completions` in sync with the CLI.** Whenever a command, flag, or option changes,
  update its `desc`/`method_option`/`class_option` text so `denise help` stays accurate — that text is the
  only documentation most users will ever see. `--completions` needs no manual upkeep at all:
  `Completions.commands`/`Completions.flags_for` (`lib/denise/completions.rb`) derive both the top-level
  command list and each command's flags (its own `method_option`s plus the global `class_option`s) straight
  from `CLI.commands`/`CLI.class_options`, so a new command or flag shows up in bash/zsh completion
  automatically — nothing to touch by hand there. Only value-completion (e.g. suggesting existing zone names
  after `-z`) would require new, hand-written logic; that's not implemented.
- **Before every commit**, run all three and don't commit unless all three are clean:
  - `bundle exec rspec`
  - `bundle exec rubocop`
  - `bundle exec bundler-audit check --update`
- `Style/StringLiterals` is configured for double-quoted strings project-wide.
- New provider integrations belong under `lib/denise/providers/` as a `Denise::Providers::Base` subclass, then
  registered in `Denise::Providers::KNOWN` and `Denise::Providers.client_for`. Wire its private `request`
  method to call `#log` (see Verbose logging above) - and add a "verbose logging" spec asserting the
  token/secret is absent from captured output, not just that a log line was produced.
- **7-day age gate on new Gemfile dependencies.** Before adding any gem, check its release date on
  rubygems.org (`https://rubygems.org/api/v1/versions/<gem>.json`) and pin the Gemfile to the newest version
  that is at least 7 days old as of the current date (exact pin, e.g. `gem "rubocop", "1.88.2"`, not `~>`).
  This guards against a supply-chain attack landing in a brand-new release before it's had time to be
  scrutinized.

## Roadmap / explicitly deferred

- Additional providers (see README TODO): GCP Cloud DNS, HostGator, Azure DNS.
- `list-entries` is local-config-only; there's no live/refresh flag to reconcile against what the provider
  actually has.
