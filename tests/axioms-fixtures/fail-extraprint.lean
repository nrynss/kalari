/-! Must FAIL `tools/axioms.sh`: a hand-written `#print axioms` line would
add an axioms report the gate did not ask for, so the report-count check
fails (unexpected extra output). The count makes the declaration-to-report
correspondence exact. -/

namespace AxiomsFixture

def x : Nat := 1

#print axioms Nat.zero

end AxiomsFixture
