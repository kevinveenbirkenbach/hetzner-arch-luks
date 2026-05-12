# Top-level targets for the hetzner-arch-luks helper package.
#
# Usage:
#   make install         # editable install for the current user
#   make uninstall
#   make clean           # remove Python build artifacts
#   make check           # quick smoke tests (imports + --help)

PYTHON ?= python3
PIP    ?= $(PYTHON) -m pip

.DEFAULT_GOAL := help
.PHONY: help install install-system uninstall clean check

help:
	@echo "Targets:"
	@echo "  install         pip install --user -e ."
	@echo "  install-system  pip install -e .   (system-wide; needs sudo or venv)"
	@echo "  uninstall       remove the installed package"
	@echo "  clean           remove __pycache__, *.egg-info, build/, dist/"
	@echo "  check           run package smoke tests"

install:
	$(PIP) install --user -e .

install-system:
	$(PIP) install -e .

uninstall:
	$(PIP) uninstall -y hetzner-arch-luks

clean:
	rm -rf build dist
	find . -type d -name '__pycache__' -prune -exec rm -rf {} +
	find . -type d -name '*.egg-info' -prune -exec rm -rf {} +

check:
	$(PYTHON) -m hetzner_arch_luks --help >/dev/null
	$(PYTHON) -c "from hetzner_arch_luks import cli, ssh, probe, remote; print('imports OK')"
