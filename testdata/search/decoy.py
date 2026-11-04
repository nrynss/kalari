# The v1 route is /v1/ledger and this comment is not a call.
def fetch(base_url):
    with urllib.request.urlopen(f"{base_url}/v1/ledger", timeout=30) as resp:
        return resp.read()

QUERY = "{ /v1/ledgerItems { id } }"
