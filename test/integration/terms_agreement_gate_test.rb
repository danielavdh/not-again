# frozen_string_literal: true

require "test_helper"

# Not only about a brand-new admin: one who has been in the database for years
# and has simply never seen this version of the terms must be stopped exactly
# the same way.
class TermsAgreementGateTest < ActionDispatch::IntegrationTest
  def sign_in(admin)
    post session_url(locale: :en), params: { username: admin.username, password: "password" }
  end

  # The fixture pre-seeds every admin as already agreed, so the rest of the
  # suite is undisturbed by this gate. A test about the UNGATED state clears
  # what the fixture set up first.
  def clear_agreement(admin)
    admin.update!(terms_agreed_version: nil, terms_agreed_at: nil)
  end

  test "an admin who has never agreed is redirected to the terms before the dashboard" do
    clear_agreement(admins(:one))
    sign_in(admins(:one))
    get dashboard_url(locale: :en)

    assert_redirected_to terms_path(locale: :en)
  end

  # admins(:one) is an ordinary long-standing fixture, not a "new admin" by any
  # definition — it existed before this feature did. It must be gated all the
  # same.
  test "an admin already in the database before this feature existed is gated too" do
    admin = admins(:one)
    clear_agreement(admin)
    assert admin.persisted?
    assert_not admin.agreed_to_current_terms?, "precondition: no prior agreement"

    sign_in(admin)
    get accounts_url(locale: :en)

    assert_redirected_to terms_path(locale: :en)
  end

  test "an admin who has already agreed to the current version is not gated" do
    admin = admins(:one) # already carries a fixture agreement to TERMS_VERSION
    sign_in(admin)
    get dashboard_url(locale: :en)

    assert_response :success
  end

  # NOT the same exemption list as OTP. upload_receipts_only is exempt from OTP
  # for friction reasons, but still handles real personal data through receipts,
  # so it is NOT exempt here.
  test "an upload-only admin is gated the same as anyone else" do
    clear_agreement(admins(:upload_only))
    sign_in(admins(:upload_only))
    get upload_standalone_receipts_url(locale: :en)

    assert_redirected_to terms_path(locale: :en)
  end

  test "a demo admin is never gated — there is no real relationship to consent to" do
    entity = entities(:family_biz)
    entity.admin_entities.joins(:admin).where(admins: { demo: false }).destroy_all
    demo = Admin.create!(username: "demo-under-test", demo: true, password: SecureRandom.hex(16))
    AdminEntity.create!(admin: demo, entity: entity, access_level: :read_only)

    post demo_path(locale: :en)
    get dashboard_url(locale: :en)

    assert_response :success
  end

  test "agreeing records what version and when, then returns to where the admin was headed" do
    admin = admins(:one)
    clear_agreement(admin)
    sign_in(admin)
    get accounts_url(locale: :en)
    assert_redirected_to terms_path(locale: :en)

    travel_to Time.zone.local(2026, 9, 3, 12, 0, 0) do
      post agree_terms_url(locale: :en), params: { confirm: "1" }
    end

    admin.reload
    assert_equal Admin::TERMS_VERSION, admin.terms_agreed_version
    assert_equal Time.zone.local(2026, 9, 3, 12, 0, 0), admin.terms_agreed_at
    assert_redirected_to accounts_url(locale: :en)
  end

  test "agreeing sends a copy by mail, so proof exists outside this installation" do
    clear_agreement(admins(:one))
    sign_in(admins(:one))
    get dashboard_url(locale: :en)

    assert_enqueued_email_with AdminMailer, :terms_agreed, params: { admin: admins(:one), version: Admin::TERMS_VERSION, locale: :en } do
      post agree_terms_url(locale: :en), params: { confirm: "1" }
    end
  end

  # A double-submitted form — double click, back-button resubmit — must not
  # raise and must not do anything strange the second time. A plain update is
  # idempotent, so this is really a smoke test that nothing throws.
  test "resubmitting the same agreement is harmless" do
    clear_agreement(admins(:one))
    sign_in(admins(:one))
    get dashboard_url(locale: :en)
    post agree_terms_url(locale: :en), params: { confirm: "1" }

    assert_nothing_raised { post agree_terms_url(locale: :en), params: { confirm: "1" } }
    assert_response :redirect
  end

  # AdminsController sits outside BaseController entirely — the gate has to be
  # wired there separately, and this proves it actually is.
  test "the gate also applies to AdminsController, not only bookkeeping pages" do
    clear_agreement(admins(:sudo))
    sign_in(admins(:sudo))
    get admins_url(locale: :en)

    assert_redirected_to terms_path(locale: :en)
  end

  test "the terms page itself never redirects to itself" do
    clear_agreement(admins(:one))
    sign_in(admins(:one))
    get terms_url(locale: :en)

    assert_response :success
  end
end
