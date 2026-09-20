# frozen_string_literal: true

require "test_helper"

# The guard itself cannot be re-run inside a booted process — it already ran
# once, at boot, before this suite started — so this tests the exact same
# condition it evaluates, rather than the initializer file as a script.
class ObjectStorageGuardTest < ActiveSupport::TestCase
  def guard_would_raise?(production:, dummy_key:, bucket:)
    production && !dummy_key && bucket.blank?
  end

  test "raises: production, no dummy key, no bucket — the broken case this exists for" do
    assert guard_would_raise?(production: true, dummy_key: false, bucket: nil)
  end

  test "does not raise: production, but SECRET_KEY_BASE_DUMMY is set — the Docker build" do
    assert_not guard_would_raise?(production: true, dummy_key: true, bucket: nil)
  end

  test "does not raise: production, with a bucket actually configured" do
    assert_not guard_would_raise?(production: true, dummy_key: false, bucket: "real-bucket")
  end

  test "does not raise: development or test, regardless of bucket" do
    assert_not guard_would_raise?(production: false, dummy_key: false, bucket: nil)
  end

  test "the guard is actually present in the initializer file, not just in this test's own logic" do
    source = File.read(Rails.root.join("config/initializers/00_object_storage.rb"))
    assert_match(/Rails\.env\.production\?/, source)
    assert_match(/SECRET_KEY_BASE_DUMMY/, source)
    assert_match(/ObjectStorage::BUCKET\.blank\?/, source)
    assert_match(/raise/, source)
  end
  # THE ACTUAL QUESTION: not "is today's shrine.rb correct" but "what happens if
  # a future change makes it wrong". This reads the PRODUCTION branch of
  # shrine.rb's own source and fails if FileSystem storage is reachable from it,
  # however that branch gets rewritten later.
  #
  # A missing-credentials check cannot catch this: it is a different mistake —
  # not "credentials absent", but "filesystem storage offered as an option in
  # production at all".
  test "filesystem storage is not reachable from the production branch of shrine.rb" do
    source = File.read(Rails.root.join("config/initializers/shrine.rb"))
    production_branch = source[/if Rails\.env\.production\?(.*?)^else\b/m, 1]

    assert production_branch, "could not find the production branch in shrine.rb — did its shape change?"
    assert_no_match(/FileSystem/, production_branch,
                     "FileSystem storage must never be reachable when Rails.env.production? is true — " \
                     "see known-limitations.md §1 for why (unauthenticated, and wiped on every redeploy)")
  end
end
