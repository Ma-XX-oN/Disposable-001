from pathlib import Path
import re
import sys
path = Path(__file__).resolve().parents[1] / "VERSION"
value = path.read_text(encoding="utf-8").strip()
arguments = sys.argv[1:]
if not arguments:
  print(value)
elif len(arguments) == 3 and arguments[:2] == ["task", "--issue"] and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
  issue = int(arguments[2])
  if issue < 1:
    raise SystemExit(2)
  path.write_text(value + f"-issue.{issue}.0.1\n", encoding="utf-8")
else:
  raise SystemExit(2)
