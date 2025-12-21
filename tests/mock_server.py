#!/usr/bin/env python3
"""
Simple HTTP mock server for testing claim-script.sh

Usage: mock_server.py <port> <method> <responses>

Where:
  - port: Port to listen on
  - method: HTTP method to respond to (GET, POST, DELETE)
  - responses: Comma-separated list of HTTP status codes to return in sequence

Example:
  mock_server.py 18080 DELETE 429,429,200

  This will return 429 for the first two DELETE requests, then 200 for subsequent ones.
"""

import http.server
import json
import sys
import threading


# Extended HTTP status messages for codes not in Python's default responses
HTTP_STATUS_MESSAGES = {
    200: "OK",
    201: "Created",
    204: "No Content",
    400: "Bad Request",
    401: "Unauthorized",
    403: "Forbidden",
    404: "Not Found",
    429: "Too Many Requests",
    500: "Internal Server Error",
    502: "Bad Gateway",
    503: "Service Unavailable",
}


class MockHandler(http.server.BaseHTTPRequestHandler):
    # Class-level state shared across requests
    responses = []
    response_index = 0
    target_method = "DELETE"
    lock = threading.Lock()

    def log_message(self, format, *args):
        # Suppress logging
        pass

    def send_mock_response(self):
        with self.lock:
            if self.response_index < len(self.responses):
                status = self.responses[self.response_index]
                MockHandler.response_index += 1
            else:
                # Default to last response if we run out
                status = self.responses[-1] if self.responses else 200

        # Handle special case: 000 means close connection (simulate network error)
        if status == 0:
            self.close_connection = True
            return

        # Send response with custom message for non-standard codes
        message = HTTP_STATUS_MESSAGES.get(status, "Unknown")
        self.send_response_only(status, message)
        self.send_header("Content-Type", "application/json")
        self.end_headers()

        # Send appropriate body based on status and path
        if status in (200, 201):
            if "/register" in self.path:
                body = json.dumps({"claim_code": "TEST123"})
            elif "/config" in self.path:
                body = json.dumps({
                    "customer": {"first_name": "Test", "last_name": "User", "email": "test@example.com"},
                    "pangolin": {"newt_id": "test", "newt_secret": "secret", "endpoint": "http://test"},
                    "auth": {"access_token": "token", "refresh_token": "refresh"}
                })
            else:
                body = json.dumps({"status": "ok"})
            self.wfile.write(body.encode())
        elif status == 204:
            # No content for 204
            pass

    def do_GET(self):
        # Health check endpoint always returns 200
        if self.path == "/health":
            self.send_response_only(200, "OK")
            self.end_headers()
            return

        if self.target_method == "GET":
            self.send_mock_response()
        else:
            self.send_response_only(404, "Not Found")
            self.end_headers()

    def do_POST(self):
        if self.target_method == "POST":
            self.send_mock_response()
        else:
            self.send_response_only(404, "Not Found")
            self.end_headers()

    def do_DELETE(self):
        if self.target_method == "DELETE":
            self.send_mock_response()
        else:
            self.send_response_only(404, "Not Found")
            self.end_headers()


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)

    port = int(sys.argv[1])
    method = sys.argv[2].upper()
    responses = [int(r) for r in sys.argv[3].split(",")]

    MockHandler.target_method = method
    MockHandler.responses = responses
    MockHandler.response_index = 0

    # Allow port reuse to avoid "Address already in use" errors
    http.server.HTTPServer.allow_reuse_address = True

    server = http.server.HTTPServer(("", port), MockHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
