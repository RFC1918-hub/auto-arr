# Cloudflare Tunnel

The optional `tunnel` profile runs a pinned Cloudflared connector on the `arr` network.
The connector requires no additional published ports or Windows port forwarding.
Cloudflare stores the ingress configuration for this remotely managed tunnel.

## EDITH routes

| Hostname | Docker origin | Authentication |
| --- | --- | --- |
| `requests.peakhq.co.za` | `http://jellyseerr:5055` | Cloudflare Access, then Seerr |
| `edith.peakhq.co.za` | `http://homepage:3000` | Cloudflare Access |

The Access policy permits only `pinortje@gmail.com` through email one-time PIN authentication.
Each route also requires a valid Access JWT at the connector.
The Homepage route sets the origin Host header to `localhost:3000`, an existing allowed host.
The final ingress rule returns HTTP 404.
Jellyfin and the arr administration interfaces have no routes through this connector.

## Connector setup

1. Retrieve the connector token for the EDITH tunnel from Cloudflare.
2. Store the token in `${CONFIG_ROOT}/cloudflared/token` on EDITH.
3. Set the token owner to UID and GID `65532`, the pinned image user.
4. Set the token file permissions to `0600`.
5. Start the connector from the repository directory:

```sh
docker compose --profile tunnel up -d cloudflared
```

The token is a Compose secret. Do not commit the token or pass it as a command argument.
The existing `config/` ignore rule excludes the default token location.
Docker restarts the connector after daemon restarts unless an operator stops it.
Run the profile command after a fresh deployment or a Cloudflared image update.

## Verification

```sh
docker compose --profile tunnel ps cloudflared
docker logs --tail 30 arr-cloudflared
curl -I https://requests.peakhq.co.za
curl -I https://edith.peakhq.co.za
```

Unauthenticated browser requests must redirect to Cloudflare Access.
After login, verify Seerr and Homepage in a browser.

## Rollback

Stop the connector:

```sh
docker compose --profile tunnel stop cloudflared
```

Remove only the EDITH DNS records and Access applications created for these routes.
Keep the existing Home Assistant tunnel and its DNS records.
