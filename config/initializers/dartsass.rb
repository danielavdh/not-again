# Two stylesheets, matching the two layouts: "application" is the public face of
# the app (front page, legal, demo) and "accounting" is everything behind a
# login.
Rails.application.config.dartsass.builds = {
  "application.scss" => "application.css",
  "accounting.scss"  => "accounting.css"
}
