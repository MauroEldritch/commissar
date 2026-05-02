require "rubygems"
require "rubygems/package"
require "net/http"
require "uri"
require "json"
require "yaml"
require "tmpdir"
require "fileutils"
require "zlib"
require "base64"
require "time"
require "set"
require "csv"
require "colorize"

module Commissar
  VERSION = "0.1.0"

	SEVERITY_WEIGHT = { "CRIT" => 15, "HIGH" => 7, "MED" => 3, "LOW" => 1 }.freeze

	CONFIG_FILES = %w[
		suspicious_urls.txt
		suspicious_functions.txt
		suspicious_shell.txt
		credential_paths.txt
		top_gems.txt
	].freeze

	module Config
		USER_DIR    = File.expand_path("~/.config/commissar")
		BUNDLED_DIR = File.expand_path("../../conf", __FILE__)

		def self.load(filename)
			path = resolve(filename)
			return [] unless path

			File.readlines(path, chomp: true)
				.reject { |l| l.strip.empty? || l.strip.start_with?("#") }
		end

		def self.resolve(filename)
			candidates = [
				File.join(USER_DIR, filename),
				File.join(Dir.pwd, "conf", filename),
				File.join(BUNDLED_DIR, filename)
			]
			candidates.find { |p| File.exist?(p) }
		end

		def self.bootstrap_user_dir
			return if File.exist?(USER_DIR)

			FileUtils.mkdir_p(USER_DIR)
			CONFIG_FILES.each do |f|
				src = File.join(BUNDLED_DIR, f)
				FileUtils.cp(src, File.join(USER_DIR, f)) if File.exist?(src)
			end
			puts "Created ~/.config/commissar/ with default config files.".colorize(:cyan)
		end
	end

	Finding = Struct.new(:category, :severity, :message, :file, :line, :snippet, keyword_init: true) do
		def weight
			SEVERITY_WEIGHT.fetch(severity, 0)
		end

		def to_s
			loc = [file, line].compact.join(":")
			loc_str = loc.empty? ? "" : " => #{loc}"
			"[#{severity.ljust(4)}] #{message}#{loc_str}"
		end
	end

	class Scanner
		RUBYGEMS_API  = "https://rubygems.org/api/v1"
		HOMOGLYPH_RE  = /[аеорсхѕіїӏορᴏᴀ]/

		attr_reader :gem_name, :version, :findings

		def initialize(gem_name, version: nil, local_path: nil)
			@gem_name   = gem_name
			@version    = version
			@local_path = local_path
			@findings   = []
			@metadata   = {}
			@files      = {}
			@owners     = :pending
			@suspicious_urls      = Config.load("suspicious_urls.txt")
			@suspicious_functions = Config.load("suspicious_functions.txt")
			@suspicious_shell     = Config.load("suspicious_shell.txt")
			@credential_paths     = Config.load("credential_paths.txt")
			@top_gems             = Config.load("top_gems.txt")
		end

		def scan
			puts "\n#{"[*] Scanning: #{gem_name}".colorize(:white)} #{version_label}"
			fetch_metadata
			fetch_and_unpack
			run_metadata_checks
			run_diff_checks
			run_gemspec_checks
			run_function_checks
			run_url_checks
			run_shell_checks
			run_encoding_checks
			run_credential_checks
			run_web3_checks
			self
		end

		def risk_score
			raw = @findings.sum(&:weight)
			[raw, 100].min
		end

		def report(format: :text, io: $stdout)
			case format
			when :csv   then report_csv(io)
			when :json  then report_json(io)
			when :table then report_table(io)
			else             report_text(io)
			end
		end

		private

		def report_text(io)
			grouped = @findings.group_by(&:category)
			if grouped.empty?
				io.puts "  #{"No findings.".colorize(:green)}"
			else
				grouped.each do |category, items|
					io.puts "\n#{category_header(category)} (#{items.size})"
					items.each do |f|
						io.puts "  └─ #{colorize_finding(f)}"
						io.puts "        #{f.snippet.colorize(:light_black)}" if f.snippet
					end
				end
			end
			io.puts "\n#{score_line}"
		end

		def report_csv(io)
			io.puts CSV.generate_line(%w[gem version category severity message file line snippet])
			v = @version || @metadata["version"] || ""
			@findings.each do |f|
				io.puts CSV.generate_line([gem_name, v, f.category, f.severity, f.message, f.file, f.line, f.snippet])
			end
		end

		def report_json(io)
			v = @version || @metadata["version"]
			io.puts JSON.pretty_generate(
				gem:        gem_name,
				version:    v,
				scanned_at: Time.now.iso8601,
				risk_score: risk_score,
				verdict:    verdict_text,
				findings:   @findings.map { |f|
					{ category: f.category, severity: f.severity, message: f.message,
					  file: f.file, line: f.line, snippet: f.snippet }
				}
			)
		end

		def report_table(io)
			if @findings.empty?
				io.puts "No findings."
				io.puts "\n#{score_line}"
				return
			end

			col_defs = [
				{ header: "SEV",      max: 4  },
				{ header: "CATEGORY", max: 22 },
				{ header: "MESSAGE",  max: 40 },
				{ header: "FILE",     max: 28 },
				{ header: "LINE",     max: 5  },
				{ header: "SNIPPET",  max: 50 },
			]
			rows = @findings.map { |f|
				[f.severity.to_s, f.category.to_s, f.message.to_s, f.file.to_s, f.line.to_s, f.snippet.to_s]
			}
			widths = col_defs.each_with_index.map do |col, i|
				content_max = rows.map { |r| r[i].length }.max || 0
				[col[:header].length, [content_max, col[:max]].min].max
			end

			sep = "+" + widths.map { |w| "-" * (w + 2) }.join("+") + "+"
			io.puts sep
			io.puts "|" + col_defs.each_with_index.map { |c, i| " #{c[:header].ljust(widths[i])} " }.join("|") + "|"
			io.puts sep
			rows.each do |row|
				io.puts "|" + row.each_with_index.map { |cell, i|
					s = cell.length > widths[i] ? "#{cell[0, widths[i] - 1]}…" : cell
					" #{s.ljust(widths[i])} "
				}.join("|") + "|"
			end
			io.puts sep
			io.puts "\n#{score_line}"
		end

		def fetch_metadata
			uri = URI("#{RUBYGEMS_API}/gems/#{gem_name}.json")
			response = Net::HTTP.get_response(uri)
			unless response.is_a?(Net::HTTPSuccess)
				warn "  Could not fetch metadata for #{gem_name}".colorize(:yellow)
				return
			end
			@metadata = JSON.parse(response.body)
			@version ||= @metadata["version"]
		end

		def fetch_and_unpack
			if @local_path
				@files = unpack_gem(@local_path)
				return
			end

			Dir.mktmpdir("commissar_") do |tmpdir|
				gem_path = download_gem(tmpdir)
				return unless gem_path
				@files = unpack_gem(gem_path)
			end
		end

		def download_gem(dir, version: nil)
			ver  = version || @version || @metadata["version"]
			uri  = URI("https://rubygems.org/gems/#{gem_name}-#{ver}.gem")
			response = Net::HTTP.get_response(uri)
			unless response.is_a?(Net::HTTPSuccess)
				warn "  Could not download .gem for #{gem_name} #{ver}".colorize(:yellow)
				return nil
			end
			path = File.join(dir, "#{gem_name}-#{ver}.gem")
			File.binwrite(path, response.body)
			path
		end

		def unpack_gem(gem_path)
			extract_dir = nil
			files = {}
			extract_dir = Dir.mktmpdir("commissar_x_")
			pkg = Gem::Package.new(gem_path)
			pkg.extract_files(extract_dir)
			pkg.contents.each do |entry|
				full_path = File.join(extract_dir, entry)
				next unless File.file?(full_path)
				next if File.size(full_path) > 1_048_576
				files[entry] = safe_read(full_path)
			end
			files
		rescue => e
			warn "  Could not unpack gem: #{e.message}".colorize(:yellow)
			{}
		ensure
			FileUtils.rm_rf(extract_dir) if extract_dir
		end

		def safe_read(path)
			File.binread(path).encode("UTF-8", "binary", invalid: :replace, undef: :replace, replace: "")
		rescue
			nil
		end

		def run_metadata_checks
			check_typosquatting
			return if @metadata.empty?
			check_version_age
			check_owner_changes
			check_missing_uris
		end

		def check_typosquatting
			return if @top_gems.empty?
			closest = @top_gems.min_by { |g| levenshtein(gem_name, g) }
			dist    = levenshtein(gem_name, closest)
			return if dist == 0 || dist > 2
			severity = dist == 1 ? "MED" : "LOW"
			add_finding(
				category: "METADATA",
				severity: severity,
				message: "Possible typosquat of '#{closest}' (Levenshtein distance: #{dist})"
			)
		end

		def run_diff_checks
			return if @files.empty?
			versions = fetch_versions
			return unless versions && versions.size >= 2
			prev_version_num = versions.map { |v| v["number"] }.reject { |n| n == @version }.first
			return unless prev_version_num
			Dir.mktmpdir("commissar_diff_") do |tmpdir|
				gem_path = download_gem(tmpdir, version: prev_version_num)
				return unless gem_path
				prev_files = unpack_gem(gem_path)
				check_version_diff(prev_files, prev_version_num)
			end
		end

		def check_version_diff(prev_files, prev_version)
			current_keys = Set.new(@files.keys)
			prev_keys    = Set.new(prev_files.keys)
			(current_keys - prev_keys).each do |f|
				add_finding(category: "DIFF", severity: "LOW", message: "New file vs #{prev_version}: #{f}")
			end
			(prev_keys - current_keys).each do |f|
				add_finding(category: "DIFF", severity: "LOW", message: "Removed vs #{prev_version}: #{f}")
			end
			(current_keys & prev_keys).each do |f|
				next if @files[f] == prev_files[f]
				add_finding(category: "DIFF", severity: "LOW", message: "Modified vs #{prev_version}: #{f}")
			end
		end

		def fetch_versions
			uri = URI("#{RUBYGEMS_API}/versions/#{gem_name}.json")
			response = Net::HTTP.get_response(uri)
			return nil unless response.is_a?(Net::HTTPSuccess)
			JSON.parse(response.body)
		rescue
			nil
		end

		def check_version_age
			return unless @metadata["version_created_at"]
			published_at = Time.parse(@metadata["version_created_at"])
			age_hours = (Time.now - published_at) / 3600
			return unless age_hours < 72
			add_finding(
				category: "METADATA",
				severity: "LOW",
				message: "Version published #{age_hours.round}h ago (threshold: 72h)"
			)
		end

		def check_owner_changes
			@owners = fetch_owners if @owners == :pending
			return if @owners.nil? || !@owners.is_a?(Array) || @owners.empty?
			return unless @owners.size == 1
			handle   = @owners.first["handle"]
			gem_age  = gem_age_days
			severity = (gem_age && gem_age < 30) ? "MED" : "LOW"
			label    = (severity == "MED") ? "new gem with single maintainer" : "single maintainer"
			add_finding(category: "METADATA", severity: severity, message: "#{label.capitalize}: #{handle}")
		end

		def fetch_owners
			uri = URI("#{RUBYGEMS_API}/gems/#{gem_name}/owners.yaml")
			response = Net::HTTP.get_response(uri)
			return nil unless response.is_a?(Net::HTTPSuccess)
			YAML.safe_load(response.body)
		end

		def gem_age_days
			return nil unless @metadata["created_at"]
			(Time.now - Time.parse(@metadata["created_at"])) / 86400
		end

		def check_missing_uris
			homepage   = @metadata["homepage_uri"].to_s.strip
			source_uri = @metadata["source_code_uri"].to_s.strip
			if homepage.empty? && source_uri.empty?
				add_finding(category: "METADATA", severity: "MED", message: "No source URIs available (no homepage_uri or source_code_uri)")
				return
			end
			if homepage.empty?
				add_finding(category: "METADATA", severity: "LOW", message: "Missing homepage_uri")
			end
			if source_uri.empty?
				add_finding(category: "METADATA", severity: "LOW", message: "Missing source_code_uri")
			end
		end

		def run_gemspec_checks
			gemspecs = @files.select { |name, _| name.end_with?(".gemspec") }
			return if gemspecs.empty?
			gemspecs.each do |filename, content|
				next if content.nil?
				check_gemspec_extensions(content, filename)
				check_gemspec_post_install(content, filename)
			end
		end

		def check_gemspec_extensions(content, filename)
			scan_lines(content, filename).each do |line, file, lineno|
				next unless line.match?(/\.extensions\s*[=<]/)
				if line.match?(/extconf\.rb|Rakefile/i)
					add_finding(
						category: "GEMSPEC", severity: "HIGH",
						message: "Native extension executes on gem install: #{line.strip}",
						file: file, line: lineno, snippet: line
					)
				else
					add_finding(
						category: "GEMSPEC", severity: "MED",
						message: "Native extension declared in gemspec",
						file: file, line: lineno, snippet: line
					)
				end
			end
		end

		def check_gemspec_post_install(content, filename)
			scan_lines(content, filename).each do |line, file, lineno|
				next unless line.match?(/post_install_message\s*=/)
				next unless line.match?(/https?:\/\/|curl\s|wget\s|sudo\s|chmod\s/i)
				add_finding(
					category: "GEMSPEC", severity: "MED",
					message: "Suspicious post_install_message content",
					file: file, line: lineno, snippet: line
				)
			end
		end

		def run_function_checks
			scan_files_for_patterns(@suspicious_functions, "DANGEROUS FUNCTIONS", files: ruby_source_files)
		end

		def run_url_checks
			scan_files_for_patterns(@suspicious_urls, "SUSPICIOUS URLS")
		end

		def run_shell_checks
			scan_files_for_patterns(@suspicious_shell, "SHELL/EXFIL")
		end

		def run_encoding_checks
			ruby_source_files.each do |filename, content|
				next if content.nil?
				scan_lines(content, filename).each do |line, file, lineno|
					check_entropy(line, file, lineno)
					check_line_length(line, file, lineno)
					check_homoglyphs(line, file, lineno)
				end
			end
		end

		def check_entropy(line, file, lineno)
			return if line.length < 20
			e = shannon_entropy(line)
			return unless e > 5.5
			add_finding(
				category: "ENCODING", severity: "HIGH",
				message: "High entropy line (#{e.round(1)} bits/char, #{line.length} chars)",
				file: file, line: lineno, snippet: line
			)
		end

		def check_line_length(line, file, lineno)
			return unless line.length > 500
			add_finding(
				category: "ENCODING", severity: "MED",
				message: "Long line (#{line.length} chars)",
				file: file, line: lineno, snippet: line
			)
		end

		def check_homoglyphs(line, file, lineno)
			return unless line.match?(HOMOGLYPH_RE)
			add_finding(
				category: "ENCODING", severity: "HIGH",
				message: "Homoglyph characters detected",
				file: file, line: lineno, snippet: line
			)
		end

		def shannon_entropy(str)
			return 0.0 if str.empty?
			freq = Hash.new(0)
			str.each_char { |c| freq[c] += 1 }
			len = str.length.to_f
			-freq.values.sum { |count| (p = count / len) * Math.log2(p) }
		end

		def run_credential_checks
			scan_files_for_patterns(@credential_paths, "CREDENTIALS")
		end

		def run_web3_checks
			return if @files.empty?
			wallet_patterns = [
				["HIGH", "ETH wallet address", /0x[a-fA-F0-9]{40}\b/],
				["HIGH", "BTC wallet address", /\b[13][a-km-zA-HJ-NP-Z1-9]{25,34}\b/],
				["HIGH", "BTC bech32 address", /\bbc1[a-z0-9]{6,87}\b/i]
			]
			clipboard_patterns = %w[xclip pbcopy pbpaste xdotool Clipboard.]
			web3_refs          = %w[metamask ethers wagmi viem hardhat truffle]
			scannable_files.each do |filename, content|
				next if content.nil?
				scan_lines(content, filename).each do |line, file, lineno|
					wallet_patterns.each do |severity, label, re|
						next unless line.match?(re)
						add_finding(category: "WEB3", severity: severity, message: label, file: file, line: lineno, snippet: line)
					end
					clipboard_patterns.each do |pattern|
						next unless line.include?(pattern)
						add_finding(category: "WEB3", severity: "HIGH", message: "Clipboard access: #{pattern}", file: file, line: lineno, snippet: line)
					end
					web3_refs.each do |ref|
						next unless line.downcase.include?(ref)
						add_finding(category: "WEB3", severity: "LOW", message: "Web3 reference: #{ref}", file: file, line: lineno, snippet: line)
					end
				end
			end
		end

		def add_finding(category:, severity:, message:, file: nil, line: nil, snippet: nil)
			@findings << Finding.new(
				category: category,
				severity: severity,
				message:  message,
				file:     file,
				line:     line,
				snippet:  snippet ? truncate(snippet.strip) : nil
			)
		end

		def truncate(str, max = 100)
			str.length > max ? "#{str[0, max]}…" : str
		end

		def verdict_text
			score = risk_score
			if score >= 70    then "DANGEROUS, DO NOT INSTALL"
			elsif score >= 40 then "REVIEW CAREFULLY"
			else                   "Looks safe but exercise caution"
			end
		end

		def levenshtein(a, b)
			return b.length if a.empty?
			return a.length if b.empty?
			prev = (0..b.length).to_a
			a.each_char.with_index(1) do |ca, i|
				curr = [i]
				b.each_char.with_index(1) do |cb, j|
					cost = ca == cb ? 0 : 1
					curr << [prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost].min
				end
				prev = curr
			end
			prev[b.length]
		end

		RUBY_EXTENSIONS = %w[.rb .gemspec .rake .ru].freeze
		RUBY_NAMES      = %w[Rakefile Gemfile].freeze

		def scannable_files
			@files.reject { |name, _| name.end_with?(".md") }
		end

		def ruby_source_files
			scannable_files.select { |name, _|
				RUBY_EXTENSIONS.include?(File.extname(name)) ||
					RUBY_NAMES.include?(File.basename(name))
			}
		end

		def scan_files_for_patterns(patterns, category, files: nil)
			target = files || scannable_files
			return if target.empty?
			patterns.each do |entry|
				severity, pattern = parse_config_entry(entry)
				target.each do |filename, content|
					scan_lines(content, filename).each do |line, file, lineno|
						next unless line.include?(pattern)
						add_finding(category: category, severity: severity, message: pattern, file: file, line: lineno, snippet: line)
					end
				end
			end
		end

		def parse_config_entry(entry)
			if entry =~ /\A(CRIT|HIGH|MED|LOW):(.*)\z/
				[$1, $2]
			else
				["MED", entry]
			end
		end

		def scan_lines(content, file_name)
			return [] if content.nil?
			content.each_line.with_index(1).map { |line, num| [line.chomp, file_name, num] }
		end

		def version_label
			v = @version || @metadata["version"]
			v ? "(#{v})".colorize(:light_black) : ""
		end

		def category_header(cat)
			titles = {
				"METADATA"            => "[*] METADATA",
				"GEMSPEC"             => "[*] GEMSPEC",
				"DANGEROUS FUNCTIONS" => "[*] DANGEROUS FUNCTIONS",
				"SUSPICIOUS URLS"     => "[*] SUSPICIOUS URLS",
				"SHELL/EXFIL"         => "[*] SHELL/EXFIL",
				"ENCODING"            => "[*] ENCODED PAYLOADS",
				"CREDENTIALS"         => "[*] CREDENTIALS",
				"WEB3"                => "[*] WEB3",
				"DIFF"                => "[*] DIFF"
			}
			titles.fetch(cat, cat).colorize(:yellow)
		end

		def colorize_finding(finding)
			color = case finding.severity
				when "CRIT" then :magenta
				when "HIGH" then :red
				when "MED"  then :yellow
				when "LOW"  then :light_black
			end
			finding.to_s.colorize(color)
		end

		def score_line
			score = risk_score
			color = if score >= 70    then :red
				elsif score >= 40 then :yellow
				else                   :green
			end
			icon = if score >= 70    then "[!]"
				elsif score >= 40 then "[?]"
				else                   "[*]"
			end
			"#{icon} Risk score: #{score}/100 — #{verdict_text}".colorize(color)
		end
	end
end
