require "test_helper"

class InstagramAccountTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "instagram-#{SecureRandom.hex(3)}@example.com", password: "password-123")
  end

  test "encrypts access tokens and excludes credentials from serialized output" do
    token = "ig-secret-token-#{SecureRandom.hex(8)}"
    account = @user.instagram_accounts.create!(
      instagram_user_id: "17841400000000000", username: "creator", account_type: "CREATOR",
      access_token: token
    )

    assert_equal token, account.access_token
    assert_not_equal token, account.access_token_ciphertext
    assert_not_includes account.as_json.keys.map(&:to_s), "access_token"
    assert_not_includes account.as_json.keys.map(&:to_s), "access_token_ciphertext"
    assert_not_includes account.inspect, token
  end

  test "accepts only Professional account types" do
    account = @user.instagram_accounts.new(
      instagram_user_id: "17841400000000001", username: "personal", account_type: "PERSONAL",
      access_token: "token"
    )

    assert_not account.valid?
    assert_includes account.errors[:account_type], "is not included in the list"
  end
end
