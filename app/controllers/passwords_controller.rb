class PasswordsController < ApplicationController
  allow_unauthenticated_access
  before_action :set_resource_by_token, only: %i[ edit update ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_password_path(locale: I18n.locale), alert: t("passwords.try_again") }
  before_action :set_title
  layout "accounting"

  def new
  end

  def create
    email = params[:email_address].to_s.strip.downcase
    # Always the same answer, found or not — otherwise this page reports which
    # addresses have an account.
    if admin = Admin.find_by(email_address: email)
      AdminMailer.with(admin: admin, locale: I18n.locale).password_reset.deliver_later
    end
    redirect_to new_session_path(locale: I18n.locale),
                notice: t("passwords.sent", type: t("auth.role.admin"))
  end

  def edit
  end

  def update
    if @resource.update(params.permit(:password, :password_confirmation))
      @resource.sessions.destroy_all
      redirect_to new_session_path(locale: I18n.locale), notice: t("passwords.updated")
    else
      redirect_to edit_password_path(params[:token], locale: I18n.locale),
                  alert: @resource.errors.full_messages.to_sentence
    end
  end

  private
  
    def set_resource_by_token
      @resource = Admin.find_by_token_for(:password_reset, params[:token])
      return if @resource

      redirect_to new_password_path(locale: I18n.locale), alert: t("passwords.invalid")
    end

    def set_title
      @title = I18n.t("passwords.forgotten")
    end

end
