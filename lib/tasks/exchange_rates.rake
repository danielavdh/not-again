# frozen_string_literal: true

namespace :exchange_rates do
  desc 'Fetch latest exchange rates from ECB and HMRC'
  task fetch: :environment do
    result = Rates::Fetcher.fetch_and_store!
    
    puts "ECB:  #{result[:ecb]}"
    puts "HMRC: #{result[:hmrc]}"
  end
end

# run manually with `rails exchange_rates:fetch`


#Your 3am on the 1st approach is correct for HMRC - by then the rates for that month are already published (from the previous month's penultimate Thursday). For ECB, you'd want the last business day of the previous month to get the rate applicable to that month's transactions.