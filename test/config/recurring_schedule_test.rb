# frozen_string_literal: true

require "test_helper"

# The schedule in config/recurring.yml is written in plain times ("every day at
# 4:30am"), and those times only mean anything against the server's clock, which
# is UTC — as is the cron that takes the nightly backup at 03:00/03:05.
#
# Solid Queue reads such times in config.time_zone unless told otherwise, and
# this app's is Berlin. Left alone, every sweep would run one or two hours
# earlier than written, landing BEFORE the backup it is supposed to follow, and
# moving twice a year with daylight saving.
class RecurringScheduleTest < ActiveSupport::TestCase
  BACKUP_DONE_AT = 3.hours + 10.minutes # 03:00 and 03:05 UTC, plus a margin

  def schedule
    YAML.load_file(Rails.root.join("config/recurring.yml"))["production"]
  end

  def next_run_utc(key, config)
    SolidQueue::RecurringTask.new(key: key, schedule: config["schedule"],
                                  class_name: config["class"] || "ErrorEvent",
                                  command: config["command"]).next_time.utc
  end

  test "the scheduler reads schedules in UTC, whatever the app's display time zone is" do
    assert_equal 0, ActiveSupport::TimeZone[SolidQueue.time_zone.to_s].utc_offset,
      "recurring.yml is written in server time; #{SolidQueue.time_zone} would shift every job"
  end

  # The sweeps delete records past their retention. Running before the nightly
  # backup means the day they drop is in no dump at all — the one thing that
  # makes a deletion unrecoverable.
  test "the retention sweeps run AFTER the nightly backup, not before it" do
    %w[sign_in_event_sweep error_event_sweep].each do |key|
      config = schedule.fetch(key)
      run_at = next_run_utc(key, config)
      seconds = run_at.hour.hours + run_at.min.minutes

      assert_operator seconds, :>, BACKUP_DONE_AT,
        "#{key} runs at #{run_at.strftime('%H:%M')} UTC, before the 03:00 backup — " \
        "the records it deletes would be in no dump"
    end
  end
end
