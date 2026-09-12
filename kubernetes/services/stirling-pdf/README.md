# stirling-pdf

Restored with fresh 2 GiB `local-bulk` storage on 2026-09-12 by J's explicit request. The former namespace and PVC were already absent; no legacy storage recovery was attempted. Chart and image versions are preserved.

The existing Application name, service name, and `https://stirling-pdf.apps.home` route are retained. Auto-sync remains disabled; follow the repository's reviewed-sync protocol.

The pinned chart requires an explicit `storage-volume` mount at `/configs`. Uploaded files and bundled OCR assets remain ephemeral. The chart has no startup-probe option, so liveness waits 180 seconds for Java/LibreOffice initialization; readiness still controls when traffic reaches the pod.
