DeNiSe CLI
==========

A thrown together simple DNS manager for hobbyists.

Providers
---------

- Cloudflare
- DreamHost
- AWS Route 53 (`--token` is `ACCESS_KEY_ID:SECRET_ACCESS_KEY`, since AWS auth is a signature, not a bearer token)

TODO
----

Planned providers:

- [ ] GCP Cloud DNS
- [ ] HostGator
- [ ] Azure DNS

Configuration
-------------

Configuration lives in `~/.config/denise-cli/config.toml`. API tokens are
encrypted at rest using a key auto-generated at `~/.config/denise-cli/key`
(created with `0600` permissions on first run). Manage configuration entirely
from the command line — see `denise help` for available commands. Run
`denise config` to view the current configuration (secrets omitted); it
creates a skeleton file first if one doesn't exist yet.

`denise add-provider` automatically imports the zones that key/account
manages at the provider. Run `denise refresh-zones` any time afterward to
pick up zones added or removed at the provider since — for a specific
source with `-p ALIAS`, or every configured source if `-p` is omitted.

Rotated a key at the provider? Run `denise update-token ALIAS` to replace
that source's stored token (pass `--token`, or omit it to be prompted
without echo). Its zones and other settings are kept.

Only zones are tracked in `config.toml` — DNS records themselves are never
stored locally. `list-records`, `search`, and `remove-record`'s automatic
`--type` detection all query the provider live, so they always reflect
what's actually there (at the cost of an API call).

Every `add-record`/`remove-record` is logged as one JSON line (timestamp,
provider, alias, action, and the record) to `~/.config/denise-cli/records.log`.
It's capped at `log_max_records` entries (default 10000, hand-editable in
`config.toml`) — past the cap, the oldest entry is shifted out rather than
rotating the whole file.

Pass `-v`/`--verbose` (after the command, e.g. `denise refresh-zones -v`) to
print each HTTP request and response status to stderr. Tokens and secrets
are never included, however verbose you get.

Shell completions
------------------

`denise --completions` prints a completion script for commands and flags
(detected from `$SHELL` by default, or pass `bash`/`zsh` explicitly).

### Bash

Add this line to `~/.bashrc` (or `~/.bash_profile` on macOS), then restart
your shell or `source` it:

```sh
eval "$(denise --completions bash)"
```

Or, if your system has `bash-completion` installed, drop the script into
its directory instead — the path varies by system, e.g.
`/etc/bash_completion.d/denise` on Linux, or via Homebrew on macOS:

```sh
denise --completions bash > "$(brew --prefix)/etc/bash_completion.d/denise"
```

### Zsh

Add these lines to `~/.zshrc`, then restart your shell or `source` it:

```sh
eval "$(denise --completions zsh)"
compdef _denise denise
```

Or, the more conventional zsh way: save the script into a directory on your
`fpath` and let `compinit` autoload it (it already starts with the
`#compdef denise` line that requires):

```sh
mkdir -p ~/.zsh/completions
denise --completions zsh > ~/.zsh/completions/_denise
```

Then, in `~/.zshrc`, add that directory to `fpath` *before* `compinit` runs:

```sh
fpath=(~/.zsh/completions $fpath)
autoload -Uz compinit && compinit
```

Either way, `denise <TAB>` should suggest commands, and `denise add-record
<TAB>` should suggest that command's flags.
