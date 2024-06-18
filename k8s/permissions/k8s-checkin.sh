#!/bin/bash

kubectl delete rolebinding "$role-$user" --namespace $namespace --context $context
