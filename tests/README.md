# Endpoint Test Script

Interactive script to test any Azure AI Foundry managed compute endpoint — no Terraform state required.

## test_endpoint_quick.py

One-command interactive test for AI Foundry Hub managed online endpoints.

```bash
uv run tests/test_endpoint_quick.py
```

### What it does

1. Choose how to connect:
   - **Option 1**: Paste the inference target URI directly (endpoint name auto-extracted from URI)
   - **Option 2**: Enter workspace details (subscription, RG, AI Foundry project, endpoint) → URI auto-resolved
2. **Payload format auto-detected** from the URI path:
   - `/v1/embeddings` → `{"input": [...]}`  (OpenAI-compatible)
   - `/v1/chat/completions` → `{"messages": [...]}`  (OpenAI-compatible)
   - `/score` → `{"input_data": {"input_string": [...]}}`  (legacy)
3. Choose input text — use built-in samples or type your own
4. Pick auth method: `[1] Key  [2] AAD  [3] AML Token`
5. **Auto-switches endpoint authMode** to match (e.g. selects AAD → sets authMode to `AADToken`)
6. **Auto-fetches credentials** — keys via SDK, AAD token via `DefaultAzureCredential`, AML token via SDK
7. **Publishes source IP** for Azure Monitor / App Insights log correlation
8. **Prints test report** — timestamp, source IP, model name, response time, request IDs, auth details
9. **Reports the model name** that served the embedding/inference task
10. **Offers to restore** original authMode after the test completes

### Key Concepts

**Inference Target URI** — Published by AI Foundry when a model is deployed:
```
https://<endpoint-name>.<region>.inference.ml.azure.com/v1/embeddings
```
The `<endpoint-name>` is auto-extracted from the URI subdomain.

**Workspace** = AI Foundry **Project** name (not the Hub). The project is the parent of the managed online endpoint.

### Prerequisites

```bash
# Option 1 — uv (recommended, faster startup, auto-installs deps)
curl -LsSf https://astral.sh/uv/install.sh | sh   # install uv (one-time)
az login                                            # or configure managed identity

# Option 2 — pip (traditional)
pip install -r requirements.txt   # azure-ai-ml, azure-identity, requests
az login
```

The script includes [PEP 723](https://peps.python.org/pep-0723/) inline metadata, so `uv run` automatically creates an ephemeral environment with the correct dependencies — no virtualenv or manual install needed.

### Important Notes

- **Workspace details are required** — the script needs them to switch authMode and fetch credentials.
- **AuthMode is changed on the live endpoint** — the script offers to restore the original mode after testing.
- Switching authMode takes ~30-60 seconds while Azure reprovisioning completes.

### Sample Session

```
==================================================
  Azure AI Foundry — Quick Endpoint Test
==================================================

  How do you want to connect?

  [1] Enter inference target URI directly
      (e.g. https://<endpoint-name>.<region>.inference.ml.azure.com/v1/embeddings)

  [2] Enter workspace details (subscription, RG, AI Foundry project, endpoint)
      -> inference URI will be resolved automatically via Azure ML SDK

  Choice (1/2): 1

  Inference Target URI: https://my-endpoint.australiaeast.inference.ml.azure.com/v1/embeddings
  Endpoint name (auto-detected): my-endpoint
  Payload format (auto-detected): embeddings

  Workspace details for Key/AML token auto-retrieval:

  Subscription ID  [e.g. 00000000-...]: 00000000-...
  Resource Group   [e.g. rg-my-project]: rg-my-project
  AI Foundry Project name [e.g. my-ai-project]: my-ai-project
--------------------------------------------------

Connecting to AI Foundry project workspace...
  Connected.

Resolving source IP for Azure log correlation...
  Source IP: <your-public-ip>

==================================================
  Select Authentication Method
==================================================
  [1] Key   — Endpoint primary/secondary key
  [2] AAD   — Azure AD (Entra ID) token
  [3] AML   — AML workspace token via SDK
==================================================

  Enter choice (1/2/3): 1

==================================================
  Configuring endpoint for: KEY auth
==================================================
  Current authMode : AADToken
  Target authMode  : Key
  Switching endpoint authMode to 'Key'...
  AuthMode switched to 'Key' successfully.

==================================================
  Fetching credentials for: KEY
==================================================

  Retrieving endpoint key via Azure ML SDK...
  Key (first 8 chars): abc12345...

  Calling endpoint: https://my-endpoint.australiaeast.inference.ml.azure.com/v1/embeddings
  Payload: 3 input string(s)

--- Response Body ---
{ "data": [ {"embedding": [0.0123, ...], "index": 0}, ... ] }
--- End ---

============================================================
  TEST REPORT
============================================================
  Timestamp      : 2026-03-25T10:30:00+00:00
  Source IP      : <your-public-ip>
  Endpoint       : my-endpoint
  Inference URI  : https://my-endpoint.australiaeast.inference.ml.azure.com/v1/embeddings
  Model Name     : thenlper-gte-base-15
  Auth Method    : KEY
  Auth Mode Set  : Key
  Input Count    : 3
  HTTP Status    : 200
  Response Time  : 1250.3 ms
  Request ID     : abc-def-123
  MS Request ID  : xyz-456
============================================================

  Use Source IP '<your-public-ip>' to filter Azure Monitor / App Insights logs.
  Use Request ID to trace this specific request in endpoint logs.
  Embedding task completed via model: thenlper-gte-base-15

  [PASS] Endpoint call succeeded.

  Original authMode was 'AADToken'.
  Restore to 'AADToken'? (Y/n): Y
  Restored authMode to 'AADToken'.
```
