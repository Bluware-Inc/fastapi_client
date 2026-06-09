#! /usr/bin/env bash

set -e
cd /generator-output

CMDNAME=${0##*/}

usage() {
  exitcode="$1"
  cat <<USAGE >&2

Postprocess the output of openapi-generator

Usage:
  $CMDNAME -p PACKAGE_NAME

Options:
  -p, --package-name       The name to use for the generated package
  -h, --help               Show this message
USAGE
  exit "$exitcode"
}

main() {
  validate_inputs
  merge_generated_models
  delete_unused
  fix_any_of
  fix_docs_path
  apply_formatters
}

validate_inputs() {
  if [ -z "$PACKAGE_NAME" ]; then
    echo "Error: you need to provide --package-name argument"
    usage 2
  fi
}

merge_generated_models() {
  # Need to merge the generated models into a single file to prevent circular imports
  # shellcheck disable=SC2046
  # shellcheck disable=SC2010
  cat $(ls "${PACKAGE_NAME}"/models/*.py | grep -v __init__) >"${PACKAGE_NAME}"/models.py
  rm -r "${PACKAGE_NAME}"/models >/dev/null 2>&1 || true

  if [ -n "$PYDANTIC_V2" ]; then
    # pydantic v2: guard with issubclass + __module__ so the loop never calls model_rebuild() on the
    # imported pydantic.BaseModel base (which raises in v2) and only rebuilds this module's models.
    echo "
import inspect
import sys
import io
import pydantic

IO = io.IOBase

current_module = sys.modules[__name__]

for model in inspect.getmembers(current_module, inspect.isclass):
    model_class = model[1]
    if issubclass(model_class, pydantic.BaseModel) and model_class.__module__ == current_module.__name__:
        model_class.model_rebuild()
" >> "${PACKAGE_NAME}"/models.py
  else
    # pydantic v1 (default): original loop, kept byte-for-byte so older releases regenerate
    # identically (no retest needed). Do not change this branch.
    echo "
import inspect
import sys
import io
import pydantic

IO = io.IOBase

current_module = sys.modules[__name__]

for model in inspect.getmembers(current_module, inspect.isclass):
    model_class = model[1]
    if isinstance(model_class, pydantic.BaseModel) or hasattr(model_class, \"update_forward_refs\"):
        model_class.update_forward_refs()
" >> "${PACKAGE_NAME}"/models.py
  fi
}

delete_unused() {
  # Delete empty folder
  rm -r "${PACKAGE_NAME}"/test >/dev/null 2>&1 || true

  rm "${PACKAGE_NAME}"/rest.py >/dev/null 2>&1 || true
  rm "${PACKAGE_NAME}"/configuration.py >/dev/null 2>&1 || true
}

fix_any_of() {
  if [ -z "$PYDANTIC_V2" ]; then
    # pydantic v1 (default): keep the original behavior EXACTLY so older releases regenerate
    # byte-for-byte identically (no retest needed). Do not change this branch.
    find . -name "*.py" -exec sed -i.bak "s/AnyOf[a-zA-Z0-9]*/Any/" {} \;
    find . -name "*.md" -exec sed -i.bak "s/AnyOf[a-zA-Z0-9]*/Any/" {} \;
    find . -name "*.bak" -exec rm {} \;
    return
  fi

  # pydantic v2: collapse synthetic anyOf schema names (e.g. AnyOfstringnull, AnyOfintegernull) to
  # `Any`. OpenAPI 'anyOf: [type, null]' params/fields generate these: model fields resolve to Any
  # via type-mappings, but API params emit `m.AnyOf...` (see _dataTypeApi.mustache isModel branch).
  # Done with a Python walk rather than find/sed -i because in-place sed over the bind-mounted output
  # can miss files in subdirectories (e.g. api/), which left the generated client unimportable.
  #   * .py  : rewrite the bare schema names to `Any`.
  #   * .md  : the docs link these synthetic schemas to non-existent pages (`[**Any**](AnyOf...md)`);
  #            strip the dangling link (keep the label), then normalize any leftover bare names.
  python - <<'PYEOF'
import os
import re

bare_ref = re.compile(r"AnyOf[A-Za-z0-9]*")
md_dead_link = re.compile(r"\[(.+?)\]\(AnyOf[A-Za-z0-9]*\.md\)")
for root, _dirs, files in os.walk("."):
    for name in files:
        is_py = name.endswith(".py")
        is_md = name.endswith(".md")
        if not (is_py or is_md):
            continue
        path = os.path.join(root, name)
        with open(path, encoding="utf-8") as handle:
            original = handle.read()
        if is_py:
            updated = bare_ref.sub("Any", original)
        else:
            updated = md_dead_link.sub(r"\1", original)
            updated = bare_ref.sub("Any", updated)
        if updated != original:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(updated)
PYEOF
}

fix_docs_path() {
  sed -i -e "s="${PACKAGE_NAME}"/docs=docs=" "${PACKAGE_NAME}"_README.md
}

apply_formatters() {
  autoflake --remove-all-unused-imports --recursive --remove-unused-variables --in-place "${PACKAGE_NAME}" --exclude=__init__.py
  isort --float-to-top -w 120 -m 3 --trailing-comma --force-grid-wrap 0 --combine-as -p "${PACKAGE_NAME}" "${PACKAGE_NAME}"
  black --fast -l 120 --target-version py36 "${PACKAGE_NAME}"
}

while [ $# -gt 0 ]; do
  case "$1" in
  -p | --package-name)
    PACKAGE_NAME=$2
    shift 2
    ;;
  -h | --help)
    usage 0
    ;;
  *)
    echo "Unknown argument: $1"
    usage 1
    ;;
  esac
done

main
