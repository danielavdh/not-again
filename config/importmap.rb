pin "application", preload: false   # the public side — front page, legal, demo
pin "accounting", preload: false  # the signed-in app
pin_all_from "app/javascript/frontend", under: "frontend", preload: false
pin_all_from "app/javascript/scripts", under: "scripts", preload: false

pin "tom-select", to: "tom-select.js", preload: false # self-hosted from vendor/javascript (v2.3.1)