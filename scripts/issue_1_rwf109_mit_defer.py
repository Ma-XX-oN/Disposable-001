"""#109 disposable MIT deferral physical provider acceptance, test-only authorities."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

ROOT = Path.cwd()
SRC = ROOT / "rwf-source"
sys.path.insert(0,str(SRC))
sys.path.insert(0,str(SRC / "adapters"))
from repo_workflow.done_host_transport import bind_native_integration_host
from repo_workflow.integration_host_v2 import IntegrationHostError
from adapters.repo_host_github_provider import GitHubBackend

REPO = "Ma-XX-oN/Disposable-001"
DEST = "issue-1-rwf109-mit-defer-20261101"

def gh_delete(ref):
  result = subprocess.run(
    ["gh","api","--method","DELETE",
     "repos/"+REPO+"/git/refs/"+ref.removeprefix("refs/")],
    text=True,capture_output=True,timeout=45,check=False)
  assert result.returncode == 0, "MIT test tag cleanup failed"

def write_issuer(path,kind):
  base = (
    "import datetime,hashlib,json,os,sys\n"
    "payload=json.load(sys.stdin)\n"
    "request=payload['request']\n"
    "assert request['repository']=='Ma-XX-oN/Disposable-001'\n"
    "assert request['operation']=='mit.deferred.record'\n"
    "assert request['request_id']==os.environ['RWF_TEST_REQUEST_ID']\n"
    "record=request['parameters']['event']\n"
    "assert record['guid']==os.environ['RWF_TEST_GUID']\n"
    "assert record['destination']=='issue-1-rwf109-mit-defer-20261101'\n"
    "def digest(obj):\n"
    "  return hashlib.sha256(json.dumps(obj,sort_keys=True,separators=(',',':')).encode()).hexdigest()\n"
    "stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')\n"
  )
  if kind=="auth":
    base+=(
      "print(json.dumps(dict(schema_version=1,request_id=request['request_id'],"
      "grant_id='disposable-mit-test',grant_revision=1,"
      "actor_id=os.environ['RWF_TEST_AUTH_ACTOR'],"
      "capability=request['operation'],scope_digest=digest(request),"
      "policy_revision='test-only',evaluated_at=stamp,decision='allow',"
      "reason='disposable controlled test')))\n"
    )
  else:
    base+=(
      "assert payload['provider_actor']==os.environ['RWF_TEST_ACTOR']\n"
      "print(json.dumps(dict(schema_version=1,request_digest=digest(request),"
      "record_digest=digest(record),actor_id=payload['provider_actor'],"
      "repository=request['repository'],operation=request['operation'],"
      "request_id=request['request_id'],decision='allow',"
      "authority_ref='disposable-mit-run-scoped',revocation_revision=1,"
      "evaluated_at=stamp)))\n"
    )
  path.write_text(base,encoding="utf-8")
  path.chmod(0o700)

def main():
  assert os.environ["GITHUB_REPOSITORY"]==REPO
  backend=GitHubBackend(REPO)
  actor=backend.identity()["login"]
  main_before=backend.get("git/ref/heads/main")["object"]["sha"]
  dest_sha=backend.get("git/ref/heads/"+DEST)["object"]["sha"]
  guid=str(uuid.uuid4())
  event={
    "repository":REPO,"guid":guid,"destination":DEST,
    "prelim_sha":dest_sha,"lease_generation":1,
    "evidence_ref":"run-"+os.environ["GITHUB_RUN_ID"],
    "reason":"timeout",
  }
  request_id="mit-test-"+os.environ["GITHUB_RUN_ID"]+"-"+guid
  params={"guid":guid,"destination":DEST,"event":event}
  ref="refs/tags/rwf-mit-deferred-v2-"+guid+"-000000000001"
  temp=Path(os.environ["RUNNER_TEMP"]).resolve()
  auth=temp/("rwf-mit-auth-"+guid+".py")
  evidence=temp/("rwf-mit-evidence-"+guid+".py")
  assert SRC not in temp.parents and temp!=SRC
  write_issuer(auth,"auth")
  write_issuer(evidence,"evidence")
  os.environ["RWF_TEST_REQUEST_ID"]=request_id
  os.environ["RWF_TEST_GUID"]=guid
  os.environ["RWF_TEST_ACTOR"]=actor
  os.environ["RWF_TEST_AUTH_ACTOR"]=actor
  host=bind_native_integration_host(
    repository=REPO,engine_root=SRC,project_root=ROOT)
  os.environ.pop("RWF_REPO_HOST_AUTH_COMMAND",None)
  os.environ.pop("RWF_REPO_HOST_INTEGRATION_EVIDENCE_COMMAND",None)
  def denied():
    try:
      host.request("mit.deferred.record",request_id,params)
    except IntegrationHostError:
      return
    raise AssertionError("provider accepted unauthorized MIT mutation")
  try:
    denied()
    os.environ["RWF_REPO_HOST_AUTH_COMMAND"]=json.dumps([str(auth)])
    os.environ["RWF_TEST_AUTH_ACTOR"]="foreign-actor"
    denied()
    os.environ["RWF_TEST_AUTH_ACTOR"]=actor
    denied() # independent evidence issuer still missing
    os.environ["RWF_REPO_HOST_INTEGRATION_EVIDENCE_COMMAND"]=json.dumps([str(evidence)])
    try:
      result=host.request("mit.deferred.record",request_id,params)
    except IntegrationHostError:
      import importlib.util
      spec=importlib.util.spec_from_file_location(
        "rwf109_debug_v2",SRC/"adapters"/"repo-host-integration-v2.py")
      assert spec and spec.loader
      adapter=importlib.util.module_from_spec(spec)
      spec.loader.exec_module(adapter)
      request={"schema_version":2,"repository":REPO,
        "operation":"mit.deferred.record","request_id":request_id,
        "parameters":params}
      try:
        adapter.process(request)
      except Exception as issue:
        print("MIT provider classified failure:",
          type(issue).__name__,str(issue)[:180],file=sys.stderr)
        raise
      raise
    assert result["event"]==event
    read=host.request("mit.deferred.read",request_id+"-read",
      {"guid":guid,"destination":DEST})
    assert read["event"]==event
    again=host.request("mit.deferred.record",request_id,params)
    assert again["event"]==event
    assert backend.get("git/ref/heads/main")["object"]["sha"]==main_before
    assert backend.get("git/ref/heads/"+DEST)["object"]["sha"]==dest_sha
    print("PASS: MIT no-auth and foreign actor denied; missing issuer denied; real deferral persisted, read back, idempotent; main unchanged")
  finally:
    try:
      backend.get("git/ref/tags/"+ref.rsplit("/",1)[1])
    except Exception as err:
      assert getattr(err,"code",None)=="not_found"
    else:
      gh_delete(ref)
    for path in (auth,evidence):
      path.unlink(missing_ok=True)
    assert backend.get("git/ref/heads/main")["object"]["sha"]==main_before
    assert backend.get("git/ref/heads/"+DEST)["object"]["sha"]==dest_sha

if __name__=="__main__":
  main()
