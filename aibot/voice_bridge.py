#!/usr/bin/env python3
"""
Realtime voice bridge: FreeSWITCH (mod_audio_stream) <-> Doubao end-to-end dialogue.

mod_audio_stream connects to this WebSocket server and:
  - sends the caller's audio as binary L16 16k mono frames  -> we forward to Doubao
  - plays back any {"type":"streamAudio",...} JSON we send   <- Doubao's reply audio

Doubao 端到端实时语音 does ASR+LLM+TTS internally; we just shuttle PCM both ways.
No transcode (AMR-WB is 16k = Doubao's rate). Greeting via SayHello; barge-in via
clearing playback when the user interrupts.
"""
import asyncio, struct, uuid, os, json, base64, traceback
from datetime import datetime
import websockets
import volcengine_audio as v
from volcengine_audio import RealtimeDialogueFunctions as F, EventReceive

APPID = os.environ["VOLC_APPID"]
TOKEN = os.environ["VOLC_ACCESS_TOKEN"]
DIALOG_URL = "wss://openspeech.bytedance.com/api/v3/realtime/dialogue"
BIND_HOST, BIND_PORT = "0.0.0.0", 8090
EVN = {int(e): e.name for e in EventReceive if isinstance(e.value, int)}

PERSONA = {"bot_name": "小豆",
           "system_role": "你是一个友好的中文电话语音助手，名叫小豆。回答口语化、简短，适合电话里听。"}
SPEAKER = "zh_female_vv_jupiter_bigtts"

def log(*a):
    print(f"[bridge {datetime.now().strftime('%H:%M:%S.%f')[:-3]}]", *a, flush=True)

def dialog_headers():
    return {"X-Api-App-ID": APPID, "X-Api-Access-Key": TOKEN,
            "X-Api-Resource-Id": "volc.speech.dialog",
            "X-Api-App-Key": "PlgvMymc7f3tQnJ6", "X-Api-Connect-Id": str(uuid.uuid4())}

def parse(b):
    # Bounds-safe: some control frames (TTSEnded/SessionFinished) omit the id or
    # payload section. Never raise — a single odd frame must not kill the call.
    if len(b) < 2:
        return 0, None, b""
    mt = b[1] >> 4; fl = b[1] & 0x0F; off = 4; ev = None
    if fl & 0x04:
        if len(b) < off + 4:
            return mt, None, b""
        ev = struct.unpack(">i", b[off:off + 4])[0]; off += 4
    if len(b) < off + 4:                                   # no id section
        return mt, ev, b""
    l1 = struct.unpack(">I", b[off:off + 4])[0]; off += 4; off += l1
    if len(b) < off + 4:                                   # no payload section
        return mt, ev, b""
    l2 = struct.unpack(">I", b[off:off + 4])[0]; off += 4; pl = b[off:off + l2]
    return mt, ev, pl

def stream_audio_msg(pcm):
    return json.dumps({"type": "streamAudio",
                       "data": {"audioDataType": "raw", "sampleRate": 16000,
                                "audioData": base64.b64encode(pcm).decode()}})

async def handle_fs(fsws):
    cid = uuid.uuid4().hex[:8]
    log(f"[{cid}] FreeSWITCH connected")
    sid = str(uuid.uuid4())
    cfg = v.RealtimeDialogueConfig(
        dialog=PERSONA,
        tts={"speaker": SPEAKER, "audio_config": {"channel": 1, "format": "pcm", "sample_rate": 16000}},
        asr={"audio_info": {"format": "pcm", "sample_rate": 16000, "channel": 1},
             "extra": {"end_smooth_window_ms": 700}})
    try:
        async with websockets.connect(DIALOG_URL, additional_headers=dialog_headers(), max_size=None) as dws:
            await dws.send(F.start_connection_payload()); parse(await dws.recv())
            await dws.send(F.start_session_payload(sid, cfg)); parse(await dws.recv())
            log(f"[{cid}] Doubao session started")
            # greet first
            try:
                await dws.send(F.say_hello_payload(sid, v.SayHelloRequest(content="你好，我是 AI 助手小豆，有什么可以帮你？")))
            except Exception as e:
                log(f"[{cid}] say_hello skipped: {e}")

            async def fs_to_doubao():
                buf = bytearray()
                async for msg in fsws:
                    if isinstance(msg, (bytes, bytearray)):
                        buf += msg
                        if len(buf) >= 3200:                # ~100ms @16k
                            await dws.send(F.task_request_payload(sid, bytes(buf))); buf = bytearray()
                    # text frames from mod_audio_stream (metadata/keepalive) ignored

            async def doubao_to_fs():
                while True:
                    raw = await dws.recv()
                    if not isinstance(raw, (bytes, bytearray)):
                        continue
                    try:
                        mt, ev, pl = parse(raw)
                    except Exception as e:
                        log(f"[{cid}] skip bad frame: {e}"); continue
                    nm = EVN.get(ev, ev)
                    if mt == 11 and pl:                     # reply audio -> play to caller
                        await fsws.send(stream_audio_msg(pl))
                    elif pl[:1] == b"{":
                        try: j = json.loads(pl)
                        except Exception: j = {}
                        if nm == "ASRResponse":
                            t = (j.get("results") or [{}])[0].get("text", "")
                            if t: log(f"[{cid}] user: {t}")
                            # barge-in: user spoke -> stop current playback
                            try: await fsws.send(json.dumps({"type": "playbackStop"}))
                            except Exception: pass
                        elif nm == "ChatResponse" and j.get("content"):
                            log(f"[{cid}] bot+= {j['content']}")
                        elif nm in ("SessionFailed",):
                            log(f"[{cid}] Doubao {nm}: {j}")

            await asyncio.gather(fs_to_doubao(), doubao_to_fs())
    except websockets.ConnectionClosed:
        log(f"[{cid}] FreeSWITCH closed")
    except Exception:
        log(f"[{cid}] error:\n" + traceback.format_exc())

async def main():
    log(f"listening on ws://{BIND_HOST}:{BIND_PORT}")
    async with websockets.serve(handle_fs, BIND_HOST, BIND_PORT, max_size=None):
        await asyncio.Future()

if __name__ == "__main__":
    asyncio.run(main())
