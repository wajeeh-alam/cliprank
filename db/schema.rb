# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_17_121000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "brand_profiles", force: :cascade do |t|
    t.text "audience", null: false
    t.jsonb "avoided_terms", default: [], null: false
    t.string "brand_name", null: false
    t.jsonb "content_pillars", default: [], null: false
    t.datetime "created_at", null: false
    t.text "default_cta", default: "", null: false
    t.text "description", null: false
    t.jsonb "example_posts", default: [], null: false
    t.jsonb "preferred_terms", default: [], null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.text "voice", null: false
    t.index ["user_id"], name: "index_brand_profiles_on_user_id", unique: true
    t.check_constraint "jsonb_typeof(avoided_terms) = 'array'::text", name: "brand_profiles_avoided_terms_array"
    t.check_constraint "jsonb_typeof(content_pillars) = 'array'::text", name: "brand_profiles_content_pillars_array"
    t.check_constraint "jsonb_typeof(example_posts) = 'array'::text", name: "brand_profiles_example_posts_array"
    t.check_constraint "jsonb_typeof(preferred_terms) = 'array'::text", name: "brand_profiles_preferred_terms_array"
  end

  create_table "candidate_clips", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "duration_ms", null: false
    t.bigint "end_ms", null: false
    t.string "generation_version", null: false
    t.string "processing_error_code"
    t.text "processing_error_message"
    t.bigint "recommended_end_ms"
    t.bigint "recommended_start_ms"
    t.integer "sequence", null: false
    t.bigint "start_ms", null: false
    t.string "status", default: "pending", null: false
    t.text "transcript", null: false
    t.text "trim_reason"
    t.datetime "updated_at", null: false
    t.bigint "video_id", null: false
    t.index ["video_id", "end_ms"], name: "index_candidate_clips_on_video_id_and_end_ms"
    t.index ["video_id", "generation_version", "start_ms", "end_ms"], name: "index_candidate_clips_on_generation_boundaries", unique: true
    t.index ["video_id", "sequence"], name: "index_candidate_clips_on_video_id_and_sequence"
    t.index ["video_id", "start_ms"], name: "index_candidate_clips_on_video_id_and_start_ms"
    t.index ["video_id", "status"], name: "index_candidate_clips_on_video_id_and_status"
    t.index ["video_id"], name: "index_candidate_clips_on_video_id"
    t.check_constraint "duration_ms = (end_ms - start_ms) AND duration_ms >= 3000 AND duration_ms <= 60000", name: "candidate_clips_duration_range"
    t.check_constraint "recommended_start_ms IS NULL AND recommended_end_ms IS NULL OR recommended_start_ms >= 0 AND recommended_start_ms < recommended_end_ms", name: "candidate_clips_recommended_range"
    t.check_constraint "sequence >= 0", name: "candidate_clips_sequence_non_negative"
    t.check_constraint "start_ms >= 0 AND start_ms < end_ms", name: "candidate_clips_timestamp_range"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'analyzing'::character varying::text, 'ranked'::character varying::text, 'rendering'::character varying::text, 'ready'::character varying::text, 'failed'::character varying::text, 'rejected'::character varying::text])", name: "candidate_clips_status_valid"
  end

  create_table "candidate_feature_sets", force: :cascade do |t|
    t.jsonb "audio_features", default: {}, null: false
    t.bigint "candidate_clip_id", null: false
    t.datetime "created_at", null: false
    t.string "feature_version", null: false
    t.string "model_version"
    t.string "prompt_version"
    t.jsonb "raw_metadata", default: {}, null: false
    t.jsonb "semantic_features", default: {}, null: false
    t.jsonb "structural_features", default: {}, null: false
    t.datetime "updated_at", null: false
    t.jsonb "visual_features", default: {}, null: false
    t.index ["candidate_clip_id", "feature_version"], name: "index_candidate_feature_sets_on_candidate_and_version", unique: true
    t.index ["candidate_clip_id"], name: "index_candidate_feature_sets_on_candidate_clip_id"
    t.index ["feature_version", "created_at"], name: "index_candidate_feature_sets_on_feature_version_and_created_at"
    t.check_constraint "jsonb_typeof(semantic_features) = 'object'::text AND jsonb_typeof(audio_features) = 'object'::text AND jsonb_typeof(visual_features) = 'object'::text AND jsonb_typeof(structural_features) = 'object'::text AND jsonb_typeof(raw_metadata) = 'object'::text", name: "candidate_feature_sets_payloads_objects"
  end

  create_table "candidate_scores", force: :cascade do |t|
    t.bigint "candidate_clip_id", null: false
    t.decimal "clip_score", precision: 5, scale: 2, null: false
    t.jsonb "component_details", default: {}, null: false
    t.decimal "content_quality", precision: 5, scale: 2, null: false
    t.datetime "created_at", null: false
    t.decimal "delivery", precision: 5, scale: 2, null: false
    t.decimal "hook", precision: 5, scale: 2, null: false
    t.decimal "pacing", precision: 5, scale: 2, null: false
    t.integer "rank", null: false
    t.bigint "ranking_run_id", null: false
    t.decimal "standalone_clarity", precision: 5, scale: 2, null: false
    t.datetime "updated_at", null: false
    t.decimal "visual_engagement", precision: 5, scale: 2, null: false
    t.index ["candidate_clip_id", "created_at"], name: "index_candidate_scores_on_candidate_clip_id_and_created_at", order: { created_at: :desc }
    t.index ["candidate_clip_id"], name: "index_candidate_scores_on_candidate_clip_id"
    t.index ["ranking_run_id", "candidate_clip_id"], name: "index_candidate_scores_on_run_and_candidate", unique: true
    t.index ["ranking_run_id", "rank"], name: "index_candidate_scores_on_run_and_rank", unique: true
    t.index ["ranking_run_id"], name: "index_candidate_scores_on_ranking_run_id"
    t.check_constraint "clip_score >= 0::numeric AND clip_score <= 100::numeric", name: "candidate_scores_clip_score_range"
    t.check_constraint "content_quality >= 0::numeric AND content_quality <= 100::numeric", name: "candidate_scores_content_quality_range"
    t.check_constraint "delivery >= 0::numeric AND delivery <= 100::numeric", name: "candidate_scores_delivery_range"
    t.check_constraint "hook >= 0::numeric AND hook <= 100::numeric", name: "candidate_scores_hook_range"
    t.check_constraint "jsonb_typeof(component_details) = 'object'::text", name: "candidate_scores_component_details_object"
    t.check_constraint "pacing >= 0::numeric AND pacing <= 100::numeric", name: "candidate_scores_pacing_range"
    t.check_constraint "rank >= 1", name: "candidate_scores_rank_positive"
    t.check_constraint "standalone_clarity >= 0::numeric AND standalone_clarity <= 100::numeric", name: "candidate_scores_standalone_clarity_range"
    t.check_constraint "visual_engagement >= 0::numeric AND visual_engagement <= 100::numeric", name: "candidate_scores_visual_engagement_range"
  end

  create_table "draft_variants", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "cta"
    t.text "description", null: false
    t.jsonb "evidence", default: {}, null: false
    t.jsonb "hashtags", default: [], null: false
    t.string "platform", null: false
    t.bigint "publishing_draft_id", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["publishing_draft_id", "platform"], name: "index_draft_variants_on_publishing_draft_id_and_platform", unique: true
    t.index ["publishing_draft_id"], name: "index_draft_variants_on_publishing_draft_id"
    t.check_constraint "jsonb_typeof(evidence) = 'object'::text", name: "draft_variants_evidence_object"
    t.check_constraint "jsonb_typeof(hashtags) = 'array'::text", name: "draft_variants_hashtags_array"
    t.check_constraint "platform::text = ANY (ARRAY['instagram'::character varying, 'linkedin'::character varying]::text[])", name: "draft_variants_platform_valid"
  end

  create_table "explanations", force: :cascade do |t|
    t.bigint "candidate_score_id", null: false
    t.datetime "created_at", null: false
    t.string "explanation_version", null: false
    t.string "model_version"
    t.string "prompt_version"
    t.jsonb "quantitative_facts", default: [], null: false
    t.jsonb "strengths", default: [], null: false
    t.text "summary", null: false
    t.datetime "updated_at", null: false
    t.jsonb "weaknesses", default: [], null: false
    t.index ["candidate_score_id", "explanation_version"], name: "index_explanations_on_score_and_version", unique: true
    t.index ["candidate_score_id"], name: "index_explanations_on_candidate_score_id"
    t.check_constraint "jsonb_typeof(strengths) = 'array'::text AND jsonb_typeof(weaknesses) = 'array'::text AND jsonb_typeof(quantitative_facts) = 'array'::text", name: "explanations_bullet_payloads_arrays"
  end

  create_table "exports", force: :cascade do |t|
    t.bigint "candidate_clip_id", null: false
    t.datetime "created_at", null: false
    t.bigint "end_ms", null: false
    t.string "error_code"
    t.text "error_message"
    t.string "export_version", null: false
    t.bigint "start_ms", null: false
    t.string "status", default: "requested", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["candidate_clip_id", "created_at"], name: "index_exports_on_candidate_clip_id_and_created_at", order: { created_at: :desc }
    t.index ["candidate_clip_id"], name: "index_exports_on_candidate_clip_id"
    t.index ["user_id", "created_at"], name: "index_exports_on_user_id_and_created_at", order: { created_at: :desc }
    t.index ["user_id"], name: "index_exports_on_user_id"
    t.check_constraint "start_ms >= 0 AND start_ms < end_ms", name: "exports_timestamp_range"
    t.check_constraint "status::text = ANY (ARRAY['requested'::character varying::text, 'rendering'::character varying::text, 'ready'::character varying::text, 'failed'::character varying::text])", name: "exports_status_valid"
  end

  create_table "instagram_accounts", force: :cascade do |t|
    t.text "access_token_ciphertext", null: false
    t.string "account_type", null: false
    t.datetime "created_at", null: false
    t.string "instagram_user_id", null: false
    t.datetime "last_synced_at"
    t.string "sync_error"
    t.datetime "token_expires_at"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "username", null: false
    t.index ["instagram_user_id"], name: "index_instagram_accounts_on_instagram_user_id", unique: true
    t.index ["user_id", "instagram_user_id"], name: "index_instagram_accounts_on_user_and_instagram_user", unique: true
    t.index ["user_id"], name: "index_instagram_accounts_on_user_id"
    t.check_constraint "account_type::text = ANY (ARRAY['BUSINESS'::character varying::text, 'CREATOR'::character varying::text])", name: "instagram_accounts_account_type_valid"
  end

  create_table "instagram_insight_snapshots", force: :cascade do |t|
    t.datetime "captured_at", null: false
    t.date "captured_on", null: false
    t.datetime "created_at", null: false
    t.bigint "instagram_account_id", null: false
    t.bigint "instagram_media_id", null: false
    t.jsonb "metrics", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["instagram_account_id", "captured_on"], name: "index_instagram_insights_on_account_and_captured_on"
    t.index ["instagram_account_id"], name: "index_instagram_insight_snapshots_on_instagram_account_id"
    t.index ["instagram_media_id", "captured_on"], name: "index_instagram_insights_on_media_and_captured_on", unique: true
    t.index ["instagram_media_id"], name: "index_instagram_insight_snapshots_on_instagram_media_id"
    t.check_constraint "jsonb_typeof(metrics) = 'object'::text", name: "instagram_insight_snapshots_metrics_object"
  end

  create_table "instagram_media", force: :cascade do |t|
    t.text "caption"
    t.integer "comments_count"
    t.datetime "created_at", null: false
    t.bigint "instagram_account_id", null: false
    t.string "instagram_media_id", null: false
    t.integer "like_count"
    t.string "media_product_type"
    t.string "media_type", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "permalink"
    t.datetime "published_at"
    t.datetime "updated_at", null: false
    t.index ["instagram_account_id", "instagram_media_id"], name: "index_instagram_media_on_account_and_instagram_media", unique: true
    t.index ["instagram_account_id"], name: "index_instagram_media_on_instagram_account_id"
    t.check_constraint "jsonb_typeof(metadata) = 'object'::text", name: "instagram_media_metadata_object"
  end

  create_table "linkedin_accounts", force: :cascade do |t|
    t.text "access_token_ciphertext", null: false
    t.datetime "created_at", null: false
    t.string "display_name", null: false
    t.datetime "last_synced_at"
    t.string "linkedin_member_id", null: false
    t.string "sync_error"
    t.datetime "token_expires_at"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["linkedin_member_id"], name: "index_linkedin_accounts_on_linkedin_member_id", unique: true
    t.index ["user_id", "linkedin_member_id"], name: "index_linkedin_accounts_on_user_and_member", unique: true
    t.index ["user_id"], name: "index_linkedin_accounts_on_user_id"
  end

  create_table "linkedin_insight_snapshots", force: :cascade do |t|
    t.datetime "captured_at", null: false
    t.date "captured_on", null: false
    t.datetime "created_at", null: false
    t.bigint "linkedin_account_id", null: false
    t.bigint "linkedin_post_id", null: false
    t.jsonb "metrics", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["linkedin_account_id", "captured_on"], name: "index_linkedin_insights_on_account_and_captured_on"
    t.index ["linkedin_account_id"], name: "index_linkedin_insight_snapshots_on_linkedin_account_id"
    t.index ["linkedin_post_id", "captured_on"], name: "index_linkedin_insights_on_post_and_captured_on", unique: true
    t.index ["linkedin_post_id"], name: "index_linkedin_insight_snapshots_on_linkedin_post_id"
    t.check_constraint "jsonb_typeof(metrics) = 'object'::text", name: "linkedin_insight_snapshots_metrics_object"
  end

  create_table "linkedin_posts", force: :cascade do |t|
    t.text "commentary"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.bigint "linkedin_account_id", null: false
    t.string "linkedin_post_urn", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "permalink"
    t.datetime "published_at"
    t.datetime "updated_at", null: false
    t.index ["linkedin_account_id", "linkedin_post_urn"], name: "index_linkedin_posts_on_account_and_urn", unique: true
    t.index ["linkedin_account_id"], name: "index_linkedin_posts_on_linkedin_account_id"
    t.check_constraint "jsonb_typeof(metadata) = 'object'::text", name: "linkedin_posts_metadata_object"
  end

  create_table "preview_artifacts", force: :cascade do |t|
    t.bigint "candidate_clip_id", null: false
    t.datetime "created_at", null: false
    t.bigint "duration_ms", null: false
    t.bigint "end_ms", null: false
    t.string "error_code"
    t.text "error_message"
    t.string "kind", null: false
    t.bigint "ranking_run_id", null: false
    t.string "render_version", null: false
    t.bigint "start_ms", null: false
    t.string "status", default: "requested", null: false
    t.datetime "updated_at", null: false
    t.index ["candidate_clip_id"], name: "index_preview_artifacts_on_candidate_clip_id"
    t.index ["ranking_run_id", "candidate_clip_id", "kind", "render_version"], name: "index_preview_artifacts_on_run_candidate_kind_version", unique: true
    t.index ["ranking_run_id", "status"], name: "index_preview_artifacts_on_ranking_run_id_and_status"
    t.index ["ranking_run_id"], name: "index_preview_artifacts_on_ranking_run_id"
    t.check_constraint "kind::text = ANY (ARRAY['preview'::character varying::text, 'thumbnail'::character varying::text])", name: "preview_artifacts_kind_valid"
    t.check_constraint "start_ms >= 0 AND start_ms < end_ms AND duration_ms = (end_ms - start_ms)", name: "preview_artifacts_timestamp_range"
    t.check_constraint "status::text = ANY (ARRAY['requested'::character varying::text, 'rendering'::character varying::text, 'ready'::character varying::text, 'failed'::character varying::text])", name: "preview_artifacts_status_valid"
  end

  create_table "processing_runs", force: :cascade do |t|
    t.integer "attempt_count", default: 0, null: false
    t.string "candidate_generation_version"
    t.string "candidate_processing_mode"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "current_stage"
    t.string "error_code"
    t.jsonb "error_details", default: {}, null: false
    t.text "error_message"
    t.string "idempotency_key", null: false
    t.string "pipeline_version", null: false
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "video_id", null: false
    t.index ["idempotency_key"], name: "index_processing_runs_on_idempotency_key", unique: true
    t.index ["video_id", "pipeline_version", "status"], name: "idx_on_video_id_pipeline_version_status_27b3ba7c54"
    t.index ["video_id"], name: "index_processing_runs_on_video_id"
    t.check_constraint "attempt_count >= 0", name: "processing_runs_attempt_count_non_negative"
    t.check_constraint "candidate_processing_mode IS NULL OR (candidate_processing_mode::text = ANY (ARRAY['audit'::character varying::text, 'repurpose'::character varying::text]))", name: "processing_runs_candidate_mode_valid"
    t.check_constraint "jsonb_typeof(error_details) = 'object'::text", name: "processing_runs_error_details_object"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'running'::character varying::text, 'succeeded'::character varying::text, 'failed'::character varying::text])", name: "processing_runs_status_valid"
  end

  create_table "publishing_drafts", force: :cascade do |t|
    t.datetime "approved_at"
    t.string "approved_payload_digest"
    t.bigint "candidate_clip_id", null: false
    t.datetime "created_at", null: false
    t.text "error_message"
    t.datetime "generated_at"
    t.string "generator_version"
    t.datetime "published_at"
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "video_id", null: false
    t.index ["candidate_clip_id", "created_at"], name: "index_publishing_drafts_on_candidate_clip_id_and_created_at", order: { created_at: :desc }
    t.index ["candidate_clip_id"], name: "index_publishing_drafts_on_candidate_clip_id"
    t.index ["user_id", "created_at"], name: "index_publishing_drafts_on_user_id_and_created_at", order: { created_at: :desc }
    t.index ["user_id", "status"], name: "index_publishing_drafts_on_user_id_and_status"
    t.index ["user_id"], name: "index_publishing_drafts_on_user_id"
    t.index ["video_id"], name: "index_publishing_drafts_on_video_id"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying, 'ready_for_review'::character varying, 'approved'::character varying, 'publishing'::character varying, 'published'::character varying, 'failed'::character varying]::text[])", name: "publishing_drafts_status_valid"
  end

  create_table "ranking_runs", force: :cascade do |t|
    t.datetime "completed_at"
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "error_code"
    t.text "error_message"
    t.string "feature_version", null: false
    t.bigint "processing_run_id", null: false
    t.string "scorer_version", null: false
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.string "title_ideas_error"
    t.string "title_ideas_status", default: "pending", null: false
    t.string "title_ideas_version"
    t.datetime "updated_at", null: false
    t.bigint "video_id", null: false
    t.index ["processing_run_id", "feature_version", "scorer_version"], name: "index_ranking_runs_on_processing_and_versions", unique: true
    t.index ["processing_run_id"], name: "index_ranking_runs_on_processing_run_id"
    t.index ["video_id", "created_at"], name: "index_ranking_runs_on_video_id_and_created_at", order: { created_at: :desc }
    t.index ["video_id"], name: "index_ranking_runs_on_video_id"
    t.check_constraint "jsonb_typeof(config) = 'object'::text", name: "ranking_runs_config_object"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'running'::character varying::text, 'succeeded'::character varying::text, 'failed'::character varying::text])", name: "ranking_runs_status_valid"
    t.check_constraint "title_ideas_status::text = ANY (ARRAY['pending'::character varying::text, 'generating'::character varying::text, 'succeeded'::character varying::text, 'failed'::character varying::text])", name: "ranking_runs_title_ideas_status_valid"
  end

  create_table "title_idea_sets", force: :cascade do |t|
    t.bigint "candidate_clip_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "evidence", default: {}, null: false
    t.bigint "ranking_run_id", null: false
    t.integer "sample_size", default: 0, null: false
    t.string "source_type", null: false
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.index ["candidate_clip_id"], name: "index_title_idea_sets_on_candidate_clip_id"
    t.index ["ranking_run_id", "candidate_clip_id", "version"], name: "index_title_idea_sets_on_run_candidate_version", unique: true
    t.index ["ranking_run_id"], name: "index_title_idea_sets_on_ranking_run_id"
    t.check_constraint "jsonb_typeof(evidence) = 'object'::text", name: "title_idea_sets_evidence_object"
    t.check_constraint "sample_size >= 0", name: "title_idea_sets_sample_size_non_negative"
    t.check_constraint "source_type::text = ANY (ARRAY['transcript'::character varying::text, 'instagram_history'::character varying::text])", name: "title_idea_sets_source_type_valid"
  end

  create_table "title_ideas", force: :cascade do |t|
    t.string "angle", null: false
    t.datetime "created_at", null: false
    t.jsonb "evidence", default: {}, null: false
    t.integer "rank", null: false
    t.string "title", null: false
    t.bigint "title_idea_set_id", null: false
    t.datetime "updated_at", null: false
    t.index ["title_idea_set_id", "rank"], name: "index_title_ideas_on_set_and_rank", unique: true
    t.index ["title_idea_set_id"], name: "index_title_ideas_on_title_idea_set_id"
    t.check_constraint "char_length(title::text) >= 1", name: "title_ideas_title_non_empty"
    t.check_constraint "jsonb_typeof(evidence) = 'object'::text", name: "title_ideas_evidence_object"
    t.check_constraint "rank >= 1", name: "title_ideas_rank_positive"
  end

  create_table "transcript_segments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "end_ms", null: false
    t.boolean "is_sentence_boundary_end", default: false, null: false
    t.boolean "is_sentence_boundary_start", default: false, null: false
    t.integer "sequence", null: false
    t.bigint "start_ms", null: false
    t.text "text", null: false
    t.string "transcript_version", null: false
    t.datetime "updated_at", null: false
    t.bigint "video_id", null: false
    t.jsonb "words", default: [], null: false
    t.index ["video_id", "end_ms"], name: "index_transcript_segments_on_video_id_and_end_ms"
    t.index ["video_id", "start_ms"], name: "index_transcript_segments_on_video_id_and_start_ms"
    t.index ["video_id", "transcript_version", "sequence"], name: "index_transcript_segments_on_video_version_sequence", unique: true
    t.index ["video_id"], name: "index_transcript_segments_on_video_id"
    t.check_constraint "jsonb_typeof(words) = 'array'::text", name: "transcript_segments_words_array"
    t.check_constraint "sequence >= 0", name: "transcript_segments_sequence_non_negative"
    t.check_constraint "start_ms >= 0 AND start_ms < end_ms", name: "transcript_segments_timestamp_range"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name"
    t.string "password_digest"
    t.datetime "updated_at", null: false
    t.index "lower((email)::text)", name: "index_users_on_lower_email", unique: true
    t.check_constraint "char_length(btrim(email::text)) > 0", name: "users_email_not_blank"
  end

  create_table "videos", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.bigint "duration_ms"
    t.string "pipeline_version", default: "phase1", null: false
    t.string "processing_error_code"
    t.jsonb "processing_error_details", default: {}, null: false
    t.text "processing_error_message"
    t.string "source_media_checksum"
    t.string "status", default: "uploading", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["source_media_checksum"], name: "index_videos_on_source_media_checksum"
    t.index ["user_id", "created_at"], name: "index_videos_on_user_id_and_created_at", order: { created_at: :desc }
    t.index ["user_id", "status"], name: "index_videos_on_user_id_and_status"
    t.index ["user_id"], name: "index_videos_on_user_id"
    t.check_constraint "duration_ms IS NULL OR duration_ms >= 0", name: "videos_duration_non_negative"
    t.check_constraint "jsonb_typeof(processing_error_details) = 'object'::text", name: "videos_error_details_object"
    t.check_constraint "status::text = ANY (ARRAY['uploading'::character varying::text, 'extracting_audio'::character varying::text, 'transcribing'::character varying::text, 'generating_candidates'::character varying::text, 'extracting_features'::character varying::text, 'ranking'::character varying::text, 'generating_previews'::character varying::text, 'complete'::character varying::text, 'failed'::character varying::text])", name: "videos_status_valid"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "brand_profiles", "users", on_delete: :cascade
  add_foreign_key "candidate_clips", "videos", on_delete: :restrict
  add_foreign_key "candidate_feature_sets", "candidate_clips", on_delete: :restrict
  add_foreign_key "candidate_scores", "candidate_clips", on_delete: :restrict
  add_foreign_key "candidate_scores", "ranking_runs", on_delete: :restrict
  add_foreign_key "draft_variants", "publishing_drafts", on_delete: :cascade
  add_foreign_key "explanations", "candidate_scores", on_delete: :restrict
  add_foreign_key "exports", "candidate_clips", on_delete: :restrict
  add_foreign_key "exports", "users", on_delete: :restrict
  add_foreign_key "instagram_accounts", "users", on_delete: :restrict
  add_foreign_key "instagram_insight_snapshots", "instagram_accounts", on_delete: :cascade
  add_foreign_key "instagram_insight_snapshots", "instagram_media", column: "instagram_media_id", on_delete: :cascade
  add_foreign_key "instagram_media", "instagram_accounts", on_delete: :cascade
  add_foreign_key "linkedin_accounts", "users", on_delete: :restrict
  add_foreign_key "linkedin_insight_snapshots", "linkedin_accounts", on_delete: :cascade
  add_foreign_key "linkedin_insight_snapshots", "linkedin_posts", on_delete: :cascade
  add_foreign_key "linkedin_posts", "linkedin_accounts", on_delete: :cascade
  add_foreign_key "preview_artifacts", "candidate_clips", on_delete: :restrict
  add_foreign_key "preview_artifacts", "ranking_runs", on_delete: :restrict
  add_foreign_key "processing_runs", "videos", on_delete: :restrict
  add_foreign_key "publishing_drafts", "candidate_clips", on_delete: :restrict
  add_foreign_key "publishing_drafts", "users", on_delete: :restrict
  add_foreign_key "publishing_drafts", "videos", on_delete: :restrict
  add_foreign_key "ranking_runs", "processing_runs", on_delete: :restrict
  add_foreign_key "ranking_runs", "videos", on_delete: :restrict
  add_foreign_key "title_idea_sets", "candidate_clips", on_delete: :cascade
  add_foreign_key "title_idea_sets", "ranking_runs", on_delete: :cascade
  add_foreign_key "title_ideas", "title_idea_sets", on_delete: :cascade
  add_foreign_key "transcript_segments", "videos", on_delete: :restrict
  add_foreign_key "videos", "users", on_delete: :restrict
end
