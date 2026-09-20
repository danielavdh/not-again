# frozen_string_literal: true

# A language sudo added, on top of the shipped LANGUAGES
# (config/initializers/locale.rb). The translation strings and the four help
# documents are fields here rather than files, so adding one is data and needs
# no deploy.
#
# Two things read this table on every request that touches a released locale —
# the routes check (ApplicationController#verify_locale_is_released) and the
# I18n lookup (#sync_custom_translations) — so, same reasoning as Currency:
# memoised with a TTL, never a query per call.
class Language < ApplicationRecord
  enum :status, { draft: 0, released: 1 }
  enum :source, { system: 0, custom: 1 }

  belongs_to :released_by_admin, class_name: "Admin", optional: true

  CACHE_TTL = 60

  # doc name (WelcomeController::HELP_DOCS, plus "terms") => the field holding
  # it. One map, for anything that needs to go from "which document" to "which
  # column".
  DOC_FIELDS = {
    "easy_manual" => :easy_manual_textile,
    "pro_manual"  => :pro_manual_textile,
    "legal"       => :legal_textile,
    "terms"       => :terms_textile
  }.freeze

  # Scoped to :source deliberately — a custom "de" sharing a code with the
  # system "de" IS the override feature, not a duplicate. Without the scope this
  # validation would refuse exactly the case it exists to allow.
  validates :code, presence: true, length: { is: 2 },
                   format: { with: /\A[a-z]{2}\z/, message: :invalid },
                   uniqueness: { case_sensitive: false, scope: :source }
  validates :label, presence: true

  validate :yml_content_must_parse, if: :custom?
  validate :system_cannot_release_while_overridden, if: :system?

  normalizes :code, with: ->(c) { c.to_s.strip.downcase }

  before_validation :substitute_placeholder_code, if: :custom?

  after_commit :expire_cache

  # Forgetting to replace the placeholder on yml_content's first line is
  # corrected here rather than rejected: the intent is unambiguous. Runs before
  # every validation, not just on create — a no-op once the real code is there.
  def substitute_placeholder_code
    return if yml_content.blank? || code.blank?

    self.yml_content = yml_content.sub(self.class.yml_code_placeholder_pattern, "#{code}:")
  end

  # A released custom row always wins over the system row it shares a code with.
  # Blocked here rather than only in the controller: a crafted request re-
  # releasing the system row must not silently un-supersede a custom override.
  def system_cannot_release_while_overridden
    return unless released?
    return unless self.class.custom.released.where(code: code).exists?

    errors.add(:status, :overridden_by_custom, code: code)
  end

  # A syntax error is the one failure mode that can actually crash a request
  # (Psych::SyntaxError on load), so it is validated before anything can save.
  # Completeness against en.yml is deliberately NOT checked: a missing key
  # already falls back to English by I18n's own design, and blocking a save over
  # it would refuse a perfectly good partial draft.
  #
  # aliases: true is required — a real prefilled yml_content uses the `<<:
  # *errors_messages` merge-key pattern from config/locales/*.yml. Without it
  # Psych raises AliasesNotEnabled, which is NOT a Psych::SyntaxError and so is
  # not caught below: exactly the unhandled crash this validation exists to
  # prevent, for the yml_content most likely to be submitted.
  def yml_content_must_parse
    return if yml_content.blank?

    parsed = YAML.safe_load(yml_content, aliases: true)
    unless parsed.is_a?(Hash) && parsed.keys == [ code ]
      errors.add(:yml_content, :wrong_shape, code: code)
    end
  rescue Psych::Exception => e
    errors.add(:yml_content, :invalid_yaml, message: e.message)
  end

  # Named rather than a plain attribute update: this becomes visible to every
  # visitor, so it is a deliberate act, not a side effect of whatever was in the
  # form.
  #
  # Releasing a custom row supersedes its system sibling automatically, in the
  # same transaction — not a separate step the caller has to remember. A draft
  # alongside an active system language is fine; two live translations for the
  # same code would be genuinely ambiguous.
  def release!(by:)
    transaction do
      update!(status: :released, released_by_admin: by, released_at: Time.current)
      self.class.system.released.where(code: code).find_each(&:unrelease!) if custom?
    end
  end

  def unrelease!
    update!(status: :draft, released_by_admin: nil, released_at: nil)
  end

  # Is a released custom row currently standing in for this system language?
  # True only for system rows — the review screen and the index use it to show
  # "overridden by your custom version" instead of a live toggle.
  def superseded?
    system? && self.class.custom.released.where(code: code).exists?
  end

  # Fills only whichever content fields are actually blank, never one that
  # already holds something however small. A draft with a genuinely partial
  # yml_content must not get silently overwritten back to English just because
  # it is incomplete — completeness was never the bar. Blank is, being the one
  # case with nothing real to lose.
  #
  # Mutates in memory only, never saves: LanguagesController#edit calls it after
  # loading the real record, so sudo picking up a half-finished draft gets
  # English to work from on whatever they have not touched.
  def fill_blank_fields_with_english!
    return unless custom?

    self.yml_content = self.class.send(:prefilled_yml) if yml_content.blank?
    self.easy_manual_textile = self.class.send(:textile_help_text, "easy_manual") if easy_manual_textile.blank?
    self.pro_manual_textile  = self.class.send(:textile_help_text, "pro_manual")  if pro_manual_textile.blank?
    self.legal_textile       = self.class.send(:textile_help_text, "legal")       if legal_textile.blank?
    self.terms_textile       = self.class.send(:textile_help_text, "terms")       if terms_textile.blank?
    self
  end

  # This row's own HTML for one of the four help documents — nil when the field
  # is blank, so the caller falls back to the shipped static template exactly as
  # if this row did not exist.
  #
  # Placeholders (ContactPlaceholders) are substituted BEFORE the Textile
  # conversion, not after: RedCloth treats a run of 3+ capitals — exactly what a
  # token like [EMAIL] is — as its own acronym markup and wraps it in <span
  # class="caps">, which would break a literal-string substitution done
  # afterwards.
  def rendered_doc(doc)
    text = public_send(self.class::DOC_FIELDS.fetch(doc))
    return nil if text.blank?

    html = RedCloth.new(ContactPlaceholders.fill(text)).to_html
    Rails::Html::SafeListSanitizer.new.sanitize(html)
  end

  class << self
    # A custom language's own HTML for one of the four help documents, or nil —
    # the one place WelcomeController and the terms partial ask whether a DB-
    # backed language overrides this, rather than querying Language themselves.
    #
    # Draft rows are included, not just released ones:
    # ApplicationController#verify_locale_is_released already refuses a draft
    # locale to anyone but sudo, so by the time this is called the requester is
    # either a visitor on a released locale or sudo previewing their own draft.
    # Scoping to .released here would silently show English to sudo on every
    # preview.
    def custom_doc_html(doc, locale)
      custom.find_by(code: locale.to_s)&.rendered_doc(doc)
    end

    # { code => { label:, rtl: } }, released only, or nil when the table cannot
    # be read — the same "nil is not an error" reasoning as Currency: this is
    # read before a database is guaranteed to exist, and the caller has
    # LANGUAGES as its fallback.
    def cached_released
      load_if_stale
      @rows
    end

    def released_codes
      cached_released&.keys || []
    end

    def load_if_stale
      return unless @rows.nil? || @loaded_at.nil? ||
                    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @loaded_at) > CACHE_TTL

      @rows      = load_rows
      sync_custom_translations
      @loaded_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def expire_cache
      @rows = @loaded_at = nil
    end

    # A brand-new custom Language with its content fields pre-filled from the
    # current English source.
    #
    # LanguagesController#new calls this and ONLY #new. #create builds a plain
    # Language.new(language_params) instead — the admin's actual submission —
    # and must never call this, or a validation failure would re-render :new
    # with their pasted translation silently replaced by English.
    def new_with_english_prefill
      new.tap(&:fill_blank_fields_with_english!)
    end

    # Only the first line changes (en: → the placeholder): every comment, blank
    # line and the exact indentation of the rest survives, which a parse-and-re-
    # serialize round trip would have lost.
    def prefilled_yml
      lines = File.readlines(Rails.root.join("config/locales/en.yml"))
      ([ "#{yml_code_placeholder(I18n.locale)}:\n" ] + lines[1..]).join
    end

    # Human-readable on purpose: it IS the instruction, and no real code is
    # chosen yet when #new prefills yml_content, so it cannot write the right
    # one in.
    #
    # Translated into whichever locale sudo is browsing in — but only
    # LANGUAGES/I18n.available_locales carry a real translation file, and a
    # custom language's own yml_content is never wired into I18n lookup, so a
    # locale outside that list falls back to the English wording like any other
    # missing key.
    def yml_code_placeholder(locale)
      "<#{I18n.t('languages.form.yml_code_placeholder', locale: locale)}>"
    end

    # Matched against every available locale's wording rather than a single
    # fixed string: the browser posts back whatever placeholder was rendered at
    # GET time, which is not necessarily I18n.locale at POST time — sudo can
    # switch admin language, or a failed first submit can re-render :new, in
    # between.
    def yml_code_placeholder_pattern
      variants = I18n.available_locales.map { |loc| yml_code_placeholder(loc) }
      /\A#{Regexp.union(variants)}:/
    end

    def textile_help_text(doc)
      File.read(Rails.root.join("db/default_en_help_files/#{doc}.textile"))
    end

    # Unlike Currency, an EMPTY result here is a real, ordinary state — a fresh
    # install with no operator-added languages yet, not "could not read the
    # table". `.presence` would turn that into nil, indistinguishable from the
    # table genuinely being unreadable. nil is reserved for that: no table, or a
    # raised ActiveRecordError.
    def load_rows
      return nil unless table_exists?

      released.to_h { |l| [ l.code, { label: l.label, rtl: l.rtl? } ] }
    rescue ActiveRecord::ActiveRecordError
      nil
    end

    # System languages already have real strings, loaded at boot from
    # config/locales/<code>.yml. A custom row's strings live only in
    # yml_content, which I18n's backend cannot see, so they are pushed in here
    # by hand on the same cache/TTL rhythm.
    #
    # Draft rows are included: sudo previewing an unreleased draft needs its
    # strings loaded too, and routing already decides who may reach that locale
    # at all — store_translations existing in memory carries no access
    # implication of its own.
    #
    # A released custom row shares store_translations' normal deep-merge with
    # whatever a same-coded system file already loaded: its own keys win, and
    # anything it lacks still resolves from the system file underneath rather
    # than going missing.
    def sync_custom_translations
      return unless table_exists?

      custom.find_each do |language|
        next if language.yml_content.blank?

        parsed = YAML.safe_load(language.yml_content, aliases: true)
        I18n.backend.store_translations(language.code.to_sym, parsed[language.code])
      rescue Psych::Exception
        next # already validated at save — a corrupt row here must not crash every request
      end
    rescue ActiveRecord::ActiveRecordError
      nil
    end
  end

  private

  def expire_cache
    self.class.expire_cache
  end

end
