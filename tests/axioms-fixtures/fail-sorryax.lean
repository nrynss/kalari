/-! Must FAIL `tools/axioms.sh`.

The `sorryAx` token is caught by the textual scan first (step 1b); the
per-declaration `#print axioms` check (step 2) stands behind it as
defense-in-depth against a `sorry` that text cannot name.
-/

namespace AxiomsFixture

theorem sneaky : False := sorryAx False

end AxiomsFixture
