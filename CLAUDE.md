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
- `lib/denise/cli_dispatch.rb` — `CLIDispatch`, class-level Thor dispatch overrides `extend`ed into `CLI`
  (`-h`/`--help` anywhere, hyphenated "Did you mean?" suggestions)
- `lib/denise/config.rb` — reads/writes `config.toml`; source/zone CRUD, alias resolution (records are never
  stored here - see Provider clients below)
- `lib/denise/crypto.rb` — key management + AES-256-GCM encrypt/decrypt for tokens
- `lib/denise/providers.rb` — registry of known providers, their default aliases, and `client_for` factory
- `lib/denise/providers/base.rb` — shared provider client interface
  (`create_record`/`delete_record`/`list_records`/`list_zones`)
- `lib/denise/providers/cloudflare.rb` — Cloudflare v4 API client (Bearer token, zone-id lookup/cache)
- `lib/denise/providers/dreamhost.rb` — DreamHost API client (key-based query auth, no zone/TTL params)
- `lib/denise/providers/aws.rb` — AWS Route 53 client (hand-rolled SigV4 signing, REST-XML API)
- `lib/denise/paths.rb` — config directory/file path resolution (`DENISE_CONFIG_DIR` override for tests)
- `lib/denise/completions.rb` — bash/zsh completion script generation
- `lib/denise/record_types.rb` — infers/resolves a record's type when `--type` is omitted (see Record type
  inference below)
- `lib/denise/record_log.rb` — appends add/remove record changes to `records.log` (see Record change log below)
- `lib/denise/search.rb` — supports `search`: live record queries plus local zone-name matching (see Search below)
- `lib/denise/table.rb` — renders every tabular command output (`list-*`, `search`); replaces Thor's
  `print_table`, which pads trailing empty columns into terminal-wrapping blank lines (see Table output below)
- `lib/denise/zone_sync.rb` — shared add-provider/refresh-zones "sync zones, report what changed" step
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
This also doubles as a manual-rotation path: a freshly hand-edited `token` always overwrites a stale
`token_encrypted`. The command-line rotation path is `update-token ALIAS` (`Config#update_token`), which takes
`--token` or prompts with echo off like `add-provider`, and leaves the source's provider/zones untouched.
Both `add_source` and `update_token` reject a blank token (`BlankTokenError`) via the shared private
`Config#encrypt_token`. `token_for` raises `MissingTokenError` (pointing at `update-token`) if a source has
neither key.

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

Zones live under their source, as a plain array of zone names - denise tracks *which* zones a source manages,
nothing more. Records are never stored in config.toml at all: `add-record`/`remove-record`/`list-records`/
`search` all query the live provider API instead (see Provider clients and Search below). This keeps
config.toml simple and guarantees it can never drift from what a provider actually has, at the cost of an API
call for every record read.

### Zone import / refresh

`add-provider` imports the source's zones from the live API right after creating it
(`CLI#sync_zones_for` → `ZoneSync.call` → `provider_client(alias).list_zones` → `Config#sync_zones`), so a
source starts populated instead of empty. Import failure doesn't roll back the source or fail the command -
it's caught and printed as a warning pointing at `refresh-zones`, since a bad/under-scoped token shouldn't
block adding the source itself. `ZoneSync` (`lib/denise/zone_sync.rb`) is a small extraction shared by
`add-provider` and `refresh-zones`, kept out of `CLI` to stay under `Metrics/ClassLength` (same pattern as
`RecordTypes`/`Search`).

`refresh-zones` re-runs the same sync: `-p ALIAS` for one source, or every configured source if `-p` is
omitted. `Config#sync_zones(alias, live_zone_names)` diffs against the locally stored zone list - zones no
longer present are dropped and new ones are added, leaving zones present in both untouched. There's no
confirmation prompt before removing a zone, unlike `remove-provider` - this command's whole point is
"make local state match the live API," so a removal here just means the CLI has already caught up to a
change made at the provider, not a new destructive action of its own. (There's nothing to lose on removal
either way - records were never stored under the zone to begin with.)

When refreshing multiple sources, `refresh_zones` validates every alias exists in one pass *before* doing any
work (so a typoed `-p` aborts cleanly), then syncs each source in a second pass where a single source's live
API failure is caught and reported per-source rather than aborting the rest (`rubocop:disable
Style/CombinableLoops` marks this as deliberate, not an oversight).

### Provider clients

Records are never stored locally (see Data model above), so `add-record`/`remove-record`/`list-records` all
call the live provider (`Denise::Providers.client_for(provider_type, token:)`) directly:

- `add-record` just calls `create_record` - there's nothing to persist afterward.
- `list-records` calls `list_records(zone:)` and prints whatever comes back - always live, never stale, at
  the cost of an API call every time.
- `remove-record` calls `list_records(zone:)` first (via `RecordTypes.find` - see Record type inference below)
  to resolve `--type` when omitted and to capture the record's value/ttl for `records.log`, then calls
  `delete_record`.

Zones, by contrast, *are* tracked locally (`Config#add_zone`/`#sync_zones`) since `-z`/`-p` resolution
(`CLI#resolve_provider_alias`, see Provider resolution below) needs to know which source owns which zone
without an API call per command - and a typoed `-z` should fail fast with `UnknownZoneError` rather than
reaching the live API blind (`Config#zone?`). Zones are actively synced from the live API by
`add-provider`/`refresh-zones` (see above); `list-zones` just reads that locally-synced list.

DreamHost's `#list_zones` has no dedicated API to call: DreamHost removed its account/domain-management
commands, leaving `dns-list_records` (which returns every record for every domain on the account, each
tagged with a `zone`) as the only way to discover which zones exist - so it's derived as the unique `zone`
values from that same call `#list_records` already uses. A domain with zero DNS records wouldn't show up this
way, but that's a real limitation of DreamHost's current API, not a bug in ours.

Every provider client subclasses `Denise::Providers::Base` and implements `create_record`/`delete_record`/
`list_records`, raising `Denise::ProviderError` on any API/network failure. `initialize(token:, connection:
nil)` accepts an injectable Faraday connection so specs can stub HTTP via `Faraday::Adapter::Test::Stubs`
without touching the network — see `spec/denise/providers/*_spec.rb`.

### Record change log (`records.log`)

`Denise::RecordLog` (`lib/denise/record_log.rb`) appends one JSON line per record change to `records.log` in
the config directory: `timestamp`, `provider`, `alias`, `action` (`add`/`remove`), `zone`, and the record's
`name`/`type`/`value`/`ttl`. `CLI#add_record`/`#remove_record` log *after* the live provider call succeeds -
so a failed command never leaves a log entry for a change that didn't actually happen. Since records are
never stored locally (see Provider clients above), the record hash logged for `add-record` is built straight
from `--name`/`--type`/`--value`/`--ttl`; for `remove-record` it's the record `RecordTypes.find` already
pulled from the live `list_records` call to resolve `--type`, so there's no second lookup just for logging.

The log is capped at `Config#log_max_records` entries (`config.toml`'s `log_max_records`, default
`Config::DEFAULT_LOG_MAX_RECORDS` = 10000) — once exceeded, the oldest line is shifted out on every write
rather than rotating the whole file. Like `token`/`token_encrypted`, there's no dedicated command to set it:
hand-edit `log_max_records` into `config.toml`, and it takes effect on the next command since `RecordLog`
reads it from the injected `Config` on every write rather than caching it. `to_toml_without_secrets` always
shows the effective value (default or overridden), so `denise config` surfaces it even when unset.

### Record type inference (`--type`)

`--type` is optional on both `add-record` and `remove-record`; the fallback lives in `Denise::RecordTypes`
(`lib/denise/record_types.rb`), kept out of `CLI` to stay under `Metrics/ClassLength`.

- `add-record`: `RecordTypes.infer(value)` parses `--value` with `IPAddr` and returns `"A"`/`"AAAA"` for a
  valid IPv4/IPv6 address, or raises `RecordTypeRequiredError` otherwise. Only A/AAAA are inferable this way —
  a CNAME/TXT/MX value isn't a distinguishable shape, so those always need an explicit `--type`.
- `remove-record`: `RecordTypes.find(records, name, type)` takes the zone's *live* `list_records(zone:)`
  result (records are never stored locally - see Provider clients above) and either validates an explicit
  `type` against it, or falls back to `#resolve` when `type` is nil: a matching name resolves silently if
  there's exactly one, zero raises `UnknownRecordError`, and more than one (e.g. a name with both an A and a
  TXT record) raises `AmbiguousRecordTypeError` asking for `--type` to disambiguate. Either way, `#find`
  returns the matched record hash, which `CLI#remove_record` reuses for `records.log` instead of looking it
  up a second time.

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

### Table output

Every tabular command (`list-providers`, `list-zones`, `list-records`, `search`, and the `help` global-flags
block) prints through `Denise::Table.print` (`lib/denise/table.rb`), not Thor's `print_table`. Thor pads every
column but the last to a fixed width, so a row whose *trailing* cells are empty still ends in a long run of
spaces — and DreamHost never reports a TTL, so `list-records` always had an empty last column. Padded out to
the width of a DKIM `TXT` value (400+ characters), every row soft-wrapped in the terminal and read as a blank
line between records. `Table` fixes both halves: it drops columns that are empty for every record (judged on
the body rows only — a header alone isn't worth 400 columns of padding beneath it) and right-strips each line,
so only a genuinely long *value* wraps now.

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

Used by every zone/record command via `CLI#resolve_provider_alias`, in this order:

1. `-p/--provider ALIAS` if given.
2. Inferred from `-z/--zone ZONE` if exactly one source owns a zone with that name (`AmbiguousZoneError` if
   more than one does — the caller must disambiguate with `-p`).
3. The configured default source (`NoProviderError` if none is set).

For `add-record`/`remove-record`/`list-records` (the three that pass `zone:`), the resolved alias must
actually have that zone tracked locally (`Config#zone?`) — `UnknownZoneError` otherwise. This is the only
local check standing between a typoed `-z` and a live API call, since records themselves are never stored
locally to catch it downstream (see Provider clients above).

`remove-provider` and `update-token` are exceptions: they never fall back to the default and always require
the alias as an explicit positional argument (`remove-provider` also asks for confirmation, skippable with
`-y/--yes`).

`search` is another exception: `-p/--provider` additionally accepts the virtual alias `all`, meaning "every
configured source" (`Search.provider_aliases`), instead of resolving to a single one. Without `-p`, it
still falls back to the default provider like everything else — `all` must be given explicitly.

### Search (`search QUERY`)

Case-insensitive substring search across a source's zone names, record names, and record values
(`Denise::Search`, `lib/denise/search.rb`). Zone-name matching is local (`Config#list_zones` - zones are
tracked locally, see Data model above); name/value matching means records are never stored locally, so
`Search` calls `provider_client(alias).list_records(zone:)` live for every zone in scope whenever the `names`
or `values` category is requested — one API call per zone, skipped entirely if `--limit zones` excludes both.
A `ProviderError` from one zone's live query is caught and warned per-zone (`denise: ALIAS/ZONE: message`),
so one bad zone doesn't abort matches from the rest.

`-p/--provider` picks which source(s) to search — a single alias, the default provider if omitted, or every
source via the virtual alias `all` (see Provider resolution above). `--limit zones,names,values` restricts
which of the three categories are searched (`Search.categories`; unknown categories raise
`InvalidSearchLimitError`). Each result row reports which field(s) matched (`zone`, `name`, `value`, or
`name,value` if both matched on the same record) alongside the provider alias, zone, and (for record hits)
type/value/ttl.

## Commands

`config`,
`add-provider` / `list-providers` (aliased as `list-sources`) / `remove-provider` / `set-default-provider` /
`update-token`,
`add-zone` / `list-zones` / `remove-zone` / `refresh-zones`,
`add-record` / `list-records` / `remove-record` / `search`,
`version`, and `--completions [bash|zsh]` (defaults to `$SHELL`; handled in `bin/denise`, not a Thor command,
so it works without a subcommand).

Thor command methods use underscores (`add_provider`); Thor normalizes hyphenated CLI input to underscores for
dispatch, so `denise add-provider` and the `desc` help text both show the hyphenated form.

`CLI#help` overrides Thor's built-in `help` command (matching its `(command = nil, subcommand = false)`
signature exactly, since Thor calls it positionally via both `super` and its own internal dispatch — see the
`rubocop:disable Style/OptionalBooleanParameter` comment). With no command given it prints a one-line tool
description and, after `super`, a "Global flags" section documenting `--completions` and `-h`/`--help` —
neither would otherwise appear anywhere in the help output: `--completions` is intercepted in `bin/denise`
before Thor ever sees it, and `-h`/`--help` are just Thor's built-in `HELP_MAPPINGS` (`-h -? --help -D`,
aliased to the `help` command) rather than a declared option, so Thor never lists them either.
`denise help COMMAND` (a specific command) skips both additions.

**`denise COMMAND -h`/`--help` works too**, not just `-h`/`--help` as the very first word. Thor's own
`HELP_MAPPINGS` only checks `argv[0]`, so without help `denise add-record --help` would be parsed as a regular
(unrecognized) option for `add-record` instead of showing its help. `CLI.dispatch` is overridden (in
`CLIDispatch`) to catch `-h`/`--help` anywhere in a command's own args *before* Thor's normal dispatch runs, and redirects to
`help COMMAND` instead — see the method comment for the exact mechanics (it works by reconstructing the args
Thor's own dispatch expects for invoking `help` with a command name, not by calling the command and then
intercepting). Because of this, `-h`/`--help` are added to every command's completions in
`Completions.flags_for` explicitly (they aren't a declared `method_option`/`class_option`, so they can't be
picked up automatically the way other flags are).

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
