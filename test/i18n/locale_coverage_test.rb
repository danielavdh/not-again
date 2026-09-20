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

  # Keys with a SHAPE, not only a value. The two tests above ask whether a key
  # RESOLVES; these two keys resolve perfectly while being wrong, so they need
  # reading rather than looking up.

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
