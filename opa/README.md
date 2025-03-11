# OPA policies with Britive broker

## Introduction

The Open Policy Agent (OPA) is an open-source, general-purpose policy engine. OPA has many use cases, but the use case relevant for PDP implementation is its ability to decouple authorization logic from an application. This is called policy decoupling. OPA is useful in implementing a PDP for several reasons.
Britive broker can help establish short-lived policy definition where you might want to limit access to protected resources and introduce zero-standing policies.

## Synopsis

Britive's resource management capabilities can help with managing OPA PDP policies. USers can be granted short-lived policies based on the Britive enforcement points. Within Britive, you can require approvals, an incident ticket, step-up verification among other constraints before creating a set policy required by the user.
The helpful scripts in this repository provide an easy work-able example of one such policies.

### New Policy

This example creates a new policy for the user upon access checkout. And removes the same policy upon manual check-in or at expiration of allocated access time.

**newpolicy_checkout.sh**
This shell script processes a checkout request for a user by dynamically generating and applying an authorization policy using Open Policy Agent (OPA). It logs the request details and sends the policy to an OPA server via a PUT request.

*Functionality*
Logs the request details, including the user, host, role, and transaction ID.
Constructs an OPA policy that grants access if the request method is GET, the request path matches the user’s identifier, and the request originates from the specified user.
Sends the generated policy to the OPA server as a plain-text payload using curl.

*Requirements*
Open Policy Agent (OPA) server must be running and accessible at the specified $host.
The script requires the variables $user, $host, $role, and $tid to be set before execution.

**newpolicy_checkin.sh**
This shell script deletes an existing policy from an Open Policy Agent (OPA) server using the provided transaction ID ($tid).

*Functionality*
Sends a DELETE request to the OPA server to remove the policy associated with the specified transaction ID.
Logs a confirmation message ("Done") upon successful execution.

*Requirements*
OPA server must be running and accessible at the specified $host.
The variable $tid must be set before executing the script.
