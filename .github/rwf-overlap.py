"""Post COUNT comments, in requests of 10, starting at a given UTC epoch time,
reporting successes; stop at the first rejection. Run at the same moment by
CI (its GITHUB_TOKEN) and locally (a personal login) to see whether the two
accounts share the 80-per-minute content limit.

Usage: rwf-overlap.py <owner/repo> <start-epoch> <count> <label>
"""
import json
import subprocess
import sys
import time

REPO, START, COUNT, LABEL = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
OWNER, NAME = REPO.split("/")
NUMBERS = list(range(54, 84))
BATCH = 10


def graphql(query):
  """Run a GraphQL request; return (seconds, data, errors)."""
  start = time.perf_counter()
  proc = subprocess.run(["gh", "api", "graphql", "-f", f"query={query}"],
                        capture_output=True, text=True)
  secs = time.perf_counter() - start
  try:
    parsed = json.loads(proc.stdout) if proc.stdout.strip() else {}
  except json.JSONDecodeError:
    parsed = {}
  return secs, parsed.get("data") or {}, parsed.get("errors") or []


def main():
  """Wait for the start time, then post the comments."""
  fields = " ".join(f"i{n}: issue(number: {n}) {{ id }}" for n in NUMBERS)
  _, data, _ = graphql(f'query {{ repository(owner: "{OWNER}", name: "{NAME}") {{ {fields} }} }}')
  ids = [data["repository"][f"i{n}"]["id"] for n in NUMBERS]
  targets = [ids[i % len(ids)] for i in range(COUNT)]
  delay = START - time.time()
  print(f"{LABEL}: waiting {delay:.1f}s for the start time")
  if delay > 0:
    time.sleep(delay)
  total = 0
  for i in range(0, COUNT, BATCH):
    chunk = targets[i:i + BATCH]
    fields = " ".join(
      f'c{j:02d}: addComment(input: {{subjectId: "{iid}", '
      f'body: "RWF overlap test {START} {LABEL} comment {i + j}"}}) '
      f'{{ commentEdge {{ node {{ id }} }} }}'
      for j, iid in enumerate(chunk))
    secs, data, errors = graphql(f"mutation {{ {fields} }}")
    ok = sum(1 for v in data.values() if v)
    total += ok
    print(f"{LABEL} request {i // BATCH + 1} at +{time.time() - START:.1f}s: "
          f"{ok}/{len(chunk)} ok, {secs:.2f}s, total {total}")
    if errors:
      print(f"{LABEL}: {len(errors)} errors, first: {errors[0].get('message')}; stopping")
      break
  print(f"{LABEL}: {total}/{COUNT} posted")


if __name__ == "__main__":
  main()
