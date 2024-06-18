#!/bin/bash

kubectl create rolebinding "$role-$user" --role $role --user $user --namespace $namespace --context $context


echo "$user can now use permissions of the role $role in $namespace namesapce"
