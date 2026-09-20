# frozen_string_literal: true

# Required here rather than relied on from elsewhere. The gem is `require:
# false` in the Gemfile and config/initializers/shrine.rb loads it only in
# production, so without this line the backup check raises NameError anywhere
# else — including in the tests meant to prove it works.
require "aws-sdk-s3"

module Maintenance
  # The weekly "is anything quietly broken" check.
  #
  # IT REPORTS ON SUCCESS AS WELL AS FAILURE, AND THAT IS THE POINT. Something
  # that only writes when it finds a problem cannot tell you it has stopped
  # running: silence would mean "all well" and "the scheduler is dead" at the
  # same time. Because this arrives every Monday, a Monday WITHOUT it is itself
  # the alarm — a dead-man's-switch needing no outside service.
  #
  # For the same reason the mail's own arrival is the check on Solid Queue: it
  # cannot be delivered unless the scheduler fired and a worker picked the job
  # up. There is deliberately no "are the workers alive" line, because a line
  # that can only ever say yes is not a check.
  #
  # Every check below asks about the WORLD, not about the code — not "did the
  # backup job run" but "how old is the newest object in the bucket". A job can
  # run to completion, report success, and produce nothing.
  class WeeklyCheck
    Finding = Struct.new(:area, :ok, :detail, keyword_init: true)

    # A nightly backup older than this means a whole night was missed, not that
    # one run was slow.
    BACKUP_MAX_AGE = 48.hours

    # A dump that suddenly loses half its bytes is the classic silent
    # corruption: the upload succeeds, the archive is valid, and most of the
    # books are not in it. backup_db.sh already refuses an empty or non-PGDMP
    # file; this catches the case where it is neither.
    #
    # If this fires, look at the DATE of the newest backup first. backup_db.sh
    # excludes sign_in_events from the 1st-of-month dump — the one copied to
    # monthly/ and yearly/ — so that file is legitimately smaller. Nowhere near
    # half the size on an ordinary installation, but on a small one under
    # sustained attack the log can outgrow the books, and then this fires with
    # entirely the wrong explanation.
    SHRINK_RATIO = 0.5

    # No pg_dump of a database with a chart of accounts in it is smaller than
    # this, so anything under it is a stub, a truncated upload or a placeholder
    # rather than a small backup.
    MIN_PLAUSIBLE_BACKUP = 10.kilobytes

    # A month the nightly FillRateGapsJob has had this long to fill and still
    # has not. Anything more recent is ordinary: GapFinder reports the current
    # month as missing on purpose — always for a daily source, which is still
    # accruing days — so alarming on "any gap" would cry wolf every week.
    GAP_GRACE = 30.days

    # The window the sign-in figures cover. One week, because the report is
    # weekly: anything longer double-counts across reports, anything shorter
    # leaves days nobody ever sees.
    SIGN_IN_WINDOW = 7.days

    # Failed passwords are ordinary — people mistype, and a handful a week is
    # noise. This is where the number stops looking like typing. Deliberately
    # well clear of that line rather than borderline: an alarm that cries wolf
    # ends up in a folder nobody opens.
    FAILED_SIGN_IN_ALARM = 50

    def self.call(s3: nil, backup_bucket: ObjectStorage::BACKUP_BUCKET, http_get: nil)
      new(s3: s3, backup_bucket: backup_bucket, http_get: http_get).call
    end

    # All three are injectable so the checks can be tested against stubbed
    # responses rather than live infrastructure. Nothing in the app passes any
    # of them; the defaults are the real configuration and a real, credential-
    # less HTTP GET.
    def initialize(s3: nil, backup_bucket: ObjectStorage::BACKUP_BUCKET, http_get: nil)
      @s3 = s3
      @backup_bucket = backup_bucket
      @http_get = http_get || method(:live_get)
    end

    def call
      [ backup, bucket_privacy, rates, failed_jobs, sign_ins ]
    end

    private

    def backup
      bucket = @backup_bucket
      unless bucket.present?
        return ok("Backups", "not checked — no :backup_bucket set in credentials")
      end

      # Caught, not raised on. Being unable to READ the bucket is a finding in
      # its own right — an expired key or a renamed bucket means nobody would
      # notice the backups had stopped — and one unreachable check must not cost
      # the other two their weekly report.
      begin
        objects = daily_backups(bucket)
      rescue BackupUnreadable => e
        return bad("Backups", "cannot read #{bucket} — #{e.message}")
      end

      # Console-created "folders" are zero-byte objects whose key ends in a
      # slash. Left in, the newest one of those IS the newest backup as far as
      # this check is concerned.
      objects = objects.reject { |o| o.key.end_with?("/") }
      return bad("Backups", "bucket #{bucket}/daily/ is EMPTY — there are no backups") if objects.empty?

      newest = objects.max_by(&:last_modified)

      # An absolute floor, checked BEFORE the ratio below, because the ratio
      # cannot catch this: with one object in the bucket the newest is also the
      # largest, so a zero-byte file is compared against itself and passes. A
      # backup monitor that blesses an empty backup is worse than none, because
      # it converts an unknown into a false assurance.
      if newest.size < MIN_PLAUSIBLE_BACKUP
        return bad("Backups", "newest is only #{ActiveSupport::NumberHelper.number_to_human_size(newest.size)} (#{newest.key}) — not a usable dump")
      end
      age    = Time.current - newest.last_modified
      size   = ActiveSupport::NumberHelper.number_to_human_size(newest.size)
      when_s = "#{newest.last_modified.utc.strftime('%Y-%m-%d %H:%M')} UTC"

      if age > BACKUP_MAX_AGE
        return bad("Backups", "newest is #{(age / 3600).round}h old (#{when_s}, #{size}) — a nightly run has been missed")
      end

      # Compare against the biggest of the recent run, not the average: one
      # already-shrunken backup would drag an average down and hide the next.
      largest = objects.max_by(&:size)
      if newest.size < largest.size * SHRINK_RATIO
        return bad("Backups", "newest is #{size}, down from #{ActiveSupport::NumberHelper.number_to_human_size(largest.size)} — dump may be incomplete")
      end

      ok("Backups", "newest #{(age / 3600).round}h old (#{when_s}, #{size}), #{objects.size} daily #{'copy'.pluralize(objects.size)} retained")
    end

    # The check that actually matters for path randomness. A random path segment
    # stops someone GUESSING a key; it does nothing once ListObjectsV2 answers
    # with no credentials at all, since that hands out every key directly. If
    # every bucket here stays private, everything downstream — receipts, tax
    # archives, database dumps — is a non-event. If one does not, nothing else
    # in this file matters more.
    def bucket_privacy
      buckets = {
        "Receipts"    => ObjectStorage::BUCKET,
        "Tax archive" => ObjectStorage::TAX_BUCKET,
        "Backups"     => @backup_bucket
      }.select { |_, bucket| bucket.present? }
      return ok("Bucket privacy", "not checked — no buckets configured") if buckets.empty?

      states = buckets.transform_values { |bucket| listing_state(bucket) }

      exposed     = states.select { |_, state| state == :public }.keys
      unreachable = states.select { |_, state| state == :unreachable }.keys

      if exposed.any?
        return bad("Bucket privacy",
          "PUBLICLY LISTABLE: #{exposed.join(', ')} — an anonymous request can list the " \
          "bucket's contents. Fix the bucket policy immediately.")
      end

      # A failed connection is reported, not treated as "must be private" — the
      # same reasoning as an unreadable backup bucket: a check that can silently
      # mean either "safe" or "broken network" is not a check.
      if unreachable.any?
        return bad("Bucket privacy",
          "could not confirm: #{unreachable.join(', ')} — the anonymous check itself failed to connect")
      end

      ok("Bucket privacy", "#{buckets.size} bucket(s) checked anonymously, none answer to listing")
    end

    # No S3 credentials involved on purpose: this has to see what a stranger on
    # the internet sees, not what this app's own access key is permitted to do.
    def listing_state(bucket)
      origin = ObjectStorage.bucket_origin(bucket)
      return :unreachable if origin.blank?

      case @http_get.call(URI("#{origin}/?list-type=2&max-keys=1"))
      when 200 then :public
      else :private
      end
    rescue StandardError
      :unreachable
    end

    def live_get(uri)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) { |http|
        http.request_get(uri).code.to_i
      }
    end

    # Asks the WORLD like the others: how many attempts happened, not whether
    # the logging code ran.
    #
    # The alarm is otp_failed at ANY count. A wrong password is someone
    # guessing; a RIGHT password stopped only by the second factor is someone
    # who already holds a working password, and that is worth a Monday morning.
    # Plain failures are reported as a number and only raise the alarm once they
    # stop resembling human typing.
    def sign_ins
      counts = SignInEvent.summary_since(SIGN_IN_WINDOW.ago)
      failed = counts["failed"].to_i
      otp    = counts["otp_failed"].to_i
      ok_in  = counts["signed_in"].to_i

      detail = "#{ok_in} signed in, #{failed} failed, #{otp} stopped at the second factor (7 days)"

      if otp.positive?
        bad("Sign-ins", "#{detail} — a CORRECT password was stopped by the second factor #{otp} #{'time'.pluralize(otp)}. Someone holds a working password.")
      elsif failed >= FAILED_SIGN_IN_ALARM
        bad("Sign-ins", "#{detail} — more failures than typing explains")
      else
        ok("Sign-ins", detail)
      end
    end

    def rates
      gaps = Rates::GapFinder.call
      return ok("Exchange rates", "no gaps — every period the books need is present") if gaps.empty?

      cutoff = GAP_GRACE.ago.to_date
      stale  = gaps.select { |_source, month| month.end_of_month < cutoff }

      if stale.empty?
        return ok("Exchange rates", "#{gaps.size} recent gap(s), all within the #{GAP_GRACE.inspect} fill window — normal")
      end

      bad("Exchange rates", "#{stale.size} period(s) still missing after #{GAP_GRACE.inspect}: #{summarise(stale)}")
    end

    # Jobs that errored, exhausted their retries and gave up. Whatever the job
    # was meant to do has not happened and nothing will try again.
    def failed_jobs
      failures = SolidQueue::FailedExecution.includes(:job).order(created_at: :desc).limit(20).to_a
      return ok("Background jobs", "no failed jobs") if failures.empty?

      lines = failures.group_by { |f| f.job&.class_name || "(unknown)" }
                      .map { |klass, fs| "#{klass} ×#{fs.size}" }
      bad("Background jobs", "#{failures.size} failed and gave up: #{lines.join(', ')}")
    end

    # One page is 1000 keys — far more than any sane retention window leaves in
    # daily/ — so this does not paginate. If it is ever full, the count in the
    # message is the clue that a lifecycle rule is missing.
    def daily_backups(bucket)
      s3.list_objects_v2(bucket: bucket, prefix: "daily/", max_keys: 1000).contents
    rescue Aws::S3::Errors::ServiceError, Seahorse::Client::NetworkingError => e
      raise BackupUnreadable, "#{e.class.name.split('::').last}: #{e.message}"
    end

    class BackupUnreadable < StandardError; end

    def s3
      @s3 ||= Aws::S3::Client.new(**ObjectStorage.client_options)
    end

    # One line per source, not per period: a publisher that has moved a URL is
    # missing every month at once, and thirty identical clauses is how an alarm
    # stops being read.
    def summarise(gaps)
      gaps.group_by(&:first).map { |source, rows|
        months = rows.map(&:last).sort
        label  = RateSourceConfig.label_for(source)
        span   = months.one? ? months.first.strftime("%Y-%m") :
                 "#{months.first.strftime('%Y-%m')}…#{months.last.strftime('%Y-%m')}"
        "#{label} #{rows.size} (#{span})"
      }.join(", ")
    end

    def ok(area, detail)  = Finding.new(area: area, ok: true,  detail: detail)
    def bad(area, detail) = Finding.new(area: area, ok: false, detail: detail)
  end
end
