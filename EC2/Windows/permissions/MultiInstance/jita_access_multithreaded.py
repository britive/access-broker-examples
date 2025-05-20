#!/usr/bin/env python3

import os
import boto3
import sys
import botocore.exceptions
from concurrent.futures import ThreadPoolExecutor, as_completed

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

def send_ssm_command(instance_id, document_name, parameters, comment):
    try:
        response = ssm.send_command(
            DocumentName=document_name,
            Targets=[{"Key": "InstanceIds", "Values": [instance_id]}],
            Parameters=parameters,
            Comment=comment
        )
        return instance_id, response["Command"]["CommandId"]
    except botocore.exceptions.ClientError as e:
        return instance_id, f"[ERROR] {e.response['Error']['Message']}"
    except botocore.exceptions.BotoCoreError as e:
        return instance_id, f"[ERROR] {e}"

def execute_multithreaded(document_name, instance_ids, parameters, comment):
    results = []
    with ThreadPoolExecutor(max_workers=10) as executor:
        future_to_instance = {
            executor.submit(send_ssm_command, instance_id, document_name, parameters, comment): instance_id
            for instance_id in instance_ids
        }
        for future in as_completed(future_to_instance):
            instance_id = future_to_instance[future]
            try:
                inst, result = future.result()
                results.append((inst, result))
            except Exception as e:
                results.append((instance_id, f"[ERROR] {e}"))
    return results

def main():
    tag_key = os.getenv("JIT_TAG_KEY")
    tag_values = os.getenv("JIT_TAG_VALUES")
    user = os.getenv("USER")
    mode = os.getenv("JIT_ACTION", "grant")  # grant, revoke, windows

    if not tag_key or not tag_values or not user:
        print("[ERROR] Missing required environment variables: JIT_TAG_KEY, JIT_TAG_VALUES, USER")
        sys.exit(1)

    try:
        instance_ids = get_instance_ids_by_tag_values(tag_key, tag_values)

        if not instance_ids:
            print("[ERROR] No matching instances found.")
            sys.exit(1)

        if mode == "checkout":
            results = execute_multithreaded(
                document_name="AddLocalAdminADUser",
                instance_ids=instance_ids,
                parameters={"username": [user]},
                comment=f"Granting Windows local admin access to {user}"
            )
            for inst, result in results:
                print(f"✅ {inst}: {result}")

        elif mode == "checkin":
            results = execute_multithreaded(
                document_name="RemoveLocalADUser",
                instance_ids=instance_ids,
                parameters={"username": [user]},
                comment=f"Revoking temporary SSH access for {user}"
            )
            for inst, result in results:
                print(f"🧹 {inst}: {result}")

        else:
            print(f"[ERROR] Unknown JIT_ACTION '{mode}'. Use 'checkout' or 'checkin'.")
            sys.exit(1)

    except Exception as e:
        print(f"[ERROR] Unexpected error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
