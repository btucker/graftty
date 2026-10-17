"""Deliberate real-Codex color checks against native rendered pixels."""
import json
import time

from harness import Action, InvariantFailure, assert_color_samples
from model import color_scenario_text
from run import Run


class ColorRun(Run):
    def __init__(self, options, actions=None):
        super().__init__(options, actions)
        self.server.models.fixture_text = color_scenario_text
        self.summary['scope'] = ('Real Codex colors in native Mac pixels' if options.mac_only else
                                 'Real Codex colors in native Mac and UIKit pixels over SSH/WebRTC')

    def check_colors(self, stage, client='mac'):
        deadline = time.monotonic() + 15
        while True:
            operation = 'verify' if client == 'mac' else 'snapshot'
            value = self.act(Action(operation, 'codex', {'colors': 'true'}, client=client))
            (self.root / f'colors-{client}-{stage}.json').write_text(json.dumps(value, indent=2))
            try:
                assert_color_samples(value)
                break
            except InvariantFailure:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(.1)
        self.summary['assertions'].append({'client': client, 'stage': stage,
                                           'colorPixels': json.loads(value['colorPixels'])})
        if client == 'mobile':
            self.act(Action('snapshot', 'codex', client='gestures'))

    def scenarios(self):
        self.phase = 'colors'
        if not self.options.mac_only:
            self.start_mobile()
        models = self.server.models
        self.paths['codex'] = self.act(Action('start', 'codex'))
        deadline = time.monotonic() + 60
        reviewed = False
        while ('codex', 'begin') not in models.arrived:
            if time.monotonic() >= deadline:
                raise InvariantFailure('Codex color fixture did not start')
            if 'Hooks need review' in self.snapshot('codex')['text'] and not reviewed:
                self.act(Action('input', 'codex', {'text': '2'}))
                reviewed = True
            time.sleep(.1)
        models.release('codex', 'begin')
        self.wait_model(lambda: ('codex', 'middle') in models.arrived)
        self.check_colors('live')
        if not self.options.mac_only:
            self.act(Action('connect', 'codex', {'session': self.paths['codex']['session']}, client='mobile'))
            self.act(Action('takeControl', 'codex', client='mobile'))
            self.converge('codex')
            self.check_colors('owner', 'mobile')
            self.act(Action('reconnect', 'codex', client='mobile'))
            self.converge('codex')
            self.check_colors('reconnected', 'mobile')
            self.act(Action('takeControl', 'codex'))
            self.converge('codex')
            self.check_colors('follower', 'mobile')
            self.check_colors('owner-return')
        models.release('codex', 'middle')
        self.wait_model(lambda: ('codex', 'end') in models.arrived)
        self.check_colors('streamed')
        models.release('codex', 'end')
        self.wait_model(lambda: ('codex', 'recap') in models.arrived)
        models.release('codex', 'recap')
        self.wait_model(lambda: 'codex' in models.recaps_done)
