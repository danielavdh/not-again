# frozen_string_literal: true

class ReceiptsController < BaseController
  allow_unauthenticated_access only: [:download]
  skip_before_action :ensure_admin, only: [:download]
  skip_before_action :require_accounts_access, only: [:download]
  skip_before_action :require_otp_verification, only: [:download]
  skip_before_action :require_write_access, only: [:download, :upload_standalone, :create, :index, :delete_own, :show, :download_selected]
  before_action :set_receipt, only: [:show, :edit, :update, :destroy, :unlink]
  before_action :require_receipt_access, only: [:new, :create, :upload_standalone, :share_receive]
  # NOT covered by require_write_access — the line above skips it for :create
  # and :delete_own, so those two are the one place in the app a demo could
  # actually write. An upload-only demo account has receipt access by
  # definition, which is exactly what makes it able to upload; this is what
  # stops it.
  before_action :refuse_demo_writes, only: [:create, :delete_own]
  before_action :authorize_receipt_target, only: [:create, :update]
  before_action :require_writable_receipt, only: [:edit, :update, :destroy, :unlink]

  def index
    scope = accessible_receipts
              .includes(:entity, posting: [:account, :journal_entry])
              .recent_first

    scope = scope.for_entity(current_entity) if params[:entity_id].present?
    scope = scope.unlinked if params[:filter] == "unlinked"
    scope = scope.linked if params[:filter] == "linked"

    if params[:start_date].present? && params[:end_date].present?
      scope = scope.by_date_range(params[:start_date].to_date, params[:end_date].to_date)
    end

    @pagy, @receipts = pagy(scope, limit: 30)
    @entities = accessible_entities
  end

  # Exactly the receipts ticked on the index page, zipped — the answer to "get
  # the receipt files out", since the year-end archive deliberately does not
  # carry them.
  #
  # Filtered through accessible_receipts, not Receipt.where(id:): the posted ids
  # are trusted for WHICH rows, never for whether this admin may see them.
  def download_selected
    ids = Array(params[:receipt_ids])
    receipts = accessible_receipts.where(id: ids)
    if receipts.none?
      redirect_to receipts_path, alert: t("receipts.none_selected")
      return
    end

    missing = []
    buffer = Zip::OutputStream.write_buffer do |zos|
      receipts.each do |receipt|
        # id-prefixed: two receipts uploaded the same day for the same trader
        # produce the same display_filename, and a zip entry silently overwrites
        # rather than erroring on a collision.
        data = read_scan(receipt)
        if data.nil?
          missing << "#{receipt.id}-#{receipt.display_filename}"
          next
        end
        zos.put_next_entry("#{receipt.id}-#{receipt.display_filename}")
        zos.write(data)
      end

      # A file the bucket has lost must not 500 the whole download — the other
      # receipts still come through, and the zip says which ones did not.
      if missing.any?
        zos.put_next_entry("_MISSING.txt")
        zos.write("These receipts could not be included — the stored file was not found:\n\n#{missing.join("\n")}\n")
      end
    end

    send_data buffer.string, filename: "receipts-#{Date.current.strftime('%y-%m-%d')}.zip",
      type: "application/zip", disposition: "attachment"
  end

  def show
    respond_to do |format|
      format.html
      format.json do
        render json: receipt_json(@receipt) 
      end
    end
  end

  def new
    @receipt = Receipt.new(receipt_date: Date.current)
    @receipt.posting_id = params[:posting_id] if params[:posting_id]
    @entities = accessible_entities_for_upload
  end

  def create
    @receipt = Receipt.new(receipt_params)
    @receipt.uploaded_by = current_admin

    if @receipt.save
      session[:last_upload_entity_id] = @receipt.entity_id if upload_receipts_only?
      respond_to do |format|
        format.html do
          if upload_receipts_only?
              redirect_to upload_standalone_receipts_path, notice: t("receipts.created")
            else
              redirect_to receipts_path, notice: t("receipts.created")
            end
        end
        format.json { render json: receipt_json(@receipt), status: :created }
      end
    else
      respond_to do |format|
        format.html do
          @entities = accessible_entities_for_upload
          if upload_receipts_only?
            @my_receipts = accessible_receipts.unlinked.where(uploaded_by: current_admin).recent_first.limit(20)
            render :upload_standalone, status: :unprocessable_entity
          else
            render :new, status: :unprocessable_entity
          end
        end
        format.json { render json: { errors: @receipt.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end
  
  def edit
    @entities = accessible_entities_for_upload
  end

  def update
    if @receipt.update(receipt_params)
      respond_to do |format|
        format.html { redirect_to receipts_path, notice: t("receipts.updated") }
        format.json { render json: receipt_json(@receipt) }
      end
    else
      respond_to do |format|
        format.html do
          @entities = accessible_entities_for_upload
          render :edit, status: :unprocessable_entity
        end
        format.json { render json: { errors: @receipt.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def destroy
    @receipt.destroy
    respond_to do |format|
      format.html { redirect_to receipts_path, notice: t("receipts.deleted") }
      format.json { head :no_content }
    end
  end
  
  def delete_own
    receipt = Receipt.unlinked.where(uploaded_by: current_admin).find(params[:id])
    receipt.destroy
    redirect_to upload_standalone_receipts_path, notice: t("receipts.deleted")
  end

  def download
    receipt = Receipt.find_signed(params[:sgid], purpose: :download)
    return head :not_found unless receipt
    url = receipt.original_url
    return head :not_found unless url
    redirect_to url, allow_other_host: true
  end

  # POST /receipts/:id/link - link receipt to a posting
  def link
    @receipt = accessible_receipts.find(params[:id])
    @receipt.link_to_posting!(accessible_postings.find(params[:posting_id]))
    render json: receipt_json(@receipt)
  rescue => e
    Rails.logger.error "Receipt#link failed: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    render json: { error: "#{e.class}: #{e.message}" }, status: :unprocessable_entity
  end

  # POST /receipts/:id/unlink - unlink receipt from posting
  def unlink
    @receipt.unlink_from_posting!
    respond_to do |format|
      format.html { redirect_back fallback_location: receipts_path, notice: t("receipts.unlinked") }
      format.json { render json: receipt_json(@receipt.reload) }
    end
  end

  # GET /receipts/for_posting/:posting_id — HTML for the picker modal's list,
  # JSON when the caller only wants the data (refreshPostingReceipts asks
  # nothing but "are there any?").
  def for_posting
    receipts = accessible_receipts.where(posting_id: params[:posting_id])
    respond_to do |format|
      format.html do
        render partial: "receipts/picker_items",
               locals: { receipts: receipts, action: "preview-receipt", posting_id: params[:posting_id] }
      end
      format.json { render json: receipts.map { |r| receipt_json(r) } }
    end
  end

  # GET /receipts/unlinked - unlinked receipts for entity (JSON)
  def unlinked
    if current_admin.sudo?
      receipts = accessible_receipts.unlinked.recent_first.limit(50)
    else
      entity_ids = current_admin.entities.pluck(:id)
      receipts = accessible_receipts.unlinked.where(entity_id: entity_ids).recent_first.limit(50)
    end
    respond_to do |format|
      format.html do
        render partial: "receipts/picker_items",
               locals: { receipts: receipts, action: "pick-receipt", posting_id: params[:posting_id] }
      end
      format.json { render json: receipts.map { |r| receipt_json(r) } }
    end
  end

  # Upload-only interface for restricted admins
  def upload_standalone
    @receipt = Receipt.new(receipt_date: Date.current)
    @entities = accessible_entities_for_upload
    if @entities.size > 1 && session[:last_upload_entity_id].present?
      @receipt.entity_id = session[:last_upload_entity_id]
    end
    @my_receipts = accessible_receipts.unlinked
                     .where(uploaded_by: current_admin)
                     .recent_first
                     .limit(20)
    render :upload_standalone
  end

  def share_receive
    @receipt = Receipt.new(receipt_date: Date.current)
    @entities = accessible_entities_for_upload

    # Pre-fill from share data
    @receipt.title = params[:title].presence || params[:text].presence || "Shared receipt"

    if params[:scan].present?
      @receipt.scan = params[:scan]
    end

    render :share_receive
  end

  private

  # nil when the receipt has no scan or the stored object is gone — the caller
  # skips it rather than letting one lost file 500 the whole zip.
  def read_scan(receipt)
    return nil if receipt.scan.blank?
    receipt.scan.read
  rescue Shrine::FileNotFound, Errno::ENOENT, Aws::S3::Errors::NoSuchKey => e
    Rails.logger.warn "download_selected: receipt #{receipt.id} scan missing: #{e.class}"
    nil
  end

  def set_receipt
    @receipt = accessible_receipts.find(params[:id])
  end

  # A receipt may be viewed wherever the admin has a link, but only changed or
  # deleted where they hold receipt access (full_access or upload_receipts) — a
  # read_only link never grants it, whatever the admin holds elsewhere.
  def require_writable_receipt
    return if @receipt.nil?
    deny_write unless writable_receipts.exists?(@receipt.id)
  end
  
  def receipt_params
    params.require(:receipt).permit(
      :title, :receipt_date, :description, :scan, :entity_id, :posting_id
    )
  end

  def receipt_json(receipt)
    {
      id: receipt.id,
      title: receipt.title,
      filename: receipt.display_filename,
      receipt_date: receipt.receipt_date,
      description: receipt.description,
      thumbnail_url: receipt.thumbnail_url,
      preview_url: receipt.preview_url,
      original_url: receipt.original_url,
      is_pdf: receipt.pdf?,
      posting_id: receipt.posting_id,
      entity_id: receipt.entity_id,
      entity_name: receipt.entity&.name,
      linked: receipt.posting_id.present?
    }
  end
  
  # Defined in BaseController — the upload modal is rendered from three other
  # controllers too, which never reach this one.
  def accessible_entities_for_upload
    entities_for_receipt_upload
  end

  def current_entity
    @current_entity ||= params[:entity_id].present? ? accessible_entities.find(params[:entity_id]) : nil
  end

  def refuse_demo_writes
    return unless demo_admin?

    deny_receipt_target
  end

  def require_receipt_access
    # Full access or upload_receipts can upload
    return if current_admin.sudo?
    return if current_admin.admin_entities.with_receipt_access.exists?

    # Through deny_receipt_target rather than a redirect of its own: uploading
    # is driven by fetch, which follows redirects. See
    # BaseController#deny_write.
    deny_receipt_target
  end

  # The entity and the posting arrive as form values, so they are the admin's
  # claim, not a fact. The dropdown is already filtered and #link resolves
  # postings through accessible_postings, so reaching here with a foreign id
  # means the form was edited by hand. Checked with exists?, one COUNT each,
  # nothing loaded.
  def authorize_receipt_target
    attrs = params[:receipt]
    return if attrs.blank?

    entity_id  = attrs[:entity_id].presence
    posting_id = attrs[:posting_id].presence

    return deny_receipt_target if entity_id  && !accessible_entities_for_upload.exists?(entity_id)
    return deny_receipt_target if posting_id && !accessible_postings.exists?(posting_id)
  end

  def deny_receipt_target
    deny_access(t("access.no_receipt_upload"), receipts_path)
  end

end
