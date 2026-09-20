class EntitiesController < BaseController
  TAX_MEMBER_ACTIONS = [:edit_tax, :update_tax, :filing_fields].freeze
  # Any admin may leave (unlink themselves from) an entity they belong to.
  SELF_SERVICE_ACTIONS = [:leave].freeze

  # update is normally sudo (full entity edit), but a full-access admin may make
  # a GROUP-ONLY update from their admin/show page (see authorize_update).
  require_sudo except: TAX_MEMBER_ACTIONS + SELF_SERVICE_ACTIONS + [:update]
  # Leaving is not a write to the books, it is disconnecting yourself — but
  # BaseController's require_write_access runs on every action and would
  # redirect a read_only or upload_receipts admin away before #leave ever runs.
  skip_before_action :require_write_access, only: SELF_SERVICE_ACTIONS
  before_action :set_entity,              only: [:edit, :update, :destroy, :leave]
  before_action :authorize_update,        only: [:update]
  before_action :set_accessible_entity,   only: TAX_MEMBER_ACTIONS
  before_action :require_tax_edit_access, only: TAX_MEMBER_ACTIONS
  layout "accounting"

  def index
    # Active entities first, orphaned ones sink to the bottom.
    @entities = Entity.includes(:entity_group)
                           .order(Arel.sql("orphaned_at IS NULL DESC, code"))
  end

  def show
    @entity = accessible_entities.includes(report_groups: :reports).find(params[:id])
    @recent_entries = accessible_journal_entries.for_entity(@entity).order(entry_date: :desc).limit(5)
  end

  def new
    @entity = Entity.new
  end

  def create
    @entity = Entity.new(entity_params)
    if @entity.save
      redirect_to entity_path(@entity), notice: "Entity created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @entity_groups = EntityGroup.order(:name)
  end

  def edit_tax
    load_tax_form_data
  end

  # The taxpayer picker for a scheme that has only just been TICKED, so its
  # authority has no block on the page yet: #filing_authorities is built from
  # saved schemes and must stay that way, or unticking one would leave its
  # fieldset behind.
  #
  # Renders nothing when the scheme cannot be filed, or when its authority is
  # already on the page — one taxpayer per authority, so a second picker would
  # be a second answer to a question that has one.
  def filing_fields
    entry = submittable_scheme(params[:scheme])
    return head(:no_content) unless entry
    return head(:no_content) if filing_authorities.any? { |a| a[:key] == entry[:key] }

    render partial: "entities/filing_fields",
           locals: { authority: authority_entry(**entry.slice(:key, :connector, :scheme), groups: []) }
  end

  def update_tax
    if @entity.update(tax_params)
      ensure_tax_report_groups
      discard_empty_unsubscribed_groups
      update_filing_details
      setup_changed = @entity.saved_changes.key?("tax_schemes")
      if setup_changed
        before, after = @entity.saved_changes.fetch("tax_schemes", [[], Array(@entity.tax_schemes)])
        removed = Array(before) - Array(after)
        added   = Array(after)  - Array(before)

        # Subscribing to a scheme is only half the job — the accounts still have
        # to be assigned to it — so land on the scheme's own page, where that is
        # done. Several schemes at once is rare, so the first one added wins.
        new_group = added.any? && @entity.report_groups.find_by(tax_scheme: added.first)

        notice =
          if removed.any? && added.empty?
            # Only schemes removed — no filing guidance, just confirm the
            # removal.
            t("entities.edit_tax.unsubscribed",
              schemes: removed.map { |s| TaxSchemeConfig.scheme_label(s) }.to_sentence)
          elsif Account.unmapped_for_tax(entity_codes: [@entity.code]).exists?
            t("entities.edit_tax.updated")
          else
            t("entities.edit_tax.updated_no_accounts")
          end
        redirect_to (new_group ? report_group_path(new_group) : dashboard_path),
                    notice: notice
      else
        redirect_to edit_tax_entity_path(@entity), notice: t("entities.edit_tax.saved")
      end
    else
      load_tax_form_data
      render :edit_tax, status: :unprocessable_entity
    end
  end

  def update
    return update_group_only if group_only_update?

    @entity_groups = EntityGroup.order(:name)
    @entity.assign_attributes(entity_params)
    @entity.entity_group = resolved_group if group_value_submitted?
    if @entity.save
      redirect_to entity_path(@entity), notice: "Entity updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Sudo-confirmed purge of an orphaned entity and ALL its data. Only permitted
  # once the entity has no admins: to delete a live entity, its admins must be
  # unlinked first. The view warns when the retention deadline has not yet
  # passed; the final call is sudo's. Irreversible and slow, so it runs in
  # Entities::PurgeJob.
  def destroy
    unless @entity.orphaned?
      redirect_to entities_path, alert: t("entities.purge.not_orphaned")
      return
    end

    Entities::PurgeJob.perform_later(@entity.id)
    redirect_to entities_path,
                notice: t("entities.purge.started",
                          code: @entity.code, name: @entity.name)
  end

  # An admin unlinks themselves from an entity. If they were the last admin the
  # entity is orphaned and the retention clock starts — handled by the
  # AdminEntity callback, which also emails them.
  #
  # Never demo. The skip_before_action above opens this action to
  # read_only/upload_receipts admins, which is what it is for, but it cannot
  # distinguish a genuine read_only admin from the public demo account — and
  # require_write_access's own demo branch was what had been blocking demo here.
  def leave
    if demo_admin?
      redirect_to dashboard_path, alert: t("access.read_only_deny")
      return
    end

    link = @entity.admin_entities.find_by(admin_id: current_admin.id)
    if link.nil?
      redirect_to dashboard_path, alert: t("entities.leave.not_member")
      return
    end

    link.destroy
    redirect_to dashboard_path,
                notice: t("entities.leave.done", name: @entity.name)
  end

  private

  def set_entity
    @entity = Entity.find(params[:id])
  end

  # update is sudo for a full entity edit. A full-access admin reaches it ONLY
  # for a group-only update, on an entity they hold, into a family they may
  # join. read_only/upload-only never get here.
  def authorize_update
    return if sudo?

    # An entity already in a family can never be MOVED to a different one from
    # here — only sudo does that, via the entity's own full edit page. LEAVING
    # (clearing it back to none) is allowed, but only for an admin who
    # manages_family? the whole family. The "Leave the family" checkbox submits
    # group_value blank, same endpoint, same shape as ungrouping.
    permitted = group_only_update? &&
                current_admin.writable_entity_ids.include?(@entity.id) &&
                (@entity.entity_group_id? ? leaving_family_permitted? : joining_family_permitted?)
    head :forbidden unless permitted
  end

  def leaving_family_permitted?
    resolved_group.nil? && current_admin.manages_family?(@entity.entity_group)
  end

  # A full-access admin sets only the family, then returns to admin/show.
  #
  # An already-grouped entity's form has no group_value at all, just the "Leave
  # the family" checkbox, so a plain submit with it unticked must be a no-op
  # rather than resolving to blank and leaving anyway. Ticking it is the only
  # thing that runs Entity#family_ties_do_not_block_leaving.
  def update_group_only
    if @entity.entity_group_id?
      unless params.dig(:entity, :leave_family) == "1"
        redirect_back fallback_location: dashboard_path
        return
      end
      @entity.entity_group = nil
    else
      @entity.entity_group = resolved_group
    end

    if @entity.save
      redirect_back fallback_location: dashboard_path,
                    notice: t("entities.group.updated", entity: @entity.code)
    else
      redirect_back fallback_location: dashboard_path,
                    alert: @entity.errors.full_messages.to_sentence
    end
  end

  def group_only_update?
    params[:group_only].present?
  end

  def group_value
    params.dig(:entity, :group_value)
  end

  def group_value_submitted?
    params[:entity]&.key?(:group_value)
  end

  def resolved_group
    return @resolved_group if defined?(@resolved_group)
    @resolved_group = EntityGroup.resolve(group_value)
  end

  # A new/empty family has no members and is always joinable; an existing one
  # only if the actor manages_family? it — full access to every current member.
  def joining_family_permitted?
    resolved_group.nil? || current_admin.manages_family?(resolved_group)
  end

  def set_accessible_entity
    @entity = accessible_entities.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    deny_access(t("access.read_only_deny"), dashboard_path)
  end

  def require_tax_edit_access
    return unless @entity
    # edit_tax is a form, and the demo may look at forms — update_tax is a PATCH
    # and is refused by the same rule that refuses every other write.
    return if demo_may_look?

    unless sudo? || can_edit_for_entity?(@entity.code)
      deny_access(t("access.read_only_deny"), dashboard_path)
    end
  end

  # Everything edit_tax renders that neither the model nor the view should be
  # assembling. Needed on the re-render after a failed save too, or the form
  # blows up on the one path where the user most needs to see it.
  def load_tax_form_data
    @schemes_by_country   = TaxSchemeConfig.schemes_by_country
    @tax_groups_by_scheme = @entity.tax_report_groups_by_scheme
    @filing_authorities   = filing_authorities
    @authority_by_scheme  = authority_by_scheme
    # scheme => its own name, in the language of its form. The page lists every
    # scheme it knows, so it needs every label.
    @scheme_labels = @schemes_by_country.values.flatten
                                        .index_with { |s| TaxSchemeConfig.scheme_label(s) }
  end

  # scheme => [authority key, authority name], for the SUBMITTABLE ones only.
  # Ticking one of these is the only time the page asks whether you file from
  # here or just export; the rest stop at tagging.
  def authority_by_scheme
    @schemes_by_country.values.flatten.to_h { |scheme|
      entry = submittable_scheme(scheme)
      [ scheme, entry && [ entry[:key], TaxSchemeConfig.authority_for_connector(entry[:connector]) ] ]
    }.compact
  end

  def tax_groups_by_scheme
    @tax_groups_by_scheme ||= @entity.tax_report_groups_by_scheme
  end

  # One entry per AUTHORITY this entity can actually file with — its subscribed
  # schemes that have a connector, grouped by who they are filed to.
  #
  # By authority rather than by scheme because permission is per authority: one
  # login covers every scheme behind it, so two blocks would print the same
  # connection state twice. The consequence is that an entity files to one
  # authority as ONE taxpayer — two people filing to HMRC need two entities.
  def filing_authorities
    @filing_authorities ||= Array(@entity.tax_schemes).filter_map { |scheme|
      submittable_scheme(scheme)
    }.group_by { |e| e[:key] }.map { |key, entries|
      groups = entries.map { |e| e[:scheme] }.filter_map { |s| tax_groups_by_scheme[s] }
      authority_entry(key: key, connector: entries.first[:connector],
                      scheme: entries.first[:scheme], groups: groups)
    }
  end

  # A scheme that can be FILED, not merely tagged and exported — it names a
  # connector and that connector exists. nil for the rest, which is most of
  # them.
  def submittable_scheme(scheme)
    connector = TaxSchemeConfig.connector_for(scheme)
    klass     = Filing::Base.connector_class(connector)
    return unless klass
    { key: klass.authority_key, connector: connector, scheme: scheme }
  end

  # scheme only decides the anchor's country; everything else about the block
  # belongs to the authority. groups is empty for a scheme that has only just
  # been ticked (see #filing_fields), and the partial then renders the picker
  # and stops — there is nothing to ask an authority until it knows whose books
  # these are.
  def authority_entry(key:, connector:, scheme:, groups:)
    # One taxpayer per authority, so it is read off any of this authority's
    # groups — update_filing_details keeps them in step.
    taxpayer = groups.map(&:taxpayer).compact.first
    {
      key:             key,
      connector:       connector,
      name:            TaxSchemeConfig.authority_for_connector(connector),
      # So "Manage taxpayers" can bring you back here instead of dead-ending on
      # the dashboard — the taxpayers index only honours it if it resolves to
      # this route.
      return_to:       edit_tax_entity_path(@entity),
      # Whether this authority wants the browser to collect anything before the
      # OAuth round trip starts. The view carries it as a data attribute.
      browser_collector: Filing::Base.connector_class(connector)&.browser_collector,
      anchor:          "#{TaxSchemeConfig.country_for(scheme)}_connection",
      groups:          groups,
      taxpayer:        taxpayer,
      choices:         current_admin.usable_taxpayers.for_authority(key).order(:label, :id),
      # What the authority says this taxpayer runs, keyed by scheme. Fetched
      # only once connected, because there is nothing to ask until then — and
      # asking is the point: a business identifier cannot be guessed, and a
      # free-text box before connecting only invites a wrong value.
      businesses:      businesses_for(connector, taxpayer),
      # Schemes we refuse to offer a choice for, because the authority's own
      # names do not distinguish its businesses. See
      # Filing::Base.ambiguous_schemes.
      blocked_schemes: blocked_schemes_for(connector, taxpayer),
      # Where the taxpayer fixes those names.
      name_help_url:   Filing::Base.connector_class(connector)&.business_name_help_url,
      # What each group may actually be given, keyed by group id — the view is
      # then a form and nothing else.
      offered:         groups.to_h { |g| [ g.id, offered_for(connector, taxpayer, g) ] }
    }
  end

  # Empty unless the taxpayer is connected, and never raises — the connector
  # rescues an unreachable authority to {}.
  #
  # Memoised per taxpayer: rendering asks for the stored one and saving asks for
  # the submitted one, usually the same, and each ask is an HTTP call.
  def businesses_for(connector, taxpayer)
    return {} unless taxpayer&.connected?

    @businesses ||= {}
    @businesses[taxpayer.id] ||=
      Filing::Base.for(connector, entity: @entity, scheme: nil,
                            admin: current_admin, taxpayer: taxpayer)
                       .businesses_by_scheme
  end

  # Judged on the authority's FULL list, before anything of ours is taken out of
  # it: whether two businesses can be told apart is a fact about the authority's
  # data, and hiding one we have already used would make the rest look clear
  # while leaving the earlier choice a guess.
  def blocked_schemes_for(connector, taxpayer)
    klass = Filing::Base.connector_class(connector)
    return [] unless klass
    klass.ambiguous_schemes(businesses_for(connector, taxpayer))
  end

  # business_id => the report group holding it, for every group filing under
  # this taxpayer, wherever those groups live. Two columns plucked, nothing
  # loaded.
  #
  # Ranges over the taxpayer rather than the entity because that is where a
  # clash can exist at all: each entity has only its own group, so the second
  # set of books is only reachable through the taxpayer they share.
  def claimed_business_ids(taxpayer)
    return {} unless taxpayer

    @claimed ||= {}
    @claimed[taxpayer.id] ||=
      ReportGroup.where(taxpayer_id: taxpayer.id)
                      .where.not(business_id: nil)
                      .pluck(:business_id, :id).to_h
  end

  # The authority's list for this group's scheme, minus every business already
  # claimed by another of this taxpayer's groups.
  #
  # Two groups pointing at one business would take turns overwriting each other:
  # each update replaces the last one for that business, so the authority keeps
  # whichever went last and the other trade is never filed at all. Nothing
  # errors, and both archived copies look right on their own.
  def offered_for(connector, taxpayer, group)
    claimed = claimed_business_ids(taxpayer)
    (businesses_for(connector, taxpayer)[group.tax_scheme] || []).reject { |b|
      owner = claimed[b["businessId"]]
      owner && owner != group.id
    }
  end

  def tax_params
    params.require(:entity).permit(:accountant_export, tax_schemes: []).tap do |p|
      p[:tax_schemes] = Array(p[:tax_schemes]).reject(&:blank?) if p[:tax_schemes]
    end
  end

  # The taxpayer and the business identifier belong to the tax report GROUP, not
  # to the entity, so they are saved separately from the entity form.
  #
  # Everything here is scoped to what this admin may actually reach: only their
  # own taxpayers, and only groups belonging to this entity. A stray id in the
  # params can therefore choose nothing it should not.
  def update_filing_details
    submitted = params[:filing]
    return if submitted.blank?

    # Recomputed, because the groups may have been created a moment ago by
    # ensure_tax_report_groups.
    @filing_authorities = @tax_groups_by_scheme = nil

    filing_authorities.each do |authority|
      attrs = submitted[authority[:key]]
      next if attrs.blank?

      # Only taxpayers this admin may use, so a stray id in the params cannot
      # attach an unrelated one to these books.
      taxpayer = current_admin.usable_taxpayers.find_by(id: attrs[:taxpayer_id])

      # One taxpayer per authority: every group behind this authority gets the
      # same taxpayer. Two people filing to HMRC need two entities.
      authority[:groups].each do |group|
        group.taxpayer    = taxpayer
        group.business_id = chosen_business_id(authority, taxpayer, group, attrs)
        group.save!
      end
    end
  end

  # Unsubscribing from a scheme that never produced a report takes its group
  # with it: an empty group for a scheme you no longer file is clutter. A group
  # WITH reports always survives — the reports are the admin's to keep or
  # discard, and once they are gone the delete button appears on the group
  # itself. The cost of discarding is that the business identifier goes with it.
  #
  # Unsubscribing also RELEASES the scheme's accounts, or they keep a tag for a
  # return this entity no longer files and become invisible: no assign page
  # lists them (the group is gone) and unmapped_for_tax does not flag them
  # either, because it looks for a BLANK key and theirs is set.
  #
  # Only where the group is actually discarded. A group kept because it has
  # reports still needs its accounts: a report stores a name and two dates and
  # nothing else, so every figure is recomputed from the accounts at render
  # time, and releasing them would quietly empty a historical report.
  def discard_empty_unsubscribed_groups
    @entity.report_groups.tax_reports.find_each do |group|
      next if Array(@entity.tax_schemes).include?(group.tax_scheme)
      next unless group.reports.empty?

      Account.release_from_scheme(entity_code: @entity.code, scheme: group.tax_scheme)
      group.destroy
    end
  end

  # The submitted identifier, but only if the authority actually offers it and
  # nothing else has already claimed it.
  #
  # Worked out against the taxpayer BEING SUBMITTED, not the one already stored:
  # on the first save there is no stored one, and that is exactly when a wrong
  # identifier gets in.
  #
  # The form is a dropdown of what the authority holds, so a value that is not
  # on that list did not come from the authority — it came from a stale form or
  # a hand-made request. Silently keeping it would file this entity's figures
  # against something that is not its business, and the submission would be
  # accepted.
  def chosen_business_id(authority, taxpayer, group, attrs)
    connector = authority[:connector]

    # Blocked: no choice was offered for this scheme, so there is no answer to
    # read. Keep what is stored rather than clearing it — a taxpayer who
    # registers a second, nameless trade today must not lose the identifier
    # chosen last week, when there was only one and nothing was ambiguous.
    return group.business_id if blocked_schemes_for(connector, taxpayer).include?(group.tax_scheme)

    submitted = attrs.dig(:business_ids, group.tax_scheme).to_s.strip.presence

    # An EMPTY LIST FROM THE AUTHORITY means it could not be reached; the field
    # falls back to free text and so does this, or a bad afternoon at HMRC would
    # wipe every identifier on the page. An empty list after our own filtering
    # is a different thing entirely — every business is already spoken for — and
    # no reason to start accepting hand-typed values.
    return submitted if (businesses_for(connector, taxpayer)[group.tax_scheme]).blank?

    return submitted if offered_for(connector, taxpayer, group)
                          .any? { |b| b["businessId"] == submitted }

    nil
  end

  # A tax report group per scheme the entity is subscribed to, created the
  # moment it subscribes. Idempotent — the unique index does the real work — and
  # only ever additive: unsubscribing does not delete the group, because reports
  # live under it and the admin should choose what happens to them.
  def ensure_tax_report_groups
    Array(@entity.tax_schemes).each do |scheme|
      next if @entity.report_groups.exists?(tax_scheme: scheme)
      @entity.report_groups.create!(
        tax_scheme: scheme,
        name:       TaxSchemeConfig.report_name(scheme) || scheme
      )
    end
  rescue ActiveRecord::RecordNotUnique
    # Raced with a concurrent save; the group exists, which is all we wanted.
    nil
  end

  # The catalogues are shipped with the code, so they are loaded with the code:
  # .kamal/hooks/pre-deploy, right after db:migrate. Run bin/rails
  # tax_categories:load by hand after editing a file, and read what it prints.
  #
  # Never from a user's save, which is where this used to live: that made a save
  # rewrite reference data — including the delete that removes categories a file
  # no longer declares — at an arbitrary moment, with output nobody would read.

  def entity_params
    params.require(:entity).permit(
      :name, :code, :active, :accountant_export,
      tax_schemes: []
    ).tap do |p|
      p[:tax_schemes] = Array(p[:tax_schemes]).reject(&:blank?) if p[:tax_schemes]
    end
  end
end
