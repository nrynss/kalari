"""Run inside the hidden-grader microVM. Prints one status line and nothing else.

The consumer is untrusted. This runner does not print the base URL, the key, or the
consumer's output. A guest that runs the aashaan is a different path: set
vm.overcommit_memory=1 before starting the aashaan. This runner is Python only.
"""
import subprocess
import sys


def main():
    if len(sys.argv) != 4:
        print("EXIT usage")
        return 2
    consumer, base_url, out_path = sys.argv[1:4]
    try:
        with open("/w/consumer.log", "w") as log:
            proc = subprocess.run(
                [sys.executable, "-I", consumer, "--base-url", base_url, "--out", out_path],
                stdout=log,
                stderr=subprocess.STDOUT,
                timeout=90,
                cwd="/w/src",
            )
        print("EXIT", proc.returncode)
        return 0
    except subprocess.TimeoutExpired:
        print("EXIT timeout")
        return 0
    except OSError:
        print("EXIT launch")
        return 0


if __name__ == "__main__":
    sys.exit(main())
