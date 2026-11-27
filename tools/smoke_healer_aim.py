"""Exercise healer-only silent targeting without a game runtime."""
import ast
import sys
from pathlib import Path
from types import SimpleNamespace as Obj

source = Path(__file__).resolve().parents[1] / "payload" / "RosPayload.py"
tree = ast.parse(source.read_text(encoding="utf-8"))
names = {"_pb_healer_active", "_pb_aim", "_pb_silent", "_pb_nrs_install"}
functions = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names]
config = [0.0] * 46
config[2] = 30.0
config[8:12] = [100.0, 100.0, 100.0, 100.0]
config[11] = 0.0  # Reserved by the native writer; range is c[10].
config[45] = 1.0
namespace = {"_PB_TRG": {}, "_PB_NRS": {"sil": True}, "_PB_SIL": {"t": None, "tv": 0},
             "_pb_aimcfg": lambda: config, "_pb_vis": lambda *_: 1,
             "_pb_aim_screen": lambda point, *_: point,
             "_pb_ar_read": lambda obj, name: obj.get(name) if isinstance(obj, dict) else getattr(obj, name, None),
             "_pb_is_mapping": lambda obj: isinstance(obj, dict),
             "_pb_enemy": lambda *_: (_ for _ in ()).throw(AssertionError("enemy selected")),
             "_pb_boneworld": lambda entity, bone: entity.bones[bone]}
exec(compile(ast.Module(body=functions, type_ignores=[]), str(source), "exec"), namespace)

rotations = []
camera = Obj(onRotateCameraFromUser=lambda *args: rotations.append(args))
player = Obj(dtsCurRailID=90050, camCtrlComp=camera, position=Obj(x=0, y=0, z=0),
             getViewPos=lambda: Obj(x=0, y=0, z=0))
assert namespace["_pb_healer_active"](player, config)
player.dtsCurRailID = 20050
player.dtsCurWeapon = 0
player.dtsWeapon0 = {'weaponID': 90050}
assert namespace["_pb_healer_active"](player, config)
enemy_candidates = [(Obj(), (40, 40), (40, 20), False, True, None, 10)]
namespace["_pb_aim"](player, enemy_candidates, tm_cands=[])
namespace["_pb_silent"](player, enemy_candidates, [], [])
assert not rotations and namespace["_PB_SIL"]["t"] is None

teammate = Obj(bones={"chest": Obj(x=1, y=2, z=10)})
teammates = [(teammate, (50, 60), (50, 40), True, True,
              Obj(x=1, y=0, z=10), 10, 0, 100)]
namespace["_pb_aim"](player, enemy_candidates, tm_cands=teammates)
namespace["_pb_silent"](player, enemy_candidates, [], teammates)
assert not rotations and namespace["_PB_SIL"]["t"] == (1, 2, 10)
for feet, head, visible in [((50, 60), (50, 40), False),
                            ((150, 60), (150, 40), True)]:
    candidate = [(teammate, feet, head, True, visible,
                  Obj(x=1, y=0, z=10), 10, 0, 100)]
    namespace["_pb_silent"](player, enemy_candidates, [], candidate)
    assert namespace["_PB_SIL"]["t"] is None
wide_camera_candidate = [(teammate, (95, 60), (95, 40), True, True,
                          Obj(x=1, y=0, z=10), 10, 0, 100)]
namespace["_pb_silent"](player, enemy_candidates, [], wide_camera_candidate)
assert namespace["_PB_SIL"]["t"] == (1, 2, 10)
class MechanicalEvaluator:
    def getRayTrajectory(self):
        return []

module_name = "healer_smoke_mechanical_evaluator"
sys.modules[module_name] = Obj(MechanicalEvaluator=MechanicalEvaluator)
def wrap_ray(original):
    def wrapped(self):
        return original(self)
    return wrapped
namespace["_pb_wray"] = wrap_ray
try:
    namespace["_pb_nrs_install"]()
    assert namespace["_PB_NRS"]["cls"] is MechanicalEvaluator
    assert MechanicalEvaluator.getRayTrajectory._pb_silent_wrapped
finally:
    del sys.modules[module_name]
print("healer aim smoke: teammate-only silent target inside visible camera FOV")
