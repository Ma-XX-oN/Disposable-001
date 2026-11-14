"""RWF809 read-only diagnostic selected solely from .ci/tests.json."""
from __future__ import annotations
from collections import Counter, defaultdict
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time

WORKBENCH = Path(__file__).resolve().parents[1]
ENGINE = WORKBENCH / "engine"
OUT = WORKBENCH / "profile-results"
EVENTS = OUT / "events"
SOURCE_SHA = "839404b33bbb9fa3ac0dcfdbcc68e5ad34ba0e66"
SELECTED = (
  "issue-545-real-consumer-verify",
  "issue-545-dirty-rename",
  "issue-545-unified-test-cli",
)

def assert_git_revision():
  actual = subprocess.check_output(["git", "-C", str(ENGINE), "rev-parse", "HEAD"], text=True).strip()
  if actual != SOURCE_SHA:
    raise RuntimeError(f"Source SHA mismatch {actual} != {SOURCE_SHA}")
  return actual

def main():
  OUT.mkdir(exist_ok=True)
  EVENTS.mkdir(exist_ok=True)
  source_sha = assert_git_revision()
  manifest = ENGINE / ".ci" / "tests.json"
  manifest_sha256 = hashlib.sha256(manifest.read_bytes()).hexdigest()
  sys.path.insert(0, str(ENGINE))
  from repo_workflow.self_ci import group_command
  catalogue = json.loads(manifest.read_text(encoding="utf-8"))
  declarations = {}
  for entry in catalogue["tests"]:
    for group, meta in entry.items():
      if group in ("test-harness", "command"):
        continue
      if group in declarations:
        raise RuntimeError(f"Duplicate catalogue group {group}")
      declarations[group] = meta
  for group in SELECTED:
    if group not in declarations or declarations[group].get("type") != "regression":
      raise RuntimeError(f"Missing regression group in catalogue: {group}")
  env = dict(os.environ)
  profiler = str(WORKBENCH / "rwf809" / "profiler")
  env["PYTHONPATH"] = os.pathsep.join([profiler, str(ENGINE), env.get("PYTHONPATH", "")]).rstrip(os.pathsep)
  env["RWF809_TRACE_DIRECTORY"] = str(EVENTS)
  env["RWF809_SOURCE_ROOT"] = str(ENGINE)
  env["PYTHONDONTWRITEBYTECODE"] = "1"
  outcomes = []
  for group in SELECTED:
    cmd = group_command(ENGINE, group)
    # Never use unittest discovery or the historical validate.py script.
    expected = ("-m", "unittest", declarations[group]["name"])
    if tuple(cmd[1:]) != expected or not Path(cmd[0]).samefile(sys.executable):
      raise RuntimeError(f"Unexpected/noncatalogue command for {group}")
    env["RWF809_GROUP"] = group
    started = time.perf_counter()
    try:
      done = subprocess.run(cmd, cwd=ENGINE, env=env,
                            capture_output=True, text=True, timeout=350, check=False)
      code = done.returncode
      (OUT / f"{group}-stdout.txt").write_text(done.stdout, encoding="utf-8")
      (OUT / f"{group}-stderr.txt").write_text(done.stderr, encoding="utf-8")
      timedout = False
    except subprocess.TimeoutExpired as ex:
      code = None
      timedout = True
      (OUT / f"{group}-stdout.txt").write_bytes(ex.stdout or b"")
      (OUT / f"{group}-stderr.txt").write_bytes(ex.stderr or b"")
    duration = time.perf_counter() - started
    outcomes.append({"group": group, "module": declarations[group]["name"],
                     "returncode": code, "timeout": timedout,
                     "wall_s": duration})
    print(f"RWF809_CATALOGUE_GROUP group={group} exit={code} timeout={timedout} wall_s={duration:.3f}", flush=True)
  events = []
  for file in EVENTS.glob("proc-*.jsonl"):
    for line in file.read_text(encoding="ascii").splitlines():
      obj = json.loads(line)
      if obj["schema"] != 1 or not isinstance(obj["elapsed_ms"], (int, float)):
        raise RuntimeError("invalid trace event schema")
      if obj["elapsed_ms"] < 0:
        raise RuntimeError("negative duration")
      events.append(obj)
  if not events:
    raise RuntimeError("No subprocess events captured")
  if not list(EVENTS.glob("hook-*.jsonl")) and not list(EVENTS.glob("hook-*")):
    raise RuntimeError("No evidence profiler loaded in child Python")
  counts = Counter((e["group"], e["kind"], e["verb"], e["callsite"]) for e in events)
  totals = defaultdict(float)
  for e in events:
    totals[(e["group"], e["kind"], e["verb"], e["callsite"])] += e["elapsed_ms"]
  summary = sorted(
    [{"group": group, "kind": kind, "verb": verb, "callsite": callsite,
      "count": n, "cumulative_ms": totals[group, kind, verb, callsite]}
     for (group, kind, verb, callsite), n in counts.items()],
    key=lambda e: e["cumulative_ms"], reverse=True
  )
  envinfo = {
    "source_sha": source_sha,
    "catalogue_sha256": manifest_sha256,
    "platform": platform.platform(),
    "python": sys.version,
    "git": subprocess.check_output(["git", "--version"], text=True).strip(),
    "autocrlf": subprocess.run(["git", "-C", str(ENGINE), "config",
                               "--get", "core.autocrlf"], capture_output=True, text=True).stdout.strip(),
    "selected": list(SELECTED),
    "run_results": outcomes,
    "trace_records": len(events),
    "github_run_id": os.environ.get("GITHUB_RUN_ID"),
    "method": "sitecustomize Popen wait/communicate/exit; diagnostic only, non-authoritative timing"
  }
  (OUT / "identity.json").write_text(json.dumps(envinfo, indent=2), encoding="utf-8")
  (OUT / "callsite-summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
  print("RWF809_CALLSITE_PROFILE_COMPLETE source=" + source_sha +
        f" groups={len(outcomes)} events={len(events)}", flush=True)
  for item in summary[:15]:
    print("RWF809_SITE " + json.dumps(item, sort_keys=True), flush=True)
  if any(x["returncode"] != 0 or x["timeout"] for x in outcomes):
    raise RuntimeError("Some selected catalogue tests failed or timed out; profile diagnostic only")

if __name__ == "__main__":
  main()
