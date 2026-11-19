# 技术栈适配：Python。uv.lock / poetry.lock 存在时经 uv run / poetry run 执行，否则使用当前已激活的环境。
# 本地请先激活项目虚拟环境（conda / venv / uv）；依赖只在 CI（CI=true）时自动安装。

python_detect() { manifest_dirs pyproject.toml setup.py setup.cfg requirements.txt; }

python_bin() { if command -v python3 >/dev/null 2>&1; then echo python3; else echo python; fi; }

py_run() {
  if [ -f uv.lock ] && command -v uv >/dev/null 2>&1; then uv run "$@"
  elif [ -f poetry.lock ] && command -v poetry >/dev/null 2>&1; then poetry run "$@"
  else "$@"
  fi
}

python_install() {
  [ "${CI:-}" = true ] || return 0
  local mark
  mark=$GATE_TMP/py-installed-$(printf '%s' "$PWD" | cksum | awk '{print $1}')
  [ ! -f "$mark" ] || return 0
  : > "$mark"
  if [ -f uv.lock ]; then uv sync
  elif [ -f poetry.lock ]; then poetry install
  elif [ -f requirements-dev.txt ]; then pip install -r requirements-dev.txt
  elif [ -f requirements.txt ]; then pip install -r requirements.txt
  elif [ -f pyproject.toml ]; then pip install -e ".[dev]" || pip install -e .
  fi
}

python_uses_pytest() {
  [ -f pytest.ini ] || [ -f conftest.py ] || [ -f tests/conftest.py ] \
    || grep -qs '^\[tool\.pytest' pyproject.toml || grep -qs '^\[tool:pytest\]' setup.cfg \
    || grep -qsi '^pytest' requirements*.txt
}

python_pytest() { # <marker 表达式>；没有匹配的测试（退出码 5）视为跳过
  local rc=0
  echo "  \$ pytest -q -m \"$1\""
  py_run "$(python_bin)" -m pytest -q -m "$1" || rc=$?
  if [ "$rc" = 5 ]; then echo "  · 没有匹配的测试（跳过）"; return 0; fi
  return "$rc"
}

python_lint() {
  python_install
  if py_run ruff --version >/dev/null 2>&1; then
    echo "  \$ ruff check ."; py_run ruff check .
  else
    echo "  · 未安装 ruff（跳过）"
  fi
  if grep -qs '^\[tool\.mypy' pyproject.toml || [ -f mypy.ini ] || [ -f .mypy.ini ]; then
    echo "  \$ mypy ."; py_run mypy .
  fi
}

python_unit() {
  python_install
  if python_uses_pytest; then
    python_pytest "not integration and not e2e and not slow"
  elif [ -d tests ]; then
    local rc=0
    echo "  \$ python -m unittest discover -s tests -t ."
    py_run "$(python_bin)" -m unittest discover -s tests -t . || rc=$?
    if [ "$rc" = 5 ]; then echo "  · 没有测试（跳过）"; return 0; fi
    return "$rc"
  else
    echo "  · 没有 tests/ 也没有 pytest 配置（跳过）"
  fi
}

python_marker_step() {
  if python_uses_pytest; then python_install; python_pytest "$1"; else echo "  · 未配置 pytest，$1 跳过"; fi
}
python_integration() { python_marker_step integration; }
python_e2e()         { python_marker_step e2e; }
python_slow()        { python_marker_step slow; }
