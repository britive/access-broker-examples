#!/usr/bin/env python3

import os
import boto3
import sys
import json
import botocore.exceptions

ec2 = boto3.client("ec2", region_name="us-west-2")
ssm = boto3.client("ssm", region_name="us-west-2")


def process_username(username, domain="AD\\"):
    if isinstance(username, str) and "@" in username and "." in username.split("@")[-1]:
        email_prefix = username.split("@")[0]
        return domain + email_prefix
    else:
        return None  # Or keep the original value, depending on your use case


def get_instance_ids_by_tags(tag_filters):
    try:
        filters = []
        for tag_key, tag_values in tag_filters.items():
            if isinstance(tag_values, str):
                tag_values = [v.strip() for v in tag_values.split(",") if v.strip()]
            filters.append({"Name": f"tag:{tag_key}", "Values": tag_values})

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


def send_ssm_command(instance_ids, document_name, parameters, comment):
    try:
        targets = [{"Key": "InstanceIds", "Values": instance_ids}]
        response = ssm.send_command(
            DocumentName=document_name,
            Targets=targets,
            Parameters=parameters,
            Comment=comment,
        )
        return response["Command"]["CommandId"]
    except botocore.exceptions.ClientError as e:
        print(f"[ERROR] Failed to send SSM command: {e.response['Error']['Message']}")
        sys.exit(1)
    except botocore.exceptions.BotoCoreError as e:
        print(f"[ERROR] General Boto3 error: {e}")
        sys.exit(1)


def main():
    raw_tags = os.getenv("JIT_TAGS")
    domain = os.getenv("DOMAIN")
    user = process_username(username=os.getenv("USER"), domain=domain)
    mode = os.getenv("JIT_ACTION", "checkout")  # checkout or checkin

    if not raw_tags or not user:
        print("[ERROR] Missing required environment variables: JIT_TAGS and USER")
        sys.exit(1)

    try:
        try:
            parsed_tags = json.loads(raw_tags)
            tag_filters = {
                k: [v.strip() for v in v.split(",")] if isinstance(v, str) else v
                for k, v in parsed_tags.items()
            }
        except json.JSONDecodeError as e:
            print(f"[ERROR] Failed to parse JIT_TAGS JSON: {e}")
            sys.exit(1)

        instance_ids = get_instance_ids_by_tags(tag_filters)

        if not instance_ids:
            print("[ERROR] No matching instances found.")
            sys.exit(1)

        if mode == "checkout":
            command_id = send_ssm_command(
                instance_ids,
                document_name="AddLocalAdminADUser",
                parameters={"username": [user]},
                comment=f"Granting Windows local admin access to {user}",
            )
            print(f"✅ Windows access granted via SSM. Command ID: {command_id}")

        elif mode == "checkin":
            command_id = send_ssm_command(
                instance_ids,
                document_name="RemoveLocalADUser",
                parameters={"username": [user]},
                comment=f"Revoking temporary access for {user}",
            )
            print(f"🧹 Windows access revoked via SSM. Command ID: {command_id}")

        else:
            print(f"[ERROR] Unknown JIT_ACTION '{mode}'. Use 'checkout' or 'checkin'.")
            sys.exit(1)

    except Exception as e:
        print(f"[ERROR] Unexpected error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
