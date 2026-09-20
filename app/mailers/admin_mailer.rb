class AdminMailer < ApplicationMailer
  # Operational mail goes to whoever runs THIS installation. Every action below
  # sets its own recipient; this is only the last resort, and it must never be a
  # hardcoded address — a self-hoster's alerts would otherwise be delivered to
  # whoever happened to write this file.
  default to: -> { CONTACT_EMAIL }

  def tax_export_ready
    @admin             = params[:admin]
    @entity            = params[:entity]
    @start_date        = params[:start_date]
    @end_date          = params[:end_date]
    @file_list         = params[:attachments].keys
    @receipt_filename  = params[:receipt_filename]

    params[:attachments].each do |filename, content|
      attachments[filename] = { mime_type: "text/csv", content: content }
    end

    I18n.with_locale(params[:locale] || I18n.default_locale) do
      mail(
        to: @admin.email_address,
        subject: t('.subject', entity: @entity.name, start_date: @start_date, end_date: @end_date)
      )
    end
  end

  def tax_export_empty
    @admin = params[:admin]
    @entity = params[:entity]
    @start_date = params[:start_date]
    @end_date = params[:end_date]

    I18n.with_locale(params[:locale] || I18n.default_locale) do
      mail(
        to: @admin.email_address,
        subject: t('.subject', entity: @entity.name)
      )
    end
  end

  def tax_export_triggered_by_coadmin
    @parent_admin = params[:parent_admin]
    @coadmin = params[:coadmin]
    @entity = params[:entity]
    @start_date = params[:start_date]
    @end_date = params[:end_date]

    I18n.with_locale(params[:locale] || I18n.default_locale) do
      mail(
        to: @parent_admin.email_address,
        # Email, never username — this is one admin being told about
        # another admin's action, never sudo (2026-09-18).
        subject: t('.subject', coadmin: @coadmin.email_address, entity: @entity.name)
      )
    end
  end
  
  # Sent after any successful submission, to any authority. The authority is
  # derived from the scheme rather than passed in: the caller knows which return
  # was filed, and the scheme already names its own authority.
  def filing_submitted
    @admin     = params[:admin]
    @entity    = params[:entity]
    @scheme    = params[:scheme]
    @start_d   = params[:start_d]
    @end_d     = params[:end_d]
    @view_url  = params[:view_url]
    @authority = TaxSchemeConfig.authority_for(@scheme)
    # Resolved here, beside the authority: a template that reaches into a config
    # object is one rename away from breaking, and there are two templates per
    # mail.
    @scheme_label = TaxSchemeConfig.scheme_label(@scheme)

    I18n.with_locale(params[:locale] || I18n.default_locale) do
      mail(
        to:      @admin.email_address,
        subject: t('.subject', authority: @authority, entity: @entity.name,
                               period: "#{I18n.l(@start_d, format: :short_date)} – #{I18n.l(@end_d, format: :short_date)}")
      )
    end
  end

  def exchange_rates_fetch_failed
    @source = params[:source]
    @error  = params[:error]
    mail to: Admin.owner_addresses, subject: "Exchange rates fetch failed: #{@source}"
  end

  # An admin added a currency, and we asked every source whether it publishes
  # one. User-facing — any full-access bookkeeper can add a currency — so
  # localised.
  #
  # The point is to say it BEFORE the currency is met as a report that will not
  # convert: "UAH is published by HMRC and ESTV. Not by the ECB or the
  # Bundesbank." Then the admin knows whether rates will arrive on their own or
  # have to be entered by hand with evidence.
  def currency_coverage
    @admin     = params[:admin]
    @code      = params[:code]
    @published = params[:published]   # [source, ...]
    @missing   = params[:missing]     # [source, ...]

    I18n.with_locale(params[:locale] || I18n.default_locale) do
      mail(to: @admin.email_address, subject: t(".subject", code: @code))
    end
  end

  # A publisher has started carrying a currency this business holds its OWN
  # rates for.
  #
  # Without this the change is invisible: a hand-entered rate outranks the
  # published series wherever it covers the date, so the day the ECB adds
  # hryvnia the app fetches it, stores it, and goes on using the typed figure,
  # forever and silently. Whether to switch is the business's call, and usually
  # not mid-year — most authorities require the choice to be applied
  # consistently across a tax period.
  def published_rate_now_available
    @admin    = params[:admin]
    @code     = params[:code]
    @source   = params[:source]
    @entities = params[:entities]

    I18n.with_locale(params[:locale] || I18n.default_locale) do
      mail(to: @admin.email_address,
           subject: t(".subject", code: @code, source: RateSourceConfig.label_for(@source)))
    end
  end

  # Sent to a departing admin when unlinking them left an entity with no
  # bookkeepers: its records are retained for the legal period, then deleted.
  def entity_orphaned_notice
    @admin           = params[:admin]
    @entity          = params[:entity]
    @deletion_due_on = @entity.deletion_due_on
    @retention_years = Entity::RETENTION_YEARS

    I18n.with_locale(params[:locale] || I18n.default_locale) do
      mail(
        to: @admin.email_address,
        subject: t('.subject', entity: @entity.name)
      )
    end
  end

  # A catalogue file dropped a category, and these accounts were tagged with it.
  # User-facing, so localised, unlike the sudo-only ops alerts below.
  #
  # The figures of a stranded account leave the tax export and the submission
  # without a word, and the account does not show up as "needs tagging" because
  # its key is not blank. This mail is the only thing that says so.
  def tax_categories_removed
    @admin        = params[:admin]
    @scheme       = params[:scheme]
    @tax_year     = params[:tax_year]
    @accounts     = params[:accounts]
    @removed_keys = params[:removed_keys]
    @scheme_label = TaxSchemeConfig.scheme_label(@scheme)

    I18n.with_locale(params[:locale] || I18n.default_locale) do
      mail(
        to: @admin.email_address,
        subject: t('.subject', count: @accounts.size)
      )
    end
  end

  # The weekly maintenance report. Internal ops mail, sudo only, so English.
  #
  # Sent whether or not anything is wrong — see Maintenance::WeeklyCheck. The
  # verdict is in the subject so a clear week can be deleted from the inbox list
  # without opening it, and a bad week cannot be mistaken for one.
  def weekly_status
    @findings = params[:findings]
    @problems = @findings.reject(&:ok)

    subject =
      if @problems.empty?
        "✅ #{SERVICE_NAME}: weekly check — all clear"
      else
        "⚠️ #{SERVICE_NAME}: weekly check — #{@problems.size} #{'problem'.pluralize(@problems.size)}"
      end

    mail to: Admin.owner_addresses, subject: subject
  end

  # Internal ops alert from the monthly retention sweep: orphaned entities whose
  # retention has elapsed and that sudo may now confirm for deletion. Sudo only,
  # and intentionally not localised.
  def entities_due_for_deletion
    @entities = params[:entities]
    mail to:      Admin.owner_addresses,
         subject: "🗑️ #{@entities.size} entit#{@entities.one? ? 'y' : 'ies'} due for deletion (retention elapsed)"
  end

  # Internal ops alert (sudo admin only, never user-facing), so intentionally
  # not localised. Raised by the weekly Hmrc::SandboxHealthcheckJob.
  def hmrc_sandbox_check_failed
    @error = params[:error]
    mail to: Admin.owner_addresses, subject: "⚠️ HMRC sandbox healthcheck failed"
  end

  # Ops alert, English-only like the sandbox healthcheck: it goes to whoever
  # maintains the catalogues, not to a bookkeeper.
  def tax_forms_changed
    @findings = params[:findings]
    mail to: Admin.owner_addresses,
         subject: "⚠️ Tax form change detected (#{@findings.size} #{'finding'.pluralize(@findings.size)})"
  end

  # Sent the moment an admin agrees, so a copy exists outside this installation.
  # Renders the same partial the in-app page showed, so the email IS what they
  # agreed to, not a summary of it.
  def terms_agreed
    @admin   = params[:admin]
    @version = params[:version]

    I18n.with_locale(params[:locale] || I18n.default_locale) do
      mail(to: @admin.email_address, subject: t('.subject', version: @version))
    end
  end

  def password_reset
    @admin = params[:admin]
    # Use the new token generator
    @token = @admin.generate_token_for(:password_reset)
    I18n.with_locale(params[:locale] || I18n.default_locale) do
      mail to: @admin.email_address, subject: t('.subject')
    end
  end

  # The token invalidates itself if the address changes (see Admin's
  # generates_token_for block), so a stale link from before an edit stops
  # working rather than needing anything here to revoke it.
  #
  # Two mails in one, because the address being confirmed is the same address
  # either way and splitting them would let the wording drift. A draft coadmin
  # someone else created is told WHO granted WHAT before being asked to confirm
  # anything — otherwise the mail is a bare confirmation request from a service
  # they have never heard of. An admin confirming their own new address gets
  # exactly that bare request, which is all it is.
  def email_verification
    @admin   = params[:admin]
    @granter = params[:granter]
    @token   = @admin.generate_token_for(:email_verification)
    # A draft's own resend (GatesController#claim_resend) has no granter to
    # name: nothing records who granted a link. The invite wording therefore
    # has to work without one, and does — the entity list is the part that
    # carries the meaning.
    @links   = @admin.draft? ? @admin.admin_entities.includes(:entity).sort_by { |ae| ae.entity.code } : []
    @invite  = @links.any?

    I18n.with_locale(params[:locale] || I18n.default_locale) do
      subject =
        if @invite && @granter
          t('.invite_subject', granter: @granter.email_address, service: SERVICE_NAME)
        elsif @invite
          t('.invite_subject_anon', service: SERVICE_NAME)
        else
          t('.subject')
        end
      mail to: @admin.email_address, subject: subject
    end
  end

  # An EXISTING admin — a coadmin already sharing books elsewhere, or another
  # full-access admin — was just linked to one or more entities by someone else.
  # Unlike email_verification, which is sent once for a brand-new account, this
  # fires every time #grant_existing_admin_access runs: the receiver is told
  # what changed and by whom, not left to discover it on their next login.
  def access_granted
    @admin    = params[:admin]
    @granter  = params[:granter]
    @entities = params[:entities]
    @level    = params[:level]
    # Subject and both bodies interpolate the same list — built once here so
    # the three cannot render different entities.
    @entity_names = @entities.map(&:name).join(", ")

    I18n.with_locale(params[:locale] || I18n.default_locale) do
      mail(to: @admin.email_address, subject: t('.subject', entities: @entity_names))
    end
  end

end


