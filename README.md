# Commissar

Static analysis tool for detecting potential supply chain attacks in RubyGems.

Scans a gem for malicious indicators before you install it: suspicious network calls, credential access, file reads, obfuscated payloads, dangerous gemspec patterns, and more.

## Install

```
gem install commissar
```

## Usage

```
commissar <gem_name> [version] [options]
commissar --local PATH [options]
```

Examples:

```
#Normal use
commissar rails

#Scan a specific version
commissar nokogiri 1.16.0

#Scan a local gem
commissar --local /tmp/my-gemfile.gem

#JSON output to screen or to file
commissar rails --format json > commissar.json
commissar rails --format json | jq

#Table format
commissar rails --format table

#CSV (format is assumed from the output file extension)
commissar rails --output results.csv

#No colour, please
commissar rails --no-color

#I just want the score for my automation tool/pipeline
commissar rails --score-only
```

Output groups findings by category with severity (`CRIT`, `HIGH`, `MED`, `LOW`, `INFO`), file, and line number. A risk score (0–100) and a final recommendation are printed at the end.

You can use `--score-only` to quickly integrate Commissar with your CI/CD pipelines. You will get a plain integer representing the risk score alone, without banner or any other information.

## Configuration

Pattern lists live in the `conf/` directory of the repo (or the gem's bundled `conf/` when installed). Edit those files directly to add or remove patterns.

Files:

| File | Purpose |
|---|---|
| `suspicious_urls.txt` | Domains associated with exfiltration or staging |
| `suspicious_functions.txt` | Dangerous Ruby methods and classes |
| `suspicious_shell.txt` | Shell commands used for data exfiltration or staging |
| `credential_paths.txt` | Filesystem paths and env vars containing secrets and sensitive info |
| `clipboard_patterns.txt` | System calls and APIs used for clipboard access |
| `known_bad_wallets.txt` | OFAC-sanctioned and DOJ-documented wallet addresses |
| `severity.txt` | Numeric weights for each severity level |

Each file is plain text, one entry per line. Lines starting with `#` are ignored.

### Pattern format

```
SEVERITY:PATTERN
```

Examples:

```
HIGH:eval
CRIT:api.telegram.org
MED:pastebin.com
```

### Antipatterns

Any fields after the first pair are treated as antipatterns: if the line matches the pattern but also contains any antipattern, the finding is suppressed. Useful for reducing false positives from legitimate metaprogramming.

```
SEVERITY:PATTERN:ANTIPATTERN:ANTIPATTERN:...
```

Examples:

```
HIGH:eval:&:binding
HIGH:instance_eval:&
HIGH:class_eval:&:__FILE__
```

`::` in Ruby namespace notation is never treated as a separator, so `MED:Net::HTTP` works as expected.

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
- High Shannon entropy strings (>5.5 bits/char)
- Lines over 500 characters (common in padding and hiding schemes)
- Access to credentials via `ENV` or filesystem paths
- Clipboard hijacking (Web3)
- Hardcoded wallet addresses: known OFAC/DOJ-sanctioned addresses flagged as `CRIT`, unknown addresses as `HIGH`

## Development

```
bundle install
rake test
```

## Contributing

I appreciate your interest! Feel free to tweak the configuration files and detection expressions and share them with me and the community, always happy to hear back from users of my tools.

If you believe your change deserves a dedicated fork, go for it!

## License

MIT - see [LICENSE](LICENSE).
