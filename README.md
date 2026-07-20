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
