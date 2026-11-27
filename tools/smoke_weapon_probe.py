"""Verify reload probing stays on the equipped weapon with two rails present."""
import ast
from pathlib import Path
from types import SimpleNamespace as Obj

source = Path(__file__).resolve().parents[1] / 'payload' / 'RosPayload.py'
tree = ast.parse(source.read_text(encoding='utf-8'))
probe = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == '_pb_ar_probe')
rifle_mag = Obj(bullet_count=5, magazine_capacity=30, ammo_box_bullet_count=70)
shot_mag = Obj(bullet_count=0, magazine_capacity=5, ammo_box_bullet_count=70)
rifle_rail = Obj(_magazine=rifle_mag, bulletCount=5, maxBullet=30, weaponID=101)
shot_rail = Obj(_magazine=shot_mag, bulletCount=0, maxBullet=5, weaponID=202)
rifle = Obj(_curRail=rifle_rail, weaponID=101)
shotgun = Obj(_curRail=shot_rail, weaponID=202)
hud = [5, 0]
player = Obj(dtsCurWeapon=1, dtsCurRailID=202, dtsWeapon1=Obj(weaponID=202),
             dtsWeaponMagazineBullets=hud, weapon_mgr=Obj(_weapon=shotgun))
env = {'_PB_GUN_SLOTS': (0, 1, 2, 6, 8, 9),
       '_PB_AMMO_ATTRS': ('bulletCount',), '_PB_MAX_ATTRS': ('maxBullet',),
       '_pb_ar_active_slot': lambda me: me.dtsCurWeapon,
       '_pb_ar_slot_gun_id': lambda me, slot: 202,
       '_pb_fire_objects': lambda me, active_only: [me, rifle, shotgun],
       '_pb_ar_read': lambda obj, name: getattr(obj, name, None),
       '_pb_is_mapping': lambda obj: False}
exec(compile(ast.Module(body=[probe], type_ignores=[]), str(source), 'exec'), env)
key, count, capacity, targets, reload_objs, gun_id, magazine = env['_pb_ar_probe'](player)
assert key == (1, 202, 202) and count == 0 and capacity == 5
assert magazine is shot_mag and shotgun in reload_objs and rifle not in reload_objs
assert all(obj is not rifle and obj is not rifle_rail and obj is not rifle_mag
           for obj, attr, idx in targets)
assert any(obj is hud and idx == 1 for obj, attr, idx in targets)
print('weapon probe smoke: selected shotgun; inactive rifle magazine untouched')
