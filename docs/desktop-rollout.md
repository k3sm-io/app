# Cluster-managed desktop apps

An enrolled k3sm GUI polls its cluster using its existing user kubeconfig. The target app runs in the current console user's Aqua session. The DaemonSet pod only reads a readiness receipt. No controller, pod or remote shell receives the user's launch authority.

Create two private directories named `enrollments` and `revisions` beneath `~/Library/Application Support/io.k3sm.app/desktop-rollout/`. Set each directory's permissions to 0700. Create a separate receipt directory at the path mounted read-only by the local pod. The console user must own this directory and be its only writer. Give the runtime identity traversal and read access to receipts, with no create, replace, or delete rights anywhere in the path. Check inherited macOS ACLs on every ancestor. A shared build or scratch directory permitting the runtime identity to write is unsuitable. The manager checks permissions again before using these paths.

Place one local JSON file per deployment in `enrollments` with mode 0600. For example:

```json
{
  "uid": 501,
  "deployment": "example",
  "node": "studio",
  "bundleID": "com.example.desktop",
  "bundleName": "Example.app",
  "repository": "apps/example",
  "teamID": "A1B2C3D4E5",
  "receiptsRoot": "/absolute/path/to/desktop-receipts"
}
```

Use the actual console UID, Kubernetes node name, receipt path and trusted signing team. For an ad-hoc test build, supply `allowedCDHashes` containing the locally approved code directory hash of each permitted build, and omit `teamID`. Obtain these values from the trusted build receipt. An optional `adoptPath` can identify one existing signed, locally owned installation to hand off from and restore on initial failure. Otherwise enrollment requires that the app is already stopped. A running copy from another path, or multiple copies, blocks replacement.

Every 15 seconds k3sm checks the DaemonSet and its single nonterminating pod for this node in `k3sm-desktop`. During a rollout, it verifies the immutable OCI manifest and ZIP layer digest, validates the expanded bundle's identifier and signature, and requests a normal quit only from the enrolled app. It keeps versions under the private revision directory. A successful launch must finish in LaunchServices and retain the same PID before the receipt is published. A launch failure restores the previous verified bundle and holds that failed pod UID. A new pod UID permits another attempt. The receipt is atomically replaced with mode 0644, contains only the pod UID, manifest digest, bundle ID, PID and readiness, and is renewed after observing the matching live app. A stale or missing receipt is unready. When cluster state disappears, the helper withdraws readiness and leaves the desktop session alone. Removing enrollment stops renewal.

The bundled registry transfer script is the k3sm registry helper from `k3sm/hack/app-bundle.sh`. The GUI invokes only its immutable pull operation.
