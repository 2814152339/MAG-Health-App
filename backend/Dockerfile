FROM python:3.12-slim
ARG INSTALL_MEDIAPIPE=false
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 MPLCONFIGDIR=/tmp/matplotlib
WORKDIR /app
COPY requirements*.txt ./
RUN if [ "$INSTALL_MEDIAPIPE" = "true" ]; then \
      apt-get update && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 libportaudio2 && \
      rm -rf /var/lib/apt/lists/* && \
      pip install --no-cache-dir -r requirements-face.txt; \
    else pip install --no-cache-dir -r requirements.txt; fi
COPY ruyuan ./ruyuan
RUN useradd --uid 10001 --create-home ruyuan && mkdir /data && chown 10001:10001 /data
USER 10001:10001
ENV RUYUAN_DATA_DIR=/data
EXPOSE 8000
CMD ["uvicorn", "ruyuan.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--no-access-log"]
