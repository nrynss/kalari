/-! Example: a decision function with theorems about it, checked when the file builds.

The pattern for Kalari's gate: keep the decision a plain, total function over plain data,
then state what it guarantees as theorems. If a later edit breaks a guarantee, the build fails.
These are illustrations, not Kalari's real gate. -/

namespace Examples.Gate

/-- One action an agent asks to run in the sandbox. -/
structure Action where
  path : String          -- where it writes
  host : Option String   -- where it connects, if anywhere
  timeoutMs : Nat        -- the cap it asks for
  deriving Repr

def workspace : String := "/workspace/"
def allowedHosts : List String := ["api.example.test"]
def maxTimeoutMs : Nat := 120000

/-- The decision. Bool-valued so it can run, and so theorems can talk about it. -/
def allowed (a : Action) : Bool :=
  a.path.startsWith workspace &&
  (match a.host with
   | none => true
   | some h => allowedHosts.contains h) &&
  decide (a.timeoutMs ≤ maxTimeoutMs)

/-- Anything allowed writes inside the workspace. -/
theorem allowed_in_workspace (a : Action) (h : allowed a = true) :
    a.path.startsWith workspace = true := by
  simp only [allowed, Bool.and_eq_true] at h
  exact h.1.1

/-- Anything allowed is capped. -/
theorem allowed_capped (a : Action) (h : allowed a = true) : a.timeoutMs ≤ maxTimeoutMs := by
  simp only [allowed, Bool.and_eq_true, decide_eq_true_eq] at h
  exact h.2

/-- Anything allowed that connects, connects only to an allowlisted host. -/
theorem allowed_host (a : Action) (host : String) (hh : a.host = some host)
    (h : allowed a = true) : host ∈ allowedHosts := by
  simp only [allowed, Bool.and_eq_true, hh] at h
  exact List.contains_iff_mem.mp h.1.2

/-- A cap clamp, with its bound proved by `omega`. -/
def clampTimeout (requested : Nat) : Nat := min requested maxTimeoutMs

theorem clampTimeout_le (n : Nat) : clampTimeout n ≤ maxTimeoutMs := by
  unfold clampTimeout; omega

-- Concrete cases, checked at build time too.
#guard allowed { path := "/workspace/out.txt", host := none, timeoutMs := 1000 }
#guard !allowed { path := "/etc/passwd", host := none, timeoutMs := 1000 }
#guard !allowed { path := "/workspace/x", host := some "evil.test", timeoutMs := 1000 }
#guard !allowed { path := "/workspace/x", host := none, timeoutMs := 999999 }

end Examples.Gate
