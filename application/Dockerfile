# Dockerfile for Crate FastAPI Application

FROM python:3.12-slim

# Create a non-root user that matches the pod securityContext (UID 1000)
RUN groupadd --gid 1000 crate && \
    useradd --uid 1000 --gid crate --no-create-home crate

WORKDIR /app

COPY --chown=crate:crate requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

COPY --chown=crate:crate . /app

USER crate

EXPOSE 5000

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "5000"]
