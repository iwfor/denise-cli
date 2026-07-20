DeNiSe CLI
==========

A thrown together simple DNS manager for hobbyists.

Providers
---------

- Cloudflare
- DreamHost

Configuration
-------------

Configuration lives in `~/.config/denise-cli/config.toml`. API tokens are
encrypted at rest using a key auto-generated at `~/.config/denise-cli/key`
(created with `0600` permissions on first run). Manage configuration entirely
from the command line — see `denise help` for available commands.
