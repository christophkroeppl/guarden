# srv

Home server compose stack with a static baseline (`traefik`, socket-proxy, apps) plus optional control-plane services.

## Dynamic deployments with Coolify (OSS)
This stack extends your baseline with **Coolify** (`coolify/compose.yaml`).

## VS Code dev server
This stack now includes a `code-server` deployment (`vscode/compose.yaml`) exposed through Traefik at:

- `https://${VSCODE_SUBDOMAIN}.${NAMECHEAP_DOMAIN__KROEPPL_ONLINE}`

Because VS Code server is published through Traefik, external access continues to use ports **80/443** only.

## Immich
This stack includes an Immich deployment (`immich/compose.yaml`) behind Traefik at:

- `https://${IMMICH_SUBDOMAIN}.${NAMECHEAP_DOMAIN__KROEPPL_ONLINE}`

## PhotoPrism
This stack includes a PhotoPrism deployment (`photoprism/compose.yaml`) behind Traefik at:

- `https://${PHOTOPRISM_SUBDOMAIN}.${NAMECHEAP_DOMAIN__KROEPPL_ONLINE}`
