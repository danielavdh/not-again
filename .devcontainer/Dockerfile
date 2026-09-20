ARG RUBY_VERSION=3.4.7
FROM docker.io/library/ruby:${RUBY_VERSION}

# Install system dependencies
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      curl \
      git \
      libpq-dev \
      libyaml-dev \
      pkg-config \
      postgresql-client \
      imagemagick \
      ghostscript \
      libheif-dev && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Fix ImageMagick PDF policy
RUN if [ -f /etc/ImageMagick-6/policy.xml ]; then \
      sed -i 's/rights="none" pattern="PDF"/rights="read|write" pattern="PDF"/' /etc/ImageMagick-6/policy.xml; \
    fi

# Create non-root user matching production
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash

WORKDIR /rails
RUN chown rails:rails /rails

USER rails
