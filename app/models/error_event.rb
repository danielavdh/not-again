# frozen_string_literal: true

# A request or job that raised and was never handled — the 500s nobody would
# otherwise hear about, since the failed-jobs check sees only jobs.
#
# ONE ROW PER (class, source, day), counted. A crash loop can raise thousands of
# times a minute, and a row each would make the table the second incident.
#
# WHAT IS DELIBERATELY NOT STORED: parameters, the query string, the admin, the
# IP. Those carry the books' own content — a journal search alone would put
# somebody's name in a query string — and this table exists to find broken code,
# not to watch people. What is kept is where the code broke: the class, the
# controller action or job, the path without its query, and the first line of
# the backtrace inside this app.
class ErrorEvent < ApplicationRecord
  # Same rule as SignInEvent: long enough to see a pattern, short enough that it
  # is not a permanent record. Swept nightly from config/recurring.yml.
  RETENTION = 90.days

  MAX_MESSAGE = 300

  scope :since,   ->(time) { where(last_seen_at: time..) }
  scope :expired, -> { where(last_seen_at: ...RETENTION.ago) }

  # NEVER let this break the request it is reporting on — the same reasoning as
  # SignInEvent.record, and more so here: this runs while something is already
  # going wrong.
  def self.record(error_class:, source:, message: nil, path: nil, line: nil, at: Time.current)
    row = {
      error_class:  error_class.to_s.first(255),
      source:       source.to_s.first(255),
      day:          at.utc.to_date,
      occurrences:  1,
      last_message: message&.to_s&.first(MAX_MESSAGE),
      last_path:    path&.to_s&.first(255),
      last_line:    line&.to_s&.first(255),
      last_seen_at: at
    }

    upsert(row, unique_by: [ :error_class, :source, :day ], on_duplicate: Arel.sql(
      "occurrences = error_events.occurrences + 1, " \
      "last_message = excluded.last_message, " \
      "last_path = excluded.last_path, " \
      "last_line = excluded.last_line, " \
      "last_seen_at = excluded.last_seen_at"
    ))
  rescue StandardError => e
    Rails.logger.error("ErrorEvent.record failed: #{e.class}: #{e.message}")
    nil
  end

  # Counted in SQL: the weekly check must not load a week of rows to add them up.
  def self.summary_since(time)
    since(time).group(:error_class, :source).sum(:occurrences)
  end
end
