#!/usr/bin/env bash
#MISE description="Upload the control-plane Talos image to the $ENVIRONMENT OVH OpenStack regions that do not have it"
# The control planes boot from this image, so run it before the first full
# apply of the OVH module (docs/01-bootstrap-guide.md). The workers need no
# upload: they are OVH BYOI servers, and OVH pulls their image from the Talos
# Factory when it installs them. The image facts (schematic, version, glance
# name, regions) and the OpenStack upload user come from the cp_image output of
# ovh/account, so nothing here has to match the module.
# The task talks to the Keystone and Glance APIs with curl. The token goes to a
# header file, never to a command line. Glance allows two images with one name,
# and the module then cannot pick one. So a region with an active image is
# skipped, a queued or killed image (what a failed or interrupted upload leaves)
# is deleted, and any other image with the name stops the task. Each upload can
# take an hour, so the regions upload at the same time. Each run downloads into
# its own directory, so two environments can upload at once.
set -euo pipefail
: "${ENVIRONMENT:?set ENVIRONMENT=staging (or production) first}"

cp_image="$(mise run //terraform/modules/ovh/account:output -- -json cp_image)"
name="$(jq -er .glance_name <<<"$cp_image")"
url="$(jq -er .download_url <<<"$cp_image")"
regions="$(jq -er '.regions[]' <<<"$cp_image")"
auth_url="$(jq -er .openstack.auth_url <<<"$cp_image")"

mkdir -p "$MISE_MONOREPO_ROOT/.private/dist"
dir="$(mktemp -d "$MISE_MONOREPO_ROOT/.private/dist/image.XXXXXX")"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$dir"' EXIT
jq '{auth: {identity: {methods: ["password"], password: {user: {name: .openstack.username, domain: {name: "Default"}, password: .openstack.password}}}, scope: {project: {id: .openstack.project_id}}}}' <<<"$cp_image" |
    curl --fail-with-body --silent --show-error --json @- --output "$dir/catalog.json" \
        --write-out 'X-Auth-Token: %header{x-subject-token}\n' "$auth_url/auth/tokens" >"$dir/auth"

api() {
    curl --fail-with-body --silent --show-error --header "@$dir/auth" "$@"
}
images_url() {
    jq -er --arg region "$1" '[.token.catalog[] | select(.type == "image") | .endpoints[] | select(.interface == "public" and .region == $region) | .url][0] | rtrimstr("/") + "/v2/images"' "$dir/catalog.json"
}

missing=""
for region in $regions; do
    base="$(images_url "$region")"
    images="$(api "$base?name=$name")"
    if [[ -n "$(jq -r '.next // empty' <<<"$images")" ]]; then
        echo "$region has more images named $name than one page of the image list holds. Delete the extra ones and run the task again." >&2
        exit 1
    fi
    for id in $(jq -r '.images[] | select(.status == "queued" or .status == "killed") | .id' <<<"$images"); do
        echo "Deleting the unfinished image $id in $region"
        api --request DELETE "$base/$id"
    done
    case "$(jq -r '[.images[] | select(.status != "queued" and .status != "killed") | .status] | join(" ")' <<<"$images")" in
    "") missing="$missing $region" ;;
    active) echo "$name is already active in $region" ;;
    *)
        echo "$region has images named $name with these statuses: $(jq -r '[.images[].status] | join(" ")' <<<"$images"). Wait for an upload in progress, or delete the extra images, then run the task again." >&2
        exit 1
        ;;
    esac
done
if [[ -z "$missing" ]]; then
    exit 0
fi

file="$dir/$name.raw"
curl --fail --location --silent --show-error "$url" | xz --decompress >"$file"

uploads=""
for region in $missing; do
    base="$(images_url "$region")"
    id="$(jq -n --arg name "$name" '{name: $name, disk_format: "raw", container_format: "bare", visibility: "shared", hw_qemu_guest_agent: "yes", img_config_drive: "mandatory"}' |
        api --json @- "$base" | jq -er .id)"
    echo "Uploading $name to $region"
    curl --fail-with-body --silent --show-error --header "@$dir/auth" \
        --header "Content-Type: application/octet-stream" --upload-file "$file" "$base/$id/file" &
    uploads="$uploads $region=$!"
done
failed=0
for entry in $uploads; do
    if wait "${entry#*=}"; then
        echo "Uploaded $name to ${entry%=*}"
    else
        echo "The upload to ${entry%=*} failed. Run the task again to retry it." >&2
        failed=1
    fi
done
exit "$failed"
