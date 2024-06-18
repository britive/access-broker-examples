#!/bin/bash

# Function to retrieve instance metadata using IMDSv2
get_instance_metadata() {
    local token=$(curl -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" -s http://169.254.169.254/latest/api/token)
    curl -H "X-aws-ec2-metadata-token: $token" -s http://169.254.169.254/latest/meta-data/tags/instance/Name
}

# Main script
main() {
    # Get instance ID
    instance_tag_name=$(get_instance_metadata)

    # Check if instance ID is retrieved successfully
    if [ -z "$instance_tag_name" ]; then
        echo "Failed to retrieve instance tag Name. Make sure script is running on an EC2 instance."
        exit 1
    fi

    # Create JSON output
    json_output=$(jq -n --arg instance_id "$instance_tag_name" '[{"name": $instance_id, "type": "Ubuntu Linux",  "labels": {"Tier": ["Application"], "Environment": ["Development"]}}]')

    echo "$json_output"
}

# Call main function
main