require "open3"
require "net/http"
require "tmpdir"
require "timeout"
require "zlib"

module Previews
  # Renders the immutable Top-5 ranking snapshot. Each output belongs to its
  # ranking run, so a rerun cannot overwrite an artifact from another run.
  class Renderer
    VERSION = "preview-1".freeze
    MAX_CANDIDATES = 5
    DEFAULT_FFMPEG_TIMEOUT = 180
    DEFAULT_FFPROBE_TIMEOUT = 20
    DEFAULT_MAX_PREVIEW_BYTES = 100 * 1024 * 1024
    DEFAULT_MAX_THUMBNAIL_BYTES = 10 * 1024 * 1024

    class AdvisoryLock
      NAMESPACE = 1_129_335_632

      def self.synchronize(ranking_run_id, connection: nil, &block)
        return synchronize_on(connection, ranking_run_id, &block) if connection

        ActiveRecord::Base.connection_pool.with_connection do |leased_connection|
          synchronize_on(leased_connection, ranking_run_id, &block)
        end
      end

      def self.synchronize_on(connection, ranking_run_id)
        lock_id = Zlib.crc32("preview-ranking-run:#{ranking_run_id}") & 0x7fff_ffff
        acquired = ActiveModel::Type::Boolean.new.cast(
          query_value(connection, "SELECT pg_try_advisory_lock(#{NAMESPACE}, #{lock_id})")
        )
        return false unless acquired

        begin
          yield
        ensure
          execute(connection, "SELECT pg_advisory_unlock(#{NAMESPACE}, #{lock_id})")
        end
      end

      def self.query_value(connection, sql)
        return connection.select_value(sql) if connection.respond_to?(:select_value)

        connection.exec(sql).getvalue(0, 0)
      end

      def self.execute(connection, sql)
        return connection.execute(sql) if connection.respond_to?(:execute)

        connection.exec(sql)
      end
      private_class_method :synchronize_on, :query_value, :execute
    end

    class Error < StandardError
      attr_reader :code, :details, :retryable

      def initialize(message, code:, retryable: false, details: {})
        super(message)
        @code = code
        @retryable = retryable
        @details = details
      end
    end
    class RetryableError < Error
      def initialize(message, code: "PREVIEW_RETRYABLE", details: {})
        super(message, code: code, retryable: true, details: details)
      end
    end
    class PermanentError < Error
      def initialize(message, code: "PREVIEW_ERROR", details: {})
        super(message, code: code, retryable: false, details: details)
      end
    end

    class CommandRunner
      def initialize(ffmpeg_timeout: nil, ffprobe_timeout: nil)
        @ffmpeg_timeout = timeout_value(ffmpeg_timeout, "PREVIEW_FFMPEG_TIMEOUT_SECONDS", DEFAULT_FFMPEG_TIMEOUT)
        @ffprobe_timeout = timeout_value(ffprobe_timeout, "PREVIEW_FFPROBE_TIMEOUT_SECONDS", DEFAULT_FFPROBE_TIMEOUT)
      end

      def probe(path)
        stdout, _stderr, status = run(
          [ "ffprobe", "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", path ], @ffprobe_timeout
        )
        raise PermanentError.new("The source media could not be inspected", code: "SOURCE_MEDIA_INVALID") unless status.success?
        duration = Float(stdout.strip)
        raise PermanentError.new("The source media has no usable duration", code: "SOURCE_DURATION_MISSING") unless duration.positive?
        duration
      rescue ArgumentError
        raise PermanentError.new("The source media has invalid duration metadata", code: "SOURCE_DURATION_INVALID")
      end

      def render_preview(source, destination, start_seconds:, duration_seconds:)
        execute_ffmpeg(
          [ "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-ss", format_seconds(start_seconds), "-i", source,
            "-t", format_seconds(duration_seconds), "-map", "0:v:0?", "-map", "0:a:0?",
            "-c:v", "libx264", "-preset", "veryfast", "-c:a", "aac", "-movflags", "+faststart", destination ]
        )
      end

      def render_thumbnail(source, destination, at_seconds:)
        execute_ffmpeg(
          [ "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-ss", format_seconds(at_seconds), "-i", source, "-frames:v", "1",
            "-vf", "scale=640:-2", destination ]
        )
      end

      private

      def execute_ffmpeg(argv)
        _stdout, _stderr, status = run(argv, @ffmpeg_timeout)
        return if status.success?
        raise PermanentError.new("The candidate preview could not be rendered", code: "PREVIEW_RENDER_FAILED")
      end

      def run(argv, timeout_seconds)
        Open3.popen3(*argv, pgroup: true) do |stdin, stdout_io, stderr_io, wait_thread|
          stdin.close
          stdout_thread = Thread.new { stdout_io.read }
          stderr_thread = Thread.new { stderr_io.read }
          status = nil
          begin
            Timeout.timeout(timeout_seconds) { status = wait_thread.value }
          rescue Timeout::Error
            terminate(wait_thread.pid)
            raise RetryableError.new("Media rendering timed out", code: "MEDIA_RENDER_TIMEOUT")
          ensure
            wait_thread.join(5) unless status
          end
          [ stdout_thread.value.to_s, stderr_thread.value.to_s, status ]
        end
      rescue Errno::ENOENT
        raise PermanentError.new("FFmpeg is unavailable", code: "FFMPEG_UNAVAILABLE")
      rescue Errno::EAGAIN, Errno::ENOMEM => error
        raise RetryableError.new("Media rendering resources are temporarily unavailable", code: "MEDIA_RENDER_RETRYABLE", details: { "class" => error.class.name })
      end

      def terminate(pid)
        Process.kill("TERM", -pid)
        sleep(0.1)
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end

      def timeout_value(value, env_key, default)
        number = Float(value || ENV.fetch(env_key, default.to_s))
        raise ArgumentError if number <= 0
        number
      rescue ArgumentError, TypeError
        default
      end

      def format_seconds(value)
        format("%.3f", value.to_f)
      end
    end

    def self.call(ranking_run, runner: nil)
      new(ranking_run, runner: runner).call
    end

    def self.top_scores(ranking_run)
      new(ranking_run).send(:top_scores)
    end

    def initialize(ranking_run, runner: nil)
      @ranking_run = ranking_run
      @video = ranking_run.video
      @runner = runner || CommandRunner.new
    end

    def call
      result = AdvisoryLock.synchronize(@ranking_run.id) { render_locked }
      result == false ? :already_running : result
    end

    private

    def render_locked
      validate_ownership!
      scores = top_scores
      raise PermanentError.new("A successful ranking must contain scores", code: "RANKING_EMPTY") if scores.empty?
      open_source do |source|
        source_duration = @runner.probe(source)
        scores.each { |score| render_score(score, source_duration, source) }
      end
      advance_barrier!(scores)
    end

    def top_scores
      all_scores = @ranking_run.candidate_scores.includes(:candidate_clip).order(:rank, :id).to_a
      raise PermanentError.new("Ranking contains a cross-video candidate", code: "RANKING_OWNERSHIP_ERROR") if all_scores.any? { |score| score.candidate_clip.video_id != @video.id }
      all_scores.select { |score| score.rank.to_i.between?(1, MAX_CANDIDATES) }.first(MAX_CANDIDATES)
    end

    def validate_ownership!
      unless @ranking_run.status == "succeeded" && @ranking_run.processing_run&.video_id == @video.id
        raise PermanentError.new("Preview ranking ownership is invalid", code: "RANKING_OWNERSHIP_ERROR")
      end
      ensure_run_active!
      raise PermanentError.new("The source media is missing", code: "SOURCE_MEDIA_MISSING") unless @video.source_media.attached?
    end

    def render_score(score, source_duration, source)
      candidate = score.candidate_clip
      validate_boundaries!(candidate, source_duration)
      artifacts = PreviewArtifact::KINDS.index_with do |kind|
        @ranking_run.preview_artifacts.find_or_create_by!(candidate_clip: candidate, kind: kind, render_version: VERSION) do |artifact|
          artifact.assign_attributes(start_ms: candidate.start_ms, end_ms: candidate.end_ms, duration_ms: candidate.duration_ms)
        end
      end
      unless artifacts.values.all? { |artifact| artifact.start_ms == candidate.start_ms && artifact.end_ms == candidate.end_ms && artifact.duration_ms == candidate.duration_ms }
        raise PermanentError.new("Preview boundaries changed for a ranked candidate", code: "PREVIEW_BOUNDARIES_CHANGED")
      end
      return if artifacts.values.all? { |artifact| artifact.ready? && artifact.file.attached? }

      Dir.mktmpdir("cliprank-preview-") do |directory|
        File.chmod(0o700, directory)
        preview_path = File.join(directory, "preview.mp4")
        thumbnail_path = File.join(directory, "thumbnail.jpg")
        render_artifact(artifacts.fetch("preview"), preview_path) do
          @runner.render_preview(source, preview_path, start_seconds: candidate.start_ms / 1000.0, duration_seconds: candidate.duration_ms / 1000.0)
        end
        render_artifact(artifacts.fetch("thumbnail"), thumbnail_path) do
          @runner.render_thumbnail(source, thumbnail_path, at_seconds: candidate.start_ms / 1000.0)
        end
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    rescue PermanentError => error
      mark_failed(artifacts, error) unless error.code == "PREVIEW_RUN_INACTIVE"
      raise
    end

    def render_artifact(artifact, destination)
      return if artifact.ready? && artifact.file.attached?
      artifact.with_lock { artifact.update!(status: "rendering", error_code: nil, error_message: nil) }
      yield
      ensure_run_active!
      max_bytes = artifact.preview? ? max_size("PREVIEW_MAX_BYTES", DEFAULT_MAX_PREVIEW_BYTES) : max_size("THUMBNAIL_MAX_BYTES", DEFAULT_MAX_THUMBNAIL_BYTES)
      unless File.file?(destination) && File.size?(destination)
        raise PermanentError.new("FFmpeg did not produce a #{artifact.kind}", code: "PREVIEW_OUTPUT_MISSING")
      end
      raise PermanentError.new("The #{artifact.kind} is too large", code: "PREVIEW_OUTPUT_TOO_LARGE") if File.size(destination) > max_bytes
      File.open(destination, "rb") do |io|
        artifact.file.attach(io: io, filename: artifact.preview? ? "clip-#{artifact.candidate_clip_id}-#{VERSION}.mp4" : "clip-#{artifact.candidate_clip_id}-#{VERSION}.jpg", content_type: artifact.preview? ? "video/mp4" : "image/jpeg")
      end
      artifact.with_lock { artifact.update!(status: "ready", error_code: nil, error_message: nil) }
    rescue RetryableError
      raise
    rescue PermanentError => error
      unless error.code == "PREVIEW_RUN_INACTIVE"
        artifact.with_lock { artifact.update!(status: "failed", error_code: error.code, error_message: safe_message(error.message)) }
      end
      raise
    end

    def validate_boundaries!(candidate, source_duration)
      if candidate.start_ms.to_i.negative? || candidate.end_ms.to_i <= candidate.start_ms.to_i || candidate.end_ms.to_i > (@video.duration_ms || (source_duration * 1000).floor) || candidate.end_ms.to_f / 1000.0 > source_duration + 0.001
        raise PermanentError.new("Candidate timestamps exceed source media", code: "INVALID_PREVIEW_BOUNDARIES")
      end
    end

    def open_source
      @video.source_media.blob.open { |file| yield file.path }
    rescue ActiveStorage::FileNotFoundError
      raise PermanentError.new("The source media is unavailable", code: "SOURCE_MEDIA_UNAVAILABLE")
    rescue IOError, SocketError, Net::OpenTimeout, Net::ReadTimeout => error
      raise RetryableError.new("The source media could not be downloaded", code: "SOURCE_MEDIA_RETRYABLE", details: { "class" => error.class.name })
    end

    def mark_failed(artifacts, error)
      PreviewArtifact.transaction do
        message = safe_message(error.message)
        artifacts&.each_value { |artifact| artifact.with_lock { artifact.update!(status: "failed", error_code: error.code, error_message: message) unless artifact.ready? } }
      end
    end

    def ensure_run_active!
      run = @ranking_run.processing_run.reload
      return if run.running? && run.current_stage == "generating_previews"

      raise PermanentError.new("The preview run is no longer active", code: "PREVIEW_RUN_INACTIVE")
    end

    def advance_barrier!(scores)
      ProcessingRun.transaction do
        run = @ranking_run.processing_run.lock!
        video = Video.lock.find(@video.id)
        return if run.failed? || run.succeeded?
        scores = @ranking_run.candidate_scores.where(rank: 1..MAX_CANDIDATES).includes(:candidate_clip).to_a
        return if scores.empty? || scores.any? { |score| score.candidate_clip.video_id != video.id }
        if scores.any? { |score| score.candidate_clip.preview_artifacts.where(ranking_run_id: @ranking_run.id, render_version: VERSION, status: "failed").exists? }
          fail_run!(run, video, "PREVIEW_RENDER_FAILED", "A selected Top-5 preview failed")
        elsif scores.all? { |score| score.candidate_clip.preview_artifacts.where(ranking_run_id: @ranking_run.id, render_version: VERSION, status: "ready").count == 2 }
          run.update!(status: "succeeded", current_stage: "complete", completed_at: Time.current, error_code: nil, error_message: nil, error_details: {})
          video.update!(status: "complete", completed_at: Time.current, processing_error_code: nil, processing_error_message: nil, processing_error_details: {})
        end
      end
    end

    def fail_run!(run, video, code, message)
      details = run.error_details.is_a?(Hash) ? run.error_details.deep_dup : {}
      details["preview_error"] = { "code" => code, "message" => message }
      run.update!(status: "failed", current_stage: "generating_previews", error_code: code, error_message: message, error_details: details, completed_at: Time.current)
      video.update!(status: "failed", processing_error_code: code, processing_error_message: message, processing_error_details: details)
    end

    def max_size(key, default)
      value = Integer(ENV.fetch(key, default.to_s))
      value.positive? ? value : default
    rescue ArgumentError
      default
    end

    def safe_message(value)
      message = value.to_s.gsub(%r{/(?:[^\s/]+/)+[^\s]*}, "[redacted-path]")
      message = "Preview rendering failed." if message.empty?
      message[0, 500]
    end
  end
end
