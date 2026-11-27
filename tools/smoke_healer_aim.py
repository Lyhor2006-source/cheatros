"""Exercise the shipped Healer Aim function without a game runtime."""
import ast
from pathlib import Path
from types import SimpleNamespace as Obj


source = Path(__file__).resolve().parents[1] / "payload" / "RosPayload.py"
tree = ast.parse(source.read_text(encoding="utf-8"))
aim = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "_pb_aim")
namespace = {"_PB_TRG": {}, "_pb_flag": lambda *_: False,
             "_pb_cam_pos": lambda me: me.position,
             "_pb_aim_screen": lambda p, *_: p,
             "_pb_vis": lambda *_: 1}
config = [0.0] * 46
config[2] = 200.0
config[8:11] = [100.0, 100.0, 100.0]
config[45] = 1.0
namespace["_pb_aimcfg"] = lambda: config
namespace["_pb_enemy"] = lambda *_: (_ for _ in ()).throw(AssertionError("enemy selected"))
namespace["_pb_boneworld"] = lambda entity, bone: entity.bones[bone]
exec(compile(ast.Module(body=[aim], type_ignores=[]), str(source), "exec"), namespace)

rotations = []
camera = Obj(onRotateCameraFromUser=lambda *args: rotations.append(args))
player = Obj(dtsCurRailID=90050, camCtrlComp=camera, position=Obj(x=0, y=0, z=0),
             getViewDirection=lambda: Obj(x=0, y=0, z=1))
enemy = Obj()
enemy_candidates = [(enemy, (40, 40), (40, 20), False, True, None, 10)]
namespace["_pb_aim"](player, enemy_candidates, tm_cands=[])
assert not rotations and namespace["_PB_TRG"]["selected"] == 0

teammate = Obj(bones={"chest": Obj(x=1, y=0, z=10)})
teammates = [(teammate, (50, 60), (50, 40), True, True,
              Obj(x=1, y=0, z=10), 10, 0, 100)]
namespace["_pb_aim"](player, enemy_candidates, tm_cands=teammates)
assert rotations and namespace["_PB_TRG"]["selected"] == 1
assert namespace["_PB_TRG"]["rotated"] == 1
print("healer aim smoke: no enemy fallback; teammate chest selected and camera rotated")
