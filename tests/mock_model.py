import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def send_json(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/v1/models":
            self.send_json({"object": "list", "data": [{"id": "TT3.6-27B-0623", "object": "model"}]})
        else:
            self.send_json({"error": "not found"}, 404)

    def do_POST(self) -> None:
        if self.path != "/v1/chat/completions":
            self.send_json({"error": "not found"}, 404)
            return
        size = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(size))
        messages = request.get("messages", [])
        if messages and messages[-1].get("role") == "tool":
            message = {"role": "assistant", "content": "MOCK_TOOL_OK"}
        else:
            message = {
                "role": "assistant",
                "content": None,
                "tool_calls": [{
                    "id": "mock-time",
                    "type": "function",
                    "function": {"name": "get_current_time", "arguments": "{}"},
                }],
            }
        self.send_json({"id": "mock", "object": "chat.completion", "choices": [{"index": 0, "message": message, "finish_reason": "stop"}]})

    def log_message(self, format: str, *args) -> None:
        return


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=6215)
    args = parser.parse_args()
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
