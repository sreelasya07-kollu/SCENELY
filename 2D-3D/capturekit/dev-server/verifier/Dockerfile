FROM python:3.12-slim
RUN pip install --no-cache-dir boto3==1.40.0
WORKDIR /app
COPY bundle_verify.py server.py ./
EXPOSE 8081
CMD ["python", "server.py"]
