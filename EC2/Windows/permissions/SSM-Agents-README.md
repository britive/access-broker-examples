| Feature                            | EC2 Instances         | On-Prem Servers (Hybrid)      | Notes |
|------------------------------------|------------------------|-------------------------------|-------|
| SSM Agent                          | ✅ Pre-installed (Amazon Linux/Windows) | ⚠️ Manual install required       | RPM, DEB, or MSI packages |
| IAM Role Support                   | ✅ Instance Profile     | ⚠️ IAM Role via Activation      | No per-instance granularity for hybrid |
| Run Command                        | ✅ Yes                 | ✅ Yes                         | Supported equally |
| Session Manager                    | ✅ Yes                 | ✅ Yes                         | Requires internet or proxy for hybrid |
| Patch Manager                      | ✅ Yes                 | ✅ Yes                         | Supported for most OS types |
| Inventory Collection               | ✅ Yes                 | ✅ Yes                         | Same capability |
| State Manager                      | ✅ Yes                 | ✅ Yes                         | Fully supported |
| Automation Participation           | ✅ Full Support        | ⚠️ Partial                     | Only some automation steps like runCommand |
| Parameter Store Access             | ✅ Yes                 | ✅ Yes                         | Access tied to IAM role from activation |
| SSM Agent Auto-Update              | ✅ Automatic           | ❌ Manual                      | No auto-update for on-prem |
| CloudWatch Agent Integration       | ✅ Easy                | ⚠️ Manual Setup                | Install and configure separately |
| Maintenance Windows                | ✅ Yes                 | ✅ Yes                         | No difference |
| Compliance Reporting               | ✅ Yes                 | ✅ Yes                         | Based on patch/inventory/state |
| VPC Endpoint Support               | ✅ Native              | ❌ Not supported               | Needs internet/VPN for hybrid |
| Resource Tagging                   | ✅ Yes                 | ⚠️ Limited                     | Can tag on registration only |
| Logging (S3/CloudTrail/CloudWatch) | ✅ Native              | ✅ With setup                  | Requires IAM role and agent config |

