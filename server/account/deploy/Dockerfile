# Build from an allowlisted context as documented in DEPLOYMENT.md.
FROM python:3.12.11-slim-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY server/account/requirements.txt server/account/requirements.txt
COPY server/images/requirements.txt server/images/requirements.txt
COPY server/shares/requirements.txt server/shares/requirements.txt
RUN pip install --no-cache-dir -r server/account/requirements.txt \
    && groupadd --gid 10001 ovid-account \
    && useradd --uid 10001 --gid 10001 --no-create-home ovid-account
COPY server/account/*.py /app/server/account/
COPY server/images/*.py /app/server/images/
COPY server/shares/*.py /app/server/shares/
COPY server/sync/*.py /app/server/sync/
COPY server/collaboration/*.py /app/server/collaboration/
USER 10001:10001
EXPOSE 8080
CMD ["python", "-m", "uvicorn", "server.account.runtime:create_app", "--factory", "--host", "0.0.0.0", "--port", "8080", "--no-access-log", "--no-proxy-headers"]
