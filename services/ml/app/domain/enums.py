from enum import StrEnum


class ContentType(StrEnum):
    STORY = "story"
    TUTORIAL = "tutorial"
    OPINION = "opinion"
    PROJECT_DEMO = "project_demo"
    CAREER_ADVICE = "career_advice"
    CODING_TIP = "coding_tip"
    EDUCATIONAL = "educational"
    ANNOUNCEMENT = "announcement"
    OTHER = "other"


class HookType(StrEnum):
    QUESTION = "question"
    CONTRARIAN = "contrarian"
    SURPRISING_CLAIM = "surprising_claim"
    PERSONAL_STORY = "personal_story"
    RESULT_FIRST = "result_first"
    PROBLEM = "problem"
    CURIOSITY_GAP = "curiosity_gap"
    NONE = "none"
