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
#     par adresse MAC sur le réseau host-only (voir trigger `before :up`).
#
# Workflow complet : voir README.md

require 'shellwords'

##############################################################################
# Paramètres du lab
##############################################################################

TALOS_VERSION  = "v1.13.5"   # https://github.com/siderolabs/talos/releases

CONTROL_PLANES = 3           # 1 = single ; 3 = HA (avec VIP)
WORKERS        = 3           # nombre de workers

CP_MEM  = 2048 ; CP_CPU = 2  # ressources control plane
WK_MEM  = 2048 ; WK_CPU = 2  # ressources worker

NETWORK      = "192.168.56"          # réseau host-only (inchangé)
VIP          = "#{NETWORK}.5"        # VIP de l'API Kubernetes (HA)
HOST_IP      = "#{NETWORK}.1"        # passerelle host-only
DISK_SIZE_MB = 20480                 # disque d'installation par node (20 Go)

# Schéma d'adressage host-only (variabilisable, surchargeable par variables d'env) :
#   control plane i -> NETWORK.(CP_IP_START + (i-1)*CP_IP_STEP)  => .10, .20, .30, ...
#   worker       i  -> NETWORK.(WK_IP_START + (i-1)*WK_IP_STEP)  => .101, .102, .103, ...
# Garder ces valeurs alignées avec talos/cluster-up.sh (mêmes noms de variables).
CP_IP_START = (ENV["CP_IP_START"] || 10).to_i  ; CP_IP_STEP = (ENV["CP_IP_STEP"] || 10).to_i
WK_IP_START = (ENV["WK_IP_START"] || 101).to_i ; WK_IP_STEP = (ENV["WK_IP_STEP"] || 1).to_i

ISO_PATH   = File.join(__dir__, "iso", "metal-amd64.iso")
DISKS_DIR  = File.join(__dir__, ".vagrant", "talos-disks")

##############################################################################
# Construction de la liste des nodes
#   CP    : talos-cp1=.10, talos-cp2=.20, ...   (voir CP_IP_START / CP_IP_STEP)
#   Worker: talos-w1=.101, talos-w2=.102, ...   (voir WK_IP_START / WK_IP_STEP)
#   Le nom de VM = le hostname Talos. La MAC reste indexée par `idx` (unique).
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

# Garde-fou : .100 = serveur DHCP host-only PAR DÉFAUT de VirtualBox (réservé) ;
# .1/.2/.5 = passerelle / serveur DHCP / VIP. Un node ne doit jamais tomber
# dessus (dépend du schéma d'adressage ci-dessus : p.ex. 10 CP => .100).
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

  # "dummy guest" : Vagrant cherche à détecter l'OS invité (action synced_folders
  # appelle guest.capability? -> detect!) ; sur Talos la détection échoue et lève
  # GuestNotDetected (fatal). On enregistre un invité bidon `detect? => true` SANS
  # aucune capability : capability? renvoie false partout => aucune commande n'est
  # jamais exécutée dans le guest. À coupler avec `config.vm.guest = :dummy`.
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
    # Purge les baux AVANT le boot des nodes : VBox honore un vieux bail déjà
    # « acked » (p.ex. .101 hérité du DHCP par défaut de vboxnet0) AVANT
    # d'appliquer la réservation MAC->IP. On efface donc les baux et on redémarre
    # le dhcpd tant qu'il tourne à vide, pour que chaque node obtienne son IP
    # réservée dès son 1er DHCP DISCOVER (cf. trigger `before :up`).
    CFG="${VBOX_USER_HOME:-$HOME/.config/VirtualBox}"
    rm -f "$CFG/HostInterfaceNetworking-$IF-Dhcpd.leases" \
          "$CFG/HostInterfaceNetworking-$IF-Dhcpd.leases-prev"
    VBoxManage dhcpserver restart --network "HostInterfaceNetworking-$IF" >/dev/null 2>&1 || true
    echo "[talos] DHCP host-only prêt sur $IF -> #{servers.map { |s| "#{s[:name]}=#{s[:ip]}" }.join(' ')}"
  SH
end

# Purge les baux DHCP du réseau host-only. VBoxManage honore un bail déjà
# « acked » AVANT les réservations MAC->IP : un bail périmé (p.ex. .101 de
# l'ancien DHCP par défaut de vboxnet0) écrase la réservation et le node
# n'obtient pas son IP fixe. On supprime donc le fichier de baux à la
# destruction pour qu'un `up` ultérieur reparte sur des réservations propres.
def hostonly_purge_leases_cmd
  <<~SH
    set -e
    IF=$(VBoxManage list hostonlyifs | awk '/^Name:/{n=$2} /^IPAddress:/{ if($2 ~ /^#{NETWORK.gsub('.', '\\.')}\\./) print n }' | head -n1)
    [ -n "$IF" ] || exit 0
    CFG="${VBOX_USER_HOME:-$HOME/.config/VirtualBox}"
    rm -f "$CFG/HostInterfaceNetworking-$IF-Dhcpd.leases" \
          "$CFG/HostInterfaceNetworking-$IF-Dhcpd.leases-prev"
    VBoxManage dhcpserver restart --network "HostInterfaceNetworking-$IF" >/dev/null 2>&1 || true
    echo "[talos] Baux DHCP périmés purgés pour $IF"
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
  config.vm.guest         = :dummy         # évite la détection d'OS invité (Talos)
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

  # (Ré)active le DHCP host-only AVANT le boot des VMs : réservations MAC->IP
  # posées ET baux périmés purgés pendant que le dhcpd tourne à vide. C'est LE
  # point clé : le node doit voir sa réservation .10/.20/.30 dès son 1er DHCP
  # DISCOVER (au boot). Posées `after :up`, elles arrivaient trop tard et un vieux
  # bail .101 gagnait. Trigger global => idempotent, rejoué avant chaque node
  # (robuste aussi pour `vagrant up <node>` seul ou `vagrant reload`).
  config.trigger.before :up do |t|
    t.name = "DHCP host-only (réservations + purge baux)"
    t.run  = host_inline(hostonly_dhcp_cmd(servers))
  end

  # Purge les baux DHCP périmés après destruction (cf. hostonly_purge_leases_cmd).
  # Déclencheur global => rejoué pour chaque node détruit ; `rm -f` est idempotent.
  config.trigger.after :destroy do |t|
    t.name = "Purge baux DHCP host-only"
    t.run  = host_inline(hostonly_purge_leases_cmd)
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

        # Storage : configuré UNE SEULE FOIS, à la création de la VM.
        # `vb.customize` (pre-boot) est rejoué à chaque `vagrant up` ; or
        # `storagectl --remove/--add` n'est pas idempotent (échoue au 2e passage).
        # Sentinelle = présence du disque : s'il existe, la VM est déjà provisionnée.
        unless File.exist?(disk_path)
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
        end

        # Boot : disque d'abord (après install), DVD en secours (1er boot)
        vb.customize ["modifyvm", :id, "--boot1", "disk", "--boot2", "dvd",
                      "--boot3", "none", "--boot4", "none"]
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
