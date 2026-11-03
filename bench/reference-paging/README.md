# Reference run: a paging upgrade

**A check that the stack works, not a comparison.** It answered: can OpenCode 2 drive DeepSeek through `microsandbox-mcp` with the host shell denied, and what does a run cost? It was easy on purpose: the server's source sat in the workspace (the agent had to start it in its own sandbox), `API_CHANGES.md` spelled out how paging ends, and the prompt asked for the count. Its pass says nothing about Kalari against the baseline. The comparison's rules are in [`../README.md`](../README.md).

The B5 task (`dev-diary/research/coding-agent.md`): Vultr's reference setup (OpenCode 2 + `microsandbox-mcp` + DeepSeek V4.1 Flash) fixing a consumer whose API started paging.

- `repo/`: the workspace the agent gets. `api_v2.py` serves 2,431 items, 100 per page, with `next_page_token`; `import_items.py` is the v1 consumer, which exits 0 with "imported 100 items"; `API_CHANGES.md` describes v2; `opencode.jsonc` is the reference config (host shell, web and outside paths denied).
- `prompt.txt`: the task as given to the agent.
- `grader/grade.sh`: the hidden grader. A fresh `--no-net` microVM runs the agent's `import_items.py` against `api_v2.py` and checks 2,431 records, each exactly once. The agent never sees it.

On the VM, with the workspace committed first so `git diff` shows the agent's change:

```bash
cp -r bench/reference-paging ~/b5 && cd ~/b5/repo && git init -q && git add -A && git commit -qm "v1 consumer"
~/b5/grader/grade.sh                               # FAIL: 100 of 2,431
printf '%s\n' "$VULTR_INFERENCE_API_KEY" | ssh <user>@kalari 'read -r VULTR_INFERENCE_API_KEY; export VULTR_INFERENCE_API_KEY
  cd ~/b5/repo && timeout 840 opencode run --standalone --format json --auto --title b5-reference "$(cat ~/b5/prompt.txt)" > ~/b5/events.jsonl'
~/b5/grader/grade.sh                               # PASS: 2,431 of 2,431
git checkout import_items.py                       # reset for the next run
```

(`--standalone` was added after the measured run: without it, `opencode run` leaves a background daemon holding the key. See `dev-diary/research/coding-agent.md`.)

Measured result: pass on the first attempt, 30 s, 18 steps, 331,501 input and 4,383 output tokens (~$0.05).
