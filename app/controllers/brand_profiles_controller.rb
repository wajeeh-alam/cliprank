class BrandProfilesController < ApplicationController
  before_action :require_authentication
  before_action :set_brand_profile

  def show
  end

  def edit
  end

  def update
    if @brand_profile.update(brand_profile_params)
      redirect_to brand_profile_path, notice: "Brand profile saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_brand_profile
    @brand_profile = current_user.brand_profile || current_user.build_brand_profile
  end

  def brand_profile_params
    permitted = params.require(:brand_profile).permit(:brand_name, :description, :audience, :voice, :default_cta,
      :content_pillars, :preferred_terms, :avoided_terms, :example_posts)

    BrandProfile::LIST_ATTRIBUTES.each do |attribute|
      next unless permitted.key?(attribute)

      permitted[attribute] = permitted[attribute].to_s.lines.map(&:strip).reject(&:blank?)
    end

    permitted
  end
end
