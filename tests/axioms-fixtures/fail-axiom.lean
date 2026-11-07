/-! Must FAIL `tools/axioms.sh`: a custom `axiom` declaration fails textually
(step 1a). Unused axioms appear in no `#print axioms` report, so only the
text scan sees them. -/

namespace AxiomsFixture

axiom myAxiom : True

end AxiomsFixture
