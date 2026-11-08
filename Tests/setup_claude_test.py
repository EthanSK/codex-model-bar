#!/usr/bin/env python3
"""Exercise the packaged setup shell in a disposable home with no real services."""
import os
import re
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
REVISION = re.search(r'^REVISION=([a-f0-9]{40})$', (ROOT / 'Resources/setup-claude.sh').read_text(), re.M).group(1)


class ClaudeSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='model-bar-setup-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / 'home'
        self.bin = self.root / 'bin'
        self.home.mkdir()
        self.bin.mkdir()
        script = (ROOT / 'Resources/setup-claude.sh').read_text()
        script = script.replace('$HOME', '$MODEL_BAR_TEST_HOME')
        script = '\n'.join(line for line in script.splitlines() if not line.startswith('export PATH='))
        self.script = self.root / 'setup.sh'
        self.script.write_text(script)
        self.base = self.home / 'Library/Application Support/Codex Model Bar'
        self.environment = {**os.environ, 'MODEL_BAR_TEST_HOME': str(self.home),
                            'PATH': f'{self.bin}:/usr/bin:/bin', 'TEST_REVISION': REVISION}

    def tool(self, name, contents='exit 0'):
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + contents + '\n')
        path.chmod(0o755)

    def run_setup(self):
        return subprocess.run(['/bin/bash', self.script], env=self.environment,
                              capture_output=True, text=True, timeout=10)

    def test_absent_claude_does_nothing(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.base.exists())

    def test_existing_service_is_untouched(self):
        path = self.home / 'Library/LaunchAgents/com.codex-claude-bridge.plist'
        path.parent.mkdir(parents=True)
        path.write_text('existing user service')
        self.assertEqual(self.run_setup().returncode, 0)
        self.assertEqual(path.read_text(), 'existing user service')
        self.assertFalse(self.base.exists())

    def test_installs_pinned_revision_once_and_preserves_completed_opt_out(self):
        for name in ('claude', 'node', 'npm'):
            self.tool(name)
        service = self.home / 'Library/LaunchAgents/com.codex-claude-bridge.plist'
        service.parent.mkdir(parents=True)
        service.write_bytes(plistlib.dumps({'ProgramArguments': ['node', str(self.base / 'Claude Bridge/failed/src/server.js')]}))
        self.tool('curl', 'exit 7')
        self.tool('git', '''
case " $* " in
  *" clone "*) target="${@: -1}"; mkdir -p "$target/.git" "$target/scripts"; printf 'exit 0\\n' > "$target/scripts/install.sh" ;;
  *" rev-parse HEAD "*) echo "$TEST_REVISION" ;;
esac
''')
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        marker = self.base / 'claude-setup-complete'
        self.assertEqual(marker.read_text().strip(), REVISION)
        self.tool('git', 'exit 91')
        self.assertEqual(self.run_setup().returncode, 0)

    def test_missing_dependency_does_not_mark_setup_complete(self):
        self.tool('claude')
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / 'claude-setup-complete').exists())


if __name__ == '__main__':
    unittest.main()
