require "test_helper"

class BrandProfileTest < ActiveSupport::TestCase
  test "stores structured brand memory for one user" do
    user = build_user.tap(&:save!)
    profile = user.create_brand_profile!(
      brand_name: "ClipRank",
      description: "Tools for turning recordings into useful social clips.",
      audience: "Independent creators",
      voice: "Clear, warm, and practical",
      content_pillars: [ "Video strategy", "Creator workflows" ],
      preferred_terms: [ "useful" ],
      avoided_terms: [ "viral hack" ],
      default_cta: "Follow for practical creator tips.",
      example_posts: [ "Make the first sentence earn attention." ]
    )

    assert_equal [ "Video strategy", "Creator workflows" ], profile.reload.content_pillars
    assert_equal profile, user.reload.brand_profile
  end

  test "requires core brand context" do
    profile = BrandProfile.new(user: build_user)

    assert_not profile.valid?
    assert_includes profile.errors[:brand_name], "can't be blank"
    assert_includes profile.errors[:description], "can't be blank"
    assert_includes profile.errors[:audience], "can't be blank"
    assert_includes profile.errors[:voice], "can't be blank"
  end

  test "requires list fields to be arrays of nonblank strings" do
    profile = BrandProfile.new(
      user: build_user, brand_name: "Brand", description: "Description", audience: "Audience", voice: "Voice",
      content_pillars: "not an array", preferred_terms: [ "" ], avoided_terms: [], example_posts: [ 1 ]
    )

    assert_not profile.valid?
    assert_includes profile.errors[:content_pillars], "must be a JSON array"
    assert_includes profile.errors[:preferred_terms], "must contain only nonblank text values"
    assert_includes profile.errors[:example_posts], "must contain only nonblank text values"
  end

  test "allows only one profile per user" do
    user = build_user.tap(&:save!)
    attributes = { brand_name: "Brand", description: "Description", audience: "Audience", voice: "Voice" }
    user.create_brand_profile!(attributes)
    duplicate = BrandProfile.new(attributes.merge(user: user))

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:user_id], "has already been taken"
  end
end
