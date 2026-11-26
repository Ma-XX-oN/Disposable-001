"""Run 3 back-to-back rounds of 30 addComment mutations with the CI token,
in requests of 10, reporting successes and rate-limit headers; stop at the
first rejection. Mirrors the personal-login comment test."""
import json
import os
import subprocess
import time

OWNER, NAME = os.environ["GITHUB_REPOSITORY"].split("/")
NUMBERS = list(range(54, 84))
ROUNDS = 3
BATCH = 10
STAMP = time.strftime("%H%M%S")


def graphql(query, headers=False):
  """Run a GraphQL request; return (seconds, exit code, header lines, data, errors)."""
  args = ["gh", "api", "graphql", "-f", f"query={query}"]
  if headers:
    args.insert(3, "-i")
  start = time.perf_counter()
  proc = subprocess.run(args, capture_output=True, text=True)
  secs = time.perf_counter() - start
  out = proc.stdout.replace("\r\n", "\n")
  head, body = (out.split("\n\n", 1) + [""])[:2] if headers else ("", out)
  try:
    parsed = json.loads(body) if body.strip() else {}
  except json.JSONDecodeError:
    parsed = {}
  return secs, proc.returncode, head.splitlines(), parsed.get("data") or {}, parsed.get("errors") or []


def main():
  """Post the comment rounds and report each request."""
  fields = " ".join(f"i{n}: issue(number: {n}) {{ id }}" for n in NUMBERS)
  _, _, _, data, _ = graphql(
    f'query {{ repository(owner: "{OWNER}", name: "{NAME}") {{ {fields} }} }}')
  ids = [data["repository"][f"i{n}"]["id"] for n in NUMBERS]
  overall = time.perf_counter()
  total = 0
  for r in range(1, ROUNDS + 1):
    for i in range(0, len(ids), BATCH):
      chunk = ids[i:i + BATCH]
      fields = " ".join(
        f'c{j:02d}: addComment(input: {{subjectId: "{iid}", '
        f'body: "RWF CI limit test {STAMP} round {r} comment {i + j}"}}) '
        f'{{ commentEdge {{ node {{ id }} }} }}'
        for j, iid in enumerate(chunk))
      secs, code, head, data, errors = graphql(f"mutation {{ {fields} }}", True)
      ok = sum(1 for v in data.values() if v)
      total += ok
      limits = [l for l in head if l.lower().startswith(("x-ratelimit-limit", "x-ratelimit-remaining", "x-ratelimit-used"))]
      print(f"Round {r} request {i // BATCH + 1} at +{time.perf_counter() - overall:.1f}s: "
            f"{ok}/{len(chunk)} ok, {secs:.2f}s, exit {code}, total {total}")
      print("  ", limits)
      if errors:
        print(f"   {len(errors)} errors, first: {errors[0].get('message')}")
        print("Stopping at first rejection.")
        return


if __name__ == "__main__":
  main()
