# Third-party code and assets

This app is AGPL-3.0. What follows is other people's work, used here under their
own terms. Full licence texts are in [`LICENSES/`](LICENSES/).

Two things are **redistributed in this repository** — one JavaScript library and
the fonts. Everything else (Ruby, Rails, the gems, the Debian packages) is
fetched when the container image is built and lives only in that image, where
each piece keeps its own licence file. It is listed here for completeness.

---

## Redistributed in this repository

### Tom Select 2.3.1 — Apache-2.0

Copyright (c) 2013 Brian Reavis & contributors. Vendored at
`vendor/javascript/tom-select.js` and
`app/assets/stylesheets/tom-select.bootstrap5.min.css` — the minified stylesheet
lost its header to minification, so the notice stands here. Licence:
[`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt).

### Fonts

Self-hosted in `app/assets/fonts/` and declared in
`app/assets/stylesheets/shared/_fonts.scss`, so no request for a font ever leaves
the server. Each is under the SIL Open Font License 1.1, except Ubuntu, which has
its own Ubuntu Font Licence 1.0. Each font's full licence text is in `LICENSES/`.

| Font | Copyright | Licence text |
|---|---|---|
| Fraunces | Copyright 2018 The Fraunces Project Authors | [`Fraunces.OFL.txt`](LICENSES/Fraunces.OFL.txt) |
| JetBrains Mono | Copyright 2020 The JetBrains Mono Project Authors | [`JetBrainsMono.OFL.txt`](LICENSES/JetBrainsMono.OFL.txt) |
| Noto Sans | Copyright 2022 The Noto Project Authors | [`NotoSans.OFL.txt`](LICENSES/NotoSans.OFL.txt) |
| Noto Sans Arabic | Copyright 2022 The Noto Project Authors | [`NotoSansArabic.OFL.txt`](LICENSES/NotoSansArabic.OFL.txt) |
| Noto Sans Armenian | Copyright 2022 The Noto Project Authors | [`NotoSansArmenian.OFL.txt`](LICENSES/NotoSansArmenian.OFL.txt) |
| Noto Sans Georgian | Copyright 2022 The Noto Project Authors | [`NotoSans.Georgian.OFL.txt`](LICENSES/NotoSans.Georgian.OFL.txt) |
| Noto Sans Hebrew | Copyright 2022 The Noto Project Authors | [`NotoSansHebrew.OFL.txt`](LICENSES/NotoSansHebrew.OFL.txt) |
| Open Sans | Copyright 2020 The Open Sans Project Authors | [`OpenSans.OFL.txt`](LICENSES/OpenSans.OFL.txt) |
| Space Grotesk | Copyright 2020 The Space Grotesk Project Authors | [`SpaceGrotesk.OFL.txt`](LICENSES/SpaceGrotesk.OFL.txt) |
| Work Sans | Copyright 2019 The Work Sans Project Authors | [`WorkSans.OFL.txt`](LICENSES/WorkSans.OFL.txt) |
| Ubuntu | Copyright 2010–2011 Canonical Ltd. | [`Ubuntu.UFL.txt`](LICENSES/Ubuntu.UFL.txt) |

---

## Bundled into the container image only

Not in this repository — pulled in by `bundle install` and `apt-get` when
`Dockerfile` builds the image. Publishing that image redistributes them; each
keeps its own licence file inside the image, so the obligations travel with the
artifact. Summarised here so the picture is complete.

### Ruby and the gems

The app runs on Ruby and the gems pinned in `Gemfile.lock` (`bundle list` prints
them with versions). They are overwhelmingly MIT, with some Apache-2.0, BSD, and
the Ruby licence. Every gem ships its own `LICENSE` file, present under the
bundle path in the image. The load-bearing ones:

| Gem | Licence |
|---|---|
| Rails, Shrine, Solid Queue, Thruster, Kamal, image_processing, aws-sdk-s3, pagy, rotp | MIT |
| Puma | BSD-3-Clause |
| pg | BSD-2-Clause |
| Ruby itself | Ruby licence / BSD-2-Clause |

### System packages

The base image is Debian (`ruby:3.4.7-slim`). On top of it: `imagemagick` and
`ghostscript` (receipt thumbnails), `libheif` (iPhone HEIC photos), `libjemalloc2`
(allocator), `postgresql-client`, `curl`. Each is under its own licence, with the
text at `/usr/share/doc/<package>/copyright` in the image.

---

## Not redistributed — build and deploy tools

Used to build and ship the app, never part of it and never in the image:
**Docker** / BuildKit, **Kamal** (deploys — a dev-group gem, `BUNDLE_WITHOUT`
drops it from the runtime image), **Bundler**, **Foreman** (`bin/dev`),
**Brakeman** and **RuboCop** (CI). These run on your machine or in CI; nothing
here carries their code, the same as it carries nothing for `git` or the shell.
