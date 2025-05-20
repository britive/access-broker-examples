#!/usr/bin/env python3

import os
import boto3
import sys
import botocore.exceptions

ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")

def get_instance_ids_by_tag_values(tag_key, tag_value_csv):
    try:
        tag_values = [v.strip() for v in tag_value_csv.split(",") if v.strip()]
        filters = [{"Name": f"tag:{tag_key}", "Values": tag_values}]
        instance_ids = []

        paginator = ec2.get_paginator("describe_instances")
        for page in paginator.paginate(Filters=filters):
            for reservation in page.get("Reservations", []):
                for instance in reservation.get("Instances", []):
                    if instance.get("State", {}).get("Name") == "running":
                        instance_ids.append(instance["InstanceId"])

        return list(set(instance_ids))
    except botocore.exceptions.BotoCoreError as e:
        print(f"[ERROR] Failed to retrieve instance IDs: {e}")
        sys.exit(1)

def revoke_temp_access(instance_ids, username):
    if not instance_ids:
        print("[ERROR] No matching instances found for revoke.")
        sys.exit(1)

    try:
        targets = [{"Key": "InstanceIds", "Values": instance_ids}]

        response = ssm.send_command(
            DocumentName="RemoveLocalADUser",
            Targets=targets,
            Parameters={
                "username": [username]
            },
            Comment=f"Revoking temporary SSH access for {username}"
        )
        return response["Command"]["CommandId"]
    except botocore.exceptions.ClientError as e:
        print(f"[ERROR] Failed to send revoke SSM command: {e.response['Error']['Message']}")
        sys.exit(1)
    except botocore.exceptions.BotoCoreError as e:
        print(f"[ERROR] General Boto3 error during revoke: {e}")
        sys.exit(1)

def grant_windows_ad_admin(instance_ids, username):
    if not instance_ids:
        print("[ERROR] No matching Windows instances found.")
        sys.exit(1)

    try:
        targets = [{"Key": "InstanceIds", "Values": instance_ids}]

        response = ssm.send_command(
            DocumentName="AddLocalAdminADUser",
            Targets=targets,
            Parameters={"username": [username]},
            Comment=f"Granting Windows local admin access to {username}"
        )
        return response["Command"]["CommandId"]
    except botocore.exceptions.ClientError as e:
        print(f"[ERROR] Failed to send Windows SSM command: {e.response['Error']['Message']}")
        sys.exit(1)
    except botocore.exceptions.BotoCoreError as e:
        print(f"[ERROR] General Boto3 error for Windows access: {e}")
        sys.exit(1)

def main():
    tag_key = os.getenv("JIT_TAG_KEY")
    tag_values = os.getenv("JIT_TAG_VALUES")
    user = os.getenv("USER")
    mode = os.getenv("JIT_ACTION", "grant")  # grant, revoke, windows

    if not tag_key or not tag_values or not user:
        print("[ERROR] Missing required environment variables: JIT_TAG_KEY, JIT_TAG_VALUES, JIT_USER_EMAIL")
        sys.exit(1)

    try:
        instance_ids = get_instance_ids_by_tag_values(tag_key, tag_values)

        if mode == "checkout":
            command_id = grant_windows_ad_admin(instance_ids, user)
            print(f"✅ Windows access granted via SSM. Command ID: {command_id}")
        elif mode == "checkin":
            command_id = revoke_temp_access(instance_ids, user)
            print(f"🧹 Windows access revoked via SSM. Command ID: {command_id}")
        else:
            print(f"[ERROR] Unknown JIT_MODE '{mode}'. Use 'checkout' or 'checkin'.")
            sys.exit(1)

    except Exception as e:
        print(f"[ERROR] Unexpected error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
