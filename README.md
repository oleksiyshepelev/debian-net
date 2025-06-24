🔧 Cambios principales:
1. Deshabilitar servicios conflictivos

Detiene y deshabilita NetworkManager si está activo
Crea backup de /etc/network/interfaces y lo desactiva
Elimina todas las configuraciones netplan previas

2. Configuración YAML mejorada

Nombre de archivo único: 00-static-config.yaml (orden de prioridad)
Deshabilita explícitamente DHCP4 y DHCP6
Añade accept-ra: false para deshabilitar autoconfiguración IPv6
Añade link-local: [] para evitar IPs link-local automáticas
Establece métrica de ruta para evitar conflictos

3. Limpieza de red mejorada

Flush de todas las IPs de la interfaz antes de aplicar
Reinicio limpio de systemd-networkd
Eliminación de configuraciones conflictivas

4. Solución específica para el problema

Una sola configuración: Elimina todos los archivos YAML previos
Sin DHCP: Deshabilita completamente DHCP en la interfaz
Sin autoconfiguración: Evita asignación automática de IPs
