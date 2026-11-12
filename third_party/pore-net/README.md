# Pore-Net attribution

Source: <https://github.com/ZombaSY/Pore-Net-release>, commit
`6f851e0d911bd73f41dd905c685129b13d52e1bc`, Apache License 2.0.

Authors: Sunyong Seo, Sangwook Yoo, Semin Kim, Daeun Yoon, Jongha Lee.
Paper: *Facial Pore Segmentation Algorithm using Shallow CNN*, CBMS 2022,
<https://doi.org/10.1109/CBMS55023.2022.00062>.

`backend/ruyuan/pore_net.py` adapts `models/model.py` (PoreNet_SC): it removes
training initializers and DataParallel, verifies the pinned tensor checkpoint,
and wraps the author's RGB normalization in the portable inference module.
`scripts/convert_pore_net.py` adds Core ML format conversion and numerical
checks. No training data or newly trained weights are claimed by this project.

Source weights/examples stay outside Git in ignored `backend/models/research`.
Exact file hashes and original URLs: `docs/models/pore-net-source.json`.
