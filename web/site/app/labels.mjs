/* Product labels. These are the words from product.md and bench/README.md,
   kept in one place so a page never invents a different name for a condition. */

export const CONDITIONS = {
  1: {
    name: "One continuous session",
    blurb:
      "The reference setup keeps one session open across both upgrades. Payouts starts it, settlements continues it.",
  },
  2: {
    name: "The notes handoff",
    blurb:
      "A new session for upgrade two reads the notes the agent wrote after upgrade one.",
  },
  3: {
    name: "A fresh session",
    blurb: "A new session for each upgrade, with no notes and no earlier context.",
  },
  4: {
    name: "Kalari, without stored lessons",
    blurb:
      "OpenCode with Kalari, and no lesson from upgrade one. This separates the pipeline from memory.",
  },
  5: {
    name: "Kalari, with the lesson",
    blurb:
      "OpenCode with Kalari, and the lesson from upgrade one recalled as a check that must pass.",
  },
  6: {
    name: "The verifier prompt",
    blurb:
      "The reference setup with one extra sentence: verify the new records against the old ones, record by record. This is the control.",
  },
};

export const UPGRADES = {
  payouts: {
    name: "Merchant payout ledger",
    format: "REST",
    blurb:
      "A windowed export with a cursor on every page, record repeats at window boundaries, and a silently capped page size.",
  },
  settlements: {
    name: "Settlement batches",
    format: "GraphQL",
    blurb:
      "A connection whose end cursor is never null, repeats across pages, and empty pages that still continue.",
  },
  disbursements: {
    name: "Disbursement payouts",
    format: "REST",
    blurb:
      "A windowed export where the final page still carries a token, amended records repeat, and one request in twenty answers with a retry delay.",
  },
};

export const BEHAVIOURS = {
  B1: "A cursor on every page",
  B2: "Repeats at page boundaries",
  B3: "An empty page that continues",
  B4: "A silently capped page size",
  B5: "A retry partway through",
};

export const BEHAVIOUR_BLURBS = {
  B1: "The last page still carries a cursor. An end flag decides when to stop.",
  B2: "A record can appear on two pages on purpose. Keep one copy by id.",
  B3: "A page can be empty and still carry a cursor. Keep going.",
  B4: "The server returns fewer records than the asked limit. Page length is not a stop signal.",
  B5: "A request can return a retry response partway through. The retry must resume, not skip.",
};

export const CHANGE_KINDS = {
  pagination_changed: "Pagination changed",
  operation_moved: "Operation moved",
  operation_renamed: "Operation renamed",
  operation_removed: "Operation removed",
  operation_added: "Operation added",
  argument_added: "Argument added",
  field_added: "Field added",
  field_required_changed: "Required field changed",
  field_type_changed: "Field type changed",
  type_added: "Type added",
  result_added: "Result added",
  rename: "Rename",
};

export const CLEF_LABELS = {
  api_change: "an API change",
  test_setup: "a test setup problem",
  flaky: "a flaky run",
  unrelated_bug: "an unrelated bug",
  hit_v1_call: "the old call",
  hit_v2_already: "the new call already in place",
  hit_comment: "a mention in a comment",
  hit_table_name: "a table name",
  hit_query: "the query",
  hit_other_query: "another query",
  to_settlements: "the settlements lesson",
  to_rename: "the rename lesson",
  to_refunds_connection: "the refunds lesson",
};

export const OBSERVATION_LABELS = {
  boundary_overlap_one: "one record repeated at a window boundary",
  final_page_token: "the final page still carried a cursor",
  empty_page_continues: "an empty page still carried a cursor",
};

export function conditionLabel(condition) {
  return CONDITIONS[condition]?.name || "A further condition";
}

export function conditionBlurb(condition) {
  return CONDITIONS[condition]?.blurb || "A condition in the comparison.";
}

export function upgradeLabel(upgrade) {
  return UPGRADES[upgrade]?.name || "Another upgrade";
}

export function upgradeFormat(upgrade) {
  return UPGRADES[upgrade]?.format || "";
}

export function changeKindLabel(kind) {
  return CHANGE_KINDS[kind] || kind || "Change";
}

export function clefLabel(label) {
  return CLEF_LABELS[label] || label || "an answer";
}

export function observationLabel(label) {
  return OBSERVATION_LABELS[label] || label || "an observed behaviour";
}
