set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']

[private]
default:
    just talos -l

[confirm('Apply Talos config to ' + node + ' — continue? [y/N]')]
[doc('Apply Talos config to a node')]
[group('talos')]
apply-node node *args:
    just talos render-config {{ node }} | talosctl -n {{ node }} apply-config -f /dev/stdin {{ args }}

[doc('Render the merged Talos machine config for a node')]
[group('talos')]
render-config node:
    TYPE="$(just talos machine-type {{ node }})"
    export SCHEMATIC="$(just talos schematic-id)"
    talosctl machineconfig patch <(just template "{{ source_directory() }}/cluster.yaml.j2" "{{ source_directory() }}/talenv.yaml") \
        -p @<(just template "{{ source_directory() }}/networking.yaml.j2") \
        -p @<(just template "{{ source_directory() }}/nodes/{{ node }}.yaml.j2") \
        -p @<(just template "{{ source_directory() }}/${TYPE}.yaml.j2")

[doc('Validate the merged Talos machine config for a node')]
[group('talos')]
validate-config node:
    just talos render-config {{ node }} | talosctl validate -m metal -c /dev/stdin

[confirm('Reboot node ' + node + ' — continue? [y/N]')]
[doc('Reboot a node')]
[group('talos')]
reboot-node node *args:
    talosctl -n {{ node }} reboot {{ args }}

[confirm('Shutdown node ' + node + ' — continue? [y/N]')]
[doc('Shutdown a node')]
[group('talos')]
shutdown-node node *args:
    talosctl -n {{ node }} shutdown --force {{ args }}

[confirm('This resets ' + node + ' to maintenance mode (DESTRUCTIVE) — continue? [y/N]')]
[doc('Reset a single node back to maintenance mode (DESTRUCTIVE)')]
[group('talos')]
reset-node node *args:
    talosctl -n {{ node }} reset \
        --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL \
        --reboot --graceful=false --wait=false {{ args }}

[confirm('This ALSO wipes the Longhorn data disk /dev/nvme0n1 on ' + node + ' — ALL storage is destroyed. Continue? [y/N]')]
[doc('Reset a single node AND wipe its Longhorn data disk /dev/nvme0n1 (DESTRUCTIVE)')]
[group('talos')]
reset-node-wipe-data node *args:
    talosctl -n {{ node }} reset \
        --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL \
        --user-disks-to-wipe /dev/nvme0n1 \
        --reboot --graceful=false --wait=false {{ args }}

[confirm('Upgrade Kubernetes on the cluster — continue? [y/N]')]
[doc('Upgrade Kubernetes to the version in talenv.yaml')]
[group('talos')]
upgrade-k8s:
    talosctl upgrade-k8s --to "$(yq -r -e '.kubernetesVersion' "{{ source_directory() }}/talenv.yaml")"

[confirm('Upgrade Talos on ' + node + ' — continue? [y/N]')]
[doc('Upgrade Talos on a single node to the schematic + version in talenv.yaml')]
[group('talos')]
upgrade-node node *args:
    talosctl -n {{ node }} upgrade -i "$(just talos machine-image)" -m powercycle --timeout=10m {{ args }}

[doc('Generate a Talos factory schematic ID from schematic.yaml.j2')]
[group('talos')]
schematic-id:
    curl -sX POST --data-binary @<(just template "{{ source_directory() }}/schematic.yaml.j2") "https://factory.talos.dev/schematics" | jq -r '.id'

[private]
machine-type node:
    just template "{{ source_directory() }}/nodes/{{ node }}.yaml.j2" | yq -r -e 'select(.machine) | .machine.type'

[private]
machine-image:
    echo "factory.talos.dev/metal-installer/$(just talos schematic-id):$(yq -r -e '.talosVersion' "{{ source_directory() }}/talenv.yaml")"
