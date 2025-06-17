## Why not just rely on “normal” replication?

Normally, changes written to one DC replicate on their own within the intra‑site interval (15 seconds by default) or inter‑site interval (as high as 180 minutes). If you’re comfortable with that delay, you can simplify the script to a single New‑ADUser/Add‑ADGroupMember against any DC and let replication happen naturally. The version above is for scenarios where:
The on‑prem and cloud DCs are separated by slower links and you can’t wait for the scheduled replication window.
You want deterministic, low‑latency updates because another workflow (or the user) will hit the cloud DC almost immediately after checkout.

   Feel free to trim out the replication pieces if your SLA allows.
