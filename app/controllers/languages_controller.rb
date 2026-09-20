# frozen_string_literal: true

class LanguagesController < ApplicationController
  require_full_access
  require_otp
  require_terms
  before_action :require_sudo_only
  before_action :set_language, only: [ :edit, :update, :destroy, :release, :unrelease ]
  before_action :set_title
  layout "accounting"

  def index
    # System rows first (source: system = 0 sorts before custom = 1),
    # alphabetical by code within each group.
    @languages = Language.order(:source, :code)
  end

  def new
    @language = Language.new_with_english_prefill
  end

  def create
    @language = Language.new(language_params)

    if @language.save
      redirect_to languages_path, notice: t("languages.created", code: @language.code)
    else
      render :new, status: :unprocessable_entity
    end
  end

  # Fills blanks only: a field that already holds something, however incomplete,
  # is left exactly as it is. Never called from #update, whose failure path must
  # show what was actually submitted.
  def edit
    @language.fill_blank_fields_with_english!
  end

  def update
    if @language.update(language_params)
      redirect_to languages_path, notice: t("languages.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @language.destroy
    redirect_to languages_path, notice: t("languages.deleted")
  end

  # Named, not a plain attribute on update: this is the one action that makes a
  # language publicly visible, so it has to be deliberate rather than a side
  # effect of whatever else was on the form.
  def release
    @language.release!(by: current_admin)
    redirect_to languages_path, notice: t("languages.released", code: @language.code)
  end

  def unrelease
    @language.unrelease!
    redirect_to languages_path, notice: t("languages.unreleased", code: @language.code)
  end

  private

  def set_title
    @title = "Languages"
  end

  def set_language
    @language = Language.find(params[:id])
  end

  def language_params
    params.require(:language).permit(
      :code, :label, :rtl, :reviewed,
      :yml_content, :easy_manual_textile, :pro_manual_textile,
      :legal_textile, :terms_textile
    )
  end
end
