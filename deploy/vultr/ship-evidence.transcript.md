# T6.4 ship transcript (sanitized)

Command run from the repository root on the laptop, SSH over the existing
Tailscale auth, no key passed, no spend:

```sh
./deploy/vultr/ship-evidence.sh
```

Output (counts and statuses only; no key, no secret, no address):

```text
== kalari: shipping 60 frozen benchmark records
== upload
== merge (preserve lesson-policy, replace shipped run ids)
store now holds: {'lesson-policy': 1, 'benchmark': 60}
== restart kalari-api
active
== verify on the VM (loopback API)
loopback ok: benchmark 60, runs 60/60 resolve
== verify from here (public demo URL)
public ok: benchmark 60, runs 60/60 resolve, kalari unknown windows 20/20 null, frozen pairs: ['payouts', 'settlements']
== cleanup upload
shipped 60 frozen benchmark records; live checks passed
```

The script was run twice. The second run printed the same store line
(`lesson-policy: 1, benchmark: 60`), proving the merge is idempotent:
previously shipped benchmark records are replaced by run id, never
duplicated.

Live judges render check (from the laptop, against the public demo URL,
using the shipped `web/site/app/views.mjs` itself):

- benchmark records: 60, run index entries: 61 (60 frozen runs plus the
  pre-existing lesson-policy provenance run).
- The judges view renders `The measured before and after`; the
  not-yet-published panel is gone.
- 61 distinct run links in the rendered page; every one returns 200 at
  `/api/runs/<id>`.
- The unknown retry windows render as `unknown`, never zero.
