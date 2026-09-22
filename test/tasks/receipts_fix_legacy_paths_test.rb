# frozen_string_literal: true
require "test_helper"
require "rake"

class ReceiptsFixLegacyPathsTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("receipts:fix_legacy_paths")
    Rake::Task["receipts:fix_legacy_paths"].reenable
    @store = Shrine.storages.fetch(:store)
    # A random token per test, not a hardcoded id segment: a fixed literal like
    # ".../900/..." can collide with an unrelated receipt that happens to get
    # id 900.
    @tok = SecureRandom.hex(6)
  end

  def scan_data_for(key, derivative_key: nil)
    data = { "id" => key, "storage" => "store", "metadata" => {} }
    data["derivatives"] = { "thumbnail" => { "id" => derivative_key, "storage" => "store", "metadata" => {} } } if derivative_key
    data
  end

  test "moves the file and rewrites the key when the source exists" do
    old_original  = "acc_receipts/scans/000/000/#{@tok}/original/x.jpg"
    old_thumbnail = "acc_receipts/scans/000/000/#{@tok}/thumbnail/x.jpg"
    @store.upload(StringIO.new("original bytes"), old_original)
    @store.upload(StringIO.new("thumb bytes"), old_thumbnail)
    receipt = Receipt.create!(title: "Legacy", receipt_date: Date.current, entity: entities(:family_biz),
      scan_data: scan_data_for(old_original, derivative_key: old_thumbnail))

    Rake::Task["receipts:fix_legacy_paths"].invoke

    receipt.reload
    new_original  = "receipts/scans/000/000/#{@tok}/original/x.jpg"
    new_thumbnail = "receipts/scans/000/000/#{@tok}/thumbnail/x.jpg"
    assert_equal new_original, receipt.scan_data["id"]
    assert_equal new_thumbnail, receipt.scan_data["derivatives"]["thumbnail"]["id"]
    assert @store.exists?(new_original)
    assert_not @store.exists?(old_original), "the old key must be gone, not just copied"
  ensure
    @store.delete("receipts/scans/000/000/#{@tok}/original/x.jpg") if @store.exists?("receipts/scans/000/000/#{@tok}/original/x.jpg")
    @store.delete("receipts/scans/000/000/#{@tok}/thumbnail/x.jpg") if @store.exists?("receipts/scans/000/000/#{@tok}/thumbnail/x.jpg")
  end

  test "rewrites the key even when the source file cannot be found, and does not raise" do
    old_key = "acc_receipts/scans/000/000/#{@tok}/original/y.jpg"
    receipt = Receipt.create!(title: "Orphaned", receipt_date: Date.current, entity: entities(:family_biz),
      scan_data: scan_data_for(old_key))

    Rake::Task["receipts:fix_legacy_paths"].invoke

    assert_equal "receipts/scans/000/000/#{@tok}/original/y.jpg", receipt.reload.scan_data["id"]
  end

  test "leaves an already-correct key untouched" do
    key = "receipts/scans/000/000/#{@tok}/original/z.jpg"
    receipt = Receipt.create!(title: "Already fine", receipt_date: Date.current, entity: entities(:family_biz),
      scan_data: scan_data_for(key))

    Rake::Task["receipts:fix_legacy_paths"].invoke

    assert_equal key, receipt.reload.scan_data["id"]
  end

  test "DRY_RUN reports without moving the file or touching the database" do
    old_key = "acc_receipts/scans/000/000/#{@tok}/original/w.jpg"
    @store.upload(StringIO.new("original bytes"), old_key)
    receipt = Receipt.create!(title: "Dry run", receipt_date: Date.current, entity: entities(:family_biz),
      scan_data: scan_data_for(old_key))

    ENV["DRY_RUN"] = "true"
    Rake::Task["receipts:fix_legacy_paths"].invoke

    assert_equal old_key, receipt.reload.scan_data["id"]
    assert @store.exists?(old_key)
    assert_not @store.exists?("receipts/scans/000/000/#{@tok}/original/w.jpg")
  ensure
    ENV.delete("DRY_RUN")
    @store.delete(old_key) if @store.exists?(old_key)
  end
end
