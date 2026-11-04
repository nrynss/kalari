# Kalari

**Rehearse every API upgrade in a contained arena, and learn from every fall.**

When an API your service depends on changes, a coding agent can write the migration. Kalari is what that agent plugs into so the migration can be trusted: it says what changed and what that touches, turns lessons from earlier upgrades into checks that must pass, runs the agent's code in a throwaway microVM it cannot escape, and records what broke so the next upgrade gets it right first time.

It works with the coding agent you already use, over MCP. The demo runs [OpenCode](https://github.com/anomalyco/opencode) on [Vultr](https://www.vultr.com/): Vultr Serverless Inference for every model call, and Microsandbox microVMs on a Vultr VM for every run.

> **Status:** entry for the Vultr: Agent Rush hackathon (lablab.ai), challenge "Blast Radius Zero", in development. Nothing below is implemented yet; see [`product.md`](product.md).

## Usage (planned)

```
kalari serve    # MCP tools for the coding agent, and the HTTP API the web app reads
```

The agent gets five tools: `what_changed`, `blast_radius`, `recall_lessons`, `run_in_sandbox` and `record_lesson`.

## The name

A *kalari* is the training arena of kalaripayattu, Kerala's martial art: often a pit dug into the ground, where moves are practised safely before they are used for real. The arena is the sandbox, its walls are the proved gate, and the training is the lessons. The supervisor inside each microVM is `kalari-aashaan`: the *aashaan* is the kalari's master, who watches each student practise and stops them before they hurt themselves.

## Built with

- [Lean 4](https://lean-lang.org/): Kalari's own executables, with the containment logic proved in the same code that ships.
- [Vimanam](https://github.com/noemaforge/vimanam) (Apache-2.0): what changed between two API versions, for OpenAPI, GraphQL and protobuf (2.1.0).
- [Lambo](https://github.com/nrynss/lambo): the memory of lessons across upgrades.
- [Microsandbox](https://github.com/superradcompany/microsandbox): the microVMs.

## Licence

MIT. See [`LICENSE`](LICENSE).
