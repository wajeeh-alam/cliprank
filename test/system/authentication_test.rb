require "application_system_test_case"

class AuthenticationTest < ApplicationSystemTestCase
  test "visitor can open the login page" do
    visit login_path

    assert_selector "h1", text: "Welcome back"
    assert_field "Email"
    assert_field "Password"
  end
end
