/-! Must FAIL `tools/axioms.sh`: only bare `#eval <ident>` lines may be
dropped from the elaborated copy, so anything else fails (step 1c). -/

namespace AxiomsFixture

def x : Nat := 1

#eval IO.println "hi"

end AxiomsFixture
