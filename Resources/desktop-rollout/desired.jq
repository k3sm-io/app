# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
$ds[0] as $controller
| select($controller.apiVersion == "apps/v1" and $controller.kind == "DaemonSet"
         and $controller.metadata.namespace == "k3sm-desktop" and $controller.metadata.name == $name
         and ($controller.metadata.uid | type) == "string" and $controller.metadata.deletionTimestamp == null)
| [.items[] | select(.metadata.namespace == "k3sm-desktop" and .metadata.deletionTimestamp == null
      and .spec.nodeName == $node and .metadata.labels["k3sm.io/desktop-app"] == $name
      and any(.metadata.ownerReferences[]?; .apiVersion == "apps/v1" and .controller == true and
              .kind == "DaemonSet" and .uid == $controller.metadata.uid and .name == $name)
      and .metadata.annotations["k3sm.io/app-bundle-id"] == $bundle
      and .metadata.annotations["k3sm.io/app-artifact"] == $controller.spec.template.metadata.annotations["k3sm.io/app-artifact"])]
| select(length == 1) | .[0].metadata | {podUID:.uid, podName:.name, artifact:.annotations["k3sm.io/app-artifact"]}
