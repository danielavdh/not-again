# Cross-origin rules for the dynamic Rails responses. If a CDN sits in front of
# the static assets it needs its own CORS configuration at the CDN, which this
# file cannot do anything about — fonts are the ones that fail first.
#
# The origins are derived from ASSET_HOST and APP_HOST rather than written in,
# so a clone allows its own hosts and not somebody else's.

if defined? Rack::Cors
    Rails.configuration.middleware.insert_before 0, Rack::Cors do
        allow do
            if Rails.env.production?
              origins [
                ENV["APP_HOST"].presence   && "https://#{ENV['APP_HOST']}",
                ENV["ASSET_HOST"].presence && "https://#{ENV['ASSET_HOST']}"
              ].compact
              resource '*',
                headers: :any,
                          # Explicitly allow needed methods
                          methods: [:get, :head, :options],  
                          expose: ['ETag', 'Cache-Control', 'Content-Type', 'Last-Modified'],
                          # Set to true if you need to send cookies
                          credentials: false,  
                          max_age: 1.hour
            else
                # Development is plain localhost — see development.rb. There is
                # no /etc/hosts entry on this machine or on CI.
                origins %w[
                     http://localhost:3000
                ]
                resource '/assets/*',
                headers: :any,
                          methods: [:get, :head, :options],
                          expose: ['ETag', 'Cache-Control', 'Content-Type', 'Last-Modified'],
                          credentials: false,
                          max_age: 1.hour
            end
        end
    end
end

