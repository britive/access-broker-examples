echo "Chekout request recieved for '$user' for '$host' with Role: '$role'. TransactionId: '$tid'"

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

curl -X PUT -H "Content-Type: text/plain" --data-binary "$policy" http://$host/v1/policies/$tid
