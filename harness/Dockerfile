# The hosted harness: standard library only, so the image is the base image.
#
#   docker build -t nanda-harness harness/ && docker run -e NANDA_HARNESS_TOKEN=… -p 8790:8790 nanda-harness
#
# On Railway the same image is built from harness/ (`railway up`), PORT comes
# from the platform, and GEMINI_API_KEY / NANDA_HARNESS_TOKEN are service
# variables — never baked in, never in the repo.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    TMPDIR=/tmp \
    NANDA_HARNESS_HOST=0.0.0.0 \
    NANDA_HARNESS_ENV=/dev/null

WORKDIR /app
COPY nanda_harness /app/nanda_harness
COPY pyproject.toml README.md /app/

RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin harness \
    && mkdir -p /tmp/nanda-harness && chown harness /tmp/nanda-harness
USER harness

EXPOSE 8790
# the healthcheck the platform probes needs no token
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s \
    CMD python -c "import os,urllib.request;urllib.request.urlopen('http://127.0.0.1:'+os.environ.get('PORT','8790')+'/healthz',timeout=4)"
CMD ["python", "-m", "nanda_harness"]
