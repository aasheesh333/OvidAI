# caddy-flips — DOCUMENTATION ONLY, never auto-applied
#
# These snippets are the per-route-group cutover from the Python/legacy
# services to the cloud services. The executable procedure (timestamped
# backup, `caddy validate`, `caddy reload`, smokes, rollback) is
# ../DECOMMISSION.md §1. Apply them BY HAND, in numeric order, with the owner
# present. Nothing in this directory runs automatically and no file here may
# be executed against the live box by CI.
#
# Target correction: the plan text says "gateway 8081", but 8081 is Caddy's
# own admin-dashboard listener on this box. The cloud gateway is
# 127.0.0.1:${GATEWAY_HOST_PORT:-8082}; the TS mint is 127.0.0.1:8091.
#
# Files:
#   1-account.conf  @account group → gateway 8082 (and delete sync/chat per Q1)
#   2-reports.conf  NEW exact /v1/reports → gateway 8082 (ahead of @api)
#   3-billing.conf  NEW /billing/* → mint 8091
#   4-images.conf   @images (/v1/images/*, /v1/models) → mint 8091
#   5-mint.conf     @mint/@usage/healthz/upgrade → mint 8091 (LAST)
