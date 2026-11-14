"""RWF809 exact-revision uninstrumented process-launch cost control."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "engine"
EXPECTED = "839404b33bbb9fa3ac0dcfdbcc68e5ad34ba0e66"
ROUNDS = 150

def invoke(args, cwd=ENGINE):
  return subprocess.run(args, cwd=cwd, capture_output=True, check=False,
                        timeout=20)

def main():
  output = ROOT / "launcher-results"
  output.mkdir(parents=True, exist_ok=True)
  rev = invoke(["git", "rev-parse", "HEAD"])
  assert rev.returncode == 0 and rev.stdout.decode().strip() == EXPECTED
  with tempfile.TemporaryDirectory(prefix="rwf809-noop-") as temp:
    source = Path(temp) / "noop.c"
    source.write_text("int main(void) { return 0; }\n", encoding="ascii")
    binary = Path(temp) / ("noop.exe" if os.name == "nt" else "noop")
    if os.name == "nt":
      pf86 = os.environ.get("ProgramFiles(x86)")
      if not pf86:
        raise RuntimeError("No installed Visual Studio path")
      vswhere = Path(pf86) / "Microsoft Visual Studio/Installer/vswhere.exe"
      vs = invoke([str(vswhere), "-latest", "-products", "*", "-property", "installationPath"])
      if vs.returncode or not vs.stdout.strip():
        raise RuntimeError("VS toolchain discovery failed")
      dev = Path(vs.stdout.decode().strip()) / "Common7/Tools/VsDevCmd.bat"
      batch = Path(temp) / "build-noop.cmd"
      batch.write_text(
        '@echo off\r\n' +
        f'call "{dev}" -no_logo -arch=amd64\r\n' +
        'if errorlevel 1 exit /b 1\r\n' +
        f'cl /nologo /O2 /Fe:"{binary}" "{source}"\r\n',
        encoding="ascii"
      )
      compile_run = invoke(["cmd.exe", "/d", "/c", str(batch)], ROOT)
    else:
      compiler = "clang" if platform.system() == "Darwin" else "cc"
      compile_run = invoke([compiler, "-O2", "-o", str(binary), str(source)], ROOT)
    if compile_run.returncode != 0 or not binary.is_file():
      raise RuntimeError("Native control compilation failed: " +
                         compile_run.stderr.decode("utf-8", errors="replace"))
    exe = str(binary)
    commands = {
      "empty_native": [exe],
      "git_version": ["git", "--version"],
      "git_status": ["git", "status", "--porcelain=v1"],
      "git_rev_parse": ["git", "rev-parse", "HEAD"],
      "python_noop": [sys.executable, "-c", "pass"],
    }
    # Separate warmups; identical fixture and no profiler instrumentation.
    for key, cmd in commands.items():
      for _ in range(5):
        result = invoke(cmd)
        if result.returncode:
          raise RuntimeError(f"{key} warmup failed: {result.stderr!r}")
    order = list(commands) * ROUNDS
    random.Random(809).shuffle(order)
    samples = []
    for index, key in enumerate(order):
      started = time.perf_counter_ns()
      result = invoke(commands[key])
      ms = (time.perf_counter_ns() - started) / 1e6
      if result.returncode != 0:
        raise RuntimeError(f"{key} command failed: {result.stderr!r}")
      if key == "git_status" and result.stdout.strip():
        raise RuntimeError("Git checkout changed during measurement")
      samples.append({"order":index,"kind":key,"elapsed_ms":ms})
    summary = []
    for key in commands:
      values = sorted(s["elapsed_ms"] for s in samples if s["kind"] == key)
      assert len(values) == ROUNDS
      summary.append({"kind":key,"n":ROUNDS,
                      "median_ms":statistics.median(values),
                      "p95_ms":values[142],"min_ms":values[0],"max_ms":values[-1]})
    identity = {
      "source_sha":EXPECTED,"os":platform.platform(),
      "runner":os.environ.get("ImageOS") or os.environ.get("RUNNER_OS"),
      "runner_image_version":os.environ.get("ImageVersion"),
      "python":sys.version, "python_executable":sys.executable,
      "git_executable":shutil.which("git"),
      "git_version":invoke(["git", "--version"]).stdout.decode().strip(),
      "autocrlf":invoke(["git", "config", "--get", "core.autocrlf"]).stdout.decode().strip(),
      "noop_source_sha256":hashlib.sha256(source.read_bytes()).hexdigest(),
      "noop_binary_sha256":hashlib.sha256(binary.read_bytes()).hexdigest(),
      "method":"untraced subprocess.run with 5 warmups and 150 interleaved rounds",
      "sample_count":len(samples),
    }
    (output/"identity.json").write_text(json.dumps(identity,indent=2),encoding="utf-8")
    (output/"raw.json").write_text(json.dumps(samples),encoding="utf-8")
    (output/"summary.json").write_text(json.dumps(summary,indent=2),encoding="utf-8")
    print("RWF809_LAUNCHER_BASELINE_PASS source="+EXPECTED+" samples="+str(len(samples)))
    for s in summary:
      print("RWF809_LAUNCHER "+json.dumps(s,sort_keys=True))

if __name__=="__main__":
  main()
