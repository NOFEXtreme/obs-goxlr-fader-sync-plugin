#!/bin/bash
set -euo pipefail

tag=${GITHUB_REF_NAME:?}
api="repos/${GITHUB_REPOSITORY:?}"
commit=$(git rev-parse HEAD)
files=(
    artifacts/windows-artifacts/FaderSyncPlugin-win-x64-installer.exe
    artifacts/windows-artifacts/FaderSyncPlugin-win-x64.zip
    artifacts/windows-artifacts/FaderSyncPlugin-win-x64-obs32.zip
    artifacts/windows-artifacts/FaderSyncPlugin-win-x64-portable.zip
    artifacts/linux-artifacts/FaderSyncPlugin-linux-x64.zip
    artifacts/SHA256SUMS.txt
)

check_tag() {
    refs=$(git ls-remote --tags origin "refs/tags/$tag" "refs/tags/$tag^{}")
    tagged=$(awk 'NR == 1 || $2 ~ /\^\{\}$/ { sha = $1 } END { print sha }' <<< "$refs")
    if [[ "$tagged" != "$commit" ]]; then
        echo "Tag $tag points to ${tagged:-no commit}, expected $commit." >&2
        exit 1
    fi
}

number='(0|[1-9][0-9]*)'
if [[ "${GITHUB_REF_TYPE:-}" != tag || ! "$tag" =~ ^v$number\.$number\.$number(-beta\.$number)?$ ]]; then
    echo "Expected a stable or beta version tag, got $tag." >&2
    exit 1
fi
prerelease=false
if [[ "$tag" == *-beta.* ]]; then prerelease=true; fi
check_tag

read_release() {
    local response delay
    for delay in 1 2 4 0; do
        if response=$(gh api "$api/releases/$id" 2>&1); then
            printf '%s\n' "$response"
            return
        fi
        printf '%s\n' "$response" >&2
        if [[ "$response" != *'(HTTP 404)'* ]] || (( delay == 0 )); then return 1; fi
        sleep "$delay"
    done
}

matches_release() {
    jq -e --arg tag "$tag" --arg commit "$commit" --argjson pre "$prerelease" --argjson draft "$1" \
        '.tag_name == $tag and .target_commitish == $commit and .prerelease == $pre and .draft == $draft' > /dev/null
}

expected_names=$(printf '%s\n' "${files[@]##*/}" | LC_ALL=C sort)
id=$(gh api --paginate "$api/releases?per_page=100" --jq ".[] | select(.tag_name == \"$tag\") | .id")
if [[ -n "$id" ]]; then
    if [[ ! "$id" =~ ^[0-9]+$ ]]; then
        echo "Multiple releases found for $tag." >&2
        exit 1
    fi
    release=$(read_release)
    if matches_release false <<< "$release"; then
        names=$(jq -r '.assets[] | select(.state == "uploaded") | .name' <<< "$release" | LC_ALL=C sort)
        [[ "$names" == "$expected_names" ]] || { echo "Unexpected asset list for published release $tag." >&2; exit 1; }
        printf 'Release `%s` already exists at `%s`.\n' "$tag" "$commit" >> "$GITHUB_STEP_SUMMARY"
        exit 0
    fi
else
    release=$(gh api --method POST "$api/releases" \
        -f tag_name="$tag" -f target_commitish="$commit" -f name="Release $tag" \
        -F draft=true -F prerelease="$prerelease" -F generate_release_notes=true -f make_latest=false)
    id=$(jq -er '.id | numbers' <<< "$release")
fi

if ! matches_release true <<< "$release"; then
    echo "Draft $tag does not match commit $commit or the expected release type." >&2
    exit 1
fi

asset_digests() {
    jq -r '.assets[] | "\(if .state == "uploaded" then .digest else .state end)  \(.name)"' | LC_ALL=C sort
}

expected=$(sha256sum -- "${files[@]}" | awk '{sub(/^.*\//, "", $2); print "sha256:" $1 "  " $2}' | LC_ALL=C sort)
unexpected=$(LC_ALL=C comm -13 <(printf '%s\n' "$expected") <(asset_digests <<< "$release"))
if [[ -n "$unexpected" ]]; then
    echo "Draft $tag contains an unexpected or unverified asset." >&2
    exit 1
fi

for file in "${files[@]}"; do
    name=${file##*/}
    if jq -e --arg name "$name" 'any(.assets[]; .name == $name)' <<< "$release" > /dev/null; then continue; fi
    gh api --method POST "https://uploads.github.com/$api/releases/$id/assets?name=$name" \
        -H 'Content-Type: application/octet-stream' --input "$file" --silent
done

release=$(read_release)
matches_release true <<< "$release"
uploaded=$(asset_digests <<< "$release")
if [[ "$expected" != "$uploaded" ]]; then
    echo "Draft $tag does not contain the exact verified artifacts for $commit." >&2
    diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$uploaded") || true
    exit 1
fi

check_tag
latest=true
if [[ "$prerelease" == true ]]; then latest=false; fi
gh api --method PATCH "$api/releases/$id" -F draft=false -f make_latest="$latest" | matches_release false
printf 'Published `%s` at `%s` with all six verified assets.\n' "$tag" "$commit" >> "$GITHUB_STEP_SUMMARY"
