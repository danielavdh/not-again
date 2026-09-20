namespace :receipts do
  desc "Rewrites acc_receipts/ storage keys (js22's old Acc:: namespace) to receipts/, moving " \
       "the underlying file in whichever storage is configured — local FileSystem in dev, S3 in " \
       "production, same code either way, via Shrine's own storage object rather than the AWS " \
       "SDK or File directly. Safe to re-run: a key already saying receipts/ is left alone. " \
       "DRY_RUN=true reports what it would do without changing anything."
  task fix_legacy_paths: :environment do
    old_prefix = "acc_receipts/"
    new_prefix = "receipts/"
    store      = Shrine.storages.fetch(:store)
    dry_run    = ActiveModel::Type::Boolean.new.cast(ENV["DRY_RUN"])

    moved, missing, untouched = 0, [], 0

    Receipt.find_each do |receipt|
      data = receipt.scan_data
      next if data.blank?

      # The main file plus every derivative (preview, thumbnail, ...) — same
      # shape, each just {"id" => ..., "storage" => ..., "metadata" => ...}.
      entries = [ data ] + data["derivatives"].to_h.values
      touched = false

      entries.each do |entry|
        key = entry["id"]
        next unless key&.start_with?(old_prefix)

        new_key = key.sub(old_prefix, new_prefix)
        if store.exists?(key)
          unless dry_run
            content = store.open(key)
            store.upload(content, new_key)
            store.delete(key)
          end
          moved += 1
        else
          # Renamed in the database regardless: the address IS wrong whether or
          # not the file behind it can still be found, and a self-hoster who
          # later finds the real file can re-attach it.
          missing << "receipt #{receipt.id}: #{key}"
        end
        entry["id"] = new_key unless dry_run
        touched = true
      end

      receipt.update_column(:scan_data, data) if touched && !dry_run
      untouched += 1 unless touched
    end

    puts "#{dry_run ? '[DRY RUN] would move' : 'Moved'}: #{moved}"
    puts "Already correct: #{untouched}"
    if missing.any?
      puts "Source file missing at the old key (nothing to copy, key #{dry_run ? 'left as-is' : 'rewritten anyway'}):"
      missing.each { |m| puts "  #{m}" }
    end
  end
end
