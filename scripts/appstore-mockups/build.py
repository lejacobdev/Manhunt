import sys
from pathlib import Path
from PIL import Image
from compose import compose
# Simulator shots from iphone-screens.yml (default_<scenario>.png), downloaded with gh run download.
SHOTS = Path(sys.argv[1] if len(sys.argv) > 1 else 'shots')
OUT = Path(__file__).resolve().parents[2] / 'site/assets/appstore-screenshots-1.2'
SET = [
    ('01-track-live', 'hud-hunter', 'TRACK LIVE', 'Radar and compass HUD'),
    ('02-invite', 'invite', 'INVITE IN SECONDS', 'Scan the code or send a link'),
    ('03-quick-setup', 'setup', 'QUICK SETUP', 'A play area around you in one tap'),
    ('04-stay-hidden', 'hud-runner', 'STAY HIDDEN', 'See hunters coming on your compass'),
    ('05-rematch', 'game-over', 'REMATCH', 'Run it back with the same group'),
    ('06-match-summary', 'summary', 'MATCH SUMMARY', 'Highlights, timeline and replay'),
    ('07-make-it-yours', 'cosmetics', 'MAKE IT YOURS', 'Map styles, radar skins and badges'),
    ('08-learn', 'how-to', 'LEARN IN A MINUTE', 'A quick walkthrough for new players'),
]
only = set(sys.argv[2:])
for d in ('1284x2778', '1290x2796'):
    (OUT / d).mkdir(parents=True, exist_ok=True)
for name, scenario, title, sub in SET:
    if only and scenario not in only:
        continue
    src = SHOTS / f'default_{scenario}.png'
    big = OUT / '1284x2778' / f'{name}.png'
    compose(src, title, sub, big)
    Image.open(big).resize((1290, 2796), Image.LANCZOS).save(OUT / '1290x2796' / f'{name}.png', optimize=True)
    print('made', name)
