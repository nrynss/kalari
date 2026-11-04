"""The measures block and the HTTP retry block for one result file.

Sandbox runs come from the consumer tool-call log in the session analysis. HTTP
retries come from the API retry journals. The two stay in separate fields and
are never added together.
"""

PHASES = ("agent", "grading")
RETRY_COUNTS = ("b5_429_responses", "matching_retry_attempts", "successful_matching_retries")


def retry_counts(measure):
    """Agent and grading HTTP retry counts, apart from sandbox runs."""
    phases = (measure or {}).get("phases") or {}
    counts = {}
    for phase in PHASES:
        doc = phases.get(phase) or {}
        counts[phase] = {
            "status": doc.get("status") or "unknown",
            **{key: doc.get(key) for key in RETRY_COUNTS},
        }
    counts["note"] = "an HTTP retry inside one consumer process is not a sandbox run"
    counts["null_means"] = "unknown, not zero"
    return counts


def build(analysis, verdict, right_first_time, tokens_input, tokens_output,
          records_lost, records_duplicated):
    """Return (measures, http_retries) from the session analysis."""
    analysis = analysis or {}
    measures = {
        "verdict": verdict,
        "right_first_time": right_first_time,
        "sandbox_runs": analysis.get("sandbox_runs"),
        "wall_time_s": analysis.get("wall_time_s"),
        "time_stuck_s": analysis.get("time_stuck_s"),
        "tokens_input": tokens_input,
        "tokens_output": tokens_output,
        "records_lost": records_lost,
        "records_duplicated": records_duplicated,
    }
    return measures, retry_counts(analysis.get("retry_measure"))
