require "test_helper"

# Silent rot, caught.
#
# A missing translation does not raise — Rails renders a grey "translation
# missing: en.foo.bar" span and the page carries on. So a key can be wrong, or
# absent in three of four languages, through every green test run and every
# deploy, until a human happens to look at that page in that language.
#
# This walks the source, works out every key the code actually asks for, and
# checks it resolves in EVERY language. Three kinds of lookup exist and all
# three are covered:
#
# 1. absolute    t("entities.index.title")      — says its own key
# 2. lazy view   t(".title")                    — key comes from the VIEW PATH
# 3. lazy mailer t(".subject") inside a mailer  — key comes from mailer + action
#
# Keys built by interpolation — t("jargon.#{account_type}") — cannot be read
# statically, and are covered separately below by expanding the enum.
class LocaleCoverageTest < ActiveSupport::TestCase
  # A key passed with default: cannot go missing, by construction.
  ABSOLUTE = /\b(?:I18n\.)?t\(\s*["']([a-z][a-z0-9_.]*)["']([^)]*)/
  LAZY     = /\b(?:I18n\.)?t\(\s*["']\.([a-z0-9_.]+)["']([^)]*)/

  def self.source_files
    Dir.glob(Rails.root.join("app/**/*.{rb,erb}"))
  end

  # "app/views/entities/_form.html.erb" → "entities.form"
  def self.view_scope(path)
    rel  = path.to_s.sub(%r{\A.*/app/views/}, "")
    dir  = File.dirname(rel)
    base = File.basename(rel).split(".").first.sub(/\A_/, "")
    "#{dir}/#{base}".tr("/", ".")
  end

  def self.wanted_keys
    keys = {} # key => [where it is asked for]

    source_files.each do |f|
      src = File.read(f)

      src.scan(ABSOLUTE) do |key, rest|
        next if rest.include?("default:")
        (keys[key] ||= []) << f
      end

      next unless f.end_with?(".erb")
      next unless f.include?("/app/views/")
      scope = view_scope(f)
      src.scan(LAZY) do |suffix, rest|
        next if rest.include?("default:")
        (keys["#{scope}.#{suffix}"] ||= []) << f
      end
    end

    # Mailers: a lazy key inside `def welcome_email` means
    # "admin_mailer.welcome_email.<key>", not anything to do with a file path.
    Dir.glob(Rails.root.join("app/mailers/*.rb")).each do |f|
      mailer = File.basename(f, ".rb")
      action = nil
      File.readlines(f).each do |line|
        action = Regexp.last_match(1) if line =~ /^\s*def\s+([a-z_][a-z0-9_]*)/
        next unless action
        line.scan(LAZY) do |suffix, rest|
          next if rest.include?("default:")
          (keys["#{mailer}.#{action}.#{suffix}"] ||= []) << f
        end
      end
    end

    keys
  end

  def missing_in(locale, keys)
    keys.reject do |key, _|
      I18n.t(key, locale: locale, raise: true, fallback: false)
      true
    rescue I18n::MissingTranslationData
      false
    rescue StandardError
      true # interpolation complaints mean the key EXISTS, which is all we ask
    end
  end

  test "every translation key the code asks for exists in every language" do
    keys = self.class.wanted_keys
    assert_operator keys.size, :>, 300,
                    "found only #{keys.size} keys — the scanner is probably broken, " \
                    "which would make this whole test pass for the wrong reason"

    report = []
    I18n.available_locales.each do |locale|
      missing = missing_in(locale, keys)
      next if missing.empty?

      report << "#{locale}: #{missing.size} missing"
      missing.first(15).each { |k, where| report << "    #{k}   (#{where.uniq.first})" }
      report << "    …and #{missing.size - 15} more" if missing.size > 15
    end

    flunk "\n#{report.join("\n")}\n" unless report.empty?
    assert true
  end

  # The interpolated ones. t("jargon.#{account.account_type}") cannot be read
  # from the source, so the enum is expanded and every value checked — this is
  # what would break if someone added an account type and stopped there.
  #
  # `tax.country.*` used to be expanded here too, because its call site passed a
  # default and so rendered "NL" rather than a visible gap. It is gone: a country
  # now declares its own name in its catalogue header (`country_label`), the way
  # a scheme declares `scheme_label`, so adding a country cannot leave three
  # languages naming it after its code. tax_scheme_config_test guards that.
  test "every enum value used as a translation key is translated in every language" do
    expansions = {
      "jargon"        => Account.account_types.keys,
      "access"        => AdminEntity.access_levels.keys,
    }

    report = []
    expansions.each do |prefix, values|
      I18n.available_locales.each do |locale|
        values.each do |v|
          key = "#{prefix}.#{v}"
          next if I18n.exists?(key, locale)
          report << "  #{locale}: #{key} — #{prefix} is looked up by interpolation, " \
                    "so nothing else would notice"
        end
      end
    end

    flunk "\n#{report.join("\n")}\n" unless report.empty?
    assert true
  end

  # The same message must interpolate the same things in every language. A
  # translation that drops a placeholder loses a name, a figure or a date and
  # still reads perfectly — and one that mistypes it, `%{{name}}` for
  # `%{name}`, prints the braces at the reader. Three languages did exactly
  # that in tax.accountant_export_add, so a German admin was offered
  # "%{{name}} hinzufügen" in a dropdown.
  #
  # Invisible to every other check here: the key exists everywhere, is a
  # string, is defined once and is not blank. Only comparing the languages to
  # each other finds it.
  test "every language interpolates the same placeholders for a given key" do
    report = []

    self.class.wanted_keys.each do |key, where|
      by_language = LANGUAGES.to_h do |_name, code|
        value = translate_or_nil(key, code)
        [ code, value.is_a?(String) ? value.scan(/%\{(\w+)\}/).flatten.uniq.sort : nil ]
      end
      # Only languages that HAVE the key — a missing one is the coverage test's
      # business, not this one.
      present = by_language.compact
      next if present.size < 2 || present.values.uniq.size == 1

      report << "  #{key}   (#{where.uniq.first})"
      present.each { |code, names| report << "      #{code}: #{names.inspect}" }
    end

    flunk "\n#{report.join("\n")}\n" unless report.empty?
    assert true
  end

  # YAML's last-one-wins, which is silent. A key written twice in the same
  # mapping loses its first value and nothing says so: `journal_entries.edit`
  # was a string AND, further down, a node — so the string was discarded and the
  # edit page printed the node's Hash as its heading. A duplicate can also be
  # two valid sentences, where the loser simply never appears (de's
  # terms_agreed.plain_notice said "du" and was overridden by one saying "Sie").
  #
  # Psych reports no error for it, and neither can a test that reads the loaded
  # Hash — by then one value is already gone. So this reads the parse tree.
  test "no locale file defines the same key twice in one mapping" do
    duplicates = []

    LANGUAGES.each do |_name, code|
      path = Rails.root.join("config/locales/#{code}.yml")
      collect_duplicate_keys(Psych.parse_file(path), [], duplicates, code)
    end

    flunk "\n#{duplicates.join("\n")}\n" unless duplicates.empty?
    assert true
  end

  # A key can resolve perfectly and still be the wrong KIND of thing. `t` given
  # the name of a parent node hands back the Hash of its children, and the view
  # prints that: journal_entries/edit.html.erb asked for "journal_entries.edit",
  # whose only child is a beginner warning, and so headed the page
  # {beginner_warning: "This is a more advanced entry..."} for as long as it has
  # existed.
  #
  # The coverage test above cannot see it — the key resolves, which is all it
  # asks. This asks what came back.
  # A pluralised key IS a Hash — `one:`/`other:` — and `t(..., count:)` picks the
  # branch. Those are correct; anything else with children is not.
  PLURAL_KEYS = %i[zero one two few many other].freeze

  test "no key the code renders resolves to a node instead of a string" do
    nodes = self.class.wanted_keys.select do |key, _|
      value = begin
        I18n.t(key, locale: :en, fallback: false)
      rescue StandardError
        nil # an interpolation complaint means a String with placeholders
      end
      value.is_a?(Hash) && (value.keys.map(&:to_sym) - PLURAL_KEYS).any?
    end

    report = nodes.map { |key, where| "  #{key} is a node, not a string   (#{where.uniq.first})" }
    flunk "\n#{report.join("\n")}\n" unless report.empty?
    assert true
  end

  # Keys with a SHAPE, not only a value. The two tests above ask whether a key
  # RESOLVES; these two keys resolve perfectly while being wrong, so they need
  # reading rather than looking up.

  # nil for a key this language does not have; the raw String otherwise, so the
  # caller can read its placeholders. `raise` so a missing one is not mistaken
  # for the "translation missing" sentence.
  def translate_or_nil(key, code)
    I18n.t(key, locale: code, fallback: false, raise: true)
  rescue StandardError
    nil
  end

  # Walks the parse tree rather than the loaded Hash: a mapping's children are
  # [key, value, key, value, ...], so a repeat is visible here and nowhere else.
  def collect_duplicate_keys(node, path, found, code)
    if node.is_a?(Psych::Nodes::Mapping)
      seen = {}
      node.children.each_slice(2) do |key, value|
        name = key.value
        if seen[name]
          where = (path + [ name ]).join(".")
          found << "  #{code}.yml: #{where} is defined twice " \
                   "(lines #{seen[name]} and #{key.start_line + 1}) — the first value is lost"
        else
          seen[name] = key.start_line + 1
        end
        collect_duplicate_keys(value, path + [ name ], found, code)
      end
    elsif node.respond_to?(:children) && node.children
      node.children.each { |child| collect_duplicate_keys(child, path, found, code) }
    end
  end

  # aliases: true — the locale files use YAML anchors (&errors_messages).
  def welcome_index(locale)
    YAML.load_file(Rails.root.join("config/locales/#{locale}.yml"), aliases: true)
        .dig(locale.to_s, "welcome", "index") || {}
  end

  # A list, so a language may use one word for the landing page's eyebrow or
  # three. Give it a String and safe_join renders the whole sentence in one
  # span.
  test "welcome.index.eyebrow is a list in every language" do
    LANGUAGES.each do |_name, code|
      assert_kind_of Array, welcome_index(code)["eyebrow"],
                     "welcome.index.eyebrow is not a list in #{code}"
    end
  end

  # The demo page's buttons are monospace in a door sized in ch, so a character
  # count IS a width — an exact check rather than a heuristic. A translation
  # that overflows is caught here instead of in a browser at some particular
  # viewport.
  #
  # The *_go labels carry a generated arrow at each end (a visible ::after and a
  # hidden ::before used as an optical counterweight), so they occupy four
  # characters more than they read.
  #
  # 28 is derived, not chosen. The door is 45vw below 900px and 30vw above it,
  # less 3vw of button padding — and the tightest point in the range is 900px
  # itself, where the door steps down to 30vw while the text does not step with
  # it: 243px of content at a 14px root, about 28.9 characters of a 0.6em
  # monospace advance.
  #
  # upload_* is exempt: that door is phone-only, where it is 100% wide.
  #
  # Recompute this if application.scss changes either door width or the button
  # padding, or _base.scss changes the font curve.
  DOOR_CH = 28
  ARROWED = /_go\z/

  test "no demo button label is wider than the door that holds it" do
    over = []
    LANGUAGES.each do |_name, code|
      keys = YAML.load_file(Rails.root.join("config/locales/#{code}.yml"), aliases: true)
                 .dig(code, "welcome", "demo") || {}
      keys.each do |key, value|
        next unless key.match?(/_(who|go|guide)\z/)
        next if key.start_with?("upload")   # phone-only door, full width there
        width = value.to_s.length + (key.match?(ARROWED) ? 4 : 0)
        over << "  #{code}: #{key} is #{width}ch (max #{DOOR_CH}) — #{value}" if width > DOOR_CH
      end
    end

    flunk "labels too wide for the door:\n#{over.join("\n")}" if over.any?
    assert true
  end

  # %{word} is the rotating word homepage.js measures and animates. Drop it and
  # the word vanishes from the sentence; write the span by hand instead and it
  # is escaped, because the ERB builds it and passes it in.
  test "welcome.index.subline_html keeps its interpolation and carries no markup" do
    LANGUAGES.each do |_name, code|
      value = welcome_index(code)["subline_html"]
      assert value, "welcome.index.subline_html is not defined in #{code}"

      assert_includes value, "%{word}",
                      "welcome.index.subline_html lost %{word} in #{code} — the rotating word will not appear"
      assert_no_match(/<[a-z]/i, value,
                      "welcome.index.subline_html contains markup in #{code} — it will be escaped, not rendered")
    end
  end
end
