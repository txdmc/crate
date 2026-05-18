# Dockerfile for Pelico FastAPI Application

FROM python:3.12-slim

# Create a non-root user that matches the pod securityContext (UID 1000)
RUN groupadd --gid 1000 pelico && \
    useradd --uid 1000 --gid pelico --no-create-home pelico

WORKDIR /app

COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

COPY . /app

USER pelico

EXPOSE 5000

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "5000"]
