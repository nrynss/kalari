/-! Positive control for the axioms gate (see tests/axioms-cases.sh).

Must PASS `tools/axioms.sh`: no placeholders, no custom postulates, no eval
lines, no elaboration-time runners. The anonymous `instance` below must appear
in the gate output as a generated `__axioms_instance_N` name with its own
report line: that is the proof anonymous instances are checked.
-/

namespace AxiomsFixture

theorem clean_add (n : Nat) : n + 0 = n := Nat.add_zero n

theorem clean_em (p : Prop) : p ∨ ¬p := Classical.em p

instance : Inhabited Nat where
  default := 0

instance namedCleanInst : Inhabited Bool where
  default := false

example : 1 + 1 = 2 := rfl

end AxiomsFixture
