import Kalari.Sandbox.Broker

/-! Live-test entry point for the broker proofs. They start Python brokers
and observers on loopback ports, so they stay out of `lake build`. Run from
the repository root (the probe scripts are `probe/*.py`):
`lake env lean --run tests/live/broker-proof.lean`. -/

def main : IO UInt32 := do
  try
    Kalari.Sandbox.Broker.brokerIsolation
    Kalari.Sandbox.Broker.brokerPayouts
    return 0
  catch e =>
    IO.eprintln s!"broker proof: {e}"
    return 1
