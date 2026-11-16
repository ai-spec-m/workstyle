#!/usr/bin/env bash
set -e
git init -q . && git config user.email e@e && git config user.name e
mkdir -p tempconv tests
printf 'def c_to_f(c: float) -> float:\n    return c * 9 / 5 + 32\n' > tempconv/__init__.py
cat > tests/test_conv.py <<'PY'
import unittest
from tempconv import c_to_f


class T(unittest.TestCase):
    def test_c_to_f(self):
        self.assertEqual(c_to_f(100), 212)
PY
git add . && git commit -qm init
printf '# tempconv\n\n## Repo-specific notes\n- Architecture: single — library, no server, no schema @ %s\n- Finish policy: local\n' "$(git rev-parse --short HEAD)" > CLAUDE.md
git add CLAUDE.md && git commit -qm claude-md
mkdir -p .workstyle && printf 'test: python3 -m unittest discover -s tests\nmax_diff_lines: 400\n' > .workstyle/gates.conf
printf '.workstyle/\narchitecture.local/\n' >> .git/info/exclude
