"""Synthetic Synapse process for the cross-service contract test.

All runtime state is in this process. Only AI extraction is substituted; real
receipt lifecycle, resolution, workspace bindings and hub transport execute.
"""

import contextlib
import json
import sys

from core import capture_clients, media_capture, media_resolution, workspace

store = {}
issued = capture_clients.issue_gateway(
    store, "Contract gateway", "fixture", ["articles"], ["saved", "status"]
)
ws = workspace.build(
    "fixture",
    {"databases": {"articles": {"saved_column": "saved"}}},
    secrets={"life_hub_url": sys.argv[1], "life_hub_token": "synthetic-writer"},
)
media_resolution.classify = lambda text: "tasks" if text == "make a task" else "articles"
media_resolution.extract = lambda category, text: {"Title": "Synthetic article", "URL": text}
for line in sys.stdin:
    payload = json.loads(line)
    with contextlib.redirect_stdout(sys.stderr), workspace.use(ws):
        try:
            media_capture.validate_envelope(payload)
            caller = media_capture.gateway_caller(store, "Bearer " + issued["token"], payload)
            if payload["action"] == "get":
                value = media_capture.get_capture(store, caller, payload["request_id"])
            else:
                value = media_capture.submit_capture(store, caller, payload["request"])
                media_capture.process_capture(store, caller, payload["request"]["request_id"])
            result = {"status": 200, "body": value}
        except media_capture.Conflict:
            result = {"status": 409, "body": {"error": "conflict"}}
        except media_capture.NotFound:
            result = {"status": 404, "body": {"error": "not found"}}
    print(json.dumps(result), flush=True)
