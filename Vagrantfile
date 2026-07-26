# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# VagrantLab-Talos
# ----------------
# Brings up a Talos Linux cluster on VirtualBox.
#
# The TOPOLOGY (node count, network, addressing) lives in `lab.env` (gitignored),
# the single source shared with talos/cluster-up.sh. Start from the template:
#     cp lab.env.example lab.env
#
# Talos specifics:
#   - Talos has NO SSH: everything is driven with `talosctl` from the host.
#     => we register a "dummy communicator" so that `vagrant up` does not
#        wait for an SSH connection that will never come.
#   - Talos has no official Vagrant box: we start from an EMPTY box
#     (pace/empty) and boot it off the `metal-amd64.iso` ISO.
#   - Vagrant cannot configure the IP inside the guest (no SSH): IPs are
#     pinned deterministically through per-MAC DHCP reservations on the
#     host-only network (see the `before :up` trigger).
#
# Full workflow: see README.md

require 'shellwords'

##############################################################################
# Lab parameters — loaded from lab.env (single source, see cluster-up.sh).
# A real environment variable wins (e.g. `WORKERS=6 vagrant up`).
##############################################################################

lab_env = File.join(__dir__, "lab.env")
if File.exist?(lab_env)
  File.foreach(lab_env) do |line|
    next if line =~ /\A\s*(#|$)/           # skip comments and blank lines
    key, val = line.strip.split("=", 2)
    ENV[key] ||= val if key && val         # ||= : a real env var stays authoritative
  end
end

# Default ALIGNED with the one in talos/cluster-up.sh: without lab.env, the two files
# used to fall back to different versions (ISO v1.13.5 / installer v1.13.7).
TALOS_VERSION  = ENV["TALOS_VERSION"] || "v1.13.7"   # https://github.com/siderolabs/talos/releases

CONTROL_PLANES = (ENV["CONTROL_PLANES"] || 3).to_i   # 1 = single node; 3 = HA (with VIP)
WORKERS        = (ENV["WORKERS"] || 3).to_i          # number of workers

# Resources per role — driven from lab.env (a real env var wins).
CP_MEM  = (ENV["CP_MEM"] || 4096).to_i ; CP_CPU = (ENV["CP_CPU"] || 2).to_i  # control plane
WK_MEM  = (ENV["WK_MEM"] || 2048).to_i ; WK_CPU = (ENV["WK_CPU"] || 2).to_i  # worker

NETWORK      = ENV["NETWORK"] || "192.168.56"    # host-only network
VIP          = ENV["VIP"] || "#{NETWORK}.5"      # Kubernetes API VIP (HA)
HOST_IP      = "#{NETWORK}.1"                     # host-only gateway
DISK_SIZE_MB = 20480                             # install disk per node (20 GB)

# Host-only addressing scheme (defined in lab.env):
#   control plane i -> NETWORK.(CP_IP_START + (i-1)*CP_IP_STEP)  => .10, .20, .30, ...
#   worker       i  -> NETWORK.(WK_IP_START + (i-1)*WK_IP_STEP)  => .101, .102, .103, ...
CP_IP_START = (ENV["CP_IP_START"] || 10).to_i  ; CP_IP_STEP = (ENV["CP_IP_STEP"] || 10).to_i
WK_IP_START = (ENV["WK_IP_START"] || 101).to_i ; WK_IP_STEP = (ENV["WK_IP_STEP"] || 1).to_i

ISO_PATH   = File.join(__dir__, "iso", "metal-amd64.iso")
DISKS_DIR  = File.join(__dir__, ".vagrant", "talos-disks")

##############################################################################
# Building the node list
#   CP    : talos-cp1=.10, talos-cp2=.20, ...   (see CP_IP_START / CP_IP_STEP)
#   Worker: talos-w1=.101, talos-w2=.102, ...   (see WK_IP_START / WK_IP_STEP)
#   The VM name IS the Talos hostname. The MAC stays indexed by `idx` (unique).
##############################################################################

servers = []
idx = 0
(1..CONTROL_PLANES).each do |i|
  idx += 1
  servers << { name: ("talos-cp%d" % i), role: "controlplane",
               ip: "#{NETWORK}.#{CP_IP_START + (i - 1) * CP_IP_STEP}", mac: ("080027AA00%02X" % idx),
               mem: CP_MEM, cpu: CP_CPU }
end
(1..WORKERS).each do |i|
  idx += 1
  servers << { name: ("talos-w%d" % i), role: "worker",
               ip: "#{NETWORK}.#{WK_IP_START + (i - 1) * WK_IP_STEP}", mac: ("080027AA00%02X" % idx),
               mem: WK_MEM, cpu: WK_CPU }
end

# Guard rail: .100 = VirtualBox's DEFAULT host-only DHCP server (reserved);
# .1/.2/.5 = gateway / DHCP server / VIP. A node must never land on one of
# them (depends on the addressing scheme above: e.g. 10 CPs => .100).
reserved_ips = ["#{NETWORK}.1", "#{NETWORK}.2", "#{NETWORK}.5", "#{NETWORK}.100"]
servers.each do |s|
  if reserved_ips.include?(s[:ip])
    raise "VagrantLab-Talos: IP #{s[:ip]} (#{s[:name]}) is reserved " \
          "(#{reserved_ips.join(', ')}). Lower CONTROL_PLANES/WORKERS."
  end
end

##############################################################################
# "dummy communicator": makes `ready?` always true so that Vagrant does not
# hang waiting for SSH (Talos exposes no SSH).
##############################################################################

module VagrantPlugins
  module DummyCommunicator
    class Plugin < Vagrant.plugin("2")
      name "dummy_communicator"
      communicator("dummy") { Communicator }
    end

    class Communicator < Vagrant.plugin("2", :communicator)
      def initialize(machine) ; @machine = machine ; end
      def ready? ; true ; end
      def wait_for_ready(_timeout) ; true ; end
      # No-op: Talos exposes no shell, these calls must do nothing.
      def test(*)    ; false ; end
      def execute(*) ; 0     ; end
      def sudo(*)    ; 0     ; end
      def upload(*)  ; true  ; end
      def download(*); true  ; end
      def reset!(*)  ; true  ; end
    end
  end

  # "dummy guest": Vagrant tries to detect the guest OS (the synced_folders action
  # calls guest.capability? -> detect!); on Talos detection fails and raises
  # GuestNotDetected (fatal). We register a bogus guest with `detect? => true` and NO
  # capability at all: capability? returns false everywhere => no command is ever
  # executed in the guest. To be paired with `config.vm.guest = :dummy`.
  module DummyGuest
    class Plugin < Vagrant.plugin("2")
      name "dummy_guest"
      guest("dummy") { Guest }
    end

    class Guest < Vagrant.plugin("2", :guest)
      def detect?(_machine) ; true ; end
    end
  end
end

##############################################################################
# Builds the shell command that configures the host-only DHCP with
# deterministic reservations (MAC -> IP). Idempotent.
##############################################################################

# Vagrant 2.4.x runs a host trigger `run.inline` through Shellwords.split + a direct
# exec (NO shell): a multi-line script breaks ("executable 'set' not found").
# So we wrap the script in `bash -c <escaped script>`.
def host_inline(script)
  { inline: "bash -c #{Shellwords.escape(script)}" }
end

def hostonly_dhcp_cmd(servers)
  reservations = servers.map do |s|
    mac = s[:mac].scan(/../).join(":").downcase
    "  VBoxManage dhcpserver modify --ifname \"$IF\" " \
      "--mac-address #{mac} --fixed-address #{s[:ip]} >/dev/null 2>&1 || true"
  end.join("\n")

  <<~SH
    set -e
    # Find the host-only interface of subnet #{NETWORK}.0/24 (created by Vagrant)
    IF=$(VBoxManage list hostonlyifs | awk '/^Name:/{n=$2} /^IPAddress:/{ if($2 ~ /^#{NETWORK.gsub('.', '\\.')}\\./) print n }' | head -n1)
    if [ -z "$IF" ]; then
      IF=$(VBoxManage hostonlyif create 2>/dev/null | sed -n "s/.*'\\(vboxnet[0-9]*\\)'.*/\\1/p")
      VBoxManage hostonlyif ipconfig "$IF" --ip #{HOST_IP} --netmask 255.255.255.0
    fi
    # (Re)enable a DHCP server. Every VM has an IP RESERVED by MAC; the dynamic
    # pool (.251-.254, never a multiple of 10) is only there to satisfy
    # VBoxManage and never collides with the nodes.
    VBoxManage dhcpserver add    --ifname "$IF" --ip #{NETWORK}.2 --netmask 255.255.255.0 \
      --lowerip #{NETWORK}.251 --upperip #{NETWORK}.254 --enable >/dev/null 2>&1 \
      || VBoxManage dhcpserver modify --ifname "$IF" --ip #{NETWORK}.2 --netmask 255.255.255.0 \
           --lowerip #{NETWORK}.251 --upperip #{NETWORK}.254 --enable >/dev/null 2>&1 || true
#{reservations}
    # Purge the leases BEFORE the nodes boot: VBox honours an already "acked" old
    # lease (e.g. .101 inherited from vboxnet0's default DHCP) BEFORE applying the
    # MAC->IP reservation. So we wipe the leases and restart the dhcpd while it is
    # still idle, so that every node gets its reserved IP on its very first DHCP
    # DISCOVER (see the `before :up` trigger).
    CFG="${VBOX_USER_HOME:-$HOME/.config/VirtualBox}"
    rm -f "$CFG/HostInterfaceNetworking-$IF-Dhcpd.leases" \
          "$CFG/HostInterfaceNetworking-$IF-Dhcpd.leases-prev"
    VBoxManage dhcpserver restart --network "HostInterfaceNetworking-$IF" >/dev/null 2>&1 || true
    echo "[talos] host-only DHCP ready on $IF -> #{servers.map { |s| "#{s[:name]}=#{s[:ip]}" }.join(' ')}"
  SH
end

# Purges the host-only network's DHCP leases. VBoxManage honours an already
# "acked" lease BEFORE the MAC->IP reservations: a stale lease (e.g. .101 from
# vboxnet0's old default DHCP) overrides the reservation and the node does not
# get its fixed IP. So we delete the lease file on destroy, so that a later
# `up` restarts from clean reservations.
def hostonly_purge_leases_cmd
  <<~SH
    set -e
    IF=$(VBoxManage list hostonlyifs | awk '/^Name:/{n=$2} /^IPAddress:/{ if($2 ~ /^#{NETWORK.gsub('.', '\\.')}\\./) print n }' | head -n1)
    [ -n "$IF" ] || exit 0
    CFG="${VBOX_USER_HOME:-$HOME/.config/VirtualBox}"
    rm -f "$CFG/HostInterfaceNetworking-$IF-Dhcpd.leases" \
          "$CFG/HostInterfaceNetworking-$IF-Dhcpd.leases-prev"
    VBoxManage dhcpserver restart --network "HostInterfaceNetworking-$IF" >/dev/null 2>&1 || true
    echo "[talos] stale DHCP leases purged for $IF"
  SH
end

##############################################################################
# Vagrant
##############################################################################

Vagrant.configure("2") do |config|
  # The pace/empty box declares `config.vagrant.plugins = ["vagrant-dummy-communicator"]`
  # in its own _Vagrantfile, which forces a gem install (prompt => failure without a TTY).
  # We define our own inline "dummy" communicator (see above): no gem needed. So we
  # override the box's declaration (merge = last-wins).
  config.vagrant.plugins = []

  config.vm.box           = "pace/empty"   # EMPTY box (no OS): we boot off the ISO
  config.vm.guest         = :dummy         # avoids guest OS detection (Talos)
  config.vm.box_check_update = false
  config.vm.boot_timeout  = 1              # no point waiting: no SSH
  config.ssh.insert_key   = false
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # Disable vagrant-vbguest if present (no guest additions on Talos)
  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
    config.vbguest.no_install  = true
    config.vbguest.no_remote   = true
  end

  # Download the Talos ISO once, before the first `up`.
  config.trigger.before :up do |t|
    t.name = "Talos ISO #{TALOS_VERSION}"
    t.run  = host_inline(<<~SH)
      set -e
      mkdir -p "#{File.dirname(ISO_PATH)}" "#{DISKS_DIR}"
      if [ ! -f "#{ISO_PATH}" ]; then
        echo "[talos] Downloading metal-amd64.iso (#{TALOS_VERSION})..."
        curl -fL --progress-bar -o "#{ISO_PATH}" \
          "https://github.com/siderolabs/talos/releases/download/#{TALOS_VERSION}/metal-amd64.iso"
      fi
    SH
  end

  # (Re)enable the host-only DHCP BEFORE the VMs boot: MAC->IP reservations laid down
  # AND stale leases purged while the dhcpd is still idle. This is THE key point: the
  # node must see its .10/.20/.30 reservation on its very first DHCP DISCOVER (at boot).
  # Laid down `after :up`, they arrived too late and an old .101 lease won. Global
  # trigger => idempotent, replayed before each node (also robust for a lone
  # `vagrant up <node>` or a `vagrant reload`).
  config.trigger.before :up do |t|
    t.name = "host-only DHCP (reservations + lease purge)"
    t.run  = host_inline(hostonly_dhcp_cmd(servers))
  end

  # Purge stale DHCP leases after a destroy (see hostonly_purge_leases_cmd).
  # Global trigger => replayed for each destroyed node; `rm -f` is idempotent.
  config.trigger.after :destroy do |t|
    t.name = "Purge host-only DHCP leases"
    t.run  = host_inline(hostonly_purge_leases_cmd)
  end

  servers.each do |s|
    disk_path = File.join(DISKS_DIR, "#{s[:name]}.vdi")

    config.vm.define s[:name] do |node|
      node.vm.communicator = "dummy"

      # NIC2 = host-only network (the real IP is assigned by DHCP reservation).
      # auto_config:false because Vagrant cannot write inside the Talos guest.
      node.vm.network "private_network",
        ip: s[:ip], mac: s[:mac], auto_config: false, nic_type: "virtio"

      node.vm.provider "virtualbox" do |vb|
        vb.name         = s[:name]
        vb.memory       = s[:mem]
        vb.cpus         = s[:cpu]
        vb.gui          = false
        vb.linked_clone = true

        # BIOS: deterministic ISO/disk boot (the pace/empty box is UEFI)
        vb.customize ["modifyvm", :id, "--firmware", "bios"]

        # Storage: configured ONLY ONCE, when the VM is created.
        # `vb.customize` (pre-boot) is replayed on every `vagrant up`, yet
        # `storagectl --remove/--add` is not idempotent (fails on the 2nd pass).
        # Sentinel = the disk being present: if it exists, the VM is already provisioned.
        unless File.exist?(disk_path)
          # Replace the box's SAS controller with SATA/AHCI (a safe Talos driver)
          vb.customize ["storagectl", :id, "--name", "SAS", "--remove"]
          vb.customize ["storagectl", :id, "--name", "SATA",
                        "--add", "sata", "--controller", "IntelAhci", "--portcount", "2"]

          # Talos install disk (=> /dev/sda)
          vb.customize ["createmedium", "disk", "--filename", disk_path,
                        "--size", DISK_SIZE_MB.to_s, "--format", "VDI"]
          vb.customize ["storageattach", :id, "--storagectl", "SATA",
                        "--port", "0", "--device", "0", "--type", "hdd", "--medium", disk_path]

          # Talos ISO in the DVD drive
          vb.customize ["storageattach", :id, "--storagectl", "SATA",
                        "--port", "1", "--device", "0", "--type", "dvddrive", "--medium", ISO_PATH]
        end

        # Boot: disk first (after install), DVD as a fallback (first boot)
        vb.customize ["modifyvm", :id, "--boot1", "disk", "--boot2", "dvd",
                      "--boot3", "none", "--boot4", "none"]
      end

      # Clean up the dedicated disk on destroy.
      node.trigger.after :destroy do |t|
        t.name = "Disk cleanup #{s[:name]}"
        t.run  = host_inline(<<~SH)
          VBoxManage closemedium disk "#{disk_path}" --delete >/dev/null 2>&1 || true
          rm -f "#{disk_path}"
        SH
      end
    end
  end
end
