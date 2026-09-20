# frozen_string_literal: true

# Whether a SYSTEM language's translation has actually been checked by a
# native speaker — shown on the languages index so a sudo choosing between
# starter options knows which to trust. Meaningless for custom rows: sudo
# wrote or reviewed that content themselves by definition of releasing it.
#
# Only German is true here — confirmed native-reviewed. Spanish and Dutch
# are explicitly confirmed NOT yet reviewed. Arabic's status was never
# stated either way, so it defaults to false rather than being guessed at.
class AddReviewedToLanguages < ActiveRecord::Migration[8.1]
  def change
    add_column :languages, :reviewed, :boolean, null: false, default: false

    reversible do |dir|
      dir.up { execute "UPDATE languages SET reviewed = true WHERE code = 'de' AND source = 0" }
    end
  end
end
