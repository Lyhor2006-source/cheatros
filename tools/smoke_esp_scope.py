"""Guard against reading ESP entity fields before they are populated."""
import ast
from pathlib import Path

source = Path(__file__).resolve().parents[1] / 'payload' / 'RosPayload.py'
tree = ast.parse(source.read_text(encoding='utf-8'))
esp = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == '_pb_esp')
uses = sorted((n.lineno, type(n.ctx).__name__) for n in ast.walk(esp)
              if isinstance(n, ast.Name) and n.id == 'on')
assert uses and uses[0][1] == 'Store', uses
assert all(line >= uses[0][0] for line, kind in uses if kind == 'Load'), uses
print('ESP scope smoke: on-screen flag assigned before entity filtering')
