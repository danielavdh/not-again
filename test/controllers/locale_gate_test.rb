# frozen_string_literal: true

require "test_helper"

# ApplicationController#verify_locale_is_released and #text_direction — cross-
# cutting, not owned by one controller. The routes constraint is just
# /[a-z]{2}/, so these two methods are the real gate and are what this checks.
class LocaleGateTest < ActionDispatch::IntegrationTest
  setup { Language.expire_cache }
  teardown { Language.expire_cache }

  test "a shipped locale works, unauthenticated" do
    get root_path(locale: :de)
    assert_response :success
  end

  test "an unreleased, made-up locale 404s rather than reaching a controller" do
    get root_path(locale: :zz)
    assert_response :not_found
  end

  test "a released Language's code is accepted, with no restart" do
    admin = admins(:sudo)
    language = Language.create!(code: "bg", label: "Български", yml_content: "bg:\n  hello: world")
    language.release!(by: admin)

    get root_path(locale: :bg)

    assert_response :success
  end

  test "a Language still in draft is not yet routable" do
    Language.create!(code: "bg", label: "Български", yml_content: "bg:\n  hello: world")

    get root_path(locale: :bg)

    assert_response :not_found
  end

  test "sudo can preview a draft language a stranger still gets 404 on" do
    Language.create!(code: "bg", label: "Български", yml_content: "bg:\n  hello: world")

    get root_path(locale: :bg)
    assert_response :not_found, "unauthenticated should still 404 on a draft"

    sign_in_as(admins(:sudo))
    get root_path(locale: :bg)
    assert_response :success, "sudo should be able to preview before releasing"
  end

  # Checking LANGUAGES membership always includes de/es/nl/ar too, so toggling a
  # system language off did nothing for actual access — the constant let it
  # through regardless. English is the one genuinely unconditional case; the
  # other four are gated by their own row.
  test "English is routable no matter what the Language table holds" do
    Language.system.released.find_each(&:unrelease!)

    get root_path(locale: :en)

    assert_response :success
  end

  test "unreleasing a system language actually blocks access to it now" do
    Language.system.find_by!(code: "es").unrelease!

    get root_path(locale: :es)

    assert_response :not_found
  end

  test "selectable_languages always lists English first, regardless of Language state" do
    Language.system.released.find_each(&:unrelease!)

    get root_path(locale: :en)

    assert_select ".langs a[hreflang=?]", "en"
  end

  # RTL_LOCALES is deliberately independent of LANGUAGES: ar left LANGUAGES when
  # it moved to a custom row but stays in RTL_LOCALES, so any locale reaching
  # that code still gets dir="rtl" from the hardcoded list rather than the row's
  # own rtl flag. It needs its own released row now — unlike when ar was a
  # system language, nothing makes /ar/ reachable without one.
  test "text_direction is rtl for the shipped RTL locales" do
    Language.create!(code: "ar", label: "العربية", yml_content: "ar:\n  hello: world")
             .release!(by: admins(:sudo))

    get root_path(locale: :ar)
    assert_select "html[dir=?]", "rtl"
  end

  test "text_direction is rtl for a released Language flagged rtl, ltr otherwise" do
    admin = admins(:sudo)
    rtl_lang = Language.create!(code: "fa", label: "فارسی", rtl: true, yml_content: "fa:\n  hello: world")
    rtl_lang.release!(by: admin)
    ltr_lang = Language.create!(code: "bg", label: "Български", yml_content: "bg:\n  hello: world")
    ltr_lang.release!(by: admin)

    get root_path(locale: :fa)
    assert_select "html[dir=?]", "rtl"

    get root_path(locale: :bg)
    assert_select "html[dir=?]", "ltr"
  end
end
