require_relative "lib/commissar"

Gem::Specification.new do |spec|
  spec.name          = "commissar"
  spec.version       = Commissar::VERSION
  spec.authors       = ["Mauro Eldritch"]
  spec.email         = ["mauroeldritch@gmail.com"]
  spec.summary       = "Supply chain attack detector for RubyGems"
  spec.description   = "Static analysis tool that scans RubyGems for indicators of supply chain compromise: malicious gemspecs, suspicious URLs, credential exfiltration, obfuscated payloads, and more."
  spec.homepage      = "https://github.com/mauroeldritch/commissar"
  spec.license       = "MIT"
  spec.metadata = {
    "bug_tracker_uri"       => "https://github.com/mauroeldritch/commissar/issues",
    "changelog_uri"         => "https://github.com/mauroeldritch/commissar/blob/main/CHANGELOG.md",
    "source_code_uri"       => "https://github.com/mauroeldritch/commissar",
    "rubygems_mfa_required" => "true"
  }
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir[
    "lib/**/*.rb",
    "exe/**/*",
    "conf/**/*.txt",
    "LICENSE",
    "README.md",
    "CHANGELOG.md"
  ]
  spec.bindir        = "exe"
  spec.executables   = ["commissar"]
  spec.add_dependency "colorize", "~> 1.1"
end
