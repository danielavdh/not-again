class SudoConstraint
  def matches?(request)
    cookies = ActionDispatch::Cookies::CookieJar.build(request, request.cookies)
    session_id = cookies.signed[:session_id]
    return false unless session_id
    
    session_record = Session.find_by(id: session_id)
    return false unless session_record
    
    admin = session_record.admin 
    admin.present? && admin.sudo?
  end
end