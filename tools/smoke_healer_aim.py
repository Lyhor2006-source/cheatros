"""Verify healer teammate camera alignment without redirecting native shots."""
import ast
import sys
from pathlib import Path
from types import SimpleNamespace as Obj

source = Path(__file__).resolve().parents[1] / 'payload' / 'RosPayload.py'
tree = ast.parse(source.read_text())
names = {'_pb_healer_point', '_pb_healer_visible', '_pb_healer_active', '_pb_aim', '_pb_silent', '_pb_nrs_tick', '_pb_flag',
         '_pb_enemy', '_pb_team_id', '_pb_squad_member', '_pb_wounded', '_pb_trackable'}
functions = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names]
config = [0.0] * 46
config[1] = 3  # Enemy scoped+firing mode must not disable healer assistance.
config[2] = 30
config[8:11] = [100, 100, 100]
config[13:15] = [1, 1]  # Enemy ray modes must not redirect healer shots.
config[45] = 1
rotations = []
camera = Obj(onRotateCameraFromUser=lambda value: rotations.append(value))
player = Obj(id=1, teamID=1, dtsCurWeapon=0, dtsWeapon0={'weaponID': 1011},
             dtsCurRailID=20011, camCtrlComp=camera,
             position=Obj(x=0,y=0,z=0), getViewPos=lambda: Obj(x=0,y=0,z=0),
             getViewDirection=lambda: Obj(x=0,y=0,z=1))
namespace = dict(_PB_AIM=dict(target=None,owner=None,key=None,last=None), _PB_HEAL=dict(target=None,owner=None), _pb_space=lambda: None, _PB_TRG={}, _PB_NRS=dict(sil=True,cls=Obj(),nr=False,ns=False),
                 _PB_SIL=dict(t=(1,2,3),tv=1), unicode=str,
                 _pb_aimcfg=lambda: config, _pb_vis=lambda *_: 1,
                 _pb_aim_screen=lambda point,*_: point,
                 _pb_ar_read=lambda obj,name: obj.get(name) if isinstance(obj,dict) else getattr(obj,name,None),
                 _pb_is_mapping=lambda obj: isinstance(obj,dict),
                 _pb_boneworld=lambda entity,bone: entity.bones.get(bone),
                 _pb_health=lambda e: (e.hp,100))
exec(compile(ast.Module(body=functions,type_ignores=[]),str(source),'exec'),namespace)
aim = namespace['_pb_aim']
silent = namespace['_pb_silent']
injured = Obj(id=2,teamID=1,bones={'chest':Obj(x=1,y=2,z=10)})
downed = Obj(id=4,teamID=1,bones={'chest':Obj(x=-1,y=2,z=10)})
enemy = Obj(id=3,teamID=2,bones={'chest':Obj(x=-5,y=2,z=10)})
def candidate(entity,feet=(50,60),head=(50,40),knocked=False,visible=True,dist=10,hp=50):
    return (entity,feet,head,knocked,visible,Obj(x=0,y=0,z=10),dist,hp,100)
def check(rows,should_rotate):
    rotations.clear()
    aim(player,[(enemy,(50,60),(50,40),False,True,Obj(x=0,y=0,z=10),10)],tm_cands=rows)
    assert bool(rotations) == should_rotate, namespace['_PB_TRG']
    if should_rotate:
        assert namespace['_PB_TRG']['selected'] == 1 and namespace['_PB_TRG']['rotated'] == 1

check([],False)
check([candidate(injured)],True)
assert rotations[0][0] > 0
check([candidate(injured),candidate(downed,knocked=True,hp=0)],True)
assert rotations[0][0] < 0  # Downed teammate takes priority.
check([candidate(enemy)],False)  # Reject an enemy in a malformed teammate list.
check([candidate(injured,visible=False)],False)
check([candidate(injured,feet=(150,60),head=(150,40))],False)
check([candidate(injured,dist=1001)],False)
native_visibility = [False]
saved_utils = sys.modules.get('shoot_utils')
sys.modules['shoot_utils'] = Obj(isCanBeShot=lambda origin,point: native_visibility[0])
check([candidate(injured)],False)  # Torso blocked despite a visible head.
native_visibility[0] = True
check([candidate(injured,visible=False)],True)  # Torso visible despite a blocked head.
if saved_utils is None:
    del sys.modules['shoot_utils']
else:
    sys.modules['shoot_utils'] = saved_utils
check([candidate(injured,feet=(95,60),head=(95,40))],True)
# Keep an equally eligible target through small pixel movements, then release it
# for a much more central target or a newly downed teammate.
other = Obj(id=5,teamID=1,bones={'chest':Obj(x=-2,y=2,z=10)})
check([candidate(injured)],True)
check([candidate(other),candidate(injured,feet=(55,60),head=(55,40))],True)
assert namespace['_PB_HEAL']['target'] == injured.id
check([candidate(other),candidate(injured,feet=(95,60),head=(95,40))],True)
assert namespace['_PB_HEAL']['target'] == other.id
check([candidate(other),candidate(downed,knocked=True,hp=0)],True)
assert namespace['_PB_HEAL']['target'] == downed.id
check([],False)
assert namespace['_PB_HEAL']['target'] is None
# Native healer shots must not be rewritten by either enemy ray mode.
namespace['_PB_NRS']['sil'] = True
silent(player,[],[],[candidate(injured)])
assert namespace['_PB_SIL']['t'] is None
namespace['_pb_nrs_tick'](player)
assert not namespace['_PB_NRS']['sil']
for weapon in ({'weaponID':1011},Obj(weaponID=1011),{'weaponID':90050}):
    player.dtsWeapon0 = weapon
    assert namespace['_pb_healer_active'](player,config)
    check([candidate(injured)],True)
config[45] = 0
check([candidate(injured)],False)
config[45] = 1
player.dtsWeapon0 = {'weaponID':42}
assert not namespace['_pb_healer_active'](player,config)
check([candidate(injured)],False)
namespace['_pb_nrs_tick'](player)
assert namespace['_PB_NRS']['sil']  # Ordinary weapon's configured mode is preserved.
# Candidate collection retains revivable players and supports roster ID formats.
for wounded in (True,lambda:True):
    assert namespace['_pb_trackable'](Obj(isAlive=False,hp=0,isWounded=wounded))
assert not namespace['_pb_trackable'](Obj(isAlive=False,hp=0,isWounded=False))
for roster in ([22],['22'],[Obj(id=22)],[{'id':'22'}],{'22':Obj()}):
    assert namespace['_pb_squad_member'](Obj(validBattleTeammates=roster),Obj(id=22))
    assert not namespace['_pb_squad_member'](Obj(validBattleTeammates=roster),Obj(id=23))
print('healer camera: native firing preserved, teammate-only rotation, downed priority, visibility/range, IDs and toggle isolation passed')
