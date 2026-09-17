require "test_helper"

class LinkedinAccountTest < ActiveSupport::TestCase
  test "encrypts access tokens and excludes ciphertext from serialization" do
    user = User.create!(email: "linkedin-model-#{SecureRandom.hex(3)}@example.com", password: "password-123")
    account = user.linkedin_accounts.create!(
      linkedin_member_id: "member-1", display_name: "Ada Lovelace", access_token: "private-token"
    )

    assert_equal "private-token", account.access_token
    assert_not_equal "private-token", account.access_token_ciphertext
    assert_not_includes account.serializable_hash.keys, "access_token_ciphertext"
  end
end
