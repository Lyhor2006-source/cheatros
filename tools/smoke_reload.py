"""Native reload regression: no fabricated reserves, no repeated requests."""
import ast
from pathlib import Path
from types import SimpleNamespace as Obj
source = Path(__file__).resolve().parents[1] / 'payload' / 'RosPayload.py'
tree = ast.parse(source.read_text())
fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == '_pb_auto_reload')
mag = Obj(bullet_count=30, magazine_capacity=30, ammo_box_bullet_count=0)
state = dict(key=None, state='idle')
loading = [False]
accepted = [True]
calls = []
wrapper = [0]
slot = [0]
def request(*args):
    calls.append(1)
    return accepted[0]
def probe(me):
    wrapper[0] += 1
    return ((slot[0],42,1,wrapper[0]),mag.bullet_count,mag.magazine_capacity,[],[],42,mag)
env = dict(_PB_AR_STATE=state, _pb_ar_install_ws_hooks=lambda: None,
           _pb_ar_probe=probe, _pb_ar_is_reloading=lambda *args: loading[0],
           _pb_ar_trigger_reload=request)
exec(compile(ast.Module(body=[fn], type_ignores=[]),str(source),'exec'),env)
tick = env['_pb_auto_reload']
config = [0]*45
config[44] = 1
player = Obj()
def update():
    tick(player,config)
    state['switch_until'] = 0
update()
# The reported failure: fire all 30 rounds with no real spare inventory.
for _ in range(30):
    mag.bullet_count -= 1
    update()
for _ in range(100): update()
assert mag.bullet_count == 0 and mag.ammo_box_bullet_count == 0
assert calls == [] and state['state'] == 'no_reserve'
# Picking up actual reserve permits one request; changing wrapper IDs does not spam.
mag.ammo_box_bullet_count = 60
update()
for _ in range(100): update()
assert len(calls) == 1 and mag.bullet_count == 0 and mag.ammo_box_bullet_count == 60
# Native reload starts, loads one shell, and ends. No forced fill occurs.
loading[0] = True
update()
mag.bullet_count = 1
update()
assert state['state'] == 'reloading' and state['requested']
loading[0] = False
update()
assert mag.bullet_count == 1 and state['state'] == 'idle'
# Failed reload gets exactly one attempt per empty cycle.
mag.bullet_count = 0
accepted[0] = False
update()
count = len(calls)
for _ in range(100): update()
assert state['state'] == 'failed' and len(calls) == count
# Toggle reset permits one more attempt; interrupted native reload doesn't rearm it.
config[44] = 0
update()
config[44] = 1
accepted[0] = True
update()
update()
loading[0] = True
update()
loading[0] = False
update()
count = len(calls)
for _ in range(100): update()
assert len(calls) == count and state['state'] == 'failed'
# A newly selected weapon gets an independent request.
slot[0] = 1
update()
update()
assert len(calls) == count + 1
print('reload regression: 30-to-zero, empty reserve, native shell load, wrapper churn, rejection and cancellation passed')
