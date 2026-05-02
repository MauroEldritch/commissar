# Changelog

## [0.1.0] - 2026-04-30

Initial release.

- CLI: `commissar <gem_name> [version]`
- Config loading from `~/.config/commissar/`, `./conf/`, or gem defaults
- Bootstraps user config directory on first run
- Skeleton detectors for: metadata, gemspec, dangerous functions, suspicious URLs, shell/exfil commands, encoding, credentials, Web3
- Risk score 0–100 with color-coded output
