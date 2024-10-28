<div align="center">
  <img src="https://raw.githubusercontent.com/aedot/home-ops/main/docs/assets/logo.png" align="center" width="144px" height="144px"/>
  <h3> My home operations repository </h3>
  <i>managed with Flux, Renovate and GitHub Actions</i> 🤖
</div>

---

## 📖 Overview

This is a monorepo for my homelab infrastructure automation deploy with [Talos](https://www.talos.dev). I try to adhere (as much as I reasonably can 😅) to Infrastructure as Code (IaC) and GitOps practices using the tools like `Kubernetes`, `FluxCD`, `Renovate` and `GitHub Actions`.

### Directories

This Git repository contains the following directories under [Kubernetes](./kubernetes/).

```sh
📁 kubernetes
├── 📁 main            # main cluster
│   ├── 📁 apps           # applications
│   ├── 📁 bootstrap      # bootstrap procedures
│   ├── 📁 flux           # core flux configuration
│   └── 📁 templates      # re-useable components
└── 📁 ...             # other clusters
```

## 🤝 Gratitude and Thanks

There is a template over at [onedr0p/flux-cluster-template](https://github.com/onedr0p/flux-cluster-template).

Thanks to all the people who donate their time to the [Kubernetes @Home](https://discord.gg/k8s-at-home) Discord community. A lot of inspiration for my cluster comes from the people that have shared their clusters using the [k8s-at-home](https://github.com/topics/k8s-at-home) GitHub topic. Be sure to check out the [Kubernetes @Home search](https://nanne.dev/k8s-at-home-search/) for ideas on how to deploy applications or get ideas on what you can deploy.

