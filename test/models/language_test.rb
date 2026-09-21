# frozen_string_literal: true
require "test_helper"

class LanguageTest < ActiveSupport::TestCase
  setup { Language.expire_cache }
  teardown { Language.expire_cache }

  test "a well-formed language is valid" do
    language = Language.new(code: "bg", label: "Български", yml_content: "bg:\n  hello: world")

    assert language.valid?
  end

  # A draft can share a code with an active system language freely, since a
  # draft is sudo-only and conflicts with nothing yet. The seeded system row is
  # what "de" resolves to here.
  test "a custom draft can share a code with an active system language" do
    language = Language.new(code: "de", label: "Deutsch (better)", yml_content: "de:\n  hello: world")

    assert language.valid?
  end

  test "releasing a custom language supersedes its system sibling, in the same act" do
    system_de = Language.system.find_by!(code: "de")
    assert system_de.released?

    custom_de = Language.create!(code: "de", label: "Deutsch (better)", yml_content: "de:\n  hello: world")
    custom_de.release!(by: admins(:sudo))

    assert system_de.reload.draft?, "the system row should have been unreleased automatically"
    assert custom_de.reload.released?
  end

  test "a superseded system row cannot be manually released again" do
    system_de = Language.system.find_by!(code: "de")
    custom_de = Language.create!(code: "de", label: "Deutsch (better)", yml_content: "de:\n  hello: world")
    custom_de.release!(by: admins(:sudo))
    system_de.reload

    assert_raises(ActiveRecord::RecordInvalid) { system_de.release!(by: admins(:sudo)) }
    assert system_de.errors.added?(:status, :overridden_by_custom, code: "de")
    assert system_de.reload.draft?, "release should have failed, leaving the system row in draft"
  end

  test "superseded? is true only for a system row with a released custom override" do
    system_de = Language.system.find_by!(code: "de")
    refute system_de.superseded?

    custom_de = Language.create!(code: "de", label: "Deutsch (better)", yml_content: "de:\n  hello: world")
    refute system_de.superseded?, "a draft override does not supersede anything yet"

    custom_de.release!(by: admins(:sudo))
    assert system_de.reload.superseded?
  end

  test "system rows skip yml_content validation entirely" do
    system_de = Language.system.find_by!(code: "de")

    assert system_de.valid?
  end

  # "BG" is deliberately not in this list: normalizes runs before validation, so
  # it becomes "bg" first and is genuinely valid. What is tested here is the
  # formats normalising cannot fix — wrong length, or a digit.
  test "code must be exactly two lowercase letters" do
    %w[b bgr b1 1b].each do |bad_code|
      language = Language.new(code: bad_code, label: "Whatever")

      refute language.valid?, "#{bad_code.inspect} should not be a valid code"
    end
  end

  test "code is normalised to lowercase and stripped" do
    language = Language.create!(code: " BG ", label: "Български")

    assert_equal "bg", language.code
  end

  test "code must be unique" do
    Language.create!(code: "bg", label: "Български")
    dupe = Language.new(code: "bg", label: "Bulgarian, again")

    refute dupe.valid?
  end

  # A real starter-pack file, not synthetic content: it uses the `<<: *anchor`
  # merge-key pattern the shipped locale files actually use.
  #
  # Without `aliases: true` this raises Psych::AliasesNotEnabled, which is not a
  # Psych::SyntaxError and slips straight past the rescue clause — an unhandled
  # exception from exactly the content most likely to be submitted for real.
  test "yml_content using YAML aliases (the merge-key pattern real locale files use) is accepted" do
    content = <<~YAML
      bg:
        errors:
          messages: &errors_messages
            on_page: "Test"
          session_expired: "Test"
        activerecord:
          errors:
            messages:
              <<: *errors_messages
    YAML

    language = Language.new(code: "bg", label: "Български", yml_content: content)

    assert language.valid?, language.errors.full_messages.join(", ")
  end

  # The one failure mode that can actually crash a request. Everything else —
  # missing keys — is safe by I18n's own fallback design and deliberately not a
  # hard validation.
  test "yml_content that is not valid YAML is refused, not silently accepted" do
    language = Language.new(code: "bg", label: "Български",
                             yml_content: "bg:\n  hello: [unterminated")

    refute language.valid?
    assert_equal :invalid_yaml, language.errors.details[:yml_content].first[:error]
  end

  test "yml_content must have exactly one top-level key matching the code" do
    wrong_key = Language.new(code: "bg", label: "Български", yml_content: "fr:\n  hello: world")
    two_keys  = Language.new(code: "bg", label: "Български", yml_content: "bg:\n  a: 1\nfr:\n  b: 2")

    refute wrong_key.valid?
    refute two_keys.valid?
  end

  test "blank yml_content is allowed — a draft can be created before any translation exists" do
    language = Language.new(code: "bg", label: "Български", yml_content: "")

    assert language.valid?
  end

  # Superseded by the prefill design. Once yml_content starts out pre-filled
  # with every English key already present, "does this key exist" can never
  # usefully mean "has this been translated" — it would always read complete,
  # translated or not.

  test "new_with_english_prefill fills all five content fields, code left as a placeholder" do
    language = Language.new_with_english_prefill

    assert_match(/\A#{Regexp.escape(Language.yml_code_placeholder(:en))}:/, language.yml_content)
    assert_includes language.yml_content, "welcome" # some real English key survived the copy
    assert language.easy_manual_textile.present?
    assert language.pro_manual_textile.present?
    assert language.legal_textile.present?
    assert language.terms_textile.present?
  end

  # The exact scenario a real leftover test row surfaced: a draft with some
  # real (if partial) yml_content and every Textile field still blank.
  test "fill_blank_fields_with_english! leaves non-blank fields untouched, fills only the blank ones" do
    partial_yml = "bg:\n  welcome:\n    title: \"Started, not finished\"\n"
    language = Language.create!(code: "bg", label: "Български", yml_content: partial_yml)

    language.fill_blank_fields_with_english!

    assert_equal partial_yml, language.yml_content, "real, if partial, content must survive untouched"
    assert language.easy_manual_textile.present?, "the blank Textile fields should have been filled"
    assert language.legal_textile.present?
  end

  test "fill_blank_fields_with_english! is a no-op for a system row" do
    system_de = Language.system.find_by!(code: "de")

    system_de.fill_blank_fields_with_english!

    assert_nil system_de.yml_content
  end

  test "the placeholder code line is silently corrected to the real code on save" do
    language = Language.new_with_english_prefill
    language.code = "bg"
    language.label = "Български"

    language.valid?

    assert_match(/\Abg:/, language.yml_content)
    refute_match(/#{Regexp.escape(Language.yml_code_placeholder(:en))}/, language.yml_content)
  end

  test "the placeholder is substituted regardless of which available locale rendered it" do
    (I18n.available_locales - [ :en ]).each do |locale|
      placeholder_line = "#{Language.yml_code_placeholder(locale)}:\n  hello: world"
      language = Language.new(code: "bg", label: "Български", yml_content: placeholder_line)

      language.valid?

      assert_match(/\Abg:/, language.yml_content,
        "locale #{locale}'s placeholder should have been substituted")
    end
  end

  test "substitute_placeholder_code is a no-op once the real code is already there" do
    language = Language.new(code: "bg", label: "Български", yml_content: "bg:\n  hello: world")

    language.valid?

    assert_equal "bg:\n  hello: world", language.yml_content
  end

  test "release! stamps who and when, and flips status" do
    admin = admins(:sudo)
    language = Language.create!(code: "bg", label: "Български", yml_content: "bg:\n  hello: world")

    language.release!(by: admin)

    assert language.released?
    assert_equal admin, language.released_by_admin
    assert_not_nil language.released_at
  end

  test "unrelease! clears the release stamp and goes back to draft" do
    admin = admins(:sudo)
    language = Language.create!(code: "bg", label: "Български", yml_content: "bg:\n  hello: world")
    language.release!(by: admin)

    language.unrelease!

    assert language.draft?
    assert_nil language.released_by_admin
    assert_nil language.released_at
  end

  test "cached_released only lists released languages, with label and rtl" do
    draft    = Language.create!(code: "bg", label: "Български")
    released = Language.create!(code: "fa", label: "فارسی", rtl: true)
    released.release!(by: admins(:sudo))

    rows = Language.cached_released

    assert_not_includes rows.keys, draft.code
    assert_equal({ label: "فارسی", rtl: true }, rows[released.code])
  end

  # Currency's cache uses .presence, which turns an empty-but-readable result
  # into nil — correct THERE, because zero currencies is never valid. Zero extra
  # languages is the ordinary state, so nil must be reserved for "table
  # unreadable" and never reused for "genuinely none yet".
  #
  # The four system languages come from the fixture and are always released, so
  # reaching "nothing released" needs unreleasing them explicitly.
  test "cached_released is an empty hash, not nil, when nothing is released" do
    Language.system.released.find_each(&:unrelease!)

    assert_equal({}, Language.cached_released)
    assert_equal [], Language.released_codes
  end

  test "saving a language invalidates the cache automatically, not only via an explicit call" do
    language = Language.create!(code: "bg", label: "Български")
    Language.cached_released # warm the cache

    language.release!(by: admins(:sudo))

    assert_includes Language.cached_released.keys, "bg"
  end

  test "rendered_doc converts Textile to sanitized HTML" do
    language = Language.new(code: "bg", label: "Български",
      easy_manual_textile: "h1. Title\n\np. Some *bold* text.")

    html = language.rendered_doc("easy_manual")

    assert_includes html, "<h1>Title</h1>"
    assert_includes html, "<strong>bold</strong>"
  end

  test "rendered_doc returns nil for a blank field, not empty HTML" do
    language = Language.new(code: "bg", label: "Български")

    assert_nil language.rendered_doc("easy_manual")
  end

  test "rendered_doc strips dangerous markup a translator's paste could carry" do
    language = Language.new(code: "bg", label: "Български",
      legal_textile: %(h1. Legal\n\n<script>alert(1)</script>\n\np(x). ok))

    html = language.rendered_doc("legal")

    refute_includes html, "<script>"
  end

  # RedCloth's "acronym" markup wraps a run of 3+ capitals — exactly what a
  # token like [EMAIL] looks like — in <span class="caps">. Filling the real
  # value in first, before conversion, is what prevents that; this is the
  # regression test for getting the order backwards.
  test "rendered_doc fills contact placeholders before Textile conversion, not after" do
    language = Language.new(code: "bg", label: "Български",
      legal_textile: "p. Contact us at [EMAIL].")

    html = language.rendered_doc("legal")

    refute_includes html, "caps"
    assert_includes html, CONTACT_EMAIL
  end

  test "custom_doc_html is nil for a system locale — those render from their own static files" do
    assert_nil Language.custom_doc_html("easy_manual", :de)
  end

  # Deliberately NOT scoped to released. The routing gate is what keeps a
  # draft's pages from a non-sudo visitor; scoping here too would just show sudo
  # English on their own preview. CustomLanguageHelpDocsTest covers the actual
  # access boundary.
  test "custom_doc_html resolves a draft's own content too, for sudo's preview" do
    Language.create!(code: "bg", label: "Български", easy_manual_textile: "p. Draft text.")

    assert_includes Language.custom_doc_html("easy_manual", :bg), "Draft text."
  end

  test "custom_doc_html returns a released custom language's own content" do
    language = Language.create!(code: "bg", label: "Български", easy_manual_textile: "p. Real text.")
    language.release!(by: admins(:sudo))

    assert_includes Language.custom_doc_html("easy_manual", :bg), "Real text."
  end

  # A shipped language has been read by somebody — that is what shipping it
  # means. Nothing in the UI can set this on a system row (the Edit link is
  # custom-only), so left to the column default every installation would report
  # its own shipped languages as unreviewed.
  test "a system language is reviewed, without anyone having to say so" do
    lang = Language.create!(code: "pt", label: "Português", source: :system)
    assert lang.reviewed, "a shipped language must not arrive marked unreviewed"
  end

  test "a system language cannot be left unreviewed, even if asked" do
    lang = Language.create!(code: "pt", label: "Português", source: :system, reviewed: false)
    assert lang.reviewed

    lang.update!(reviewed: false)
    assert lang.reload.reviewed
  end

  # Custom languages are the case the flag exists for, so they keep it.
  test "a custom language keeps whatever review state it is given" do
    lang = Language.create!(code: "pt", label: "Português", source: :custom)
    assert_not lang.reviewed

    lang.update!(reviewed: true)
    assert lang.reload.reviewed
  end
end
