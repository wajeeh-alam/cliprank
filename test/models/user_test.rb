require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "normalizes email and owns videos and exports" do
    user = User.create!(email: " Creator@Example.COM ", name: "Creator")

    assert_equal "creator@example.com", user.email
    assert_respond_to user, :videos
    assert_respond_to user, :exports
  end

  test "requires a unique nonblank email" do
    User.create!(email: "creator@example.com")

    duplicate = User.new(email: " creator@example.com ")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:email], "has already been taken"
  end
end
