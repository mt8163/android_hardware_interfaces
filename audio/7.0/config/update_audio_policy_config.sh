#!/bin/bash
# tools/audio/update_apm_config_v7.sh
set -euo pipefail

usage() {
  cat <<'EOF'
Update Audio Policy Manager config file to V7.0 list-separator rules.

USAGE:
  update_apm_config_v7.sh [--yes] [--dry-run] [--debug] APM_XML_FILE [OLD_VERSION]

FLAGS:
  -y, --yes     Non-interactive; proceed without prompt.
      --dry-run Show planned edits; do not modify files.
      --debug   Shell trace.

EXAMPLE:
  update_apm_config_v7.sh -y device/.../audio_policy_configuration.xml 6.0
EOF
}

YES=0
DRYRUN=0
DEBUG=0
ARGS=()

for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    -y|--yes) YES=1 ;;
    --dry-run) DRYRUN=1 ;;
    --debug) DEBUG=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
[[ $DEBUG -eq 1 ]] && set -x

if [[ ${#ARGS[@]} -lt 1 ]]; then
  echo "APM_XML_FILE required."; usage; exit 2
fi

readonly HAL_DIRECTORY=hardware/interfaces/audio
readonly SHARED_CONFIGS_DIRECTORY=frameworks/av/services/audiopolicy/config
readonly NEW_VERSION=7.0
readonly NEW_VERSION_UNDERSCORE=7_0

: "${ANDROID_BUILD_TOP:?ANDROID_BUILD_TOP must be set}"

readonly SOURCE_CONFIG="${ANDROID_BUILD_TOP}/${ARGS[0]}"
readonly OLD_VERSION="${ARGS[1]:-$(
  ls "${ANDROID_BUILD_TOP}/${HAL_DIRECTORY}" | grep -E '[0-9]+\.[0-9]+' \
    | sort -n | tail -n1
)}"

# Confirm step: skip if non-TTY or --yes
confirm() {
  if [[ $YES -eq 1 || ! -t 0 ]]; then
    return 0
  fi
  echo "Will update ${ARGS[0]} and included device-specific files in place."
  echo "Will update paths to shared included files."
  read -r -p "Continue? [Enter=Yes, Ctrl-C=Cancel] " _
}

# xmllint may be chatty; warn where it is
echo "Validating source against ${OLD_VERSION} schema..."
xmllint --noout --xinclude \
  --nofixup-base-uris \
  --path "${ANDROID_BUILD_TOP}/${SHARED_CONFIGS_DIRECTORY}" \
  --schema \
  "${ANDROID_BUILD_TOP}/${HAL_DIRECTORY}/${OLD_VERSION}/config/audio_policy_configuration.xsd" \
  "${SOURCE_CONFIG}"

SOURCE_FILES="${SOURCE_CONFIG}"
SHARED_FILES=""

find_includes() {
  local to_check=""
  while IFS= read -r F; do
    mapfile -t incs < <(grep -Po '<xi:include href="\K[^"]+(?="\/>)' "${F}" || true)
    for I in "${incs[@]}"; do
      local source_full; source_full="$(dirname "${F}")/${I}"
      local shared_full; shared_full="${ANDROID_BUILD_TOP}/${SHARED_CONFIGS_DIRECTORY}/${I}"
      if [[ -f "${source_full}" ]]; then
        SOURCE_FILES+=$'\n'"${source_full}"
        to_check+=$'\n'"${source_full}"
      elif [[ -f "${shared_full}" ]]; then
        SHARED_FILES+=$'\n'"${I}"
        to_check+=$'\n'"${shared_full}"
      else
        echo "Include file not found: ${I}" >&2
        exit 1
      fi
    done
  done <<<"${1}"
  if [[ -n "${to_check}" ]]; then
    find_includes "${to_check}"
  fi
}
find_includes "${SOURCE_FILES}"

confirm

apply_sed_inplace() {
  if [[ $DRYRUN -eq 1 ]]; then
    sed -E "$@" </dev/null >/dev/null || true
  else
    sed -E -i "$@"
  fi
}

# 1) Bump version in main file only
apply_sed_inplace '0,/(audioPolicyConfiguration version=")1\.0/s//\17.0/' \
  "${SOURCE_CONFIG}"

# 2) Robust attribute separator normalizer
update_attr_separators() {
  local file="$1" attr="$2" sep="$3"
  local s="${sep//\//\\/}"
  local d='|'; [[ "${s}" == '|' ]] && d='/'
  if [[ $DRYRUN -eq 1 ]]; then
    echo "[dry-run] normalize ${attr} in ${file} (sep='${sep}')"
  else
    :
  fi
  apply_sed_inplace ":a; s/(${attr}=\"[^\"]*)${d}${s}${d}([^\"\n]*\")/\1 \2/g; ta" "${file}"
}

normalize_files() {
  while IFS= read -r F; do
    [[ -z "${F}" ]] && continue
    update_attr_separators "${F}" "channelMasks" ","
    update_attr_separators "${F}" "samplingRates" ","
    update_attr_separators "${F}" "flags" "|"
    update_attr_separators "${F}" "sources" ","
  done <<<"${SOURCE_FILES}"
}
normalize_files

# 3) Update shared includes if *_7_0.xml exists
update_includes() {
  local file="$1"
  while IFS= read -r I; do
    [[ -z "${I}" ]] && continue
    local new="${I%.*}_${NEW_VERSION_UNDERSCORE}.${I##*.}"
    if [[ -e "${ANDROID_BUILD_TOP}/${SHARED_CONFIGS_DIRECTORY}/${new}" ]]; then
      apply_sed_inplace "s#(<xi:include href=\")${I}(\"/>)#\1${new}\2#g" "${file}"
    fi
  done <<<"${SHARED_FILES}"
}
while IFS= read -r F; do
  [[ -z "${F}" ]] && continue
  update_includes "${F}"
done <<<"${SOURCE_FILES}"

echo "Validating result against ${NEW_VERSION} schema..."
xmllint --noout --xinclude \
  --nofixup-base-uris \
  --path "${ANDROID_BUILD_TOP}/${SHARED_CONFIGS_DIRECTORY}" \
  --schema \
  "${ANDROID_BUILD_TOP}/${HAL_DIRECTORY}/${NEW_VERSION}/config/audio_policy_configuration.xsd" \
  "${SOURCE_CONFIG}"

echo "Done."
[[ $DRYRUN -eq 1 ]] && echo "(dry-run: no files modified)"
