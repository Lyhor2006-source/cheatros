"""Trigger truth table, equipped-rail firing, target stability and smoothing."""
import ast
import math
from pathlib import Path
from types import SimpleNamespace as Obj

source = Path(__file__).resolve().parents[1] / 'payload' / 'RosPayload.py'
tree = ast.parse(source.read_text())
names = {'_pb_aim', '_pb_aim_trigger', '_pb_aim_response', '_pb_flag'}
functions = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names]
config = [0.0] * 46
config[:11] = [1, 0, 30, 4, 100, 1, 1, 0, 100, 100, 100]
rotations = []
rail = Obj(_isFiring=False)
camera = Obj(_gunSightOpened=False, onRotateCameraFromUser=lambda value: rotations.append(value))
player = Obj(id=1, camCtrlComp=camera, dtsCurRailID=20003, position=Obj(x=0,y=0,z=0),
             getViewDirection=lambda: Obj(x=0,y=0,z=1))
world_visible = [True]
env = dict(_PB_TRG={}, _PB_AIM=dict(target=None,owner=None,key=None,last=None),
           _PB_HEAL=dict(target=None,owner=None), _pb_aimcfg=lambda: config,
           _pb_healer_active=lambda *args: False, _pb_ar_active_slot=lambda me: 0,
           _pb_ar_probe=lambda me: ((0,1003,20003),30,30,[],[rail],1003,Obj()),
           _pb_enemy=lambda me,e: e.team,
           _pb_aim_screen=lambda point,*args: point,
           _pb_boneworld=lambda e,bone: e.bones[bone], _pb_vis=lambda *args: world_visible[0],
           _pb_healer_visible=lambda *args: world_visible[0])
exec(compile(ast.Module(body=functions,type_ignores=[]),str(source),'exec'),env)
trigger = env['_pb_aim_trigger']
for scoped in (False, True):
    for firing in (False, True):
        camera._gunSightOpened = scoped
        rail._isFiring = firing
        expected = [True, scoped, firing and not scoped, firing or scoped]
        for mode in range(4):
            assert trigger(player,camera,mode) == expected[mode], (mode,scoped,firing)
rail._isFiring = False
camera._gunSightOpened = False
assert not trigger(player,camera,3)
# An unrelated holstered rail cannot activate a trigger.
holstered = Obj(_isFiring=True)
assert not trigger(player,camera,2)
assert not trigger(player,camera,99)

enemy = Obj(id=2,team=1,bones={'head':Obj(x=1,y=2,z=10),'chest':Obj(x=1,y=1,z=10)})
other = Obj(id=3,team=1,bones={'head':Obj(x=-1,y=2,z=10)})
friend = Obj(id=4,team=0,bones=enemy.bones)
def candidate(e, x=50, knocked=False, visible=True, distance=10):
    return e,(x,60),(x,40),knocked,visible,Obj(x=0,y=0,z=10),distance
def check(rows, expected):
    rotations.clear()
    env['_pb_aim'](player,rows)
    assert bool(rotations)==expected, env['_PB_TRG']

for mode in range(4):
    config[1] = mode
    for scoped in (False,True):
        for firing in (False,True):
            camera._gunSightOpened = scoped
            rail._isFiring = firing
            check([candidate(enemy)], [True,scoped,firing and not scoped,firing or scoped][mode])
config[1] = 0
check([candidate(enemy)],True)
check([candidate(other,x=50),candidate(enemy,x=55)],True)
assert env['_PB_AIM']['target']==enemy.id
check([candidate(other),candidate(enemy,x=95)],True)
assert env['_PB_AIM']['target']==other.id
check([candidate(friend)],False)
check([candidate(enemy,knocked=True)],False)
check([candidate(enemy,distance=1001)],False)
check([candidate(enemy,x=95)],False)
world_visible[0] = False
check([candidate(enemy)],False)
world_visible[0] = True
check([candidate(enemy,visible=False)],True)  # Fresh aim-point query recovers stale head visibility.
config[0] = 0
check([candidate(enemy)],False)
assert env['_PB_AIM']['target'] is None

response = env['_pb_aim_response']
assert response(1,0.02)==1
assert 0 < response(20,0.02) < response(4,0.02) < 1
# Equal time at 25 and 50 updates per second yields equal remaining error.
assert math.isclose((1-response(4,0.04))**25,(1-response(4,0.02))**50,rel_tol=1e-12)
print('aim: all trigger combinations, equipped rail, FOV/team/range filters, stable targets and frame-independent smoothing passed')
