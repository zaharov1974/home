#!/usr/bin/env bash
set -e

declare -a MISSING_PACKAGES

function info { echo -e "\e[32m[info] $*\e[39m"; }
function warn  { echo -e "\e[33m[warn] $*\e[39m"; }
function error { echo -e "\e[31m[error] $*\e[39m"; exit 1; }

info ""
info "В глубокой древности это был официальный скрипт установки"
info ""
info "Home Assistant Supervised"
info ""
info "После очередного 'улучшения' был исправлен и переведен"
info ""

sleep 10

ARCH=$(uname -m)

IP_ADDRESS=$(hostname -I | awk '{ print $1 }')

BINARY_DOCKER=/usr/bin/docker

DOCKER_REPO=homeassistant

SERVICE_DOCKER="docker.service"
SERVICE_NM="NetworkManager.service"

FILE_DOCKER_CONF="/etc/docker/daemon.json"
FILE_INTERFACES="/etc/network/interfaces"
FILE_NM_CONF="/etc/NetworkManager/NetworkManager.conf"
FILE_NM_CONNECTION="/etc/NetworkManager/system-connections/default"

URL_RAW_BASE="https://raw.githubusercontent.com/ntguest/32bit-home-assistant-supervised-installer/main/files"
URL_VERSION="https://version.home-assistant.io/stable.json"
URL_BIN_APPARMOR="${URL_RAW_BASE}/usr/sbin/hassio-apparmor"
URL_BIN_HASSIO="${URL_RAW_BASE}/usr/sbin/hassio-supervisor"
URL_DOCKER_DAEMON="${URL_RAW_BASE}/etc/docker/daemon.json"
URL_HA="${URL_RAW_BASE}/usr/bin/ha"
URL_INTERFACES="${URL_RAW_BASE}/etc/network/interfaces"
URL_NM_CONF="${URL_RAW_BASE}/etc/NetworkManager/NetworkManager.conf"
URL_NM_CONNECTION="${URL_RAW_BASE}/etc/NetworkManager/system-connections/default"
URL_SERVICE_APPARMOR="${URL_RAW_BASE}/etc/systemd/system/hassio-apparmor.service"
URL_SERVICE_HASSIO="${URL_RAW_BASE}/etc/systemd/system/hassio-supervisor.service"
URL_APPARMOR_PROFILE="https://version.home-assistant.io/apparmor.txt"

# Check env
command -v systemctl > /dev/null 2>&1 || MISSING_PACKAGES+=("systemd")
command -v nmcli > /dev/null 2>&1 || MISSING_PACKAGES+=("network-manager")
#command -v apparmor_parser > /dev/null 2>&1 || MISSING_PACKAGES+=("apparmor")
command -v docker > /dev/null 2>&1 || MISSING_PACKAGES+=("docker")
command -v jq > /dev/null 2>&1 || MISSING_PACKAGES+=("jq")
command -v curl > /dev/null 2>&1 || MISSING_PACKAGES+=("curl")
command -v dbus-daemon > /dev/null 2>&1 || MISSING_PACKAGES+=("dbus")


if [ ! -z "${MISSING_PACKAGES}" ]; then
    warn "Следующие пакеты отсутствуют в системе. "
    warn "Они должны быть установлены перед повторным запуском скрипта"
    error "missing: ${MISSING_PACKAGES[@]}"
fi

# Check if Modem Manager is enabled
if systemctl is-enabled ModemManager.service &> /dev/null; then
    warn "Служба ModemManager активна. Это может повлиять на корректость установки."
fi

# Detect wrong docker logger config
if [ ! -f "$FILE_DOCKER_CONF" ]; then
  # Write default configuration
  info "Создание конфигурации docker $FILE_DOCKER_CONF"
  curl -sL ${URL_DOCKER_DAEMON} > "${FILE_DOCKER_CONF}"

  # Restart Docker service
  info "Перезапуск docker"
  systemctl restart "$SERVICE_DOCKER"
else
  STORAGE_DRIVER=$(docker info -f "{{json .}}" | jq -r -e .Driver)
  LOGGING_DRIVER=$(docker info -f "{{json .}}" | jq -r -e .LoggingDriver)
  if [[ "$STORAGE_DRIVER" != "overlay2" ]]; then 
    warn "Docker использует $STORAGE_DRIVER а не 'overlay2' в качестве драйвера, это не поддерживается."
  fi
  if [[ "$LOGGING_DRIVER"  != "journald" ]]; then 
    warn "Docker использует $LOGGING_DRIVER а не 'journald' в качестве драйвера, это не поддерживается."
  fi
fi

# Check dmesg access
if [[ "$(sysctl --values kernel.dmesg_restrict)" != "0" ]]; then
    info "Исправление dmesg запрета ядра"
    echo 0 > /proc/sys/kernel/dmesg_restrict
    echo "kernel.dmesg_restrict=0" >> /etc/sysctl.conf
fi

# Create config for NetworkManager
info "Создание конфигурации NetworkManager"
curl -sL "${URL_NM_CONF}" > "${FILE_NM_CONF}"
if [ ! -f "$FILE_NM_CONNECTION" ]; then
    curl -sL "${URL_NM_CONNECTION}" > "${FILE_NM_CONNECTION}"
fi

warn "Изменения нужно записать в файл /etc/network/interfaces"
info "Если вы вручную изменили сеть на хосте, теперь изменения будут перезаписаны"
info "Если вы не перезапишите сейчас, вам нужно будет сделать это позже вручную"
info "Вы хотите продолжить перезапись файла /etc/network/interfaces file? [N/y] "
read answer < /dev/tty

if [[ "$answer" =~ "y" ]] || [[ "$answer" =~ "Y" ]]; then
    info "Изменение /etc/network/interfaces"
    curl -sL "${URL_INTERFACES}" > "${FILE_INTERFACES}";
fi

info "Перезапуск NetworkManager"
systemctl restart "${SERVICE_NM}"

# Parse command line parameters
while [[ $# -gt 0 ]]; do
    arg="$1"

    case $arg in
        -m|--machine)
            MACHINE=$2
            shift
            ;;
        -d|--data-share)
            DATA_SHARE=$2
            shift
            ;;
        -p|--prefix)
            PREFIX=$2
            shift
            ;;
        -s|--sysconfdir)
            SYSCONFDIR=$2
            shift
            ;;
        *)
            error "Неопознанная опция $1"
            ;;
    esac
    shift
done

PREFIX=${PREFIX:-/usr}
SYSCONFDIR=${SYSCONFDIR:-/etc}
DATA_SHARE=${DATA_SHARE:-$PREFIX/share/hassio}
CONFIG=$SYSCONFDIR/hassio.json

# Generate hardware options
case $ARCH in
    "i386" | "i686")
        MACHINE=${MACHINE:=qemux86}
        HASSIO_DOCKER="$DOCKER_REPO/i386-hassio-supervisor"
    ;;
    "x86_64")
        MACHINE=${MACHINE:=qemux86-64}
        HASSIO_DOCKER="$DOCKER_REPO/amd64-hassio-supervisor"
    ;;
    "arm" |"armv6l")
        if [ -z $MACHINE ]; then
            error "Please set machine for $ARCH"
        fi
        HASSIO_DOCKER="$DOCKER_REPO/armhf-hassio-supervisor"
    ;;
    "armv7l")
        if [ -z $MACHINE ]; then
            error "Please set machine for $ARCH"
        fi
        HASSIO_DOCKER="$DOCKER_REPO/armv7-hassio-supervisor"
    ;;
    "aarch64")
        if [ -z $MACHINE ]; then
            error "Please set machine for $ARCH"
        fi
        HASSIO_DOCKER="$DOCKER_REPO/aarch64-hassio-supervisor"
    ;;
    *)
        error "$ARCH неизвестна!"
    ;;
esac

if [[ ! "${MACHINE}" =~ ^(intel-nuc|odroid-c2|odroid-n2|odroid-xu|qemuarm|qemuarm-64|qemux86|qemux86-64|raspberrypi|raspberrypi2|raspberrypi3|raspberrypi4|raspberrypi3-64|raspberrypi4-64|tinker)$ ]]; then
    error "Неизвестный тип сервера ${MACHINE}!"
fi

### Main

# Init folders
if [ ! -d "$DATA_SHARE" ]; then
    mkdir -p "$DATA_SHARE"
fi

if [ ! -d "${PREFIX}/sbin" ]; then
    mkdir -p "${PREFIX}/sbin"
fi

if [ ! -d "${PREFIX}/bin" ]; then
    mkdir -p "${PREFIX}/bin"
fi
# Read infos from web
HASSIO_VERSION=$(curl -s $URL_VERSION | jq -e -r '.supervisor')

##
# Write configuration
cat > "$CONFIG" <<- EOF
{
    "supervisor": "${HASSIO_DOCKER}",
    "machine": "${MACHINE}",
    "data": "${DATA_SHARE}"
}
EOF

##
# Pull supervisor image
info "Установка контейнера Docker Supervisor"
docker pull "$HASSIO_DOCKER:$HASSIO_VERSION" > /dev/null
docker tag "$HASSIO_DOCKER:$HASSIO_VERSION" "$HASSIO_DOCKER:latest" > /dev/null

##
# Install Hass.io Supervisor
info "Установка загрузочных скриптов supervisor"
curl -sL ${URL_BIN_HASSIO} > "${PREFIX}/sbin/hassio-supervisor"
curl -sL ${URL_SERVICE_HASSIO} > "${SYSCONFDIR}/systemd/system/hassio-supervisor.service"

sed -i "s,%%HASSIO_CONFIG%%,${CONFIG},g" "${PREFIX}"/sbin/hassio-supervisor
sed -i -e "s,%%BINARY_DOCKER%%,${BINARY_DOCKER},g" \
       -e "s,%%SERVICE_DOCKER%%,${SERVICE_DOCKER},g" \
       -e "s,%%BINARY_HASSIO%%,${PREFIX}/sbin/hassio-supervisor,g" \
       "${SYSCONFDIR}/systemd/system/hassio-supervisor.service"

chmod a+x "${PREFIX}/sbin/hassio-supervisor"
systemctl enable hassio-supervisor.service > /dev/null 2>&1;

#
# Install Hass.io AppArmor
info "Установка скриптов AppArmor"
mkdir -p "${DATA_SHARE}/apparmor"
curl -sL ${URL_BIN_APPARMOR} > "${PREFIX}/sbin/hassio-apparmor"
curl -sL ${URL_SERVICE_APPARMOR} > "${SYSCONFDIR}/systemd/system/hassio-apparmor.service"
curl -sL ${URL_APPARMOR_PROFILE} > "${DATA_SHARE}/apparmor/hassio-supervisor"

sed -i "s,%%HASSIO_CONFIG%%,${CONFIG},g" "${PREFIX}/sbin/hassio-apparmor"
sed -i -e "s,%%SERVICE_DOCKER%%,${SERVICE_DOCKER},g" \
    -e "s,%%HASSIO_APPARMOR_BINARY%%,${PREFIX}/sbin/hassio-apparmor,g" \
    "${SYSCONFDIR}/systemd/system/hassio-apparmor.service"

chmod a+x "${PREFIX}/sbin/hassio-apparmor"
systemctl enable hassio-apparmor.service > /dev/null 2>&1;
systemctl start hassio-apparmor.service


##
# Init system
info "Запуск Home Assistant Supervised"
systemctl start hassio-supervisor.service

##
# Setup CLI
info "Установка 'ha' cli"
curl -sL ${URL_HA} > "${PREFIX}/bin/ha"
chmod a+x "${PREFIX}/bin/ha"

info
info "Home Assistant supervised установлен"
info "Первый запуск может быть длительным (20 минут), когда все будет готово системв будет доступна по адресу:"
info "http://${IP_ADDRESS}:8123"
info
info "Автор модификации скрипта будет принимает благодорность за бессонные ночи в виде https://yoomoney.ru/to/410011383527168"