# frozen_string_literal: true

module Archives
  # Builds and uploads one archive file — the single point every trigger goes
  # through: a close, the sweep, a correction refresh, the manual button, a
  # dissolved-family flush. Header-only CSVs, meaning nothing happened in that
  # scope that year, are not uploaded.
  class Generate
    def self.call(scope_key:, year:, year_end: true, through: nil)
      csv = BooksCsv.new(scope_key: scope_key, year: year, through: through).generate
      return nil if csv.lines.count <= 1

      date = through || (year_end ? year : Date.current)
      key  = Storage.key_for(scope_key, date, year_end: year_end)
      Storage.upload(key, csv)
      key
    end
  end
end
