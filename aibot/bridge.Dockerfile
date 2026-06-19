FROM python:3.12-slim
RUN pip install --no-cache-dir websockets volcengine-audio
COPY voice_bridge.py /app/voice_bridge.py
WORKDIR /app
CMD ["python3", "voice_bridge.py"]
