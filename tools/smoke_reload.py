"""Regression checks: native reload owns timing and magazine writes."""
import ast
from pathlib import Path
from types import SimpleNamespace as Obj
source = Path(__file__).resolve().parents[1] / 'payload' / 'RosPayload.py'
tree = ast.parse(source.read_text())
fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == '_pb_auto_reload')
mag = Obj(bullet_count=0, magazine_capacity=5, ammo_box_bullet_count=0)
player = Obj(dtsCurRailID=1)
state = dict(state='idle', key=None, unlim_on=False)
loading = [False]
accepted = [True]
calls = []
def request(*args):
    calls.append(1)
    return accepted[0]
env = dict(_PB_AR_STATE=state, _pb_ar_install_ws_hooks=lambda: None,
           _pb_ar_probe=lambda me: ((0, 42, 1, id(mag)), mag.bullet_count, 5, [], [], 42, mag),
           _pb_ar_is_reloading=lambda *args: loading[0], _pb_ar_trigger_reload=request)
exec(compile(ast.Module(body=[fn], type_ignores=[]), str(source), 'exec'), env)
tick = env['_pb_auto_reload']
config = [0]*45
config[44] = 1
tick(player, config)
state['switch_until'] = 0
tick(player, config)
assert len(calls) == 1 and mag.ammo_box_bullet_count == 25
state['reload_start'] = -1e12
for _ in range(5): tick(player, config)
assert mag.bullet_count == 0 and len(calls) == 1
loading[0] = True
tick(player, config)
mag.bullet_count = 1
tick(player, config)
assert mag.bullet_count == 1 and state['state'] == 'reloading'
loading[0] = False
tick(player, config)
assert mag.bullet_count == 1 and state['state'] == 'idle'
# A native rejection stops requests; no timer creates ammunition.
mag.bullet_count = 0
accepted[0] = False
tick(player, config)
count = len(calls)
for _ in range(5): tick(player, config)
assert state['state'] == 'failed' and len(calls) == count and mag.bullet_count == 0
# Disable/re-enable resets the attempt without fabricating a reload.
config[44] = 0
tick(player, config)
assert state['key'] is None
config[44] = 1
accepted[0] = True
tick(player, config)
state['switch_until'] = 0
tick(player, config)
loading[0] = True
tick(player, config)
loading[0] = False
tick(player, config)
assert state['state'] == 'failed' and mag.bullet_count == 0
print('reload smoke: native timing, partial shells, no timed refill, rejection, cancellation, reset passed')
