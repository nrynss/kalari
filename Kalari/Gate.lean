import Kalari.Model

/-! The decision every sandbox run passes before a backend.

`decide` is pure: it reads no environment and does no IO. `(true, none)` allows
the run. `(false, some reason)` refuses it. The reason names the rule:
`workspace`, `allowlist`, `caps`, `secret`, or `key-shape`. -/

namespace Kalari.Gate

open Kalari.Model

/-- A path segment that is not empty, `.`, or `..`. -/
def segmentOk (seg : String) : Bool :=
  seg != "" && seg != "." && seg != ".."

/-- Segments after a leading `/`.

`splitOn "/"` turns that slash into a leading empty string. That empty string
is the root marker, not a path segment: counting it would refuse `/workspace`.
A string that does not start with `/` has no absolute segments. -/
def absSegments (s : String) : List String :=
  if s.startsWith "/" then (s.splitOn "/").drop 1 else []

/-- Absolute, and no segment is empty, `.`, or `..`. -/
def workspaceOk (w : String) : Bool :=
  w.startsWith "/" && (absSegments w).all segmentOk

/-- `true` when `path` is `workspace`, or `workspace` plus `/` plus a relative
path whose segments are not empty, `.`, or `..`.

The slash is the segment boundary: `/workspace` does not contain
`/workspace-evil`. The remainder is relative, so a double slash stays an empty
segment instead of being dropped with the root marker. -/
def insideWorkspace (workspace path : String) : Bool :=
  if path == workspace then
    true
  else
    match path.dropPrefix? (workspace ++ "/") with
    | none => false
    | some rest => (rest.toString.splitOn "/").all segmentOk

/-- An argument that starts with `/`, or that contains `..`, is a write path and
must sit inside the workspace. A relative argument with no `..` is not one:
the program name is relative, and the sandbox resolves it. -/
def commandInside (workspace : String) (command : List String) : Bool :=
  command.all fun arg =>
    !(arg.startsWith "/" || arg.contains "..") || insideWorkspace workspace arg

/-- `true` when `allowed` has an entry with this host and this port. A string
prefix of a host is not a match. -/
def hostListed (allowed : List AllowHost) (host : AllowHost) : Bool :=
  allowed.any fun a => a.host == host.host && a.port == host.port

/-- Every requested host and port is in `allowed`. An empty request connects
nowhere, and that is allowed. -/
def netOk (asked allowed : List AllowHost) : Bool :=
  asked.all (hostListed allowed)

/-- All three caps are within the configured maximum. `≤`, so the maximum itself
is allowed. -/
def capsOk (requested maximum : Caps) : Bool :=
  Decidable.decide (requested.timeout_ms ≤ maximum.timeout_ms) &&
    Decidable.decide (requested.output_cap_bytes ≤ maximum.output_cap_bytes) &&
    Decidable.decide (requested.memory_mib ≤ maximum.memory_mib)

/-- No non-empty secret is a substring of `haystack`.

An empty secret is ignored. `String.contains` of the empty pattern is true for
every string, so the empty check has to come first. -/
def freeOf (haystack : String) (secrets : List String) : Bool :=
  secrets.all fun s => s == "" || !(haystack.contains s)

/-- The workspace, every command argument, and every allowlist host are free of
non-empty secrets. -/
def secretsOk (req : RunRequest) (secrets : List String) : Bool :=
  freeOf req.workspace secrets &&
    req.command.all (fun arg => freeOf arg secrets) &&
    req.allowlist.all (fun host => freeOf host.host secrets)

/-- `true` when `s` has `n` ASCII letters or digits in a row.

`Char.isAlphanum` is ASCII. A character outside that set ends the run. -/
def hasAlnumRun (s : String) (n : Nat) : Bool :=
  (s.foldl (fun (st : Bool × Nat) c =>
    if st.1 then
      st
    else if c.isAlphanum then
      let k := st.2 + 1
      (Decidable.decide (k ≥ n), k)
    else
      (false, 0)) (false, 0)).1

/-- No workspace, command argument, or allowlist host contains 32 ASCII letters
or digits in a row. -/
def keyShapeOk (req : RunRequest) : Bool :=
  !hasAlnumRun req.workspace 32 &&
    req.command.all (fun arg => !hasAlnumRun arg 32) &&
    req.allowlist.all (fun host => !hasAlnumRun host.host 32)

private def passes (req : RunRequest) (maxCaps : Caps) (allowedNet : List AllowHost)
    (secrets : List String) : Bool :=
  workspaceOk req.workspace &&
    commandInside req.workspace req.command &&
    netOk req.allowlist allowedNet &&
    capsOk req.caps maxCaps &&
    secretsOk req secrets &&
    keyShapeOk req

private def refusal (req : RunRequest) (maxCaps : Caps) (allowedNet : List AllowHost)
    (secrets : List String) : String :=
  if !workspaceOk req.workspace || !commandInside req.workspace req.command then
    "workspace"
  else if !netOk req.allowlist allowedNet then
    "allowlist"
  else if !capsOk req.caps maxCaps then
    "caps"
  else if !secretsOk req secrets then
    "secret"
  else
    "key-shape"

/-- Allow or refuse one sandbox run. `true` with `none` allows it. A refusal
names the first rule that failed. -/
def decide (req : RunRequest) (maxCaps : Caps) (allowedNet : List AllowHost)
    (secrets : List String) : Bool × Option String :=
  (passes req maxCaps allowedNet secrets,
    if passes req maxCaps allowedNet secrets then
      none
    else
      some (refusal req maxCaps allowedNet secrets))

private theorem passes_parts (req : RunRequest) (maxCaps : Caps) (allowedNet : List AllowHost)
    (secrets : List String) (h : (decide req maxCaps allowedNet secrets).1 = true) :
    ((((workspaceOk req.workspace = true ∧ commandInside req.workspace req.command = true) ∧
            netOk req.allowlist allowedNet = true) ∧
          capsOk req.caps maxCaps = true) ∧
        secretsOk req secrets = true) ∧
      keyShapeOk req = true := by
  have hp : passes req maxCaps allowedNet secrets = true := by
    unfold decide at h
    exact h
  simpa only [passes, Bool.and_eq_true] using hp

private theorem workspace_spec (w : String) (h : workspaceOk w = true) :
    w.startsWith "/" = true ∧
      ∀ seg ∈ absSegments w, seg ≠ "" ∧ seg ≠ "." ∧ seg ≠ ".." := by
  simp only [workspaceOk, Bool.and_eq_true] at h
  refine ⟨h.1, ?_⟩
  intro seg hmem
  have hok : segmentOk seg = true := (List.all_eq_true.mp h.2) seg hmem
  simp only [segmentOk, Bool.and_eq_true, bne_iff_ne] at hok
  exact ⟨hok.1.1, hok.1.2, hok.2⟩

private theorem command_spec (workspace : String) (command : List String)
    (h : commandInside workspace command = true) :
    ∀ arg ∈ command,
      (arg.startsWith "/" = true ∨ arg.contains ".." = true) →
        insideWorkspace workspace arg = true := by
  intro arg hmem hwrite
  have harg := (List.all_eq_true.mp h) arg hmem
  simp only [Bool.or_eq_true, Bool.not_eq_true'] at harg
  have hw : (arg.startsWith "/" || arg.contains "..") = true := by
    simpa only [Bool.or_eq_true] using hwrite
  cases harg with
  | inl hf =>
      rw [hw] at hf
      cases hf
  | inr hin => exact hin

private theorem hostListed_mem (allowed : List AllowHost) (host : AllowHost)
    (h : hostListed allowed host = true) :
    ∃ a ∈ allowed, a.host = host.host ∧ a.port = host.port := by
  simp only [hostListed, List.any_eq_true, Bool.and_eq_true, beq_iff_eq] at h
  exact h

private theorem freeOf_spec (haystack : String) (secrets : List String)
    (h : freeOf haystack secrets = true) (secret : String) (hmem : secret ∈ secrets)
    (hne : secret ≠ "") : haystack.contains secret = false := by
  have hf := (List.all_eq_true.mp h) secret hmem
  simp only [Bool.or_eq_true, Bool.not_eq_true'] at hf
  cases hf with
  | inl he => exact absurd (beq_iff_eq.mp he) hne
  | inr hc => exact hc

/-- Anything allowed has an absolute workspace with no empty, `.`, or `..`
segment, and every command argument that is absolute or contains `..` is inside
that workspace on a segment boundary. -/
theorem decide_workspace (req : RunRequest) (maxCaps : Caps) (allowedNet : List AllowHost)
    (secrets : List String) (h : (decide req maxCaps allowedNet secrets).1 = true) :
    req.workspace.startsWith "/" = true ∧
      (∀ seg ∈ absSegments req.workspace, seg ≠ "" ∧ seg ≠ "." ∧ seg ≠ "..") ∧
      (∀ arg ∈ req.command,
        (arg.startsWith "/" = true ∨ arg.contains ".." = true) →
          insideWorkspace req.workspace arg = true) := by
  obtain ⟨⟨⟨⟨⟨hws, hcmd⟩, _⟩, _⟩, _⟩, _⟩ := passes_parts req maxCaps allowedNet secrets h
  have hw := workspace_spec req.workspace hws
  exact ⟨hw.1, hw.2, command_spec req.workspace req.command hcmd⟩

/-- Anything allowed connects only to hosts and ports in `allowedNet`. -/
theorem decide_network (req : RunRequest) (maxCaps : Caps) (allowedNet : List AllowHost)
    (secrets : List String) (h : (decide req maxCaps allowedNet secrets).1 = true) :
    ∀ host ∈ req.allowlist, ∃ allowed ∈ allowedNet,
      allowed.host = host.host ∧ allowed.port = host.port := by
  obtain ⟨⟨⟨⟨⟨_, _⟩, hnet⟩, _⟩, _⟩, _⟩ := passes_parts req maxCaps allowedNet secrets h
  intro host hmem
  simp only [netOk] at hnet
  exact hostListed_mem allowedNet host ((List.all_eq_true.mp hnet) host hmem)

/-- Anything allowed is capped within `maxCaps` on all three fields. -/
theorem decide_caps (req : RunRequest) (maxCaps : Caps) (allowedNet : List AllowHost)
    (secrets : List String) (h : (decide req maxCaps allowedNet secrets).1 = true) :
    req.caps.timeout_ms ≤ maxCaps.timeout_ms ∧
      req.caps.output_cap_bytes ≤ maxCaps.output_cap_bytes ∧
      req.caps.memory_mib ≤ maxCaps.memory_mib := by
  obtain ⟨⟨⟨⟨⟨_, _⟩, _⟩, hcaps⟩, _⟩, _⟩ := passes_parts req maxCaps allowedNet secrets h
  simp only [capsOk, Bool.and_eq_true, decide_eq_true_eq] at hcaps
  exact ⟨hcaps.1.1, hcaps.1.2, hcaps.2⟩

/-- Anything allowed carries no non-empty secret as a substring of the workspace
or of any command argument. -/
theorem decide_secrets (req : RunRequest) (maxCaps : Caps) (allowedNet : List AllowHost)
    (secrets : List String) (h : (decide req maxCaps allowedNet secrets).1 = true) :
    ∀ secret ∈ secrets, secret ≠ "" →
      req.workspace.contains secret = false ∧
        ∀ arg ∈ req.command, arg.contains secret = false := by
  obtain ⟨⟨⟨⟨⟨_, _⟩, _⟩, _⟩, hsec⟩, _⟩ := passes_parts req maxCaps allowedNet secrets h
  simp only [secretsOk, Bool.and_eq_true] at hsec
  intro secret hmem hne
  refine ⟨freeOf_spec req.workspace secrets hsec.1.1 secret hmem hne, ?_⟩
  intro arg harg
  exact freeOf_spec arg secrets ((List.all_eq_true.mp hsec.1.2) arg harg) secret hmem hne

private def allowReq : RunRequest := {
  workspace := "/workspace"
  command := ["python3", "/workspace/correct.py"]
  caps := { timeout_ms := 1000, output_cap_bytes := 1024, memory_mib := 128 }
  allowlist := [{ host := "api.example.test", port := 443 }]
}

private def allowMax : Caps :=
  { timeout_ms := 30000, output_cap_bytes := 1048576, memory_mib := 512 }

private def allowNet : List AllowHost := [{ host := "api.example.test", port := 443 }]

private def allowSecrets : List String := ["pasted-key-value-not-real", ""]

private def longToken : String := String.ofList (List.replicate 32 'a')

private def reasonHas (req : RunRequest) (word : String) : Bool :=
  match decide req allowMax allowNet allowSecrets with
  | (false, some reason) => reason.contains word
  | _ => false

#guard decide allowReq allowMax allowNet allowSecrets = (true, none)

#guard decide { allowReq with allowlist := [] } allowMax allowNet allowSecrets = (true, none)

#guard reasonHas { allowReq with command := ["python3", "/etc/passwd"] } "workspace"

#guard reasonHas { allowReq with command := ["python3", "/workspace-evil/x"] } "workspace"

#guard reasonHas { allowReq with command := ["python3", "/workspace/../etc/passwd"] } "workspace"

#guard reasonHas { allowReq with allowlist := [{ host := "other.test", port := 443 }] } "allowlist"

#guard reasonHas { allowReq with allowlist := [{ host := "api.example.test", port := 80 }] } "allowlist"

#guard reasonHas
  { allowReq with caps := { allowReq.caps with timeout_ms := 999999 } } "caps"

#guard reasonHas
  { allowReq with command := ["python3", "use pasted-key-value-not-real"] } "secret"

#guard longToken.length = 32

#guard reasonHas { allowReq with command := ["python3", longToken] } "key-shape"

end Kalari.Gate
