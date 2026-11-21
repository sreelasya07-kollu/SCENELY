# Build context is capturekit/ (see docker-compose.yml): the verifier runs the same semantic
# validator as `ckit validate --level semantic` (tools/ckit + spec/scanbundle), so it must ship them.
# Layout mirrors the repo because ckit.core finds spec/ as parents[2] of ckit/core.py.
FROM python:3.12-slim
# Pins from tools/uv.lock (ckit needs only jsonschema, mcap, protobuf for validation).
RUN pip install --no-cache-dir boto3==1.40.0 jsonschema==4.26.0 mcap==1.6.0 protobuf==3.20.3
ENV PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python \
    PYTHONPATH=/ck/tools
WORKDIR /app
COPY dev-server/verifier/bundle_verify.py dev-server/verifier/server.py ./
COPY tools/ckit /ck/tools/ckit
COPY spec/scanbundle /ck/spec/scanbundle
EXPOSE 8081
CMD ["python", "server.py"]
