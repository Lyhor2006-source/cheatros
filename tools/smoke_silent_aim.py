"""Independent silent distance, 360 selection, trigger modes and ray output."""
import ast
from pathlib import Path
from types import SimpleNamespace as Obj

source = Path(__file__).resolve().parents[1] / 'payload' / 'RosPayload.py'
tree = ast.parse(source.read_text())
names = {'_pb_silent', '_pb_aim_trigger', '_pb_flag', '_pb_wray', '_pb_silgen',
         '_pb_origin', '_pb_redir', '_pb_isvec'}
functions = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names]


class Vec:
    def __init__(self, x, y, z):
        self.x, self.y, self.z = x, y, z


config = [0.0] * 47
config[2] = 60
config[5] = config[6] = 1
config[8:11] = [100, 100, 5]  # Normal aim range is deliberately only five metres.
config[13] = 1
config[46] = 100
camera = Obj(_gunSightOpened=False)
rail = Obj(_isFiring=False)
player = Obj(camCtrlComp=camera, getViewPos=lambda: Vec(0,0,0))
enemy = Obj(team=1)
friend = Obj(team=0)
visible = [True]
env = dict(_PB_NRS=dict(sil=True), _PB_SIL=dict(t=None,tv=0,n=0), _PB_TRG={},
           _pb_aimcfg=lambda: config, _pb_healer_active=lambda *args: False,
           _pb_ar_probe=lambda me: ((0,42,1),1,30,[],[rail],42,Obj()),
           _pb_enemy=lambda me,e: e.team, _pb_vis=lambda *args: visible[0],
           _pb_aim_screen=lambda point,*args: point,
           _pb_head_pos=lambda e,*args: Vec(1,2,100),
           _pb_boneworld=lambda e,bone: Vec(1,2,100))
exec(compile(ast.Module(body=functions,type_ignores=[]),str(source),'exec'),env)
silent = env['_pb_silent']
def candidate(e=enemy, distance=500, knocked=False, screen=(52,30)):
    return e,(screen[0],60),screen,knocked,True,Vec(0,0,100),distance

silent(player,[candidate()],[])
assert env['_PB_SIL']['t']==(1,2,100)  # Works independently of camera aim and its range.
wrapped = env['_pb_wray'](lambda self: iter([(Vec(0,0,0),Vec(0,0,1))]))
origin,direction = list(wrapped(Obj()))[0]
assert (origin.x,origin.y,origin.z)==(0,0,0)
assert direction.x>0 and direction.y>0
assert abs(direction.x**2+direction.y**2+direction.z**2-1)<1e-12
for rows in ([candidate(distance=1001)], [candidate(friend)], [candidate(knocked=True)]):
    silent(player,rows,[])
    assert env['_PB_SIL']['t'] is None
visible[0] = False
silent(player,[candidate()],[])
assert env['_PB_SIL']['t'] is None
visible[0] = True
for mode in range(4):
    config[1] = mode
    for scoped in (False,True):
        for firing in (False,True):
            camera._gunSightOpened = scoped
            rail._isFiring = firing
            silent(player,[candidate()],[])
            assert (env['_PB_SIL']['t'] is not None)==[True,scoped,firing and not scoped,firing or scoped][mode]
config[1] = 0
silent(player,[candidate(screen=(500,30))],[])
assert env['_PB_SIL']['t'] is None
config[13] = 0
config[14] = 1
silent(player,[],[(enemy,False,True,Vec(0,0,-100),500)])
assert env['_PB_SIL']['t'] is not None  # 360 targets need no on-screen projection.
silent(player,[],[(enemy,False,True,Vec(0,0,-100),1001)])
assert env['_PB_SIL']['t'] is None
config[14] = 0
silent(player,[candidate()],[])
assert env['_PB_SIL']['t'] is None
print('silent aim: independent range/toggle, 360 offscreen targets, all triggers, visibility/team filtering and unit ray redirection passed')
