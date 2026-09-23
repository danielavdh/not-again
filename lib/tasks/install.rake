# Creating the first admin, which is otherwise impossible.
#
# Every page in this app is behind a login, and the page that creates admins is
# behind require_full_access as well, so a fresh installation is a closed loop:
# you cannot make an admin without being one. This task is the way in, and the
# only one.
#
# It refuses to run if any admin already exists. That is not a formality — it is
# what stops the task being a permanent back door into a running installation.
namespace :install do
  desc "Create the first admin (the owner). Refuses if any admin already exists."
  task owner: :environment do
    if Admin.any?
      abort <<~MSG
        This installation already has #{Admin.count} admin(s), so there is nothing to bootstrap.

        A new admin is added by an existing owner, from Admins in the app.
        If you have lost access to every owner account, open a console and set
        the flag by hand — there is deliberately no task for it:

            bin/rails runner 'Admin.find_by(username: "…").update!(sudo: true)'
      MSG
    end

    username = owner_env("USERNAME") || prompt("Username")
    email    = owner_env("EMAIL")      || prompt("Email address (optional, used for password resets)", allow_blank: true)
    password = owner_env("PASSWORD")   || prompt_secret("Password (at least 8 characters)")

    admin = Admin.new(username: username, email_address: email.presence, sudo: true)
    admin.password = password

    unless admin.save
      abort "\nCould not create the admin:\n" + admin.errors.full_messages.map { |m| "  - #{m}" }.join("\n")
    end

    puts <<~DONE

      Created "#{admin.username}" as the owner of this installation.

      Owner means: full access everywhere, and the only account that can reach
      the admin list. It is a column on the admins row (admins.sudo), so a second
      owner is made by ticking the box on their admin page — and the last one
      cannot be removed, by either route.

      Next: start the app, sign in, and create your first entity. In production
      you will be asked to set up a second factor before anything else.
    DONE

    warn "\nNOTE: PASSWORD was read from the environment, so it is in your shell history." if ENV["PASSWORD"].present?
  end

  # The same thing for a platform that has no terminal to type into — a hosted
  # deploy (Scalingo, and anything else with a post-deploy hook) runs this with
  # OWNER_USERNAME / OWNER_EMAIL / OWNER_PASSWORD set, and a fresh installation
  # comes up with a way in. Without it that installation is unreachable: every
  # page needs a login, and only an owner can make one.
  #
  # Unlike install:owner it SUCCEEDS when the installation is already set up,
  # because it runs on every deploy and a deploy must not fail on the second
  # one. It is no more of a back door than install:owner: it refuses just the
  # same, it only refuses quietly. Nothing existing is ever changed.
  #
  # The test is ANY admin, not "no owner". An installation whose last owner was
  # somehow demoted by hand still holds real books, and minting a fresh owner
  # into it from environment variables would be a way in that nobody asked for.
  # "Is this installation still empty?" cannot do that.
  desc "Create the owner from OWNER_USERNAME/OWNER_EMAIL/OWNER_PASSWORD, or do nothing if this installation has admins."
  task owner_if_missing: :environment do
    if Admin.any?
      puts "This installation already has #{Admin.count} admin(s) — nothing to do."
      next
    end

    unless ENV["OWNER_USERNAME"].present? && ENV["OWNER_PASSWORD"].present?
      abort "OWNER_USERNAME and OWNER_PASSWORD must be set to create the first admin."
    end

    Rake::Task["install:owner"].invoke
  end

  # RECOVERY — a back door by nature, but not a NEW one: anyone who can run this
  # already has the database and a Rails console, so it grants nothing shell
  # access did not. What it adds is that the way back is documented instead of
  # being folklore about ActiveRecord in a console.
  #
  # It matters more here than in a hosted app. Password reset goes out over
  # SMTP, and an installation on somebody's laptop has no SMTP at all — so
  # without this, "I forgot my password" means the books are gone for good.
  desc "Set a new password for an admin. For when reset-by-email is not available."
  task reset_password: :environment do
    admin = find_admin!(ENV["USERNAME"].presence || prompt("Username"))

    admin.password = ENV["PASSWORD"].presence || prompt_secret("New password (at least 8 characters)")

    unless admin.save
      abort "\nCould not change the password:\n" + admin.errors.full_messages.map { |m| "  - #{m}" }.join("\n")
    end

    puts "\nPassword changed for \"#{admin.username}\". Existing sessions stay signed in."
    warn "\nNOTE: PASSWORD was read from the environment, so it is in your shell history." if ENV["PASSWORD"].present?
  end

  # The other half of the lockout: a correct password is not enough once the
  # phone holding the second factor is lost, and in production a second factor
  # is required.
  desc "Clear an admin's second factor, so they set it up again at the next sign-in."
  task reset_otp: :environment do
    admin = find_admin!(ENV["USERNAME"].presence || prompt("Username"))

    unless admin.otp_configured?
      puts "\n\"#{admin.username}\" has no second factor set up. Nothing to clear."
      next
    end

    admin.disable_otp!

    puts <<~DONE

      Cleared the second factor for "#{admin.username}".

      In production they will be asked to set up a new one at the next sign-in,
      so have the new device to hand.
    DONE
  end

  # RECOVERY, same class as reset_password and reset_otp above, for the one
  # scenario the app deliberately refuses to solve through its own UI. Owners
  # cannot edit, demote or delete each other there — can_manage? refuses every
  # owner but yourself, on purpose, so a rogue owner cannot be reached from
  # another owner's session, which would just mean whoever moves first wins. The
  # person with server access is the actual backstop.
  #
  # Demotes, does not delete. It revokes access immediately, since a demoted
  # admin holds no entity links either and so can reach nothing at all, while
  # leaving the account and its history in place. Deleting it too is a separate,
  # deliberate step.
  desc "Demote a rogue owner. The one thing owners cannot do to each other in the app."
  task demote_owner: :environment do
    admin = find_admin!(ENV["USERNAME"].presence || prompt("Username"))

    unless admin.sudo?
      puts "\n\"#{admin.username}\" is not an owner. Nothing to do."
      next
    end

    unless admin.update(sudo: false)
      abort "\nCould not demote \"#{admin.username}\":\n" + admin.errors.full_messages.map { |m| "  - #{m}" }.join("\n")
    end

    puts <<~DONE

      Demoted "#{admin.username}". They hold no entity links, so — unlike a
      full-access or read-only admin — they can now reach nothing in the app.

      The account itself still exists. To remove it entirely:

          bin/rails runner 'Admin.find_by(username: "#{admin.username}").destroy'
    DONE
  end

  # OWNER_-prefixed first: a hosted platform sets these as ordinary app
  # environment variables, where a bare USERNAME would collide with the one
  # every Unix shell already has.
  def owner_env(name)
    ENV["OWNER_#{name}"].presence || ENV[name].presence
  end

  def find_admin!(username)
    admin = Admin.find_by(username: username)
    return admin if admin

    known = Admin.order(:username).pluck(:username)
    abort "\nNo admin called #{username.inspect}." +
          (known.any? ? " This installation has: #{known.join(', ')}." : " This installation has no admins — use install:owner.")
  end

  def prompt(label, allow_blank: false)
    loop do
      print "#{label}: "
      value = $stdin.gets.to_s.strip
      return value if allow_blank || value.present?

      puts "  required."
    end
  end

  # No echo, and never reaches the shell history.
  def prompt_secret(label)
    require "io/console"
    loop do
      print "#{label}: "
      value = $stdin.noecho(&:gets).to_s.strip
      puts
      print "Confirm: "
      confirm = $stdin.noecho(&:gets).to_s.strip
      puts
      next puts "  they do not match." unless value == confirm
      next puts "  at least 8 characters." if value.length < 8

      return value
    end
  end
end
