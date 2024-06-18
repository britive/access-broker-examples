#!/bin/bash

# Function to retrieve instance metadata using IMDSv2
get_instance_metadata() {
    local token=$(curl -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" -s http://169.254.169.254/latest/api/token)
    curl -H "X-aws-ec2-metadata-token: $token" -s http://169.254.169.254/latest/meta-data/tags/instance/Name
}

# Main script
main() {
    instance_tag_name=$(get_instance_metadata)
    echo "$instance_tag_name"
}

# Call main function
main