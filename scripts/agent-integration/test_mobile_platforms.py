from contextlib import ExitStack
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import preview_ui
import worktree_ui


class MobilePlatformTests(unittest.TestCase):
    def test_validation_uses_destination_sdks_for_phone_and_embedded_watch(self):
        for runner in (preview_ui, worktree_ui):
            for phase in ('red', 'green'):
                with self.subTest(runner=runner.__name__, phase=phase), \
                     tempfile.TemporaryDirectory() as temporary, ExitStack() as patches:
                    directory = Path(temporary)
                    options = SimpleNamespace(output=directory, derived_data=directory / 'derived',
                                              source_packages=None, timeout=10)
                    patches.enter_context(patch.dict('os.environ', {'GRAFTTY_RENDERER_CONTEXT': 'fixture'}))
                    execute = patches.enter_context(patch.object(runner, 'execute', side_effect=RuntimeError('command captured')))
                    if runner is worktree_ui:
                        patches.enter_context(patch.object(runner, 'collect_renders', return_value={'images': []}))
                    runner.run_phase(phase, options, 'fixture-simulator')
                    command = execute.call_args.args[0]
                    self.assertNotIn('-sdk', command,
                                     'A global iOS SDK also overrides the embedded watch target SDK')
                    self.assertEqual(command[command.index('-destination') + 1],
                                     'platform=iOS Simulator,id=fixture-simulator')


if __name__ == '__main__':
    unittest.main()
