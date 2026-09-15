Rails.application.config.session_store :cookie_store,
  key: "_clip_rank_session",
  httponly: true,
  same_site: :lax,
  secure: Rails.env.production?
