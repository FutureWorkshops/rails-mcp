module RailsMcp
  class OnboardingController < ApplicationController
    before_action :require_sign_in
    before_action :skip_if_already_onboarded, only: :new

    def new
      @account = current_user.account
      @default_name = suggested_name
    end

    def create
      account = current_user.account
      name = params[:name].to_s.strip.presence || suggested_name

      if account.update(name: name)
        account.mark_onboarded!
        redirect_to "/connections", notice: "Welcome! You're all set."
      else
        flash.now[:alert] = account.errors.full_messages.to_sentence
        @account = account
        @default_name = suggested_name
        render :new, status: :unprocessable_entity
      end
    end

    private

    def suggested_name
      RailsMcp.config.suggested_account_name.call(current_user) ||
        current_user.account.name
    end

    def skip_if_already_onboarded
      redirect_to "/connections" if current_user.account.onboarded?
    end
  end
end
