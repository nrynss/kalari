# Clef recordings (T0.5)

Clef's answers at `/v1/systemone` on benchmark cases, for the Clef client (T3.3) to replay. Recorded with `record.py` (the key is sent in a header and never written): each case has `<case>.request.json` and `<case>.response.json` (`status`, `ms`, `body`). `index.json` lists what a correct answer is and what came back.

| Case | Question | Correct | Clef |
|---|---|---|---|
| `failure-api-change-duplicates` | Why did this run fail? | api_change | api_change |
| `failure-api-change-hang` | | api_change | api_change |
| `failure-api-change-truncated` | | api_change | api_change |
| `failure-unrelated-bug` | | unrelated_bug | unrelated_bug |
| `failure-flaky` | | flaky | flaky |
| `failure-test-setup` | | test_setup | test_setup |
| `calls-changed-operation` | Does this code call the changed operation? (4 hits) | yes, no, no, yes | 0.969, 0.066, 0.008, 0.947 |
| `calls-changed-operation-graphql` | (2 hits) | yes, no | 0.980, 0.024 |
| `lesson-applies` | Does the lesson apply? (3 changes) | yes, no, yes | 0.980, 0.026, 0.973 |
| `over-length` | | 422 | `422 validation_error`: "the request takes 300140 tokens, more than the 262144 this model reads" |

All 9 answered correctly, ~1 s each. Several questions go in one request (up to 64). The over-length request body is elided in its recording (1.26 MB of repeated log lines).
