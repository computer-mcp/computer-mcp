#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
CATALOG="$ROOT_DIR/Sources/ComputerMCPApp/Resources/Localizable.xcstrings"
TEMP_DIR=$(/usr/bin/mktemp -d /tmp/computer-mcp-localization.XXXXXX)
trap '/bin/rm -rf -- "$TEMP_DIR"' EXIT

fail() {
  echo "error: $1" >&2
  exit 1
}

[[ -f "$CATALOG" ]] || fail "Missing App String Catalog."
/usr/bin/jq empty "$CATALOG"

duplicate_keys=$(
  /usr/bin/sed -n 's/^    "\(.*\)" : .*/\1/p' "$CATALOG" \
    | /usr/bin/sort \
    | /usr/bin/uniq -d
)
[[ -z "$duplicate_keys" ]] \
  || fail "Duplicate String Catalog keys:\n$duplicate_keys"

/usr/bin/env -u GEM_HOME -u GEM_PATH \
  /usr/bin/ruby --disable-gems -rjson - "$ROOT_DIR" "$CATALOG" <<'RUBY'
root, catalog_path = ARGV
catalog = JSON.parse(File.read(catalog_path)).fetch("strings")
abort "error: App String Catalog unexpectedly contains fewer than 450 keys." if catalog.length < 450

placeholder_pattern = /%(?:\d+\$)?[@dfiu]/
catalog.each do |key, entry|
  localizations = entry.fetch("localizations")
  values = %w[en zh-Hans].to_h do |locale|
    unit = localizations.fetch(locale).fetch("stringUnit")
    abort "error: #{key.inspect} is not translated for #{locale}." unless unit["state"] == "translated"
    value = unit.fetch("value")
    abort "error: #{key.inspect} is empty for #{locale}." if value.empty?
    [locale, value]
  end
  en_placeholders = values.fetch("en").scan(placeholder_pattern)
  zh_placeholders = values.fetch("zh-Hans").scan(placeholder_pattern)
  abort "error: Placeholder mismatch for #{key.inspect}." unless en_placeholders == zh_placeholders
end

critical_keys = [
  "Welcome to Computer MCP",
  "Gateway runtime and local data plane",
  "A required dependency or component is unavailable.",
  "Required for window observation and screenshots.",
  "Unable to start gateway",
  "Opens the %@ setup page",
  "Installed",
  "Pass",
  "Warning",
  "Fail",
  "Allowed",
  "Prepared",
  "Committed",
]
critical_keys.each do |key|
  entry = catalog.fetch(key).fetch("localizations")
  english = entry.fetch("en").fetch("stringUnit").fetch("value")
  chinese = entry.fetch("zh-Hans").fetch("stringUnit").fetch("value")
  abort "error: Critical zh-Hans translation still equals English for #{key.inspect}." if english == chinese
end

allowed_identical_chinese = [
  "%@ B",
  "CLI",
  "ChatGPT",
  "Cloudflare",
  "Codex",
  "Computer MCP",
  "Computer MCP.app",
  "Computer Use",
  "MCP",
  "OpenAI",
  "cloudflared PID %@",
  "https://%@/mcp",
]
forbidden_chinese_ui_terms =
  /\b(?:Profile|Provider|Manifest|Skills|Socket|App|API Key|Access Token|Connector|doctor|secret|Shell|tools|installed|Pass|Warning|Fail|Allowed|Prepared|Committed|Running|Ready|Not configured)\b/i
catalog.each do |key, entry|
  localizations = entry.fetch("localizations")
  english = localizations.fetch("en").fetch("stringUnit").fetch("value")
  chinese = localizations.fetch("zh-Hans").fetch("stringUnit").fetch("value")
  if english == chinese && !allowed_identical_chinese.include?(chinese)
    abort "error: zh-Hans translation still equals English for #{key.inspect}."
  end

  generic_ui_copy = chinese.gsub("Computer MCP.app", "").gsub("App Server", "")
  if generic_ui_copy.match?(forbidden_chinese_ui_terms)
    abort "error: zh-Hans UI copy retains a generic English term for #{key.inspect}."
  end
  if chinese.match?(/\p{Han} \p{Han}/)
    abort "error: zh-Hans UI copy contains mechanical spacing for #{key.inspect}."
  end
end

allowed_stable_literals = [
  "Recent redacted audit:",
  "init(coder:) has not been implemented",
]
missing_literals = []
unlocalized_error_sites = []
interpolated_swiftui_sites = []
Dir.glob(File.join(root, "Sources/ComputerMCPApp/*.swift")).sort.each do |path|
  source = File.read(path)
  if File.basename(path) != "AppLocalization.swift" && source.match?(/error\.localizedDescription/)
    unlocalized_error_sites << path.delete_prefix(root + "/")
  end
  source.scan(/"((?:\\.|[^"\\])*)"/) do |match|
    raw = match.first
    next if raw.include?("\\(")
    value = raw.gsub('\\"', '"').gsub('\\\\', '\\')
    next unless value.match?(/[A-Za-z]/) && value.match?(/\s/)
    next if catalog.key?(value) || allowed_stable_literals.include?(value)
    missing_literals << "#{path.delete_prefix(root + "/")}: #{value}"
  end

  source.scan(/AppLocalization\.(?:string|formatted)\(\s*"((?:\\.|[^"\\])*)"/m) do |match|
    value = match.first.gsub('\\"', '"').gsub('\\\\', '\\')
    missing_literals << "#{path.delete_prefix(root + "/")}: #{value}" unless catalog.key?(value)
  end

  source.scan(/\b(?:Text|Label|Button|Section|LabeledContent|Toggle)\s*\(\s*"((?:\\.|[^"\\])*)"/m) do |match|
    raw = match.first
    if raw.include?('\\(')
      interpolated_swiftui_sites << "#{path.delete_prefix(root + "/")}: #{raw}"
    end
  end
end

unless missing_literals.empty?
  abort "error: Product-authored App strings are missing from the String Catalog:\n" \
    + missing_literals.uniq.sort.join("\n")
end
unless unlocalized_error_sites.empty?
  abort "error: App errors bypass AppLocalization.errorDescription:\n" \
    + unlocalized_error_sites.uniq.sort.join("\n")
end
unless interpolated_swiftui_sites.empty?
  abort "error: Interpolated SwiftUI strings must use AppLocalization.formatted with Text(verbatim:):\n" \
    + interpolated_swiftui_sites.uniq.sort.join("\n")
end

serialized = JSON.generate(catalog)
forbidden = [/(?:^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{16,}/, /-----BEGIN [A-Z ]*PRIVATE KEY-----/]
abort "error: String Catalog contains credential-like material." if forbidden.any? { |pattern| serialized.match?(pattern) }
RUBY

COMPILED_DIR="$TEMP_DIR/compiled"
/usr/bin/xcrun xcstringstool compile \
  "$CATALOG" \
  --output-directory "$COMPILED_DIR" \
  --serialization-format binary

for locale in en zh-Hans; do
  [[ -f "$COMPILED_DIR/$locale.lproj/Localizable.strings" ]] \
    || fail "String Catalog did not compile $locale resources."
done

EXTRACTED_DIR="$TEMP_DIR/extracted"
/bin/mkdir -p "$EXTRACTED_DIR"
/usr/bin/xcrun extractLocStrings -SwiftUI \
  -o "$EXTRACTED_DIR" \
  "$ROOT_DIR"/Sources/ComputerMCPApp/*.swift \
  2>"$TEMP_DIR/extract-errors"
[[ ! -s "$TEMP_DIR/extract-errors" ]] \
  || fail "Apple localization extraction reported errors:\n$(<"$TEMP_DIR/extract-errors")"

/usr/bin/jq -r '.strings | keys[]' "$CATALOG" | /usr/bin/sort -u >"$TEMP_DIR/catalog-keys"
: >"$TEMP_DIR/extracted-keys"
for strings_file in "$EXTRACTED_DIR"/*.strings(N); do
  /usr/bin/plutil -convert json -o - "$strings_file" \
    | /usr/bin/jq -r 'keys[]' >>"$TEMP_DIR/extracted-keys"
done
/usr/bin/sort -u -o "$TEMP_DIR/extracted-keys" "$TEMP_DIR/extracted-keys"
missing_extracted=$(/usr/bin/comm -23 "$TEMP_DIR/extracted-keys" "$TEMP_DIR/catalog-keys")
[[ -z "$missing_extracted" ]] \
  || fail "SwiftUI-extracted strings are missing from the String Catalog:\n$missing_extracted"

echo "Localization gate passed: $(/usr/bin/jq '.strings | length' "$CATALOG") keys, en + zh-Hans."
