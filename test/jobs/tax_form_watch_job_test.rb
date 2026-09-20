# frozen_string_literal: true
require "test_helper"

# The catalogues are transcriptions of real forms. When an authority reissues
# one, nothing raises — a box number simply becomes wrong, and figures land in
# the wrong place on a return. This job is the only thing that would notice, so
# what it does and does NOT report both matter.
class TaxFormWatchJobTest < ActiveJob::TestCase
  Job = TaxFormWatchJob

  setup do
    @job    = Job.new
    @source = {
      "form_year" => 2026,
      "url"       => "https://example.test/SA105_2026.pdf",
      "sha256"    => Digest::SHA256.hexdigest("the form we transcribed"),
      "index_url" => "https://example.test/sa105"
    }
  end

  def stub_fetch(responses)
    @job.define_singleton_method(:fetch) { |url, **| responses.fetch(url, [ nil, :unreachable ]) }
  end

  # ── the file itself ────────────────────────────────────────────────────────

  test "says nothing when the form is byte-for-byte what we transcribed" do
    stub_fetch(@source["url"] => [ "the form we transcribed", :ok ])
    assert_nil @job.send(:check_file, "gb_property", @source)
  end

  test "reports a form that has been reissued at the same address" do
    stub_fetch(@source["url"] => [ "a quietly different form", :ok ])
    finding = @job.send(:check_file, "gb_property", @source)
    assert_equal :changed, finding[:kind]
  end

  # Daniela's distinction: a 404 means the authority moved or withdrew it, which
  # is news. A timeout means the network, which is not.
  test "a 404 is reported as the address having changed" do
    stub_fetch(@source["url"] => [ nil, :gone ])
    assert_equal :gone, @job.send(:check_file, "gb_property", @source)[:kind]
  end

  test "an unreachable host is not reported at all" do
    stub_fetch(@source["url"] => [ nil, :unreachable ])
    assert_nil @job.send(:check_file, "gb_property", @source)
  end

  # ── a newer edition ────────────────────────────────────────────────────────

  test "spots the next year's edition on the listing page" do
    stub_fetch(@source["index_url"] => [ "<li>2026 to 2027</li><li>2025 to 2026</li>", :ok ])
    finding = @job.send(:check_for_newer_edition, "gb_property", @source)
    assert_equal :newer_year, finding[:kind]
    assert_includes finding[:message], "2027"
  end

  test "spots an edition we skipped a cycle of" do
    stub_fetch(@source["index_url"] => [ "the 2029 return", :ok ])
    assert_equal :newer_year, @job.send(:check_for_newer_edition, "gb_property", @source)[:kind]
  end

  # The reason for a bounded window rather than "the highest number on the
  # page".
  test "a stray four-digit number is not mistaken for a tax year" do
    stub_fetch(@source["index_url"] => [ "reference 4015, call 2099 ext 7", :ok ])
    assert_nil @job.send(:check_for_newer_edition, "gb_property", @source)
  end

  test "the year we already built from is not a newer edition" do
    stub_fetch(@source["index_url"] => [ "2025 to 2026 — current", :ok ])
    assert_nil @job.send(:check_for_newer_edition, "gb_property", @source)
  end

  test "a year embedded in a longer number does not count" do
    stub_fetch(@source["index_url"] => [ "/media/12027456/file.pdf", :ok ])
    assert_nil @job.send(:check_for_newer_edition, "gb_property", @source)
  end

  # ── catalogues with nothing to watch ───────────────────────────────────────

  test "a scheme built from statute rather than a form is skipped" do
    assert_nil TaxSchemeConfig.source_for("ch_selbst"),
               "Switzerland's categories come from OR Art. 959b, so there is no form"
    assert_nil @job.send(:check, "ch_selbst")
  end

  test "every catalogue that declares a source declares which edition it used" do
    TaxSchemeConfig.all_schemes.each do |scheme|
      source = TaxSchemeConfig.source_for(scheme)
      next if source.blank?
      assert source["form_year"].to_i.positive?,
             "#{scheme} must say which year's form it was built from"
      assert source["sha256"].present?, "#{scheme} must record a checksum"
    end
  end
end
