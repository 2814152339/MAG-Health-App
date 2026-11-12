# RihemXX/Acnes binary segmentation attribution

- Author repository: https://github.com/rihem-bs02/Acnes
- Author GitHub revision: `826e2adfc7d85c4cf9f3ffa3a68b82d24d3baeb7`
- Tensor checkpoint: https://huggingface.co/spaces/RihemXX/Acnes
- Checkpoint revision: `79182ede8d14cb44de63b4f6ace1fa2a5a7a3d83`
- License: Apache-2.0, as indicated by the Space metadata and the author's GitHub `LICENSE`; the latter is retained verbatim here.
- SHA-pinned sources and notices: `docs/models/acne-segmentation-source.json`.

The independent Ruyuan adapter reconstructs SMP's U-Net ResNet34 with no encoder download, loads only the verified tensor state with `weights_only=True`, embeds RGB normalization, adds explicit readiness and optional skin ROI gating. Downloaded notebooks are never executed. The original model's training-image provenance, consent, pixel-label protocol and subject-disjoint evaluation materials have not been disclosed. The author README's claimed IoU is not an Ruyuan validation result. No image, original checkpoint, or optimizer is included in Git.
