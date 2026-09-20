# frozen_string_literal: true

require "test_helper"

class LanguagesControllerTest < ActionDispatch::IntegrationTest

  # ==================== Sudo Tests ====================

  class SudoAdminTests < ActionDispatch::IntegrationTest
    setup do
      @admin = admins(:sudo)
      sign_in_as(@admin)
    end

    test "should get index" do
      get languages_url(locale: :en)
      assert_response :success
    end

    test "should get new" do
      get new_language_url(locale: :en)
      assert_response :success
    end

    test "edit fills a blank field with English but leaves a real, partial field alone" do
      partial_yml = "bg:\n  welcome:\n    title: \"Started, not finished\"\n"
      language = Language.create!(code: "bg", label: "Български", yml_content: partial_yml)

      get edit_language_url(language, locale: :en)

      assert_response :success
      assert_select "textarea#language_yml_content", text: partial_yml
      assert_select "textarea#language_legal_textile" do |textareas|
        refute_empty textareas.first.text.strip
      end
    end

    test "update's failure path shows what was actually submitted, not a re-prefill" do
      language = Language.create!(code: "bg", label: "Български", yml_content: "bg:\n  hello: world")

      patch language_url(language, locale: :en), params: {
        language: { yml_content: "bg:\n  a: [unterminated" }
      }

      assert_response :unprocessable_entity
      assert_select "textarea#language_yml_content", text: "bg:\n  a: [unterminated"
    end

    test "should create language" do
      assert_difference("Language.count") do
        post languages_url(locale: :en), params: {
          language: { code: "bg", label: "Български", yml_content: "bg:\n  hello: world" }
        }
      end
      assert_redirected_to languages_url(locale: :en)
    end

    test "create allows a custom draft to share a code with an active system language" do
      assert_difference("Language.count") do
        post languages_url(locale: :en), params: { language: { code: "de", label: "Deutsch (better)" } }
      end
      assert_redirected_to languages_url(locale: :en)
      assert Language.custom.find_by(code: "de").draft?
    end

    test "release supersedes the system row sharing its code" do
      system_de = Language.system.find_by!(code: "de")
      custom_de = Language.create!(code: "de", label: "Deutsch (better)", yml_content: "de:\n  hello: world")

      patch release_language_url(custom_de, locale: :en)

      assert custom_de.reload.released?
      assert system_de.reload.draft?
    end

    test "create refuses yml_content that does not parse" do
      assert_no_difference("Language.count") do
        post languages_url(locale: :en), params: {
          language: { code: "bg", label: "Български", yml_content: "bg:\n  a: [unterminated" }
        }
      end
      assert_response :unprocessable_entity
    end

    test "should update language" do
      language = Language.create!(code: "bg", label: "Български")
      patch language_url(language, locale: :en), params: { language: { label: "Bulgarian" } }
      assert_redirected_to languages_url(locale: :en)
      assert_equal "Bulgarian", language.reload.label
    end

    test "should destroy language" do
      language = Language.create!(code: "bg", label: "Български")
      assert_difference("Language.count", -1) do
        delete language_url(language, locale: :en)
      end
      assert_redirected_to languages_url(locale: :en)
    end

    test "release makes a draft released" do
      language = Language.create!(code: "bg", label: "Български", yml_content: "bg:\n  hello: world")

      patch release_language_url(language, locale: :en)

      assert_redirected_to languages_url(locale: :en)
      assert language.reload.released?
      assert_equal @admin, language.released_by_admin
    end

    test "unrelease sends a released language back to draft" do
      language = Language.create!(code: "bg", label: "Български", yml_content: "bg:\n  hello: world")
      language.release!(by: @admin)

      patch unrelease_language_url(language, locale: :en)

      assert_redirected_to languages_url(locale: :en)
      assert language.reload.draft?
    end
  end

  # Sudo only, deliberately more restricted than currencies. Every action
  # redirects, not just index.

  class FullAccessAdminTests < ActionDispatch::IntegrationTest
    setup do
      @admin = admins(:one) # full_access to personal and spouse
      sign_in_as(@admin)
    end

    test "index is sudo only - redirects full_access admin" do
      get languages_url(locale: :en)
      assert_redirected_to dashboard_path
    end

    test "new is sudo only" do
      get new_language_url(locale: :en)
      assert_redirected_to dashboard_path
    end

    test "create is sudo only" do
      assert_no_difference("Language.count") do
        post languages_url(locale: :en), params: { language: { code: "bg", label: "Български" } }
      end
      assert_redirected_to dashboard_path
    end

    test "release is sudo only" do
      language = Language.create!(code: "bg", label: "Български", yml_content: "bg:\n  hello: world")
      patch release_language_url(language, locale: :en)
      assert_redirected_to dashboard_path
      refute language.reload.released?
    end
  end
end
