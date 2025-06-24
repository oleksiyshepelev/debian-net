#!/bin/bash
set -euo pipefail

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Función para imprimir mensajes coloreados
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

# Función para validar IP
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [[ $i -gt 255 ]] || [[ $i -lt 0 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Función para validar CIDR
validate_cidr() {
    local cidr=$1
    if [[ $cidr =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        local ip=$(echo "$cidr" | cut -d'/' -f1)
        local mask=$(echo "$cidr" | cut -d'/' -f2)
        if validate_ip "$ip" && [[ $mask -ge 1 ]] && [[ $mask -le 32 ]]; then
            return 0
        fi
    fi
    return 1
}

# Función para validar DNS (puede ser múltiple separado por comas)
validate_dns() {
    local dns_list=$1
    IFS=',' read -ra DNS_ARRAY <<< "$dns_list"
    for dns in "${DNS_ARRAY[@]}"; do
        dns=$(echo "$dns" | xargs) # Trim whitespace
        if ! validate_ip "$dns"; then
            return 1
        fi
    done
    return 0
}

# Verificar si se ejecuta como root (opcional pero recomendado)
if [[ $EUID -eq 0 ]]; then
    print_warning "Ejecutándose como root. Se recomienda usar un usuario con sudo."
fi

# 1️⃣ Verificar e instalar sudo si falta
if ! command -v sudo &>/dev/null; then
    print_info "sudo no instalado. Instalándolo..."
    if [[ $EUID -eq 0 ]]; then
        apt update && apt install -y sudo
    else
        print_error "Se necesita sudo o ejecutar como root para instalar paquetes."
        exit 1
    fi
fi

# 2️⃣ Instalar netplan.io si no existe
if ! dpkg -s netplan.io &>/dev/null; then
    print_info "Instalando netplan.io..."
    sudo apt update && sudo apt install -y netplan.io
    print_success "netplan.io instalado correctamente"
else
    print_success "netplan.io ya está instalado"
fi

# 3️⃣ Habilitar systemd-networkd
print_info "Habilitando systemd-networkd..."
sudo systemctl enable --now systemd-networkd

# 4️⃣ Deshabilitar NetworkManager y interfaces tradicionales si están activos
print_info "Verificando y deshabilitando servicios conflictivos..."

# Deshabilitar NetworkManager si está activo
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    print_warning "NetworkManager está activo. Deshabilitándolo..."
    sudo systemctl stop NetworkManager
    sudo systemctl disable NetworkManager
fi

# Verificar y renombrar /etc/network/interfaces si existe
if [[ -f /etc/network/interfaces ]] && grep -v "^#\|^$" /etc/network/interfaces | grep -q .; then
    print_warning "Configuración en /etc/network/interfaces detectada. Creando backup..."
    sudo mv /etc/network/interfaces /etc/network/interfaces.backup-$(date +%Y%m%d-%H%M%S)
    echo "# Interfaces file disabled - using netplan instead" | sudo tee /etc/network/interfaces
fi

# Crear backup de netplan
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CONFIG_DIR="/etc/netplan"
BACKUP_DIR="$CONFIG_DIR/backup-$TIMESTAMP"

print_info "Creando backup de configuraciones existentes de netplan..."
sudo mkdir -p "$BACKUP_DIR"
if sudo find "$CONFIG_DIR" -name "*.yaml" -o -name "*.yml" | head -1 | grep -q .; then
    sudo cp "$CONFIG_DIR"/*.yaml "$BACKUP_DIR"/ 2>/dev/null || true
    sudo cp "$CONFIG_DIR"/*.yml "$BACKUP_DIR"/ 2>/dev/null || true
    print_success "Backup guardado en $BACKUP_DIR"
    
    # Remover configuraciones conflictivas
    print_info "Removiendo configuraciones netplan existentes..."
    sudo rm -f "$CONFIG_DIR"/*.yaml
    sudo rm -f "$CONFIG_DIR"/*.yml
else
    print_info "No se encontraron configuraciones previas para respaldar"
fi

# 5️⃣ Obtener lista de interfaces de red
print_info "Detectando interfaces de red..."
mapfile -t IFACES < <(
    ip -o link show \
        | awk -F': ' '{print $2}' \
        | grep -Ev '^(lo|virbr|docker|br-|veth|tap|tun)' \
        | sort
)

if [[ ${#IFACES[@]} -eq 0 ]]; then
    print_error "No se encontraron interfaces de red válidas."
    exit 1
fi

echo
print_info "Interfaces de red disponibles:"
for i in "${!IFACES[@]}"; do
    IFACE="${IFACES[$i]}"
    # Obtener información adicional de la interfaz
    STATE=$(ip link show "$IFACE" | grep -o 'state [A-Z]*' | cut -d' ' -f2)
    CURRENT_IP=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | head -1)
    printf "  [%d] %-12s Estado: %-8s IP actual: %s\n" $((i+1)) "$IFACE" "$STATE" "${CURRENT_IP:-Sin IP}"
done

# Selección de interfaz
while true; do
    echo
    read -rp "Selecciona la interfaz de red (número): " selection
    if [[ "$selection" =~ ^[1-9][0-9]*$ ]] && [ "$selection" -le "${#IFACES[@]}" ]; then
        SELECTED_IFACE="${IFACES[$((selection-1))]}"
        break
    fi
    print_error "Selección inválida. Introduce un número entre 1 y ${#IFACES[@]}."
done

print_success "Interfaz seleccionada: $SELECTED_IFACE"

# 6️⃣ Obtener valores actuales
print_info "Obteniendo configuración actual..."
CUR_IP=$(ip -4 -o addr show dev "$SELECTED_IFACE" 2>/dev/null | awk '{print $4}' | head -1)
CUR_GW=$(ip route | awk '/^default/ {print $3; exit}')
CUR_DNS=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | head -1)

echo
print_info "Configuración actual de la red:"
echo "  Interfaz:     $SELECTED_IFACE"
echo "  IP/Máscara:   ${CUR_IP:-Sin configurar}"
echo "  Gateway:      ${CUR_GW:-Sin configurar}"
echo "  DNS:          ${CUR_DNS:-Sin configurar}"

# 7️⃣ Configuración interactiva
echo
print_info "Configuración de IP estática"
echo "============================================"

# Configurar IP
while true; do
    if [[ -n "${CUR_IP:-}" ]]; then
        read -rp "IP/Máscara (formato: 192.168.1.100/24) [ENTER para mantener $CUR_IP]: " NEW_IP
        NEW_IP="${NEW_IP:-$CUR_IP}"
    else
        read -rp "IP/Máscara (formato: 192.168.1.100/24): " NEW_IP
    fi
    
    if validate_cidr "$NEW_IP"; then
        break
    fi
    print_error "Formato de IP/Máscara inválido. Use el formato: 192.168.1.100/24"
done

# Configurar Gateway
while true; do
    if [[ -n "${CUR_GW:-}" ]]; then
        read -rp "Gateway [ENTER para mantener $CUR_GW]: " NEW_GW
        NEW_GW="${NEW_GW:-$CUR_GW}"
    else
        read -rp "Gateway (ejemplo: 192.168.1.1): " NEW_GW
    fi
    
    if validate_ip "$NEW_GW"; then
        break
    fi
    print_error "Dirección de gateway inválida."
done

# Configurar DNS
while true; do
    if [[ -n "${CUR_DNS:-}" ]]; then
        read -rp "Servidores DNS (separados por comas) [ENTER para mantener $CUR_DNS]: " NEW_DNS
        NEW_DNS="${NEW_DNS:-$CUR_DNS}"
    else
        read -rp "Servidores DNS (ejemplo: 8.8.8.8,8.8.4.4): " NEW_DNS
    fi
    
    if validate_dns "$NEW_DNS"; then
        break
    fi
    print_error "Uno o más servidores DNS son inválidos."
done

# Formatear DNS para YAML
DNS_FORMATTED=$(echo "$NEW_DNS" | sed 's/,/, /g' | sed 's/\([0-9.]*\)/"\1"/g')

# 8️⃣ Mostrar resumen y confirmar
echo
print_info "Resumen de la configuración:"
echo "============================================"
echo "  Interfaz:     $SELECTED_IFACE"
echo "  IP/Máscara:   $NEW_IP"
echo "  Gateway:      $NEW_GW"
echo "  DNS:          $NEW_DNS"
echo
read -rp "¿Aplicar esta configuración? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    print_info "Configuración cancelada por el usuario."
    exit 0
fi

# 9️⃣ Generar archivo YAML de configuración
YAML_FILE="$CONFIG_DIR/00-static-config.yaml"
print_info "Generando archivo de configuración: $YAML_FILE"

# Asegurar que sea el único archivo
sudo rm -f "$CONFIG_DIR"/*.yaml "$CONFIG_DIR"/*.yml 2>/dev/null || true

sudo tee "$YAML_FILE" >/dev/null <<EOF
# Configuración de red estática generada por script
# Fecha: $(date)
# Interfaz: $SELECTED_IFACE
# IMPORTANTE: Este es el único archivo de configuración netplan
network:
  version: 2
  renderer: networkd
  ethernets:
    $SELECTED_IFACE:
      dhcp4: false
      dhcp6: false
      accept-ra: false
      link-local: []
      addresses:
        - $NEW_IP
      routes:
        - to: default
          via: $NEW_GW
          metric: 100
      nameservers:
        addresses: [$DNS_FORMATTED]
        search: []
EOF

sudo chmod 600 "$YAML_FILE"
print_success "Archivo de configuración creado con permisos seguros (600)"

# 🔟 Limpiar configuraciones de red previas
print_info "Limpiando configuraciones de red previas..."

# Flush todas las IPs de la interfaz
sudo ip addr flush dev "$SELECTED_IFACE" 2>/dev/null || true

# Parar servicios que puedan interferir
sudo systemctl stop systemd-networkd 2>/dev/null || true
sleep 2

# Aplicar configuración
print_info "Aplicando nueva configuración de red..."
print_warning "La conexión puede interrumpirse momentáneamente..."

# Validar sintaxis antes de aplicar
if ! sudo netplan generate 2>/dev/null; then
    print_error "Error en la sintaxis del archivo de configuración"
    sudo rm -f "$YAML_FILE"
    exit 1
fi

# Reiniciar servicios de red
sudo systemctl restart systemd-networkd
sleep 3

# Aplicar con timeout para evitar cuelgues
if timeout 45 sudo netplan apply 2>&1 | grep -v "ovsdb-server.service" || true; then
    sleep 5
    print_success "Configuración aplicada correctamente"
else
    print_error "Error o timeout al aplicar la configuración. Restaurando backup..."
    sudo rm -f "$YAML_FILE"
    if [[ -d "$BACKUP_DIR" ]] && [[ $(ls -A "$BACKUP_DIR" 2>/dev/null) ]]; then
        sudo cp "$BACKUP_DIR"/* "$CONFIG_DIR"/
        sudo netplan apply
    fi
    exit 1
fi

# 🏁 Verificación final
echo
print_success "Configuración completada exitosamente!"
print_info "Verificando estado de la interfaz $SELECTED_IFACE:"
echo "============================================"

# Mostrar estado de la interfaz
if command -v networkctl &>/dev/null; then
    sudo networkctl status "$SELECTED_IFACE" 2>/dev/null || true
fi

# Mostrar información de IP
echo
print_info "Información de direcciones IP:"
ip -4 addr show dev "$SELECTED_IFACE"

# Mostrar rutas
echo
print_info "Tabla de rutas:"
ip route show | grep -E "(default|$SELECTED_IFACE)"

# Verificar conectividad
echo
print_info "Probando conectividad..."
if timeout 5 ping -c 1 "$NEW_GW" &>/dev/null; then
    print_success "Conectividad con gateway OK"
else
    print_warning "No se puede hacer ping al gateway"
fi

if timeout 10 ping -c 1 8.8.8.8 &>/dev/null; then
    print_success "Conectividad con Internet OK"
else
    print_warning "No se puede hacer ping a Internet"
fi

echo
print_success "¡Configuración de red estática completada!"
print_info "Archivo de configuración: $YAML_FILE"
print_info "Backup disponible en: $BACKUP_DIR"