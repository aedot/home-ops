<div align="center">
   <img src="https://raw.githubusercontent.com/aedot/home-ops/main/docs/src/assets/logo.png" align="center" width="144px" height="144px"/>
  <h3> My home operations repository </h3>
  <i>managed with Flux, Renovate and GitHub Actions</i> 🤖
</div>

---
<div align="center">

[![NixOS](https://img.shields.io/badge/NixOS-23.11-blue?style=for-the-badge&logo=nixos&logoColor=white)](https://nixos.org)
[![Kubernetes](https://img.shields.io/endpoint?url=https%3A%2F%2Fkromgo.devbu.io%2Fkubernetes_version&style=for-the-badge&logo=kubernetes&logoColor=white&color=blue&label=%20)](https://kubernetes.io)

[![renovate](https://img.shields.io/badge/renovate-enabled-%231A1F6C?logo=renovatebot)](https://developer.mend.io/github/aedot/home-ops)
![Code Comprehension](https://img.shields.io/badge/Code%20comprehension-2%25-red)

</div>

---
## 📖 Overview
Homelab infrastructure automation in IaC. GitOps practices using `Kubernetes`, `FluxCD`, `Renovate` and `GitHub Actions`.

### Directories

```sh
📁 cluster  #hold FluxCD config
```
## command
### SopS 
- encrypt
```
sops --encrypt --age $(grep -o "public key: .*" $SOPS_AGE_KEY_FILE | cut -d " " -f 3) --encrypted-regex '^(stringData)$' --in-place ./<file-name.extension>