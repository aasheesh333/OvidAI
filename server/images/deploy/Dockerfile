FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir \
    fastapi==0.115.* \
    "uvicorn[standard]==0.32.*" \
    "pyjwt[crypto]==2.9.*" \
    cryptography==43.* \
    redis==5.* \
    httpx==0.27.* \
    "Pillow>=10.4,<13"
COPY mint.py /app/mint.py
COPY images_gateway.py /app/images_gateway.py
# Vendored Ovid image service (server.images package) — repo source, deploy copy.
COPY server /app/server
RUN mkdir -p /data
EXPOSE 8090
CMD ["uvicorn", "mint:app", "--host", "0.0.0.0", "--port", "8090"]
