# Commissar

Static analysis tool for detecting potential supply chain attacks in RubyGems.

Scans a gem for malicious indicators before you install it: suspicious network calls, credential access, file reads, obfuscated payloads, dangerous gemspec patterns, and more.

## Install

```
gem install commissar
```

## Usage

```
commissar <gem_name> [version]
```

Examples:

```
commissar rails
commissar nokogiri 1.16.0
commissar --local /tmp/my-gemfile.gem
```

Output groups findings by category with severity (`HIGH`, `MED`, `LOW`), file, and line number. A risk score (0–100) and a final recommendation are printed at the end.

## Configuration

On first run, Commissar copies default pattern lists to `~/.config/commissar/`. Edit those files to add or remove patterns without touching the source.

Load order: `~/.config/commissar/` → `./conf/` → gem defaults.

Files:

| File | Purpose |
|---|---|
| `suspicious_urls.txt` | Domains associated with exfiltration or staging |
| `suspicious_functions.txt` | Dangerous Ruby methods and classes |
| `suspicious_shell.txt` | Shell commands used for data exfiltration or staging |
| `credential_paths.txt` | Filesystem paths and env vars containing secrets and sensitive info |

Each file is plain text, one entry per line. Lines starting with `#` are ignored. Feel free to fine-tune as much as you need!

## What it detects

- Version published in the last 72 hours
- Recent owner changes or new maintainer accounts
- Missing or broken homepage/source URIs
- Gemspec `extensions` pointing to `extconf.rb` or `Rakefile` (run on `gem install`)
- Top-level code in the gemspec
- `eval`, `system`, backticks, and other dangerous function calls
- Outbound network calls (Telegram bots, Discord webhooks, paste sites, webhook services)
- `curl`/`wget` POST commands and Ruby HTTP POST equivalents
- Base64-encoded or zlib-compressed payloads
- High Shannon entropy strings (>4.5 bits/char)
- Lines over 500 characters (common in padding and hiding schemes)
- Access to credentials via `ENV` or filesystem paths
- Wallet address patterns and clipboard hijacking (Web3)

## Development

```
bundle install
rake test
```

## License

MIT — see [LICENSE](LICENSE).
