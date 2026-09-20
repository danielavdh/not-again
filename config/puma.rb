if ENV.fetch("RAILS_ENV", "development") == "production"
  workers Integer(ENV['WEB_CONCURRENCY'] || 2)
  preload_app!

  # This block is critical for preventing database connection errors.
  before_worker_boot do
    ActiveRecord::Base.establish_connection
  end
else
  workers 0
end

threads_count = Integer(ENV['RAILS_MAX_THREADS'] || 3)
threads threads_count, threads_count

enable_keep_alives(false) if respond_to?(:enable_keep_alives)

# Bind every interface in production, where kamal-proxy reaches the app from
# outside the container and loopback would make it unreachable. Everywhere else
# bind loopback only: `bin/dev` on a cafe or office network otherwise serves a
# whole set of books to the room, with no login in front of the receipt files,
# which development stores under public/.
#
# 127.0.0.1 rather than `localhost` or `::1` on purpose — a .test hostname in
# /etc/hosts points at the IPv4 loopback, and binding the IPv6 one would refuse
# those connections.
#
# BIND overrides it: `BIND=:: bin/dev` to reach the dev server from a phone,
# which is how the upload-only receipt flow gets tested on a real camera.
#
# Plain Ruby, no .presence: Puma evaluates this file before Rails, so
# ActiveSupport's core extensions are not loaded yet.
bind_host = ENV["BIND"]
bind_host = nil if bind_host.nil? || bind_host.empty?
bind_host ||= ENV.fetch("RAILS_ENV", "development") == "production" ? "::" : "127.0.0.1"
port(ENV['PORT'] || 3000, bind_host)
environment ENV['RACK_ENV'] || 'development'

plugin :tmp_restart

plugin :solid_queue if ENV["RAILS_ENV"] == "production" || ENV["SOLID_QUEUE_IN_PUMA"]

