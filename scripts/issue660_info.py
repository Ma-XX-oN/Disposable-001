import json
import sys
if len(sys.argv) == 4 and sys.argv[1:3] == ["issue", "get"]:
  number = int(sys.argv[3])
  print(json.dumps({"schema_version": 1, "number": number, "title": "Disposable version start fixture", "state": "open", "link": "https://github.com/Ma-XX-oN/Disposable-001/issues/1"}))
  raise SystemExit(0)
raise SystemExit(2)
