#!/usr/bin/env python3
"""
PlexBeam S3 Pull Proxy — Accepts chunk uploads from the cartridge (localhost),
uploads them to S3, and returns a pre-signed download URL.

Cloud workers (SaladCloud) download chunks directly from S3.
AWS credentials stay here — the cartridge never sees them.

Usage:
    python3 pull-server.py [--port 8780] [--s3-prefix plexbeam-chunks]

Endpoints:
    PUT /upload/<filename>   — Upload file, push to S3, return pre-signed URL
    DELETE /upload/<filename> — Delete file from S3

Environment variables (required):
    AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION, S3_BUCKET_NAME
"""
import argparse
import io
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import boto3
from botocore.config import Config


class S3PullHandler(BaseHTTPRequestHandler):

    s3_client = None
    s3_bucket = None
    s3_prefix = None
    staging_dir = None

    def log_message(self, format, *args):
        print(f"[{self.log_date_time_string()}] {format % args}")

    def do_PUT(self):
        """Receive file from cartridge, upload to S3, return pre-signed URL."""
        path = self.path.lstrip("/")
        if not path.startswith("upload/"):
            self.send_error(404, "Use PUT /upload/<filename>")
            return

        filename = path[len("upload/"):]
        if not filename or "/" in filename or "\\" in filename:
            self.send_error(400, "Invalid filename")
            return

        # Read request body
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length == 0:
            # Chunked or streamed — read until EOF
            body = self.rfile.read()
        else:
            body = self.rfile.read(content_length)

        s3_key = f"{self.s3_prefix}/{filename}"

        try:
            # Upload to S3
            self.s3_client.put_object(
                Bucket=self.s3_bucket,
                Key=s3_key,
                Body=body,
            )

            # Generate pre-signed URL (1 hour)
            url = self.s3_client.generate_presigned_url(
                "get_object",
                Params={"Bucket": self.s3_bucket, "Key": s3_key},
                ExpiresIn=3600,
            )

            size_mb = len(body) / (1024 * 1024)
            print(f"[upload] {filename}: {size_mb:.1f} MB → s3://{self.s3_bucket}/{s3_key}")

            response = json.dumps({"url": url, "key": s3_key, "size": len(body)})
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response.encode())

        except Exception as e:
            print(f"[upload] ERROR: {e}")
            err = json.dumps({"error": str(e)})
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(err.encode())

    def do_DELETE(self):
        """Delete file from S3."""
        path = self.path.lstrip("/")
        if not path.startswith("upload/"):
            self.send_error(404)
            return

        filename = path[len("upload/"):]
        s3_key = f"{self.s3_prefix}/{filename}"

        try:
            self.s3_client.delete_object(Bucket=self.s3_bucket, Key=s3_key)
            print(f"[delete] {s3_key}")
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
        except Exception as e:
            print(f"[delete] ERROR: {e}")
            self.send_error(500, str(e))

    def do_GET(self):
        """Health check."""
        if self.path == "/health":
            body = json.dumps({"status": "ok", "bucket": self.s3_bucket}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)


def s3_cleanup_loop(client, bucket, prefix, ttl):
    """Periodically delete old S3 objects under the prefix."""
    while True:
        try:
            response = client.list_objects_v2(Bucket=bucket, Prefix=prefix + "/")
            now = time.time()
            for obj in response.get("Contents", []):
                age = now - obj["LastModified"].timestamp()
                if age > ttl:
                    client.delete_object(Bucket=bucket, Key=obj["Key"])
                    print(f"[s3-cleanup] Deleted {obj['Key']} (age: {age:.0f}s)")
        except Exception as e:
            print(f"[s3-cleanup] Error: {e}")
        time.sleep(60)


def main():
    parser = argparse.ArgumentParser(description="PlexBeam S3 Pull Proxy")
    parser.add_argument("--port", type=int, default=8780)
    parser.add_argument("--bind", default="127.0.0.1",
                        help="Bind address (default: 127.0.0.1 — localhost only)")
    parser.add_argument("--s3-prefix", default="plexbeam-chunks",
                        help="S3 key prefix (default: plexbeam-chunks)")
    parser.add_argument("--ttl", type=int, default=600,
                        help="S3 object TTL in seconds (default: 600)")
    args = parser.parse_args()

    # Validate env vars
    for var in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "S3_BUCKET_NAME"):
        if not os.environ.get(var):
            print(f"ERROR: {var} not set", file=sys.stderr)
            sys.exit(1)

    client = boto3.client(
        "s3",
        aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        region_name=os.environ.get("AWS_REGION", "us-east-2"),
        config=Config(signature_version="s3v4"),
    )

    # Set class-level config
    S3PullHandler.s3_client = client
    S3PullHandler.s3_bucket = os.environ["S3_BUCKET_NAME"]
    S3PullHandler.s3_prefix = args.s3_prefix

    # Start S3 cleanup thread
    cleaner = threading.Thread(
        target=s3_cleanup_loop,
        args=(client, S3PullHandler.s3_bucket, args.s3_prefix, args.ttl),
        daemon=True,
    )
    cleaner.start()

    server = HTTPServer((args.bind, args.port), S3PullHandler)
    print(f"PlexBeam S3 Pull Proxy")
    print(f"  Bucket:  s3://{S3PullHandler.s3_bucket}/{args.s3_prefix}/")
    print(f"  Listen:  {args.bind}:{args.port}")
    print(f"  TTL:     {args.ttl}s")
    print(f"  Ready.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.shutdown()


if __name__ == "__main__":
    main()
