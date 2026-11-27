"""Check normal aim accepts ESP candidates with unknown team classification."""
import ast
from pathlib import Path
from types import SimpleNamespace as Obj

source = Path(__file__).resolve().parents[1] / 'payload' / 'RosPayload.py'
tree = ast.parse(source.read_text(encoding='utf-8'))
names = {'_pb_healer_active', '_pb_aim'}
functions = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names]
config = [0.0] * 46
config[0] = 1.0
config[2] = 120.0
config[4] = 100.0
config[8:11] = [100.0, 100.0, 100.0]
rotations = []
cam = Obj(onRotateCameraFromUser=lambda *args: rotations.append(args))
me = Obj(camCtrlComp=cam, position=Obj(x=0, y=0, z=0),
         getViewDirection=lambda: Obj(x=0, y=0, z=1))
enemy = Obj(team=-1, bone=Obj(x=1, y=0, z=10))
teammate = Obj(team=0, bone=Obj(x=1, y=0, z=10))
env = {'_PB_TRG': {}, '_pb_aimcfg': lambda: config,
       '_pb_flag': lambda *_: False, '_pb_cam_pos': lambda me: me.position,
       '_pb_aim_screen': lambda p, *_: p,
       '_pb_enemy': lambda me, e: e.team,
       '_pb_vis': lambda *_: 1,
       '_pb_boneworld': lambda e, bone: e.bone}
exec(compile(ast.Module(body=functions, type_ignores=[]), str(source), 'exec'), env)
position = Obj(x=1, y=0, z=10)
candidate = lambda e: (e, (51, 60), (51, 40), False, True, position, 10)
env['_pb_aim'](me, [candidate(enemy)])
assert rotations and env['_PB_TRG']['selected'] == 1 and env['_PB_TRG']['rotated'] == 1
rotations.clear()
env['_pb_aim'](me, [candidate(teammate)])
assert not rotations and env['_PB_TRG']['selected'] == 0
print('normal aim smoke: unknown non-teammate selected; teammate excluded')
