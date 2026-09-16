from typing import Annotated, Literal

from pydantic import AnyHttpUrl, BaseModel, BeforeValidator, ConfigDict, Field, model_validator

from app.domain.enums import ContentType, HookType
from app.domain.ranking import DEFAULT_WEIGHTS


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


ContractVersion = Literal["1.0"]
ProcessingMode = Literal["audit", "repurpose"]
NonEmpty = Annotated[str, Field(min_length=1)]
Millis = Annotated[int, Field(ge=0)]
UnitFloat = Annotated[float, Field(ge=0.0, le=1.0)]
ContentTypeValue = Annotated[ContentType, BeforeValidator(lambda value: ContentType(value) if isinstance(value, str) else value)]
HookTypeValue = Annotated[HookType, BeforeValidator(lambda value: HookType(value) if isinstance(value, str) else value)]


class MediaRef(StrictModel):
    signed_url: AnyHttpUrl
    mime_type: NonEmpty


class Word(StrictModel):
    start_ms: Millis
    end_ms: Annotated[int, Field(gt=0)]
    text: NonEmpty

    @model_validator(mode="after")
    def ordered(self):
        if self.end_ms <= self.start_ms:
            raise ValueError("end_ms must be greater than start_ms")
        return self


class TranscriptSegment(StrictModel):
    sequence: Annotated[int, Field(ge=0)]
    start_ms: Millis
    end_ms: Annotated[int, Field(gt=0)]
    text: NonEmpty
    words: list[Word] = Field(default_factory=list)
    is_sentence_boundary_start: bool = False
    is_sentence_boundary_end: bool = False

    @model_validator(mode="after")
    def ordered(self):
        if self.end_ms <= self.start_ms:
            raise ValueError("end_ms must be greater than start_ms")
        for word in self.words:
            if word.start_ms < self.start_ms or word.end_ms > self.end_ms:
                raise ValueError("word bounds must be within segment bounds")
        return self


class TranscriptionRequest(StrictModel):
    contract_version: ContractVersion
    video_id: NonEmpty
    media: MediaRef
    duration_ms: Millis
    transcript_version: NonEmpty
    language: str | None = None


class TranscriptionResponse(StrictModel):
    """Validated API data returned by the transcription use case."""

    video_id: NonEmpty
    transcript_version: NonEmpty
    language: str | None = None
    segments: list[TranscriptSegment]

    @model_validator(mode="after")
    def ordered_segments(self):
        previous_end = 0
        for expected_sequence, segment in enumerate(self.segments):
            if segment.sequence != expected_sequence:
                raise ValueError("transcript segment sequence must be contiguous")
            if segment.start_ms < previous_end:
                raise ValueError("transcript segments must not overlap")
            previous_end = segment.end_ms
        return self


class CandidateGenerationRequest(StrictModel):
    contract_version: ContractVersion
    video_id: NonEmpty
    duration_ms: Millis
    generation_version: NonEmpty
    processing_mode: ProcessingMode = "repurpose"
    min_duration_ms: Annotated[int, Field(gt=0)] = 15_000
    max_duration_ms: Annotated[int, Field(gt=0)] = 60_000
    target_count_min: Annotated[int, Field(ge=1)] = 10
    target_count_max: Annotated[int, Field(ge=1)] = 40
    segments: list[TranscriptSegment] = Field(min_length=1)

    @model_validator(mode="after")
    def valid_policy(self):
        if self.max_duration_ms < self.min_duration_ms:
            raise ValueError("max_duration_ms must be >= min_duration_ms")
        if self.target_count_max < self.target_count_min:
            raise ValueError("target_count_max must be >= target_count_min")
        minimum = 3_000 if self.processing_mode == "audit" else 15_000
        if self.min_duration_ms < minimum:
            raise ValueError(f"{self.processing_mode} candidates must be at least {minimum // 1000} seconds")
        return self


class Candidate(StrictModel):
    sequence: Annotated[int, Field(ge=0)]
    start_ms: Millis
    end_ms: Annotated[int, Field(gt=0)]
    duration_ms: Annotated[int, Field(gt=0)]
    transcript: NonEmpty
    source_segment_sequences: list[Annotated[int, Field(ge=0)]]

    @model_validator(mode="after")
    def valid_bounds(self):
        if self.end_ms <= self.start_ms or self.duration_ms != self.end_ms - self.start_ms:
            raise ValueError("candidate timestamps or duration are inconsistent")
        if not self.source_segment_sequences:
            raise ValueError("candidate must reference source segments")
        return self


class SemanticFeatures(StrictModel):
    hook_strength: UnitFloat
    standalone_clarity: UnitFloat
    information_density: UnitFloat
    novelty: UnitFloat
    emotional_intensity: UnitFloat
    quotability: UnitFloat
    payoff_strength: UnitFloat
    story_completeness: UnitFloat
    technical_depth: UnitFloat
    call_to_action_presence: UnitFloat
    topic: NonEmpty
    content_type: ContentTypeValue
    hook_type: HookTypeValue


class AudioFeatures(StrictModel):
    words_per_minute: Annotated[float, Field(ge=0)]
    average_audio_energy: UnitFloat
    energy_variance: UnitFloat
    energy_change_at_hook: UnitFloat
    silence_ratio: UnitFloat
    longest_pause_ms: Millis
    pause_frequency: UnitFloat


class VisualFeatures(StrictModel):
    face_presence_ratio: UnitFloat
    visual_motion: UnitFloat
    scene_change_rate: UnitFloat
    screen_recording_ratio: UnitFloat
    camera_change_frequency: UnitFloat
    sample_count: Annotated[int, Field(ge=0)]


class StructuralFeatures(StrictModel):
    time_to_main_point_ms: Millis
    intro_length_ms: Millis
    sentence_completeness: UnitFloat
    hook_to_payoff_time_ms: Millis
    dead_air_start_ms: Millis
    dead_air_end_ms: Millis


class FeatureRequest(StrictModel):
    contract_version: ContractVersion
    video_id: NonEmpty
    candidate_id: NonEmpty
    feature_version: NonEmpty
    media: MediaRef
    start_ms: Millis
    end_ms: Annotated[int, Field(gt=0)]
    transcript: NonEmpty
    transcript_segments: list[TranscriptSegment] = Field(min_length=1)

    @model_validator(mode="after")
    def valid_bounds(self):
        if self.end_ms <= self.start_ms:
            raise ValueError("end_ms must be greater than start_ms")
        previous_end = self.start_ms
        for segment in sorted(self.transcript_segments, key=lambda item: item.start_ms):
            if segment.start_ms < self.start_ms or segment.end_ms > self.end_ms:
                raise ValueError("transcript segment bounds must be within candidate bounds")
            if segment.start_ms < previous_end:
                raise ValueError("transcript segments must not overlap")
            previous_end = segment.end_ms
        return self


class FeatureSet(StrictModel):
    video_id: NonEmpty
    candidate_id: NonEmpty
    feature_version: NonEmpty
    model_version: NonEmpty
    prompt_version: str | None = None
    semantic: SemanticFeatures
    audio: AudioFeatures
    visual: VisualFeatures
    structural: StructuralFeatures
    capability_warnings: list[NonEmpty] = Field(default_factory=list)


class RankConfig(StrictModel):
    weights: dict[Literal["semantic", "hook", "structural", "delivery", "visual"], Annotated[float, Field(ge=0.0, le=1.0)]]
    output_scale: Literal[100] = 100

    @model_validator(mode="after")
    def complete_weights(self):
        expected = {"semantic", "hook", "structural", "delivery", "visual"}
        if set(self.weights) != expected:
            raise ValueError("weights must define exactly semantic, hook, structural, delivery, and visual")
        if abs(sum(self.weights.values()) - 1.0) > 1e-9:
            raise ValueError("weights must sum to 1")
        if any(abs(self.weights[key] - DEFAULT_WEIGHTS[key]) > 1e-9 for key in expected):
            raise ValueError("weights must match the documented heuristic configuration")
        return self


class RankCandidate(StrictModel):
    """A candidate plus its validated feature set.

    The versioned ``FeatureSet`` contract intentionally carries IDs/version but
    not source boundaries, so this boundary cannot be cross-checked here. The
    feature extraction stage validates its own candidate interval before this
    request is constructed.
    """

    candidate_id: NonEmpty
    start_ms: Millis
    end_ms: Annotated[int, Field(gt=0)]
    features: FeatureSet

    @model_validator(mode="after")
    def valid_bounds(self):
        if self.end_ms <= self.start_ms:
            raise ValueError("end_ms must be greater than start_ms")
        if self.features.candidate_id != self.candidate_id:
            raise ValueError("candidate feature id must match candidate id")
        return self


class RankComponentDetail(StrictModel):
    weight: UnitFloat
    normalized: UnitFloat


class RankRequest(StrictModel):
    contract_version: ContractVersion
    video_id: NonEmpty
    feature_version: NonEmpty
    scorer_version: Literal["heuristic-1"]
    config: RankConfig
    candidates: list[RankCandidate] = Field(min_length=1, max_length=40)

    @model_validator(mode="after")
    def matching_feature_versions(self):
        mismatched = [c.candidate_id for c in self.candidates if c.features.feature_version != self.feature_version]
        if mismatched:
            raise ValueError("candidate feature_version must match request feature_version")
        wrong_videos = [c.candidate_id for c in self.candidates if c.features.video_id != self.video_id]
        if wrong_videos:
            raise ValueError("candidate feature video_id must match request video_id")
        candidate_ids = [candidate.candidate_id for candidate in self.candidates]
        if len(candidate_ids) != len(set(candidate_ids)):
            raise ValueError("candidate ids must be unique within a ranking request")
        return self


class RankedCandidate(StrictModel):
    candidate_id: NonEmpty
    rank: Annotated[int, Field(ge=1)]
    clip_score: Annotated[float, Field(ge=0.0, le=100.0)]
    components: dict[Literal["content_quality", "hook", "delivery", "pacing", "visual_engagement", "standalone_clarity"], Annotated[float, Field(ge=0.0, le=100.0)]]
    component_details: dict[Literal["semantic", "hook", "structural", "delivery", "visual"], RankComponentDetail]

    @model_validator(mode="after")
    def complete_components(self):
        expected = {"content_quality", "hook", "delivery", "pacing", "visual_engagement", "standalone_clarity"}
        if set(self.components) != expected:
            raise ValueError("ranked candidate must include exactly the documented score components")
        if set(self.component_details) != {"semantic", "hook", "structural", "delivery", "visual"}:
            raise ValueError("ranked candidate must include exactly the documented component details")
        return self


class Envelope(StrictModel):
    contract_version: ContractVersion
    request_id: NonEmpty
    idempotency_key: NonEmpty
    data: object
    warnings: list[NonEmpty] = Field(default_factory=list)


class ErrorDetail(StrictModel):
    code: NonEmpty
    message: NonEmpty
    retryable: bool
    details: dict[str, object] = Field(default_factory=dict)


class ErrorEnvelope(StrictModel):
    contract_version: ContractVersion = "1.0"
    request_id: NonEmpty
    error: ErrorDetail
