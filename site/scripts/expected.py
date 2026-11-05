import ast
import json
import re
import sys

text = open('bench/RESULTS.md').read()
m = re.search(r'EXPECTED = (\{.*?\n\})', text, re.S)
if not m:
    sys.exit('EXPECTED block not found')
print(json.dumps(ast.literal_eval(m.group(1))))
