"""Optional RWF809 diagnostic-only subprocess profiler; no product patches."""
from __future__ import annotations
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

_OUT = os.environ.get("RWF809_TRACE_DIRECTORY", "")
_ROOT = os.path.normcase(os.path.abspath(os.environ.get("RWF809_SOURCE_ROOT", ".")))
_BASE = subprocess.Popen
_LOCK = threading.Lock()

def _origin():
  frame = sys._getframe(2)
  stack = []
  while frame is not None:
    file = os.path.normcase(os.path.abspath(frame.f_code.co_filename))
    if file.startswith(_ROOT + os.sep) and not file.endswith("sitecustomize.py"):
      stack.append(f"{file[len(_ROOT)+1:]}:{frame.f_lineno}:{frame.f_code.co_name}")
    frame = frame.f_back
  return stack[:8]

def _command(args):
  if isinstance(args, (tuple, list)):
    parts = [os.fsdecode(v) if isinstance(v, bytes) else str(v) for v in args]
  else:
    parts = [os.fsdecode(args) if isinstance(args, bytes) else str(args)]
  executable = os.path.basename(parts[0].replace("\\", "/")).lower() if parts else ""
  if executable in {"git", "git.exe"}:
    verb = ""
    skip = False
    for token in parts[1:]:
      if skip:
        skip = False
        continue
      if token in ("-C", "-c", "--git-dir", "--work-tree"):
        skip = True
        continue
      if token.startswith("-"):
        continue
      verb = token
      break
    return "git", verb
  if executable.startswith(("python", "py.exe")):
    return "python", parts[1] if len(parts)>1 else ""
  return executable[:80], parts[1][:80] if len(parts)>1 else ""

class ProfiledPopen(_BASE):
  def __init__(self, *args, **kwargs):
    command = args[0] if args else kwargs.get("args", [])
    self._rwf_kind, self._rwf_verb = _command(command)
    self._rwf_origin = _origin()
    self._rwf_started_ns = time.perf_counter_ns()
    self._rwf_logged = False
    super().__init__(*args, **kwargs)

  def _rwf_finish(self):
    if self._rwf_logged or self.returncode is None:
      return
    self._rwf_logged = True
    event = {
      "schema": 1, "parent_pid": os.getpid(), "child_pid": self.pid,
      "group": os.environ.get("RWF809_GROUP", ""),
      "kind": self._rwf_kind, "verb": self._rwf_verb,
      "returncode": self.returncode,
      "elapsed_ms": (time.perf_counter_ns()-self._rwf_started_ns)/1e6,
      "callsite": self._rwf_origin[0] if self._rwf_origin else "outside-source",
      "stack": self._rwf_origin,
    }
    path = os.path.join(_OUT, f"proc-{os.getpid()}.jsonl")
    encoded = (json.dumps(event, ensure_ascii=True, separators=(",", ":")) + "\n").encode("ascii")
    with _LOCK:
      with open(path, "ab", buffering=0) as handle:
        handle.write(encoded)

  def wait(self, *args, **kwargs):
    result = super().wait(*args, **kwargs)
    self._rwf_finish()
    return result

  def communicate(self, *args, **kwargs):
    result = super().communicate(*args, **kwargs)
    self._rwf_finish()
    return result

  def __exit__(self, *args):
    result = super().__exit__(*args)
    self._rwf_finish()
    return result

if _OUT and os.path.isdir(_OUT):
  subprocess.Popen = ProfiledPopen
  with open(os.path.join(_OUT, f"hook-{os.getpid()}"), "wb") as marker:
    marker.write(b"RWF809_POPEN_HOOK_ACTIVE\n")
