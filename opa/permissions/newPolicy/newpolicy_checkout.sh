
echo "Checkout request processed for '$user' for '$host' with Role: '$role'. TransactionId: '$tid'" # Optional

# Write a policy definition
policy=$(cat <<EOF
package app.rbac

default allow = false

allow = true if{
    input.method == "GET"
    input.path = ["users", "$user"]
    input.user = "$user"
}
EOF
)

# Create a policy using a PUT request
curl -X PUT -H "Content-Type: text/plain" --data-binary "$policy" http://$host/v1/policies/$tid
