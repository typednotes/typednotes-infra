# Service network access

Access policy is a resource property in `Fleet.lean`, supported by Infra
**0.23.0**. Shared network/allowlist values live in `Fleet/Access.lean`.
There is no consumer-side networking reconciliation script or apply hook.

## Declared policy

- **App:** public at `https://app.typednotes.com`, attached to the internal
  network for service calls, with `httpsOnly := some true`.
- **Supporting containers:** vault, ledger, liaison, Lode, Lun and the direct
  DB inspector endpoint use `ScalewayAccess.internalOnly`; their public
  endpoints are disabled and native private endpoints are enabled.
- **DB admin ingress:** `operator-gateway` uses the official NGINX Alpine image
  and `proxyTo inspectorContainer operatorCidrs "/db-inspector/"`. Infra manages
  and reads back its actual enforcement/configuration. Basic auth, the read-only
  observer identity and locked pgweb session remain required.
- **Compute PostgreSQL:** `scalewayAccess` is private-only. The endpoint is
  provider-assigned through IPAM, and its composed URL uses `endpointOf computeDb`.
  No database IP is hard-coded in the declaration; PostgreSQL TLS is required.
- **Agreed exception:** `typednotes-db` and `secrets-db` retain their public,
  IAM-protected Serverless SQL endpoints. Scaleway has no private endpoint or
  IP allowlist for this product. Migration to classic PostgreSQL was deferred.

The current DB admin UI is:

https://typednotes642d16b8-operator-gateway.functions.fnc.fr-par.scw.cloud/db-inspector/

The existing network is `9dd55512-09f6-4e7a-a864-19c82f348ab8`, in dedicated VPC
`7e3ef8fa-1071-45fe-88f9-ec47245df1ba`, project
`b77ecf48-3340-4419-bbbd-098f972832fd`, `fr-par`. These prerequisite network
resources survive fleet teardown; Infra does not manage VPC lifecycle.
No VPN is needed. Service URLs come from the provider's observed native private
URL, including its scheme; vault clients extract the host and use private HTTP.

## Operator addresses

`operatorCidrs` records the IPv4/IPv6 workstation addresses observed during setup:

- `92.146.149.116/32`
- `2a01:cb04:31d:1d00:943a:f26b:7e49:b97f/128`
- `90.92.120.28/32`
- `2a01:cb04:1a6:4300:5cca:5ad4:bcac:b7fc/128`

Edit that list and use the normal plan/apply flow. Empty, malformed and
world-open proxy policies fail validation. The caller is never automatically
added; network changes and IPv6 privacy-address rotations need an explicit edit.

## Plan and apply

```sh
lake build
lake exe typednotes-infra check
lake exe typednotes-infra plan
lake script run apply --yes --refresh-secrets
```

`Main.lean` delegates directly to Infra. Native fields are included at resource
creation and compared on plan. Mutable endpoint changes re-materialise dependent
callers; `--refresh-secrets` updates connection recipes/copies after the new
endpoint is available. Unsafe custom-domain/trigger bypasses on private services
are refused. Proxy readback checks actual NGINX config, not just metadata.

The local `v0.23.0` release must be published before fresh CI runners can resolve
the pin. Until then, local verification uses that same committed/tagged revision
in the dependency checkout. Consumer changes do not publish the Infra release.

Compile-time fleet guards verify every container's access role, the admin
allowlist/backend/prefix, private compute DB policy, the Serverless SQL exception
and rollout ordering. Infra's own suite covers native readback/payloads, enforcement
drift, IP-header rules and endpoint-dependent refresh.

Live setup verification on 2026-10-11 confirmed direct supporting endpoints were
blocked, trusted admin ingress required basic auth, forged XFF from untrusted
egress was denied, and private PostgreSQL responded to TLS negotiation. Infra
0.23.0 read-only observation matched all eight deployed container policies and
the private compute database. The first normal apply will adopt the generated
proxy policy into Infra's managed readback format.
