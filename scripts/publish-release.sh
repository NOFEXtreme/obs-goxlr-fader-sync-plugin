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

release_id() {
    gh api --paginate "$api/releases?per_page=100" --jq ".[] | select(.tag_name == \"$tag\") | .id"
}

expected_names=$(printf '%s\n' "${files[@]##*/}" | LC_ALL=C sort)
id=$(release_id)
if [[ -n "$id" ]]; then
    release=$(gh api "$api/releases/$id")
    if ! jq -e --arg tag "$tag" --arg commit "$commit" --argjson pre "$prerelease" \
        '.tag_name == $tag and .target_commitish == $commit and .prerelease == $pre' <<< "$release" > /dev/null; then
        echo "Existing release $tag does not match commit $commit or the expected release type." >&2
        exit 1
    fi
    if jq -e '.draft == false' <<< "$release" > /dev/null; then
        names=$(jq -r '.assets[] | select(.state == "uploaded") | .name' <<< "$release" | LC_ALL=C sort)
        if [[ "$names" != "$expected_names" ]]; then
            echo "Published release $tag has an unexpected asset list." >&2
            exit 1
        fi
        printf 'Release `%s` already exists at `%s`.\n' "$tag" "$commit" >> "$GITHUB_STEP_SUMMARY"
        exit 0
    fi
else
    options=(--draft --verify-tag --target "$commit" --title "Release $tag" --generate-notes)
    if [[ "$prerelease" == true ]]; then options+=(--prerelease --latest=false); fi
    gh release create "$tag" "${files[@]}" "${options[@]}"
    id=$(release_id)
    release=$(gh api "$api/releases/$id")
fi

jq -e --arg tag "$tag" --arg commit "$commit" --argjson pre "$prerelease" \
    '.draft and .tag_name == $tag and .target_commitish == $commit and .prerelease == $pre' <<< "$release" > /dev/null
expected=$(sha256sum -- "${files[@]}" | awk '{sub(/^.*\//, "", $2); print "sha256:" $1 "  " $2}' | LC_ALL=C sort)
uploaded=$(jq -r '.assets[] | select(.state == "uploaded") | "\(.digest)  \(.name)"' <<< "$release" | LC_ALL=C sort)
if [[ "$expected" != "$uploaded" ]]; then
    echo "Draft $tag does not contain the exact verified artifacts for $commit." >&2
    diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$uploaded") || true
    exit 1
fi

check_tag
gh release edit "$tag" --draft=false --prerelease="$prerelease" --latest="$([[ "$prerelease" == true ]] && echo false || echo true)" --verify-tag
gh api "$api/releases/$id" | jq -e --argjson pre "$prerelease" '(.draft == false) and (.prerelease == $pre)' > /dev/null
printf 'Published `%s` at `%s` with all six verified assets.\n' "$tag" "$commit" >> "$GITHUB_STEP_SUMMARY"
