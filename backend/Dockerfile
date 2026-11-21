FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash noteit

WORKDIR /app

COPY requirements.txt .
RUN pip install --upgrade pip && pip install -r requirements.txt

COPY docker-entrypoint.sh /usr/local/bin/noteit-start.sh
RUN chmod +x /usr/local/bin/noteit-start.sh

COPY app ./app

RUN mkdir -p /data && chown -R noteit:noteit /app /data

EXPOSE 8080

CMD ["/usr/local/bin/noteit-start.sh"]
