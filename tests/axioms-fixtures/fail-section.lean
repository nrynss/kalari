/-! Must FAIL `tools/axioms.sh`: the extractor tracks `namespace`/`end` but
not `section`, so a `section` fails closed instead of silently checking the
wrong names. -/

namespace AxiomsFixture

section
variable (n : Nat)

end AxiomsFixture
