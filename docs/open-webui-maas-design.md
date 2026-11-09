# Open WebUI talking to MaaS models directly: design

Design only. Nothing here is implemented, and no policy has changed.

Today each Open WebUI user reaches exactly one model, `hermes-agent`, through
one shared Hermes API key (the `open-webui` policy copies
`hermes/hermes-api-key` into `open-webui/open-webui-hermes`). Hermes in turn
calls the MaaS gateway with its own key, owned by its ServiceAccount. As far as
MaaS can tell, every person's chat is one user: `system:serviceaccount:hermes:hermes-agent`.

This page sets out the ways users could also chat with MaaS models directly,
ideally with a MaaS key per person so that quota and audit are per person. The
recommendation is kept separate, at the end.

Checked against Open WebUI v0.12.5 (the deployed image, code read in the pod),
RHOAI 3.5.2 MaaS on sandbox141, and the RHOAI 3.5 book
[Govern LLM access with Models-as-a-Service][maas-book] (cited as "MaaS book").

## What the platform gives us

### MaaS: the quota follows the key's owner, not the key

The generated `TokenRateLimitPolicy` (`llm/maas-trlp-granite-4-tiny-gpu` on
sandbox141) counts tokens per **subscription and user**:

```yaml
counters:
  - expression: auth.identity.selected_subscription_key
  - expression: auth.identity.userid
rates:
  - limit: 300000
    window: 1m
```

As a result:

- Every key one identity owns shares that identity's 300k tokens per minute.
  Minting more keys as the same identity adds no quota.
- A key shared by many people gives all of them one user's quota, and the
  gateway, the maas-api key list and the dashboard all attribute every request
  to that one owner.
- Per-person quota and audit therefore need **a key owned by each person**, not
  merely a key per person.

Access is checked on every request, not only at minting: "a valid API key or
OIDC token, an active subscription, and an authorized group are required to
access a model" (MaaS book, 1.15.1). Removing a person from the subscription's
group cuts them off even while their key is unexpired.

How a person gets a key of their own, today:

- **Self-service:** Gen AI studio → API keys in the dashboard, or a temporary
  1-hour key from the Endpoints dialog (MaaS book, 2.2.1 and 2.2.4).
- **An administrator, on their behalf:** "Create an API key for a user"
  (MaaS book, 1.16.2). The book documents only the dashboard for this. Whether
  maas-api exposes an owner field for it is unverified.
- **Programmatically:** `POST /maas-api/v1/api-keys` with that person's own
  OpenShift token. This is what Hermes does with its ServiceAccount token.
  Keys are capped at 2160h.

The gateway serves the OpenAI model list at `https://maas.<domain>/v1/models`
(HTTP 200 on sandbox141; ids are the qualified form
`publishers/llm/models/granite-4-tiny-gpu`), so `https://maas.<domain>/v1` works
as an Open WebUI connection URL as it stands.

### Open WebUI: what it can do per user, and what it cannot

| Feature | Setting | What it does here |
|---|---|---|
| Several OpenAI connections | `OPENAI_API_BASE_URLS` / `OPENAI_API_KEYS`, `;`-separated | One key per connection, used by the **server** for every user. Hermes and MaaS can sit side by side. |
| Connection auth type `bearer` | per connection, admin UI or config | The connection's fixed key. |
| Auth type `session` | per connection | Sends Open WebUI's own session JWT. MaaS cannot validate it. |
| Auth type `system_oauth` | per connection | Sends the user's access token **from Open WebUI's own OAuth login** (`utils/headers.py`, `get_system_oauth_token` in `utils/oauth.py`). With our trusted-header sign-in there is no such session, so it sends nothing. |
| Forward user headers | `ENABLE_FORWARD_USER_INFO_HEADERS=true` | Adds `X-OpenWebUI-User-Name`, `-Id`, `-Email`, `-Role` (and `-Chat-Id`) to calls to a connection. With `FORWARD_USER_INFO_HEADER_JWT_SECRET` set, it sends one signed HS256 JWT (`X-OpenWebUI-User-Jwt`, 300 s lifetime) instead, which a backend can verify. |
| Direct connections | `ENABLE_DIRECT_CONNECTIONS=true` | Each user adds their own URL and key in Settings → Connections. The **browser** makes the request: the server hands it to the client over the WebSocket (`generate_direct_chat_completion` in `utils/chat.py`). The key stays in the browser. |
| Functions (Pipe) | admin-uploaded Python | Runs in the Open WebUI process with the calling user's identity (`__user__`). It could pick or fetch a key per user. |
| Per-user server-side connections | none | There is no server-side store for a key per user. |

One operational trap applies to every option that adds a connection: Open
WebUI's `PersistentConfig` applies `OPENAI_API_*` only on first start, after
which the database wins. Adding a connection to the existing deployment needs
either the admin UI, or `ENABLE_PERSISTENT_CONFIG=False` (config.py) so the
environment is authoritative. The `open-webui` policy would have to pick one.

### oauth-proxy can hand the user's token on

`openshift/oauth-proxy` with `--pass-access-token` adds the signed-in user's
OpenShift OAuth token to every upstream request as `X-Forwarded-Access-Token`.
The proxy currently requests `scope=user:info user:check-access` (visible in
the authorize redirect). Whether maas-api accepts a token **with that scope**
for `POST /v1/api-keys` is not known. It authenticates with a TokenReview,
which should succeed for scoped tokens, but any authorization check made with the
token would be limited by the scope. A broader scope (`user:full`) would work,
but it hands a full-power user token to whatever sits behind the proxy.

## Options

### A. One shared MaaS connection

Add MaaS as a second connection next to Hermes, with one key minted by an
`open-webui` ServiceAccount and renewed the way Hermes renews its key (the
bootstrap pattern already in the fork).

- Users get the MaaS models in the model picker next to `hermes-agent`.
  Open WebUI's per-model access control (model visibility per group) decides
  who sees which model.
- **Loses per-person quota:** all users share the ServiceAccount's 300k tokens
  per minute, and one heavy user throttles everyone, Hermes excluded (Hermes
  has its own owner).
- **Loses per-person audit at MaaS:** every request is the ServiceAccount.
  Open WebUI's own chat history remains a per-user record, but it is held in
  Open WebUI and is editable by its administrators.
- MaaS side: `system:serviceaccounts:open-webui` must be added to the model's
  `accessGroups` and to the subscription's owner groups, as was done for
  Hermes.
- Security: the key never reaches a browser. Every Open WebUI user can use
  it, and an Open WebUI administrator can read it in the connection settings.
- FIPS: nothing new. No new image; the request is made by Open WebUI's server,
  already the case for Hermes.
- Effort: small. The minting and renewal code exists.

### B. Direct connections with each user's own key

Turn on `ENABLE_DIRECT_CONNECTIONS`. Each person creates a key in Gen AI
studio → API keys and adds `https://maas.<domain>/v1` with it in Settings →
Connections.

- Per-person quota and audit, natively: each key is owned by its user.
- **Does not work today.** The browser calls the gateway cross-origin, and the
  gateway has no CORS: a preflight from the Open WebUI origin returns HTTP 401
  on the model path and 404 on `/v1/chat/completions`, with no
  `Access-Control-Allow-*` headers. Fixing that means CORS on the MaaS
  Gateway and an `OPTIONS` exemption in `maas-gateway-auth`, both owned and
  reconciled by the MaaS controller. We must not author competing policies
  there (the same rule as in [model-guardrails-design.md](model-guardrails-design.md)).
- Security: the key sits in the browser's storage, outside the cluster's
  control. Each user handles expiry (at most 90 days) by hand.
- FIPS: nothing server-side. The TLS client is the user's browser.

### C. A key broker: per-user keys minted automatically

A small service in the `open-webui` namespace, with two jobs:

1. **Capture.** It sits between oauth-proxy and Open WebUI. oauth-proxy runs
   with `--pass-access-token`. When the broker sees a user with no valid stored
   key, it calls `POST /maas-api/v1/api-keys` with that user's
   `X-Forwarded-Access-Token`, so the key is **owned by that user**. It stores
   the key, renews it inside a window as Hermes does, and strips the token
   header before passing the request on.
2. **Serve.** Open WebUI gets a connection "MaaS" whose URL is the broker, with
   `ENABLE_FORWARD_USER_INFO_HEADERS=true` and
   `FORWARD_USER_INFO_HEADER_JWT_SECRET` set. The broker verifies the signed
   user JWT, swaps in that user's MaaS key, and forwards to the gateway. A
   NetworkPolicy admits only the Open WebUI pod.

- Per-person quota and audit at MaaS, with group membership checked per person
  on every request (non-members get 403, not someone else's quota).
- **Unknown that decides feasibility:** whether maas-api mints for a
  `user:info user:check-access` token. If it needs `user:full`, the broker
  receives every user's full-power token, which is a much larger risk than the
  benefit.
  - A variant avoids user tokens altogether: an administrator's identity mints
    keys **on behalf of** users, as the dashboard does (MaaS book, 1.16.2).
    That needs a maas-api owner field, which is unverified, and it gives the
    broker administrator minting power.
- Security: the broker holds every user's key. It is a new credential store,
  and new code to review, own and patch. A key is minted only after the user
  has signed in, and revoking group membership takes effect at the gateway at
  once.
- FIPS: a new image. Build it on UBI with RHEL's OpenSSL. HMAC-SHA256 (the
  JWT) and TLS through RHEL crypto are both FIPS-approved. Open WebUI's side of
  the JWT is signed by its Debian Python, as all its crypto is today.
- Effort: a real component, delivered as a third container or Deployment in the
  `open-webui` policy.

### D. A Pipe function that fetches a key per user

The same broker logic, written as an Open WebUI Function. It has no user token
to mint with under trusted-header sign-in, so it reduces to C's admin variant.
Its code and the keys it stores live in Open WebUI's database, uploaded through
the admin UI, so neither can be delivered or reviewed through Git. Not pursued.

### E. Open WebUI's own OAuth login, with `system_oauth`

Replace the oauth-proxy with Open WebUI's native OIDC sign-in, so that a
connection with `auth_type: system_oauth` can forward each user's token.

- The OpenShift OAuth server is not an OIDC provider, so this needs an external
  OIDC identity provider (for example Red Hat build of Keycloak, or OpenShift
  external OIDC authentication). That is a cluster-wide change.
- Even then, MaaS accepts OIDC tokens for **minting** keys, while "you must use
  an API key to access models" (MaaS book, 1.19.1.1 and 2.2.1). A forwarded
  token is probably refused for inference, so this still ends up needing C.
- FIPS: depends on the IdP. Red Hat build of Keycloak supports FIPS mode.

## Summary

| | Per-person quota | Per-person MaaS audit | Works today | New code | Key exposure |
|---|---|---|---|---|---|
| A. Shared connection | no | no | yes | renewal reuse | Open WebUI admins |
| B. Direct connections | yes | yes | **no** (no CORS on the gateway) | none | user's browser |
| C. Key broker | yes | yes | needs a spike | a service | broker store |
| D. Pipe function | yes | yes | reduces to C | in Open WebUI DB | Open WebUI DB |
| E. Native OIDC | yes | yes | no (needs an IdP, and C) | IdP | IdP tokens |

## Recommendation

1. **Ship A now.** It gives every user the MaaS models next to Hermes with a
   small change to the `open-webui` policy, reusing Hermes' minting and
   renewal. Accept a shared quota: 300k tokens per minute is ample for a
   handful of people, and Open WebUI's chat history is the per-user record in
   the meantime. Decide `ENABLE_PERSISTENT_CONFIG` as part of it.
2. **Spike C before building it**, by answering two questions on sandbox141:
   - Does `POST /maas-api/v1/api-keys` accept a `user:info user:check-access`
     scoped OAuth token? Test it by running oauth-proxy with
     `--pass-access-token` and calling maas-api with the forwarded token.
   - Can an administrator mint a key owned by another user through maas-api,
     as the dashboard does?

   If the first answer is yes, build C with user-owned keys. If only the second
   is yes, weigh the broker holding administrator minting power before
   building. If neither, per-person keys wait for RHOAI.
3. **Do not pursue B** unless RHOAI adds CORS to the MaaS gateway. **Do not
   pursue D.** **Pursue E only** if an external IdP is wanted for other
   reasons.

[maas-book]: https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/govern_llm_access_with_models-as-a-service/index
