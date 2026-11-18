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
`vaultEnvironment` derives host, front-door port and TLS together from that URL;
it does not substitute the vault executable's internal listener port.

## Operator addresses

The DB admin gateway's allowlist is operator-private data: the workstation
IPv4/IPv6 addresses are deliberately **not committed to this repository**,
which is public. The declaration (`Fleet/Access.lean`) carries only
`192.0.2.0/24` — RFC 5737 documentation space: bounded and valid, so it
passes every offline check, yet no real traffic can originate from it.

Real addresses are supplied at plan/apply time through `OPERATOR_CIDRS`,
a comma-separated list of bounded CIDRs:

```sh
export OPERATOR_CIDRS="203.0.113.7/32,2001:db8:1234::/64"
```

`Main.lean` validates the list and splices it into the gateway
(`withOperatorCidrs` in `Fleet.lean`). A full or `full-from-lite`
plan/apply without the variable is refused rather than closing the gateway
on the declared placeholder. In CI, `OPERATOR_CIDRS` is a repository secret
(`scripts/check-deployment-secrets.sh` lists it for the full topologies).
Network changes and IPv6 privacy-address rotations need an explicit update
of the secret or the exported variable; the caller is never added
automatically.

## Plan and apply

```sh
export TYPEDNOTES_DEPLOYMENT=full # independent original deployment
export OPERATOR_CIDRS="…"         # operator workstation CIDRs, comma-separated
lake build
lake exe typednotes-infra check
lake exe typednotes-infra plan
lake script run apply --yes --refresh-secrets
```

For a promoted installation use `full-from-lite` and a tested
`TYPEDNOTES_LITE_IMAGE` digest instead. CI uses the repository's persisted
`current` topology and image pin; see [promotion and later updates](lite.md#upgrade-lite-to-full-in-place).

`Main.lean` delegates reconciliation to Infra after its read-only topology
check for Lite commands. Native fields are included at resource
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
