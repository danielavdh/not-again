# less noise from bots

Rack::Attack.blocklist("vulnerability scanners") do |req|
  req.path.end_with?(".php", ".asp", ".aspx", ".cgi", ".env") ||
    req.path.include?("wp-admin") ||
    req.path.include?("wp-content") ||
    req.path.include?("wp-includes") ||
    req.path.include?("xmlrpc") ||
    req.path.include?("phpmyadmin") ||
    req.path.include?("/.git") ||
    req.path.include?("/.env")
end

Rack::Attack.blocklisted_responder = lambda do |_env|
  [403, { "Content-Type" => "text/plain" }, ["Forbidden"]]
end