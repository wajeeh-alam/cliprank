from app.adapters.baseline import UnsupportedSemanticFeatureExtractor, UnsupportedTranscriber


def transcribe(*_args, **_kwargs):
    return UnsupportedTranscriber().transcribe("", 0)


def extract_features(*_args, **_kwargs):
    return UnsupportedSemanticFeatureExtractor().extract("")
