/-! Must FAIL `tools/axioms.sh`: the `sorry` token fails textually (step 1b),
anywhere in the file. -/

namespace AxiomsFixture

def bad_add (n : Nat) : Nat := sorry

end AxiomsFixture
