# Items API v2

- `GET /items` now returns at most 100 items per response: `{"items": [...], "next_page_token": "..."}`.
- Pass `?page_token=<next_page_token>` to get the next page. The last page has no `next_page_token`.
- v1 returned every item in one response. v1 is retired; `api_v2.py` is the server.
