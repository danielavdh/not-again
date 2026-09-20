module SessionTestHelper
  # One host, one kind of login.
  def sign_in_as(admin, password: "password")
    post session_url(locale: :en), params: { username: admin.username, password: password }
    follow_redirect!
  end

  def sign_out
    delete session_url(locale: :en)
  end
end
