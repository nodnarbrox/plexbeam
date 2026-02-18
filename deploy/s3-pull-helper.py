#!/usr/bin/env python3
"""
PlexBeam S3 Pull Helper — Upload/delete chunk files to S3 for cloud workers.

Usage:
    python3 s3-pull-helper.py upload <local_file> <s3_key>
    python3 s3-pull-helper.py delete <s3_key>
    python3 s3-pull-helper.py url <s3_key>

Environment variables:
    AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION, S3_BUCKET_NAME

Generates pre-signed download URLs (valid 1 hour) so the bucket stays private.
"""
import os
import sys
import boto3
from botocore.config import Config


def get_client():
    return boto3.client(
        "s3",
        aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        region_name=os.environ.get("AWS_REGION", "us-east-2"),
        config=Config(signature_version="s3v4"),
    )


def upload(local_path, s3_key):
    client = get_client()
    bucket = os.environ["S3_BUCKET_NAME"]
    client.upload_file(local_path, bucket, s3_key)
    # Generate pre-signed URL valid for 1 hour
    url = client.generate_presigned_url(
        "get_object",
        Params={"Bucket": bucket, "Key": s3_key},
        ExpiresIn=3600,
    )
    print(url)


def delete(s3_key):
    client = get_client()
    bucket = os.environ["S3_BUCKET_NAME"]
    client.delete_object(Bucket=bucket, Key=s3_key)
    print("deleted")


def get_url(s3_key):
    client = get_client()
    bucket = os.environ["S3_BUCKET_NAME"]
    url = client.generate_presigned_url(
        "get_object",
        Params={"Bucket": bucket, "Key": s3_key},
        ExpiresIn=3600,
    )
    print(url)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} upload|delete|url <args>", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "upload" and len(sys.argv) == 4:
        upload(sys.argv[2], sys.argv[3])
    elif cmd == "delete" and len(sys.argv) == 3:
        delete(sys.argv[2])
    elif cmd == "url" and len(sys.argv) == 3:
        get_url(sys.argv[2])
    else:
        print(f"Unknown: {cmd}", file=sys.stderr)
        sys.exit(1)
