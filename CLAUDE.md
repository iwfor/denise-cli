# DeNiSe CLI

A thrown together simple DNS manager for hobbyists, written in Ruby.

## Providers

- Cloudflare
- DreamHost

## Structure

- `bin/denise` — CLI entry point; intercepts `--completions` before handing off to Thor
- `lib/denise.rb` — top-level requires
- `lib/denise/cli.rb` — Thor-based command definitions
- `lib/denise/config.rb` — reads/writes `config.toml`; source/zone/entry CRUD, alias resolution
- `lib/denise/crypto.rb` — key management + AES-256-GCM encrypt/decrypt for tokens
- `lib/denise/providers.rb` — registry of known providers and their default aliases
- `lib/denise/paths.rb` — config directory/file path resolution (`DENISE_CONFIG_DIR` override for tests)
- `lib/denise/completions.rb` — bash/zsh completion script generation
- `lib/denise/errors.rb` — typed error classes, each rescued in the CLI and printed as `denise: <message>`
- `lib/denise/version.rb` — version constant
- `spec/` — RSpec tests (each example runs against a fresh `Dir.mktmpdir` config dir)

## Stack

- Ruby, managed with Bundler (`Gemfile`)
- `thor` for the CLI
- `faraday` for provider HTTP APIs (not yet wired up — see Roadmap)
- `tomlib` for TOML config read/write
- `rspec` for tests, `rubocop` for linting, `bundler-audit` for dependency vulnerability scanning
- `base64` and `reline` are pulled in explicitly since they stopped being Ruby default gems as of 3.4/4.0

## Configuration

Config lives at `~/.config/denise-cli/config.toml` (override with `DENISE_CONFIG_DIR`, used by the test suite).
A per-install encryption key is auto-created at `~/.config/denise-cli/key` with `0600` permissions on first run
(`Denise::Crypto#ensure_key!`) and used to AES-256-GCM encrypt every provider API token before it's written to
the TOML file. The key is never rotated automatically — rotating it would orphan already-encrypted tokens.

### Data model

A **source** is one configured instance of a provider: a provider type (`cloudflare`, `dreamhost`, ...), an
encrypted API token, and the zones managed through it. Sources are keyed in the config by a unique **alias**
(`dh`, `cf`, ...). Duplicate provider types are allowed — e.g. two DreamHost accounts — as long as their
aliases differ.

- Each provider type has a default alias (`Denise::Providers::KNOWN`, e.g. `dreamhost` → `dh`).
- An explicit `--alias` must be unique or `add-provider` rejects it (`AliasConflictError`).
- An omitted `--alias` uses the provider's default alias, auto-numbered (`dh`, `dh2`, `dh3`, ...) if already taken.
- The default *source* is whichever alias was added first, unless overridden with `--default` on `add-provider`
  or later via `set-default-provider`.

Zones live under their source; entries (DNS records: name/type/value/ttl) live under their zone. Entries are
config-only for now — no live provider API calls are made yet (see Roadmap).

### Provider resolution (`-p`/`--provider`)

Used by every zone/entry command via `CLI#resolve_provider_alias`, in this order:

1. `-p/--provider ALIAS` if given.
2. Inferred from `-z/--zone ZONE` if exactly one source owns a zone with that name (`AmbiguousZoneError` if
   more than one does — the caller must disambiguate with `-p`).
3. The configured default source (`NoProviderError` if none is set).

`remove-provider` is the one exception: it never falls back to the default and always requires the alias as an
explicit positional argument, plus a confirmation prompt (skippable with `-y/--yes`).

## Commands

`add-provider` / `list-providers` / `remove-provider` / `set-default-provider`,
`add-zone` / `list-zones` / `remove-zone`,
`add-entry` / `list-entries` / `remove-entry`,
`version`, and `--completions [bash|zsh]` (defaults to `$SHELL`; handled in `bin/denise`, not a Thor command,
so it works without a subcommand).

Thor command methods use underscores (`add_provider`); Thor normalizes hyphenated CLI input to underscores for
dispatch, so `denise add-provider` and the `desc` help text both show the hyphenated form.

## Conventions

- **Test everything.** Every new module, command, or behavior change needs RSpec coverage in `spec/` before
  it's considered done — not just the happy path, but conflict/error cases (see the alias-conflict,
  ambiguous-zone, and unknown-* examples in the existing specs as the bar to match).
- **Before every commit**, run all three and don't commit unless all three are clean:
  - `bundle exec rspec`
  - `bundle exec rubocop`
  - `bundle exec bundler-audit check --update`
- `Style/StringLiterals` is configured for double-quoted strings project-wide.
- New provider integrations belong under `lib/denise/providers/` behind a shared interface (not yet created —
  only the alias registry exists so far).
- **7-day age gate on new Gemfile dependencies.** Before adding any gem, check its release date on
  rubygems.org (`https://rubygems.org/api/v1/versions/<gem>.json`) and pin the Gemfile to the newest version
  that is at least 7 days old as of the current date (exact pin, e.g. `gem "rubocop", "1.88.2"`, not `~>`).
  This guards against a supply-chain attack landing in a brand-new release before it's had time to be
  scrutinized.

## Roadmap / explicitly deferred

- Live Cloudflare/DreamHost API calls for `add/list/remove-entry` (currently local-config-only, by design —
  confirmed with the user rather than assumed).
- A real provider client abstraction once API calls are wired up.
