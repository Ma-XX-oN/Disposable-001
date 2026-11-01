"""Real GitHub provider smoke: test-scoped auth, immutable request, cleanup.

Temporary acceptance probe, NOT a production authorization issuer.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

repo = "Ma-XX-oN/Disposable-001"
source = (Path(__file__).resolve().parents[1] / "rwf-source").resolve()
sys.path.insert(0, str(source))
sys.path.insert(0, str(source / "adapters"))
from repo_workflow.done_host_transport import (
  NativeHostTransportError, bind_native_integration_host,
)
from adapters.repo_host_github_provider import (
  GitHubBackend, reservation_ref,
)

def gh(method, route, payload=None):
  command = ["gh", "api", "--method", method, route]
  if payload is not None:
    command += ["--input", "-"]
  proc = subprocess.run(
    command, input=json.dumps(payload) if payload is not None else None,
    text=True, capture_output=True, timeout=45, check=False,
  )
  if proc.returncode != 0:
    raise AssertionError("GitHub API request failed: " + method + " " + route)
  return json.loads(proc.stdout) if proc.stdout.strip() else None

def delete_ref(ref):
  route = "repos/" + repo + "/git/refs/" + ref.removeprefix("refs/")
  proc = subprocess.run(["gh", "api", "--method", "DELETE", route],
                        text=True, capture_output=True, timeout=45)
  assert proc.returncode == 0, "failed to clean run-scoped ref"

def main():
  assert os.environ["GITHUB_REPOSITORY"] == repo
  assert os.environ["GH_TOKEN"]
  backend = GitHubBackend(repo)
  actor = backend.identity()["login"]
  default = backend.get("")["default_branch"]
  original = backend.get("git/ref/heads/" + default)["object"]["sha"]
  run = os.environ["GITHUB_RUN_ID"]
  guid = str(uuid.uuid4())
  ref = "refs/heads/INT-ATTEMPT-issue-1/rwf109test-" + guid
  request_id = "rwf109-real-" + run + "-" + guid
  parameters = {"ref": ref, "sha": original}
  request = {
    "schema_version": 2, "repository": repo,
    "operation": "ref.create", "request_id": request_id,
    "parameters": parameters,
  }
  reservation = reservation_ref(request)
  transport = bind_native_integration_host(
    repository=repo, engine_root=source,
    project_root=Path.cwd(),
  )
  os.environ.pop("RWF_REPO_HOST_AUTH_COMMAND", None)
  denied = False
  try:
    transport.request("ref.create", request_id, parameters)
  except NativeHostTransportError:
    denied = True
  assert denied, "missing verifier did not fail closed"
  assert backend.get("git/ref/heads/" + default)["object"]["sha"] == original

  temp = Path(os.environ["RUNNER_TEMP"]).resolve()
  verifier = temp / ("rwf109-test-issuer-" + run + ".py")
  verifier.write_text(
    "#!/usr/bin/env python3\n"
    "import datetime,hashlib,json,os,sys\n"
    "data=json.load(sys.stdin)['request']\n"
    "raw=json.dumps(data,sort_keys=True,separators=(',',':')).encode()\n"
    "assert data['repository']=='Ma-XX-oN/Disposable-001'\n"
    "assert data['operation']=='ref.create'\n"
    "assert data['parameters']['ref']==os.environ['RWF_TEST_SCOPE_REF']\n"
    "assert data['request_id']==os.environ['RWF_TEST_REQUEST_ID']\n"
    "actor=os.environ['RWF_TEST_ACTOR']\n"
    "print(json.dumps(dict(schema_version=1,request_id=data['request_id'],"
    "grant_id='disposable-test-only',grant_revision=1,actor_id=actor,"
    "capability=data['operation'],"
    "scope_digest=hashlib.sha256(raw).hexdigest(),"
    "policy_revision='run-scoped-test-only',"
    "evaluated_at=datetime.datetime.now(datetime.timezone.utc)"
    ".strftime('%Y-%m-%dT%H:%M:%SZ'),"
    "decision='allow',reason='isolated disposable-ref smoke')))\n",
    encoding="utf-8",
  )
  verifier.chmod(0o700)
  assert source not in verifier.parents
  os.environ["RWF_REPO_HOST_AUTH_COMMAND"] = json.dumps([str(verifier)])
  os.environ["RWF_TEST_SCOPE_REF"] = ref
  os.environ["RWF_TEST_REQUEST_ID"] = request_id
  os.environ["RWF_TEST_ACTOR"] = "deliberately-foreign-actor"
  try:
    rejected = False
    try:
      transport.request("ref.create", request_id, parameters)
    except NativeHostTransportError:
      rejected = True
    assert rejected, "foreign actor did not fail closed"
    try:
      backend.get("git/ref/" + ref.removeprefix("refs/"))
    except Exception as error:
      assert getattr(error, "code", None) == "not_found"
    else:
      raise AssertionError("foreign actor created ref")

    os.environ["RWF_TEST_ACTOR"] = actor
    result = transport.request("ref.create", request_id, parameters)
    assert result == parameters, "authorized provider result differs"
    actual = backend.get("git/ref/" + ref.removeprefix("refs/"))
    assert actual["object"]["sha"] == original
    assert backend.get("git/ref/heads/" + default)["object"]["sha"] == original
    second = transport.request("ref.create", request_id, parameters)
    assert second == parameters, "idempotent retry changed result"
    assert backend.get("git/ref/" + ref.removeprefix("refs/"))["object"]["sha"] == original
    print("PASS: unauthorized denied; actor mismatch denied; real ref created; readback; idempotency; main unchanged")
  finally:
    os.environ.pop("RWF_REPO_HOST_AUTH_COMMAND", None)
    for reference in (ref, reservation):
      try:
        backend.get("git/ref/" + reference.removeprefix("refs/"))
      except Exception as error:
        if getattr(error, "code", None) != "not_found":
          raise
      else:
        delete_ref(reference)
    assert backend.get("git/ref/heads/" + default)["object"]["sha"] == original
    verifier.unlink(missing_ok=True)

if __name__ == "__main__":
  main()
