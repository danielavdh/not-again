# frozen_string_literal: true
require "test_helper"

# Asks the one question no code can answer: did the AUTHORITY change this, or
# did WE get it wrong? The two need opposite handling and look identical in a
# diff.
#
# we were wrong     → correct the file in place. The key was never valid.
# authority changed → write a NEW YEAR FILE and leave the old one alone.
#
# Get that backwards and it cannot be undone. The loader upserts by (country,
# scheme, year, key), so editing export_column or api_field mutates the existing
# row — and a report re-run over a period you have already filed then resolves
# against the new box. What 2026's boxes were is gone, from everywhere except
# git.
#
# Removing a key is caught at runtime instead: the rows are deleted and
# TaxCategoryRemovalNotificationJob emails the bookkeepers whose accounts were
# tagged with it. Mutation cannot be caught that way, because by the time the
# loader runs the old value has already gone.
#
# This test forbids nothing. It stops a change until someone has answered the
# question, and leaves the answer in the commit.
class TaxCatalogueSnapshotTest < ActiveSupport::TestCase
  UPDATE = "bin/rails acc:tax_categories:snapshot"

  test "the snapshot exists" do
    assert TaxCatalogueSnapshot::PATH.exist?,
      "No catalogue snapshot. Generate it once with:\n\n    #{UPDATE}\n"
  end

  test "no category has quietly changed where it files its figure" do
    changes = TaxCatalogueSnapshot.changes
    return pass if changes.empty?

    lines = changes.map { |file, key, field, was, now|
      "  #{file} — `#{key}`\n      #{field}: #{was.inspect} → #{now.inspect}"
    }

    flunk <<~MSG
      A tax category now files its figure somewhere else:

      #{lines.join("\n")}

      The loader upserts the SAME row, so this rewrites history: a report re-run
      over an already-filed period will resolve against the new box, and what the
      old box was survives only in git.

        · Did the TAX AUTHORITY change it? Then leave this file alone and add a
          new year file — gb_self_employment_2029.yml, not an edit to 2026. The
          old rows stay, and already-filed periods keep resolving correctly.

        · Did WE get it wrong? Then this is the right fix. Record it:

              #{UPDATE}

          and commit the snapshot in the same commit, so the diff says what moved.
    MSG
  end

  test "no key has been removed without it being recorded" do
    removals = TaxCatalogueSnapshot.removals
    return pass if removals.empty?

    lines = removals.map { |file, key| "  #{file} — `#{key}`" }

    flunk <<~MSG
      A tax category has been removed from a catalogue:

      #{lines.join("\n")}

      Its rows will be deleted on the next load, and any account tagged with it
      stops resolving — the figures leave the tax export and the submission
      without an error, and the account does not join the "needs tagging" list,
      because its key is not blank. Bookkeepers are emailed
      (TaxCategoryRemovalNotificationJob), but they can only re-tag; they
      cannot undo a removal that should not have happened.

        · Did the TAX AUTHORITY drop this box? Then add a new year file rather
          than editing this one, so already-filed periods still resolve.

        · Was it never a real box? Then removing it is right:

              #{UPDATE}
    MSG
  end

  # Additions are safe — nothing that already files stops filing — so they are
  # recorded rather than questioned. The assertion exists so the snapshot stays
  # complete: a stale snapshot silently stops guarding the keys it never knew.
  test "new categories have been recorded in the snapshot" do
    additions = TaxCatalogueSnapshot.new_keys
    return pass if additions.empty?

    lines = additions.map { |file, key| "  #{file} — `#{key}`" }
    flunk <<~MSG
      New categories are not in the snapshot yet:

      #{lines.join("\n")}

      Adding a box is safe and needs no decision. Just record it, so the snapshot
      goes on guarding everything:

          #{UPDATE}
    MSG
  end

  test "a catalogue file that is entirely new is recorded too" do
    unknown = TaxCatalogueSnapshot.current.keys - TaxCatalogueSnapshot.recorded.keys
    assert_empty unknown,
      "New catalogue files are not in the snapshot: #{unknown.join(', ')}.\nRecord them with:\n\n    #{UPDATE}\n"
  end

  # Proof the guard actually guards: with a doctored snapshot, a moved box is
  # reported. Without this, all of the above would pass just as happily if
  # `changes` always returned [].
  test "a moved box really is detected" do
    real = TaxCatalogueSnapshot.recorded
    file = real.keys.first
    key  = real[file].keys.first

    doctored = Marshal.load(Marshal.dump(real))
    doctored[file][key]["export_column"] = "SOMETHING-ELSE"

    TaxCatalogueSnapshot.stub(:recorded, doctored) do
      found = TaxCatalogueSnapshot.changes
      assert found.any? { |f, k, field, _was, _now| f == file && k == key && field == "export_column" },
        "the guard did not notice a changed export_column"
    end
  end

  test "a removed key really is detected" do
    real = TaxCatalogueSnapshot.recorded
    file = real.keys.first
    doctored = Marshal.load(Marshal.dump(real))
    doctored[file]["a_key_the_file_does_not_have"] = { "section" => "income" }

    TaxCatalogueSnapshot.stub(:recorded, doctored) do
      assert_includes TaxCatalogueSnapshot.removals, [file, "a_key_the_file_does_not_have"]
    end
  end
end
