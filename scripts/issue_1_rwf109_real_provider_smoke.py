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
from repo_workflow.integration_host_v2 import IntegrationHostError
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
  cleanup_refs = [ref, reservation]
  transport = bind_native_integration_host(
    repository=repo, engine_root=source,
    project_root=Path.cwd(),
  )
  os.environ.pop("RWF_REPO_HOST_AUTH_COMMAND", None)
  denied = False
  try:
    transport.request("ref.create", request_id, parameters)
  except (NativeHostTransportError, IntegrationHostError):
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
    "assert data['operation'] in ('ref.create','ref.cas')\n"
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
    except (NativeHostTransportError, IntegrationHostError):
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
    # Exact-old-SHA CAS against the same disposable INT ref, not main.
    local = Path.cwd()
    def git(*args):
      process = subprocess.run(
        ["git", "-C", str(local), *args], text=True, capture_output=True,
        timeout=45, check=False,
      )
      assert process.returncode == 0, "isolated test Git operation failed: " + str(args)
      return process.stdout.strip()
    cfg = local / ".ci" / "repoworkflow.json"
    assert not cfg.exists(), "test expected no project config"
    cfg.write_text(json.dumps({
      "schema": 1, "versionCommand": ["python", "version.py"],
      "repository": {"integrationBranch": "main", "authoritativeRemote": "origin"},
      "environments": [{
        "id": "disposable", "validationCommand": ["python", "validate.py"],
      }], "artifacts": [],
    }), encoding="utf-8")
    try:
      clone_url = backend.get("")["clone_url"]
      assert clone_url == "https://github.com/Ma-XX-oN/Disposable-001.git"
      git("remote", "set-url", "origin", clone_url)
      import base64
      secret = base64.b64encode(
        ("x-access-token:" + os.environ["GH_TOKEN"]).encode()
      ).decode("ascii")
      git("config", "--local", "http.https://github.com/.extraheader",
          "AUTHORIZATION: basic " + secret)
      git("fetch", "--no-tags", "origin", default)
      git("cat-file", "-e", original + "^{commit}")
      tree = git("rev-parse", original + "^{tree}")
      newer = git(
        "-c", "user.name=RWF-Test", "-c",
        "user.email=rwf-test@users.noreply.github.com",
        "commit-tree", tree, "-p", original,
        "-m", "RWF #109 disposable INT-CAS smoke " + run,
      )
      assert len(newer) == 40 and newer != original
      for suffix in ("-cas", "-stale"):
        cleanup_refs.append(reservation_ref({
          "schema_version": 2, "repository": repo, "operation": "ref.cas",
          "request_id": request_id + suffix,
          "parameters": {
            "ref": ref, "expected_sha": original, "sha": newer,
          },
        }))
      cas_id = request_id + "-cas"
      os.environ["RWF_TEST_REQUEST_ID"] = cas_id
      result = transport.request("ref.cas", cas_id, {
        "ref": ref, "expected_sha": original, "sha": newer,
      })
      assert result == {"ref": ref, "sha": newer}
      assert backend.get("git/ref/" + ref.removeprefix("refs/"))["object"]["sha"] == newer
      assert backend.get("git/ref/heads/" + default)["object"]["sha"] == original
      stale_id = request_id + "-stale"
      os.environ["RWF_TEST_REQUEST_ID"] = stale_id
      rejected = False
      try:
        transport.request("ref.cas", stale_id, {
          "ref": ref, "expected_sha": original, "sha": newer,
        })
      except (NativeHostTransportError, IntegrationHostError):
        rejected = True
      assert rejected, "stale CAS was accepted"
      assert backend.get("git/ref/" + ref.removeprefix("refs/"))["object"]["sha"] == newer
      print("PASS: actual scoped CAS applied, stale CAS rejected, destination unchanged")
    finally:
      cfg.unlink(missing_ok=True)
      git("config", "--local", "--unset-all", "http.https://github.com/.extraheader")
    print("PASS: unauthorized denied; actor mismatch denied; real ref created; readback; idempotency; main unchanged")
  finally:
    os.environ.pop("RWF_REPO_HOST_AUTH_COMMAND", None)
    for reference in cleanup_refs:
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
