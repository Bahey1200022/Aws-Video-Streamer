FROM python:3.12-slim

# ffmpeg/ffprobe: validate imported videos and push them to nginx-rtmp
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Unprivileged runtime user (matches the owner of /var/lib/studio on the host)
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin studio

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY templates templates
COPY static static

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    STUDIO_DATA=/data

USER 10001

# One worker so the in-memory ffmpeg process table is shared; threads for concurrency
CMD ["gunicorn", "--bind", "127.0.0.1:5000", "--workers", "1", "--threads", "4", \
     "--timeout", "120", "app:app"]
