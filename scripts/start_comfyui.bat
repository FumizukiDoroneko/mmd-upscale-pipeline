@echo off
REM ---------------------------------------------------------------
REM  ComfyUI portable launcher (RTX 5070 / 12GB)
REM
REM  PYTHONUTF8=1 is REQUIRED on this machine: the system locale is
REM  Chinese (GBK console), and nodes that log emoji (e.g. SeedVR2's
REM  compatibility check) crash ComfyUI at startup with
REM  UnicodeEncodeError if Python writes to the console as GBK.
REM ---------------------------------------------------------------
set PYTHONUTF8=1
set PYTHONIOENCODING=utf-8
REM Unbuffered stdout, so progress bars (SeedVR2 sampling, etc.) stream to the
REM console instead of appearing only when a buffer fills.
set PYTHONUNBUFFERED=1
REM HuggingFace direct is unreachable from this network (0 MB/s); the mirror is
REM fast. huggingface_hub honours HF_ENDPOINT, so node packs (SeederVR2,
REM FlashVSR) that auto-download weights will pull through the mirror.
set HF_ENDPOINT=https://hf-mirror.com

cd /d "D:\ComfyUI"

"D:\ComfyUI\python_embeded\python.exe" -s "ComfyUI\main.py" ^
  --windows-standalone-build ^
  --port 8188 ^
  --listen 127.0.0.1 ^
  %*

pause
