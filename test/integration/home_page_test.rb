require "test_helper"

class HomePageTest < ActionDispatch::IntegrationTest
  test "shows a public project overview without exposing private workspace links" do
    get root_path

    assert_response :success
    assert_select "h1", text: /Find the strongest moments/
    assert_select "a[href=?]", login_path
    assert_select "a[href=?]", videos_path, count: 0
    assert_select "a[href=?]", new_video_path, count: 0
    assert_select "video", count: 0
  end
end
