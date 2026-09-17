set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']

[group: 'bootstrap']
mod? bootstrap 'bootstrap'

[group: 'kubernetes']
mod? kube 'kubernetes'

[group: 'talos']
mod? talos 'talos'

[private]
default:
    just -l

[doc('Render a Jinja2 template and resolve bws:// secret refs')]
template file *args:
    minijinja-cli --env --autoescape=none "{{ file }}" {{ args }} | "{{ justfile_directory() }}/scripts/bws-inject.sh"

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}
