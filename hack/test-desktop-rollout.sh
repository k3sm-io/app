#!/bin/bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
jq -n '{apiVersion:"apps/v1", kind:"DaemonSet", metadata:{name:"studio-app",namespace:"k3sm-desktop",uid:"owner"},
  spec:{template:{metadata:{annotations:{"k3sm.io/app-artifact":"apps/example@sha256:123"}}}}}' > "$fixture/ds"
jq -n '{items:[{metadata:{uid:"pod",name:"app-abc",namespace:"k3sm-desktop",
  labels:{"k3sm.io/desktop-app":"studio-app"},annotations:{"k3sm.io/app-artifact":"apps/example@sha256:123","k3sm.io/app-bundle-id":"com.example.app"},
  ownerReferences:[{apiVersion:"apps/v1",kind:"DaemonSet",uid:"owner",name:"studio-app",controller:true}]},spec:{nodeName:"studio"}}]}' > "$fixture/pods"
select_pod() {
    jq -e --slurpfile ds "$fixture/ds" --arg node studio --arg name studio-app --arg bundle com.example.app \
        -f "$root/Resources/desktop-rollout/desired.jq"
}
[[ $(select_pod < "$fixture/pods" | jq -r .podUID) == pod ]]
for edit in '.items[0].spec.nodeName="book"' '.items[0].metadata.ownerReferences[0].uid="old"' \
    '.items[0].metadata.annotations["k3sm.io/app-artifact"]="other"' '.items[0].metadata.deletionTimestamp="now"' \
    '.items[0].metadata.namespace="other"' '.items += .items'; do
    if jq "$edit" "$fixture/pods" | select_pod >/dev/null; then exit 1; fi
done
echo 'desktop rollout desired-state checks passed'
