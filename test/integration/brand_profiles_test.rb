require "test_helper"

class BrandProfilesTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "brand-#{SecureRandom.hex(3)}@example.com", password: "password-123")
  end

  test "requires authentication" do
    get brand_profile_path

    assert_redirected_to login_path
  end

  test "shows setup state before the user has a brand profile" do
    login_as(@user)

    get brand_profile_path

    assert_response :success
    assert_select "h1", "Your brand"
    assert_select "a", text: "Set up brand"
  end

  test "creates the current user's profile and turns line-separated fields into arrays" do
    login_as(@user)

    assert_difference "BrandProfile.count", 1 do
      patch brand_profile_path, params: { brand_profile: valid_attributes.merge(
        content_pillars: "Education\nBehind the scenes\n",
        preferred_terms: "practical\nuseful",
        avoided_terms: "viral hack\n\n",
        example_posts: "First example\nSecond example"
      ) }
    end

    assert_redirected_to brand_profile_path
    profile = @user.reload.brand_profile
    assert_equal [ "Education", "Behind the scenes" ], profile.content_pillars
    assert_equal [ "practical", "useful" ], profile.preferred_terms
    assert_equal [ "viral hack" ], profile.avoided_terms
    assert_equal [ "First example", "Second example" ], profile.example_posts
  end

  test "updates and displays the current user's profile" do
    profile = @user.create_brand_profile!(valid_attributes.merge(
      content_pillars: [ "Video strategy" ], preferred_terms: [ "useful" ],
      avoided_terms: [ "viral hack" ], example_posts: [ "Make the first sentence earn attention." ]
    ))
    login_as(@user)

    patch brand_profile_path, params: { brand_profile: valid_attributes.merge(brand_name: "Updated Brand") }
    assert_redirected_to brand_profile_path
    assert_equal "Updated Brand", profile.reload.brand_name

    follow_redirect!
    assert_select "h2", "Updated Brand"
    assert_select "li", "Video strategy"
  end

  test "renders validation errors without creating a profile" do
    login_as(@user)

    assert_no_difference "BrandProfile.count" do
      patch brand_profile_path, params: { brand_profile: valid_attributes.merge(brand_name: "") }
    end

    assert_response :unprocessable_entity
    assert_select "div[role=alert]", text: /Brand name can't be blank/
  end

  private

  def valid_attributes
    {
      brand_name: "ClipRank",
      description: "A social video publishing assistant.",
      audience: "Independent creators",
      voice: "Clear, warm, and practical",
      content_pillars: "Video strategy",
      preferred_terms: "useful",
      avoided_terms: "viral hack",
      default_cta: "Follow for practical creator tips.",
      example_posts: "Make the first sentence earn attention."
    }
  end

  def login_as(user)
    post login_path, params: { session: { email: user.email, password: "password-123" } }
    assert_redirected_to videos_path
  end
end
