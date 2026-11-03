# Vultr Serverless Inference

Base URL `https://api.vultrinference.com/v1`, `Authorization: Bearer <key>`. Required for every agent model call in the Blast Radius Zero challenge.

## Decided

| Job | Model ID | Why |
|---|---|---|
| Coding agent, both arms | `deepseek-v4.1-flash-1017` | The strongest model on the list (user's call); drives tool calls reliably (below). Fallback if it ever fails: `qwen3.8-27b` |
| Clef's three judgement calls | `clef` (`clef-flash` exists, less accurate) | Typed answers with probabilities; cost negligible |
| Lambo's embeddings | `qwen3-embedding-4b` | **BGE M3 isn't served** (below), and it keeps every model call on Vultr |

## Endpoints

| Endpoint | What matters |
|---|---|
| `POST /chat/completions` | OpenAI/OpenRouter shape. `tools`, `tool_choice` (forced and `allowed_tools`), strict `json_schema`, `seed`, `logprobs`. **`completion_tokens` includes reasoning**, billed as output: set `reasoning_effort` deliberately (`low`). `usage.prompt_tokens_details.cached_tokens` reports prefix-cache hits. Default output cap 32,768 |
| `POST /messages`, `POST /responses` | Also served. `/messages` (Anthropic shape) returned a valid DeepSeek `tool_use` with a thinking block |
| `POST /systemone` | Decisions in TypeSafe's System One format. Models `clef`, `clef-flash`. `state` plus up to 64 `questions`; `state` billed once; no output tokens. Over-length input is **refused with 422, not truncated** |
| `POST /embeddings` | OpenAI shape plus `input_type`; up to 2,048 inputs per request. `qwen3-embedding-4b` **rejects over-length input with a 400** (32,768-token context); `dimensions` truncates its 2560-wide output |
| `GET /models`, `GET /embeddings/models`, `GET /usage`, `GET /health` | IDs; per-model token counts this month and last; health |
| `POST /rerank` | Available (`bge-reranker-v2-m3`), not needed |

**Limits:** chat, embeddings and rerank 120 requests a minute and 16 at once; decisions 600 / 16. Over the concurrency limit a request waits up to 2 minutes, then 429 with `Retry-After: 5`. Requests time out after about 9 minutes (504). Retry 429 after `Retry-After`; 502, 503, 504 with backoff.

## Measured

**A1, model IDs.** `deepseek-v4.1-flash-1017`, `clef`, `clef-flash` present. `/embeddings/models` lists only `qwen3-embedding-4b`. `bge-m3` and `BAAI/bge-m3` return 404 "not found on any available cluster", although BGE M3 is on the console's price list. `/models` gives no context windows in `.context_length`.

**A2, DeepSeek tool calls.** Four requests (auto at `low` and `medium`, forced twice): every one `finish_reason: tool_calls`, one `run_in_sandbox` call, arguments valid JSON (forced runs also set `timeout_ms`). 348 prompt tokens; reasoning tokens 13 at `low`, 32 at `medium`. **From the second identical request, 256 of 348 prompt tokens were cached.**

**Clef's limit and accuracy (T0.5):** it reads **262,144 tokens**; over that, `422` `validation_error` with both counts in the message. On nine benchmark cases (six failure causes, six code hits, three lesson checks) every answer was right, ~1 s a request: recordings in `testdata/clef/`.

**A3, Clef's answer shape** (not in the docs):

```json
{"model": "clef",
 "answers": {
   "failure_cause": {"type": "choice", "choice": "api_change",
                     "probabilities": {"api_change": 0.967, "test_setup": 0.005, "flaky": 0.005, "unrelated_bug": 0.023},
                     "confidence": 0.956},
   "calls_changed_operation": {"type": "noul", "noul": 0.973},
   "lesson_applies": {"type": "noul", "noul": 0.981}},
 "usage": {"input_tokens": 485, "output_tokens": 0}}
```

`choice` questions take `instructions` and `criteria` (option → description); `noul` is yes/no and returns the probability of yes, with no confidence.

**A4, embeddings.** `qwen3-embedding-4b` returns 2560 dimensions; with `"dimensions": 1024`, 1024 (unit norm). Lambo 0.8.0's adapter sends only `model` and `input`, so Lambo runs at 2560.

**A5, spend.** `/v1/usage` reports token counts per model only, **no dollar amounts**, and counts cached tokens as input (4 × 348 = 1,392). Whether cached input is discounted can't be seen there: check the console's billing page. Part A cost under $0.01.

## Prices (console, per 1M tokens, input / output)

| Model | In | Out |
|---|---|---|
| DeepSeek V4.1 Flash 1017 | $0.15 | $0.60 |
| GLM 5.3 | $0.75 | $3.00 |
| GLM 5.3 Flash | $0.10 | $0.35 |
| MiMo V2.6 Pro | $0.40 | $0.80 |
| Qwen 3.8 27B | $0.15 | $1.00 |
| Clef / Clef Flash | $0.10 / $0.05 | — |
| Qwen 3 Embedding 4B | $0.05 | — |

Per token, no subscription, no included allowance.

## Budget, measured

The reference run (OpenCode 2, a small paging upgrade, see `coding-agent.md`): **331,501 input and 4,383 output tokens over 18 steps, about $0.05 at list price**, 91% of input from cache. Budget real upgrades at ~$0.25 a run until the demo APIs are measured: ~$13 for a 50-run comparison, ~$40 with development. With the VM (~$55 to the credit's expiry), about $100 of the $205 credit.

## Reproduce

```bash
V=https://api.vultrinference.com/v1; AUTH="Authorization: Bearer $VULTR_INFERENCE_API_KEY"
curl -s $V/models -H "$AUTH" | jq -r '.data[].id' | sort
curl -s $V/embeddings/models -H "$AUTH" | jq -c '.data[] | {id, context_length}'
curl -s $V/usage -H "$AUTH" | jq '.usage.current_month.chat_usage'
```

The A2 tool-call requests, the A3 Clef request and the A4 embeddings request are in `commands.md`.
