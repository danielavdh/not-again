# frozen_string_literal: true

# Uploading installation-level documents — sudo only. See Document.
class DocumentsController < ApplicationController
  require_sudo
  require_otp
  require_terms

  def create
    document = Document.find_or_initialize_by(kind: params[:kind])
    document.uploaded_by = current_admin

    if document.update(doc: params[:doc])
      redirect_to legal_path, notice: t(".success")
    else
      redirect_to legal_path, alert: document.errors.full_messages.to_sentence
    end
  end
end
