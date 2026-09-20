# frozen_string_literal: true

require "test_helper"
# The tests reach for Aws::S3::Client before anything has referenced
# Maintenance::WeeklyCheck, so Zeitwerk has not yet run the require inside it.
require "aws-sdk-s3"

# These try to make the check LIE — to report "all clear" over a backup that
# would be useless in a restore. That is the only failure mode that matters
# here: a monitor which misses a problem is no worse than not having one, but a
# monitor which actively blesses a broken backup replaces an unknown with a
# false assurance, and nobody looks again.
class Maintenance::WeeklyCheckTest < ActiveSupport::TestCase
  BUCKET = "test-db-backups"

  # A believable nightly dump.
  def dump(key: "daily/db_backup_2026-08-31_03-00-00.dump", size: 40.megabytes, age: 2.hours)
    { key: key, size: size, last_modified: age.ago }
  end

  # Every bucket answers "private" unless a test says otherwise — the point of
  # these tests is almost never the privacy check itself.
  def private_http_get = ->(_uri) { 403 }

  def backup_finding(contents)
    client = Aws::S3::Client.new(region: "fr-par", stub_responses: true)
    client.stub_responses(:list_objects_v2, contents: contents)

    Maintenance::WeeklyCheck.call(s3: client, backup_bucket: BUCKET, http_get: private_http_get)
      .find { |f| f.area == "Backups" }
  end

  test "a healthy nightly dump passes" do
    f = backup_finding([ dump ])
    assert f.ok, "a 40MB dump from two hours ago should pass, got: #{f.detail}"
  end

  # With one object in the bucket the newest is also the largest, so a
  # proportional shrink test compares it against itself and always passes.
  test "an empty dump is NOT a backup, even when it is the only object" do
    f = backup_finding([ dump(size: 0) ])
    assert_not f.ok, "a zero-byte backup must never report OK, got: #{f.detail}"
  end

  test "a truncated dump is not a backup" do
    f = backup_finding([ dump(size: 200) ])
    assert_not f.ok, "a 200-byte backup must not report OK, got: #{f.detail}"
  end

  # Creating a "folder" in the Scaleway console writes a zero-byte object whose
  # key ends in a slash. It is newer than every real dump on the day it is made.
  test "a console-created folder marker is not mistaken for a backup" do
    f = backup_finding([ dump(age: 20.hours), { key: "daily/", size: 0, last_modified: 1.minute.ago } ])
    assert f.ok, "the real dump should still be found behind the folder marker, got: #{f.detail}"
    assert_includes f.detail, "20h old"
  end

  test "a missed night is reported" do
    f = backup_finding([ dump(age: 3.days) ])
    assert_not f.ok, "a three-day-old nightly backup must be flagged, got: #{f.detail}"
  end

  # The silent corruption case: the upload succeeds, the archive is valid, and
  # most of the books are not in it.
  test "a dump that suddenly loses most of its bytes is flagged" do
    f = backup_finding([
      dump(key: "daily/a.dump", size: 40.megabytes, age: 3.days),
      dump(key: "daily/b.dump", size: 40.megabytes, age: 2.days),
      dump(key: "daily/c.dump", size:  4.megabytes, age: 2.hours)
    ])
    assert_not f.ok, "a backup at a tenth of the previous size must be flagged, got: #{f.detail}"
  end

  test "an empty bucket is a problem, not a pass" do
    f = backup_finding([])
    assert_not f.ok
    assert_includes f.detail, "EMPTY"
  end

  # An expired key or a renamed bucket means nobody would notice the backups had
  # stopped, so it has to be reported — and it must not take the other checks
  # down with it.
  test "an unreadable bucket is reported and the other checks still run" do
    client = Aws::S3::Client.new(region: "fr-par", stub_responses: true)
    client.stub_responses(:list_objects_v2, "AccessDenied")

    findings = Maintenance::WeeklyCheck.call(s3: client, backup_bucket: BUCKET, http_get: private_http_get)

    backup = findings.find { |f| f.area == "Backups" }
    assert_not backup.ok
    assert_includes backup.detail, "cannot read"
    # Named rather than counted: a bare number tells you something changed, but
    # not that the check you cared about is still running.
    assert_equal [ "Backups", "Bucket privacy", "Exchange rates", "Background jobs", "Sign-ins" ],
                 findings.map(&:area), "one failing check must not suppress the others"
  end

  # A self-hoster who has not set up object-storage backups should not be told
  # every Monday for ever that something is broken. It says so without alarming.
  test "no configured bucket is stated plainly rather than alarming" do
    client = Aws::S3::Client.new(region: "fr-par", stub_responses: true)
    findings = Maintenance::WeeklyCheck.call(s3: client, backup_bucket: nil, http_get: private_http_get)
    f = findings.find { |f| f.area == "Backups" }
    assert f.ok
    assert_includes f.detail, "not checked"
  end

  test "every check reports something, so a silent pass cannot be mistaken for a skipped one" do
    findings = Maintenance::WeeklyCheck.call(
      s3: Aws::S3::Client.new(region: "fr-par", stub_responses: true), backup_bucket: nil, http_get: private_http_get)
    assert_equal %w[Backups], findings.map(&:area) & %w[Backups]
    assert findings.all? { |f| f.detail.present? }, "a finding with no detail says nothing"
  end

  # This is the check that makes path-randomness matter at all: randomness does
  # nothing once a bucket answers ListObjectsV2 with no credentials, because
  # that hands out every key directly.
  test "a bucket that answers anonymous listing is flagged, by name" do
    findings = Maintenance::WeeklyCheck.call(
      s3: Aws::S3::Client.new(region: "fr-par", stub_responses: true),
      backup_bucket: BUCKET, http_get: ->(_uri) { 200 })

    f = findings.find { |f| f.area == "Bucket privacy" }
    assert_not f.ok, "an anonymous 200 on ListObjectsV2 must not pass"
    assert_includes f.detail, "PUBLICLY LISTABLE"
    assert_includes f.detail, "Backups"
  end

  test "buckets that refuse anonymous listing pass" do
    findings = Maintenance::WeeklyCheck.call(
      s3: Aws::S3::Client.new(region: "fr-par", stub_responses: true),
      backup_bucket: BUCKET, http_get: private_http_get)

    f = findings.find { |f| f.area == "Bucket privacy" }
    assert f.ok, "buckets answering 403 to an anonymous request should pass, got: #{f.detail}"
  end

  # A network failure while checking has to be reported as "could not tell",
  # never folded into "must be private" — the same reasoning as an unreadable
  # backup bucket: a check that can silently mean either thing is not a check.
  test "a failed connection while checking privacy is reported, not swallowed as private" do
    findings = Maintenance::WeeklyCheck.call(
      s3: Aws::S3::Client.new(region: "fr-par", stub_responses: true),
      backup_bucket: BUCKET, http_get: ->(_uri) { raise SocketError, "getaddrinfo failed" })

    f = findings.find { |f| f.area == "Bucket privacy" }
    assert_not f.ok
    assert_includes f.detail, "could not confirm"
  end
end
