# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# VagrantLab-Talos
# ----------------
# Monte un cluster Talos Linux sur VirtualBox.
#
# Particularités Talos :
#   - Talos n'a PAS de SSH : tout se pilote avec `talosctl` depuis l'hôte.
#     => on enregistre un "dummy communicator" pour que `vagrant up`
#        n'attende pas une connexion SSH qui n'arrivera jamais.
#   - Talos n'a pas de box Vagrant officielle : on part d'une box VIDE
#     (pace/empty) que l'on fait booter sur l'ISO `metal-amd64.iso`.
#   - Vagrant ne peut pas configurer l'IP dans le guest (pas de SSH) :
#     les IP sont fixées de façon déterministe via des réservations DHCP
#     par adresse MAC sur le réseau host-only (voir trigger `after :up`).
#
# Workflow complet : voir README.md

require 'shellwords'

##############################################################################
# Paramètres du lab
##############################################################################

TALOS_VERSION  = "v1.13.5"   # https://github.com/siderolabs/talos/releases

CONTROL_PLANES = 1           # 1 = single ; 3 = HA (avec VIP)
WORKERS        = 2           # nombre de workers

CP_MEM  = 2048 ; CP_CPU = 2  # ressources control plane
WK_MEM  = 2048 ; WK_CPU = 2  # ressources worker

NETWORK      = "192.168.56"          # réseau host-only (inchangé)
VIP          = "#{NETWORK}.5"        # VIP de l'API Kubernetes (HA)
HOST_IP      = "#{NETWORK}.1"        # passerelle host-only
DISK_SIZE_MB = 20480                 # disque d'installation par node (20 Go)

ISO_PATH   = File.join(__dir__, "iso", "metal-amd64.iso")
DISKS_DIR  = File.join(__dir__, ".vagrant", "talos-disks")

##############################################################################
# Construction de la liste des nodes
#   box01 = 1er control plane = .10, box02 = .20, ... (.role = controlplane/worker)
##############################################################################

servers = []
idx = 0
(1..CONTROL_PLANES).each do
  idx += 1
  servers << { name: ("box%02d" % idx), role: "controlplane",
               ip: "#{NETWORK}.#{idx * 10}", mac: ("080027AA00%02X" % idx),
               mem: CP_MEM, cpu: CP_CPU }
end
(1..WORKERS).each do
  idx += 1
  servers << { name: ("box%02d" % idx), role: "worker",
               ip: "#{NETWORK}.#{idx * 10}", mac: ("080027AA00%02X" % idx),
               mem: WK_MEM, cpu: WK_CPU }
end

# Garde-fou : .100 = serveur DHCP host-only PAR DÉFAUT de VirtualBox (réservé) ;
# .1/.2/.5 = passerelle / serveur DHCP / VIP. Un node ne doit jamais tomber
# dessus (n'arrive qu'avec ~10 nodes, car idx*10 = 100).
reserved_ips = ["#{NETWORK}.1", "#{NETWORK}.2", "#{NETWORK}.5", "#{NETWORK}.100"]
servers.each do |s|
  if reserved_ips.include?(s[:ip])
    raise "VagrantLab-Talos : l'IP #{s[:ip]} (#{s[:name]}) est réservée " \
          "(#{reserved_ips.join(', ')}). Réduis CONTROL_PLANES/WORKERS."
  end
end

##############################################################################
# "dummy communicator" : rend `ready?` toujours vrai pour que Vagrant
# ne reste pas bloqué à attendre SSH (Talos n'expose pas SSH).
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
      # No-op : Talos n'expose pas de shell, ces appels ne doivent rien faire.
      def test(*)    ; false ; end
      def execute(*) ; 0     ; end
      def sudo(*)    ; 0     ; end
      def upload(*)  ; true  ; end
      def download(*); true  ; end
      def reset!(*)  ; true  ; end
    end
  end
end

##############################################################################
# Construit la commande shell qui configure le DHCP host-only avec des
# réservations déterministes (MAC -> IP). Idempotente.
##############################################################################

# Vagrant 2.4.x exécute un host trigger `run.inline` via Shellwords.split + exec
# direct (PAS de shell) : un script multiligne casse ("executable 'set' not found").
# On enveloppe donc le script dans `bash -c <script échappé>`.
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
    # Trouve l'interface host-only du sous-réseau #{NETWORK}.0/24 (créée par Vagrant)
    IF=$(VBoxManage list hostonlyifs | awk '/^Name:/{n=$2} /^IPAddress:/{ if($2 ~ /^#{NETWORK.gsub('.', '\\.')}\\./) print n }' | head -n1)
    if [ -z "$IF" ]; then
      IF=$(VBoxManage hostonlyif create 2>/dev/null | sed -n "s/.*'\\(vboxnet[0-9]*\\)'.*/\\1/p")
      VBoxManage hostonlyif ipconfig "$IF" --ip #{HOST_IP} --netmask 255.255.255.0
    fi
    # (Ré)active un serveur DHCP. Toutes les VMs ont une IP RÉSERVÉE par MAC ;
    # le pool dynamique (.251-.254, jamais un multiple de 10) ne sert qu'à
    # satisfaire VBoxManage et n'entre jamais en collision avec les nodes.
    VBoxManage dhcpserver add    --ifname "$IF" --ip #{NETWORK}.2 --netmask 255.255.255.0 \
      --lowerip #{NETWORK}.251 --upperip #{NETWORK}.254 --enable >/dev/null 2>&1 \
      || VBoxManage dhcpserver modify --ifname "$IF" --ip #{NETWORK}.2 --netmask 255.255.255.0 \
           --lowerip #{NETWORK}.251 --upperip #{NETWORK}.254 --enable >/dev/null 2>&1 || true
#{reservations}
    echo "[talos] DHCP host-only prêt sur $IF -> #{servers.map { |s| "#{s[:name]}=#{s[:ip]}" }.join(' ')}"
  SH
end

##############################################################################
# Vagrant
##############################################################################

Vagrant.configure("2") do |config|
  # La box pace/empty déclare `config.vagrant.plugins = ["vagrant-dummy-communicator"]`
  # dans son _Vagrantfile, ce qui force l'install d'un gem (prompt => échec sans TTY).
  # On définit notre propre communicator "dummy" inline (cf. plus haut) : pas besoin
  # du gem. On écrase donc la déclaration de la box (merge = last-wins).
  config.vagrant.plugins = []

  config.vm.box           = "pace/empty"   # box VIDE (aucun OS) : on boote sur l'ISO
  config.vm.box_check_update = false
  config.vm.boot_timeout  = 1              # inutile d'attendre : pas de SSH
  config.ssh.insert_key   = false
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # Désactive vagrant-vbguest si présent (pas de guest additions sur Talos)
  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
    config.vbguest.no_install  = true
    config.vbguest.no_remote   = true
  end

  # Télécharge l'ISO Talos une seule fois, avant le 1er `up`.
  config.trigger.before :up do |t|
    t.name = "Talos ISO #{TALOS_VERSION}"
    t.run  = host_inline(<<~SH)
      set -e
      mkdir -p "#{File.dirname(ISO_PATH)}" "#{DISKS_DIR}"
      if [ ! -f "#{ISO_PATH}" ]; then
        echo "[talos] Téléchargement de metal-amd64.iso (#{TALOS_VERSION})..."
        curl -fL --progress-bar -o "#{ISO_PATH}" \
          "https://github.com/siderolabs/talos/releases/download/#{TALOS_VERSION}/metal-amd64.iso"
      fi
    SH
  end

  servers.each do |s|
    disk_path = File.join(DISKS_DIR, "#{s[:name]}.vdi")

    config.vm.define s[:name] do |node|
      node.vm.communicator = "dummy"

      # NIC2 = réseau host-only (l'IP réelle est attribuée par réservation DHCP).
      # auto_config:false car Vagrant ne peut pas écrire dans le guest Talos.
      node.vm.network "private_network",
        ip: s[:ip], mac: s[:mac], auto_config: false, nic_type: "virtio"

      node.vm.provider "virtualbox" do |vb|
        vb.name         = s[:name]
        vb.memory       = s[:mem]
        vb.cpus         = s[:cpu]
        vb.gui          = false
        vb.linked_clone = true

        # BIOS : boot ISO/disque déterministe (la box pace/empty est en UEFI)
        vb.customize ["modifyvm", :id, "--firmware", "bios"]

        # Remplace le contrôleur SAS de la box par du SATA/AHCI (driver Talos sûr)
        vb.customize ["storagectl", :id, "--name", "SAS", "--remove"]
        vb.customize ["storagectl", :id, "--name", "SATA",
                      "--add", "sata", "--controller", "IntelAhci", "--portcount", "2"]

        # Disque d'installation Talos (=> /dev/sda)
        vb.customize ["createmedium", "disk", "--filename", disk_path,
                      "--size", DISK_SIZE_MB.to_s, "--format", "VDI"]
        vb.customize ["storageattach", :id, "--storagectl", "SATA",
                      "--port", "0", "--device", "0", "--type", "hdd", "--medium", disk_path]

        # ISO Talos en lecteur DVD
        vb.customize ["storageattach", :id, "--storagectl", "SATA",
                      "--port", "1", "--device", "0", "--type", "dvddrive", "--medium", ISO_PATH]

        # Boot : disque d'abord (après install), DVD en secours (1er boot)
        vb.customize ["modifyvm", :id, "--boot1", "disk", "--boot2", "dvd",
                      "--boot3", "none", "--boot4", "none"]
      end

      # Après le démarrage : (ré)active le DHCP host-only avec les réservations.
      # Relancé pour chaque node => l'état final laisse bien le DHCP actif.
      node.trigger.after :up do |t|
        t.name = "DHCP host-only (#{s[:name]} -> #{s[:ip]})"
        t.run  = host_inline(hostonly_dhcp_cmd(servers))
      end

      # Nettoyage du disque dédié au destroy.
      node.trigger.after :destroy do |t|
        t.name = "Nettoyage disque #{s[:name]}"
        t.run  = host_inline(<<~SH)
          VBoxManage closemedium disk "#{disk_path}" --delete >/dev/null 2>&1 || true
          rm -f "#{disk_path}"
        SH
      end
    end
  end
end
