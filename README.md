# srv

Home server compose stack with a static baseline (`traefik`, socket-proxy, apps) plus a dynamic deployment control-plane powered by Coolify.

## Dynamic deployments with Coolify (OSS)
This stack extends your baseline with **Coolify** (`coolify/compose.yaml`).

Why this matches your requirements:
- Open-source deployment platform (no cluster-heavy platform required).
- Handles dynamic app add/remove and branch deployments.
- Uses your existing Traefik setup for ingress.
- Supports GitHub-driven deployments and cancel/redeploy behavior via branch webhooks and build queue handling.
- Allows one shared DB server with separate per-environment databases managed through deployment hooks.

See `coolify/README.md` for the exact flow and setup.
