# frozen_string_literal: true
require "test_helper"

# These call the real entry points with only the HTTP layer replaced, so the way
# arguments reach post_token is actually exercised.
#
# That gap let a live bug sit for weeks: post_token takes one positional hash
# plus a `base:` keyword, and exchange_code and refresh passed bare keywords,
# which Ruby 3 keeps separate — so the positional never arrived and every real
# token exchange raised "wrong number of arguments (given 0, expected 1)".
# Nothing caught it because everything else stubs exchange_code itself.
class Hmrc::OauthTest < ActiveSupport::TestCase
  class FakeHTTP
    attr_accessor :use_ssl, :open_timeout, :read_timeout
    attr_reader :last_request

    def initialize(body)
      @body = body
    end

    def request(req)
      @last_request = req
      resp = Net::HTTPOK.new("1.1", "200", "OK")
      body = @body
      resp.define_singleton_method(:body) { body }
      resp
    end
  end

  def with_http(body)
    fake = FakeHTTP.new(body)
    with_credentials do
      Net::HTTP.stub(:new, ->(*_) { fake }) { yield fake }
    end
  end

  # The OTHER external dependency, and the one that made this file green locally
  # and red on CI: CI withholds RAILS_MASTER_KEY deliberately, because it
  # decrypts credentials.yml.enc, which holds the Scaleway keys for the receipts
  # bucket and the database backups. So the real lookup returns nil there and
  # Config raises "Missing credential", while a developer with config/master.key
  # on disk never sees it.
  #
  # Stubbed here rather than in the environment, because this file exists to
  # exercise the REAL entry points — the value of a client id has nothing to do
  # with what it tests, and the raising lookup is right to keep.
  def with_credentials(&block)
    Hmrc::Config.stub(:client_id, "test-client-id") do
      Hmrc::Config.stub(:client_secret, "test-client-secret") do
        Hmrc::Config.stub(:sandbox_client_id, "test-client-id") do
          Hmrc::Config.stub(:sandbox_client_secret, "test-client-secret", &block)
        end
      end
    end
  end

  TOKEN_JSON = '{"access_token":"AT","refresh_token":"RT","expires_in":14400}'

  test "exchange_code posts the authorization code and parses the token" do
    result = with_http(TOKEN_JSON) do |fake|
      out = Hmrc::Oauth.exchange_code(code: "abc123", redirect_uri: "https://x/callback")
      assert_includes fake.last_request.body, "grant_type=authorization_code"
      assert_includes fake.last_request.body, "code=abc123"
      out
    end

    assert_equal "AT", result[:access_token]
    assert_equal "RT", result[:refresh_token]
    assert_equal 14_400, result[:expires_in]
  end

  test "refresh posts the refresh token and parses the new one" do
    result = with_http(TOKEN_JSON) do |fake|
      out = Hmrc::Oauth.refresh(refresh_token: "old-refresh")
      assert_includes fake.last_request.body, "grant_type=refresh_token"
      assert_includes fake.last_request.body, "refresh_token=old-refresh"
      out
    end

    assert_equal "AT", result[:access_token]
  end

  test "application_token returns just the token" do
    with_http(TOKEN_JSON) do |fake|
      assert_equal "AT", Hmrc::Oauth.application_token(sandbox: true)
      assert_includes fake.last_request.body, "grant_type=client_credentials"
    end
  end

  # ── ensure_fresh! ─────────────────────────────────────────────────────────

  def taxpayer(expires_at)
    admins(:sudo).taxpayers.create!(authority: "hmrc", label: "T",
                                    access_token: "old", refresh_token: "old-refresh",
                                    token_expires_at: expires_at)
  end

  test "a token with time left is left alone" do
    t = taxpayer(2.hours.from_now)
    Hmrc::Oauth.ensure_fresh!(t)
    assert_equal "old", t.reload.access_token
  end

  test "a token about to expire is refreshed and saved" do
    t = taxpayer(1.minute.from_now)
    with_http(TOKEN_JSON) { Hmrc::Oauth.ensure_fresh!(t) }

    t.reload
    assert_equal "AT", t.access_token
    assert_equal "RT", t.refresh_token
    assert t.token_expires_at > 3.hours.from_now
  end

  # HMRC does not always issue a new refresh token; blanking it would leave the
  # next refresh with nothing to send.
  test "a refresh with no new refresh token keeps the old one" do
    t = taxpayer(1.minute.from_now)
    with_http('{"access_token":"AT","expires_in":14400}') do
      Hmrc::Oauth.ensure_fresh!(t)
    end
    assert_equal "old-refresh", t.reload.refresh_token
  end

  test "a taxpayer that never connected is not refreshed" do
    t = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Never")
    assert_nil Hmrc::Oauth.ensure_fresh!(t)
    assert_nil Hmrc::Oauth.ensure_fresh!(nil)
  end
end
