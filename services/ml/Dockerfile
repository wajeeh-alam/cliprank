FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Keep the model lazy: the image contains the provider, while model weights are
# loaded on first transcription using the configured model name/cache.
ENV HF_HOME=/var/cache/huggingface \
    TRANSFORMERS_CACHE=/var/cache/huggingface
RUN mkdir -p /var/cache/huggingface

WORKDIR /app
COPY pyproject.toml ./
COPY app ./app
RUN pip install --no-cache-dir .

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
