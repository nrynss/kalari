/-! Must FAIL `tools/axioms.sh`: elaboration-time runners other than the
covered `#eval` shape are not checked, so they fail (step 1d). -/

namespace AxiomsFixture

run_cmd do pure ()

end AxiomsFixture
