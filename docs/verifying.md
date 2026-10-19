# Verifying

Two checks, covering different things. Run both.

## Phase 30: does the platform work?

```bash
scripts/30-verify-maas.sh
scripts/30-verify-maas.sh --no-cleanup   # leave test resources behind
scripts/30-verify-maas.sh --cleanup-only # remove them later
```

Wraps the guide's six-phase `verify.sh`:

1. infrastructure health — Gateway, PostgreSQL, maas-api, maas-controller
2. deploys a simulator model plus its MaaS resources
3. API checks — health, API key creation, model listing, inference
4. auth enforcement — unauthenticated and bad-token requests are rejected
5. rate limiting — confirms 429s trigger
6. cleanup

**It deploys its own throwaway simulator and tests that.** So it proves the
MaaS platform is wired up correctly — not that the model you deployed serves
traffic.

## Phase 35: does *your* model work?

```bash
scripts/35-smoke-test.sh
scripts/35-smoke-test.sh --prompt "Write a haiku about etcd."
scripts/35-smoke-test.sh --model <model-id>
scripts/35-smoke-test.sh --keep-key      # keep the API key for your own calls
```

Exercises the real path, the same way a consumer would:

1. discovers your `MaaSSubscription`
2. mints an API key with your OpenShift token
3. lists models through the gateway
4. `POST /v1/chat/completions` with a real prompt
5. prints the completion and token usage
6. revokes the key

If the response looks like stub text it says so — the quickest way to catch a
silent simulator fallback.

## By hand

```bash
source bin/ocp-env.sh
export KUBECONFIG=clusters/rhoai/auth/kubeconfig

HOST="https://maas.$("$OC" get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
SUB=$("$OC" get maassubscription -A -o jsonpath='{.items[0].metadata.name}')

KEY=$(curl -sSk -X POST "$HOST/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $("$OC" whoami -t)" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"manual\",\"expiresIn\":\"1h\",\"subscription\":\"$SUB\"}" | jq -r .key)

# Take the model id from HERE. It is not the LLMInferenceService name.
MODEL=$(curl -sSk "$HOST/maas-api/v1/models" -H "Authorization: Bearer $KEY" | jq -r '.data[0].id')
echo "$MODEL"   # publishers/llm/models/granite-4-tiny-gpu

curl -sSk "$HOST/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg m "$MODEL" '{model:$m,messages:[{role:"user",content:"Hello"}]}')" \
  | jq -r '.choices[0].message.content'
```

### The model id is qualified, and the bare name 404s

On the body-based route, `model` must be the **fully qualified publisher
id** that `/maas-api/v1/models` reports in `.data[].id`:

```
{"model":"publishers/llm/models/granite-4-tiny-gpu"}   -> 200
{"model":"granite-4-tiny-gpu"}                         -> 404
```

The bare name is the `LLMInferenceService` name, and reading it off the
cluster is the natural wrong move. It 404s because the gateway's HTTPRoute
matches on a derived `X-Gateway-Model-Name:
publishers/llm/models/<name>` header; a bare name matches no rule.

Two things make this harder than it should be:

- **The advice does not transfer between routing modes.** On the legacy
  path-based route — `/llm/granite-4-tiny-gpu/v1/chat/completions` — the bare
  name *is* correct, because it is in the URL. Guidance written for one route
  is wrong for the other.
- **A successful response does not tell you what to send.** The 200 echoes the
  *served* name back, not the id you must use. Only `/v1/models` is
  authoritative.

Always resolve the id from `/maas-api/v1/models` rather than constructing it.
`scripts/35-smoke-test.sh` does exactly that — it never hardcodes a name.

## Deeper: the verify-guide skill

The guide ships a `verify-guide` skill, symlinked into `.claude/skills/`. On
top of `verify.sh` it runs 8 blind-spot regression checks distilled from
manual walkthroughs, and validates that the guide's own documented commands
still produce the documented output.

That last part matters if you are contributing fixes back upstream. It needs
an AI assistant; everything else here does not.

## Quick health check

```bash
"$OC" get nodes
"$OC" get clusterversion
"$OC" get co | grep -v 'True.*False.*False'   # any degraded operator
"$OC" get dsc,dsci -A
"$OC" get maasmodelref,maassubscription -A
"$OC" get gateway -n openshift-ingress
"$OC" get pods -n redhat-ai-gateway-infra
```
