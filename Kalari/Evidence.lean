import Lean.Data.Json
import Std.Sync.Mutex

/-! Append-only evidence JSONL. One `Store` is shared by all writers in a
Kalari process; its mutex serializes append and reload. `payload` contains the
complete evidence, while the envelope supplies query keys. -/

open Lean
namespace Kalari.Evidence

/-- The complete evidence payload and its indexes. `kind` identifies the payload
as a run, check result, model answer, or lesson; multiple change kinds may apply. -/
structure Record where
  kind : String
  session_id : String
  run_id : String
  change_kinds : List String
  payload : Json
  deriving FromJson, ToJson

structure Loaded where
  records : List Record
  warnings : List String

structure Store where
  path : System.FilePath
  private lock : Std.Mutex Unit

/-- Open a store under the given workspace. Share this value among callers; it
is the synchronization boundary. Multiple processes must not write the same store. -/
def openStore (workspace : System.FilePath) : IO Store := do
  let dir := workspace / ".kalari"
  IO.FS.createDirAll dir
  return { path := dir / "evidence.jsonl", lock := ← Std.Mutex.new () }

private def read (path : System.FilePath) : IO ByteArray := do
  if ← path.pathExists then IO.FS.readBinFile path else pure ByteArray.empty

/-- A newline commits a record. Decode bytes per line so a partial UTF-8 code
point in a truncated suffix does not prevent recovery of earlier records. -/
def decode (bytes : ByteArray) : Loaded := Id.run do
  let mut records := []
  let mut warnings := []
  let mut start := 0
  let mut lineNo := 1
  for i in [0:bytes.size] do
    if bytes[i]! == 10 then
      let line := String.fromUTF8? (bytes.extract start i)
      let parsed := line.bind fun text => (Json.parse text >>= (fromJson? (α := Record))).toOption
      match parsed with
      | some record => records := record :: records
      | none => warnings := s!"invalid evidence line {lineNo}; skipped" :: warnings
      start := i + 1
      lineNo := lineNo + 1
  if start < bytes.size then warnings := "truncated final evidence line; skipped" :: warnings
  return { records := records.reverse, warnings := warnings.reverse }

/-- Reload all records, returning warnings to the caller. Warnings do not contain
record contents, which can include logs. -/
def load (store : Store) : IO Loaded := store.lock.atomically do
  let loaded := decode (← read store.path)
  for warning in loaded.warnings do IO.eprintln s!"evidence: {warning}"
  return loaded

/-- Append a complete JSON record and flush it. If a prior write left a partial
suffix, append an invalidating byte and newline before the next record; reload
warns and skips it, even if the suffix happened to be valid JSON.
This only appends bytes and never rewrites existing evidence. -/
def append (store : Store) (record : Record) : IO Unit := store.lock.atomically do
  let old ← read store.path
  let separator := if old.isEmpty || old[old.size - 1]! == 10 then "" else "!\n"
  let h ← IO.FS.Handle.mk store.path .append
  h.putStr (separator ++ (toJson record).compress ++ "\n")
  h.flush

/-- Records associated with a run, in append order. -/
def byRun (loaded : Loaded) (id : String) : List Record :=
  loaded.records.filter (·.run_id == id)

/-- Records associated with a change kind, in append order. -/
def byChangeKind (loaded : Loaded) (kind : String) : List Record :=
  loaded.records.filter (·.change_kinds.contains kind)

/-- Records associated with a session, in append order. -/
def bySession (loaded : Loaded) (id : String) : List Record :=
  loaded.records.filter (·.session_id == id)

private def verify (b : Bool) (message : String) : IO Unit := do
  unless b do throw <| .userError message

private def testRecord (kind session run : String) (changes : List String) (body : String) : Record :=
  { kind, session_id := session, run_id := run, change_kinds := changes, payload := Json.str body }

private def checks : IO Unit := IO.FS.withTempDir fun dir => do
  let store ← openStore dir
  let run := testRecord "run" "s1" "r1" ["pagination_changed"] "input verdict logs"
  let check := testRecord "check" "s1" "r1" ["pagination_changed"] "check result"
  let answer := testRecord "decision" "s1" "r1" ["pagination_changed"] "Clef probabilities"
  let lesson := testRecord "lesson" "s2" "r2" ["pagination_changed", "argument_added"] "lesson"
  for entry in [run, check, answer, lesson] do append store entry
  let loaded ← load store
  verify (loaded.records.length == 4 && loaded.warnings.isEmpty) "append/reload"
  verify ((byRun loaded "r1").length == 3 && (byRun loaded "missing").isEmpty) "run query"
  verify ((byChangeKind loaded "pagination_changed").length == 4 &&
    (byChangeKind loaded "argument_added").length == 1) "change query"
  verify ((bySession loaded "s2").length == 1) "session query"
  let some first := loaded.records.head? | throw <| .userError "missing record"
  verify ((toJson first).compress == (toJson run).compress) "payload round trip"
  let h ← IO.FS.Handle.mk store.path .append
  h.putStr "{\"partial\":"
  h.flush
  let truncated ← load store
  verify (truncated.records.length == 4 && truncated.warnings.length == 1) "truncated tail"
  append store run
  let recovered ← load store
  verify (recovered.records.length == 5 && recovered.warnings.length == 1) "append after truncation"
  -- Even a complete-looking JSON value without its newline is not committed.
  let h ← IO.FS.Handle.mk store.path .append
  h.putStr (toJson lesson).compress
  h.flush
  append store check
  let recovered ← load store
  verify (recovered.records.length == 6 && recovered.warnings.length == 2) "unterminated valid tail"
  let h ← IO.FS.Handle.mk store.path .append
  h.write (ByteArray.mk #[0x7b, 0x22, 0xc3])
  h.flush
  let utf8Tail ← load store
  verify (utf8Tail.records.length == 6 && utf8Tail.warnings.length == 3) "partial UTF-8 tail"
  append store run
  let utf8Recovered ← load store
  verify (utf8Recovered.records.length == 7 && utf8Recovered.warnings.length == 3) "partial UTF-8 recovery"
  let tasks ← (List.range 24).mapM fun i => IO.asTask <|
    append store (testRecord "run" "parallel" s!"r{i}" [] s!"payload{i}")
  for task in tasks do IO.ofExcept task.get
  let concurrent ← load store
  verify ((bySession concurrent "parallel").length == 24 && concurrent.records.length == 31) "concurrent appends"
  for i in List.range 24 do
    verify (((byRun concurrent s!"r{i}").filter (·.session_id == "parallel")).length == 1) "concurrent record missing or duplicated"
  let ignored ← IO.FS.readFile ".gitignore"
  verify (ignored.splitOn "\n" |>.contains "/.kalari/") "store not gitignored"

#eval checks

end Kalari.Evidence
