# Trim to get just the username before the @
username="${user%@*}"

if [ "$action" = "checkout" ]; then
  echo "Adding user $username to instance $instance"

  # Generates a 12-character complex password
  password=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*()-_=+[]{}' < /dev/urandom | head -c12)
  echo "Generated password: $password"

  # Create the user and set the password
  aws ssm send-command \
  --document-name "AddLocalAdminADUser" \
  --targets "Key=InstanceIds,Values='$instance'" \
  --parameters '{"username":["'$username'"]}' \
  > /dev/null
else
  echo "Removing user $username from instance $instance" 
  aws ssm send-command \
  --document-name "RemoveLocalADUser" \
  --targets "Key=InstanceIds,Values='$instance'" \
  --parameters '{"username":["'$username'"]}'
fi