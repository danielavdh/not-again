# The demo account, marked as data rather than guessed from a username.
#
# Same reasoning as admins.sudo: matching on a name worked for exactly one
# operator and revoked itself silently the moment anyone renamed the account.
#
# It carries three consequences, all of them in code that reads this column:
#   - it is the account /demo signs a visitor in as
#   - it is exempt from OTP, because a stranger has no second factor to offer
#   - the demo exists at all only while a row has it set, so a fresh clone has
#     no public door until someone deliberately runs demo:seed
class AddDemoToAdmins < ActiveRecord::Migration[8.1]
  def change
    add_column :admins, :demo, :boolean, default: false, null: false
    add_index  :admins, :demo, where: "demo", name: "index_admins_on_demo_true"
  end
end
